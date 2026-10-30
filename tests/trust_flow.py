"""Who's asking, through the service, on a throwaway vault: Auto and bypass only for agents otto verifies by their
signature, approvals remembered per thread, a notification event for each use nobody approved right then, Stop
(cut_off) for a thread, and fills that submit by default. This script plays Otto.app and the browser extension (a fake
bridge, trusted through OTTO_DEV_BROWSER); stand-in agents (unsigned copies of bash) run the CLI. The test service
trusts the ones in agents/ through OTTO_DEV_AGENT, honored only for a throwaway vault; the "claude" in strangers/ is an
impostor.
Usage: python3 tests/trust_flow.py <otto binary>"""
import json, os, shlex, shutil, socket, struct, subprocess, sys, tempfile, threading, time

exe = os.path.abspath(sys.argv[1])
here = os.path.dirname(os.path.abspath(__file__))
ORIGIN = "chrome-extension://iphednfmmkainniibplfpnchaigilkgg/"
home = tempfile.mkdtemp(prefix="ot-", dir="/tmp")  # short: the socket path must fit in 104 bytes
agents, strangers = os.path.join(home, "agents"), os.path.join(home, "strangers")
for d in (agents, strangers):
    os.makedirs(d)
    shutil.copy("/bin/bash", os.path.join(d, "claude"))
loop = os.path.join(home, "loop.sh")
with open(loop, "w") as f:
    f.write('while IFS= read -r line; do eval "$line"; done\n')
sock_py = os.path.join(home, "sock.py")
with open(sock_py, "w") as f:
    f.write("import json, socket, sys\ns = socket.socket(socket.AF_UNIX)\ns.connect(sys.argv[1])\n"
            "s.sendall((json.dumps({'id': 1, 'op': sys.argv[2], 'args': json.loads(sys.argv[3])}) + '\\n').encode())\n"
            "print(s.makefile().readline().strip())\n")
env = dict(os.environ, OTTO_HOME=home, OTTO_DEV_KEY="test-key", OTTO_DEV_AGENT=agents, OTTO_DEV_BROWSER="/")
lock = threading.Lock()
waiting, nid = {}, [0]
asked = []    # approvals the service asked the app for
used = []     # "used" events (the app's notifications)
say = {"approve": True}

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
    if op == "approve":
        asked.append(a)
        return {"approved": say["approve"]}
    if op == "consent_bypass":
        return {"granted": True, "statement": "TEST: i understand", "auth": "touch_id"}
    raise Exception("unexpected " + op)

def reader(proc):
    for line in proc.stdout:
        m = json.loads(line)
        if m["type"] == "res" and m["id"] in waiting:
            waiting[m["id"]][1] = m
            waiting[m["id"]][0].set()
        elif m["type"] == "req":
            try:
                send({"type": "res", "id": m["id"], "ok": True, "result": answer(m["op"], m["args"])})
            except Exception as e:
                send({"type": "res", "id": m["id"], "ok": False, "error": {"code": "x", "message": str(e)}})
        elif m["type"] == "event" and m["event"] == "used":
            used.append(m["data"])

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

    def otto(self, *args, child=False):
        cmd = " ".join(shlex.quote(a) for a in (exe, *args))
        # child: from a process the agent started, not the agent itself
        return self.sh(f"/bin/sh -c {shlex.quote(cmd)}" if child else cmd)

    def op(self, op, args):
        rc, out = self.sh(" ".join(shlex.quote(a) for a in ("python3", "-I", sock_py, os.path.join(home, "otto.sock"), op, json.dumps(args))))
        return json.loads(out.splitlines()[-1])

    def close(self):
        self.p.stdin.close()
        self.p.wait(5)

ok = fail = 0
def check(what, cond, extra=""):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ") + what + (f"  [{extra}]" if extra and not cond else ""))
    ok, fail = ok + bool(cond), fail + (not cond)

def entry(name):
    return next(e for e in call("entries") if e["name"] == name)

start()
call("unlock", {"password": "test-key", "create": True})
otp = "JBSWY3DPEHPK3PXP"
call("upsert", {"patch": {"name": "auto-site", "username": "alfa", "password": "pw-TEST-auto", "otp": otp, "sites": ["site.example"], "policy": "auto"}})
call("upsert", {"patch": {"name": "ask-site", "username": "alfa", "password": "pw-TEST-ask", "otp": otp, "sites": ["site.example"], "policy": "ask"}})
call("upsert", {"patch": {"name": "away", "password": "pw-TEST-away", "otp": otp, "sites": ["away.example"], "policy": "ask"}})
call("upsert", {"patch": {"name": "hidden", "password": "pw-TEST-hidden", "otp": otp, "sites": ["hidden.example"], "policy": "never"}})
call("upsert", {"patch": {"name": "openai", "kind": "key", "fields": {"key": "sk-TEST-trust-123"}, "scripts": True, "policy": "auto"}})
call("bypass_on", {"id": entry("away")["id"], "statement": "TEST", "auth": "touch_id"})
call("bypass_on", {"id": entry("hidden")["id"], "statement": "TEST", "auth": "touch_id"})

# ---- the fake browser extension, behind otto's own bridge process ----
fills = []    # what the "browser" was asked to fill (submit flag)
held = {"why": None}
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
        if m["op"] == "has_tab":
            r = {"found": "site.example" in a.get("sites", [])}
        elif m["op"] in ("fill", "fill_code") and "site.example" in a.get("sites", []):
            fills.append((m["op"], a.get("submit")))
            r = {"url": "https://site.example/login", "filled": sorted(a.get("values", {"code": 1})), "submitted": bool(a.get("submit")) and not held["why"]}
            if a.get("submit") and held["why"]:
                r["held"] = held["why"]
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
x = Session(strangers)

print("1. an agent otto verifies: Auto and bypass skip approval")
before = len(asked)
rc, out = a.otto("code", "auto-site")
check("Auto: code without asking", rc == 0 and out.split()[0].isdigit() and len(asked) == before, out)
rc, out = a.otto("code", "away")
check("bypass: code without asking", rc == 0 and len(asked) == before, out)
rc, out = a.otto("ls")
check("it sees auto as auto, and the never entry that has bypass", "auto-site" in out and "[auto]" in out and "hidden" in out, out)

print("2. an impostor (an unsigned \"claude\"): every use asks")
rc, out = x.otto("ls", "--json")
seen = {e["name"]: e for e in json.loads(out)} if rc == 0 else {}
check("auto shows as ask to it, bypass as off", seen.get("auto-site", {}).get("policy") == "ask" and seen.get("away", {}).get("policy") == "ask", out[:300])
check("a never entry stays hidden, even with bypass", "hidden" not in seen, out[:300])
before = len(asked)
rc, out = x.otto("code", "auto-site")
check("Auto asks it", rc == 0 and len(asked) == before + 1, out)
check("the prompt says it's unverified", asked and asked[-1]["agent"] == "an unverified program (claude)" and asked[-1]["verified"] is False, json.dumps(asked[-1:]))
rc, out = x.otto("code", "away")
check("bypass asks it too", rc == 0 and len(asked) == before + 2, out)
say["approve"] = False
rc, out = x.otto("code", "hidden")
check("the never entry is off-limits to it", rc != 0 and "off-limits" in out and len(asked) == before + 2, out)
rc, out = x.otto("type", "away", "password")
check("bypass doesn't let it type into any app (and nobody's asked)", rc != 0 and "isn't tied to any app" in out and len(asked) == before + 2, out)
say["approve"] = True
rc, out = x.otto("bypass", "ask-site", "--reason", "TEST")
check("it can't even ask for bypass", rc != 0 and "verify" in out, out)
log = call("log", {"limit": 30})
marks = [l.get("unverified", False) for l in log if l["op"] == "code" and l["entry"] == "auto-site" and l["ok"]]
check("its log lines are marked unverified, the real agent's aren't", sorted(set(marks)) == [False, True], json.dumps(log[:2]))

print("3. an approval belongs to the thread that got it")
b = Session(agents)
before = len(asked)
rc, out = a.otto("code", "ask-site")
check("thread A asks", rc == 0 and len(asked) == before + 1, out)
rc, out = a.otto("code", "ask-site")
check("thread A again: remembered", rc == 0 and len(asked) == before + 1, out)
rc, out = a.otto("code", "ask-site", child=True)
check("a command thread A runs counts as thread A", rc == 0 and len(asked) == before + 1, out)
rc, out = b.otto("code", "ask-site")
check("thread B is asked for itself", rc == 0 and len(asked) == before + 2, out)

print("4. a notification for each use nobody approved right then")
grants = [(u["entry"], u["grant"]) for u in used]
check("Auto and bypass uses", ("auto-site", "auto") in grants and ("away", "bypass") in grants, json.dumps(grants))
check("an earlier yes for this thread", ("ask-site", "remembered") in grants, json.dumps(grants))
check("never for a use the user just approved", ("ask-site", "asked") not in grants and len([g for g in grants if g == ("ask-site", "remembered")]) == 2, json.dumps(grants))
u = next(u for u in used if u["entry"] == "away")
check("it says who, what, the thread and its folder", u["who"] == "claude" and u["how"] == "got" and u["what"] == ["2FA code"]
      and u["bypass"] is True and ":" in u["thread"] and u["folder"] and u["folder"].endswith("tests"), json.dumps(u))
check("the bypass use is logged as bypass", any(l["op"] == "code" and l["entry"] == "away" and l["detail"].endswith("(bypass)") for l in call("log", {"limit": 40})))
n = len(used)
rc, out = a.otto("run", "--env", "K=openai", "--", "/usr/bin/true")
k = used[n:] and used[-1]
check("a script use names the command and the field", rc == 0 and k and k["how"] == "handed" and k["what"] == ["key"] and k["place"] == "true", json.dumps(k))
eid = next(e["id"] for e in call("entries") if e["name"] == "openai")
call("upsert", {"patch": {"id": eid, "quiet": True}})
n = len(used)
rc, out = a.otto("run", "--env", "K=openai", "--", "/usr/bin/true")
check("notifications off for an entry: it still works, with no notification", rc == 0 and len(used) == n, out)
check("the log still has the use, and that they turned it off", any(l["op"] == "env" and l["entry"] == "openai" for l in call("log", {"limit": 40})) and '"op":"notify_off"' in open(os.path.join(home, "activity.jsonl")).read())
rc, out = a.sh("printf x | " + shlex.quote(exe) + " save openai otto.quiet")
check("an agent can't change it", rc != 0 and next(e for e in call("entries") if e["name"] == "openai")["quiet"] is True, out)
call("upsert", {"patch": {"id": eid, "quiet": False}})
rc, out = a.otto("run", "--env", "K=openai", "--", "/usr/bin/true")
check("on again: the notification's back", rc == 0 and len(used) == n + 1, out)
check("and never carries a value", all("sk-TEST" not in json.dumps(u) and "pw-TEST" not in json.dumps(u) for u in used))

print("5. fills submit unless the agent says not to")
r = a.op("fill", {"entry": "auto-site"})
check("fill with no submit flag submits", r["ok"] and fills[-1] == ("fill", True) and r["result"]["submitted"] is True, json.dumps(r))
r = a.op("fill", {"entry": "auto-site", "submit": False})
check("submit:false doesn't", r["ok"] and fills[-1] == ("fill", False), json.dumps(r))
r = a.op("fill_code", {"entry": "auto-site"})
check("a 2FA code fill submits too", r["ok"] and fills[-1] == ("fill_code", True), json.dumps(r))
held["why"] = "the Cloudflare Turnstile check isn't done"
r = a.op("fill", {"entry": "auto-site"})
check("the browser held back: the agent hears why", r["ok"] and r["result"]["held"] == held["why"] and r["result"]["submitted"] is False, json.dumps(r))
check("and the log says so", call("log", {"limit": 1})[0]["detail"].endswith("didn't submit: the Cloudflare Turnstile check isn't done"), json.dumps(call("log", {"limit": 1})))
held["why"] = None
check("a fill is one notification: login fields, on the site", used[-1]["how"] == "filled" and used[-1]["place"] == "site.example" and "password" in used[-1]["what"], json.dumps(used[-1]))

print("6. Stop: the thread is cut off, and what it runs")
c = Session(agents)
rc, out = c.otto("code", "auto-site")
t = used[-1]["thread"]
check("thread C used it", rc == 0 and t not in {u["thread"] for u in used[:-1]})
r = call("cut_off", {"thread": t, "who": "claude", "folder": "~/otto/tests"})
check("cut off", r.get("cut") is True, json.dumps(r))
rc, out = c.otto("code", "auto-site")
check("its next request is refused", rc != 0 and "stopped this session" in out, out)
rc, out = c.otto("code", "auto-site", child=True)
check("so is a command it runs", rc != 0 and "stopped this session" in out, out)
rc, out = c.otto("ls")
check("and anything else it asks", rc != 0 and "stopped this session" in out, out)
rc, out = b.otto("code", "auto-site")
check("other threads go on", rc == 0, out)
log = call("log", {"limit": 10})
check("Activity: you stopped it", any(l["op"] == "cut_off" and l["agent"] == "you" and l["detail"] == "claude (~/otto/tests)" for l in log), json.dumps(log[:5]))
check("its refusals are logged", any(l["op"] == "code" and not l["ok"] and "stopped" in l["detail"] for l in log))
r = call("cut_off", {"thread": "999999:1"})
check("a thread that's gone: nothing to cut", r.get("gone") is True and r.get("cut") is False, json.dumps(r))
pid = int(t.split(":")[0])
c.close()
check("the session exited", subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0)

print("7. the stand-in agents are trusted only for a throwaway vault in dev mode")
bridge.kill()
p.stdin.close()
p.wait(5)
for s in (a, b, x):
    s.close()
env.pop("OTTO_DEV_KEY")
start()
call("unlock", {"password": "test-key"})
a = Session(agents)
before = len(asked)
rc, out = a.otto("code", "auto-site")
check("without OTTO_DEV_KEY the stand-in is just an unverified program", rc == 0 and len(asked) == before + 1 and "unverified" in asked[-1]["agent"], out)
a.close()

p.stdin.close()
p.wait(5)
shutil.rmtree(home, ignore_errors=True)
print(f"{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
