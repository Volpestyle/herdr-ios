#!/usr/bin/env python3
"""Pair a phone running the Herdr app with this computer (docs/adr/0002-qr-pairing.md, v1).

    python3 herdr-pair.py [--session NAME] [--host NAME ...] [--port 22]

Shows a QR code. The phone scans it and SSHes in with the one-time key it carries. The key only
runs `herdr-pair.py --enroll`, only from the tailnet or loopback, and only for 10 minutes. That
command hands over the phone's device key, and you approve it here. The one-time key is removed
on every exit path; sshd's expiry-time is the backstop if this process dies.

Stdlib only, Python 3.9+, macOS and Windows. Keep qrcodegen.py next to this file.
Approval needs a person at a terminal: stdin must be a TTY, and anything typed before the prompt
is discarded. Test-only (need HERDR_PAIR_TEST=1): --print-url, --state, --keys-file, --ttl, and
answering the prompt from a pipe (`echo y | ... --print-url`) for unattended end-to-end runs.
"""
import argparse
import base64
import getpass
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.parse

WINDOWS = sys.platform == "win32"
TTL = 600
DECISION_WAIT = 120
TAILNET_AND_LOOPBACK = "100.64.0.0/10,fd7a:115c:a1e0::/48,127.0.0.1,::1"
ID_RE = re.compile(r"^[A-Za-z0-9_-]{22}$")
SESSION_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
HOST_RE = re.compile(r"^[A-Za-z0-9.:-]{1,253}$")
ED25519_PREFIX = b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"
HOST_KEY_TYPES = ("ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521")
OUTCOMES = {0: "OK", 2: "INVALID", 3: "DENIED", 4: "EXPIRED", 5: "USED"}


def die(message):
    print(f"herdr-pair: {message}", file=sys.stderr)
    sys.exit(1)


# --- keys ---------------------------------------------------------------------------------------

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def fingerprint(blob):
    return "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).rstrip(b"=").decode()


def ed25519_blob(line):
    """The wire blob of an 'ssh-ed25519 <base64> [comment]' line, or None."""
    parts = line.split()
    if len(parts) < 2 or parts[0] != "ssh-ed25519":
        return None
    try:
        blob = base64.b64decode(parts[1], validate=True)
    except ValueError:
        return None
    return blob if len(blob) == 51 and blob.startswith(ED25519_PREFIX) else None


def _ssh_string(buf, i):
    n = int.from_bytes(buf[i:i + 4], "big")
    return buf[i + 4:i + 4 + n], i + 4 + n


def mint_one_time_key():
    """(seed, public blob) of a fresh Ed25519 key. The private key file lives only for the read."""
    tmp = tempfile.mkdtemp(prefix="herdr-pair-")
    try:
        path = os.path.join(tmp, "k")
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", path],
                       check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
        with open(path) as f:
            pem = f.read()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    body = base64.b64decode("".join(l for l in pem.splitlines() if not l.startswith("-----")))
    magic = b"openssh-key-v1\0"
    i = len(magic)
    cipher, i = _ssh_string(body, i)
    _, i = _ssh_string(body, i)  # kdf name
    _, i = _ssh_string(body, i)  # kdf options
    i += 4  # key count
    public, i = _ssh_string(body, i)
    private, i = _ssh_string(body, i)
    j = 8  # two check ints
    kind, j = _ssh_string(private, j)
    pub, j = _ssh_string(private, j)
    secret, j = _ssh_string(private, j)
    if not body.startswith(magic) or cipher != b"none" or kind != b"ssh-ed25519" \
            or len(secret) != 64 or secret[32:] != pub or public != ED25519_PREFIX + pub:
        die("ssh-keygen produced an unexpected key format")
    return secret[:32], public


# --- host facts ---------------------------------------------------------------------------------

def tailnet_identity():
    """(hostnames preferred first, display name) from `tailscale status --json`."""
    candidates = [shutil.which("tailscale"), "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                  r"C:\Program Files\Tailscale\tailscale.exe"]
    exe = next((c for c in candidates if c and os.path.exists(c)), None)
    if not exe:
        die("Tailscale CLI not found; install Tailscale or pass --host with this computer's MagicDNS name")
    run = subprocess.run([exe, "status", "--json"], capture_output=True, text=True, timeout=20)
    if run.returncode:
        die(f"`tailscale status` failed: {run.stderr.strip()}")
    me = json.loads(run.stdout).get("Self") or {}
    fqdn = (me.get("DNSName") or "").rstrip(".").lower()
    names = [fqdn, fqdn.split(".")[0]] if fqdn else []
    names += [ip for ip in me.get("TailscaleIPs") or [] if ip.startswith("100.")][:1]
    if not names:
        die("this computer has no tailnet name or address; is Tailscale connected?")
    return names, me.get("HostName") or socket.gethostname()


def host_key_fingerprints(port):
    """SHA256 fingerprints of this computer's ed25519/ecdsa host keys, as sshd serves them."""
    scan = subprocess.run(["ssh-keyscan", "-T", "5", "-p", str(port), "-t", "ed25519,ecdsa", "127.0.0.1"],
                          capture_output=True, text=True, timeout=30)
    fps = []
    for line in scan.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in HOST_KEY_TYPES:
            fps.append(fingerprint(base64.b64decode(parts[2])))
    if not fps:
        die(f"no ed25519/ecdsa host key answered on 127.0.0.1:{port}; "
            "is Remote Login (macOS) or OpenSSH Server (Windows) on?")
    return fps[:3]


def authorized_keys_path():
    """The file scripts/authorize-key.sh targets; keep the two in step."""
    if not WINDOWS:
        return os.path.expanduser("~/.ssh/authorized_keys")
    groups = subprocess.run(["whoami", "/groups", "/fo", "csv"], capture_output=True, text=True).stdout
    if "S-1-5-32-544" in groups:
        config = os.path.join(os.environ.get("PROGRAMDATA", r"C:\ProgramData"), "ssh", "sshd_config")
        try:
            with open(config, encoding="utf-8", errors="replace") as f:
                admin_block = re.search(r"(?im)^\s*Match\s+Group\s+administrators\b", f.read())
        except FileNotFoundError:
            admin_block = None
        if admin_block:
            return os.path.join(os.environ.get("PROGRAMDATA", r"C:\ProgramData"), "ssh",
                                "administrators_authorized_keys")
    return os.path.join(os.environ["USERPROFILE"], ".ssh", "authorized_keys")


def secure_keys_file(path):
    if not WINDOWS:
        os.chmod(os.path.dirname(path), 0o700)
        os.chmod(path, 0o600)
        if shutil.which("restorecon"):
            subprocess.run(["restorecon", "-R", os.path.dirname(path)], capture_output=True)
        return
    grants = ["*S-1-5-32-544:F", "*S-1-5-18:F"]
    if not path.lower().endswith("administrators_authorized_keys"):
        me = subprocess.run(["whoami", "/user", "/fo", "csv", "/nh"], capture_output=True, text=True).stdout
        grants.append("*" + me.strip().split(",")[-1].strip('"') + ":F")
    args = ["icacls", path, "/inheritance:r"]
    for grant in grants:
        args += ["/grant", grant]
    subprocess.run(args, check=True, capture_output=True)


def add_key_line(path, line, blob_b64):
    """Append line unless that key is already there. UTF-8 without BOM: sshd can't read UTF-16."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a+b") as f:
        f.seek(0)
        data = f.read()
        if blob_b64.encode() not in data:
            if data and not data.endswith(b"\n"):
                f.write(b"\n")
            f.write(line.encode() + b"\n")
    secure_keys_file(path)


def remove_key_lines(path, blob_b64):
    """Drop every line carrying that key, rewriting in place so the file keeps its mode/ACL."""
    try:
        f = open(path, "r+b")
    except FileNotFoundError:
        return
    with f:
        data = f.read()
        kept = b"".join(l for l in data.splitlines(keepends=True) if blob_b64.encode() not in l)
        if kept != data:
            f.seek(0)
            f.write(kept)
            f.truncate()


def forced_command(pair_id, state):
    args = [sys.executable, os.path.abspath(__file__), f"--enroll={pair_id}", f"--state={state}"]
    if WINDOWS:
        # sshd runs this through its default shell, cmd or PowerShell, which quote differently,
        # so the command carries no quotes at all: 8.3 short names drop the spaces.
        import ctypes
        def short(path):
            buf = ctypes.create_unicode_buffer(1024)
            return buf.value if ctypes.windll.kernel32.GetShortPathNameW(path, buf, 1024) else path
        args = [short(args[0]), short(args[1]), args[2], "--state=" + short(state)]
        command = " ".join(args)
        if any(" " in a for a in args):
            die(f"paths with spaces and no 8.3 short name can't go in the forced command: {command}")
    else:
        command = " ".join(shlex.quote(a) for a in args)
    if '"' in command:
        die(f"forced command can't contain a double quote: {command}")
    return command


# --- state files --------------------------------------------------------------------------------
# <id>.offer    foreground, while the offer stands: {"expires": epoch seconds}
# <id>.claim    the one enroll that claimed the id (exclusive create): {"key", "name", "t"}
# <id>.decision exclusive create, whoever decides first: "approve <fp>" | "deny" | "expired"
# <id>.result   foreground, after acting on an approval: "ok" | "expired"
# <id>.done     the claiming enroll, on exit; the foreground waits for it before cleaning up
# Every file is written once and ends with "\n", so a reader retries until it sees the newline.

def create_once(path, text):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0), 0o600)
    except FileExistsError:
        return False
    with os.fdopen(fd, "wb") as f:
        f.write(text.encode() + b"\n")
    return True


def read_complete(path):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        return None
    return text[:-1] if text.endswith("\n") else None


def read_json(path):
    text = read_complete(path)
    return json.loads(text) if text else None


# --- enroll: the forced command -----------------------------------------------------------------

def finish(code):
    print(OUTCOMES[code], flush=True)
    sys.exit(code)


def enroll(pair_id, state):
    if not ID_RE.match(pair_id):
        finish(2)
    path = lambda suffix: os.path.join(state, f"{pair_id}.{suffix}")
    offer = read_json(path("offer"))
    if not offer or time.time() > offer["expires"]:
        finish(4)

    stalled = threading.Timer(30, lambda: (print("INVALID", flush=True), os._exit(2)))
    stalled.daemon = True
    stalled.start()
    raw = [sys.stdin.buffer.readline(1024) for _ in range(2)]
    stalled.cancel()
    try:
        key_line, name = (r.decode("utf-8").strip() for r in raw)
    except UnicodeDecodeError:
        finish(2)
    blob = ed25519_blob(key_line)
    if not blob or not 0 < len(name) <= 64 or not name.isprintable():
        finish(2)
    fp = fingerprint(blob)
    request = {"key": "ssh-ed25519 " + base64.b64encode(blob).decode(), "name": name, "t": time.time()}
    if not create_once(path("claim"), json.dumps(request)):
        finish(5)  # single use: another enroll claimed this id, and that's what the computer prompts for

    try:
        give_up = min(time.time() + DECISION_WAIT, offer["expires"])
        while True:
            decision = read_complete(path("decision"))
            if decision is not None:
                break
            if time.time() > give_up or not os.path.exists(path("offer")):
                if create_once(path("decision"), "expired"):
                    finish(4)
                continue  # the foreground decided in the same instant
            time.sleep(0.2)
        if decision == "deny":
            finish(3)
        if decision != f"approve {fp}":
            finish(4)
        for _ in range(150):
            result = read_complete(path("result"))
            if result is not None:
                finish(0 if result == "ok" else 4)
            time.sleep(0.1)
        finish(4)
    finally:
        create_once(path("done"), "")


# --- foreground ---------------------------------------------------------------------------------

def ask(prompt, timeout):
    """input() with a deadline: None on timeout, '' on EOF. A thread keeps it portable to Windows."""
    print(prompt, end="", flush=True)
    answer = []
    reader = threading.Thread(target=lambda: answer.append(sys.stdin.readline()), daemon=True)
    reader.start()
    end = time.time() + timeout
    while reader.is_alive() and time.time() < end:
        reader.join(0.2)
    if not answer:
        print()
    return answer[0] if answer else None


def discard_typeahead():
    """Drop keys pressed before the prompt, so a stray `y` can't approve a device unseen."""
    if not sys.stdin.isatty():
        return
    if WINDOWS:
        import msvcrt
        while msvcrt.kbhit():
            msvcrt.getwch()
    else:
        import termios
        termios.tcflush(sys.stdin, termios.TCIFLUSH)


def render_qr(text):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    sys.dont_write_bytecode = True  # no __pycache__ next to a copied script
    import qrcodegen
    qr = qrcodegen.QrCode.encode_text(text, qrcodegen.QrCode.Ecc.LOW)
    quiet, size = 4, qr.get_size()
    # Black on white whatever the terminal theme; each cell is two modules stacked (half blocks).
    lines = []
    for y in range(-quiet, size + quiet, 2):
        cells = "".join(" ▀▄█"[qr.get_module(x, y) | qr.get_module(x, y + 1) << 1]
                        for x in range(-quiet, size + quiet))
        lines.append("\x1b[38;5;16;48;5;231m" + cells + "\x1b[0m")
    return "\n".join(lines)


def enable_windows_vt():
    import ctypes
    kernel32 = ctypes.windll.kernel32
    handle, mode = kernel32.GetStdHandle(-11), ctypes.c_uint32()
    if kernel32.GetConsoleMode(handle, ctypes.byref(mode)):
        kernel32.SetConsoleMode(handle, mode.value | 0x4)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING


def display_name(name):
    """The computer name as the phone accepts it (ADR 0002 `n`): no control, format (bidi),
    line/paragraph separator, surrogate, private-use or unassigned characters; at most 64."""
    kept = "".join(c for c in name if unicodedata.category(c) not in ("Cc", "Cf", "Zl", "Zp", "Cs", "Co", "Cn"))
    return kept.strip()[:64] or "computer"


def pairing_url(params):
    # RFC 3986 escaping (%20, %2B): iOS URLComponents keeps a literal "+" rather than reading a space.
    return "herdr://pair?" + urllib.parse.urlencode(params, safe=",:", quote_via=urllib.parse.quote)


def device_comment(name):
    safe = re.sub(r"[^A-Za-z0-9._@-]+", "-", name).strip("-") or "device"
    return f"herdr-ios:{safe}:{time.strftime('%Y-%m-%d')}"


def pair(args):
    state = os.path.abspath(args.state or (os.path.join(os.environ["LOCALAPPDATA"], "herdr-pair") if WINDOWS
                                           else os.path.expanduser("~/.herdr-pair")))
    os.makedirs(state, mode=0o700, exist_ok=True)
    names, display = (args.host, socket.gethostname()) if args.host else tailnet_identity()
    fps = host_key_fingerprints(args.port)
    keys = args.keys_file or authorized_keys_path()
    pair_id = b64url(secrets.token_bytes(16))
    while pair_id[0] == "-":  # keep argv parsers from reading it as a flag
        pair_id = b64url(secrets.token_bytes(16))
    path = lambda suffix: os.path.join(state, f"{pair_id}.{suffix}")
    seed, public = mint_one_time_key()
    one_time_b64 = base64.b64encode(public).decode()
    expires = int(time.time()) + args.ttl
    line = (f'restrict,expiry-time="{time.strftime("%Y%m%d%H%M%S", time.localtime(expires))}",'
            f'from="{TAILNET_AND_LOOPBACK}",command="{forced_command(pair_id, state)}" '
            f"ssh-ed25519 {one_time_b64} herdr-pair:{pair_id}")
    params = [("v", "1"), ("id", pair_id), ("n", display_name(display)), ("u", getpass.getuser()),
              ("os", "windows" if WINDOWS else "unix"), ("h", ",".join(names)), ("p", str(args.port)),
              ("fp", ",".join(fps)), ("k", b64url(seed)), ("x", str(expires))]
    if args.session:
        params.append(("s", args.session))
    url = pairing_url(params)

    try:
        create_once(path("offer"), json.dumps({"expires": expires}))
        add_key_line(keys, line, one_time_b64)
        if args.print_url:
            print(url, flush=True)
        else:
            if WINDOWS:
                enable_windows_vt()
            print(f"\nScan with the Herdr app to pair {getpass.getuser()}@{display}.")
            print(render_qr(url))
            print(f"Host key {fps[0]}. The code expires in {args.ttl // 60} min; Ctrl+C cancels.",
                  flush=True)
        return await_enrollment(path, expires, keys)
    except KeyboardInterrupt:
        print("\nCancelled; nothing was authorized.")
        return 130
    finally:
        try:
            remove_key_lines(keys, one_time_b64)
        except OSError as err:
            print(f"herdr-pair: could not remove the one-time key from {keys} ({err}); delete the "
                  f"line ending herdr-pair:{pair_id}. It stops working at its expiry-time anyway.",
                  file=sys.stderr)
        try:
            os.remove(path("offer"))  # tells a waiting enroll to stop
        except FileNotFoundError:
            pass
        if os.path.exists(path("claim")):
            for _ in range(50):
                if os.path.exists(path("done")):
                    break
                time.sleep(0.1)
        for suffix in ("claim", "decision", "result", "done"):
            try:
                os.remove(path(suffix))
            except FileNotFoundError:
                pass


def await_enrollment(path, expires, keys):
    while (request := read_json(path("claim"))) is None:
        if time.time() > expires:
            print("The code expired; nothing was authorized.")
            return 4
        time.sleep(0.25)
    blob = ed25519_blob(request["key"])
    fp = fingerprint(blob)
    print(f"\nPairing request from {request['name']!r}\n  device key {fp}")
    discard_typeahead()
    answer = ask("Approve this device? [y/N] ", request["t"] + DECISION_WAIT - 5 - time.time())
    if answer is None:
        create_once(path("decision"), "expired")
        print("No answer; nothing was authorized.")
        return 4
    if answer.strip().lower() not in ("y", "yes"):
        create_once(path("decision"), "deny")
        print("Denied; nothing was authorized.")
        return 3
    # expiry-time only gates SSH authentication, so the deadline is enforced here too.
    if time.time() > expires or not create_once(path("decision"), f"approve {fp}"):
        create_once(path("decision"), "expired")
        print("Too late: the code expired; nothing was authorized.")
        return 4
    if time.time() > expires:
        create_once(path("result"), "expired")
        print("Too late: the code expired; nothing was authorized.")
        return 4
    add_key_line(keys, f"ssh-ed25519 {base64.b64encode(blob).decode()} {device_comment(request['name'])}",
                 base64.b64encode(blob).decode())
    create_once(path("result"), "ok")
    print(f"Paired {request['name']!r}. The phone is connecting.")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Pair the Herdr app with this computer.")
    parser.add_argument("--session", help="herdr session the phone attaches to (default: herdr's default)")
    parser.add_argument("--host", action="append", help="hostname for the phone, preferred first "
                        "(repeatable; default: this computer's Tailscale names)")
    parser.add_argument("--port", type=int, default=22, help="sshd port (default 22)")
    parser.add_argument("--enroll", metavar="ID", help=argparse.SUPPRESS)
    parser.add_argument("--state", help=argparse.SUPPRESS)
    parser.add_argument("--print-url", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--keys-file", help=argparse.SUPPRESS)
    parser.add_argument("--ttl", type=int, default=TTL, help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.enroll is not None:
        if not args.state:
            finish(2)
        enroll(args.enroll, args.state)
    testing = os.environ.get("HERDR_PAIR_TEST") == "1"
    if (args.print_url or args.state or args.keys_file or args.ttl != TTL) and not testing:
        die("--print-url, --state, --keys-file and --ttl are test-only (set HERDR_PAIR_TEST=1)")
    if not testing and not sys.stdin.isatty():
        die("run this in a terminal: approving a device needs a person at the keyboard")
    if args.session and not SESSION_RE.match(args.session):
        die("session names are 1-64 of A-Z a-z 0-9 . _ -")
    if args.host and not all(HOST_RE.match(h) for h in args.host):
        die("--host takes a hostname or IP address")
    if not 0 < args.port < 65536 or not 0 < args.ttl <= TTL:
        die("--port must be 1-65535 and --ttl 1-600")
    if WINDOWS and not sys.stdout.isatty():
        sys.stdout.reconfigure(encoding="utf-8")
    for name in ("SIGTERM", "SIGHUP", "SIGBREAK"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), lambda signum, _frame: sys.exit(128 + signum))
    sys.exit(pair(args))


if __name__ == "__main__":
    main()
