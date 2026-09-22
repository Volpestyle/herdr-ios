import HerdrKit
import Observation
import SwiftTerm
import UIKit

/// Every host's session, kept alive across sidebar switches and navigation pops.
@MainActor @Observable
final class SessionRegistry {
    // Created lazily from view bodies, so nothing observes the dictionary itself.
    @ObservationIgnored private var sessions: [UUID: HostSession] = [:]

    func session(for id: UUID, store: HostStore) -> HostSession {
        if let session = sessions[id] { return session }
        let session = HostSession(hostID: id, store: store)
        sessions[id] = session
        return session
    }

    func existing(_ id: UUID) -> HostSession? { sessions[id] }

    func remove(_ id: UUID) { sessions.removeValue(forKey: id)?.stop() }

    func suspendAll() { sessions.values.forEach { $0.suspend() } }

    func resumeAll() { sessions.values.forEach { $0.resume() } }
}

struct HostKeyPrompt: Identifiable {
    let id = UUID()
    let challenge: HostKeyChallenge
}

/// One host's terminal: a SwiftTerm view that outlives individual SSH connections,
/// plus the current HerdrKit `TerminalSession` feeding it.
@MainActor @Observable
final class HostSession {
    let hostID: UUID
    @ObservationIgnored let terminalView: HerdrTerminalView
    @ObservationIgnored private let store: HostStore

    private(set) var connection: TerminalSession?
    /// True after a background return or a manual retry, so the overlay says "Reconnecting".
    private(set) var isReconnect = false
    var hostKeyPrompt: HostKeyPrompt?

    @ObservationIgnored private var hostKeyReply: CheckedContinuation<Bool, Never>?
    /// Bumped whenever the current connection is dropped, so a stale one can't raise a trust prompt.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var wantsConnection = false
    /// Set from background until active again; no connect path may run while it is.
    @ObservationIgnored private var inBackground = false

    var state: SessionState { connection?.state ?? .idle }

    init(hostID: UUID, store: HostStore) {
        self.hostID = hostID
        self.store = store
        terminalView = HerdrTerminalView(frame: .zero, font: TerminalFont.font())
        terminalView.terminalDelegate = self
    }

    /// The terminal screen appeared: connect as soon as the view has a real grid.
    func start() {
        wantsConnection = true
        connectIfReady()
    }

    func reconnect() {
        dropConnection()
        isReconnect = true
        wantsConnection = true
        connectIfReady()
    }

    func stop() {
        wantsConnection = false
        dropConnection()
    }

    /// Always drops the connection: without keepalives a socket iOS killed can still read
    /// `.connected`, so returning to the foreground must reattach rather than trust it.
    func suspend() {
        inBackground = true
        dropConnection()
    }

    func resume() {
        guard inBackground else { return }
        inBackground = false
        if wantsConnection { isReconnect = true }
        connectIfReady()
    }

    /// The hosting view laid out; the first layout is what unblocks the initial connect.
    func viewDidLayout() { connectIfReady() }

    func answerHostKey(_ trust: Bool) {
        hostKeyPrompt = nil
        hostKeyReply?.resume(returning: trust)
        hostKeyReply = nil
    }

    /// Disconnects and refuses any trust prompt it left open: an approval only counts for the
    /// connection that asked, and that connection is gone.
    private func dropConnection() {
        generation += 1
        answerHostKey(false)
        connection?.disconnect()
        connection = nil
    }

    private func connectIfReady() {
        // A laid-out view keeps its grid after leaving the window, so hidden sessions reattach too.
        guard wantsConnection, !inBackground, connection == nil, terminalView.bounds.width > 0,
              let profile = store.hosts.first(where: { $0.id == hostID })
        else { return }

        let terminal = terminalView.getTerminal()
        // A fresh attach redraws everything; drop modes left over from the previous connection.
        terminal.resetToInitialState()
        let attempt = generation
        let session = TerminalSession(profile: profile, store: store) { [weak self] challenge in
            guard let self, self.generation == attempt else { return false }
            return await self.confirm(challenge)
        }
        session.onOutput = { [weak self] bytes in
            self?.terminalView.feed(byteArray: bytes[...])
        }
        connection = session
        let cols = terminal.cols, rows = terminal.rows
        Task { [weak self] in
            // start/suspend/stop can all run before this task does; only the current one connects.
            guard let self, self.connection === session, !self.inBackground else { return }
            await session.connect(cols: cols, rows: rows)
            guard self.connection === session else { return }
            // HerdrKit refuses a changed key outright; show the mismatch rather than just an error.
            if let rejected = session.rejectedHostKey { self.hostKeyPrompt = HostKeyPrompt(challenge: rejected) }
            guard session.state == .connected else { return }
            // The keyboard or a rotation can resize the grid while the PTY was being set up.
            let now = self.terminalView.getTerminal()
            if now.cols != cols || now.rows != rows { session.resize(cols: now.cols, rows: now.rows) }
            if self.terminalView.window != nil { _ = self.terminalView.becomeFirstResponder() }
        }
    }

    private func confirm(_ challenge: HostKeyChallenge) async -> Bool {
        hostKeyReply?.resume(returning: false)
        return await withCheckedContinuation { reply in
            hostKeyReply = reply
            hostKeyPrompt = HostKeyPrompt(challenge: challenge)
        }
    }
}

extension HostSession: @preconcurrency TerminalViewDelegate {
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        connection?.send(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        connection?.resize(cols: newCols, rows: newRows)
    }

    // herdr copies selections with OSC 52.
    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func bell(source: TerminalView) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
