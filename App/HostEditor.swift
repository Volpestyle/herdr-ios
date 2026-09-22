import HerdrKit
import SwiftUI

struct HostEditor: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var host: HostProfile
    let isNew: Bool
    @State private var password = ""
    @State private var forgetPassword = false
    @State private var confirmingForgetKey = false
    @State private var forgotKey = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $host.name, prompt: Text("Studio Mac"))
                    TextField("Hostname", text: $host.hostname, prompt: Text("my-mac or 100.x.y.z"))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $host.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                    TextField("User", text: $host.username, prompt: Text("james"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Platform", selection: $host.platform) {
                        ForEach(HostPlatform.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("Use the host's Tailscale MagicDNS name or its 100.x address.")
                }

                Section {
                    TextField("Session", text: $host.herdrSession.orEmpty, prompt: Text("default"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Command", text: $host.remoteCommand.orEmpty,
                              prompt: Text(HerdrCommand.attach(platform: host.platform,
                                                               session: session.flatMap {
                                                                   HerdrCommand.sessionNameError($0) == nil ? $0 : nil
                                                               })),
                              axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("herdr")
                } footer: {
                    if let sessionProblem {
                        Text("Invalid session: \(sessionProblem).").foregroundStyle(.red)
                    } else {
                        Text("Leave the session empty for herdr's default session. The command overrides how herdr is started on the host.")
                    }
                }

                Section {
                    SecureField("Password", text: $password, prompt: Text(isNew ? "Optional" : "Unchanged"))
                    if !isNew && store.hasPassword(for: host.id) {
                        Toggle("Forget Saved Password", isOn: $forgetPassword)
                    }
                } header: {
                    Text("Password")
                } footer: {
                    Text("This device's key is tried first. A password is only a fallback and is kept in the Keychain.")
                }
                if !isNew {
                    Section {
                        Button(forgotKey ? "Host Key Forgotten" : "Forget Host Key", role: .destructive) {
                            confirmingForgetKey = true
                        }
                        .disabled(forgotKey)
                        .confirmationDialog("Forget the pinned host key?", isPresented: $confirmingForgetKey,
                                            titleVisibility: .visible) {
                            Button("Forget Host Key", role: .destructive) {
                                // The pin belongs to the saved address, not unsaved edits in this form.
                                let saved = store.hosts.first { $0.id == host.id } ?? host
                                store.forgetHostKey(hostname: saved.hostname, port: saved.port)
                                forgotKey = true
                            }
                        } message: {
                            Text("Only do this if you know the host was reinstalled or its SSH keys were regenerated. The next connection asks you to trust its new key.")
                        }
                    } footer: {
                        Text("Herdr refuses hosts whose key changed since it was first trusted.")
                    }
                }
            }
            .navigationTitle(isNew ? "Add Host" : "Edit Host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", role: .confirm, action: save)
                        .disabled(trimmed(host.hostname).isEmpty || trimmed(host.username).isEmpty
                                  || !(1...65535).contains(host.port) || sessionProblem != nil)
                }
            }
        }
    }

    private func save() {
        host.name = trimmed(host.name)
        host.hostname = trimmed(host.hostname)
        host.username = trimmed(host.username)
        host.herdrSession = session
        host.remoteCommand = host.remoteCommand.map(trimmed).flatMap { $0.isEmpty ? nil : $0 }
        store.upsert(host)
        if !password.isEmpty {
            store.setPassword(password, for: host.id)
        } else if forgetPassword {
            store.setPassword(nil, for: host.id)
        }
        dismiss()
    }

    private var session: String? { host.herdrSession.map(trimmed).flatMap { $0.isEmpty ? nil : $0 } }

    /// herdr's own session-name rule; moot when an explicit command replaces the attach command.
    private var sessionProblem: String? {
        guard let session, host.remoteCommand.map(trimmed)?.isEmpty ?? true else { return nil }
        return HerdrCommand.sessionNameError(session)
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension Binding where Value == String? {
    /// Edits an optional string as plain text; empty means nil.
    var orEmpty: Binding<String> {
        Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}
