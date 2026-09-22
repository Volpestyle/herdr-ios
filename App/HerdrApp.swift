import HerdrKit
import SwiftUI

@main
struct HerdrApp: App {
    @State private var store = HostStore()
    @State private var sessions = SessionRegistry()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HostsView()
                .environment(store)
                .environment(sessions)
        }
        // iOS drops sockets once the app is suspended, so close cleanly on the way out
        // and reattach on return; herdr keeps every pane running on the host meanwhile.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: sessions.suspendAll()
            case .active: sessions.resumeAll()
            default: break
            }
        }
    }
}
