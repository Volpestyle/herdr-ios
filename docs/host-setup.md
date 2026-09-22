# Host setup

A host is any Mac or Windows PC the app attaches to. It needs three things: an SSH server reachable
over Tailscale, `herdr` on the PATH that an SSH session sees, and the device's public key
authorized. The app opens SSH with a PTY (`TERM=xterm-256color`), runs the attach command for the
host's platform, and renders the herdr TUI. herdr keeps the session and its agents running on the
host between connections.

```mermaid
sequenceDiagram
  participant App as iPhone / iPad
  participant SSHD as sshd on host
  participant Sh as login shell / PowerShell
  participant C as herdr client
  participant S as herdr server (session)
  App->>SSHD: SSH over Tailscale, pty-req + exec(attach command)
  SSHD->>Sh: unix: $SHELL -c '<cmd>' · windows: DefaultShell -c '<cmd>'
  Sh->>C: unix: exec "$SHELL" -lc 'herdr …' · windows: herdr …
  C->>S: attach (starts the session if it is not running)
  App-->>C: keys, window-change
  C-->>App: TUI frames
  Note over App,S: ctrl+b q detaches the client; the session keeps running
```

## Attach commands

| Platform | Default session | Named session |
| --- | --- | --- |
| macOS, Linux (`unix`) | `exec "$SHELL" -lc 'herdr'` | `exec "$SHELL" -lc 'herdr session attach NAME'` |
| Windows (`windows`) | `herdr` | `herdr session attach NAME` |

- `HerdrCommand.attach(platform:session:)` produces these strings, and a host's `remoteCommand`
  overrides them.
- On unix, sshd runs the command with `$SHELL -c`, which is neither a login shell nor an
  interactive one. On macOS that PATH is `/usr/bin:/bin:/usr/sbin:/sbin` plus whatever
  `~/.zshenv` adds, so Homebrew's `/opt/homebrew/bin/herdr` is missing. `"$SHELL" -lc` reads the
  login profile (`~/.zprofile`, `~/.bash_profile`, `~/.profile`, fish's `config.fish`), which is
  where Homebrew and most installers set PATH.
- On Windows, sshd gives the session the user's registry PATH, so bare `herdr` resolves. The same
  string works whether sshd's default shell is `cmd.exe` or Windows PowerShell.
- `herdr session attach NAME` and `herdr --session NAME` are the same code path. Both start the
  session when it is not running. `default` names the default session.
- herdr accepts `NAME` only as 1–64 bytes of `A-Z a-z 0-9 . _ -`, and not `.` or `..`. That charset
  needs no quoting in sh, zsh, bash, fish, cmd or PowerShell, so the app rejects any other name
  rather than escaping it.

What the TUI does over SSH:

- `ctrl+b q` detaches. herdr exits, the SSH channel closes, and the session keeps running. The
  next attach shows the same screen.
- Below 64 columns herdr switches to its mobile layout (`ui.mobile_width_threshold`, default 64).
  SSH window-change reflows it live between the mobile and desktop layouts.
- The most recently attached client becomes the foreground client, and every pane in that session
  is resized to its terminal. When it detaches, the panes return to the remaining client's size.

## Tailscale

1. Install Tailscale on each host (macOS: the Mac App Store or standalone app; Windows: the
   installer from tailscale.com) and sign in to the tailnet.
2. On iPhone or iPad, install the Tailscale app, sign in to the same tailnet, and turn the VPN on.
3. Add hosts in the app by MagicDNS name (e.g. `jamess-macbook-pro`) or `100.x.y.z` address.
   `tailscale status` on any device lists both.

The app uses the host's own sshd. Tailscale only carries the traffic, and nothing from Tailscale is
embedded in the app.

## macOS host

1. Turn on Remote Login: System Settings › General › Sharing › Remote Login, with "Allow access
   for" including your user. (`sudo systemsetup -setremotelogin on` does the same.)
2. Install herdr: `brew install herdr`, or `curl -fsSL https://herdr.dev/install.sh | sh`
   (installs to `~/.local/bin`).
3. Make sure a login shell finds it. From another machine, or over loopback:

   ```sh
   ssh you@host 'exec "$SHELL" -lc "command -v herdr"'
   ```

   If that prints nothing, the PATH line is only in an interactive file such as `~/.zshrc`. Move
   it to `~/.zprofile` (zsh) or `~/.bash_profile` (bash).
4. Keep the Mac reachable. A sleeping Mac drops off the tailnet. System Settings › Battery ›
   Options › "Prevent automatic sleeping on power adapter when the display is off" keeps it up.

## Windows host

1. Install and start OpenSSH Server in an elevated PowerShell:

   ```powershell
   Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
   Start-Service sshd
   Set-Service sshd -StartupType Automatic
   ```

   The capability adds the `OpenSSH-Server-In-TCP` firewall rule for port 22.
2. Default shell (optional). sshd uses `cmd.exe` unless
   `HKLM:\SOFTWARE\OpenSSH\DefaultShell` names another shell. The attach command works with
   either. To use Windows PowerShell:

   ```powershell
   New-ItemProperty -Path HKLM:\SOFTWARE\OpenSSH -Name DefaultShell -PropertyType String -Force `
     -Value C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe
   ```

   sshd starts PowerShell without `-NoProfile`, so the profile runs on every connection. Keep it
   quiet and fast.
3. Install herdr as the user who will connect:

   ```powershell
   powershell -ExecutionPolicy Bypass -c "irm https://herdr.dev/install.ps1 | iex"
   ```

   The installer puts `%LOCALAPPDATA%\Programs\Herdr\bin` on the user PATH. That folder, like
   `%USERPROFILE%\.herdr\packages\standalone\current`, is a junction to the current
   `…\standalone\releases\<version>` folder, created at medium integrity.

   - **Standard users:** their SSH sessions run at medium integrity and follow the junction, so
     nothing more is needed.
   - **Administrators:** their SSH sessions run elevated (High Mandatory Level). Windows refuses
     to follow a junction that a medium-integrity process created: "The path cannot be traversed
     because it contains an untrusted mount point". An admin therefore needs the real
     `releases\<version>` folder on the user PATH, and must move that entry to the new folder after
     each `herdr update`. The updater keeps three releases, so a stale entry keeps resolving the
     older client for two updates and then disappears.

   Check with a new SSH session: `ssh you@host herdr --version` should print the version that
   `herdr --version` prints on the desktop.
4. Start the default session from the desktop (open a terminal and run `herdr`, then `ctrl+b q`).
   A herdr server survives the SSH disconnect that started it, but it then lives in the SSH logon
   session: for an administrator that is an elevated token (new panes are titled
   `Administrator: …`), outside the console desktop.

herdr runs in the ConPTY that Windows OpenSSH allocates for the PTY. On connect, ConPTY sends
`ESC[?9001h` (win32-input-mode) and `ESC[?1004h` (focus reporting). A terminal that doesn't know
mode 9001 ignores it, and ConPTY falls back to plain VT input.

## Pair with a QR code

On a host that is already set up (sshd on, herdr on the SSH PATH, Tailscale connected), pairing
needs no copying or typing on the phone. The protocol is [ADR 0002](adr/0002-qr-pairing.md).

1. Put [`scripts/herdr-pair.py`](../scripts/herdr-pair.py) and
   [`scripts/qrcodegen.py`](../scripts/qrcodegen.py) (Nayuki's MIT QR encoder) in one folder on
   the computer. They need Python 3.9 or newer: `/usr/bin/python3` on macOS, the python.org
   build on Windows. `ssh-keygen` and `ssh-keyscan` come with OpenSSH on both.
2. In a terminal logged in as the account the phone should use, run
   `python3 herdr-pair.py [--session NAME]` (`python` on Windows). It refuses to run without a
   terminal on stdin, because approving a device needs a person at the keyboard. It prints a
   black-on-white QR code, about 73×37 cells, and the host-key fingerprint.
3. Scan it with the Herdr app, or with the Camera app, which opens `herdr://pair?…`. The phone
   shows the computer and account.
4. The computer asks:

   ```
   Pairing request from 'iPhone'
     device key SHA256:…
   Approve this device? [y/N]
   ```

   iOS reports only the model ("iPhone", "iPad") as the device name, so the fingerprint is what
   identifies the phone. The phone shows its own device key on the pairing screen. Approve only if
   it matches the prompt. Anything typed before the prompt appears is discarded, so only an answer
   given after reading it counts. `y` authorizes that exact key as
   `ssh-ed25519 … herdr-ios:<name>:<date>`. The phone pins the
   host key from the QR code (no TOFU prompt), saves the host and attaches.

What the helper does:

- It reads the host names (MagicDNS name, short name, `100.x` address) and the computer name
  from `tailscale status --json`, and the ed25519/ecdsa host keys from `ssh-keyscan 127.0.0.1`.
  `--host NAME` (repeatable) replaces the host names, and then the system hostname is the computer
  name. `--port` selects sshd's port. Characters the phone rejects (control, bidi and other format
  characters, separators, private use) are dropped from the computer name.
- It adds one line to the same authorized_keys file `authorize-key.sh` targets:

  ```
  restrict,expiry-time="…",from="100.64.0.0/10,fd7a:115c:a1e0::/48,127.0.0.1,::1",command="<python> <herdr-pair.py> --enroll=<id> --state=<dir>" ssh-ed25519 … herdr-pair:<id>
  ```

  The key only runs the enroll command, only from the tailnet or loopback, for 10 minutes.
  `restrict` refuses PTYs and all forwarding, and the forced command also replaces any exec or
  subsystem request. On Windows the command uses 8.3 short paths, so it needs no quoting under
  either cmd or PowerShell.
- The line is removed on approval, denial, expiry, Ctrl+C, SIGTERM/SIGHUP and errors. If the
  process is killed outright, `expiry-time` retires the key; so does the case where, on Windows,
  the SSH session that started the helper drops. To clean up early, delete lines ending in
  `herdr-pair:<id>`.
- The pairing id is single use. The first enroll claims it with an exclusive create, and any
  later enroll for that id gets `USED`. The approval is bound to the key shown in the prompt. The
  deadline is checked again at approval and before the key is written, so a late `y` authorizes
  nothing.
- Handoff files live in `~/.herdr-pair/` (macOS) or `%LOCALAPPDATA%\herdr-pair` (Windows), and
  the folder is empty between pairings. The helper never prints the one-time seed or the full URL.

The enroll command answers the phone with one token on stdout:

| Token | Exit | Meaning |
| --- | --- | --- |
| `OK` | 0 | Approved; the device key is authorized |
| `DENIED` | 3 | Denied at the prompt |
| `EXPIRED` | 4 | The 10-minute code or the 120 s approval window passed, or the answer came after the deadline |
| `INVALID` | 2 | The key isn't a bare `ssh-ed25519`, or the device name is empty, longer than 64 characters, or has control characters |
| `USED` | 5 | Another enroll already claimed this code; the prompt on the computer is for that device, so deny it |

When the Windows default shell is PowerShell, sshd reports 3, 4 and 5 as exit 1, so the token
is what counts.

Checks: `python3 scripts/herdr-pair.test.py` covers URL escaping, approve, claim-once,
deny, expiry, a late approval, invalid input, the terminal requirement, discarded typeahead and
signal cleanup. It uses a temp keys file, plus a
private loopback sshd on macOS for the forced-command probes. Adding
`--remote-windows volpe@supedupsilly 'C:\Users\volpe\herdr-pair-test'` runs the same probes
against the PC's real sshd from the Mac. The Windows ssh client hangs on exit when it runs without
a console, so the probes can't run on the PC itself. For an unattended end-to-end run, set
`HERDR_PAIR_TEST=1` and pass `--print-url`, which prints the URL instead of the QR code, and
answer the prompt from a pipe (`echo y | …`). Without that variable, `--print-url`, `--state`,
`--keys-file`, `--ttl` and a piped stdin are all refused.

## Authorize the device key by hand

Without the QR code, the app shows its Ed25519 public key for copying. Authorize it with
[`scripts/authorize-key.sh`](../scripts/authorize-key.sh):

```sh
scripts/authorize-key.sh local "ssh-ed25519 AAAA… iPhone"                     # on the Mac itself
scripts/authorize-key.sh james@jamess-macbook-pro ~/Downloads/ipad.pub         # a unix host over SSH
scripts/authorize-key.sh volpe@supedupsilly "ssh-ed25519 AAAA…" --platform windows
```

- Each key is written as `<type> <base64> herdr-ios[:<comment>]`, so `grep herdr-ios` finds every
  device key. Revoke a device by deleting its line.
- Running it again with the same key changes nothing. The script accepts only a bare public key on
  one line (no `command=` or other options).
- Reaching a remote host needs SSH access it already accepts (a password or another key). `local`
  needs none.
- **unix:** appends to `~/.ssh/authorized_keys` and sets `~/.ssh` to `700` and the file to `600`
  (and runs `restorecon` where SELinux is present).
- **windows:** detected automatically when `--platform` is omitted. An administrator whose
  `C:\ProgramData\ssh\sshd_config` has an active `Match Group administrators` block gets
  `C:\ProgramData\ssh\administrators_authorized_keys`, restricted to Administrators and SYSTEM.
  Otherwise, including administrators on a host where that block is commented out, the key goes
  in `%USERPROFILE%\.ssh\authorized_keys`, restricted to the user, SYSTEM and Administrators. The
  file is written as UTF-8 without a BOM, because sshd can't read the UTF-16 that `>>` and
  `Out-File` produce in Windows PowerShell.

`scripts/authorize-key.test.sh` checks the script locally without touching any host.

## Verify a host

From a Mac on the tailnet, run the same command the app runs:

```sh
ssh -tt you@mac 'exec "$SHELL" -lc herdr'                # full layout
ssh -tt you@mac 'stty cols 50; exec "$SHELL" -lc herdr'  # mobile layout
ssh -tt you@pc herdr
```

`ctrl+b q` returns to the local shell with the session still running (`herdr session list` on the
host).

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `zsh:1: command not found: herdr`, exit 127 | herdr's PATH entry is only in an interactive rc file | Move it to `~/.zprofile` / `~/.bash_profile`, or set the host's remote command to an absolute path |
| `The term 'herdr' is not recognized…` (Windows) | herdr isn't on the user PATH | Re-run the installer, then reconnect. With a PTY, Windows sshd reports exit status 0 here, so the only sign is the text |
| `ssh you@pc herdr --version` prints an older version than the desktop (admin account) | The user PATH still names the previous `releases\<version>` folder; elevated SSH sessions can't use the `Programs\Herdr\bin` junction | Point the PATH entry at the current `releases\<version>` folder |
| `Permission denied (publickey)` on Windows | Key in the wrong file for the `Match Group administrators` setting, a UTF-16 file, or loose ACLs | Run `authorize-key.sh`; check the `Match` block in `C:\ProgramData\ssh\sshd_config` |
| `Permission denied (publickey)` on unix | `~/.ssh` or `authorized_keys` writable by others, or a group-writable home directory | `authorize-key.sh` fixes `~/.ssh` and the file; `chmod go-w ~` |
| App refuses a changed host key | The host was reinstalled, or the name now points at another machine | Compare the fingerprint with `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` (macOS) or `C:\ProgramData\ssh\ssh_host_ed25519_key.pub` (Windows), then remove the pinned key in the app |
| New Windows panes print `The variable '$global:__HerdrOriginalPrompt' cannot be retrieved…` | A PowerShell profile turns on `Set-StrictMode`, which herdr's prompt integration doesn't tolerate; the prompt still works, but herdr stops tracking the pane's cwd | Keep `Set-StrictMode` out of profile scope (don't dot-source scripts that set it) |
| Desktop panes change size while the phone is attached | herdr sizes panes to the most recently attached client | Expected; they return when the phone detaches |
| Connection times out | Tailscale is off on the device, or the host is asleep | Turn the VPN on; `tailscale ping <host>` |
