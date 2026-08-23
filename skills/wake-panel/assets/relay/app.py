#!/usr/bin/env python3
"""
Wake Panel relay.

A magic packet is a layer-2 broadcast and Tailscale is layer 3, so a phone off
the LAN cannot wake anything directly. This service runs on an always-on device
that IS on the LAN and turns an HTTP request from anywhere on the tailnet into a
broadcast on the local segment.

    phone (anywhere) --Tailscale--> this host --LAN broadcast--> target

It also polls each machine over SSH for vitals and can sleep/reboot/shut them
down. Standard library only: no pip install, runs on any Python 3.9+.

Config:
  HOSTS_FILE   default ./hosts.json      machines, ports, poll settings
  SECRETS_FILE default /secrets/config.json   password hash + cookie secret
"""

import hashlib
import hmac
import json
import os
import secrets
import shutil
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOSTS_FILE = os.environ.get("HOSTS_FILE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "hosts.json"))
SECRETS_FILE = os.environ.get("SECRETS_FILE", "/secrets/config.json")
SESSION_DAYS = 30
WOL_PORTS = (9, 7)


def _load(path, what):
    try:
        with open(path) as fh:
            return json.load(fh)
    except FileNotFoundError:
        print(f"  !! {what} not found at {path}", flush=True)
    except ValueError as e:
        print(f"  !! {what} at {path} is not valid JSON: {e}", flush=True)
    return {}


CFG = _load(HOSTS_FILE, "hosts file")
HOSTS = CFG.get("hosts", {})
LISTEN_PORT = int(CFG.get("listen_port", 8099))
POLL_SECONDS = int(CFG.get("poll_seconds", 8))
IDLE_AFTER = int(CFG.get("idle_after", 45))
SSH_KEY = CFG.get("ssh_key", "/secrets/id_ed25519")

SECRETS = _load(SECRETS_FILE, "secrets file")
AUTH_ENABLED = bool(SECRETS.get("password_hash") and SECRETS.get("cookie_secret"))
COOKIE_SECRET = (SECRETS.get("cookie_secret") or secrets.token_hex(32)).encode()

SSH_BIN = shutil.which("ssh")


def broadcast_targets(ip):
    """Global broadcast plus this host's /24 directed broadcast.

    Some NICs ignore 255.255.255.255 but honour the subnet broadcast, and some
    routed setups drop the global one. Sending both costs nothing.
    """
    out = ["255.255.255.255"]
    parts = (ip or "").split(".")
    if len(parts) == 4 and all(p.isdigit() for p in parts):
        out.append(f"{parts[0]}.{parts[1]}.{parts[2]}.255")
    return out


# --------------------------------------------------------------------------- #
# auth
# --------------------------------------------------------------------------- #

_login_fails = {}
_login_lock = threading.Lock()


def login_blocked(ip):
    with _login_lock:
        _, until = _login_fails.get(ip, (0, 0))
        return time.time() < until


def note_login_result(ip, ok):
    with _login_lock:
        if ok:
            _login_fails.pop(ip, None)
            return
        fails, _ = _login_fails.get(ip, (0, 0))
        fails += 1
        # 5 free attempts, then exponential backoff. This panel can power off
        # machines, so an unlimited password oracle is not acceptable even on a
        # network you trust.
        delay = 0 if fails < 5 else min(300, 2 ** (fails - 4))
        _login_fails[ip] = (fails, time.time() + delay)


def check_password(pw):
    if not AUTH_ENABLED:
        return False
    p = SECRETS.get("scrypt", {"n": 2 ** 14, "r": 8, "p": 1, "dklen": 32})
    dk = hashlib.scrypt(
        pw.encode(), salt=bytes.fromhex(SECRETS["password_salt"]),
        n=p["n"], r=p["r"], p=p["p"], dklen=p["dklen"],
    )
    return hmac.compare_digest(dk.hex(), SECRETS["password_hash"])


def make_token():
    exp = str(int(time.time()) + SESSION_DAYS * 86400)
    return f"{exp}.{hmac.new(COOKIE_SECRET, exp.encode(), hashlib.sha256).hexdigest()}"


def token_valid(tok):
    if not tok or "." not in tok:
        return False
    exp, _, sig = tok.partition(".")
    good = hmac.new(COOKIE_SECRET, exp.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(sig, good):
        return False
    try:
        return time.time() < int(exp)
    except ValueError:
        return False


# --------------------------------------------------------------------------- #
# collection
# --------------------------------------------------------------------------- #

def magic_packet(mac):
    clean = "".join(c for c in mac if c in "0123456789abcdefABCDEF")
    if len(clean) != 12:
        raise ValueError(f"bad MAC: {mac!r}")
    return b"\xff" * 6 + bytes.fromhex(clean) * 16   # 6x 0xFF + MAC x16 = 102B


def send_magic_packet(mac, ip, port=22, rounds=3, gap=1.5):
    """Every wake vector we have, repeated. Returns the number of sends.

    Four mechanisms, because they fail independently:

    1. BROADCAST magic packet - global and the /24 directed broadcast, ports 9
       and 7. The classic path, and the only one that works from S5.
    2. UNICAST magic packet to the host's own address. A sleeping NIC answers
       ARP from its offload engine, so the switch still has a port for it; this
       arrives where broadcast is rate-limited or filtered.
    3. DIRECTED PACKET - a plain TCP SYN. Most NICs ship *WakeOnPattern
       enabled, and Wake on Directed Packet brings a machine out of S3 with NO
       magic packet involved. Sending only broadcasts leaves this unused.
       It does NOT work from S5, where the NIC honours magic packets only, so
       it complements the broadcast rather than replacing it.
    4. REPETITION. Single packets genuinely get lost; machines that wake on the
       second or third attempt are common. Three rounds costs nothing.
    """
    packet = magic_packet(mac)
    sent = 0
    targets = broadcast_targets(ip)
    unicast = [ip] if ip else []

    for r in range(rounds):
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        try:
            for addr in targets + unicast:
                for p in WOL_PORTS:
                    try:
                        sock.sendto(packet, (addr, p))
                        sent += 1
                    except OSError:
                        pass
        finally:
            sock.close()

        # Directed packet. Whether it connects is irrelevant - the SYN is the
        # trigger - so the timeout is short enough not to stall the burst.
        for addr in unicast:
            try:
                t = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                t.settimeout(0.4)
                try:
                    t.connect_ex((addr, port))
                    sent += 1
                finally:
                    t.close()
            except OSError:
                pass

        # Between rounds only; sleeping after the last adds latency for nothing.
        if r < rounds - 1:
            time.sleep(gap)
    return sent


def tcp_up(ip, port, timeout=1.0):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return True
    except OSError:
        return False


def ssh_run(host, remote_cmd, timeout=20):
    if not SSH_BIN:
        return False, "", "no ssh client available"
    if not host.get("ssh_user"):
        return False, "", "no ssh_user configured"
    cmd = [
        SSH_BIN, "-i", SSH_KEY,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", f"ConnectTimeout={max(3, timeout // 3)}",
        f"{host['ssh_user']}@{host['ip']}", remote_cmd,
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode == 0, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return False, "", "ssh timeout"
    except OSError as e:
        return False, "", str(e)


def collector_command(host):
    collector = host.get("collector")
    if not collector:
        return None
    if (host.get("os") or "windows").lower().startswith("win"):
        return f"powershell -NoProfile -ExecutionPolicy Bypass -File {collector}"
    return f"sh {collector}"


def normalise(stats):
    """PowerShell's ConvertTo-Json collapses single-element arrays into a bare
    object and empty ones into {}. Without this, one loaded model arrives as a
    dict and zero arrives as {} which then renders as 'undefined NaNGB'."""
    for key in ("ollama", "workloads"):
        v = stats.get(key)
        if isinstance(v, dict):
            v = [v] if v else []
        stats[key] = [x for x in (v or []) if isinstance(x, dict)]
    procs = stats.get("gpu_procs")
    if isinstance(procs, str):
        procs = [procs]
    stats["gpu_procs"] = [p for p in (procs or []) if p]
    return stats


def collect(host):
    up = tcp_up(host["ip"], int(host.get("probe_port", 22)))
    out = {
        "label": host.get("label") or host["ip"],
        "note": host.get("note", ""),
        "ip": host["ip"],
        "up": up,
        "wol_verified": bool(host.get("wol_verified")),
        "can_command": bool(host.get("ssh_user")) and bool(SSH_BIN),
        "stats": None,
        "stats_error": None,
    }
    cmd = collector_command(host)
    if not up or not cmd:
        if up and not cmd:
            out["stats_error"] = "no collector configured"
        return out

    ok, stdout, err = ssh_run(host, cmd)
    if not ok:
        out["stats_error"] = err or "collector failed"
        return out
    try:
        out["stats"] = normalise(json.loads(stdout.splitlines()[-1]))
    except (ValueError, IndexError):
        out["stats_error"] = "unparseable collector output"
    return out


STATE = {k: {"label": h.get("label") or k, "note": h.get("note", ""), "ip": h.get("ip"),
             "up": None, "wol_verified": bool(h.get("wol_verified")),
             "can_command": False, "stats": None, "stats_error": None}
         for k, h in HOSTS.items()}
STATE_LOCK = threading.Lock()
LAST_POLL = [0.0]
LAST_VIEW = [0.0]
VIEW_EVENT = threading.Event()


def poller():
    """Poll only while someone is watching.

    Idle polling means an SSH login and a shell process on every machine every
    few seconds, forever, for nobody's benefit. /api/status stamps LAST_VIEW and
    sets VIEW_EVENT, so opening the panel resumes instantly instead of waiting
    out a sleep.
    """
    while True:
        if time.time() - LAST_VIEW[0] > IDLE_AFTER:
            VIEW_EVENT.wait(30)
            VIEW_EVENT.clear()
            continue

        results, threads = {}, []
        for key, host in HOSTS.items():
            t = threading.Thread(target=lambda k=key, h=host: results.__setitem__(k, collect(h)),
                                 daemon=True)
            t.start()
            threads.append(t)
        for t in threads:
            t.join(timeout=25)      # a hung SSH must not stall the whole loop

        with STATE_LOCK:
            STATE.update(results)
            LAST_POLL[0] = time.time()

        VIEW_EVENT.wait(POLL_SECONDS)
        VIEW_EVENT.clear()


# --------------------------------------------------------------------------- #
# web
# --------------------------------------------------------------------------- #

HERE = os.path.dirname(os.path.abspath(__file__))


def asset(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as fh:
        return fh.read()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "wakepanel"

    def _send(self, code, body, ctype, extra=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _json(self, code, obj, extra=None):
        self._send(code, json.dumps(obj), "application/json", extra)

    def _cookie(self):
        for part in self.headers.get("Cookie", "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "wakepanel":
                return v
        return None

    def _authed(self):
        # Fail CLOSED. Missing or corrupt secrets must lock everyone out, never
        # expose working reboot buttons to whatever can reach this port.
        return AUTH_ENABLED and token_valid(self._cookie())

    def _ip(self):
        return self.client_address[0] if self.client_address else "?"

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/healthz":
            return self._json(200, {"ok": True, "auth": AUTH_ENABLED,
                                    "ssh": bool(SSH_BIN), "hosts": len(HOSTS),
                                    "last_poll": LAST_POLL[0]})
        if path == "/login":
            if not AUTH_ENABLED:
                return self._send(503, asset("login.html").replace("{{MSG}}",
                                  "no password configured &mdash; run set-password"),
                                  "text/html; charset=utf-8")
            if self._authed():
                return self._send(302, b"", "text/plain", {"Location": "/"})
            return self._send(200, asset("login.html").replace("{{MSG}}", ""),
                              "text/html; charset=utf-8")
        if not self._authed():
            if path.startswith("/api/"):
                return self._json(401, {"error": "unauthorized"})
            return self._send(302, b"", "text/plain", {"Location": "/login"})
        if path in ("/", "/index.html"):
            return self._send(200, asset("panel.html"), "text/html; charset=utf-8")
        if path == "/api/status":
            LAST_VIEW[0] = time.time()
            VIEW_EVENT.set()
            with STATE_LOCK:
                # Age computed server-side: deriving it in the browser would be
                # wrong by whatever the client's clock skew happens to be.
                age = int(time.time() - LAST_POLL[0]) if LAST_POLL[0] else None
                return self._json(200, {k: dict(v, age_s=age) for k, v in STATE.items()})
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/login":
            ip = self._ip()
            if login_blocked(ip):
                return self._send(200, asset("login.html").replace("{{MSG}}",
                                  "too many attempts &mdash; wait a moment"),
                                  "text/html; charset=utf-8")
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n).decode("utf-8", "replace") if n else ""
            ok = check_password((parse_qs(body).get("password") or [""])[0])
            note_login_result(ip, ok)
            if not ok:
                return self._send(200, asset("login.html").replace("{{MSG}}", "incorrect password"),
                                  "text/html; charset=utf-8")
            return self._send(302, b"", "text/plain", {
                "Location": "/",
                "Set-Cookie": f"wakepanel={make_token()}; Path=/; HttpOnly; "
                              f"SameSite=Lax; Max-Age={SESSION_DAYS * 86400}",
            })

        if not self._authed():
            return self._json(401, {"error": "unauthorized"})

        action = path[len("/api/"):] if path.startswith("/api/") else ""
        key = (parse_qs(parsed.query).get("host") or [""])[0]
        host = HOSTS.get(key)
        if not host:
            return self._json(400, {"error": f"unknown host {key!r}"})

        if action == "wake":
            try:
                sent = send_magic_packet(host["mac"], host.get("ip"),
                                        int(host.get("probe_port", 22)))
            except (ValueError, OSError) as e:
                return self._json(500, {"error": str(e)})
            print(f"WOL -> {host.get('label', key)} x{sent}", flush=True)
            return self._json(200, {"ok": True,
                                    "detail": f"wake sent — {sent} packets across "
                                              "broadcast, unicast and directed vectors"})

        win = (host.get("os") or "windows").lower().startswith("win")
        cmds = {
            "sleep": "rundll32.exe powrprof.dll,SetSuspendState 0,1,0" if win else "systemctl suspend",
            "reboot": "shutdown /r /t 0 /f" if win else "sudo systemctl reboot",
            "shutdown": "shutdown /s /t 0 /f" if win else "sudo systemctl poweroff",
        }
        if action not in cmds:
            return self._json(404, {"error": "unknown action"})
        if action == "shutdown" and not host.get("wol_verified"):
            return self._json(403, {"error": "shutdown blocked: wake unverified on "
                                    f"{host.get('label', key)}. It may need a physical "
                                    "power button press. Verify wake, then set "
                                    "wol_verified: true in hosts.json."})
        if not host.get("ssh_user"):
            return self._json(400, {"error": "no ssh_user configured for this host"})

        # These kill the connection by design, so a non-zero exit or a timeout
        # is expected and not worth surfacing as an error.
        ssh_run(host, cmds[action], timeout=8)
        print(f"{action.upper()} -> {host.get('label', key)}", flush=True)
        return self._json(200, {"ok": True, "detail": f"{action} sent"})

    def handle_one_request(self):
        # Browsers dropping keep-alive connections otherwise dump a full
        # ConnectionResetError traceback into the log on every page close.
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError, TimeoutError):
            self.close_connection = True

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    print(f"Wake Panel on 0.0.0.0:{LISTEN_PORT} | hosts={len(HOSTS)} | "
          f"auth={'on' if AUTH_ENABLED else 'OFF'} | ssh={bool(SSH_BIN)}", flush=True)
    if not HOSTS:
        print(f"  !! no hosts configured - check {HOSTS_FILE}", flush=True)
    if not AUTH_ENABLED:
        print("  !! no password set - panel is LOCKED until you run set-password", flush=True)
    threading.Thread(target=poller, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
