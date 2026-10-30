"""A stand-in for otto's remote server, to look at the phone page without a daemon or Tailscale.

Serves core/src/remote/ the way the daemon does (same paths, same headers) and fakes the JSON API.
Each request id is a scenario: /r/save-new, /r/save-existing, /r/save-2fa, /r/save-only-2fa, /r/save-app,
/r/approve, /r/approve-card, /r/approve-unverified, /r/approve-change, /r/approve-change-2fa, /r/approve-command, /r/approve-command-fill, /r/approve-command-saved, /r/approve-command-elsewhere, /r/expired, /r/answered-mac, /r/answered-phone, /r/flip
(answered at the Mac after a few polls), /r/soon (45 s left), /r/not-yours, /r/this-mac, /r/locked, /r/gone.
The PIN is 123456; 5 wrong ones lock it (POST /mock/reset to start over). GET /mock/log lists every POST
with its headers and body, so a test can check what the page sends.

    python3 -I tests/remote_page_mock.py [port]     (default 8796)
"""

import copy
import json
import os
import re
import secrets
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "core", "src", "remote")
PIN = "123456"
DEVICE = "iphone-se-gen-3"
CSP = (
    "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; "
    "form-action 'none'; frame-ancestors 'none'; base-uri 'none'"
)
FILES = {
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/icon.svg": ("icon.svg", "image/svg+xml"),
    "/touch-icon.png": ("touch-icon.png", "image/png"),
}

SAVE = {
    "kind": "save",
    "state": "pending",
    "agent": "claude",
    "folder": "~/otto",
    "expires_in": 14 * 60 + 20,
    "answered_from": None,
    "name": "github",
    "site": "github.com",
    "app": None,
    "username": "alfa",
    "needs": ["password"],
    "note": "PREVIEW: your github session expired; i need to log back in to push the release",
    "existing": None,
}
APPROVE = {
    "kind": "approve",
    "state": "pending",
    "agent": "claude via T3 Code",
    "folder": "~/otto",
    "expires_in": 9 * 60 + 40,
    "answered_from": None,
    "entry": "GitHub",
    "entry_kind": "login",
    "sites": ["github.com"],
    "action": "fill its login in the browser",
    "prompt": "let claude via T3 Code fill GitHub’s login in the browser",
}


def scenarios():
    return {
        "save-new": dict(SAVE),
        "save-existing": dict(SAVE, username=None, existing={"username": "alfa@example.com", "has_password": True, "has_2fa": False},
                              note="PREVIEW: the saved password stopped working, can you put the new one in?"),
        "save-2fa": dict(SAVE, name="hetzner", site="accounts.hetzner.com", username=None, needs=["password", "totp"],
                         note="PREVIEW: hetzner asks for a 6-digit code after the password"),
        "save-only-2fa": dict(SAVE, name="stripe", site="dashboard.stripe.com", needs=["totp"], note=None,
                              existing={"username": "alfa", "has_password": True, "has_2fa": False}),
        "save-app": dict(SAVE, name="docker", site=None, app="com.docker.docker", agent="codex", folder="~/api",
                         note="PREVIEW: docker desktop wants to sign in again"),
        "approve": dict(APPROVE),
        "approve-card": dict(APPROVE, agent="claude", entry="Visa", entry_kind="card", sites=[], action="fill Visa •••• 4242 on shop.example.com",
                             prompt="let claude fill your Visa •••• 4242 on shop.example.com"),
        "approve-unverified": dict(APPROVE, agent="an unverified program (python3)", folder=None,
                                   prompt="let an unverified program (python3) fill GitHub’s login in the browser"),
        "approve-change": dict(APPROVE, agent="codex", action="change its password", prompt="let codex change GitHub’s password",
                               change={"field": "password", "value": "PREVIEW-n3w-pa55word", "label": None, "secret": True}),
        "approve-command": dict(APPROVE, agent="claude", entry="a command", entry_kind=None, sites=[], action="run `networksetup …`",
                                prompt="let claude run this command", folder="~/website",
                                command="sudo networksetup -setdnsservers Wi-Fi 1.1.1.1 1.0.0.1 && dscacheutil -flushcache",
                                why="PREVIEW: you asked me to switch Wi-Fi DNS to Cloudflare and flush the cache"),
        "approve-command-fill": dict(APPROVE, agent="claude", entry="a command", entry_kind=None, sites=[], action="run `xcrun …`",
                                     prompt="let claude run this command", folder="~/otto",
                                     command="xcrun notarytool store-credentials otto-notary --apple-id {{apple id}} --team-id TMF25D4TR4 --password {{app-specific password}}",
                                     why="PREVIEW: otto's releases get notarized with this. you make the password at account.apple.com",
                                     blanks=[{"name": "apple id", "secret": False}, {"name": "app-specific password", "secret": True}]),
        "approve-command-saved": dict(APPROVE, agent="claude", entry="a command", entry_kind=None, sites=[], action="run `xcrun …`",
                                      prompt="let claude run this command", folder="~/otto",
                                      command="xcrun notarytool store-credentials otto-notary --apple-id {{apple id}} --team-id TMF25D4TR4 --password {{app-specific password}}",
                                      why="PREVIEW: otto's releases get notarized with this",
                                      blanks=[{"name": "apple id", "secret": False, "saved": True, "value": "kept@example.com"}, {"name": "app-specific password", "secret": True, "saved": True}]),
        "approve-command-elsewhere": dict(APPROVE, agent="claude", entry="a command", entry_kind=None, sites=[], action="run `xcrun …`",
                                          prompt="let claude run this command", folder="~/otto",
                                          command="xcrun notarytool submit build/Otto.dmg --password {{app-specific password}}",
                                          why="PREVIEW: sends the release to Apple",
                                          blanks=[{"name": "app-specific password", "secret": True, "saved": False, "elsewhere": ["xcrun notarytool store-credentials otto-notary --password {{app-specific password}}"]}]),
        "approve-change-2fa": dict(APPROVE, agent="codex", action="replace its 2FA secret", prompt="let codex replace GitHub’s 2FA secret",
                                   change={"field": "2FA secret", "value": None, "label": "from the QR code for GitHub, alfa", "secret": True}),
        "expired": dict(SAVE, state="expired", expires_in=0),
        "answered-mac": dict(SAVE, state="saved", expires_in=0, answered_from="the Mac"),
        "answered-phone": dict(APPROVE, state="approved", expires_in=0, answered_from="ipad-pro"),
        "flip": dict(SAVE, flip_after=2),
        "soon": dict(APPROVE, expires_in=45),
    }


ERRORS = {
    "not-yours": (403, {"error": "not_yours", "message": "this device isn't yours on Tailscale"}),
    "this-mac": (403, {"error": "not_yours", "self": True, "message": "open it on your phone, not on the Mac itself"}),
    "locked": (423, {"error": "locked", "message": "remote is off after too many wrong PINs"}),
    "gone": (404, {"error": "not_found", "message": "no such request"}),
}

state = {"asks": scenarios(), "left": 5, "devices": set(), "log": [], "polls": {}}


def reset():
    state.update(asks=scenarios(), left=5, devices=set(), log=[], polls={})


class Handler(BaseHTTPRequestHandler):
    server_version = "otto"
    sys_version = ""

    def log_message(self, fmt, *args):
        if os.environ.get("MOCK_VERBOSE"):
            sys.stderr.write("mock: " + fmt % args + "\n")

    def send(self, status, body, ctype="application/json", extra=None):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def paired(self):
        m = re.search(r"(?:^|;\s*)otto_device=([^;]+)", self.headers.get("Cookie", ""))
        return bool(m) and m.group(1) in state["devices"]

    def view(self, rid, ask):
        out = {k: v for k, v in ask.items() if k != "flip_after"}
        out["paired"] = self.paired()
        out["device"] = DEVICE
        return out

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/" or re.fullmatch(r"/r/[A-Za-z0-9_-]+/?", path):
            with open(os.path.join(PAGE, "page.html"), "rb") as f:
                return self.send(200, f.read(), "text/html; charset=utf-8")
        if path in FILES:
            name, ctype = FILES[path]
            with open(os.path.join(PAGE, name), "rb") as f:
                return self.send(200, f.read(), ctype)
        if path == "/mock/log":
            return self.send(200, state["log"])
        m = re.fullmatch(r"/api/r/([A-Za-z0-9_-]+)", path)
        if m:
            rid = m.group(1)
            if state["left"] <= 0:
                return self.send(*ERRORS["locked"])
            if rid in ERRORS:
                return self.send(*ERRORS[rid])
            ask = state["asks"].get(rid)
            if ask is None:
                return self.send(*ERRORS["gone"])
            n = state["polls"][rid] = state["polls"].get(rid, 0) + 1
            if ask.get("flip_after") and n > ask["flip_after"] and ask["state"] == "pending":
                ask.update(state="saved", answered_from="the Mac", expires_in=0)
            return self.send(200, self.view(rid, ask))
        return self.send(404, {"error": "not_found", "message": "nothing here"})

    def do_POST(self):
        path = self.path.split("?")[0]
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        entry = {"path": path, "content_type": self.headers.get("Content-Type"), "origin": self.headers.get("Origin"),
                 "cookie": bool(self.headers.get("Cookie")), "body": raw.decode("utf-8", "replace")}
        state["log"].append(entry)
        if path == "/mock/reset":
            reset()
            return self.send(200, {"reset": True})
        if (self.headers.get("Content-Type") or "").split(";")[0].strip() != "application/json":
            return self.send(415, {"error": "bad_request", "message": "send JSON"})
        origin = self.headers.get("Origin")
        if origin and origin != "http://" + self.headers.get("Host", ""):
            return self.send(403, {"error": "bad_origin", "message": "wrong origin"})
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            return self.send(400, {"error": "bad_request", "message": "bad JSON"})
        if state["left"] <= 0:
            return self.send(*ERRORS["locked"])

        def pin_ok():
            if body.get("pin") == PIN:
                state["left"] = 5
                return True
            state["left"] -= 1
            return False

        def wrong():
            if state["left"] <= 0:
                return self.send(*ERRORS["locked"])
            return self.send(403, {"error": "wrong_pin", "message": "wrong PIN", "left": state["left"]})

        if path == "/api/pair":
            if set(body) != {"pin"}:
                return self.send(400, {"error": "bad_request", "message": f"pair takes pin only, got {sorted(body)}"})
            if not pin_ok():
                return wrong()
            dev = secrets.token_hex(8) + "." + secrets.token_hex(16)
            state["devices"].add(dev)
            cookie = f"otto_device={dev}; Max-Age=31536000; Path=/; HttpOnly; SameSite=Strict"
            return self.send(200, {"paired": True, "device": DEVICE}, extra={"Set-Cookie": cookie})

        m = re.fullmatch(r"/api/r/([A-Za-z0-9_-]+)/(save|approve|decline)", path)
        if not m:
            return self.send(404, {"error": "not_found", "message": "nothing here"})
        rid, what = m.groups()
        if rid in ERRORS:
            return self.send(*ERRORS[rid])
        ask = state["asks"].get(rid)
        if ask is None:
            return self.send(*ERRORS["gone"])
        if not self.paired():
            return self.send(401, {"error": "not_paired", "message": "pair this device first"})
        if ask["state"] == "expired":
            return self.send(410, {"error": "expired", "message": "this request expired"})
        if ask["state"] != "pending":
            return self.send(409, {"error": "answered", "message": "already answered"})
        if what == "decline":
            if body != {}:
                return self.send(400, {"error": "bad_request", "message": f"decline takes {{}}, got {body}"})
            ask.update(state="declined", answered_from=DEVICE)
            return self.send(200, {"declined": True})
        if what == "approve":
            if ask["kind"] != "approve":
                return self.send(400, {"error": "bad_request", "message": "not an approval"})
            wants = {"pin", "values", "remember"} if ask.get("blanks") else {"pin"}
            if any("elsewhere" in b for b in ask.get("blanks") or []):
                wants.add("reuse")
            if set(body) != wants:
                return self.send(400, {"error": "bad_request", "message": f"approve takes {sorted(wants)}, got {sorted(body)}"})
            if not pin_ok():
                return wrong()
            ask.update(state="approved", answered_from=DEVICE)
            return self.send(200, {"approved": True})
        if ask["kind"] != "save":
            return self.send(400, {"error": "bad_request", "message": "not a save request"})
        if set(body) != {"username", "password", "two_factor", "otp"}:
            return self.send(400, {"error": "bad_request", "message": f"save takes username, password, two_factor, otp; got {sorted(body)}"})
        if body["otp"] and not re.fullmatch(r"(otpauth://totp/.+|[A-Za-z2-7 =]{16,})", body["otp"]):
            return self.send(400, {"error": "bad_totp", "message": "that isn't a 2FA setup key or an otpauth:// link"})
        ask.update(state="saved", answered_from=DEVICE, saved=copy.deepcopy(body))
        return self.send(200, {"saved": True})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8796
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
