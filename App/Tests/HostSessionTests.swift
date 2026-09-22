import HerdrKit
import Testing
import SwiftTerm
import UIKit
@testable import Herdr

@MainActor
struct HostSessionTests {
    /// Windows ConPTY enables SGR mouse and then resets SGR-pixel; clicks must stay SGR.
    @Test func conptyMouseModesKeepSGRClicks() {
        let view = HerdrTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), font: nil)
        let sink = SentBytes()
        view.terminalDelegate = sink
        view.feedHost(Array("\u{1b}[?1000h\u{1b}[?1002h\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1016l".utf8))
        view.sendClick(at: CGPoint(x: 20, y: 20))
        #expect(String(decoding: sink.bytes, as: UTF8.self).hasPrefix("\u{1b}[<0;"))
    }

    /// Background must hold every connect path shut: iOS lays views out for snapshots while
    /// backgrounded, and that layout must not reconnect.
    @Test func backgroundBlocksLayoutReconnect() async {
        let store = HostStore(fileURL: .temporaryDirectory.appending(path: "\(UUID()).json"))
        // Port 9 on loopback refuses fast; only whether a connection object exists matters here.
        let host = HostProfile(name: "x", hostname: "127.0.0.1", port: 9, username: "x")
        store.upsert(host)
        let session = HostSession(hostID: host.id, store: store)
        session.terminalView.frame = CGRect(x: 0, y: 0, width: 400, height: 300)

        session.start()
        let first = session.connection
        #expect(first != nil)
        session.suspend()
        #expect(session.connection == nil)
        session.viewDidLayout()
        #expect(session.connection == nil)
        // Off screen, returning doesn't reattach (herdr would resize that host's panes to this
        // device); opening the host does.
        session.resume()
        #expect(session.connection == nil)
        session.start()
        let second = session.connection
        #expect(second != nil)
        // On screen, returning reattaches.
        let window = UIWindow(frame: session.terminalView.frame)
        window.addSubview(session.terminalView)
        session.suspend()
        session.resume()
        let third = session.connection
        #expect(third != nil && third !== second)
        session.stop()

        // Both connect tasks are still queued; once they run, retired sessions must not move.
        let retired = [first, second, third].compactMap { $0 }
        let states = retired.map(\.state)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(retired.map(\.state) == states)
    }
}

private final class SentBytes: TerminalViewDelegate {
    var bytes: [UInt8] = []
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes += data }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
