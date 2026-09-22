# Lane: hosts (w29:p4)

Owned paths: `docs/host-setup.md`, `scripts/**`, `docs/lanes/hosts.md`.

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

## Follow-ups

1. **herdr (upstream):** `WINDOWS_POWERSHELL_SHELL_INTEGRATION_COMMAND` (`src/pane.rs`) reads
   `$global:__HerdrOriginalPrompt` before setting it, so it throws under `Set-StrictMode` and the
   cwd integration never installs. Guard it with `Test-Path variable:global:__HerdrOriginalPrompt`.
   supedupsilly hits this because its profile dot-sources `opencode-private.ps1`, whose first line
   is `Set-StrictMode -Version Latest`.
2. **supedupsilly:** the user PATH points at
   `C:\Users\volpe\.herdr\packages\standalone\releases\0.9.0-x86_64-pc-windows-msvc`, not
   `%LOCALAPPDATA%\Programs\Herdr\bin` (which exists but isn't on PATH). An update that prunes the
   0.9.0 folder takes herdr off the SSH PATH. Re-running `install.ps1` fixes it. It was left alone
   because the PC's default session has a live agent.
3. **transport/app:** Windows PTY sessions report exit status 0 even when the command fails, so
   treat an early channel close as a failure and show the output.
