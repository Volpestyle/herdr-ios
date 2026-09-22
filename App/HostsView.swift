import HerdrKit
import SwiftUI

/// Sidebar of hosts with the selected host's terminal as detail. Compact width collapses
/// this into a push stack on iPhone; sessions live in `SessionRegistry` either way.
struct HostsView: View {
    @Environment(HostStore.self) private var store
    @Environment(SessionRegistry.self) private var sessions
    @State private var selection: UUID?
    @State private var columns = NavigationSplitViewVisibility.automatic
    @State private var editing: HostProfile?
    @State private var showingDeviceKey = false
    @State private var pairing: PairingRoute?

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $selection) {
                ForEach(store.hosts) { host in
                    NavigationLink(value: host.id) {
                        HostRow(host: host, state: sessions.existing(host.id)?.state)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editing = host }
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(host) }
                    }
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { delete(host) }
                        Button("Edit", systemImage: "pencil") { editing = host }
                    }
                }
            }
            .overlay {
                if store.hosts.isEmpty {
                    ContentUnavailableView {
                        Label("No Hosts", systemImage: "desktopcomputer")
                    } description: {
                        Text("Run herdr-pair on a Mac or PC on your tailnet, then scan its code.")
                    } actions: {
                        Button("Pair a Computer") { pairing = .scan }
                            .buttonStyle(.borderedProminent)
                        Button("Add Manually") { editing = .draft() }
                        Button("Show Device Key") { showingDeviceKey = true }
                    }
                }
            }
            .navigationTitle("Herdr")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Device Key", systemImage: "key") { showingDeviceKey = true }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Add Host", systemImage: "plus") { editing = .draft() }
                    Button("Pair Computer", systemImage: "qrcode.viewfinder") { pairing = .scan }
                }
            }
        } detail: {
            if let id = selection, let host = store.hosts.first(where: { $0.id == id }) {
                TerminalScreen(host: host, session: sessions.session(for: id, store: store))
                    .id(id)
            } else {
                ContentUnavailableView("Select a Host", systemImage: "terminal")
            }
        }
        // A terminal wants every column; the sidebar button brings the host list back.
        .onChange(of: selection) { _, id in
            if id != nil { columns = .detailOnly }
        }
        .sheet(item: $editing) { host in
            HostEditor(host: host, isNew: !store.hosts.contains { $0.id == host.id })
        }
        .sheet(isPresented: $showingDeviceKey) {
            NavigationStack { DeviceKeyView() }
        }
        .sheet(item: $pairing) { route in
            PairingFlow(route: route) { host in selection = host.id }
        }
        // herdr://pair links, from the system Camera or `simctl openurl`.
        .onOpenURL { url in
            guard url.scheme == "herdr", url.host() == "pair" else { return }
            editing = nil
            showingDeviceKey = false
            pairing = .link(url)
        }
    }

    private func delete(_ host: HostProfile) {
        if selection == host.id { selection = nil }
        sessions.remove(host.id)
        store.delete(host.id)
    }
}

private struct HostRow: View {
    let host: HostProfile
    let state: SessionState?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: host.platform == .windows ? "pc" : "laptopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name.isEmpty ? host.hostname : host.name)
                Text("\(host.username)@\(host.hostname)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if state == .connected {
                Circle().fill(.green).frame(width: 8, height: 8)
                    .accessibilityLabel("Connected")
            }
        }
    }
}

extension HostProfile {
    static func draft() -> HostProfile {
        HostProfile(id: UUID(), name: "", hostname: "", port: 22, username: "", platform: .unix,
                    herdrSession: nil, remoteCommand: nil)
    }
}

extension HostPlatform {
    var label: String {
        switch self {
        case .unix: "macOS / Linux"
        case .windows: "Windows"
        }
    }
}
