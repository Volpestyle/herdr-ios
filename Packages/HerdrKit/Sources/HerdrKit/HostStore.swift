import Foundation
import Observation
import os

/// Host profiles as JSON in Application Support; passwords in the Keychain.
@MainActor @Observable public final class HostStore {
    public private(set) var hosts: [HostProfile] = []
    @ObservationIgnored private let fileURL: URL

    public static let defaultFileURL = URL.applicationSupportDirectory.appending(path: "Herdr/hosts.json")
    static let passwordService = "com.volpestyle.herdr.password"
    private static let log = Logger(subsystem: "com.volpestyle.herdr", category: "HostStore")

    public init(fileURL: URL = HostStore.defaultFileURL) {
        self.fileURL = fileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            hosts = try JSONDecoder().decode([HostProfile].self, from: data)
        } catch {
            // Keep the unreadable file instead of overwriting it on the next save.
            Self.log.error("hosts.json unreadable, moved aside: \(error)")
            try? FileManager.default.moveItem(at: fileURL, to: fileURL.appendingPathExtension("corrupt"))
        }
    }

    public func upsert(_ host: HostProfile) {
        if let i = hosts.firstIndex(where: { $0.id == host.id }) { hosts[i] = host } else { hosts.append(host) }
        save()
    }

    public func delete(_ id: UUID) {
        hosts.removeAll { $0.id == id }
        setPassword(nil, for: id)
        save()
    }

    /// Stores (or with `nil`, removes) the password fallback for a host.
    public func setPassword(_ password: String?, for id: UUID) {
        do {
            try Keychain.set(password.map { Data($0.utf8) }, service: Self.passwordService, account: id.uuidString)
        } catch {
            Self.log.error("setPassword failed: \(error)")
        }
    }

    public func hasPassword(for id: UUID) -> Bool { password(for: id) != nil }

    /// Drops the pinned host key so the next connect asks again (after a legitimate host rebuild).
    public func forgetHostKey(hostname: String, port: Int) {
        do { try HostKeyPins.forget(hostname: hostname, port: port) } catch { Self.log.error("forgetHostKey failed: \(error)") }
    }

    func password(for id: UUID) -> String? {
        (try? Keychain.read(service: Self.passwordService, account: id.uuidString)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(hosts).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            Self.log.error("hosts.json save failed: \(error)")
        }
    }
}
