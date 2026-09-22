import HerdrKit
import SwiftUI

/// This device's SSH public key, for pasting into each host's authorized_keys.
struct DeviceKeyView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key: Result<String, Error>?
    @State private var copied = false

    var body: some View {
        List {
            switch key {
            case .success(let key):
                Section {
                    Text(key)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } footer: {
                    Text("Append this line to ~/.ssh/authorized_keys on each Mac, or to the matching authorized_keys file on Windows. The README covers both.")
                }
                Section {
                    Button(copied ? "Copied" : "Copy Key", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = key
                        copied = true
                    }
                    ShareLink(item: key) { Label("Share Key", systemImage: "square.and.arrow.up") }
                }
            case .failure(let error):
                ContentUnavailableView("No Device Key", systemImage: "key.slash",
                                       description: Text(error.localizedDescription))
            case nil:
                ProgressView()
            }
        }
        .navigationTitle("This Device Key")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", role: .close) { dismiss() }
            }
        }
        .task { key = Result { try DeviceKey.publicKeyOpenSSH() } }
    }
}
