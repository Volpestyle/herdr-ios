import HerdrKit
import SwiftUI
import VisionKit

/// How a pairing starts: the in-app scanner, or a `herdr://pair` link the system Camera opened.
enum PairingRoute: Identifiable {
    case scan
    case link(URL)

    var id: String {
        switch self {
        case .scan: "scan"
        case .link(let url): url.absoluteString
        }
    }
}

/// Scan (when needed), review the computer, then enroll this device and hand back the saved host.
struct PairingFlow: View {
    let route: PairingRoute
    let onPaired: (HostProfile) -> Void
    @State private var scanned: URL?

    var body: some View {
        NavigationStack {
            if let url = scanned ?? route.url {
                PairingReview(url: url, onPaired: onPaired)
            } else {
                ScanComputer { scanned = $0 }
            }
        }
    }
}

private extension PairingRoute {
    var url: URL? {
        if case .link(let url) = self { url } else { nil }
    }
}

private struct ScanComputer: View {
    let onCode: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                QRScanner(onCode: onCode)
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        Text("Point the camera at the code from herdr-pair on your computer.")
                            .font(.callout)
                            .padding()
                            .glassEffect(in: .rect(cornerRadius: 16))
                            .padding()
                    }
            } else {
                ContentUnavailableView {
                    Label("Camera Unavailable", systemImage: "camera")
                } description: {
                    Text("Scan the code from herdr-pair with the Camera app instead. It opens Herdr. You can also add the computer by hand.")
                }
            }
        }
        .navigationTitle("Scan Computer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { dismiss() }
            }
        }
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (URL) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (URL) -> Void
        private var delivered = false

        init(onCode: @escaping (URL) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for case .barcode(let code) in added {
                // Any other QR code is ignored; only herdr's pairing links start a pairing.
                guard let text = code.payloadStringValue, let url = URL(string: text),
                      url.scheme == "herdr", url.host() == "pair" else { continue }
                delivered = true
                scanner.stopScanning()
                onCode(url)
                return
            }
        }
    }
}

/// Shows who the code says the computer is, then pairs on the user's tap.
private struct PairingReview: View {
    @Environment(HostStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onPaired: (HostProfile) -> Void
    @State private var payload: Result<PairingPayload, Error>
    @State private var phase = Phase.review
    @State private var task: Task<Void, Never>?

    enum Phase: Equatable {
        case review, connecting, waiting, failed(String)
    }

    init(url: URL, onPaired: @escaping (HostProfile) -> Void) {
        self.onPaired = onPaired
        _payload = State(initialValue: Result { try PairingPayload(url: url, now: .now) })
    }

    var body: some View {
        Group {
            switch payload {
            case .failure(let error):
                ContentUnavailableView {
                    Label("Can't Use This Code", systemImage: "qrcode")
                } description: {
                    Text(PairingMessage.invalidCode(error))
                }
            case .success(let payload):
                details(payload)
            }
        }
        .navigationTitle("Pair Computer")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) {
                    task?.cancel()
                    dismiss()
                }
            }
        }
        .interactiveDismissDisabled(phase == .connecting || phase == .waiting)
        .onDisappear { task?.cancel() }
    }

    private func details(_ payload: PairingPayload) -> some View {
        List {
            Section {
                LabeledContent("Computer", value: payload.name)
                LabeledContent("Account", value: payload.username)
                LabeledContent("Address", value: payload.hosts.first ?? "")
                LabeledContent("Platform", value: payload.platform.label)
                LabeledContent("herdr Session", value: payload.session ?? "default")
            }
            Section {
                ForEach(payload.fingerprints, id: \.self) { fingerprint in
                    Text(fingerprint)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
            } header: {
                Text("Host Key")
            } footer: {
                Text("Herdr only connects if the computer presents one of these keys, so there's nothing to compare by hand.")
            }
            Section {
                switch phase {
                case .review:
                    Button {
                        pair(payload)
                    } label: {
                        Text("Pair").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                case .connecting:
                    progress("Connecting to \(payload.name)…")
                case .waiting:
                    progress("Waiting for approval on \(payload.name)…")
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } footer: {
                if phase == .waiting {
                    Text("Approve this device at the herdr-pair prompt on \(payload.name).")
                }
            }
            .listRowBackground(phase == .review ? Color.clear : nil)
            .listRowInsets(phase == .review ? EdgeInsets() : nil)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(text)
        }
    }

    private func pair(_ payload: PairingPayload) {
        phase = .connecting
        task = Task {
            do throws(PairingError) {
                let paired = try await Pairing.enroll(payload: payload, deviceName: UIDevice.current.name) { step in
                    if case .waitingForApproval = step { phase = .waiting } else { phase = .connecting }
                }
                var host = paired
                // Pairing the same account again updates that host (with the computer's current
                // name) instead of adding a twin.
                let twin = store.hosts.first { (saved: HostProfile) -> Bool in
                    saved.hostname == paired.hostname && saved.port == paired.port && saved.username == paired.username
                }
                if let existing = twin {
                    host.id = existing.id
                }
                store.upsert(host)
                onPaired(host)
                dismiss()
            } catch .cancelled {
            } catch {
                phase = .failed(PairingMessage.failed(error, computer: payload.name))
            }
        }
    }
}

/// What the user reads when a code or a pairing fails. Every message says what to do next.
enum PairingMessage {
    static func invalidCode(_ error: Error) -> String { error.localizedDescription }

    /// HerdrKit's descriptions, with the computer's name where the user decides what to do next.
    static func failed(_ error: PairingError, computer: String) -> String {
        switch error {
        case .denied: "\(computer) declined this device. Nothing was added."
        case .expired, .linkExpired: "This pairing code expired before it was approved. Run herdr-pair again on \(computer)."
        case let .conflictingPin(hostname, port):
            "This device already trusts a different host key for \(hostname):\(port), and pairing never replaces one. Only if \(computer) was reinstalled, use Forget Host Key in Edit Host, then pair again."
        default: error.localizedDescription
        }
    }
}
