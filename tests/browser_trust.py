"""A browser otto doesn't pin asks the user once; otto remembers the yes in the vault.
This script stands in for the browser: it starts otto's browser helper itself, so it has to run under an
interpreter signed with a Developer ID that otto doesn't pin, e.g. python.org's:
  /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 tests/browser_trust.py <otto binary> [adhoc python]
The optional second interpreter (ad hoc signed, like Homebrew's python3) must be refused without asking."""
import json, os, struct, subprocess, sys, tempfile, threading, time

exe = os.path.abspath(sys.argv[1])
adhoc = sys.argv[2] if len(sys.argv) > 2 else None
ORIGIN = "chrome-extension://iphednfmmkainniibplfpnchaigilkgg/"
home = tempfile.mkdtemp(prefix="obt-", dir="/tmp")  # short: the socket path must fit in 104 bytes
env = dict(os.environ, OTTO_HOME=home)
env.pop("OTTO_DEV_BROWSER", None)
answer = {"approve_browser": False}
asked = []
app = {}

def start():
    p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                         env=env, text=True, bufsize=1)
    app.update(p=p, waiting={}, nid=0, lock=threading.Lock())
    threading.Thread(target=reader, args=(p,), daemon=True).start()
    call("unlock", {"password": "test-key", "create": True})

def send(obj):
    with app["lock"]:
        app["p"].stdin.write(json.dumps(obj) + "\n")
        app["p"].stdin.flush()

def reader(p):
    for line in p.stdout:
        m = json.loads(line)
        if m["type"] == "res" and m["id"] in app["waiting"]:
            app["waiting"][m["id"]][1] = m
            app["waiting"][m["id"]][0].set()
        elif m["type"] == "req":
            asked.append((m["op"], m["args"]))
            send({"type": "res", "id": m["id"], "ok": True, "result": {"approved": answer.get(m["op"], False)}})

def call(op, args=None):
    app["nid"] += 1
    i = app["nid"]
    ev = threading.Event()
    app["waiting"][i] = [ev, None]
    send({"type": "req", "id": i, "op": op, "args": args or {}})
    ev.wait(10)
    m = app["waiting"].pop(i)[1]
    if not m["ok"]:
        raise RuntimeError(m["error"]["message"])
    return m["result"]

def stop():
    app["p"].stdin.close()
    app["p"].wait(5)

def bridge(cmd=None):
    """Start the browser helper the way a browser does and return the service's first answer."""
    h = subprocess.Popen(cmd or [exe, ORIGIN], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
    try:
        n = struct.unpack("=I", h.stdout.read(4))[0]
        return json.loads(h.stdout.read(n)), h
    except Exception as e:
        return {"error": str(e)}, h

ok = fail = 0
def check(what, cond, extra=""):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ") + what + (f"  [{extra}]" if extra and not cond else ""))
    ok, fail = ok + bool(cond), fail + (not cond)

start()
print("1. a Developer ID browser otto doesn't pin: the user is asked, and says no")
r, h = bridge()
check("asked once", [o for o, _ in asked] == ["approve_browser"], str(asked))
sig = asked[0][1] if asked else {}
check(f"with who signed it ({sig.get('signer')}, {sig.get('team')})", sig.get("team") and sig.get("signer"))
check("refused", r.get("data", {}).get("connected") is False, json.dumps(r))
h.kill()
r, h = bridge()
check("not asked again after a no", len(asked) == 1 and r.get("data", {}).get("connected") is False)
h.kill()

print("2. after a restart the user says yes")
stop()
asked.clear()
answer["approve_browser"] = True
start()
r, h = bridge()
check("asked, allowed, connected", [o for o, _ in asked] == ["approve_browser"] and r.get("data", {}).get("connected") is True, json.dumps(r))
time.sleep(0.3)
trusted = call("browsers")["trusted"]
check("kept in the vault", len(trusted) == 1 and trusted[0]["team"] == sig.get("team"), json.dumps(trusted))
check("the app sees it connected", call("browsers")["connected"] != [])
check("logged as yours", any(l["op"] == "browser_on" and l["agent"] == "you" for l in call("log", {"limit": 5})))
r2, h2 = bridge()
check("a second window connects without asking", len(asked) == 1 and r2.get("data", {}).get("connected") is True)
h.kill(); h2.kill()

print("3. remembered across restarts, until forgotten")
stop()
asked.clear()
answer["approve_browser"] = False
start()
r, h = bridge()
check("connects without asking", asked == [] and r.get("data", {}).get("connected") is True, json.dumps(r))
call("forget_browser", {"bundle": trusted[0]["bundle"] if trusted else ""})
check("forget cuts it off at once", call("browsers")["connected"] == [])
h.kill()
r, h = bridge()
check("and it has to ask again", [o for o, _ in asked] == ["approve_browser"])
h.kill()

if adhoc:
    print("4. an ad hoc signed program is refused without asking")
    asked.clear()
    r, h = bridge([adhoc, "-c", f"import subprocess,sys; subprocess.run([{exe!r}, {ORIGIN!r}])"])
    check("refused", r.get("data", {}).get("connected") is False, json.dumps(r))
    check("nobody was asked", asked == [])
    check("the log says why", any("verified developer" in l["detail"] for l in call("log", {"limit": 5})))
    h.kill()

stop()
subprocess.run(["rm", "-rf", home])
print(f"{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
