# Lane: hosts (w29:p4)

Owned paths: `docs/host-setup.md`, `scripts/**`, `docs/lanes/hosts.md`. For pairing, that's
`scripts/herdr-pair.py`, `scripts/herdr-pair.test.py`, `scripts/qrcodegen.py` and the pairing
section of host-setup.

Stage: done. The attach commands are in [host-setup](../host-setup.md#attach-commands) and went to
transport (w29:p2) for `HerdrCommand.attach(platform:session:)` on 2026-09-21.

## Verdicts

Each check ran `ssh -tt` (pty-req + exec, `TERM=xterm-256color`) with the exact attach string.

**macOS: works.** Tested on this Mac (herdr 0.9.1 client, server 0.9.0), over `127.0.0.1` and
the tailnet address `100.103.220.58`:

- Bare `herdr` isn't found in an SSH exec, because PATH is `~/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin`.
  `exec "$SHELL" -lc '…'` resolves `/opt/homebrew/bin/herdr`.
- Throwaway session `hosts-probe`: renders the desktop layout. Typing works, and the remote pane
  sees `TERM=xterm-256color` and `HERDR_SESSION=hosts-probe`. `ctrl+b q` exits SSH with 0 and the
  session stays running.
- Reattaching at `stty cols 50` shows the mobile layout (header with tab and switch, full-width
  pane, 49 inner columns) with the earlier output intact.
- Window-change over SSH reflows live. The layout area goes 94×39 at 120 cols (desktop), 50×38 at
  50 cols (mobile), then 154×49 at 180 cols.
- `default` attached via bare `herdr` at the live client's size and rendered the running
  workspaces. After detach the panes were back at 296×79.

**Windows (supedupsilly, herdr 0.9.0, OpenSSH_for_Windows 9.5p2): works.**

- sshd's `DefaultShell` is Windows PowerShell 5.1. The profile loads on every exec, and
  `Set-StrictMode` is on through a dot-sourced script. The user PATH carries herdr, so bare
  `herdr` resolves.
- Throwaway `hosts-probe` inside ConPTY: renders the desktop layout. Typing works (`TERM=xterm-256color`,
  269 inner columns). `ctrl+b q` exits with 0.
- The server started over SSH (pid 9444, Windows session 0) was still running after the SSH
  session closed. Reattaches showed the earlier output.
- 50 cols gives the mobile layout (50×38). Resizing goes to desktop at 120 cols (94×39) and back.
- `cmd /c herdr session attach hosts-probe` also attaches, which covers hosts whose default shell
  is cmd.exe.
- `default` (console session 1, one idle Claude agent in `w1:p1`) attached via bare `herdr` at
  its own size (area 134×79 before and after). The agent stayed idle.
- A missing binary under a PTY exits **0** after printing `The term 'herdr-missing' is not
  recognized…` (exit 1 without a PTY). On macOS it exits 127.

Both `hosts-probe` sessions are stopped and deleted. No other session was touched.

**authorize-key.sh:** checked with `local` on this Mac, and on the PC with platform
auto-detection. There, an admin with the `Match Group administrators` block commented out lands
in `%USERPROFILE%\.ssh\authorized_keys` as UTF-8 without a BOM, with ACL
Administrators/SYSTEM/volpe. A second run reports `present`. `scripts/authorize-key.test.sh`
covers idempotency, perms, rejection of options and multi-line input, and SSH-failure exit status.
Mutation checks confirmed it fails on the earlier pipe and the earlier validation. Neighbor w29:p7
reviewed both fixes.

## QR pairing helper (ADR 0002)

Stage: done. `scripts/herdr-pair.py` (stdlib, Python 3.9+) plus vendored Nayuki `qrcodegen.py`
(MIT header kept, upstream sha256 `9f4ed1dd…c8ef`). Usage and guarantees are in
[host-setup › Pair with a QR code](../host-setup.md#pair-with-a-qr-code).

Evidence, 2026-09-21:

- `python3 scripts/herdr-pair.test.py --remote-windows volpe@supedupsilly 'C:\Users\volpe\herdr-pair-test'`
  on this Mac, with `/usr/bin/python3` 3.9: all 42 checks pass (after the review fixes below).
  - The local set covers RFC 3986 URL escaping, approve, claim-once (a second enroll gets `USED`)
    bound to the claiming key, deny, expiry, a late approval (EXPIRED, no key), a foreground
    deadline re-check, and invalid input. It also covers refusing a piped stdin outside test mode,
    discarding a `y` typed before the prompt (pty), and SIGINT/SIGTERM cleanup.
  - The same probes run against a private loopback sshd and against supedupsilly's real sshd
    over the tailnet (Windows PowerShell default shell). The one-time key rebuilt from the QR
    seed gets `INVALID` for `exec whoami`; `-t` gives "PTY allocation request failed"; the sftp
    subsystem runs the enroll; `-R` is refused and `-L` gives "administratively prohibited".
    Enroll then prints `OK`, the enrolled key logs in, the one-time key is rejected afterwards,
    and a denial leaves no key.
  - Both PC key files end byte-for-byte as they started.
- On the PC itself (Python 3.11), the local set passes too (21 checks; the pty and SIGTERM ones
  are unix-only; Windows exit for Ctrl+Break: 149).
- Mutation checks: making the claim non-exclusive, dropping the deadline re-check, and dropping
  the cleanup in `finally` each fail the suite.
- The QR renderer's half-block output, turned back into modules and decoded with CoreImage,
  returns the exact 345-char URL. It renders at 73×37 cells.
- The app lane paired the iPhone simulator with this Mac end to end through `simctl openurl`.
  That run found the `+`-for-space URL bug, now fixed with `quote_via=urllib.parse.quote` and
  covered by a check.

Incident: the first `--remote-windows` run's cleanup rewrote every candidate keys file, including
the PC's unused `C:\ProgramData\ssh\administrators_authorized_keys`. Its key text was unchanged,
but 2 CRLFs became LF. I restored it byte-for-byte from the 2026-09-16 shadow copy (sha256
`95A5B128…FEE6A`, ACL unchanged). The cleanup now touches only files that contain the test key
and keeps their line endings. The helper itself only ever wrote the per-user file.

Review (w29:p5): accept-with-fixes, both fixed.

- A second enroll for a claimed id now answers `USED` (exit 5) instead of `DENIED`. That lets
  the phone tell a leaked-code race apart from a human "no". The lead signed off in ADR 0002,
  and HerdrKit maps it (25ea9ad).
- Approval needs a TTY on stdin outside `HERDR_PAIR_TEST`, and typed-ahead input is flushed
  before the prompt (`tcflush` on unix, an `msvcrt` drain on Windows). A scripted `echo y |` or
  a stray keypress can no longer approve an unseen device.

Protocol notes (ADR 0002 as implemented):

1. Outcome `INVALID` (exit 2) covers a malformed key or name. The enroll's approval wait ends at
   the earlier of 120 s and the code's expiry.
2. The enroll accepts `ssh-ed25519 <b64>` with a trailing comment and ignores the comment.
3. Under Windows' PowerShell default shell, sshd reports exits 3, 4 and 5 as 1. HerdrKit decides on
   the token (transport, 88180ed).
4. If the helper is killed outright (SIGKILL, or the Windows SSH session that launched it
   dropping), the restricted line stays until its `expiry-time`. That's the documented backstop.

## Follow-ups

1. **herdr (upstream):** `WINDOWS_POWERSHELL_SHELL_INTEGRATION_COMMAND` (`src/pane.rs`) reads
   `$global:__HerdrOriginalPrompt` before setting it, so it throws under `Set-StrictMode` and the
   cwd integration never installs. Guard it with `Test-Path variable:global:__HerdrOriginalPrompt`.
   supedupsilly hits this because its profile dot-sources `opencode-private.ps1`, whose first line
   is `Set-StrictMode -Version Latest`.
2. **herdr upstream: Windows admin SSH PATH doesn't follow updates.** On supedupsilly the user
   PATH names `C:\Users\volpe\.herdr\packages\standalone\releases\0.9.0-x86_64-pc-windows-msvc`.
   The installer's `%LOCALAPPDATA%\Programs\Herdr\bin` (not on PATH) is not a shim. It is a
   junction to that same release folder, like `standalone\current`, created 2026-09-09 by the
   installer at medium integrity.
   - volpe's SSH sessions are elevated (`High Mandatory Level`, `IsInRole(Administrator)` True).
     Windows refuses to let them follow the junction: `[IO.Directory]::GetFiles` throws "The path
     cannot be traversed because it contains an untrusted mount point", and `Test-Path …\bin\herdr.exe`
     is False. So prepending it would add a dead entry, not an update-proof one. The user PATH was
     left unchanged (checked 2026-09-21).
   - `herdr update` runs the bundled `install.ps1`, which retargets the junctions and keeps three
     releases (`-Retain 3`). The versioned entry therefore survives two updates, but after the
     first one SSH runs the old client against the new server.
   - Upstream fix: give elevated sessions a launcher that isn't a medium-integrity junction, for
     example a real `herdr.exe` copy or a hardlink in the bin folder. Until then, repoint the PATH
     entry after each update on the PC.
3. **transport/app:** Windows PTY sessions report exit status 0 even when the command fails, so
   treat an early channel close as a failure and show the output.
