#!/usr/bin/env python3
"""Checks for herdr-pair.py.

    python3 scripts/herdr-pair.test.py     # temp keys file; plus a private loopback sshd on macOS/Linux
    python3 scripts/herdr-pair.test.py --remote-windows volpe@supedupsilly 'C:\\Users\\volpe\\herdr-pair-test'

Local checks (any OS): URL escaping, approve, claim-once with the approval bound to the claiming
key, deny, expiry before the claim, approval after the deadline, invalid input, and cleanup on a
signal. Over SSH: the one-time key rebuilt from the QR seed runs only the forced command (no other
exec, no PTY, no subsystem, no forwarding), enrolls a key that then logs in, stops working
afterwards, and a denial leaves nothing behind.

--remote-windows runs the SSH checks against a Windows host's real sshd from this machine, because
the Windows ssh client hangs on exit when it runs without a console, e.g. inside an SSH session.
It copies the helper to DIR, briefly adds its restricted line to the real authorized_keys, and
checks the file ends byte-for-byte as it started. It assumes PowerShell is sshd's default shell.
"""
import base64
import getpass
import importlib.util
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
HELPER = os.path.join(HERE, "herdr-pair.py")
WINDOWS = sys.platform == "win32"
TMP = tempfile.mkdtemp(prefix="herdr-pair-test-")
USER = getpass.getuser()
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def ssh_string(b):
    return len(b).to_bytes(4, "big") + b


def keygen(name):
    path = os.path.join(TMP, name)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", path], check=True)
    with open(path + ".pub") as f:
        return path, " ".join(f.read().split()[:2])


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Helper:
    def __init__(self, port, keys=None, ttl=None, answer=None, state=None):
        self.state = state or tempfile.mkdtemp(dir=TMP)
        args = [sys.executable, HELPER, "--print-url", "--host", "127.0.0.1", "--port", str(port),
                "--state", self.state]
        if keys:
            args += ["--keys-file", keys]
        if ttl:
            args += ["--ttl", str(ttl)]
        flags = subprocess.CREATE_NEW_PROCESS_GROUP if WINDOWS else 0
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                                     env={**os.environ, "HERDR_PAIR_TEST": "1"}, creationflags=flags)
        self.url = self.proc.stdout.readline().strip()
        self.q = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlparse(self.url).query).items()}
        self.id = self.q.get("id", "")
        if answer is not None:
            self.answer(answer)

    def answer(self, text):
        self.proc.stdin.write(text + "\n")
        self.proc.stdin.flush()

    def wait(self):
        try:
            return self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            return None

    def stop(self):
        self.proc.send_signal(signal.CTRL_BREAK_EVENT if WINDOWS else signal.SIGINT)
        self.wait()

    def leftovers(self):
        return [f for f in os.listdir(self.state) if f.startswith(self.id)]


def enroll_direct(helper, key_line, name="Test Phone", wait=True):
    proc = subprocess.Popen([sys.executable, HELPER, f"--enroll={helper.id}", f"--state={helper.state}"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    proc.stdin.write(f"{key_line}\n{name}\n")
    proc.stdin.close()
    if not wait:
        return proc
    return proc.stdout.read().strip().splitlines()[-1:] or [""], proc.wait(timeout=180)


def text(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def one_time_key_file(helper, keys_text):
    """Rebuild the one-time private key from the QR seed, as the phone does."""
    line = next(l for l in keys_text.splitlines() if f"herdr-pair:{helper.id}" in l)
    pub = base64.b64decode(line.split()[-2])[-32:]
    seed = base64.urlsafe_b64decode(helper.q["k"] + "==")
    check = os.urandom(4)
    private = check + check + ssh_string(b"ssh-ed25519") + ssh_string(pub) + ssh_string(seed + pub) + ssh_string(b"")
    private += bytes(range(1, 1 + (-len(private) % 8)))
    body = (b"openssh-key-v1\0" + ssh_string(b"none") + ssh_string(b"none") + ssh_string(b"") +
            (1).to_bytes(4, "big") + ssh_string(ssh_string(b"ssh-ed25519") + ssh_string(pub)) + ssh_string(private))
    b64 = base64.b64encode(body).decode()
    path = os.path.join(TMP, f"onetime-{helper.id}")
    with open(path, "w", newline="\n") as f:
        f.write("-----BEGIN OPENSSH PRIVATE KEY-----\n" +
                "\n".join(b64[i:i + 70] for i in range(0, len(b64), 70)) +
                "\n-----END OPENSSH PRIVATE KEY-----\n")
    if WINDOWS:
        subprocess.run(["icacls", path, "/inheritance:r", "/grant", f"{USER}:F"], check=True, capture_output=True)
    else:
        os.chmod(path, 0o600)
    return path


def ssh(port, key, *extra, stdin="", timeout=60):
    args = ["ssh", "-p", str(port), "-i", key, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=no", "-o", f"UserKnownHostsFile={os.devnull}",
            "-o", "LogLevel=ERROR", *extra]
    return subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)


def private_sshd(keys):
    """A throwaway sshd on loopback reading keys, or None where one can't run (Windows, no sshd)."""
    sshd = shutil.which("sshd") or "/usr/sbin/sshd"
    if WINDOWS or not os.path.exists(sshd):
        return None, None
    port = free_port()
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", os.path.join(TMP, "hostkey")], check=True)
    config = os.path.join(TMP, "sshd_config")
    with open(config, "w") as f:
        f.write(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {TMP}/hostkey\nAuthorizedKeysFile {keys}\n"
                f"PasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\n"
                f"StrictModes no\nPidFile {TMP}/sshd.pid\nSubsystem sftp internal-sftp\n")
    proc = subprocess.Popen([sshd, "-D", "-e", "-f", config], stderr=open(os.path.join(TMP, "sshd.log"), "w"))
    for _ in range(50):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return proc, port
        time.sleep(0.1)
    proc.kill()
    return None, None


def url_checks():
    spec = importlib.util.spec_from_file_location("herdr_pair", HELPER)
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    url = helper.pairing_url([("n", "James's MacBook Pro"), ("fp", "SHA256:a+b/c")])
    check("James%27s%20MacBook%20Pro" in url and "a%2Bb%2Fc" in url and "+" not in url,
          f"URL uses RFC 3986 escaping, no literal '+' ({url})")


def local_checks(port, phone_a, phone_b):
    keys = os.path.join(TMP, "authorized_keys")

    h = Helper(port, keys, answer="y")
    check(h.url.startswith("herdr://pair?v=1&") and len(h.id) == 22, "helper prints a v1 pairing URL")
    line = next((l for l in text(keys).splitlines() if f"herdr-pair:{h.id}" in l), "")
    check(line.startswith('restrict,expiry-time="') and 'from="100.64.0.0/10,fd7a:115c:a1e0::/48,127.0.0.1,::1"' in line
          and f"--enroll={h.id}" in line, "one-time line is restrict + expiry-time + from= + forced command")
    out, code = enroll_direct(h, phone_a)
    check((out, code) == (["OK"], 0) and h.wait() == 0, "approve: enroll prints OK, exit 0")
    check(phone_a.split()[1] in text(keys) and "herdr-ios:Test-Phone:" in text(keys), "approve: device key authorized with herdr-ios tag")
    check(f"herdr-pair:{h.id}" not in text(keys) and not h.leftovers(), "approve: one-time line and state files removed")

    h = Helper(port, keys)
    first = enroll_direct(h, phone_b, "First", wait=False)
    while not os.path.exists(os.path.join(h.state, h.id + ".claim")):
        time.sleep(0.05)
    out, code = enroll_direct(h, phone_a, "Second")
    check((out, code) == (["DENIED"], 3), "claim-once: a second enroll for the id is refused")
    h.answer("y")
    check(first.stdout.read().strip() == "OK" and first.wait() == 0 and h.wait() == 0, "claim-once: the first enroll completes")
    check(text(keys).count(phone_b.split()[1]) == 1 and "herdr-ios:First:" in text(keys) and "Second" not in text(keys),
          "claim-once: exactly the claiming key was authorized")

    before = text(keys)
    h = Helper(port, keys, answer="n")
    out, code = enroll_direct(h, keygen("denied")[1])
    check((out, code) == (["DENIED"], 3) and h.wait() == 3, "deny: enroll prints DENIED, exit 3")
    check(text(keys) == before and not h.leftovers(), "deny: no key added, one-time line and state removed")

    h = Helper(port, keys, ttl=2)
    time.sleep(3)
    out, code = enroll_direct(h, keygen("late")[1])
    check((out, code) == (["EXPIRED"], 4) and h.wait() == 4, "expiry: an enroll after the TTL gets EXPIRED, exit 4")
    check(text(keys) == before and not h.leftovers(), "expiry: no key added, one-time line and state removed")

    h = Helper(port, keys, ttl=3)
    slow = enroll_direct(h, keygen("slow")[1], "Slow", wait=False)
    time.sleep(4)
    h.answer("y")
    check(slow.stdout.read().strip() == "EXPIRED" and slow.wait() == 4 and h.wait() == 4,
          "approval after the deadline: EXPIRED, exit 4")
    check(text(keys) == before and not h.leftovers(), "approval after the deadline: no key written")

    # The foreground re-checks the deadline itself, even when no enroll is there to expire it.
    h = Helper(port, keys, ttl=3)
    with open(os.path.join(h.state, h.id + ".claim"), "w") as f:
        f.write('{"key": "%s", "name": "Direct", "t": %f}\n' % (keygen("direct")[1], time.time()))
    time.sleep(4)
    h.answer("y")
    check(h.wait() == 4 and text(keys) == before, "foreground refuses to authorize past the deadline")

    h = Helper(port, keys, answer="y")
    out, code = enroll_direct(h, "ssh-rsa AAAAB3NzaC1yc2E bad")
    check((out, code) == (["INVALID"], 2), "invalid key: INVALID, exit 2, id not consumed")
    out, code = enroll_direct(h, phone_a, "bad\x1bname")
    check((out, code) == (["INVALID"], 2), "control characters in the device name: INVALID")
    out, code = enroll_direct(h, phone_a, "Again")
    check((out, code) == (["OK"], 0) and h.wait() == 0, "a valid enroll after invalid ones still pairs")

    h = Helper(port, keys)
    while f"herdr-pair:{h.id}" not in text(keys):
        time.sleep(0.05)
    h.proc.send_signal(signal.CTRL_BREAK_EVENT if WINDOWS else signal.SIGINT)
    code = h.wait()
    check(code is not None and f"herdr-pair:{h.id}" not in text(keys) and not h.leftovers(),
          f"signal: one-time line and state removed (exit {code})")
    if not WINDOWS:
        h = Helper(port, keys)
        while f"herdr-pair:{h.id}" not in text(keys):
            time.sleep(0.05)
        h.proc.terminate()
        check(h.wait() == 143 and f"herdr-pair:{h.id}" not in text(keys), "SIGTERM: one-time line removed (exit 143)")


def ssh_checks(label, port, target, start_helper, keys_text, remove_blob):
    """Everything a stolen QR could try with the one-time key, then a real enroll and a deny."""
    phone_key, phone_pub = keygen(f"phone-{label}")
    user = target.split("@")[0]
    h = start_helper("y")
    try:
        one_time = one_time_key_file(h, keys_text())
        r = ssh(port, one_time, target, "whoami")
        check(r.stdout.strip().splitlines()[-1:] == ["INVALID"] and user not in r.stdout,
              f"{label}: exec `whoami` runs only the enroll ({r.stdout.strip()!r})")
        r = ssh(port, one_time, "-tt", target, "whoami")
        check("PTY allocation request failed" in r.stderr and user not in r.stdout,
              f"{label}: -t is refused ({r.stderr.strip()[:60]!r})")
        r = ssh(port, one_time, "-s", target, "sftp")
        check("INVALID" in r.stdout, f"{label}: the sftp subsystem gets the forced command ({r.stdout.strip()!r})")
        r = ssh(port, one_time, "-N", "-o", "ExitOnForwardFailure=yes", "-R", f"127.0.0.1:{free_port()}:127.0.0.1:{port}", target)
        check(r.returncode != 0 and "forwarding failed" in r.stderr, f"{label}: -R is refused ({r.stderr.strip()[:60]!r})")
        fwd = free_port()
        tunnel = subprocess.Popen(["ssh", "-p", str(port), "-i", one_time, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                                   "-o", "StrictHostKeyChecking=no", "-o", f"UserKnownHostsFile={os.devnull}",
                                   "-N", "-L", f"127.0.0.1:{fwd}:127.0.0.1:{port}", target],
                                  stderr=subprocess.PIPE, text=True)
        time.sleep(4)
        with socket.socket() as s:
            s.settimeout(5)
            try:
                s.connect(("127.0.0.1", fwd))
                banner = s.recv(64)
            except OSError:
                banner = b""
        time.sleep(1)
        tunnel.terminate()
        refusal = [l for l in tunnel.communicate()[1].splitlines() if "open failed" in l or "prohibited" in l]
        check(not banner.startswith(b"SSH-") and bool(refusal), f"{label}: -L is refused ({refusal[:1]})")
        r = ssh(port, one_time, target, "anything", stdin=f"{phone_pub}\n{label} phone\n")
        check(r.stdout.strip().splitlines()[-1:] == ["OK"] and h.wait() == 0,
              f"{label}: enroll over SSH prints OK (ssh exit {r.returncode})")
        r = ssh(port, phone_key, target, "whoami")
        check(user in r.stdout, f"{label}: the enrolled device key logs in ({r.stdout.strip()!r})")
        r = ssh(port, one_time, target, "x")
        check(r.returncode == 255 and "Permission denied" in r.stderr, f"{label}: the one-time key no longer authenticates")

        denied_pub = keygen(f"denied-{label}")[1]
        h = start_helper("n")
        r = ssh(port, one_time_key_file(h, keys_text()), target, "anything", stdin=f"{denied_pub}\nDenied\n")
        h.wait()
        check(r.stdout.strip().splitlines()[-1:] == ["DENIED"] and denied_pub.split()[1] not in keys_text()
              and f"herdr-pair:{h.id}" not in keys_text(),
              f"{label}: deny over SSH prints DENIED and leaves no key (ssh exit {r.returncode})")
    finally:
        if h.proc.poll() is None:  # interrupt, not kill, so the helper's own cleanup runs
            h.stop()
        remove_blob(phone_pub.split()[1])


class RemoteHelper(Helper):
    """The helper on a Windows host (PowerShell default shell), driven over SSH from here."""
    def __init__(self, target, remote_dir, answer):
        command = f"$env:HERDR_PAIR_TEST='1'; python {remote_dir}\\herdr-pair.py --print-url"
        self.proc = subprocess.Popen(["ssh", "-o", "BatchMode=yes", target, command], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True)
        self.url = self.proc.stdout.readline().strip()
        self.q = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlparse(self.url).query).items()}
        self.id = self.q.get("id", "")
        self.answer(answer)

    def stop(self):
        self.answer("n")  # killing the SSH session would kill the helper before its cleanup
        self.wait()


def powershell(target, script):
    encoded = base64.b64encode(script.encode("utf-16-le")).decode()
    return subprocess.run(["ssh", "-o", "BatchMode=yes", target, "powershell", "-NoProfile", "-NonInteractive",
                           "-EncodedCommand", encoded], capture_output=True, text=True, timeout=60).stdout


def remote_windows_checks(target, remote_dir):
    files = '"$env:USERPROFILE\\.ssh\\authorized_keys", "$env:ProgramData\\ssh\\administrators_authorized_keys"'
    snapshot = lambda: powershell(target, f"foreach ($f in {files}) {{ if (Test-Path $f) {{ (Get-FileHash $f).Hash }} }}")
    before = snapshot()
    powershell(target, f'New-Item -ItemType Directory -Force "{remote_dir}" | Out-Null')
    subprocess.run(["scp", "-q", "-o", "BatchMode=yes", HELPER, os.path.join(HERE, "qrcodegen.py"),
                    f"{target}:{remote_dir.replace(chr(92), '/')}/"], check=True, timeout=60)

    def remove_blob(blob):
        # Only files holding the test key, line endings kept: nothing else may change by a byte.
        powershell(target, f"foreach ($f in {files}) {{ if ((Test-Path $f) -and (Select-String -Path $f "
                           f"-SimpleMatch '{blob}' -Quiet)) {{ $t = [IO.File]::ReadAllText($f); $kept = "
                           f"([regex]::Split($t, '(?<=\\n)') | Where-Object {{ -not $_.Contains('{blob}') }}) -join ''; "
                           f"$s = [IO.File]::Open($f, 'Open', 'Write'); $bytes = (New-Object Text.UTF8Encoding $false)"
                           f".GetBytes($kept); $s.SetLength(0); $s.Write($bytes, 0, $bytes.Length); $s.Close() }} }}")

    ssh_checks("windows", 22, target, lambda answer: RemoteHelper(target, remote_dir, answer),
               lambda: powershell(target, f"foreach ($f in {files}) {{ if (Test-Path $f) {{ Get-Content $f }} }}"),
               remove_blob)
    check(snapshot() == before and before, "windows: authorized_keys files are byte-for-byte what they were")


def main():
    keys = os.path.join(TMP, "authorized_keys")
    open(keys, "w").close()
    sshd, port = private_sshd(keys)
    try:
        url_checks()
        local_checks(port or 22, keygen("phone-a")[1], keygen("phone-b")[1])
        if sshd:
            ssh_checks("private sshd", port, f"{USER}@127.0.0.1", lambda answer: Helper(port, keys, answer=answer),
                       lambda: text(keys), lambda blob: None)
        if "--remote-windows" in sys.argv:
            i = sys.argv.index("--remote-windows")
            remote_windows_checks(sys.argv[i + 1], sys.argv[i + 2])
    finally:
        if sshd:
            sshd.terminate()
        shutil.rmtree(TMP, ignore_errors=True)
    print(f"herdr-pair: {'FAILED ' + str(len(failures)) if failures else 'ok'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
