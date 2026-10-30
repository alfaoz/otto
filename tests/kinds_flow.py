"""Cards, API keys, notes and the Mac password through the service, on a throwaway vault. This script plays
Otto.app (answers approvals) and the browser extension (a fake bridge: the service trusts it through
OTTO_DEV_BROWSER), while the CLI plays the agent.
Usage: python3 tests/kinds_flow.py <otto binary> [--sudo]
--sudo also runs `otto sudo` for real once: sudo gets a made-up Mac password from otto, says it's wrong,
and asks again, which otto refuses (one failed sudo attempt on this Mac, nothing else)."""
import json, os, shutil, socket, struct, subprocess, sys, tempfile, threading, time

exe = os.path.abspath(sys.argv[1])
real_sudo = "--sudo" in sys.argv
ORIGIN = "chrome-extension://iphednfmmkainniibplfpnchaigilkgg/"
home = tempfile.mkdtemp(prefix="ok-", dir="/tmp")  # short: the socket path must fit in 104 bytes
# the CLI plays the agent from under a stand-in "claude" (an unsigned copy of bash): Auto and bypass only count
# for agents otto verifies, and the test service trusts this one through OTTO_DEV_AGENT (throwaway vaults only)
agents = os.path.join(home, "agents")
os.makedirs(agents)
shutil.copy("/bin/bash", os.path.join(agents, "claude"))
with open(os.path.join(agents, "run.sh"), "w") as f:
    f.write('"$@"\nexit $?\n')
AS_AGENT = [os.path.join(agents, "claude"), os.path.join(agents, "run.sh")]
# a test service only: any program may be a browser bridge
env = dict(os.environ, OTTO_HOME=home, OTTO_DEV_BROWSER="/", OTTO_DEV_KEY="test-key", OTTO_DEV_AGENT=agents)
p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=env, text=True, bufsize=1)
lock = threading.Lock()
waiting, nid = {}, [0]
asked = []         # approvals the service asked the app for
say = {"approve": True}

def send(obj):
    with lock:
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()

def answer(op, a):
    if op == "approve":
        asked.append(a)
        return {"approved": say["approve"]}
    if op == "consent_bypass":
        return {"granted": True, "statement": "TEST: i understand", "auth": "touch_id"}
    if op == "type_text":
        return {"app": "Front App"}
    raise Exception("unexpected " + op)

def reader():
    for line in p.stdout:
        m = json.loads(line)
        if m["type"] == "res" and m["id"] in waiting:
            waiting[m["id"]][1] = m
            waiting[m["id"]][0].set()
        elif m["type"] == "req":
            try:
                send({"type": "res", "id": m["id"], "ok": True, "result": answer(m["op"], m["args"])})
            except Exception as e:
                send({"type": "res", "id": m["id"], "ok": False, "error": {"code": "x", "message": str(e)}})

threading.Thread(target=reader, daemon=True).start()

def call(op, args=None):
    nid[0] += 1
    i = nid[0]
    ev = threading.Event()
    waiting[i] = [ev, None]
    send({"type": "req", "id": i, "op": op, "args": args or {}})
    ev.wait(10)
    m = waiting.pop(i)[1]
    if not m["ok"]:
        raise RuntimeError(f"{op}: {m['error']['message']}")
    return m["result"]

# ---- the fake browser extension, behind otto's own bridge process ----
tabs = {"shop.example": "https://shop.example/checkout", "other.example": "https://other.example/pay", "blog.example": "https://blog.example/"}
frames = []        # what the "browser" says it filled besides the page
got = []           # card values that reached the browser
probed = []        # what the browser was told before the user was asked
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
        site = next((s for s in a.get("sites", []) if s in tabs), None)
        if m["op"] == "has_tab":
            r = {"found": site is not None}
        elif m["op"] == "probe_card" and site:
            # stand-ins only: the real card isn't sent before the user said yes
            probed.append(a["values"])
            r = {"fields": [] if site == "blog.example" else sorted(a["values"])}
        elif m["op"] == "fill_card" and site:
            got.append(a["values"])
            r = {"url": tabs[site], "frames": list(frames), "filled": sorted(a["values"])}
        else:
            native_send({"type": "res", "id": m["id"], "ok": False, "error": {"code": "no_tab", "message": "no tab"}})
            continue
        native_send({"type": "res", "id": m["id"], "ok": True, "result": r})

threading.Thread(target=extension, daemon=True).start()

def otto(*args, stdin=None):
    r = subprocess.run([*AS_AGENT, exe, *args], capture_output=True, text=True, env=env, input=stdin, timeout=60)
    return r.returncode, (r.stdout + r.stderr).strip()

ok = fail = 0
def check(what, cond, extra=""):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ") + what + (f"  [{extra}]" if extra and not cond else ""))
    ok, fail = ok + bool(cond), fail + (not cond)

def entry(name):
    return next(e for e in call("entries") if e["name"] == name)

call("unlock", {"password": "test-key", "create": True})
NUMBER, CVC, MACPW = "4242 4242 4242 4242", "737", "TEST-made-up-mac-password"
card = {"number": NUMBER, "expiry": "08/28", "cvc": CVC, "cardholder": "TEST Person", "postal_code": "34000"}
call("upsert", {"patch": {"name": "visa", "kind": "card", "fields": card, "policy": "ask"}})
call("upsert", {"patch": {"name": "auto-card", "kind": "card", "fields": card, "policy": "auto"}})
call("upsert", {"patch": {"name": "shop-card", "kind": "card", "fields": card, "sites": ["shop.example"], "policy": "ask"}})
call("upsert", {"patch": {"name": "openai", "kind": "key", "fields": {"key": "sk-TEST-123"}, "scripts": True, "policy": "auto"}})
call("upsert", {"patch": {"name": "recovery", "kind": "note", "notes": "TEST: recovery words", "policy": "auto"}})
call("upsert", {"patch": {"name": "this mac", "kind": "mac", "password": MACPW, "policy": "ask", "apps": ["com.apple.Terminal"], "scripts": True}})
for _ in range(50):
    if call("status")["browsers"]:
        break
    time.sleep(0.1)

print("1. kinds: agents see what each entry is, never the card's number or CVC")
rc, out = otto("ls", "--json")
listed = {e["name"]: e for e in json.loads(out)}
check("kinds listed", [listed[n]["kind"] for n in ("visa", "openai", "recovery", "this mac")] == ["card", "key", "note", "mac"], out[:300])
check("a card shows brand, last 4 and expiry", listed["visa"]["card"] == {"brand": "Visa", "last4": "4242", "expiry": "08/28"}, json.dumps(listed["visa"]["card"]))
check("no number or CVC in the list", "4242 4242" not in out and "4242424242424242" not in out and f'"{CVC}"' not in out)
rc, out = otto("ls")
check("the plain list says so too", "Visa ••4242" in out and "api-key" in out and "mac-password" in out, out)

print("2. each kind is used its own way")
rc, out = otto("fill", "visa")
check("a card isn't a login", rc != 0 and "fill_card" in out, out)
rc, out = otto("fill", "openai")
check("an API key points to otto run", rc != 0 and "otto run" in out, out)
rc, out = otto("fill", "this mac", "--site", "shop.example", "--reason", "TEST")
check("the Mac password never fills a site", rc != 0 and "otto sudo" in out, out)
rc, out = otto("type", "this mac", "password")
check("nor gets typed into an app", rc != 0 and "otto sudo" in out, out)
rc, out = otto("run", "--env", "P=this mac", "--", "/usr/bin/true")
check("nor goes to a script", rc != 0 and "otto sudo" in out, out)
rc, out = otto("fill-card", "openai", "--site", "shop.example")
check("fill-card only takes cards", rc != 0 and "isn't a card" in out, out)
rc, out = otto("run", "--env", "K=openai", "--", "/bin/sh", "-c", '[ "$K" = sk-TEST-123 ] && printf same')
check("otto run without a field hands over the API key", rc == 0 and out == "same", out)
rc, out = otto("run", "--env", "K=openai", "--", "/bin/sh", "-c", 'printf %s "$K"')
check("and what the command prints shows it masked", rc == 0 and out == "••••", out)

print("3. a card asks every time, showing the card and the site")
before = len(asked)
rc, out = otto("fill-card", "visa", "--site", "https://shop.example/checkout")
check("filled", rc == 0 and "shop.example" in out, out)
check("asked once, naming the card and the site", len(asked) == before + 1 and "Visa •••• 4242" in (asked[-1].get("prompt") or "") and "shop.example" in asked[-1]["prompt"],
      json.dumps(asked[before:]))
v = got[-1] if got else {}
check("the browser got the whole card", v.get("number") == NUMBER and v.get("cvc") == CVC and v.get("exp_month") == "08" and v.get("exp_year") == "2028"
      and v.get("cardholder") == "TEST Person" and v.get("postal_code") == "34000", json.dumps(v))
rc, out = otto("fill-card", "visa", "--site", "shop.example")
check("and asks again right after", rc == 0 and len(asked) == before + 2, out)
rc, out = otto("fill-card", "auto-card", "--site", "shop.example")
check("Auto doesn't skip it for a card", rc == 0 and len(asked) == before + 3, out)

print("4. the user says no, or the page isn't right")
say["approve"] = False
n = len(got)
rc, out = otto("fill-card", "visa", "--site", "shop.example")
check("denied", rc == 3, out)
check("nothing reached the browser", len(got) == n)
say["approve"] = True
rc, out = otto("fill-card", "visa", "--site", "nowhere.example")
check("no tab: nobody is asked", rc != 0 and "no open tab" in out and len(asked) == before + 4, out)
rc, out = otto("fill-card", "visa", "--site", "blog.example")
check("no card form on the page: nobody is asked", rc != 0 and "no card form" in out and len(asked) == before + 4, out)
check("and nothing secret was sent to ask", probed and all(NUMBER not in json.dumps(x) and CVC not in json.dumps(x) for x in probed), json.dumps(probed[-1:]))
rc, out = otto("fill-card", "visa", "--site", "github.io")
check("a shared host is refused", rc != 0 and "shared" in out, out)
rc, out = otto("fill-card", "shop-card", "--site", "other.example")
check("a card kept to shop.example won't go elsewhere", rc != 0 and "shop.example" in out, out)
frames[:] = ["https://js.stripe.com/v3/elements-inner-card.html"]
rc, out = otto("fill-card", "visa", "--site", "shop.example")
check("a payment provider's frame is fine", rc == 0, out)
frames[:] = ["https://cards.evil.example/steal"]
rc, out = otto("fill-card", "visa", "--site", "shop.example")
check("a frame from anywhere else is caught", rc != 0 and "evil.example" in out, out)
frames.clear()

print("5. bypass: no question")
call("bypass_on", {"id": entry("visa")["id"], "statement": "TEST", "auth": "touch_id"})
before = len(asked)
rc, out = otto("fill-card", "visa", "--site", "other.example")
check("filled without asking", rc == 0 and len(asked) == before, out)
check("logged as bypass", any(l["op"] == "fill_card" and l["ok"] and l["detail"].endswith("(bypass)") for l in call("log", {"limit": 3})))

print("6. agents save API keys and notes, not cards")
rc, out = otto("save", "anthropic", "key", "--kind", "key", stdin="sk-ant-TEST")
check("saved as an API key", rc == 0 and entry("anthropic")["kind"] == "key", out)
rc, out = otto("save", "stolen", "number", "--kind", "card", stdin="4111111111111111")
check("a card from an agent is refused", rc != 0 and "not a card" in out, out)

print("7. the Mac password only goes to sudo's askpass helper")
s = socket.socket(socket.AF_UNIX)
s.connect(os.path.join(home, "otto.sock"))
s.sendall(b'{"id":1,"op":"askpass","args":{}}\n')
r = json.loads(s.makefile().readline())
s.close()
check("anything else asking is refused", not r["ok"] and r["error"]["code"] == "denied", json.dumps(r))
check("and the log says so", any(l["op"] == "sudo" and not l["ok"] and "refused" in l["detail"] for l in call("log", {"limit": 3})))
r = subprocess.run([exe, "status"], capture_output=True, text=True, env=dict(env, OTTO_ASKPASS="1"))
check("OTTO_ASKPASS alone doesn't make otto an askpass helper", r.returncode == 0 and "unlocked" in r.stdout, r.stdout + r.stderr)

if real_sudo:
    print("8. otto sudo for real (a made-up password: sudo refuses it once, then otto stops)")
    before = len(asked)
    rc, out = otto("sudo", "--", "-k", "/usr/bin/true")
    check("sudo failed on the made-up password", rc != 0 and "incorrect password" in out, out)
    check("asked once, showing the command", len(asked) == before + 1 and "sudo -k /usr/bin/true" in (asked[-1].get("prompt") or ""), json.dumps(asked[before:]))
    log = call("log", {"limit": 5})
    check("logged: handed to sudo, then refused the retry", [l["ok"] for l in log if l["op"] == "sudo"][:2] == [False, True]
          and "didn't take" in next(l["detail"] for l in log if l["op"] == "sudo"), json.dumps(log[:3]))

print("9. nothing secret in the log")
raw = open(os.path.join(home, "activity.jsonl")).read()
check("no card number, CVC, key or Mac password", all(x not in raw for x in ("4242 4242", "4242424242424242", f'"{CVC}"', "sk-TEST-123", "sk-ant-TEST", MACPW)))

bridge.kill()
p.stdin.close()
p.wait(5)
shutil.rmtree(home, ignore_errors=True)
print(f"{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
