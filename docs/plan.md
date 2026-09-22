# herdr-ios delivery plan (lead-owned index)

Goal: a universal iPhone/iPad app that connects to herdr on any of my Macs or my Windows PC over
Tailscale. Architecture: [ADR 0001](adr/0001-ssh-terminal-client.md).

Scope owner: the lead pane (w29:p1). Only the lead changes this file or the acceptance below.
Each lane owns its own record under `docs/lanes/` and its own paths.

## Acceptance (fixed)

1. The app builds for iOS Simulator (iPhone and iPad, iOS 26+ deployment target) and installs on
   the paired physical iPhone 17 Pro Max and iPad Pro 13.
2. In the app you can add a host (MagicDNS name or `100.x`), connect over SSH with the device's
   Ed25519 key, and land in that host's live herdr TUI. Typing, the `ctrl+b` prefix, esc and
   arrows all work. Taps click in herdr. Rotation and iPad multitasking resizes reflow the
   terminal.
3. The same works against the Windows PC `supedupsilly`, or there is a documented blocker with
   evidence and a named follow-up.
4. Backgrounding and then returning reattaches to the same herdr session automatically.
5. Host keys are pinned on first use (TOFU) with a prompt, and a changed key is refused.
6. The README covers setup: the Tailscale app, Remote Login/OpenSSH on hosts, and authorizing the
   device key. Docs describe what exists.

## Acceptance: QR pairing (added 2026-09-21 at the user's request)

Protocol: [ADR 0002](adr/0002-qr-pairing.md).

7. `python3 scripts/herdr-pair.py [--session NAME]` on a Mac or on the Windows PC shows a QR code
   in the terminal. After you scan it (in-app scanner, or the system Camera via `herdr://`), the
   phone shows the computer and account. Approving on the computer authorizes the device key,
   pins the host key without a TOFU prompt, saves the host, and attaches to herdr. It involves no
   typing on the phone.
8. The one-time key is restricted (`restrict`, `from=` the tailnet, `expiry-time`, forced
   command), is single use, and is removed on every exit path. A denial or expiry leaves no
   device key behind. A QR can never set a remote command or overwrite an existing pin.
9. Proven end to end in the simulator against this Mac and against supedupsilly, using
   `simctl openurl` for the scan path, with throwaway sessions. Physical-device scanning is the
   user's check.

## Tailnet facts

| Device | Tailscale name | IP | Role |
| --- | --- | --- | --- |
| MacBook Pro (this Mac) | `jamess-macbook-pro` | 100.103.220.58 | host, sshd on :22 |
| Windows PC | `supedupsilly` | 100.108.214.60 | host (see `windows-pc` skill for SSH) |
| iPad Pro 13 (M5) | `ipad173` | 100.79.186.68 | client, devicectl `00008142-00117899226B401C` |
| iPhone 17 Pro Max | `iphone182` | 100.96.21.94 | client, devicectl `00008150-0016258C21F2401C` |

Signing: `Apple Development: James Volpe`. Bundle id `com.volpestyle.herdr`. Look up the team id
from the existing identity and projects (macpad uses `DEVELOPMENT_TEAM = 8YW4D4C6CW`).

## Layout and ownership

| Lane | Owner | Owned paths | Record |
| --- | --- | --- | --- |
| transport | w29:p2 | `Packages/HerdrKit/**` | [lanes/transport.md](lanes/transport.md) |
| app | w29:p3 | `project.yml`, `App/**`, `README.md` | [lanes/app.md](lanes/app.md) |
| hosts | w29:p4 | `docs/host-setup.md`, `scripts/**` | [lanes/hosts.md](lanes/hosts.md) |
| review | w29:p5 | none (reserved for one bounded review at integration) | this file |
| pairing: host helper | w29:p4 | `scripts/herdr-pair.py`, `scripts/qrcodegen*.py`, pairing section of `docs/host-setup.md` | lanes/hosts.md |
| pairing: HerdrKit | w29:p2 | `Packages/HerdrKit/**` except the two parser files (`Pairing.enroll`) | lanes/transport.md |
| pairing: parser | w29:p7 (Codex) | `HerdrKit/PairingPayload.swift`, `HerdrKitTests/PairingPayloadTests.swift` | commit message |
| pairing: app | w29:p3 | `App/**` (URL scheme, scanner, pairing flow) | lanes/app.md |


All lanes share the `main` checkout at `~/dev/herdr-ios`. Load `shared-checkout` before
committing, commit only your own paths, and commit directly on `main`.

Testing rule: herdr sizes every pane in a session to the foreground client's terminal
(`effective_size` in `src/server/headless.rs`). An end-to-end attach at phone width against a
host's default session would reflow every live agent pane there. All test attaches use a
throwaway named session (`herdr-ios-test`, `hosts-probe`), and afterwards only that session gets
deleted.

## HerdrKit contract (transport ↔ app)

transport produces this API and app consumes it. Changes need both owners to agree directly, and
the lead has to be told. Exact spelling can change, but the capabilities can't.

```swift
public enum HostPlatform: String, Codable, CaseIterable, Sendable { case unix, windows }

public struct HostProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String            // display name
    public var hostname: String        // MagicDNS name or 100.x.y.z
    public var port: Int               // default 22
    public var username: String
    public var platform: HostPlatform
    public var herdrSession: String?   // nil → herdr's default session
    public var remoteCommand: String?  // nil → HerdrCommand.attach(platform:session:)
}

public enum HerdrCommand { public static func attach(platform: HostPlatform, session: String?) -> String }

@MainActor @Observable public final class HostStore {   // JSON persistence in Application Support
    public private(set) var hosts: [HostProfile]
    public func upsert(_ host: HostProfile); public func delete(_ id: UUID)
    public func setPassword(_ password: String?, for id: UUID)  // Keychain
}

public enum DeviceKey { public static func publicKeyOpenSSH() throws -> String }  // Ed25519, Keychain, created on first use

public struct HostKeyChallenge: Sendable {
    public enum Kind: Sendable { case firstUse, changed(previousFingerprint: String) }
    public let hostname: String; public let port: Int; public let fingerprintSHA256: String; public let kind: Kind
}

public enum SessionState: Equatable, Sendable { case idle, connecting, connected, failed(String), closed }

@MainActor @Observable public final class TerminalSession {
    public init(profile: HostProfile, store: HostStore,
                confirmHostKey: @escaping @MainActor (HostKeyChallenge) async -> Bool)
    public private(set) var state: SessionState
    public var onOutput: (@MainActor ([UInt8]) -> Void)?
    public func connect(cols: Int, rows: Int) async   // PTY (xterm-256color) + attach command
    public func send(_ bytes: [UInt8])
    public func resize(cols: Int, rows: Int)          // SSH window-change
    public func disconnect()
}
```

Changed host keys are refused inside HerdrKit. `confirmHostKey` is only asked on first use; for
`.changed` the UI shows the mismatch and the connection fails.

## Status

| Lane | Stage | Evidence |
| --- | --- | --- |
| hosts | accepted | macOS + Windows attach verified; `authorize-key.sh`; [lanes/hosts.md](lanes/hosts.md) |
| transport | accepted | HerdrKit, 55 tests incl. live sshd; two review passes fixed; [lanes/transport.md](lanes/transport.md) |
| app | accepted | simulator e2e on iPhone and iPad against the Mac and the PC; [lanes/app.md](lanes/app.md) |
| pairing | accepted | helper + HerdrKit + parser + app; sim e2e on both hosts incl. deny, USED and tamper cases; security review fixed |
| devices | partial | iPhone 17 Pro Max has the current build installed; iPad Pro 13 install is queued until it unlocks; physical QR scan is the user's check |

Known gaps:

- supedupsilly's PATH pins herdr's versioned 0.9.0 folder. The stable bin folder is a junction
  that elevated SSH sessions refuse to follow, so after a herdr update SSH may run the old client.
  Needs an upstream herdr installer fix (a real copy or hardlink in `bin`).
- The app strips one ConPTY mouse-reset sequence to work around a SwiftTerm bug. Upstream
  SwiftTerm fix: `cmdResetMode` should clear the mouse encoding only for the active mode.
- herdr's PowerShell prompt integration throws under `Set-StrictMode` (upstream `src/pane.rs`).
- iPhone to Windows: narrow panes can show blank for a few seconds after reattach (likely late
  ConPTY repaint). iPad redraws fine.
- The transport sshd suite's `herdr-ios-test` key stays in `~/.ssh/authorized_keys` on this Mac.
  Removal steps are in [lanes/transport.md](lanes/transport.md#authorized_keys-entry-remove-later).
