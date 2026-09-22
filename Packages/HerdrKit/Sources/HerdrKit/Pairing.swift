import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
@preconcurrency import NIOSSH

/// QR pairing (ADR 0002): enrolls this device's key on a computer through the one-time key in a
/// `PairingPayload`. The host key must match one of the payload's fingerprints (there is no TOFU
/// prompt), and an existing pin always wins. Nothing here logs the payload or its seed.
public enum Pairing {
    public enum Progress: Sendable, Equatable {
        case connecting(hostname: String)
        /// The computer has this device's key and is asking its user to approve it.
        case waitingForApproval(computer: String)
    }

    /// Tries `payload.hosts` in order until one is reachable. After the computer answers `OK` it
    /// pins the host key (add-only) and returns the profile to save: the payload's name, user,
    /// port, platform and session, the hostname that connected, and no `remoteCommand`.
    @MainActor
    public static func enroll(
        payload: PairingPayload, deviceName: String,
        progress: @escaping @MainActor (Progress) -> Void = { _ in }
    ) async throws(PairingError) -> HostProfile {
        try await enroll(Invitation(payload), deviceName: deviceName, progress: progress)
    }

    /// Tailscale's ranges (ADR 0002): `100.64.0.0/10` and `fd7a:115c:a1e0::/48`. A QR short name can
    /// resolve off the tailnet through DNS search domains, so the connected address is checked too.
    static func isTailnet(_ address: SocketAddress) -> Bool {
        switch address {
        case .v4(let v4):
            let bytes = withUnsafeBytes(of: v4.address.sin_addr) { Array($0) }
            return bytes[0] == 100 && (64...127).contains(bytes[1])
        case .v6(let v6):
            let bytes = withUnsafeBytes(of: v6.address.sin6_addr) { Array($0) }
            if bytes.prefix(12).elementsEqual([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff]) {  // IPv4-mapped
                return bytes[12] == 100 && (64...127).contains(bytes[13])
            }
            return bytes.prefix(6).elementsEqual([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0])
        case .unixDomainSocket: return false
        }
    }

    /// The host side waits up to 120 s for approval; this is the phone's backstop.
    static let approvalTimeout: TimeAmount = .seconds(180)

    @MainActor
    static func enroll(
        _ invitation: Invitation, deviceName: String, progress: @escaping @MainActor (Progress) -> Void
    ) async throws(PairingError) -> HostProfile {
        do {
            return try await run(invitation, deviceName: deviceName, progress: progress)
        } catch let error as PairingError {
            throw error
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .failed(status: nil, output: SSHTransport.describe(error))
        }
    }

    @MainActor
    private static func run(
        _ invitation: Invitation, deviceName: String, progress: @MainActor (Progress) -> Void
    ) async throws -> HostProfile {
        // The confirmation screen can sit open past the expiry the parser checked.
        guard invitation.expiresAt > .now else { throw PairingError.linkExpired }
        let port = invitation.port
        let offered = Set(invitation.fingerprints)
        // Existing pins win: refuse before the one-time key is used against any of the names.
        var accepted: [String: Set<String>] = [:]
        for host in invitation.hosts {
            guard let pinned = try HostKeyPins.fingerprint(hostname: host, port: port) else {
                accepted[host] = offered
                continue
            }
            guard offered.contains(pinned) else { throw PairingError.conflictingPin(hostname: host, port: port) }
            accepted[host] = [pinned]
        }
        let credentials = Credentials(
            username: invitation.username,
            key: try Curve25519.Signing.PrivateKey(rawRepresentation: invitation.seed), password: nil)
        let request = try enrollRequest(deviceName: deviceName)

        var unreachable = "No hostname to try."
        var offTailnet: (host: String, address: String)?
        for host in invitation.hosts {
            try Task.checkCancellation()
            progress(.connecting(hostname: host))
            let validator = PinValidator(accepted: accepted[host] ?? [])
            let connection: Channel
            do {
                connection = try await SSHTransport.open(
                    host: host, port: port, credentials: credentials, validator: validator,
                    allowRemote: invitation.allowRemote)
            } catch {
                if case SessionError.remoteNotAllowed(let address)? = error as? SessionError {
                    offTailnet = (host, address)
                    continue  // nothing was sent to it; another name may resolve onto the tailnet
                }
                guard let presented = validator.presented.withLockedValue({ $0 }) else {
                    unreachable = SSHTransport.describe(error)
                    continue  // never reached SSH (DNS, route, refused): try the next name
                }
                guard validator.accepted.contains(presented) else {
                    throw offered.contains(presented)
                        ? PairingError.conflictingPin(hostname: host, port: port)
                        : PairingError.hostKeyMismatch(hostname: host, fingerprint: presented)
                }
                if case SessionError.authenticationFailed? = error as? SessionError { throw PairingError.pairingKeyRejected }
                throw error
            }
            defer { connection.close(promise: nil) }
            guard let presented = validator.presented.withLockedValue({ $0 }) else { throw PairingError.pairingKeyRejected }

            let (status, stdout, stderr) = try await withTaskCancellationHandler {
                try await exchange(on: connection, request: request, computer: invitation.name, progress: progress)
            } onCancel: {
                connection.close(promise: nil)
            }
            try Task.checkCancellation()
            if let refusal = verdict(status: status, stdout: stdout, stderr: stderr) { throw refusal }
            // Add-only. If a pin appeared while the computer was deciding, it must be this key.
            if try !HostKeyPins.pin(presented, hostname: host, port: port),
               try HostKeyPins.fingerprint(hostname: host, port: port) != presented {
                throw PairingError.conflictingPin(hostname: host, port: port)
            }
            return HostProfile(
                name: invitation.name, hostname: host, port: port, username: invitation.username,
                platform: invitation.platform, herdrSession: invitation.session)
        }
        if let offTailnet { throw PairingError.notOnTailnet(hostname: offTailnet.host, address: offTailnet.address) }
        throw PairingError.unreachable(unreachable)
    }

    /// Execs on the one-time key (its forced command runs whatever is asked; no PTY), writes the two
    /// request lines, closes stdin, and reads stdout and stderr until the command exits.
    @MainActor
    private static func exchange(
        on connection: Channel, request: String, computer: String, progress: @MainActor (Progress) -> Void
    ) async throws -> (status: Int?, stdout: [UInt8], stderr: [UInt8]) {
        let (events, sink) = AsyncStream<SessionEvent>.makeStream()
        let ready = connection.eventLoop.makePromise(of: Void.self)
        let channel = try await SSHTransport.openSessionChannel(on: connection, replies: 1, ready: ready, events: sink)
        do {
            try await channel.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: "herdr-pair", wantReply: true)).get()
            try await ready.futureResult.get()
        } catch {
            ready.fail(error)
            throw error
        }
        // A write can fail if the helper already answered (EXPIRED); the answer is still read below.
        try? await channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(string: request)))).get()
        try? await channel.close(mode: .output).get()
        progress(.waitingForApproval(computer: computer))

        let timeout = connection.eventLoop.scheduleTask(in: approvalTimeout) { connection.close(promise: nil) }
        defer { timeout.cancel() }
        var status: Int?
        var stdout: [UInt8] = []
        var stderr: [UInt8] = []
        for await event in events {
            switch event {
            case .output(let bytes):
                stdout = Array((stdout + bytes).suffix(16_384))
                channel.read()
            case .stderr(let bytes):
                stderr = Array((stderr + bytes).suffix(16_384))
                channel.read()
            case .exitStatus(let code): status = code
            case .error, .closed: break
            }
        }
        return (status, stdout, stderr)
    }

    /// The helper's answer is the last non-empty stdout line: `OK`, `DENIED`, `EXPIRED`, `USED` or
    /// `INVALID`. The token wins over the exit status, which is advisory because a Windows
    /// PowerShell DefaultShell reports every non-zero exit as 1. Success still needs exit 0. `nil`
    /// means approved.
    static func verdict(status: Int?, stdout: [UInt8], stderr: [UInt8]) -> PairingError? {
        let token = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.last { !$0.isEmpty }
        let tail = SSHTransport.lastLines(stdout + [0x0A] + stderr)
        switch (token, status) {
        case ("OK"?, 0?): return nil
        case ("DENIED"?, _), (nil, 3?): return .denied(output: tail)
        case ("EXPIRED"?, _), (nil, 4?): return .expired(output: tail)
        case ("USED"?, _), (nil, 5?): return .used(output: tail)
        default: return .failed(status: status, output: tail)
        }
    }

    /// Line 1: the device key as `ssh-ed25519 <base64>`. Line 2: the device name.
    static func enrollRequest(deviceName: String) throws -> String {
        let key = try DeviceKey.publicKeyOpenSSH().split(separator: " ").prefix(2).joined(separator: " ")
        return "\(key)\n\(sanitizedDeviceName(deviceName))\n"
    }

    /// At most 64 printable code points (Python's `str.isprintable`, which the host checks): other
    /// spaces become a plain space, and control, format and unassigned characters are dropped.
    static func sanitizedDeviceName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .spaceSeparator: scalars.append(" ")
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: continue
            default: scalars.append(scalar)
            }
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Herdr device" : String(String.UnicodeScalarView(trimmed.unicodeScalars.prefix(64)))
    }
}

/// The payload fields enroll uses. Tests build one directly to reach loopback servers, which the
/// payload parser's tailnet-only host rule refuses.
struct Invitation: Sendable {
    var name: String
    var username: String
    var platform: HostPlatform
    var hosts: [String]
    var port: Int
    var fingerprints: [String]
    var seed: Data
    var expiresAt: Date
    var session: String?
    var allowRemote: @Sendable (SocketAddress) -> Bool = Pairing.isTailnet
}

extension Invitation {
    init(_ payload: PairingPayload) {
        self.init(
            name: payload.name, username: payload.username, platform: payload.platform, hosts: payload.hosts,
            port: payload.port, fingerprints: payload.fingerprints, seed: payload.privateKeySeed,
            expiresAt: payload.expiresAt, session: payload.session)
    }
}

/// Why an enrollment failed. Output tails come from the computer's pairing helper.
public enum PairingError: Error, Equatable, Sendable, LocalizedError {
    case linkExpired
    /// This host:port already has a different pinned key. A pairing never replaces a pin.
    case conflictingPin(hostname: String, port: Int)
    /// The host presented a key the pairing code doesn't list.
    case hostKeyMismatch(hostname: String, fingerprint: String)
    /// No hostname in the code was reachable; the reason is from the last one tried.
    case unreachable(String)
    /// A hostname resolved to an address outside the tailnet. It was refused before any SSH traffic.
    case notOnTailnet(hostname: String, address: String)
    /// The computer turned down the one-time key (already used, expired, or removed).
    case pairingKeyRejected
    case denied(output: String)
    case expired(output: String)
    /// Another enroll claimed this code first, and its request may be waiting on the computer.
    case used(output: String)
    case failed(status: Int?, output: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .linkExpired: "This pairing code has expired. Generate a new code on the computer."
        case let .conflictingPin(hostname, port):
            "\(hostname):\(port) is already saved with a different host key, and pairing never replaces one. If the computer was reinstalled, forget its host key first."
        case let .hostKeyMismatch(hostname, fingerprint):
            "\(hostname) presented a host key (\(fingerprint)) that isn't in the pairing code, so pairing stopped."
        case .unreachable(let reason): "Couldn't reach the computer. Check that Tailscale is on for both devices. \(reason)"
        case let .notOnTailnet(hostname, address):
            "\(hostname) resolved to \(address), which is outside your tailnet, so pairing didn't connect. Check that Tailscale is on."
        case .pairingKeyRejected: "The computer didn't accept this pairing code. It may be used or expired; generate a new one."
        case .denied: "Pairing was declined on the computer."
        case .expired: "The request expired on the computer before it was approved. Generate a new code."
        case .used: "Another device already used this code. Deny its request on the computer, then pair again."
        case let .failed(status, output):
            "Pairing failed" + (status.map { " (exit status \($0))" } ?? "") + (output.isEmpty ? "." : ":\n\(output)")
        case .cancelled: "Pairing was cancelled."
        }
    }
}
