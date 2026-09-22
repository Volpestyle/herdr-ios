# Lane: transport (w29:p2)

Owned paths: `Packages/HerdrKit/**` (except `PairingPayload.swift` and `PairingPayloadTests.swift`,
which belong to w29:p7), `docs/lanes/transport.md`.

Stage: done, pairing included. `Packages/HerdrKit` is a Swift package (iOS 26, macOS 15) that
implements the [HerdrKit contract](../plan.md#herdrkit-contract-transport--app) and
`Pairing.enroll` for [ADR 0002](../adr/0002-qr-pairing.md). It depends on swift-nio-ssh 0.15.0
and swift-nio. It does not use Citadel (see [Decisions](#decisions)).

| File | Holds |
| --- | --- |
| `SSHTransport.swift` | Shared plumbing: connect with the peer-address gate, host-key validator and auth, session channels with backpressure, output tails, error text |
| `TerminalSession.swift` | PTY sessions, TOFU, end states |
| `Pairing.swift` | `Pairing.enroll`, `PairingError` |
| `Keychain.swift` | Keychain, `DeviceKey`, `HostKeyPins` |
| `HostProfile.swift`, `HostStore.swift` | Profiles, attach commands, persistence |
| `PairingPayload.swift` (w29:p7) | The `herdr://pair` parser |

## API delta vs the contract

Every contract signature exists as written. These members are additions, and the app lane
already uses them:

| Addition | Why |
| --- | --- |
| `HostProfile.init(id:name:hostname:port:username:platform:herdrSession:remoteCommand:)` | Public memberwise init, `port` defaults to 22, `platform` to `.unix`. |
| `HostStore.init(fileURL:)`, `HostStore.defaultFileURL` | Default is `Application Support/Herdr/hosts.json`. Tests pass a temp file. |
| `HostStore.hasPassword(for:)` | Lets the editor show that a password is saved without reading it. |
| `HostStore.forgetHostKey(hostname:port:)` | Recovery after a legitimate host rebuild. Otherwise a changed key stays refused forever. |
| `TerminalSession.profile`, `TerminalSession.rejectedHostKey` | `rejectedHostKey` carries the `.changed(previousFingerprint:)` challenge after a refusal, for the mismatch UI. |
| `HerdrCommand.sessionNameError(_:)` | herdr's own `validate_name` rule, returning herdr's message. Use it for form validation. |
| `HostKeyChallenge: Equatable` | Tests and UI diffing. |
| `DeviceKey.fingerprintSHA256()` | `SHA256:…` of the device key, the same value the pairing helper's approval prompt prints, so the phone can show what the computer asks about. |

Behavior the app relies on:

- `attach(platform:session:)` returns the strings in
  [host-setup](../host-setup.md#attach-commands). It never traps. An invalid name is quoted
  (POSIX for unix, PowerShell for windows), so it reaches herdr as one literal argument and herdr
  rejects it. `connect` refuses an invalid `herdrSession` before opening a socket:
  `failed("Invalid herdr session name: …")`. A non-blank `remoteCommand` is used verbatim.
- `failed(String)` can span several lines. When the channel closes, the message is the reason
  followed by up to 3 readable lines of the last output, with escape sequences stripped.
- End states: `disconnect()` gives `.closed`. A clean exit (status 0) more than 2 s after
  `.connected`, such as `ctrl+b q`, gives `.closed`. Any other exit is `.failed`. That covers exit
  0 within 2 s (Windows reports 0 when `herdr` isn't recognized), any non-zero status (127 names
  "not found"), and a dropped connection.
- `onOutput` gets stdout and stderr in order on the MainActor, one chunk per network read burst.
  `send` writes stdin, and `resize` sends an SSH window-change. The PTY is `xterm-256color` with
  IUTF8 set.
- Output has backpressure. The next read waits until `onOutput` returns, so a slow or blocked
  MainActor stalls the host in its SSH window instead of buffering in app memory.
- The hostname is canonicalized (trimmed, lowercased, trailing `.` dropped) for both the connect
  and the pin. `Host.ts.net.` and `host.ts.net` share one pin, while `100.x`, the short MagicDNS
  name and the FQDN each get their own, like `known_hosts`.

## Pairing API

```swift
public enum Pairing {
    public enum Progress: Sendable, Equatable {
        case connecting(hostname: String)
        case waitingForApproval(computer: String)
    }
    @MainActor public static func enroll(
        payload: PairingPayload, deviceName: String,
        progress: @escaping @MainActor (Progress) -> Void = { _ in }
    ) async throws(PairingError) -> HostProfile
}

public enum PairingError: Error, Equatable, Sendable, LocalizedError {
    case linkExpired                                          // expiresAt passed before enroll started
    case conflictingPin(hostname: String, port: Int)          // a different pin exists; never replaced
    case hostKeyMismatch(hostname: String, fingerprint: String) // presented key isn't in the code
    case unreachable(String)                                  // no name reached SSH; last reason
    case notOnTailnet(hostname: String, address: String)      // resolved outside the tailnet
    case pairingKeyRejected                                   // one-time key used, expired or removed
    case denied(output: String)                               // exit 3
    case expired(output: String)                              // exit 4
    case used(output: String)                                 // exit 5: another enroll claimed the code
    case failed(status: Int?, output: String)
    case cancelled
}
```

The caller saves the returned profile (`store.upsert`). It is the payload's `name`, `username`,
`port`, `platform` and `session`, plus the hostname that connected, with no `remoteCommand`.
`errorDescription` holds text ready for the UI. Cancelling the task closes the connection
within about a second, even while the computer is deciding.

How `enroll` runs:

1. It rechecks `expiresAt`, because the confirmation screen can sit open.
2. It reads the pin for every `hostname:port` in the code. A pin that isn't one of the code's
   fingerprints fails with `conflictingPin` before any connection. A pin that is in the list
   becomes the only key accepted for that name.
3. It tries the names in order, using `SSHTransport.open` with the seed's Ed25519 key and a
   `PinValidator` over the accepted set (no prompt). A `RemoteAddressGate` checks the connected
   address before `NIOSSHHandler` starts, so an address outside `100.64.0.0/10` or
   `fd7a:115c:a1e0::/48` gets no SSH bytes at all. Such a name, like one that never answers,
   moves on to the next name. `notOnTailnet` is reported if no name pairs. A presented key
   outside the accepted set stops pairing (`hostKeyMismatch` or `conflictingPin`), and so does
   a rejected one-time key.
4. It execs with no PTY (the forced command ignores the command string), writes
   `ssh-ed25519 <b64>\n<device name>\n`, closes stdin, and reads until exit. The device name is
   cut to 64 printable code points. Spaces become a plain space; control and format characters
   are dropped. The phone gives up after 180 s, and the host waits up to 120 s.
5. The helper's answer is its last non-empty stdout line (`OK`, `DENIED`, `EXPIRED`, `USED`,
   `INVALID`).
   stdout and stderr are read separately, so a trailing warning can't hide the answer. The token
   wins over the exit status, because a Windows PowerShell DefaultShell turns the helper's 3 and 4
   into 1. Statuses 3, 4 and 5 still count when no token arrives. Success needs `OK` and exit 0.
   The pin is add-only. If `pin` returns false and the pin
   that is there isn't the presented key, enroll fails with `conflictingPin`.

## Decisions

**NIOSSH directly, not Citadel.** ADR 0001 names Citadel, and I built on Citadel 0.12.1 first.
Citadel's only public way to get a connection you can open a custom channel on,
`SSHClient.connect(on:settings:)`, calls `channel.pipeline.syncOperations` from the caller's task.
That trips `NIOCore/ChannelPipeline.swift:1208: Precondition failed` (`assertInEventLoop`), and it
crashed the first test run. `SSHClientSettings.channelHandlers` is internal and never added. The
TTY API only offers pty-req + *shell* (`withPTY`), and the contract needs pty-req + exec.
Citadel's connect path wraps about 20 lines of NIOSSH, so `TerminalSession.open` adds
`NIOSSHHandler` and an auth waiter in the bootstrap's `channelInitializer` (on the loop). Dropping
Citadel also drops its dependency on a personal swift-nio-ssh fork (`Wellz26/swift-nio-ssh`) in
favor of upstream `apple/swift-nio-ssh`. The lead owns ADR 0001, which still says Citadel.

**Two-phase TOFU.** With no pin, the host key validator always refuses. So the first handshake
ends before auth, and no credential reaches an unconfirmed host. The session then asks
`confirmHostKey`, pins on approval, and reconnects. The second handshake must present exactly the
pinned fingerprint. Because of this, the trust prompt never sits inside a live handshake, where it
would hit handshake timeouts or sshd's `LoginGraceTime`. The state is decided from the key the
host presented, not from how NIO reported the failure. A disconnect during the prompt discards the
answer: generation checks follow every await. Pinning is add-only. If two sessions to a new host
both prompt, the later approval keeps the earlier pin, and its reconnect either matches that pin or
takes the changed-key refusal. A pin changes only through `forgetHostKey`.

**Backpressure.** The session channel runs with autoRead off. `SessionChannelHandler` collects one read
burst into a single `.output` event, and the MainActor pump requests the next read after
`onOutput` returns. NIOSSH sends WINDOW_ADJUST only when bytes reach the pipeline, so unread
output waits in the host's SSH window (`maximumPacketSize` × 64), and at most one burst sits in the
app. Every NIO promise is completed on every path. A failed TCP connect fails the auth promise, and
a `createChannel` that fails before its initializer runs fails `ready`. NIO traps on a leaked
promise in debug builds.

```mermaid
sequenceDiagram
  participant App
  participant TS as TerminalSession
  participant Host as sshd
  App->>TS: connect(cols, rows)
  TS->>TS: validate herdrSession
  TS->>Host: TCP + kex (validator: pin for host:port)
  alt no pin
    Host-->>TS: host key K
    TS-->>Host: refuse (no auth sent)
    TS->>App: confirmHostKey(.firstUse, SHA256(K))
    alt approved and still current
      TS->>TS: pin SHA256(K) in Keychain (add-only)
      TS->>Host: reconnect, must present the pinned key
    else declined or disconnected
      TS-->>App: failed / closed, nothing pinned
    end
  else pin != SHA256(K)
    TS-->>App: failed(changed), rejectedHostKey = .changed (never prompts)
  end
  TS->>Host: auth: device Ed25519 key, then saved password
  TS->>Host: session channel, pty-req xterm-256color, exec attach command
  Host-->>TS: success x2
  TS-->>App: connected, onOutput stream
```

**Storage.** Everything goes in the Keychain as generic passwords with
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`:

| Service | Account | Data |
| --- | --- | --- |
| `com.volpestyle.herdr.device-key` | `ed25519` | 32-byte raw private key, created on first use |
| `com.volpestyle.herdr.host-key` | canonical `hostname:port` | `SHA256:…` fingerprint |
| `com.volpestyle.herdr.password` | host UUID | password |

Pins are keyed by `hostname:port` like `known_hosts`, so deleting a profile doesn't forget its
pin. On iOS these items are always in the data-protection keychain. On macOS (tests only) they're
in the login keychain, because the data-protection keychain rejects unsigned binaries with
`-34018`. Host profiles are JSON written with `completeFileProtectionUntilFirstUserAuthentication`.
An unreadable file is moved aside as `hosts.json.corrupt` instead of being overwritten.

## Evidence

In `Packages/HerdrKit`:

- `swift build`: clean, no warnings in HerdrKit sources. `xcodebuild -scheme HerdrKit
  -destination 'generic/platform=iOS Simulator' build`: `BUILD SUCCEEDED`.
- `swift test`: 55 tests in 10 suites pass, including w29:p7's parser tests, and the 16 sshd
  tests are skipped. Run with no network setup:
  - Attach strings match host-setup exactly.
  - Invalid names are quoted instead of trapping. The unix attach command goes through real
    `/bin/sh` twice with a fake `herdr`, for 9 hostile names (`$(touch pwned)`, backticks, `;`,
    quotes, empty). herdr always receives `session attach <name>` and nothing executes.
  - herdr's name rule: 3 valid and 11 invalid cases.
  - DeviceKey output parses as an OpenSSH key, and fingerprints equal `ssh-keygen -l -E sha256`.
    Hostname spellings share one pin, and pins are add-only.
  - HostStore round-trips JSON and Keychain.
  - Output-tail stripping works on unix and ConPTY-shaped bytes.
  - An in-process NIOSSH server covers trust: first use approved pins the exact key, reconnects,
    and reaches auth. Declining pins nothing and makes no auth attempt. A changed key is refused
    without a prompt, the pin is untouched, and no auth attempt reaches the impostor. A disconnect
    during the prompt leaves `.closed`, no pin, and no second socket. An invalid session name
    fails before connecting.
  - A concurrent first-use approval keeps the first pin and refuses the other key as changed.
  - A refused channel open fails the session.
  - A refused TCP connect (`127.0.0.1:1`) fails the session instead of trapping on a leaked promise.
  - A channel open on a connection with no SSH handler completes `ready`.
  - Pairing, against the in-process server:
    - A host key not in the code gives `hostKeyMismatch`, with no auth attempt and no pin.
    - A conflicting existing pin gives `conflictingPin` with zero TCP connections.
    - A pin that is in the code is the one used.
    - Names are tried in order (`.invalid`, then `127.0.0.1`).
    - Nothing reachable gives `unreachable`.
    - The real tailnet predicate refuses `127.0.0.1` with `notOnTailnet`, one TCP connection
      and no auth.
    - A stale `expiresAt` gives `linkExpired` without connecting.
    - The tailnet predicate passes 5 addresses and refuses 8. Device names are sanitized. The
      request is exactly two lines.
    - A 16-case verdict table covers the token and status: CRLF, a banner before `OK`,
      `DENIED`/`EXPIRED`/`USED` with exit 1, a bare exit 3, 4 or 5, `OK` with a non-zero or
      missing status, and `INVALID`.
- `HERDR_IOS_SSH_TEST=1 swift test`: 55 tests in 10 suites pass, against this Mac's sshd at
  `127.0.0.1:22` as `james` with the DeviceKey:
  - First use pins a fingerprint that is in `ssh-keyscan 127.0.0.1` | `ssh-keygen -l`.
  - `TERM=xterm-256color` and `stty size` = `24 80`. After `resize(120, 40)` and a sent line, it's
    `40 120`. stdin echoes back through `cat`, and stderr arrives. `disconnect()` gives `.closed`.
  - `exec "$SHELL" -lc 'herdr --version'` prints `herdr 0.9.1`, so the login shell finds Homebrew's
    herdr.
  - `exit 3` fails with status 3. A missing command fails with 127 and `command not found: …`.
  - A quick exit 0 fails with its output, and a clean exit after 2.2 s is `.closed`.
  - A changed pinned key against the real sshd is refused, and `rejectedHostKey` names the live
    fingerprint.
  - Backpressure: `onOutput` blocks the MainActor for 3 s on the first chunk while the host writes
    64 MB. The writer hasn't finished when the stall ends. All 64 MB then arrive, and no chunk is
    over 16 MB.
  - Pairing through w29:p7's parser, against the tailnet address `100.103.220.58`. Each test adds
    a real one-time key line (`restrict`, `expiry-time`, `from=`, `command=` a stand-in for
    `herdr-pair.py --enroll` that records what it received) and removes exactly that line.
    - Approved: progress is `connecting` then `waitingForApproval`. The profile is right and has
      no `remoteCommand`. The pin is one of sshd's non-RSA keys. The helper received the device
      key and the sanitized name with no TTY, stdin reached EOF, and `SSH_ORIGINAL_COMMAND` was
      the phone's ignored `herdr-pair`.
    - Denied (exit 3) and expired (exit 4) give typed errors and leave no pin. `DENIED\r\n` with
      exit 1 (Windows-style) is still denied.
    - `OK` followed by a stderr warning still pairs. `USED` (exit 5) is `.used` and leaves no pin.
    - Cancelling while waiting returns `.cancelled` in under 5 s, with no pin.
    - Comparing `authorized_keys` before and after a run shows no line of mine left behind. (A
      one-time line from w29:p4's live helper came and went during the run, untouched.)
- Each of the leak, backpressure and add-only-pin tests fails against a scratch copy with its fix
  removed. Without backpressure, the 64 MB writer finishes during the stall.

### authorized_keys entry (remove later)

This line in `~/.ssh/authorized_keys` on this Mac is the transport lane's. The sshd suite uses it.
Other lines there (device keys) belong to other lanes.

```
from="127.0.0.1,::1,100.64.0.0/10" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIERrvlx0U2/xRcgre1YFPaR9v15A/8yd0h9T+UL06j8w herdr-ios-test
```

Remove it with `sed -i '' '/herdr-ios-test$/d' ~/.ssh/authorized_keys`. The private key is the
login-keychain item `com.volpestyle.herdr.device-key`/`ed25519`, created by the tests. Delete it
with `security delete-generic-password -s com.volpestyle.herdr.device-key -a ed25519`. The
hosts lane's `scripts/authorize-key.sh` doesn't write the `from=` restriction, so I added the
line by hand.

## Gaps

- The pairing tests use a stand-in forced command, not `scripts/herdr-pair.py`. The real helper
  end to end (scan → approve → attach) is plan acceptance item 9, run from the app with
  `simctl openurl`.
- Both the pairing tests and w29:p4's helper rewrite `authorized_keys`. Each removes only its
  own line, re-reading just before the write. A write landing in that microsecond window could
  still drop the other's line.
- HerdrKit hasn't paired against Windows. Whether the forced command holds under Windows OpenSSH
  is the hosts lane's check.

- No HerdrKit test attaches to a live herdr session. An attaching client resizes every pane in
  that session. The hosts lane verified attach, detach, mobile layout and reflow over `ssh -tt`
  with throwaway sessions, and the app lane covers the app end to end.
- HerdrKit hasn't connected to Windows. The device key isn't authorized on supedupsilly. A raw
  `ssh -tt` capture there (missing command) returned only ConPTY control sequences and exit 0,
  which the quick-exit rule and output tail handle.
- The password fallback (method `password`) is untested. This Mac's sshd config wasn't touched.
  NIOSSH has no `keyboard-interactive`, so a host that only allows keyboard-interactive needs the
  device key.
- For an invalid session name, `attach(.windows, …)` quoting is PowerShell-safe but not cmd.exe
  safe. `TerminalSession` never sends invalid names. This only matters to a caller that runs
  `attach` output directly on a cmd.exe-default host.
- There's no SSH keepalive. iOS drops the socket in the background anyway, and the app reconnects
  on return.
