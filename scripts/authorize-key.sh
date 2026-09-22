#!/bin/sh
# Authorize a herdr-ios device public key on a host, idempotently.
#
#   scripts/authorize-key.sh <ssh-target|local> <pubkey-file-or-string> [--platform unix|windows]
#
#   scripts/authorize-key.sh local "ssh-ed25519 AAAA... iPhone"          # this Mac, no SSH
#   scripts/authorize-key.sh james@jamess-macbook-pro ~/Downloads/ipad.pub
#   scripts/authorize-key.sh volpe@supedupsilly "ssh-ed25519 AAAA..." --platform windows
#
# The line is written as "<type> <base64> herdr-ios[:<original comment>]" so every device key is
# easy to find (grep herdr-ios) and revoke. A key already present (matched on its base64) is left
# alone. unix: ~/.ssh 700, authorized_keys 600. windows: an admin user whose sshd_config has an
# active "Match Group administrators" block gets administrators_authorized_keys (Administrators +
# SYSTEM only); everyone else gets %USERPROFILE%\.ssh\authorized_keys (user + SYSTEM +
# Administrators). The platform is detected over SSH when --platform is omitted.
set -eu

usage() { echo "usage: $0 <ssh-target|local> <pubkey-file-or-string> [--platform unix|windows]" >&2; exit 2; }
[ $# -eq 2 ] || [ $# -eq 4 ] || usage
target=$1 key=$2 platform=
if [ $# -eq 4 ]; then
  [ "$3" = --platform ] || usage
  platform=$4
fi
case $platform in ''|unix|windows) ;; *) usage ;; esac

[ -f "$key" ] && key=$(head -n 1 "$key" | tr -d "\r")
bad() { echo "not a bare OpenSSH public key (no options, one line): $key" >&2; exit 1; }
case $key in *"
"*) bad ;; esac
set -f
set -- $key
[ $# -ge 2 ] || bad
type=$1 blob=$2
shift 2
# ssh-keygen alone accepts an authorized_keys options prefix, so pin both fields before trusting
# them in a remote command line.
case $type in
  ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
  sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
  *) bad ;;
esac
printf '%s' "$blob" | grep -Eqx '[A-Za-z0-9+/]+={0,2}' || bad
printf '%s %s\n' "$type" "$blob" | ssh-keygen -l -f - >/dev/null 2>&1 || bad
orig=$(printf '%s' "$*" | tr -c 'A-Za-z0-9._@:-' '-' | sed 's/^-*//; s/-*$//')
case $orig in
  herdr-ios*) comment=$orig ;;
  '') comment=herdr-ios ;;
  *) comment=herdr-ios:$orig ;;
esac

# Runs under sh on the host (or locally for "local"); args: type blob comment.
UNIX_SCRIPT='set -eu
umask 077
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
f=$HOME/.ssh/authorized_keys
touch "$f"
chmod 600 "$f"
if grep -qF -- "$2" "$f"; then
  echo "present $f"
else
  if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then echo >> "$f"; fi
  printf "%s %s %s\n" "$1" "$2" "$3" >> "$f"
  echo "added $f"
fi
if command -v restorecon >/dev/null 2>&1; then restorecon -R "$HOME/.ssh" 2>/dev/null || true; fi'

WINDOWS_SCRIPT='$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$line = "__TYPE__ __BLOB__ __COMMENT__"
$blob = "__BLOB__"
$isAdmin = [bool](whoami /groups /fo csv | ConvertFrom-Csv | Where-Object SID -eq "S-1-5-32-544")
$cfg = Join-Path $env:ProgramData "ssh\sshd_config"
$adminBlock = $isAdmin -and (Test-Path $cfg) -and (Select-String -Path $cfg -Pattern "^\s*Match\s+Group\s+administrators\b" -Quiet)
if ($adminBlock) {
  $f = Join-Path $env:ProgramData "ssh\administrators_authorized_keys"
  $grants = @("*S-1-5-32-544:F", "*S-1-5-18:F")
} else {
  $dir = Join-Path $env:USERPROFILE ".ssh"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $f = Join-Path $dir "authorized_keys"
  $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $grants = @("*${me}:F", "*S-1-5-18:F", "*S-1-5-32-544:F")
}
$text = if (Test-Path $f) { [IO.File]::ReadAllText($f) } else { "" }
if ($text.Contains($blob)) { $state = "present" } else {
  if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
  # sshd cannot parse UTF-16, which is what Out-File and >> write in Windows PowerShell.
  [IO.File]::WriteAllText($f, $text + $line + "`n", (New-Object Text.UTF8Encoding $false))
  $state = "added"
}
$icaclsArgs = @($f, "/inheritance:r") + ($grants | ForEach-Object { "/grant", $_ })
& icacls @icaclsArgs | Out-Null
if ($LASTEXITCODE) { throw "icacls failed on $f" }
"$state $f"'

if [ "$target" = local ]; then
  [ -z "$platform" ] || [ "$platform" = unix ] || usage
  exec sh -c "$UNIX_SCRIPT" sh "$type" "$blob" "$comment"
fi

ssh_() { ssh -o ConnectTimeout=10 "$target" "$@"; }

if [ -z "$platform" ]; then
  # Windows answers uname with an error, or MINGW/MSYS/CYGWIN when Git's tools are on PATH.
  case $(ssh_ uname -s 2>/dev/null || true) in
    Darwin|Linux|*BSD*|SunOS) platform=unix ;;
    *) platform=windows ;;
  esac
fi

if [ "$platform" = unix ]; then
  # type, blob and comment are limited to [A-Za-z0-9+/=._@:-], so they survive the remote shell.
  printf '%s\n' "$UNIX_SCRIPT" | ssh_ sh -s -- "$type" "$blob" "$comment"
else
  ps=$(printf '%s' "$WINDOWS_SCRIPT" | sed "s|__TYPE__|$type|; s|__BLOB__|$blob|g; s|__COMMENT__|$comment|")
  enc=$(printf '%s' "$ps" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  # Assign first: a pipeline would report tr's status and hide an SSH failure.
  out=$(ssh_ powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "$enc")
  printf '%s\n' "$out" | tr -d '\r'
fi
