import CryptoKit
import Foundation
import NIOCore
import Testing
@testable import HerdrKit

@MainActor final class ProgressLog {
    var steps: [Pairing.Progress] = []
}

@Suite struct PairingRulesTests {
    @Test func tailnetAddresses() throws {
        for address in ["100.64.0.1", "100.127.255.255", "100.103.220.58", "fd7a:115c:a1e0::1", "::ffff:100.64.0.9"] {
            #expect(Pairing.isTailnet(try SocketAddress(ipAddress: address, port: 22)), "\(address)")
        }
        for address in ["100.63.255.255", "100.128.0.0", "127.0.0.1", "10.0.0.1", "8.8.8.8", "fd7a:115c:a1e1::1", "::1", "::ffff:8.8.8.8"] {
            #expect(!Pairing.isTailnet(try SocketAddress(ipAddress: address, port: 22)), "\(address)")
        }
    }

    @Test func deviceNameIsPrintableAndShort() {
        #expect(Pairing.sanitizedDeviceName("James’s iPhone") == "James’s iPhone")
        #expect(Pairing.sanitizedDeviceName(" a\nb\u{202E}c\u{00A0}d\t ") == "abc d")
        #expect(Pairing.sanitizedDeviceName("\u{07}\n") == "Herdr device")
        #expect(Pairing.sanitizedDeviceName(String(repeating: "é", count: 100)).unicodeScalars.count == 64)
    }

    /// The last non-empty stdout line decides; statuses 3 and 4 only matter when there is no token.
    @Test(arguments: [
        ("OK\n", 0, nil), ("OK\r\n", 0, nil), ("welcome\nOK\n\n", 0, nil), ("OK", 1, "failed"), ("OK", nil, "failed"),
        ("DENIED\r\n", 1, "denied"), ("DENIED", 0, "denied"), ("", 3, "denied"),
        ("EXPIRED\r\n", 1, "expired"), ("", 4, "expired"), ("INVALID\n", 1, "failed"), ("OK\nINVALID\n", 0, "failed"),
    ] as [(String, Int?, String?)])
    func verdictReadsTheResultToken(stdout: String, status: Int?, expected: String?) {
        let verdict = Pairing.verdict(status: status, stdout: Array(stdout.utf8), stderr: Array("warning: noise\n".utf8))
        switch verdict {
        case nil: #expect(expected == nil)
        case .denied?: #expect(expected == "denied")
        case .expired?: #expect(expected == "expired")
        case .failed?: #expect(expected == "failed")
        default: Issue.record("unexpected \(String(describing: verdict))")
        }
    }

    @Test func enrollRequestIsKeyThenName() throws {
        let lines = try Pairing.enrollRequest(deviceName: "iPad\nrm -rf").split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3 && lines[2].isEmpty)
        #expect(lines[0] == (try DeviceKey.publicKeyOpenSSH()).split(separator: " ").prefix(2).joined(separator: " "))
        #expect(lines[1] == "iPadrm -rf")
    }
}

/// Enroll's refusals against an in-process SSH server that rejects every login.
@MainActor @Suite struct PairingEnrollTests {
    let server: TestSSHServer

    init() async throws { server = try await TestSSHServer.start() }

    func invitation(hosts: [String] = ["127.0.0.1"], port: Int? = nil, fingerprints: [String]? = nil, expiresIn: TimeInterval = 600) -> Invitation {
        Invitation(
            name: "Test Mac", username: "t", platform: .unix, hosts: hosts, port: port ?? server.port,
            fingerprints: fingerprints ?? [server.fingerprint], seed: Curve25519.Signing.PrivateKey().rawRepresentation,
            expiresAt: .now + expiresIn, session: nil, allowRemote: { _ in true })
    }

    func enroll(_ invitation: Invitation, log: ProgressLog = ProgressLog()) async -> PairingError? {
        do {
            _ = try await Pairing.enroll(invitation, deviceName: "test") { log.steps.append($0) }
            return nil
        } catch {
            return error
        }
    }

    func pin() throws -> String? { try HostKeyPins.fingerprint(hostname: "127.0.0.1", port: server.port) }

    @Test func hostKeyNotInTheCodeIsRefused() async throws {
        defer { server.stop() }
        let other = "SHA256:" + String(repeating: "C", count: 43)
        #expect(await enroll(invitation(fingerprints: [other])) == .hostKeyMismatch(hostname: "127.0.0.1", fingerprint: server.fingerprint))
        #expect(server.authAttempts == 0)  // the one-time key never went out
        #expect(try pin() == nil)
    }

    @Test func conflictingPinIsRefusedBeforeConnecting() async throws {
        defer { server.stop() }
        let existing = "SHA256:" + String(repeating: "B", count: 43)
        try HostKeyPins.pin(existing, hostname: "127.0.0.1", port: server.port)
        #expect(await enroll(invitation()) == .conflictingPin(hostname: "127.0.0.1", port: server.port))
        #expect(server.connections == 0)
        #expect(try pin() == existing)
    }

    @Test func pinThatIsInTheCodeIsUsed() async throws {
        defer { server.stop() }
        try HostKeyPins.pin(server.fingerprint, hostname: "127.0.0.1", port: server.port)
        #expect(await enroll(invitation()) == .pairingKeyRejected)
        #expect(server.authAttempts > 0)
    }

    @Test func hostsAreTriedInOrder() async throws {
        defer { server.stop() }
        let log = ProgressLog()
        #expect(await enroll(invitation(hosts: ["herdrkit-no-such-host.invalid", "127.0.0.1"]), log: log) == .pairingKeyRejected)
        #expect(log.steps == [.connecting(hostname: "herdrkit-no-such-host.invalid"), .connecting(hostname: "127.0.0.1")])
        #expect(try pin() == nil)  // nothing is pinned without the computer's OK
    }

    @Test func nothingReachable() async throws {
        defer { server.stop() }
        guard case .unreachable? = await enroll(invitation(port: 1)) else { Issue.record("expected unreachable"); return }
    }

    @Test func offTailnetAddressIsRefusedBeforeSSH() async throws {
        defer { server.stop() }
        var invitation = invitation()
        invitation.allowRemote = Pairing.isTailnet
        #expect(await enroll(invitation) == .notOnTailnet(hostname: "127.0.0.1", address: "127.0.0.1"))
        #expect(server.connections == 1 && server.authAttempts == 0)
        #expect(try pin() == nil)
    }

    @Test func expiredCodeIsRefusedBeforeConnecting() async throws {
        defer { server.stop() }
        #expect(await enroll(invitation(expiresIn: -1)) == .linkExpired)
        #expect(server.connections == 0)
    }
}

/// Plays the computer's side of ADR 0002 on this Mac: a real restricted one-time key whose forced
/// command stands in for `herdr-pair.py --enroll`, reached over the tailnet address.
/// Opt in with `HERDR_IOS_SSH_TEST=1`; each test removes its authorized_keys line.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HERDR_IOS_SSH_TEST"] == "1"))
struct PairingSSHDTests {
    nonisolated static let host = "100.103.220.58"  // this Mac on the tailnet (docs/plan.md)

    @Test func approvedPairingPinsAndReturnsTheProfile() async throws {
        let computer = try FakeComputer(mode: "ok")
        defer { computer.remove() }
        let payload = try PairingPayload(url: computer.url(session: "pair-test"))
        let log = ProgressLog()
        let profile = try await Pairing.enroll(payload: payload, deviceName: "HerdrKit test\u{00A0}iPad") { log.steps.append($0) }
        #expect(log.steps == [.connecting(hostname: Self.host), .waitingForApproval(computer: "HerdrKit test Mac")])
        #expect(profile.name == "HerdrKit test Mac" && profile.hostname == Self.host && profile.port == 22)
        #expect(profile.username == NSUserName() && profile.platform == .unix && profile.herdrSession == "pair-test")
        #expect(profile.remoteCommand == nil)
        let pin = try #require(try HostKeyPins.fingerprint(hostname: Self.host, port: 22))
        #expect(try sshdFingerprints(excludingRSA: true).contains(pin))
        let received = try String(contentsOf: computer.received, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        let deviceKey = try DeviceKey.publicKeyOpenSSH().split(separator: " ").prefix(2).joined(separator: " ")
        #expect(received.prefix(5) == [Substring(deviceKey), "HerdrKit test iPad", "notty", "rest=", "orig=herdr-pair"])
    }

    /// A stderr warning after `OK` doesn't hide the token (stdout and stderr are read separately).
    @Test func okWithStderrNoiseStillPairs() async throws {
        let computer = try FakeComputer(mode: "ok-noisy")
        defer { computer.remove() }
        let profile = try await Pairing.enroll(payload: try PairingPayload(url: computer.url(session: nil)), deviceName: "t")
        #expect(profile.hostname == Self.host)
    }

    /// Windows PowerShell reports the helper's exit 3 as 1; the DENIED token still decides.
    @Test func denialWithACollapsedStatusIsStillDenied() async throws {
        let computer = try FakeComputer(mode: "deny-as-1")
        defer { computer.remove() }
        let payload = try PairingPayload(url: computer.url(session: nil))
        await #expect(throws: PairingError.denied(output: "DENIED")) { try await Pairing.enroll(payload: payload, deviceName: "t") }
        #expect(try HostKeyPins.fingerprint(hostname: Self.host, port: 22) == nil)
    }

    @Test func deniedLeavesNoPin() async throws {
        let computer = try FakeComputer(mode: "deny")
        defer { computer.remove() }
        let payload = try PairingPayload(url: computer.url(session: nil))
        await #expect(throws: PairingError.denied(output: "DENIED")) { try await Pairing.enroll(payload: payload, deviceName: "t") }
        #expect(try HostKeyPins.fingerprint(hostname: Self.host, port: 22) == nil)
    }

    @Test func expiredOnTheComputer() async throws {
        let computer = try FakeComputer(mode: "expire")
        defer { computer.remove() }
        let payload = try PairingPayload(url: computer.url(session: nil))
        await #expect(throws: PairingError.expired(output: "EXPIRED")) { try await Pairing.enroll(payload: payload, deviceName: "t") }
        #expect(try HostKeyPins.fingerprint(hostname: Self.host, port: 22) == nil)
    }

    @Test func cancellingWhileWaitingForApprovalStopsPromptly() async throws {
        let computer = try FakeComputer(mode: "hang")
        defer { computer.remove() }
        let payload = try PairingPayload(url: computer.url(session: nil))
        let log = ProgressLog()
        let task = Task { @MainActor in try await Pairing.enroll(payload: payload, deviceName: "t") { log.steps.append($0) } }
        #expect(await eventually { log.steps.last == .waitingForApproval(computer: "HerdrKit test Mac") })
        let start = ContinuousClock.now
        task.cancel()
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(5))
        guard case .failure(let error) = result else { Issue.record("expected cancellation"); return }
        #expect(error as? PairingError == .cancelled)
        #expect(try HostKeyPins.fingerprint(hostname: Self.host, port: 22) == nil)
    }
}

/// A restricted one-time key in ~/.ssh/authorized_keys plus the stand-in forced command.
struct FakeComputer {
    let dir: URL
    let received: URL
    let id: String
    let seed: Data

    static let authorizedKeys = URL.homeDirectory.appending(path: ".ssh/authorized_keys")

    init(mode: String) throws {
        try? HostKeyPins.forget(hostname: PairingSSHDTests.host, port: 22)
        dir = URL.temporaryDirectory.appending(path: "herdrkit-pair-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        received = dir.appending(path: "received")
        id = base64URL(Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
        let key = Curve25519.Signing.PrivateKey()
        seed = key.rawRepresentation
        // Records what the phone sent. `cat` returns only once the phone closes stdin.
        let script = dir.appending(path: "enroll.sh")
        try """
        mode=$1 out=$2
        if [ -t 0 ]; then tty=tty; else tty=notty; fi
        IFS= read -r key; IFS= read -r name
        rest=$(cat)
        printf '%s\\n%s\\n%s\\nrest=%s\\norig=%s\\n' "$key" "$name" "$tty" "$rest" "$SSH_ORIGINAL_COMMAND" > "$out"
        case $mode in
          ok) echo OK; exit 0 ;;
          ok-noisy) echo OK; echo 'warning: noise' >&2; exit 0 ;;
          deny-as-1) printf 'DENIED\r\n'; exit 1 ;;
          deny) echo DENIED; exit 3 ;;
          expire) echo EXPIRED; exit 4 ;;
          hang) sleep 30 ;;
        esac

        """.write(to: script, atomically: true, encoding: .utf8)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        let expiry = formatter.string(from: .now + 600) + "Z"
        let blob = DeviceKey.wireBlob(key.publicKey).base64EncodedString()
        let line = #"restrict,expiry-time="\#(expiry)",from="100.64.0.0/10,fd7a:115c:a1e0::/48,127.0.0.1,::1",command="/bin/sh \#(script.path) \#(mode) \#(received.path)" ssh-ed25519 \#(blob) herdr-pair:\#(id)"#
        var existing = (try? String(contentsOf: Self.authorizedKeys, encoding: .utf8)) ?? ""
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        try (existing + line + "\n").write(to: Self.authorizedKeys, atomically: false, encoding: .utf8)
    }

    func url(session: String?) -> URL {
        var parts = URLComponents()
        parts.scheme = "herdr"
        parts.host = "pair"
        parts.queryItems = [
            .init(name: "v", value: "1"), .init(name: "id", value: id), .init(name: "n", value: "HerdrKit test Mac"),
            .init(name: "u", value: NSUserName()), .init(name: "os", value: "unix"), .init(name: "h", value: PairingSSHDTests.host),
            .init(name: "p", value: "22"),
            .init(name: "fp", value: ((try? sshdFingerprints(excludingRSA: true)) ?? []).sorted().joined(separator: ",")),
            .init(name: "k", value: base64URL(seed)), .init(name: "x", value: String(Int(Date.now.timeIntervalSince1970) + 600)),
        ] + (session.map { [URLQueryItem(name: "s", value: $0)] } ?? [])
        return parts.url!
    }

    /// Deletes exactly this key's line (other lines, including a sibling's, are rewritten untouched).
    func remove() {
        try? HostKeyPins.forget(hostname: PairingSSHDTests.host, port: 22)
        try? FileManager.default.removeItem(at: dir)
        guard let text = try? String(contentsOf: Self.authorizedKeys, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasSuffix("herdr-pair:\(id)") }
        try? kept.joined(separator: "\n").write(to: Self.authorizedKeys, atomically: false, encoding: .utf8)
    }
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}
