import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH
import Testing
@testable import HerdrKit

@Suite struct CommandTests {
    @Test func attachStringsMatchHostSetup() {
        #expect(HerdrCommand.attach(platform: .unix, session: nil) == #"exec "$SHELL" -lc 'herdr'"#)
        #expect(HerdrCommand.attach(platform: .unix, session: "work") == #"exec "$SHELL" -lc 'herdr session attach work'"#)
        #expect(HerdrCommand.attach(platform: .windows, session: nil) == "herdr")
        #expect(HerdrCommand.attach(platform: .windows, session: "work") == "herdr session attach work")
    }

    @Test func attachQuotesInvalidNamesInsteadOfCrashing() {
        #expect(HerdrCommand.attach(platform: .windows, session: "$(calc) 'x'") == "herdr session attach '$(calc) ''x'''")
        #expect(HerdrCommand.attach(platform: .windows, session: " ") == "herdr session attach ' '")
        #expect(HerdrCommand.attach(platform: .unix, session: ".") == #"exec "$SHELL" -lc 'herdr session attach .'"#)
    }

    /// Runs the unix attach command through real shells with a fake `herdr` that prints its argv:
    /// whatever the session string, herdr receives it as one literal argument and nothing else runs.
    @Test(arguments: ["work", "a b", "a'b", "$(touch pwned)", "`touch pwned`", "x;touch pwned", "'; touch pwned; '", #"\""#, ""])
    func unixAttachSurvivesTheShell(_ name: String) throws {
        let dir = URL.temporaryDirectory.appending(path: "herdrkit-sh-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for tool in ["fakeshell", "herdr"] {
            let url = dir.appending(path: tool)
            try "#!/bin/sh\nfor a; do printf '%s\\0' \"$a\"; done\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // sshd runs the command with the user's shell, which then execs `$SHELL -lc <inner>`.
        let outer = try sh(HerdrCommand.attach(platform: .unix, session: name), env: ["SHELL": dir.appending(path: "fakeshell").path], in: dir)
        #expect(outer.first == "-lc" && outer.count == 2)
        let inner = try sh(outer.last ?? "", env: ["PATH": "\(dir.path):/usr/bin:/bin"], in: dir)
        #expect(inner == ["session", "attach", name])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "pwned").path))
    }

    private func sh(_ command: String, env: [String: String], in dir: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = env
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
    }

    @Test(arguments: ["default", "a.b_c-1", String(repeating: "x", count: 64)])
    func validSessionNames(_ name: String) { #expect(HerdrCommand.sessionNameError(name) == nil) }

    @Test(arguments: ["", " ", ".", "..", String(repeating: "x", count: 65), "a b", "$(calc)", "a'b", "a\"b", "naïve", "a;b"])
    func invalidSessionNames(_ name: String) { #expect(HerdrCommand.sessionNameError(name) != nil) }

    @Test func resolvedCommand() throws {
        var profile = HostProfile(name: "m", hostname: "h", username: "u", herdrSession: " work ")
        #expect(try profile.resolvedCommand() == #"exec "$SHELL" -lc 'herdr session attach work'"#)
        profile.herdrSession = "  "
        #expect(try profile.resolvedCommand() == #"exec "$SHELL" -lc 'herdr'"#)
        profile.herdrSession = "$(rm -rf ~)"
        #expect(throws: SessionError.self) { try profile.resolvedCommand() }
        profile.remoteCommand = "   "
        #expect(throws: SessionError.self) { try profile.resolvedCommand() }
        profile.remoteCommand = "echo hi"  // an explicit override is used as-is
        #expect(try profile.resolvedCommand() == "echo hi")
    }
}

@Suite struct KeyTests {
    @Test func deviceKeyIsStableOpenSSHEd25519() throws {
        let line = try DeviceKey.publicKeyOpenSSH()
        #expect(line == (try DeviceKey.publicKeyOpenSSH()))
        #expect(line.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5"))
        _ = try NIOSSHPublicKey(openSSHPublicKey: line)
    }

    @Test func fingerprintMatchesSshKeygen() throws {
        // This Mac's sshd ed25519 host key; `ssh-keygen -lf` prints the same SHA256 value.
        let line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPAjE1mI2c0NdpJtgyM6X78KWFoWASbfap0XOy8ir/MK"
        #expect(HostKeyPins.fingerprintSHA256(try NIOSSHPublicKey(openSSHPublicKey: line)) == (try sshKeygenFingerprint(line)))
    }
}

@Suite struct OutputTailTests {
    @Test func stripsEscapesAndKeepsLastLines() {
        let unix = "\u{1B}[1mline1\u{1B}[0m\r\nline2\r\nzsh:1: command not found: herdr\r\n\r\nlast\r\n"
        #expect(TerminalSession.lastLines(Array(unix.utf8)) == "line2\nzsh:1: command not found: herdr\nlast")
        // ConPTY: mode switches, clear, OSC title, and cursor positioning instead of newlines.
        let conpty = "\u{1B}[?9001h\u{1B}[?1004h\u{1B}[2J\u{1B}[m\u{1B}[H\u{1B}]0;C:\\Windows\\conhost.exe\u{07}herdr : The term 'herdr' is not recognized\u{1B}[2;1HAt line:1\u{1B}[?25h"
        #expect(TerminalSession.lastLines(Array(conpty.utf8)) == "herdr : The term 'herdr' is not recognized\nAt line:1")
        #expect(TerminalSession.lastLines(Array("\u{1B}[?9001h\u{1B}]0;title\u{07}\u{1B}[?25h".utf8)).isEmpty)
    }
}

@MainActor @Suite struct HostStoreTests {
    @Test func persistsAndDeletes() throws {
        let url = URL.temporaryDirectory.appending(path: "herdrkit-\(UUID())/hosts.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let host = HostProfile(name: "Mac", hostname: "jamess-macbook-pro", username: "james", herdrSession: "work")
        let store = HostStore(fileURL: url)
        store.upsert(host)
        store.upsert(HostProfile(id: host.id, name: "Mac 2", hostname: host.hostname, username: "james"))
        store.setPassword("pw", for: host.id)
        #expect(HostStore(fileURL: url).hosts.map(\.name) == ["Mac 2"])
        #expect(store.password(for: host.id) == "pw")
        store.delete(host.id)
        #expect(HostStore(fileURL: url).hosts.isEmpty)
        #expect(!store.hasPassword(for: host.id))
    }
}

/// TOFU and the changed-key refusal against an in-process SSH server that rejects every login.
@MainActor @Suite struct HostKeyTrustTests {
    let server: TestSSHServer
    let store = HostStore(fileURL: URL.temporaryDirectory.appending(path: "herdrkit-\(UUID()).json"))

    init() async throws { server = try await TestSSHServer.start() }

    func session(_ confirm: @escaping @MainActor (HostKeyChallenge) async -> Bool) -> TerminalSession {
        TerminalSession(profile: HostProfile(name: "t", hostname: "127.0.0.1", port: server.port, username: "t"), store: store, confirmHostKey: confirm)
    }

    func pin() throws -> String? { try HostKeyPins.fingerprint(hostname: "127.0.0.1", port: server.port) }

    @Test func firstUseAcceptedPinsThenAuthenticates() async throws {
        defer { server.stop() }
        var challenges: [HostKeyChallenge] = []
        let s = session { challenges.append($0); return true }
        await s.connect(cols: 80, rows: 24)
        #expect(challenges == [HostKeyChallenge(hostname: "127.0.0.1", port: server.port, fingerprintSHA256: server.fingerprint, kind: .firstUse)])
        #expect(try pin() == server.fingerprint)
        #expect(server.authAttempts > 0)  // reconnected, the pinned key passed, and it reached auth
        #expect(s.state == .failed(SessionError.authenticationFailed.description))
    }

    @Test func firstUseDeclinedPinsNothing() async throws {
        defer { server.stop() }
        let s = session { _ in false }
        await s.connect(cols: 80, rows: 24)
        #expect(s.state == .failed(SessionError.hostKeyNotTrusted.description))
        #expect(try pin() == nil)
        #expect(server.authAttempts == 0)
    }

    @Test func changedKeyIsRefusedWithoutPrompt() async throws {
        defer { server.stop() }
        let stale = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        try HostKeyPins.pin(stale, hostname: "127.0.0.1", port: server.port)
        var prompted = false
        let s = session { _ in prompted = true; return true }
        await s.connect(cols: 80, rows: 24)
        #expect(!prompted)
        #expect(s.rejectedHostKey == HostKeyChallenge(hostname: "127.0.0.1", port: server.port, fingerprintSHA256: server.fingerprint, kind: .changed(previousFingerprint: stale)))
        guard case .failed(let message) = s.state else { Issue.record("expected refusal, got \(s.state)"); return }
        #expect(message.contains("changed"))
        #expect(try pin() == stale)
        #expect(server.authAttempts == 0)  // no credentials offered to the impostor
    }

    @Test func disconnectDuringTrustPromptDiscardsTheAnswer() async throws {
        defer { server.stop() }
        var s: TerminalSession!
        s = session { _ in s.disconnect(); return true }
        await s.connect(cols: 80, rows: 24)
        try await Task.sleep(for: .milliseconds(200))
        #expect(s.state == .closed)
        #expect(try pin() == nil)
        #expect(server.authAttempts == 0)  // no second socket
    }

    @Test func invalidSessionNameFailsBeforeConnecting() async throws {
        defer { server.stop() }
        var profile = HostProfile(name: "t", hostname: "127.0.0.1", port: server.port, username: "t")
        profile.herdrSession = "a b"
        var prompted = false
        let s = TerminalSession(profile: profile, store: store) { _ in prompted = true; return true }
        await s.connect(cols: 80, rows: 24)
        guard case .failed(let message) = s.state else { Issue.record("got \(s.state)"); return }
        #expect(message.contains("Invalid herdr session name"))
        #expect(!prompted)
    }
}

/// Against this Mac's sshd at 127.0.0.1:22 as the current user, authenticating with DeviceKey.
/// Opt in with `HERDR_IOS_SSH_TEST=1 swift test`; setup is in docs/lanes/transport.md.
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HERDR_IOS_SSH_TEST"] == "1"))
struct SSHDIntegrationTests {
    let store = HostStore(fileURL: URL.temporaryDirectory.appending(path: "herdrkit-\(UUID()).json"))

    func session(_ command: String, confirm: @escaping @MainActor (HostKeyChallenge) async -> Bool = { _ in true }) -> TerminalSession {
        TerminalSession(
            profile: HostProfile(name: "local", hostname: "127.0.0.1", username: NSUserName(), remoteCommand: command),
            store: store, confirmHostKey: confirm)
    }

    @Test func deviceKeyIsAuthorized() throws {
        let blob = try DeviceKey.publicKeyOpenSSH().split(separator: " ")[1]
        let keys = (try? String(contentsOf: URL.homeDirectory.appending(path: ".ssh/authorized_keys"), encoding: .utf8)) ?? ""
        #expect(keys.contains(blob), "append: from=\"127.0.0.1,::1,100.64.0.0/10\" ssh-ed25519 \(blob) herdr-ios-test")
    }

    @Test func firstUsePinsTheSshdKey() async throws {
        store.forgetHostKey(hostname: "127.0.0.1", port: 22)
        var challenges: [HostKeyChallenge] = []
        let s = session("exec cat") { challenges.append($0); return true }
        await s.connect(cols: 80, rows: 24)
        #expect(s.state == .connected)
        s.disconnect()
        let challenge = try #require(challenges.first)
        #expect(challenges.count == 1 && challenge.kind == .firstUse)
        #expect(try sshdFingerprints().contains(challenge.fingerprintSHA256))
        #expect(try HostKeyPins.fingerprint(hostname: "127.0.0.1", port: 22) == challenge.fingerprintSHA256)
    }

    @Test func ptyRunsTheCommandWithInputOutputAndResize() async throws {
        let s = session(#"printf 'term=%s\n' "$TERM"; stty size; read line; stty size; echo "got=$line"; echo oops >&2; exec cat"#)
        let out = Transcript()
        s.onOutput = { out.bytes += $0 }
        await s.connect(cols: 80, rows: 24)
        #expect(s.state == .connected)
        #expect(await eventually { out.text.contains("term=xterm-256color") && out.text.contains("24 80") }, "\(out.text)")
        s.resize(cols: 120, rows: 40)
        s.send(Array("hello\r".utf8))
        #expect(await eventually { out.text.contains("40 120") && out.text.contains("got=hello") && out.text.contains("oops") }, "\(out.text)")
        s.send(Array("ping\r".utf8))
        #expect(await eventually { out.text.components(separatedBy: "ping").count > 2 }, "\(out.text)")  // tty echo + cat
        s.disconnect()
        #expect(s.state == .closed)
    }

    @Test func loginShellFindsHerdr() async throws {
        let s = session(#"exec "$SHELL" -lc 'herdr --version'"#)
        let out = Transcript()
        s.onOutput = { out.bytes += $0 }
        await s.connect(cols: 80, rows: 24)
        // An immediate exit reads as a failure (see quickExitFailsWithTheOutput); the tail proves herdr ran.
        #expect(await eventually { s.state.failureMessage?.contains("\nherdr ") == true }, "state: \(s.state)")
        #expect(out.text.hasPrefix("herdr "), "\(out.text)")
    }

    @Test func nonZeroExitFails() async throws {
        let s = session("exit 3")
        await s.connect(cols: 80, rows: 24)
        #expect(await eventually { s.state == .failed("The remote command exited with status 3.") }, "state: \(s.state)")
    }

    @Test func commandNotFoundIsNamed() async throws {
        let s = session("exec herdr-ios-no-such-command")
        await s.connect(cols: 80, rows: 24)
        #expect(await eventually { s.state.failureMessage?.contains("127") == true }, "state: \(s.state)")
        #expect(s.state.failureMessage?.contains("command not found: herdr-ios-no-such-command") == true, "state: \(s.state)")
    }

    /// Windows exits 0 even when `herdr` is not recognized, so any exit right after connecting fails
    /// with the last output; a later clean exit (ctrl+b q detach) is a normal close.
    @Test func quickExitFailsWithTheOutput() async throws {
        let quick = session("echo detached-too-soon")
        await quick.connect(cols: 80, rows: 24)
        #expect(await eventually { quick.state == .failed("The remote command exited right after connecting.\ndetached-too-soon") }, "state: \(quick.state)")
        let later = session("sleep 2.2")
        await later.connect(cols: 80, rows: 24)
        #expect(await eventually(.seconds(15)) { later.state == .closed }, "state: \(later.state)")
    }

    @Test func changedSshdKeyIsRefused() async throws {
        defer { store.forgetHostKey(hostname: "127.0.0.1", port: 22) }
        let stale = "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        try HostKeyPins.pin(stale, hostname: "127.0.0.1", port: 22)
        var prompted = false
        let s = session("true") { _ in prompted = true; return true }
        await s.connect(cols: 80, rows: 24)
        #expect(!prompted)
        guard case .failed(let message) = s.state else { Issue.record("expected refusal, got \(s.state)"); return }
        #expect(message.contains("changed"))
        let rejected = try #require(s.rejectedHostKey)
        #expect(rejected.kind == .changed(previousFingerprint: stale))
        #expect(try sshdFingerprints().contains(rejected.fingerprintSHA256))
    }
}

extension SessionState {
    var failureMessage: String? { if case .failed(let message) = self { message } else { nil } }
}

@MainActor final class Transcript {
    var bytes: [UInt8] = []
    var text: String { String(decoding: bytes, as: UTF8.self) }
}

@MainActor func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if .now > deadline { return false }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return true
}

func run(_ tool: String, _ args: [String], stdin: String? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: tool)
    process.arguments = args
    let out = Pipe(), input = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    if stdin != nil { process.standardInput = input }
    try process.run()
    if let stdin { input.fileHandleForWriting.write(Data(stdin.utf8)); try input.fileHandleForWriting.close() }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// `ssh-keygen -lf -` for one OpenSSH public key line: the reference fingerprint.
func sshKeygenFingerprint(_ line: String) throws -> String {
    String(try run("/usr/bin/ssh-keygen", ["-l", "-E", "sha256", "-f", "-"], stdin: line + "\n").split(separator: " ")[1])
}

/// Every host key fingerprint this Mac's sshd offers, as `ssh-keygen` computes them.
func sshdFingerprints() throws -> Set<String> {
    let lines = try run("/usr/bin/ssh-keyscan", ["-p", "22", "127.0.0.1"]).split(separator: "\n").filter { !$0.hasPrefix("#") }
    return Set(try lines.map { try sshKeygenFingerprint($0.split(separator: " ").dropFirst().joined(separator: " ")) })
}

final class TestSSHServer: Sendable {
    let port: Int
    let fingerprint: String
    private let channel: Channel
    private let auth: RejectAll

    var authAttempts: Int { auth.attempts.withLockedValue { $0 } }

    private init(port: Int, fingerprint: String, channel: Channel, auth: RejectAll) {
        self.port = port
        self.fingerprint = fingerprint
        self.channel = channel
        self.auth = auth
    }

    static func start() async throws -> TestSSHServer {
        let key = Curve25519.Signing.PrivateKey()
        let hostKey = NIOSSHPrivateKey(ed25519Key: key)
        let auth = RejectAll()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    let config = SSHServerConfiguration(hostKeys: [hostKey], userAuthDelegate: auth)
                    try child.pipeline.syncOperations.addHandler(
                        NIOSSHHandler(role: .server(config), allocator: child.allocator, inboundChildChannelInitializer: nil))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let line = "ssh-ed25519 " + DeviceKey.wireBlob(key.publicKey).base64EncodedString()
        return TestSSHServer(port: channel.localAddress!.port!, fingerprint: try sshKeygenFingerprint(line), channel: channel, auth: auth)
    }

    func stop() {
        try? HostKeyPins.forget(hostname: "127.0.0.1", port: port)
        channel.close(promise: nil)
    }
}

final class RejectAll: NIOSSHServerUserAuthenticationDelegate, Sendable {
    let attempts = NIOLockedValueBox(0)
    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }

    func requestReceived(request: NIOSSHUserAuthenticationRequest, responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
        attempts.withLockedValue { $0 += 1 }
        responsePromise.succeed(.failure)
    }
}
