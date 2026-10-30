"""Plays Otto.app against `otto daemon` so the core can be tested without the UI.
Usage: python3 fake_app.py <otto binary> <home dir>   (then use the CLI with OTTO_HOME=<home dir>)
Approves everything (Touch ID, new sites, cards) except entries whose name contains "deny"; turns on bypass for anything
not named "*nobypass*"; answers save windows itself;
reads browser QR codes with tests/qr.swift (screen scans get a fixed demo secret). Adds a made-up card, "testcard"."""
import base64, json, subprocess, sys, tempfile, threading, os

exe, home = sys.argv[1], sys.argv[2]
env = dict(os.environ, OTTO_HOME=home)
p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True, bufsize=1)
lock = threading.Lock()
nid = [100]
waiting = {}

def send(obj):
    with lock:
        p.stdin.write(json.dumps(obj) + "\n"); p.stdin.flush()

def request(op, args):
    nid[0] += 1; i = nid[0]
    ev = threading.Event(); waiting[i] = [ev, None]
    send({"type": "req", "id": i, "op": op, "args": args})
    ev.wait(10)
    return waiting.pop(i)[1]

def answer(msg):
    op, a = msg["op"], msg["args"]
    if op == "approve":
        ok = "deny" not in a["entry"]
        print(f"[app] approve? {a['agent']} wants to {a['action']} for {a['entry']} -> {ok}", flush=True)
        return {"approved": ok}
    if op == "approve_site":
        ok = "deny" not in a["entry"]
        print(f"[app] {a['agent']} wants {a['entry']} on {a['domain']} ({a['reason']}) -> {ok}", flush=True)
        return {"approved": ok, "remember": ok}
    if op == "consent_bypass":
        ok = "nobypass" not in a["entry"]
        print(f"[app] bypass for {a['entry']}? {a['agent']}: {a['reason']} -> {ok}", flush=True)
        return {"granted": True, "statement": "TEST: i understand", "auth": "touch_id"} if ok else {"granted": False}
    if op == "save_dialog":
        print(f"[app] save window for {a['name']} site={a.get('site')} needs={a.get('needs')}", flush=True)
        patch = {"name": a["name"], "username": a.get("username") or "demo", "password": "pw-from-user",
                 "sites": [a["site"]] if a.get("site") else [], "policy": "auto"}
        if a.get("existing"):
            patch["id"] = a["existing"]["id"]
        return {"saved": True, "patch": patch}
    if op == "decode_qr":
        # read the tab's QR for real, so the site accepts the codes otto makes from it
        with tempfile.NamedTemporaryFile(suffix=".png") as f:
            f.write(base64.b64decode(a["png"])); f.flush()
            qr = os.path.join(os.path.dirname(os.path.abspath(__file__)), "qr.swift")
            out = subprocess.run(["swift", qr, f.name], capture_output=True, text=True).stdout
        return {"payloads": out.split()}
    if op == "scan_screen":
        return {"payloads": ["otpauth://totp/Demo:demo?secret=JBSWY3DPEHPK3PXP&issuer=Demo"]}
    if op == "type_text":
        print(f"[app] would type {len(a['text'])} chars into {'the app in front' if a.get('any') else a['apps']}", flush=True)
        return {"app": a["apps"][0] if a["apps"] else "Front App"}
    raise Exception("unknown " + op)

def reader():
    for line in p.stdout:
        msg = json.loads(line)
        if msg["type"] == "res":
            if msg["id"] in waiting:
                waiting[msg["id"]][1] = msg; waiting[msg["id"]][0].set()
        elif msg["type"] == "req":
            try:
                send({"type": "res", "id": msg["id"], "ok": True, "result": answer(msg)})
            except Exception as e:
                send({"type": "res", "id": msg["id"], "ok": False, "error": {"code": "x", "message": str(e)}})
        elif msg["type"] == "event":
            if msg["event"] == "activity":
                d = msg["data"]; print(f"[feed] {d['agent']} {d['op']} {d.get('entry')} ok={d['ok']} {d['detail']}", flush=True)

threading.Thread(target=reader, daemon=True).start()
print("[app] unlock:", request("unlock", {"password": "test-recovery-key", "create": True}), flush=True)
# a made-up card for the checkout pages (agents can't save cards; the user does, in the app)
request("upsert", {"patch": {"name": "testcard", "kind": "card", "policy": "ask", "fields": {
    "number": "4242 4242 4242 4242", "expiry": "08/28", "cvc": "737", "cardholder": "TEST Person", "postal_code": "34000"}}})
sys.stdin.read()  # stay alive until stdin closes
