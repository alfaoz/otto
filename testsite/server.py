"""A fake login site for testing otto end to end: password login, authenticator 2FA, a
2FA setup page with a QR code, and checkout pages for cards. Stdlib only. Run: python3 server.py [port]  (default 8765)
With TESTSITE_TLS=<cert.pem>:<key.pem> it also serves https on port+1, for card fields in "payment provider"
frames (map the provider's name to 127.0.0.1 in the test browser)."""
import base64, hashlib, hmac, html, http.server, json, os, secrets, ssl, struct, sys, threading, time, urllib.parse

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
HERE = os.path.dirname(os.path.abspath(__file__))
USER = "demo"
# the password and the 2FA secret survive restarts, so a login saved in otto keeps working
PW_FILE, TOTP_FILE = os.path.join(HERE, ".password"), os.path.join(HERE, ".totp")
PASSWORD = os.environ.get("TESTSITE_PASSWORD") or (open(PW_FILE).read().strip() if os.path.exists(PW_FILE) else "pw-" + secrets.token_urlsafe(9))
open(PW_FILE, "w").write(PASSWORD)
state = {"secret": open(TOTP_FILE).read().strip() if os.path.exists(TOTP_FILE) else None, "pending": None}

def set_secret(v):
    state["secret"] = v
    if v:
        open(TOTP_FILE, "w").write(v)
    elif os.path.exists(TOTP_FILE):
        os.remove(TOTP_FILE)
sessions = {}

def totp(secret_b32, t=None, step=30, digits=6):
    key = base64.b32decode(secret_b32 + "=" * (-len(secret_b32) % 8))
    counter = int((t or time.time()) // step)
    h = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    o = h[-1] & 15
    return str((struct.unpack(">I", h[o:o + 4])[0] & 0x7FFFFFFF) % 10 ** digits).zfill(digits)

def code_ok(secret, code):
    return any(hmac.compare_digest(totp(secret, time.time() + d * 30), code.strip()) for d in (-1, 0, 1))

PAGE = """<!doctype html><html><head><meta charset=utf-8><title>{title}</title>
<meta name=viewport content="width=device-width">
<style>body{{font:15px -apple-system,system-ui;max-width:380px;margin:60px auto;padding:0 16px;color:#111}}
input{{display:block;width:100%;box-sizing:border-box;padding:9px;margin:6px 0 14px;font-size:15px;border:1px solid #bbb;border-radius:6px}}
button{{padding:9px 16px;font-size:15px;border-radius:6px;border:0;background:#111;color:#fff}}
.err{{color:#b3261e}} .boxes input{{display:inline-block;width:40px;text-align:center;margin-right:6px}} small{{color:#666}}</style>
</head><body><h2>{title}</h2>{body}</body></html>"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        sys.stderr.write("testsite: " + (a[0] % a[1:]) + "\n")

    def session(self):
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "sid" and v in sessions:
                return sessions[v]
        return None

    def send(self, title, body, code=200, cookie=None):
        data = PAGE.format(title=title, body=body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, to, cookie=None):
        self.send_response(303)
        self.send_header("Location", to)
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def form(self):
        n = int(self.headers.get("Content-Length") or 0)
        return {k: v[0] for k, v in urllib.parse.parse_qs(self.rfile.read(n).decode()).items()}

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        s = self.session()
        if u.path == "/":
            err = '<p class=err>wrong username or password</p>' if "err" in q else ""
            return self.send("Sign in to Testsite", err + """<form method=post action=/login>
                <label>Username<input name=username autocomplete=username></label>
                <label>Password<input name=password type=password autocomplete=current-password></label>
                <button type=submit>Sign in</button></form>
                <p><small>2FA is """ + ("on" if state["secret"] else "off") + """. <a href=/setup>set up 2FA</a></small></p>""")
        if u.path == "/2fa":
            if not s or s.get("step") != "2fa":
                return self.redirect("/")
            err = '<p class=err>that code is wrong</p>' if "err" in q else ""
            if "boxes" in q:
                boxes = "".join(f'<input name=d{i} maxlength=1 inputmode=numeric>' for i in range(6))
                field = f'<div class=boxes>{boxes}</div><input type=hidden name=boxes value=1>'
            else:
                field = '<label>Authenticator code<input name=code inputmode=numeric autocomplete=one-time-code></label>'
            return self.send("Two-factor check", err + f'<form method=post action=/2fa>{field}<button type=submit>Verify</button></form>')
        if u.path == "/setup":
            state["pending"] = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
            uri = f"otpauth://totp/Testsite:{USER}?secret={state['pending']}&issuer=Testsite"
            err = '<p class=err>that code is wrong, scan again</p>' if "err" in q else ""
            return self.send("Set up 2FA", err + f"""<p>Scan this with your authenticator app:</p>
                <div id=qr style="width:220px;height:220px;margin:12px 0"></div>
                <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
                <script>new QRCode(document.getElementById('qr'), {{text: {json.dumps(uri)}, width: 220, height: 220}});</script>
                <form method=post action=/setup><label>Code from the app<input name=code inputmode=numeric autocomplete=one-time-code></label>
                <button type=submit>Turn on 2FA</button></form>""")
        if u.path == "/welcome":
            if not s or s.get("step") != "in":
                return self.redirect("/")
            return self.send("Welcome", f"<p id=done>signed in as <b>{html.escape(s['user'])}</b>. 2FA was {'used' if state['secret'] else 'off'}.</p><p><a href=/logout>sign out</a></p>")
        # fixtures for the browser fill engine
        if u.path.startswith("/challenge/"):
            # captchas, Cloudflare checks and fussy forms, for the checks before a submit (tests/submit_checks.mjs)
            name = u.path.rsplit("/", 1)[1]
            f = os.path.join(HERE, "challenges", name + ".html")
            if not name.replace("-", "").isalnum() or not os.path.exists(f):
                return self.send("Not found", "<p>no such challenge page</p>", 404)
            data = open(f, "rb").read()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            return self.wfile.write(data)
        if u.path == "/shadow":
            # the login form lives in a web component's shadow root (like Reddit's)
            return self.send("Sign in (web component)", """<x-login></x-login>
                <form id=real method=post action=/login hidden><input name=username><input name=password></form>
                <script>customElements.define('x-login', class extends HTMLElement {
                  connectedCallback() {
                    const r = this.attachShadow({mode: 'open'});
                    r.innerHTML = '<label>Username<input name=username autocomplete=username></label>' +
                      '<label>Password<input name=password type=password></label><button>Log In</button>';
                    r.querySelector('button').onclick = () => {
                      const f = document.getElementById('real'), [u, p] = r.querySelectorAll('input');
                      f.username.value = u.value; f.password.value = p.value; f.submit();
                    };
                  }
                });</script>""")
        if u.path in ("/framed", "/framed-elsewhere"):
            # the form is in a frame: from this machine (counts as the same site), or from another site
            host = "localhost" if u.path == "/framed" else "evil.test"
            return self.send("Sign in (framed)", f"""<input placeholder="Search the site">
                <iframe src="http://{host}:{PORT}/inner" style="width:100%;height:260px;border:1px solid #ddd"></iframe>
                <script>window.seen = {{}}; addEventListener('message', (e) => {{ window.seen = e.data; }});</script>""")
        if u.path == "/inner":
            return self.send("Inner sign-in", """<label>Username<input name=username autocomplete=username></label>
                <label>Password<input name=password type=password></label>
                <script>for (const i of document.querySelectorAll('input')) i.addEventListener('input', () =>
                  parent.postMessage({u: document.querySelector('[name=username]').value, p: document.querySelector('[name=password]').value}, '*'));</script>""")
        if u.path == "/checkout":
            # card fields on the shop's own page, with a shipping address in another form
            months = "".join(f"<option value={m:02}>{m:02}</option>" for m in range(1, 13))
            years = "".join(f"<option value={y}>{y}</option>" for y in range(2026, 2036))
            return self.send("Checkout", f"""<form id=ship><label>Shipping postal code<input name=ship_zip autocomplete="shipping postal-code"></label></form>
                <form id=pay method=post action=/pay>
                <label>Name on card<input name=ccname autocomplete=cc-name></label>
                <label>Card number<input name=cardnumber autocomplete=cc-number inputmode=numeric></label>
                <label>Expiry month<select name=exp_month><option value="">MM</option>{months}</select></label>
                <label>Expiry year<select name=exp_year><option value="">YYYY</option>{years}</select></label>
                <label>CVC<input name=cvc inputmode=numeric></label>
                <label>Billing postal code<input name=zip autocomplete="billing postal-code"></label>
                <button type=submit>Pay</button></form>""")
        if u.path == "/checkout-framed":
            # card fields in a payment provider's frames, one per field (like Stripe Elements)
            provider = q.get("provider", ["js.stripe.com"])[0]
            frames = "".join(f'<iframe src="https://{provider}:{PORT + 1}/card-frame?part={p}" style="width:100%;height:90px;border:1px solid #ddd"></iframe>' for p in ("number", "expiry", "cvc"))
            return self.send("Checkout (framed)", f"""<label>Email<input name=email autocomplete=email></label>{frames}
                <script>window.seen = {{}}; addEventListener('message', (e) => {{ window.seen[e.data.part] = e.data.values; }});</script>""")
        if u.path == "/checkout-nested":
            # the provider's frames inside another site's frame: not the shop's checkout
            return self.send("Checkout (nested)", f"""<iframe src="http://evil.test:{PORT}/checkout-framed" style="width:100%;height:400px"></iframe>""")
        if u.path == "/card-frame":
            part = q.get("part", ["number"])[0]
            field = {
                "number": '<input name=cardnumber autocomplete=cc-number placeholder="1234 1234 1234 1234">',
                "expiry": '<input name=exp-date autocomplete=cc-exp placeholder="MM / YY">',
                "cvc": '<input name=cvc autocomplete=cc-csc placeholder=CVC><input name=postal autocomplete=postal-code placeholder=ZIP>',
            }.get(part, "")
            return self.send("card " + html.escape(part), field + """<script>for (const i of document.querySelectorAll('input')) i.addEventListener('input', () =>
                parent.postMessage({part: %s, values: Object.fromEntries([...document.querySelectorAll('input')].map((i) => [i.name, i.value]))}, '*'));</script>""" % json.dumps(part))
        if u.path == "/logout":
            return self.redirect("/", cookie="sid=; Max-Age=0")
        if u.path == "/reset":
            set_secret(None)
            return self.redirect("/")
        self.send("Not found", "", 404)

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        f = self.form()
        if u.path == "/login":
            if f.get("username") == USER and hmac.compare_digest(f.get("password", ""), PASSWORD):
                sid = secrets.token_urlsafe(16)
                sessions[sid] = {"user": USER, "step": "2fa" if state["secret"] else "in"}
                return self.redirect("/2fa" if state["secret"] else "/welcome", cookie=f"sid={sid}; HttpOnly; SameSite=Lax")
            return self.redirect("/?err=1")
        if u.path == "/2fa":
            s = self.session()
            if not s:
                return self.redirect("/")
            code = "".join(f.get(f"d{i}", "") for i in range(6)) if f.get("boxes") else f.get("code", "")
            if state["secret"] and code_ok(state["secret"], code):
                s["step"] = "in"
                return self.redirect("/welcome")
            return self.redirect("/2fa?err=1" + ("&boxes=1" if f.get("boxes") else ""))
        if u.path == "/pay":
            last4 = f.get("cardnumber", "")[-4:]
            return self.send("Paid", f"<p id=done>paid with the card ending {html.escape(last4)}, {html.escape(f.get('exp_month', ''))}/{html.escape(f.get('exp_year', ''))}</p>")
        if u.path == "/setup":
            if state["pending"] and code_ok(state["pending"], f.get("code", "")):
                set_secret(state["pending"])
                state["pending"] = None
                return self.send("2FA is on", "<p id=done>2FA turned on. <a href=/>sign in</a></p>")
            return self.redirect("/setup?err=1")
        self.send("Not found", "", 404)

print(f"testsite on http://127.0.0.1:{PORT}  user={USER}  password in {HERE}/.password", flush=True)
if os.environ.get("TESTSITE_TLS"):
    cert, key = os.environ["TESTSITE_TLS"].split(":")
    tls = http.server.ThreadingHTTPServer(("127.0.0.1", PORT + 1), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(cert, key)
    tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
    threading.Thread(target=tls.serve_forever, daemon=True).start()
    print(f"and https on port {PORT + 1}", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
