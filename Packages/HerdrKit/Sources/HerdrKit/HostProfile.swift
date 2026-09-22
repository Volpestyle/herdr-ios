import Foundation

public enum HostPlatform: String, Codable, CaseIterable, Sendable { case unix, windows }

public struct HostProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// MagicDNS name or `100.x.y.z`.
    public var hostname: String
    public var port: Int
    public var username: String
    public var platform: HostPlatform
    /// `nil` attaches to herdr's default session.
    public var herdrSession: String?
    /// `nil` (or blank) runs `HerdrCommand.attach(platform:session:)`.
    public var remoteCommand: String?

    public init(
        id: UUID = UUID(), name: String, hostname: String, port: Int = 22, username: String,
        platform: HostPlatform = .unix, herdrSession: String? = nil, remoteCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.username = username
        self.platform = platform
        self.herdrSession = herdrSession
        self.remoteCommand = remoteCommand
    }

    /// The command the session execs on the host; throws for a session name herdr would reject.
    func resolvedCommand() throws -> String {
        if let remoteCommand, !remoteCommand.trimmingCharacters(in: .whitespaces).isEmpty { return remoteCommand }
        guard let session = herdrSession?.trimmingCharacters(in: .whitespaces), !session.isEmpty else {
            return HerdrCommand.attach(platform: platform, session: nil)
        }
        if let problem = HerdrCommand.sessionNameError(session) { throw SessionError.invalidSessionName(problem) }
        return HerdrCommand.attach(platform: platform, session: session)
    }
}

public enum HerdrCommand {
    /// Default attach command per host platform; see docs/host-setup.md.
    /// Valid herdr session names (`sessionNameError(_:) == nil`) pass through bare. Anything else is
    /// quoted so it reaches herdr as one literal argument, and herdr rejects it; `TerminalSession`
    /// refuses invalid names before connecting.
    public static func attach(platform: HostPlatform, session: String?) -> String {
        switch platform {
        case .unix:
            // SSH exec runs a non-login `zsh -c` without Homebrew on PATH; the login shell finds herdr.
            let herdr = session.map { "herdr session attach \(isWord($0) ? $0 : posixQuoted($0))" } ?? "herdr"
            return "exec \"$SHELL\" -lc \(posixQuoted(herdr))"
        case .windows:
            // ponytail: PowerShell quoting (the PC's sshd DefaultShell); a cmd.exe default shell would
            // need cmd quoting for invalid names, which TerminalSession never sends.
            return session.map { "herdr session attach \(isWord($0) ? $0 : powerShellQuoted($0))" } ?? "herdr"
        }
    }

    /// herdr's own rule (`validate_name` in herdr's src/session.rs): 1-64 bytes of ASCII letters,
    /// digits, `.`, `_`, `-`, and not `.` or `..`. Returns herdr's message, or `nil` if valid.
    public static func sessionNameError(_ name: String) -> String? {
        if name.isEmpty { return "session name cannot be empty" }
        if name.utf8.count > 64 { return "session name cannot be longer than 64 bytes" }
        if name == "." || name == ".." { return "session name cannot be . or .." }
        guard isWord(name) else { return "session name may only contain ASCII letters, numbers, '.', '_' and '-'" }
        return nil
    }

    static func posixQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    static func powerShellQuoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }

    private static func isWord(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
                || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
    }
}
