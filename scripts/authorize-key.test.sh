#!/bin/sh
# Local regression check for authorize-key.sh; touches no real host or ~/.ssh.
#   scripts/authorize-key.test.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ssh-keygen -q -t ed25519 -N '' -C 'test device' -f "$tmp/k"
pub=$(cat "$tmp/k.pub")
fail() { echo "FAIL: $*" >&2; exit 1; }

# Idempotent append with the herdr-ios tag, correct perms, and a repaired trailing newline.
mkdir -p "$tmp/home/.ssh"
printf 'ssh-rsa AAAAexisting' > "$tmp/home/.ssh/authorized_keys"
HOME=$tmp/home "$here/authorize-key.sh" local "$pub" | grep -q '^added ' || fail "first run did not add"
HOME=$tmp/home "$here/authorize-key.sh" local "$tmp/k.pub" | grep -q '^present ' || fail "second run was not a no-op"
[ "$(grep -c herdr-ios:test-device "$tmp/home/.ssh/authorized_keys")" = 1 ] || fail "tagged line count"
[ "$(wc -l < "$tmp/home/.ssh/authorized_keys" | tr -d ' ')" = 2 ] || fail "existing line was not newline-terminated"
[ "$(stat -f %Lp "$tmp/home/.ssh" 2>/dev/null || stat -c %a "$tmp/home/.ssh")" = 700 ] || fail ".ssh perms"
[ "$(stat -f %Lp "$tmp/home/.ssh/authorized_keys" 2>/dev/null || stat -c %a "$tmp/home/.ssh/authorized_keys")" = 600 ] || fail "authorized_keys perms"

# Options prefixes and multi-line input are refused before anything reaches a remote shell.
for key in "command=\"\$(printf\${IFS}PROBE)\" $pub" "no-pty $pub" "$pub
$pub" "ssh-ed25519 not/base64!"; do
  if HOME=$tmp/home "$here/authorize-key.sh" local "$key" 2>/dev/null; then fail "accepted: $key"; fi
done

# An SSH failure is the script's failure on both platforms (ssh mocked to exit 42).
mkdir "$tmp/bin"
printf '#!/bin/sh\nexit 42\n' > "$tmp/bin/ssh"
chmod +x "$tmp/bin/ssh"
for platform in unix windows; do
  code=0
  PATH=$tmp/bin:$PATH "$here/authorize-key.sh" host "$pub" --platform "$platform" >/dev/null 2>&1 || code=$?
  [ "$code" = 42 ] || fail "$platform ssh failure returned $code"
done
echo "authorize-key: ok"
