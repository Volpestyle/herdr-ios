import HerdrKit
import SwiftUI

struct TerminalScreen: View {
    let host: HostProfile
    @Bindable var session: HostSession

    var body: some View {
        TerminalContainer(session: session)
            .accessibilityIdentifier("terminal")
            .background(Color.black.ignoresSafeArea())
            .overlay { StatusOverlay(session: session) }
            .navigationTitle(host.name.isEmpty ? host.hostname : host.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Keyboard", systemImage: "keyboard") {
                        let terminal = session.terminalView
                        if terminal.isFirstResponder { terminal.hideKeyboard() } else { terminal.showKeyboard() }
                    }
                    Button("Reconnect", systemImage: "arrow.clockwise") { session.reconnect() }
                }
            }
            .sheet(item: $session.hostKeyPrompt, onDismiss: { session.answerHostKey(false) }) { prompt in
                HostKeySheet(challenge: prompt.challenge) { session.answerHostKey($0) }
            }
            .onAppear { session.start() }
    }
}

private struct StatusOverlay: View {
    let session: HostSession

    var body: some View {
        switch session.state {
        case .connected:
            EmptyView()
        case .idle, .connecting:
            card {
                ProgressView().controlSize(.large)
                Text(session.isReconnect ? "Reconnecting…" : "Connecting…").font(.headline)
            }
        case .failed(let message):
            card {
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
                Text("Couldn't Connect").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { session.reconnect() }.buttonStyle(.borderedProminent)
            }
        case .closed:
            card {
                Image(systemName: "powerplug").font(.largeTitle).foregroundStyle(.secondary)
                Text("Session Ended").font(.headline)
                Text("herdr keeps running on the host.").font(.callout).foregroundStyle(.secondary)
                Button("Reattach") { session.reconnect() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(24)
            .frame(maxWidth: 340)
            .glassEffect(in: .rect(cornerRadius: 24))
            .padding()
    }
}

private struct HostKeySheet: View {
    let challenge: HostKeyChallenge
    let answer: (Bool) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Host", value: "\(challenge.hostname):\(challenge.port)")
                    LabeledContent("SHA256") {
                        Text(challenge.fingerprintSHA256)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    if case .changed(let previous) = challenge.kind {
                        LabeledContent("Pinned") {
                            Text(previous)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                } footer: {
                    if case .changed = challenge.kind {
                        Text("This host's key doesn't match the one pinned on first connection, so Herdr refuses to connect. If you know the host was reinstalled, use Forget Host Key in Edit Host, then reconnect.")
                    } else {
                        Text("First connection to this host. Check the fingerprint on the host with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, then trust it.")
                    }
                }
            }
            .navigationTitle(isChanged ? "Host Key Changed" : "Trust This Host?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isChanged {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close", role: .close) { answer(false) }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { answer(false) }
                    }
                    // Not the confirmation slot: that is the default action, and a reflexive Return on
                    // a hardware keyboard must never trust an unverified key.
                    ToolbarItem(placement: .primaryAction) {
                        Button("Trust") { answer(true) }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var isChanged: Bool {
        if case .changed = challenge.kind { true } else { false }
    }
}
