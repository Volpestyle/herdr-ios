import Darwin
import Foundation

/// Validated v1 pairing invitation. The seed is temporary SSH authentication material;
/// neither this value nor the original URL should be logged or persisted.
public struct PairingPayload: Sendable {
    public let id: String
    public let name: String
    public let username: String
    public let platform: HostPlatform
    public let hosts: [String]
    public let port: Int
    public let fingerprints: [String]
    public let privateKeySeed: Data
    public let expiresAt: Date
    public let session: String?

    public init(url: URL, now: Date = .now) throws {
        guard url.absoluteString.utf8.count <= 8192,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "herdr", parts.host?.lowercased() == "pair",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.fragment == nil else {
            throw PairingPayloadError.invalidURL
        }
        let known: Set<String> = ["v", "id", "n", "u", "os", "h", "p", "fp", "k", "x", "s"]
        var fields: [String: String] = [:]
        for item in parts.queryItems ?? [] where known.contains(item.name) {
            guard fields[item.name] == nil else { throw PairingPayloadError.duplicateField(item.name) }
            guard let value = item.value else { throw PairingPayloadError.invalidField(item.name) }
            fields[item.name] = value
        }
        func required(_ key: String) throws -> String {
            guard let value = fields[key] else { throw PairingPayloadError.missingField(key) }
            return value
        }
        guard try required("v") == "1" else { throw PairingPayloadError.unsupportedVersion }
        id = try required("id")
        guard Self.base64URL(id, bytes: 16) != nil else { throw PairingPayloadError.invalidField("id") }
        name = try required("n")
        guard name.count <= 64 else { throw PairingPayloadError.invalidField("n") }
        username = try required("u")
        guard !username.isEmpty, username.count <= 64,
              username.rangeOfCharacter(from: .controlCharacters.union(.whitespacesAndNewlines)) == nil else {
            throw PairingPayloadError.invalidField("u")
        }
        guard let platform = HostPlatform(rawValue: try required("os")) else {
            throw PairingPayloadError.invalidField("os")
        }
        self.platform = platform
        let hosts = try required("h").components(separatedBy: ",").map(HostKeyPins.canonical)
        guard (1...4).contains(hosts.count), hosts.allSatisfy(Self.isAllowedHost) else {
            throw PairingPayloadError.invalidField("h")
        }
        self.hosts = hosts
        let portText = try required("p")
        guard Self.isDecimal(portText), let port = Int(portText), (1...65535).contains(port) else {
            throw PairingPayloadError.invalidField("p")
        }
        self.port = port
        fingerprints = try required("fp").components(separatedBy: ",")
        guard (1...3).contains(fingerprints.count), fingerprints.allSatisfy(Self.isFingerprint) else {
            throw PairingPayloadError.invalidField("fp")
        }
        guard let seed = Self.base64URL(try required("k"), bytes: 32) else {
            throw PairingPayloadError.invalidField("k")
        }
        privateKeySeed = seed
        let expiryText = try required("x")
        guard Self.isDecimal(expiryText), let seconds = Int64(expiryText) else {
            throw PairingPayloadError.invalidField("x")
        }
        expiresAt = Date(timeIntervalSince1970: TimeInterval(seconds))
        let remaining = expiresAt.timeIntervalSince(now)
        guard remaining > 0 else { throw PairingPayloadError.expired }
        guard remaining <= 15 * 60 else { throw PairingPayloadError.invalidField("x") }
        session = fields["s"]
        if let session, HerdrCommand.sessionNameError(session) != nil {
            throw PairingPayloadError.invalidField("s")
        }
    }

    private static func isDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func base64URL(_ value: String, bytes: Int) -> Data? {
        let standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard + padding), data.count == bytes else { return nil }
        // Round-trip rejects padding, the wrong alphabet, and noncanonical unused bits.
        let canonical = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return canonical == value ? data : nil
    }

    private static func isFingerprint(_ value: String) -> Bool {
        guard value.hasPrefix("SHA256:") else { return false }
        let digest = String(value.dropFirst(7))
        guard digest.utf8.count == 43, let data = Data(base64Encoded: digest + "="), data.count == 32 else {
            return false
        }
        return data.base64EncodedString() == digest + "="
    }

    private static func isAllowedHost(_ host: String) -> Bool {
        if host.contains(":") {
            // Darwin's inet_pton also accepts zone suffixes; QR hosts are bare addresses.
            guard host.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || $0 == 58 }) else {
                return false
            }
            var address = in6_addr()
            guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return false }
            return withUnsafeBytes(of: address) { $0.prefix(6).elementsEqual([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]) }
        }
        // Reject abbreviated, octal, and integer IPv4 spellings that a resolver could
        // otherwise treat as an IP despite looking like a DNS label.
        var address = in_addr()
        if host.withCString({ inet_aton($0, &address) }) == 1 {
            let pieces = host.components(separatedBy: ".")
            guard pieces.count == 4 else { return false }
            let octets = pieces.compactMap { UInt8($0) }
            guard octets.count == 4,
                  zip(pieces, octets).allSatisfy({ $0.0 == String($0.1) }) else { return false }
            return octets[0] == 100 && (64...127).contains(octets[1])
        }
        guard host.utf8.count <= 253 else { return false }
        let labels = host.components(separatedBy: ".")
        guard labels.allSatisfy(isDNSLabel) else { return false }
        return labels.count == 1 || (labels.count >= 3 && host.hasSuffix(".ts.net"))
    }

    private static func isDNSLabel(_ label: String) -> Bool {
        func alphanumeric(_ byte: UInt8) -> Bool { (97...122).contains(byte) || (48...57).contains(byte) }
        guard (1...63).contains(label.utf8.count),
              let first = label.utf8.first, let last = label.utf8.last,
              alphanumeric(first), alphanumeric(last) else { return false }
        return label.utf8.allSatisfy { alphanumeric($0) || $0 == 45 }
    }
}

/// Diagnostics name the malformed field, never its value (which may contain a credential).
public enum PairingPayloadError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL
    case unsupportedVersion
    case missingField(String)
    case duplicateField(String)
    case invalidField(String)
    case expired

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "This is not a Herdr pairing code."
        case .unsupportedVersion: "This pairing code needs a different version of Herdr."
        case .missingField: "This pairing code is incomplete. Generate a new code on the computer."
        case .duplicateField, .invalidField: "This pairing code is invalid. Generate a new code on the computer."
        case .expired: "This pairing code has expired. Generate a new code on the computer."
        }
    }
}
