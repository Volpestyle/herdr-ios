import Foundation
import Testing
@testable import HerdrKit

@Suite struct PairingPayloadTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let seed = Data(repeating: 0x42, count: 32)
    private var fields: [String: String] {
        ["v": "1", "id": base64URL(Data(repeating: 0x10, count: 16)), "n": "James’s Mac",
         "u": "james", "os": "unix", "h": " Mac.Tail123.ts.net. ,mac,100.64.0.1,fd7a:115c:a1e0::1",
         "p": "22", "fp": "SHA256:" + String(seed.base64EncodedString().dropLast()),
         "k": base64URL(seed), "x": "1800000600", "s": "phone"]
    }

    @Test func parsesBothPlatformsAndIgnoresCommands() throws {
        for platform in ["unix", "windows"] {
            var input = fields
            input["os"] = platform
            input["cmd"] = "touch pwned"
            input["remoteCommand"] = "powershell arbitrary-command"
            let payload = try PairingPayload(url: url(input), now: now)
            #expect(payload.id == fields["id"])
            #expect(payload.name == "James’s Mac")
            #expect(payload.username == "james")
            #expect(payload.platform.rawValue == platform)
            #expect(payload.hosts == ["mac.tail123.ts.net", "mac", "100.64.0.1", "fd7a:115c:a1e0::1"])
            #expect(payload.port == 22)
            #expect(payload.fingerprints == [fields["fp"]!])
            #expect(payload.privateKeySeed == seed)
            #expect(payload.expiresAt == now.addingTimeInterval(600))
            #expect(payload.session == "phone")
        }
        var input = fields
        input.removeValue(forKey: "s")
        #expect(try PairingPayload(url: url(input), now: now).session == nil)
    }

    @Test func rejectsMissingDuplicateAndUnsupportedFields() throws {
        for field in fields.keys where field != "s" {
            var input = fields
            input.removeValue(forKey: field)
            #expect(throws: PairingPayloadError.missingField(field)) {
                try PairingPayload(url: url(input), now: now)
            }
        }
        for field in fields.keys {
            var parts = URLComponents(url: try url(fields), resolvingAgainstBaseURL: false)!
            parts.queryItems!.append(URLQueryItem(name: field, value: fields[field]))
            #expect(throws: PairingPayloadError.duplicateField(field)) {
                try PairingPayload(url: #require(parts.url), now: now)
            }
        }
        var input = fields
        input["v"] = "2"
        #expect(throws: PairingPayloadError.unsupportedVersion) { try PairingPayload(url: url(input), now: now) }
    }

    @Test func validatesCredentialAndProfileBoundaries() throws {
        let invalid: [String: [String]] = [
            "id": ["", "../state", base64URL(Data(repeating: 0, count: 15)), String(repeating: "A", count: 21) + "B"],
            "n": [String(repeating: "x", count: 65)],
            "u": ["", "james volpe", "james\n", "james\t", "james" + String(UnicodeScalar(0)!), String(repeating: "u", count: 65)],
            "os": ["macos", "WINDOWS", ""],
            "p": ["0", "65536", "-1", "+22", "22.0", " 22", "٢٢", ""],
            "fp": ["", "SHA256:abc", "MD5:" + String(repeating: "a", count: 43),
                   "SHA256:" + String(repeating: "A", count: 42) + "B",
                   "SHA256:" + String(repeating: "_", count: 43),
                   Array(repeating: fields["fp"]!, count: 4).joined(separator: ",")],
            "k": ["", seed.base64EncodedString(), base64URL(Data(repeating: 0, count: 31)),
                  String(repeating: "A", count: 42) + "B", String(repeating: "/", count: 43)],
            "x": ["nan", "inf", "1800000600.5", "9223372036854775808", "1800000901", "+1800000600"],
            "s": ["", ".", "..", "a b", "$(calc)", String(repeating: "a", count: 65)],
        ]
        for (field, values) in invalid {
            for value in values {
                var input = fields
                input[field] = value
                #expect(throws: PairingPayloadError.invalidField(field)) {
                    try PairingPayload(url: url(input), now: now)
                }
            }
        }
    }

    @Test func validatesHostsWithoutNumericIPBypasses() throws {
        for host in ["100.64.0.0", "100.127.255.255", "PC-01", "pc.tail123.ts.net.",
                     "fd7a:115c:a1e0::", "fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff"] {
            var input = fields
            input["h"] = host
            #expect(try PairingPayload(url: url(input), now: now).hosts == [HostKeyPins.canonical(host)])
        }
        for host in ["", "pc,", "pc,,mac", "a,b,c,d,e", "127.0.0.1", "192.168.1.1", "100.63.255.255",
                     "100.128.0.0", "100.064.0.1", "2130706433", "0x7f000001", "127.1", "0177.0.0.1",
                     "::1", "::ffff:100.64.0.1", "fd7a:115c:a1e1::1", "fd7a:115c:a1e0::1%en0",
                     "[fd7a:115c:a1e0::1]", "example.com", "ts.net", "pc.ts.net.evil.com", "pc..ts.net",
                     "-pc", "pc-", "pc_name", "pc/path", "pc:22", "pc@mac", "pc\nmac",
                     "*.ts.net", "fd7a:115c:a1e0::1" + String(UnicodeScalar(0)!) + "ignored",
                     String(repeating: "a", count: 64)] {
            var input = fields
            input["h"] = host
            #expect(throws: PairingPayloadError.invalidField("h")) {
                try PairingPayload(url: url(input), now: now)
            }
        }
    }

    @Test func expiryIsBoundedAtBothEnds() throws {
        for seconds in [1, 900] {
            var input = fields
            input["x"] = String(Int(now.timeIntervalSince1970) + seconds)
            #expect(try PairingPayload(url: url(input), now: now).expiresAt > now)
        }
        for seconds in [-1, 0] {
            var input = fields
            input["x"] = String(Int(now.timeIntervalSince1970) + seconds)
            #expect(throws: PairingPayloadError.expired) { try PairingPayload(url: url(input), now: now) }
        }
    }

    @Test func rejectsOtherURLShapesAndKeepsErrorsFreeOfSecrets() throws {
        let base = try url(fields)
        for text in [base.absoluteString.replacingOccurrences(of: "herdr:", with: "https:"),
                     base.absoluteString.replacingOccurrences(of: "//pair?", with: "//other?"),
                     base.absoluteString.replacingOccurrences(of: "//pair?", with: "//user@pair?"),
                     base.absoluteString.replacingOccurrences(of: "//pair?", with: "//pair:22?"),
                     base.absoluteString.replacingOccurrences(of: "//pair?", with: "//pair/path?"),
                     base.absoluteString + "#fragment", base.absoluteString + "&extra=" + String(repeating: "x", count: 8192)] {
            #expect(throws: PairingPayloadError.invalidURL) {
                try PairingPayload(url: #require(URL(string: text)), now: now)
            }
        }
        var input = fields
        input["k"] = "sensitive-invalid-seed"
        do {
            _ = try PairingPayload(url: url(input), now: now)
            Issue.record("Invalid credential accepted")
        } catch {
            #expect(!error.localizedDescription.contains("sensitive-invalid-seed"))
            #expect(!String(describing: error).contains("sensitive-invalid-seed"))
        }
    }

    private func url(_ values: [String: String]) throws -> URL {
        var parts = URLComponents()
        parts.scheme = "herdr"
        parts.host = "pair"
        parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try #require(parts.url)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
