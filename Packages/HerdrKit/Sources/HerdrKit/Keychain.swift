import CryptoKit
import Foundation
import NIOSSH
import Security

/// Generic-password items, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
/// iOS always uses the data-protection keychain. On macOS (tests only) this falls back to the
/// login keychain, because the data-protection keychain needs a signed, entitled binary.
enum Keychain {
    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")" }
    }

    static func read(service: String, account: String) throws -> Data? {
        var query = item(service, account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return result as? Data
    }

    /// Adds the item. Returns `false` (and changes nothing) if it already exists.
    @discardableResult
    static func add(_ data: Data, service: String, account: String) throws -> Bool {
        var query = item(service, account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw Failure(status: status) }
        return true
    }

    static func delete(service: String, account: String) throws {
        let status = SecItemDelete(item(service, account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    static func set(_ data: Data?, service: String, account: String) throws {
        try delete(service: service, account: account)
        if let data { try add(data, service: service, account: account) }
    }

    private static func item(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// This device's SSH identity: one Ed25519 key, created on first use, never leaves the Keychain.
public enum DeviceKey {
    static let service = "com.volpestyle.herdr.device-key"
    static let account = "ed25519"

    /// `ssh-ed25519 AAAA… herdr-ios`, ready for a host's `authorized_keys`.
    public static func publicKeyOpenSSH() throws -> String {
        "ssh-ed25519 \(wireBlob(try privateKey().publicKey).base64EncodedString()) herdr-ios"
    }

    static func privateKey() throws -> Curve25519.Signing.PrivateKey {
        if let raw = try Keychain.read(service: service, account: account) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.Signing.PrivateKey()
        if try Keychain.add(key.rawRepresentation, service: service, account: account) { return key }
        // Lost a creation race: use the key that won.
        guard let raw = try Keychain.read(service: service, account: account) else { throw Keychain.Failure(status: errSecItemNotFound) }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }

    /// RFC 8709 public key blob: string "ssh-ed25519", string key.
    static func wireBlob(_ key: Curve25519.Signing.PublicKey) -> Data {
        Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data([0, 0, 0, 32]) + key.rawRepresentation
    }
}

/// TOFU pins, one SHA256 fingerprint per `hostname:port`, in the Keychain.
enum HostKeyPins {
    static let service = "com.volpestyle.herdr.host-key"

    static func fingerprint(hostname: String, port: Int) throws -> String? {
        try Keychain.read(service: service, account: account(hostname, port)).map { String(decoding: $0, as: UTF8.self) }
    }

    static func pin(_ fingerprint: String, hostname: String, port: Int) throws {
        try Keychain.set(Data(fingerprint.utf8), service: service, account: account(hostname, port))
    }

    static func forget(hostname: String, port: Int) throws {
        try Keychain.delete(service: service, account: account(hostname, port))
    }

    /// OpenSSH-style `SHA256:<unpadded base64>` of the key's wire blob.
    static func fingerprintSHA256(_ key: NIOSSHPublicKey) -> String {
        let base64 = String(openSSHPublicKey: key).split(separator: " ")[1]
        return fingerprintSHA256(blob: Data(base64Encoded: String(base64)) ?? Data())
    }

    static func fingerprintSHA256(blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    private static func account(_ hostname: String, _ port: Int) -> String { "\(hostname.lowercased()):\(port)" }
}
