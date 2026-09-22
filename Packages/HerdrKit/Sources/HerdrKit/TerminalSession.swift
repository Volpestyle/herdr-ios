import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
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
            state = .failed(Self.describe(error))
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
        let host = profile.hostname, port = profile.port
        let credentials = Credentials(
            username: profile.username, key: try DeviceKey.privateKey(), password: store.password(for: profile.id))
        while true {
            let pinned = try HostKeyPins.fingerprint(hostname: host, port: port)
            let validator = PinValidator(pinned: pinned)
            do {
                return try await Self.open(host: host, port: port, credentials: credentials, validator: validator)
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
                try HostKeyPins.pin(presented, hostname: host, port: port)
                // Reconnect; the next handshake must present exactly this key.
            }
        }
    }

    private nonisolated static func open(
        host: String, port: Int, credentials: Credentials, validator: PinValidator
    ) async throws -> Channel {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = loop.makePromise(of: Void.self)
        let tcp = try await ClientBootstrap(group: loop)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let config = SSHClientConfiguration(userAuthDelegate: OfferQueue(credentials), serverAuthDelegate: validator)
                    try channel.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        AuthWaiter(authenticated))
                }
            }
            .connect(host: host, port: port).get()
        let timeout = loop.scheduleTask(in: .seconds(20)) { authenticated.fail(ChannelError.connectTimeout(.seconds(20))) }
        do {
            try await authenticated.futureResult.get()
            timeout.cancel()
            return tcp
        } catch {
            tcp.close(promise: nil)
            throw error
        }
    }

    /// Opens a session channel, requests the PTY, and execs the attach command.
    private func openPTY(on connection: Channel, command: String, cols: Int, rows: Int, generation: Int) async throws {
        let (events, sink) = AsyncStream<PTYEvent>.makeStream()
        let ready = connection.eventLoop.makePromise(of: Void.self)
        let pty = try await connection.eventLoop.flatSubmit {
            let created = connection.eventLoop.makePromise(of: Channel.self)
            do {
                let ssh = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(created, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(PTYHandler(ready: ready, events: sink))
                    }
                }
            } catch {
                created.fail(error)
            }
            return created.futureResult
        }.get()
        guard isCurrent(generation) else { throw CancellationError() }
        self.pty = pty
        Task { [weak self] in
            for await event in events { self?.handle(event, generation: generation) }
        }
        try await pty.triggerUserOutboundEvent(SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: max(cols, 1), terminalRowHeight: max(rows, 1),
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([.init(rawValue: 42): 1]))).get()  // IUTF8 (RFC 8160)
        try await pty.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).get()
        try await ready.futureResult.get()
    }

    private func handle(_ event: PTYEvent, generation: Int) {
        guard isCurrent(generation) else { return }
        switch event {
        case .output(let bytes):
            recentOutput = Array((recentOutput + bytes).suffix(4096))
            onOutput?(bytes)
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
                let tail = Self.lastLines(recentOutput)
                state = .failed(tail.isEmpty ? reason : reason + "\n" + tail)
            } else {
                state = .closed
            }
        }
    }

    /// The last few readable lines of terminal output, without escape sequences.
    nonisolated static func lastLines(_ bytes: [UInt8], count: Int = 3) -> String {
        String(decoding: bytes, as: UTF8.self)
            .replacing(#/\x{1B}\[[0-9;]*[Hf]/#, with: "\n")  // cursor moves stand in for line breaks
            .replacing(#/\x{1B}(\[[0-?]*[ -\/]*[@-~]|\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)?|.)/#, with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.filter { $0.asciiValue.map { $0 >= 0x20 && $0 != 0x7F } ?? true }.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: "\n")
    }

    private nonisolated static func describe(_ error: Error) -> String {
        if let error = error as? SessionError { return error.description }
        if error is NIOConnectionError || error is IOError || error is ChannelError {
            return "Could not reach the host: \(error)"
        }
        return "\(error)"
    }
}

enum SessionError: Error, CustomStringConvertible {
    case hostKeyChanged(host: String, port: Int, presented: String, pinned: String)
    case hostKeyNotTrusted
    case invalidSessionName(String)
    case authenticationFailed
    case requestRefused

    var description: String {
        switch self {
        case let .hostKeyChanged(host, port, presented, pinned):
            "The host key for \(host):\(port) changed (now \(presented), pinned \(pinned)). The connection was refused."
        case .hostKeyNotTrusted: "The host key was not trusted."
        case .invalidSessionName(let problem): "Invalid herdr session name: \(problem)."
        case .authenticationFailed:
            "Authentication failed. Add this device's key to the host's authorized_keys or save a password."
        case .requestRefused: "The host refused the terminal or the command."
        }
    }
}

/// Accepts only the pinned fingerprint and records what the host presented.
/// With no pin it always refuses, so credentials never reach an unconfirmed host.
final class PinValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let pinned: String?
    let presented = NIOLockedValueBox<String?>(nil)

    init(pinned: String?) { self.pinned = pinned }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = HostKeyPins.fingerprintSHA256(hostKey)
        presented.withLockedValue { $0 = fingerprint }
        if let pinned, pinned == fingerprint {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(SessionError.hostKeyNotTrusted)
        }
    }
}

struct Credentials: Sendable {
    let username: String
    let key: Curve25519.Signing.PrivateKey
    let password: String?
}

/// Offers the device key, then the saved password, skipping methods the server doesn't allow.
final class OfferQueue: NIOSSHClientUserAuthenticationDelegate {
    private var offers: [NIOSSHUserAuthenticationOffer]

    init(_ credentials: Credentials) {
        let user = credentials.username
        offers = [.init(username: user, serviceName: "", offer: .privateKey(.init(privateKey: .init(ed25519Key: credentials.key))))]
        if let password = credentials.password {
            offers.append(.init(username: user, serviceName: "", offer: .password(.init(password: password))))
        }
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while !offers.isEmpty {
            let offer = offers.removeFirst()
            switch offer.offer {
            case .privateKey where availableMethods.contains(.publicKey),
                 .password where availableMethods.contains(.password):
                return nextChallengePromise.succeed(offer)
            default: continue
            }
        }
        nextChallengePromise.fail(SessionError.authenticationFailed)
    }
}

/// Completes once user auth succeeds; fails on the first error (host key refusal, auth failure) or EOF.
final class AuthWaiter: ChannelInboundHandler {
    typealias InboundIn = Any
    private let authenticated: EventLoopPromise<Void>

    init(_ authenticated: EventLoopPromise<Void>) { self.authenticated = authenticated }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent { authenticated.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        authenticated.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        authenticated.fail(ChannelError.eof)
        context.fireChannelInactive()
    }
}

enum PTYEvent: Sendable { case output([UInt8]), exitStatus(Int), error(String), closed }

/// Session-channel handler: forwards stdout/stderr and lifecycle into an ordered stream, and
/// completes `ready` once the PTY and exec requests are both accepted.
final class PTYHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let ready: EventLoopPromise<Void>
    private let events: AsyncStream<PTYEvent>.Continuation
    private var pendingReplies = 2  // pty-req, exec

    init(ready: EventLoopPromise<Void>, events: AsyncStream<PTYEvent>.Continuation) {
        self.ready = ready
        self.events = events
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = data.data, data.type == .channel || data.type == .stdErr else { return }
        events.yield(.output(Array(buffer.readableBytesView)))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            pendingReplies -= 1
            if pendingReplies == 0 { ready.succeed(()) }
        case is ChannelFailureEvent:
            events.yield(.error(SessionError.requestRefused.description))
            ready.fail(SessionError.requestRefused)
            context.close(promise: nil)
        case let status as SSHChannelRequestEvent.ExitStatus:
            events.yield(.exitStatus(status.exitStatus))
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        events.yield(.error("\(error)"))
        ready.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        ready.fail(ChannelError.eof)
        events.yield(.closed)
        events.finish()
        context.fireChannelInactive()
    }
}
