import Foundation
import NIOCore
@preconcurrency import NIOSSH
import Observation

public struct HostKeyChallenge: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case firstUse, changed(previousFingerprint: String) }
    public let hostname: String
    public let port: Int
    public let fingerprintSHA256: String
    public let kind: Kind
}

public enum SessionState: Equatable, Sendable { case idle, connecting, connected, failed(String), closed }

/// One SSH connection running the host's herdr attach command in an `xterm-256color` PTY.
///
/// Host keys are pinned on first use (after `confirmHostKey` approves) and a changed key is
/// always refused: the session fails and `rejectedHostKey` carries the `.changed` challenge.
@MainActor @Observable public final class TerminalSession {
    public let profile: HostProfile
    public private(set) var state: SessionState = .idle
    /// Set when the host presented a key that differs from the pinned one.
    public private(set) var rejectedHostKey: HostKeyChallenge?
    @ObservationIgnored public var onOutput: (@MainActor ([UInt8]) -> Void)?

    @ObservationIgnored private let store: HostStore
    @ObservationIgnored private let confirmHostKey: @MainActor (HostKeyChallenge) async -> Bool
    @ObservationIgnored private var connection: Channel?  // TCP
    @ObservationIgnored private var pty: Channel?  // SSH session channel
    @ObservationIgnored private var exitStatus: Int?
    @ObservationIgnored private var lastError: String?
    @ObservationIgnored private var connectedAt: ContinuousClock.Instant?
    @ObservationIgnored private var recentOutput: [UInt8] = []
    @ObservationIgnored private var generation = 0

    public init(
        profile: HostProfile, store: HostStore,
        confirmHostKey: @escaping @MainActor (HostKeyChallenge) async -> Bool
    ) {
        self.profile = profile
        self.store = store
        self.confirmHostKey = confirmHostKey
    }

    deinit { connection?.close(promise: nil) }

    public func connect(cols: Int, rows: Int) async {
        switch state {
        case .connecting, .connected: return
        case .idle, .failed, .closed: break
        }
        generation += 1
        let generation = generation
        state = .connecting
        rejectedHostKey = nil
        exitStatus = nil
        lastError = nil
        connectedAt = nil
        recentOutput = []
        do {
            let command = try profile.resolvedCommand()
            let connection = try await authenticate(generation: generation)
            guard isCurrent(generation) else { connection.close(promise: nil); return }
            self.connection = connection
            try await openPTY(on: connection, command: command, cols: cols, rows: rows, generation: generation)
            if isCurrent(generation), pty != nil {
                state = .connected
                connectedAt = .now
            }
        } catch {
            guard isCurrent(generation) else { return }
            connection?.close(promise: nil)
            state = .failed(SSHTransport.describe(error))
        }
    }

    public func send(_ bytes: [UInt8]) {
        guard let pty, !bytes.isEmpty else { return }
        pty.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(ByteBuffer(bytes: bytes))), promise: nil)
    }

    public func resize(cols: Int, rows: Int) {
        guard let pty, cols > 0, rows > 0 else { return }
        let change = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: cols, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0)
        pty.triggerUserOutboundEvent(change, promise: nil)
    }

    public func disconnect() {
        generation += 1
        connection?.close(promise: nil)
        connection = nil
        pty = nil
        if state != .idle { state = .closed }
    }

    // MARK: - Connection

    private func isCurrent(_ generation: Int) -> Bool { generation == self.generation }

    /// TCP + key exchange + auth, pinning the host key on first use.
    /// Rechecks `generation` after every await, so a `disconnect()` during the trust prompt
    /// can't pin the stale answer or open another socket.
    private func authenticate(generation: Int) async throws -> Channel {
        let host = HostKeyPins.canonical(profile.hostname), port = profile.port
        let credentials = Credentials(
            username: profile.username, key: try DeviceKey.privateKey(), password: store.password(for: profile.id))
        while true {
            let pinned = try HostKeyPins.fingerprint(hostname: host, port: port)
            let validator = PinValidator(accepted: pinned.map { [$0] } ?? [])
            do {
                return try await SSHTransport.open(host: host, port: port, credentials: credentials, validator: validator)
            } catch {
                guard isCurrent(generation) else { throw CancellationError() }
                // Decide from what the host presented, not from how the failure surfaced.
                guard let presented = validator.presented.withLockedValue({ $0 }), presented != pinned else { throw error }
                if let pinned {
                    rejectedHostKey = HostKeyChallenge(
                        hostname: host, port: port, fingerprintSHA256: presented, kind: .changed(previousFingerprint: pinned))
                    throw SessionError.hostKeyChanged(host: host, port: port, presented: presented, pinned: pinned)
                }
                let challenge = HostKeyChallenge(hostname: host, port: port, fingerprintSHA256: presented, kind: .firstUse)
                let trusted = await confirmHostKey(challenge)
                guard isCurrent(generation) else { throw CancellationError() }
                guard trusted else { throw SessionError.hostKeyNotTrusted }
                // Add-only: if another session pinned this host meanwhile, keep its pin. The loop re-reads
                // the pin, so this key either matches it or takes the changed-key refusal.
                try HostKeyPins.pin(presented, hostname: host, port: port)
                // Reconnect; the next handshake must present exactly the pinned key.
            }
        }
    }

    /// Opens a session channel, requests the PTY, and execs the attach command.
    private func openPTY(on connection: Channel, command: String, cols: Int, rows: Int, generation: Int) async throws {
        let (events, sink) = AsyncStream<SessionEvent>.makeStream()
        let ready = connection.eventLoop.makePromise(of: Void.self)
        let pty = try await SSHTransport.openSessionChannel(on: connection, replies: 2, ready: ready, events: sink)
        guard isCurrent(generation) else { throw CancellationError() }
        self.pty = pty
        Task { [weak self] in
            for await event in events { self?.handle(event, generation: generation) }
        }
        do {
            try await pty.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: "xterm-256color",
                terminalCharacterWidth: max(cols, 1), terminalRowHeight: max(rows, 1),
                terminalPixelWidth: 0, terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([.init(rawValue: 42): 1]))).get()  // IUTF8 (RFC 8160)
            try await pty.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).get()
            try await ready.futureResult.get()
        } catch {
            ready.fail(error)
            throw error
        }
    }

    private func handle(_ event: SessionEvent, generation: Int) {
        guard isCurrent(generation) else { return }
        switch event {
        case .output(let bytes):
            recentOutput = Array((recentOutput + bytes.suffix(4096)).suffix(4096))
            onOutput?(bytes)
            pty?.read()  // the next chunk
        case .exitStatus(let code): exitStatus = code
        case .error(let message): lastError = message
        case .closed:
            // The single place that settles the end state of an established channel.
            connection?.close(promise: nil)
            connection = nil
            pty = nil
            // Windows exits 0 even when `herdr` is not recognized, so a close right after connecting
            // is a failure on every platform; the last output lines say why.
            let quick = connectedAt.map { .now - $0 < .seconds(2) } ?? true
            let reason: String? = switch exitStatus {
            case 0? where !quick: nil
            case 0?: "The remote command exited right after connecting."
            case 127?: "The remote command exited with status 127: herdr (or the command) was not found on the host."
            case let code?: "The remote command exited with status \(code)."
            case nil: lastError ?? "The connection closed."
            }
            if let reason {
                let tail = SSHTransport.lastLines(recentOutput)
                state = .failed(tail.isEmpty ? reason : reason + "\n" + tail)
            } else {
                state = .closed
            }
        }
    }

}
