"""Remote, through the service, on a throwaway vault: with a PIN set, saves and approvals come back right away with a
link for the user's phone (the Mac window and Touch ID still show); the page only opens for the user's own Tailscale
devices, not this Mac; a device pairs once with the PIN; saving needs a paired device, approving needs one and the
PIN, each time; whichever side answers first counts; 5 wrong PINs turn remote off. This script plays Otto.app, the
browser extension and the phone; a stand-in `tailscale` (OTTO_TAILSCALE, honored only for a throwaway vault) says who
each connection is. Stand-in agents (unsigned copies of bash) run the CLI and the MCP server.
Usage: python3 tests/remote_flow.py <otto binary>"""
import http.client, json, os, re, shlex, shutil, socket, struct, subprocess, sys, tempfile, threading, time

exe = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
ORIGIN = "chrome-extension://iphednfmmkainniibplfpnchaigilkgg/"
home = tempfile.mkdtemp(prefix="or-", dir="/tmp")  # short: the socket path must fit in 104 bytes
agents = os.path.join(home, "agents")
os.makedirs(agents)
shutil.copy("/bin/bash", os.path.join(agents, "claude"))
loop = os.path.join(home, "loop.sh")
with open(loop, "w") as f:
    f.write('while IFS= read -r line; do eval "$line"; done\n')

# ---- a stand-in tailscale: this Mac is nSELF on user 42, and whoever connects is what ts.json says ----
s = socket.socket()
s.bind(("127.0.0.1", 0))
PORT = s.getsockname()[1]
s.close()
ts = os.path.join(home, "tailscale")
with open(ts, "w") as f:
    f.write("#!/usr/bin/env python3\nimport json, os, sys\n"
            "st = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'ts.json')))\n"
            "if sys.argv[1:3] == ['status', '--json']:\n"
            "    print(json.dumps({'BackendState': 'Running', 'Self': {'ID': 'nSELF', 'UserID': 42, 'TailscaleIPs': ['127.0.0.1', 'fd7a::1']}}))\n"
            "elif sys.argv[1:3] == ['whois', '--json'] and sys.argv[3] in st:\n"
            "    print(json.dumps({'Node': st[sys.argv[3]], 'UserProfile': {}}))\n"
            "else:\n"
            "    sys.stderr.write('no match for that IP\\n'); sys.exit(1)\n")
os.chmod(ts, 0o755)
DEVICES = {
    "mac": {"StableID": "nSELF", "User": 42, "ComputedName": "fubar", "Hostinfo": {"OS": "macOS"}},
    "stranger": {"StableID": "nOTHER", "User": 7, "ComputedName": "someone-else", "Hostinfo": {"OS": "iOS"}},
    "server": {"StableID": "nTAG", "User": 42, "Tags": ["tag:server"], "ComputedName": "box", "Hostinfo": {"OS": "linux"}},
    "phone": {"StableID": "nPHONE", "User": 42, "ComputedName": "iphone-test", "Hostinfo": {"OS": "iOS"}},
    "pad": {"StableID": "nPAD", "User": 42, "ComputedName": "ipad-test", "Hostinfo": {"OS": "iOS"}},
}
def connecting(who):
    with open(os.path.join(home, "ts.json"), "w") as f:
        json.dump({"127.0.0.1": DEVICES[who]}, f)
connecting("phone")

env = dict(os.environ, OTTO_HOME=home, OTTO_DEV_KEY="test-key", OTTO_DEV_AGENT=agents, OTTO_DEV_BROWSER="/",
           OTTO_TAILSCALE=ts, OTTO_REMOTE_PORT=str(PORT))
lock = threading.Lock()
waiting, nid = {}, [0]
mac = {"approve": "hang", "save": "hang"}   # what "the user at the Mac" does
held = []      # requests the Mac never answered: (op, id, args)
asked = []     # (op, args) the app was asked
events = []    # (event, data)

def start():
    global p
    p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         env=env, text=True, bufsize=1)
    threading.Thread(target=reader, args=(p,), daemon=True).start()

def send(obj):
    with lock:
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()

def answer(op, a):
    asked.append((op, a))
    if op == "approve":
        return {"yes": {"approved": True}, "no": {"approved": False, "declined": True}, "cant": {"approved": False}}.get(mac["approve"])
    if op == "approve_command":
        return mac["command"]
    if op == "save_dialog":
        if mac["save"] == "save":
            return {"saved": True, "patch": {"name": a["name"], "username": "from-mac", "password": "pw-TEST-mac", "sites": [a["site"]], "policy": "auto"}}
        return {"no": {"saved": False}}.get(mac["save"])
    raise Exception("unexpected " + op)

def reader(proc):
    for line in proc.stdout:
        m = json.loads(line)
        if m["type"] == "res" and m["id"] in waiting:
            waiting[m["id"]][1] = m
            waiting[m["id"]][0].set()
        elif m["type"] == "req":
            r = answer(m["op"], m["args"])
            if r is None:
                held.append((m["op"], m["id"], m["args"]))
            else:
                send({"type": "res", "id": m["id"], "ok": True, "result": r})
        elif m["type"] == "event":
            events.append((m["event"], m["data"]))

def call(op, args=None):
    nid[0] += 1
    i = nid[0]
    ev = threading.Event()
    waiting[i] = [ev, None]
    send({"type": "req", "id": i, "op": op, "args": args or {}})
    ev.wait(15)
    m = waiting.pop(i)[1]
    if not m["ok"]:
        raise RuntimeError(f"{op}: {m['error']['message']}")
    return m["result"]

def restart(who):
    """Tailscale's answers are kept for a while: a new identity needs a fresh service."""
    p.stdin.close()
    p.wait(5)
    connecting(who)
    start()
    call("unlock", {"password": "test-key"})
    listening()

def listening():
    for _ in range(50):
        if call("remote_status")["listening"]:
            return True
        time.sleep(0.1)
    return False

def phone(method, path, body=None, cookie=None, host=None, ctype="application/json", origin=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=15)
    h = {"Host": host or f"127.0.0.1:{PORT}"}
    if cookie:
        h["Cookie"] = cookie
    data = None
    if body is not None:
        data = json.dumps(body)
        h["Content-Type"] = ctype
    if origin:
        h["Origin"] = origin
    c.request(method, path, body=data, headers=h)
    r = c.getresponse()
    raw = r.read()
    try:
        j = json.loads(raw)
    except Exception:
        j = None
    return r.status, j, r.getheader("Set-Cookie"), raw

class Session:
    """One stand-in agent process: everything it runs is one thread to otto."""
    def __init__(self, folder):
        self.p = subprocess.Popen([os.path.join(folder, "claude"), loop], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, env=env, text=True, bufsize=1, cwd=here)

    def sh(self, cmd):
        self.p.stdin.write(cmd + " 2>&1; echo __rc=$?\n")
        self.p.stdin.flush()
        out = []
        for line in self.p.stdout:
            if line.startswith("__rc="):
                return int(line[5:]), "".join(out).strip()
            out.append(line)
        return -1, "".join(out)

    def otto(self, *args):
        return self.sh(" ".join(shlex.quote(a) for a in (exe, *args)))

    def mcp(self, tool, args):
        """otto's MCP server, started by the agent like Claude Code would."""
        script = ("import json, subprocess, sys\n"
                  "p = subprocess.Popen([sys.argv[1], 'mcp'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)\n"
                  "def rpc(i, m, prm):\n"
                  "    p.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': i, 'method': m, 'params': prm}) + '\\n'); p.stdin.flush()\n"
                  "    return json.loads(p.stdout.readline())\n"
                  "rpc(1, 'initialize', {'protocolVersion': '2025-06-18'})\n"
                  "print(json.dumps(rpc(2, 'tools/call', {'name': sys.argv[2], 'arguments': json.loads(sys.argv[3])})['result']))\n")
        path = os.path.join(home, "mcp_client.py")
        with open(path, "w") as f:
            f.write(script)
        rc, out = self.sh(" ".join(shlex.quote(a) for a in ("python3", "-I", path, exe, tool, json.dumps(args))))
        r = json.loads(out.splitlines()[-1])
        return r["content"][0]["text"], r.get("isError")

ok = fail = 0
def check(what, cond, extra=""):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ") + what + (f"  [{extra}]" if extra and not cond else ""))
    ok, fail = ok + bool(cond), fail + (not cond)

def link_of(out):
    m = re.search(r"(http://127\.0\.0\.1:\d+/r/([a-z0-9]+))", out)
    return (m.group(1), m.group(2)) if m else (None, None)

def eventually(cond, wait=3):
    """events come in on their own thread: give them a moment"""
    for _ in range(int(wait * 20)):
        if cond():
            return True
        time.sleep(0.05)
    return cond()

def since(n, name):
    return [d for e, d in events[n:] if e == name]

start()
call("unlock", {"password": "test-key", "create": True})
otp = "JBSWY3DPEHPK3PXP"
call("upsert", {"patch": {"name": "ask-site", "username": "alfa", "password": "pw-TEST-ask", "otp": otp, "sites": ["site.example"], "policy": "ask"}})
call("upsert", {"patch": {"name": "card", "kind": "card", "fields": {"number": "4242424242424242", "expiry": "12/34", "cvc": "123"}, "policy": "auto"}})

# ---- the fake browser extension ----
fills = []
bridge = subprocess.Popen([exe, ORIGIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)

def native_send(obj):
    b = json.dumps(obj).encode()
    bridge.stdin.write(struct.pack("=I", len(b)) + b)
    bridge.stdin.flush()

def extension():
    while True:
        head = bridge.stdout.read(4)
        if len(head) < 4:
            return
        m = json.loads(bridge.stdout.read(struct.unpack("=I", head)[0]))
        if m.get("type") != "req":
            continue
        a = m["args"]
        if m["op"] == "probe_card" and "site.example" in a.get("sites", []):
            r = {"url": "https://site.example/checkout", "fields": ["number", "cvc"]}
        elif m["op"] in ("fill", "fill_code") and "site.example" in a.get("sites", []):
            fills.append(m["op"])
            r = {"url": "https://site.example/login", "filled": sorted(a.get("values", {"code": 1})), "submitted": True}
        else:
            native_send({"type": "res", "id": m["id"], "ok": False, "error": {"code": "no_tab", "message": "no tab"}})
            continue
        native_send({"type": "res", "id": m["id"], "ok": True, "result": r})

threading.Thread(target=extension, daemon=True).start()
for _ in range(50):
    if call("status")["browsers"]:
        break
    time.sleep(0.1)

a = Session(agents)

print("1. remote off: nothing changes")
st = call("remote_status")
check("tailscale is up, no PIN, nothing listening", st["tailscale"] == "running" and not st["pin_set"] and not st["listening"] and st["ip"] == "127.0.0.1", json.dumps(st))
mac["approve"] = "yes"
rc, out = a.otto("fill", "ask-site")
check("an approval waits for Touch ID like before", rc == 0 and "filled" in out and not asked[-1][1].get("ask"), out)
call("forget_approvals")
rc, out = a.otto("--remote", "fill", "ask-site")
check("--remote without remote set up: says so, asks nobody", rc != 0 and "Settings → Remote" in out and "http://" not in out, out)
try:
    call("remote_set_pin", {"pin": "12345"})
    check("a 5-digit PIN is refused", False)
except RuntimeError as e:
    check("a 5-digit PIN is refused", "6 digits" in str(e), str(e))

print("2. set a PIN: the page goes up on the Tailscale address")
n = len(events)
st = call("remote_set_pin", {"pin": "482913"})
check("on and listening", st["on"] and st["listening"] and st["url"] == f"http://127.0.0.1:{PORT}", json.dumps(st))
check("the app hears about it", since(n, "remote"), "")
check("the PIN isn't in the log", "482913" not in open(os.path.join(home, "activity.jsonl")).read())
code, _, _, raw = phone("GET", "/r/whatever")
check("the page itself loads", code == 200, raw[:80])
code, j, _, _ = phone("GET", "/api/r/nope", host="evil.example:%d" % PORT)
check("another Host name gets nothing (DNS rebinding)", code == 421, j)
call("forget_approvals")
before = len(asked)
rc, out = a.otto("fill", "ask-site")
check("remote on, but the user didn't say they're away: Touch ID on the Mac, no link", rc == 0 and "filled" in out and "http://" not in out
      and asked[-1][0] == "approve" and not asked[-1][1].get("ask"), out)

print("3. only the user's own devices, never this Mac")
restart("mac")
code, j, _, _ = phone("GET", "/api/r/nope")
check("this Mac itself is refused", code == 403 and j["error"] == "this_mac", j)
restart("stranger")
code, j, _, _ = phone("GET", "/api/r/nope")
check("another Tailscale user's device is refused", code == 403 and j["error"] == "not_yours", j)
restart("server")
code, j, _, _ = phone("GET", "/api/r/nope")
check("a tagged server is refused", code == 403 and j["error"] == "not_yours", j)
restart("phone")
code, j, _, _ = phone("GET", "/api/r/nope")
check("the phone gets through (and a made-up id is not found)", code == 404 and j["error"] == "not_found", j)
code, j, _, _ = phone("POST", "/api/pair", {"pin": "000000"}, ctype="text/plain")
check("a POST that isn't JSON is refused", code == 400, j)
code, j, _, _ = phone("POST", "/api/pair", {"pin": "000000"}, origin="http://evil.example")
check("a POST from another page is refused", code == 403 and j["error"] == "bad_origin", j)

print("4. the user is away: a link, only a notification on the Mac; the phone approves with the PIN")
mac["approve"] = "hang"
call("forget_approvals")
n, before = len(events), len(asked)
rc, out = a.otto("--remote", "fill", "ask-site")
link, rid = link_of(out)
check("the agent gets a link and `otto wait` (exit 5)", rc == 5 and link and f"otto wait {rid}" in out, out)
time.sleep(0.3)
check("nothing pops up on the Mac", len(asked) == before, json.dumps(asked[before:]))
check("the Mac gets a notification for it instead", eventually(lambda: any(d["ask"] == rid and d["title"] == "claude wants to fill ask-site’s login in the browser" for d in since(n, "ask"))), json.dumps(since(n, "ask")))
pend = [d for d in since(n, "activity") if d.get("pending")]
check("the log says it's waiting (not failed)", pend and pend[0]["op"] == "fill", json.dumps(since(n, "activity")))
code, j, _, _ = phone("GET", f"/api/r/{rid}")
check("the phone sees what it's for", code == 200 and j["kind"] == "approve" and j["state"] == "pending" and not j["paired"]
      and j["prompt"] == "let claude fill ask-site’s login in the browser" and j["agent"] == "claude" and j["device"] == "iphone-test", j)
check("and never a secret", "pw-TEST" not in json.dumps(j))
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913"})
check("an unpaired phone can't approve", code == 401 and j["error"] == "not_paired", j)
code, j, _, _ = phone("POST", "/api/pair", {"pin": "111111"})
check("a wrong PIN says how many tries are left", code == 403 and j["error"] == "wrong_pin" and j["left"] == 4, j)
n = len(events)
code, j, cookie, _ = phone("POST", "/api/pair", {"pin": "482913"})
check("the right PIN pairs it, with a cookie only otto's page can use", code == 200 and j["paired"] and cookie and "HttpOnly" in cookie and "SameSite=Strict" in cookie, (code, j, cookie))
jar = cookie.split(";")[0]
check("the app gets a notice and the device list", eventually(lambda: any(d.get("kind") == "paired" for d in since(n, "remote_notice"))) and call("remote_status")["devices"][0]["name"] == "iphone-test")
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("now it's paired", j["paired"] is True, j)
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "222222"}, cookie=jar)
check("approving needs the PIN every time (wrong one counted again)", code == 403 and j["left"] == 4, j)
n = len(events)
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913"}, cookie=jar)
check("paired + PIN: allowed", code == 200 and j["approved"], j)
check("the Mac is told to drop its notification", eventually(lambda: {"ask": rid} in since(n, "ask_done")), json.dumps(since(n, "ask_done")))
check("logged as the user's yes, from the phone", eventually(lambda: any(d["op"] == "approved" and d["agent"] == "you" and "from iphone-test" in d["detail"] for d in since(n, "activity"))))
rc, out = a.otto("wait", rid)
check("`otto wait` says allowed, from the phone", rc == 0 and "allowed (from iphone-test)" in out, out)
n, before, f0 = len(events), len(asked), len(fills)
rc, out = a.otto("--remote", "fill", "ask-site")
check("running it again goes through, nobody asked again", rc == 0 and "filled" in out and len(asked) == before and len(fills) == f0 + 1, out)
check("and no 'used without asking' notification for it", not since(n, "used"), json.dumps(since(n, "used")))
check("clicking the old notification does nothing now", call("ask_here", {"ask": rid})["shown"] is False and len(asked) == before)
b = Session(agents)
rc, out = b.otto("wait", rid)
check("another session can't wait on it", rc != 0 and "another session" in out, out)
b.p.stdin.close()

print("5. caught at the Mac: clicking the notification asks there")
for say, want in (("yes", "approved"), ("no", "declined")):
    call("forget_approvals")
    mac["approve"] = say
    rc, out = a.otto("--remote", "fill", "ask-site")
    link, rid = link_of(out)
    before = len(asked)
    check(f"clicked: Touch ID on the Mac ({say})", call("ask_here", {"ask": rid})["shown"] is True and eventually(lambda: len(asked) == before + 1) and asked[-1][1]["ask"] == rid)
    time.sleep(0.3)
    code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
    check(f"the phone shows it {want} at the Mac", j["state"] == want and j["answered_from"] == "the Mac", j)
    code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913"}, cookie=jar)
    check("answering it again from the phone: already answered", code == 409, j)
    rc, out = a.otto("wait", rid)
    check("`otto wait`: " + ("allowed at the Mac" if say == "yes" else "a no at the Mac is a no"), (rc == 0 and "at the Mac" in out) if say == "yes" else (rc == 3 and "said no (at the Mac)" in out), out)
mac["approve"] = "cant"
rc, out = a.otto("--remote", "fill", "ask-site")
link, rid = link_of(out)
call("ask_here", {"ask": rid})
time.sleep(0.3)
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("a prompt that couldn't show (screen locked) leaves the link open", j["state"] == "pending", j)
code, j, _, _ = phone("POST", f"/api/r/{rid}/decline", {}, cookie=jar)
check("the phone can say no", code == 200 and j["declined"], j)
rc, out = a.otto("wait", rid)
check("`otto wait`: no, from the phone", rc == 3 and "from iphone-test" in out, out)

print("6. a card, over MCP")
mac["approve"] = "hang"
text, err = a.mcp("fill_card", {"entry": "card", "site": "site.example", "remote": True})
check("waiting, not an error, with the link and wait_for_user", not err and "wait_for_user" in text and link_of(text)[0], text)
text, err = a.mcp("fill_card", {"entry": "card", "site": "site.example"})
check("without remote it asks at the Mac (and here nobody answers: a no)", "http://" not in text and asked[-1][0] == "approve" and not asked[-1][1].get("ask"), text)

print("7. save a login from the phone")
mac["save"] = "hang"
n, before = len(events), len(asked)
rc, out = a.otto("--remote", "request-save", "gh", "--site", "github.com", "--needs", "password,2fa", "--username", "alfa", "--note", "PREVIEW: test")
link, rid = link_of(out)
check("request-save comes back with a link right away", rc == 5 and link and "otto wait" in out, out)
check("no window on the Mac, a notification", len(asked) == before and eventually(lambda: any(d["ask"] == rid and d["title"] == "claude needs your gh login" for d in since(n, "ask"))))
call("ask_here", {"ask": rid})
check("clicked: the save window opens after all", eventually(lambda: asked[-1][0] == "save_dialog") and asked[-1][1]["ask"] == rid)
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("the phone sees what to save", j["kind"] == "save" and j["name"] == "gh" and j["site"] == "github.com" and j["needs"] == ["password", "totp"] and j["username"] == "alfa", j)
code, j, _, _ = phone("POST", f"/api/r/{rid}/save", {"username": "alfa", "password": "pw-TEST-phone", "two_factor": "app", "otp": otp})
check("saving needs a paired device", code == 401, j)
code, j, _, _ = phone("POST", f"/api/r/{rid}/save", {"username": "alfa", "password": "", "two_factor": "app", "otp": otp}, cookie=jar)
check("no password: refused", code == 400, j)
code, j, _, _ = phone("POST", f"/api/r/{rid}/save", {"username": "alfa", "password": "pw-TEST-phone", "two_factor": "app", "otp": "nope!"}, cookie=jar)
check("a bad 2FA key: refused", code == 400 and j["error"] == "bad_totp", j)
n = len(events)
code, j, _, _ = phone("POST", f"/api/r/{rid}/save", {"username": "alfa", "password": "pw-TEST-phone", "two_factor": "app", "otp": otp}, cookie=jar)
check("saved without a PIN (the device is paired)", code == 200 and j["saved"], j)
e = next(x for x in call("entries") if x["name"] == "gh")
check("it's in the vault, with the password and 2FA", call("secret", {"id": e["id"], "field": "password"}) == "pw-TEST-phone" and e["totp"] and e["sites"] == ["github.com"] and e["policy"] == "auto", e)
check("the Mac window is told to close", eventually(lambda: {"ask": rid} in since(n, "ask_done")))
rc, out = a.otto("wait", rid)
check("`otto wait` prints the saved entry", rc == 0 and 'saved "gh" (from iphone-test)' in out, out)
op, hid, _ = held.pop()
send({"type": "res", "id": hid, "ok": True, "result": {"saved": True, "patch": {"name": "gh", "password": "pw-TEST-late"}}})
time.sleep(0.3)
check("the Mac window answering late overwrites nothing", call("secret", {"id": e["id"], "field": "password"}) == "pw-TEST-phone")
check("the password never shows in the log", "pw-TEST-phone" not in open(os.path.join(home, "activity.jsonl")).read())
mac["save"] = "save"
rc, out = a.otto("--remote", "request-save", "gl", "--site", "gitlab.com")
link, rid = link_of(out)
call("ask_here", {"ask": rid})
time.sleep(0.3)
code, j, _, _ = phone("POST", f"/api/r/{rid}/save", {"username": "x", "password": "pw-TEST-x"}, cookie=jar)
check("saved at the Mac first: the phone gets 'already answered'", code == 409, j)
text, err = a.mcp("wait_for_user", {"request": rid})
check("wait_for_user over MCP: saved at the Mac", not err and "saved (at the Mac)" in text, text)

print("7b. a change shows what it would write; the yes covers that value only")
mac["approve"] = "hang"
gh = next(x for x in call("entries") if x["name"] == "gh")
pw = lambda: call("secret", {"id": gh["id"], "field": "password"})
n, before = len(events), len(asked)
text, err = a.mcp("save_secret", {"entry": "gh", "field": "password", "value": "pw-TEST-new1", "remote": True})
link, rid = link_of(text)
check("changing a saved password while away: a link", not err and link and "wait_for_user" in text and len(asked) == before, text)
check("the notification says change", eventually(lambda: any(d["ask"] == rid and d["title"] == "claude wants to change gh’s password" for d in since(n, "ask"))), json.dumps(since(n, "ask")))
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("the phone gets the new value to show, hidden until tapped", j["change"] == {"field": "password", "value": "pw-TEST-new1", "label": None, "secret": True} and j["prompt"] == "let claude change gh’s password", j)
check("never the one saved now", pw() not in json.dumps(j))
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913"}, cookie=jar)
check("allowed with the PIN", code == 200 and j["approved"], j)
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("once answered, the page doesn't get the value any more", j["state"] == "approved" and j["change"]["value"] is None and "pw-TEST-new1" not in json.dumps(j), j)
text, err = a.mcp("save_secret", {"entry": "gh", "field": "password", "value": "pw-TEST-other", "remote": True})
check("that yes doesn't cover another value: asked again", not err and link_of(text)[0] and pw() == "pw-TEST-phone", text)
other = link_of(text)[1]
text, err = a.mcp("save_secret", {"entry": "gh", "field": "password", "value": "pw-TEST-new1", "remote": True})
check("the value that was allowed goes through", not err and "saved password" in text and pw() == "pw-TEST-new1", text)
phone("POST", f"/api/r/{other}/decline", {}, cookie=jar)
text, err = a.mcp("save_secret", {"entry": "gh", "field": "username", "value": "alfa2", "remote": True})
rid = link_of(text)[1]
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("a username shows as it is", j["change"]["value"] == "alfa2" and j["change"]["secret"] is False, j)
phone("POST", f"/api/r/{rid}/decline", {}, cookie=jar)
text, err = a.mcp("save_secret", {"entry": "gh", "field": "otp", "value": "GEZDGNBVGY3TQOJQ", "remote": True})
rid = link_of(text)[1]
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("a 2FA secret is named, never shown", j["change"]["value"] is None and j["change"]["label"].startswith("from claude, not shown") and "GEZDGNBVGY3TQOJQ" not in json.dumps(j), j)
mac["approve"] = "yes"
before = len(asked)
call("ask_here", {"ask": rid})
check("clicked at the Mac: the app gets the change and whether it can ask for the PIN", eventually(lambda: len(asked) == before + 1)
      and asked[-1][1]["change"]["field"] == "2FA secret" and asked[-1][1]["pin"] is True and asked[-1][1]["ask"] == rid, asked[-1][1])
text, err = a.mcp("wait_for_user", {"request": rid})
check("allowed at the Mac", not err and "allowed (at the Mac)" in text, text)
before = len(asked)
text, err = a.mcp("save_secret", {"entry": "gh", "field": "password", "value": "pw-TEST-mac2"})
req = asked[-1][1] if len(asked) > before else {}
check("not away: the app gets what it would write, to show before Touch ID", req.get("change") == {"field": "password", "value": "pw-TEST-mac2", "label": None, "secret": True}
      and req.get("pin") is True and req.get("action") == "change its password" and not req.get("ask"), req)
check("saved after the yes", not err and pw() == "pw-TEST-mac2", text)
check("new values never show in the log", not any(v in open(os.path.join(home, "activity.jsonl")).read() for v in ("pw-TEST-new1", "pw-TEST-mac2", "alfa2", "GEZDGNBVGY3TQOJQ")))
n = len(events)
r = call("check_pin", {"pin": "000001"})
check("the Mac's PIN field (no Touch ID): a wrong one counts with the phone's", r == {"ok": False, "left": 4}, r)
check("logged as from this Mac", eventually(lambda: any(d["op"] == "remote_pin" and "from this Mac" in d["detail"] for d in since(n, "activity"))))
r = call("check_pin", {"pin": "482913"})
check("the right one", r == {"ok": True}, r)

print("7c. a command with blanks, from the phone: filled in there, run by the service")
call("forget_approvals")
SECRET = "phone-typed-secret"
blanks = ["--blank", "who", "--secret-blank", "the pw"]
cmd = ["/bin/sh", "-c", "echo hello {{who}}; printf '%s' {{the pw}} | wc -c; printf 'pw=%s' {{the pw}}"]
rc, out = a.otto("--remote", "approve", "--why", "store a login", *blanks, "--", *cmd)
link, rid = link_of(out)
check("the agent gets a link", rc == 5 and link, out)
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("the phone sees the command and what to fill in", code == 200 and "{{the pw}}" in j["command"] and j["why"] == "store a login"
      and j["blanks"] == [{"name": "who", "secret": False, "saved": False}, {"name": "the pw", "secret": True, "saved": False}], j)
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "000000", "values": ["somebody", ""]}, cookie=jar)
check("a blank left empty doesn't cost a PIN try", code == 400 and j["error"] == "blank" and "the pw" in j["message"], j)
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "000000"}, cookie=jar)
check("nor do no values at all", code == 400 and j["error"] == "blank", j)
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913", "values": ["somebody", SECRET]}, cookie=jar)
check("filled in + PIN: allowed", code == 200 and j["approved"], j)
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("the page doesn't keep what was typed", j["state"] == "approved" and SECRET not in json.dumps(j), j)
rc, out = a.otto("wait", rid)
check("`otto wait` says allowed, without the values", rc == 0 and "allowed (from iphone-test)" in out and SECRET not in out, out)
before = len(asked)
rc, out = a.otto("--remote", "approve", "--why", "store a login", *blanks, "--", *cmd)
check("the same command again runs it, nobody asked again, with the values hidden",
      rc == 0 and "hello ••••" in out and "pw=••••" in out and str(len(SECRET)) in out and SECRET not in out and len(asked) == before, out)
rc, out = a.otto("--remote", "approve", "--why", "store a login", *blanks, "--", *cmd)
check("that yes was for one run: it asks again", rc == 5 and "http://" in out, out)
_, rid2 = link_of(out)
phone("POST", f"/api/r/{rid2}/decline", {}, cookie=jar)
rc, out = a.otto("--remote", "approve", "--why", "other", *blanks, "--", "/bin/sh", "-c", "echo {{who}} {{the pw}} other")
_, rid3 = link_of(out)
code, j, _, _ = phone("POST", f"/api/r/{rid3}/approve", {"pin": "482913", "values": ["somebody", SECRET]}, cookie=jar)
rc, out = a.otto("--remote", "approve", "--why", "other", *blanks, "--", "/bin/sh", "-c", "echo {{who}} {{the pw}} changed")
check("a yes doesn't cover a different command", rc == 5 and "••••" not in out and SECRET not in out, out)
_, rid4 = link_of(out)
phone("POST", f"/api/r/{rid4}/decline", {}, cookie=jar)
mac_values = {"approved": True, "values": ["from-the-mac", "mac-typed-secret"]}
mac["command"] = mac_values
rc, out = a.otto("--remote", "approve", "--why", "at mac", *blanks, "--", "/bin/sh", "-c", "echo mac {{who}} {{the pw}}")
_, rid5 = link_of(out)
check("clicked at the Mac: the window asks for the blanks there", call("ask_here", {"ask": rid5})["shown"] is True and eventually(lambda: asked[-1][0] == "approve_command" and asked[-1][1].get("blanks")), asked[-1:])
check("the window is told how long the request has left", 0 < asked[-1][1].get("expires_in", 0) <= 900, asked[-1][1].get("expires_in"))
check("and that answer counts", eventually(lambda: phone("GET", f"/api/r/{rid5}", cookie=jar)[1]["state"] == "approved"))
rc, out = a.otto("--remote", "approve", "--why", "at mac", *blanks, "--", "/bin/sh", "-c", "echo mac {{who}} {{the pw}}")
check("then the command runs with what was typed at the Mac", rc == 0 and "mac •••• ••••" in out and "mac-typed-secret" not in out, out)
logged = open(os.path.join(home, "activity.jsonl")).read()
check("nothing typed is in the log", SECRET not in logged and "mac-typed-secret" not in logged and "from-the-mac" not in logged)

print("7c2. how long a phone link lasts is the user's setting")
usual = call("waits")
call("set_waits", {"waits": dict(usual, phone=120)})
rc, out = a.otto("--remote", "approve", "--why", "short", "--", "/bin/sh", "-c", "echo short")
_, rid = link_of(out)
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("the link lasts as long as Settings says", 0 < j["expires_in"] <= 120, j)
phone("POST", f"/api/r/{rid}/decline", {}, cookie=jar)
call("set_waits", {"waits": usual})

print("7d. remembering from the phone")
call("forget_approvals")
rem = ["--blank", "who", "--secret-blank", "the pw", "--", "/bin/sh", "-c", "echo rem {{who}} {{the pw}}"]
rc, out = a.otto("--remote", "approve", *rem)
_, rid = link_of(out)
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913", "values": ["phone-person", "phone-secret-1"], "remember": [True, True]}, cookie=jar)
check("ticked on the phone: allowed", code == 200, j)
rc, out = a.otto("--remote", "approve", *rem)
check("it runs", rc == 0 and "rem •••• ••••" in out, out)
rc, out = a.otto("--remote", "approve", *rem)
_, rid = link_of(out)
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("next time a paired phone sees the name's value, and only that the secret is there", j["blanks"] == [{"name": "who", "secret": False, "saved": True, "value": "phone-person"}, {"name": "the pw", "secret": True, "saved": True}], j)
code, j2, _, _ = phone("GET", f"/api/r/{rid}")
check("an unpaired device sees neither", j2["blanks"] == [{"name": "who", "secret": False, "saved": True}, {"name": "the pw", "secret": True, "saved": True}] and "phone-person" not in json.dumps(j2), j2)
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913", "values": ["", ""], "remember": [True, True]}, cookie=jar)
check("left empty, otto uses what it has", code == 200, j)
rc, out = a.otto("--remote", "approve", *rem)
check("and hides it", rc == 0 and "rem •••• ••••" in out and "phone-secret-1" not in out, out)
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("once answered, the page shows no value", "phone-person" not in json.dumps(j), j)
logged = open(os.path.join(home, "activity.jsonl")).read()
check("nothing remembered is in the log", "phone-secret-1" not in logged and "phone-person" not in logged)
for x in call("entries"):
    if x["kind"] == "value":
        call("delete", {"id": x["id"]})

print("7e. a secret saved for another command, from the phone")
call("upsert", {"patch": {"name": "the pw", "kind": "value", "secret": True, "fields": {"value": "phone-saved-9"}, "commands": ["old {{the pw}}"]}})
use = ["--secret-blank", "the pw", "--", "/bin/sh", "-c", "echo use {{the pw}}"]
rc, out = a.otto("--remote", "approve", *use)
_, rid = link_of(out)
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("a paired phone is told where it's saved for", j["blanks"] == [{"name": "the pw", "secret": True, "saved": False, "elsewhere": ["old {{the pw}}"]}], j)
code, j2, _, _ = phone("GET", f"/api/r/{rid}")
check("an unpaired device isn't", j2["blanks"] == [{"name": "the pw", "secret": True, "saved": False}], j2)
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913", "values": [""], "remember": [False]}, cookie=jar)
check("without choosing to use it, it still needs filling in", code != 200 and j.get("error") == "blank", j)
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913", "values": [""], "remember": [True], "reuse": [True]}, cookie=jar)
check("choosing it allows the command", code == 200, j)
rc, out = a.otto("--remote", "approve", *use)
check("it runs with what's saved, hidden", rc == 0 and "use ••••" in out and "phone-saved-9" not in out, out)
check("and remember adds this command to it", next(x for x in call("entries") if x["kind"] == "value")["commands"] == ["old {{the pw}}", "echo use {{the pw}}"])
for x in call("entries"):
    if x["kind"] == "value":
        call("delete", {"id": x["id"]})

print("8. a cookie only works from the device that paired")
mac["approve"] = "hang"
def fresh():
    call("forget_approvals")
    rc, out = a.otto("--remote", "fill", "ask-site")
    return link_of(out)[1]
restart("pad")
rid = fresh()
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("the phone's cookie from the iPad: not paired", j and j["paired"] is False, j)
restart("phone")
rid = fresh()
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("from the phone: still paired after a restart", j and j["paired"] is True, j)

print("9. 5 wrong PINs turn remote off")
mac["approve"] = "hang"
rid = fresh()
n = len(events)
results = [phone("POST", f"/api/r/{rid}/approve", {"pin": "999999"}, cookie=jar) for _ in range(5)]
check("tries count down, the 5th locks", [r[1].get("left") for r in results[:4]] == [4, 3, 2, 1] and results[4][0] == 423, [r[1] for r in results])
check("the app gets a 'locked' notice", eventually(lambda: any(d.get("kind") == "locked" for d in since(n, "remote_notice"))))
st = call("remote_status")
check("remote is off (but the PIN is kept)", st["locked"] and not st["on"] and st["pin_set"], json.dumps(st))
mac["approve"] = "no"
a.mcp("save_secret", {"entry": "gh", "field": "password", "value": "pw-TEST-locked"})
check("a change window at the Mac doesn't offer the PIN now", asked[-1][1].get("pin") is False and pw() == "pw-TEST-mac2", asked[-1][1])
try:
    call("check_pin", {"pin": "482913"})
    check("the Mac's PIN field: refused while locked", False)
except RuntimeError as err:
    check("the Mac's PIN field: refused while locked", "too many wrong PINs" in str(err), str(err))
code, j, _, _ = phone("POST", f"/api/r/{rid}/approve", {"pin": "482913"}, cookie=jar)
check("even the right PIN does nothing now", code == 423, j)
rc, out = a.otto("--remote", "fill", "ask-site")
check("--remote now says remote is off", rc != 0 and "Settings → Remote" in out, out)
mac["approve"] = "yes"
rc, out = a.otto("fill", "ask-site")
check("without it: Touch ID at the Mac like before", rc == 0 and "filled" in out, out)
st = call("remote_set_pin", {"pin": "482913"})
check("setting the PIN again turns it back on", st["on"] and not st["locked"], json.dumps(st))
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("the paired phone is still paired", j and j["paired"] is True, j)

print("10. forgetting a device, turning remote off")
dev = call("remote_status")["devices"][0]["id"]
call("remote_forget", {"id": dev})
code, j, _, _ = phone("GET", f"/api/r/{rid}", cookie=jar)
check("a forgotten device isn't paired any more", j and j["paired"] is False, j)
st = call("remote_off")
check("off: no PIN, no devices, not listening", not st["pin_set"] and not st["devices"] and not st["listening"], json.dumps(st))
try:
    phone("GET", "/")
    check("nothing answers on the port", False)
except OSError:
    check("nothing answers on the port", True)

a.p.stdin.close()
p.stdin.close()
bridge.stdin.close()
print(f"\n{ok} ok, {fail} failed")
shutil.rmtree(home, ignore_errors=True)
sys.exit(1 if fail else 0)
