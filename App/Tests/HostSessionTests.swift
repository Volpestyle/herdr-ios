import HerdrKit
import Testing
import UIKit
@testable import Herdr

@MainActor
struct HostSessionTests {
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
        session.resume()
        let second = session.connection
        #expect(second != nil)
        session.stop()

        // Both connect tasks are still queued; once they run, retired sessions must not move.
        let retired = [first, second].compactMap { $0 }
        let states = retired.map(\.state)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(retired.map(\.state) == states)
    }
}
