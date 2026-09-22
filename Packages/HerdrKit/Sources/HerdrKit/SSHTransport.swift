import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
@preconcurrency import NIOSSH

/// The SSH plumbing `TerminalSession` and `Pairing` share: connect with a host-key check and user
/// auth, session channels with backpressure, and output and error formatting.
enum SSHTransport {
    /// TCP, key exchange (host key checked by `validator`), and user auth. With `allowRemote`, a
    /// peer address it rejects ends the connection before any SSH traffic, as
    /// `SessionError.remoteNotAllowed`.
    static func open(
        host: String, port: Int, credentials: Credentials, validator: PinValidator,
        allowRemote: (@Sendable (SocketAddress) -> Bool)? = nil
    ) async throws -> Channel {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let authenticated = loop.makePromise(of: Void.self)
        let refused = NIOLockedValueBox<String?>(nil)
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let config = SSHClientConfiguration(userAuthDelegate: OfferQueue(credentials), serverAuthDelegate: validator)
                    if let allowRemote {
                        try channel.pipeline.syncOperations.addHandler(RemoteAddressGate(allow: allowRemote, refused: refused))
                    }
                    try channel.pipeline.syncOperations.addHandlers(
                        NIOSSHHandler(role: .client(config), allocator: channel.allocator, inboundChildChannelInitializer: nil),
                        AuthWaiter(authenticated))
                }
            }
        let tcp: Channel
        do {
            tcp = try await bootstrap.connect(host: host, port: port).get()
        } catch {
            authenticated.fail(error)  // NIO traps on an unfulfilled promise in debug builds
            throw error
        }
        let timeout = loop.scheduleTask(in: .seconds(20)) { authenticated.fail(ChannelError.connectTimeout(.seconds(20))) }
        do {
            try await authenticated.futureResult.get()
            timeout.cancel()
            return tcp
        } catch {
            tcp.close(promise: nil)
            if let address = refused.withLockedValue({ $0 }) { throw SessionError.remoteNotAllowed(address) }
            throw error
        }
    }

    /// Opens a session channel carrying a `SessionChannelHandler` that completes `ready` after
    /// `replies` accepted requests. `ready` is completed on every path, including a `createChannel`
    /// that fails before the initializer runs (connection gone after auth).
    static func openSessionChannel(
        on connection: Channel, replies: Int, ready: EventLoopPromise<Void>,
        events sink: AsyncStream<SessionEvent>.Continuation
    ) async throws -> Channel {
        try await connection.eventLoop.flatSubmit {
            let created = connection.eventLoop.makePromise(of: Channel.self)
            created.futureResult.whenFailure { ready.fail($0) }
            do {
                let ssh = try connection.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(created, channelType: .session) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        // Backpressure: read only when the MainActor has taken the last chunk, so unread
                        // output waits in the host's SSH window instead of app memory.
                        try child.syncOptions?.setOption(ChannelOptions.autoRead, value: false)
                        try child.pipeline.syncOperations.addHandler(SessionChannelHandler(replies: replies, ready: ready, events: sink))
                    }
                }
            } catch {
                created.fail(error)
            }
            return created.futureResult
        }.get()
    }

    /// The last few readable lines of terminal output, without escape sequences.
    static func lastLines(_ bytes: [UInt8], count: Int = 3) -> String {
        String(decoding: bytes, as: UTF8.self)
            .replacing(#/\x{1B}\[[0-9;]*[Hf]/#, with: "\n")  // cursor moves stand in for line breaks
            .replacing(#/\x{1B}(\[[0-?]*[ -\/]*[@-~]|\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)?|.)/#, with: "")
            .split(whereSeparator: \.isNewline)
            .map { $0.filter { $0.asciiValue.map { $0 >= 0x20 && $0 != 0x7F } ?? true }.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .joined(separator: "\n")
    }

    static func describe(_ error: Error) -> String {
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
    case remoteNotAllowed(String)

    var description: String {
        switch self {
        case let .hostKeyChanged(host, port, presented, pinned):
            "The host key for \(host):\(port) changed (now \(presented), pinned \(pinned)). The connection was refused."
        case .hostKeyNotTrusted: "The host key was not trusted."
        case .invalidSessionName(let problem): "Invalid herdr session name: \(problem)."
        case .authenticationFailed:
            "Authentication failed. Add this device's key to the host's authorized_keys or save a password."
        case .requestRefused: "The host refused the terminal or the command."
        case .remoteNotAllowed(let address): "\(address) is not an allowed address for this connection."
        }
    }
}

/// Accepts only fingerprints in `accepted` and records what the host presented. An empty set
/// always refuses, so credentials never reach an unconfirmed host.
final class PinValidator: NIOSSHClientServerAuthenticationDelegate, Sendable {
    let accepted: Set<String>
    let presented = NIOLockedValueBox<String?>(nil)

    init(accepted: Set<String>) { self.accepted = accepted }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fingerprint = HostKeyPins.fingerprintSHA256(hostKey)
        presented.withLockedValue { $0 = fingerprint }
        if accepted.contains(fingerprint) {
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

/// Sits ahead of `NIOSSHHandler` and withholds `channelActive` (so NIOSSH never starts) when the
/// peer address fails `allow`.
final class RemoteAddressGate: ChannelInboundHandler {
    typealias InboundIn = Any
    private let allow: @Sendable (SocketAddress) -> Bool
    private let refused: NIOLockedValueBox<String?>

    init(allow: @escaping @Sendable (SocketAddress) -> Bool, refused: NIOLockedValueBox<String?>) {
        self.allow = allow
        self.refused = refused
    }

    func channelActive(context: ChannelHandlerContext) {
        if let address = context.remoteAddress, allow(address) { return context.fireChannelActive() }
        let description = context.remoteAddress?.ipAddress ?? "an unknown address"
        refused.withLockedValue { $0 = description }
        context.fireErrorCaught(SessionError.remoteNotAllowed(description))
        context.close(promise: nil)
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

enum SessionEvent: Sendable { case output([UInt8]), exitStatus(Int), error(String), closed }

/// Session-channel handler: forwards stdout/stderr and lifecycle into an ordered stream, and
/// completes `ready` once every request sent with wantReply is accepted.
///
/// The channel runs with autoRead off. Each read burst becomes one `.output` event, and the
/// consumer requests the next read, so at most one burst (at most one SSH window) sits in memory.
final class SessionChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let ready: EventLoopPromise<Void>
    private let events: AsyncStream<SessionEvent>.Continuation
    private var pendingReplies: Int  // one per request sent with wantReply
    private var burst: [UInt8] = []

    init(replies: Int, ready: EventLoopPromise<Void>, events: AsyncStream<SessionEvent>.Continuation) {
        pendingReplies = replies
        self.ready = ready
        self.events = events
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .byteBuffer(let buffer) = data.data, data.type == .channel || data.type == .stdErr else { return }
        burst.append(contentsOf: buffer.readableBytesView)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        if burst.isEmpty {
            context.read()  // nothing for the consumer to take, so it won't ask; keep reading
        } else {
            events.yield(.output(burst))
            burst = []
        }
        context.fireChannelReadComplete()
    }

    func channelActive(context: ChannelHandlerContext) {
        context.read()
        context.fireChannelActive()
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
        if !burst.isEmpty { events.yield(.output(burst)) }
        ready.fail(ChannelError.eof)
        events.yield(.closed)
        events.finish()
        context.fireChannelInactive()
    }
}
