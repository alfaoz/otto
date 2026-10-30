"""Bypass end to end through the service, on a throwaway vault: this script plays Otto.app (it answers the
service's approval requests and makes the private-channel calls) while the CLI plays the agent.
"The user is away": every Touch ID and new-site window times out. The consent window is answered yes,
except for entries named *nobypass*.
Usage: python3 tests/bypass_flow.py <otto binary>"""
import datetime, json, os, shutil, subprocess, sys, tempfile, threading, time

exe = sys.argv[1]
home = tempfile.mkdtemp(prefix="ob-", dir="/tmp")  # short: the socket path must fit in 104 bytes
# the CLI plays the agent from under a stand-in "claude" (an unsigned copy of bash): Auto and bypass only count
# for agents otto verifies, and the test service trusts this one through OTTO_DEV_AGENT (throwaway vaults only)
agents = os.path.join(home, "agents")
os.makedirs(agents)
shutil.copy("/bin/bash", os.path.join(agents, "claude"))
with open(os.path.join(agents, "run.sh"), "w") as f:
    f.write('"$@"\nexit $?\n')
AS_AGENT = [os.path.join(agents, "claude"), os.path.join(agents, "run.sh")]
env = dict(os.environ, OTTO_HOME=home, OTTO_DEV_KEY="test-key", OTTO_DEV_AGENT=agents)
p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=env, text=True, bufsize=1)
lock = threading.Lock()
waiting, nid = {}, [0]
asked = []      # every approval the service asked the app for
typed = []      # type_text requests

def send(obj):
    with lock:
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()

class Away(Exception):
    pass

def answer(op, a):
    if op != "type_text":
        asked.append((op, a.get("entry"), a.get("hours")))
    if op in ("approve", "approve_site"):
        raise Away()  # nobody at the Mac: the window times out
    if op == "consent_bypass":
        if "nobypass" in a["entry"]:
            return {"granted": False}
        return {"granted": True, "statement": "TEST: i understand", "auth": "touch_id", "hours_seen": a.get("hours")}
    if op == "type_text":
        typed.append(a)
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
            except Away:
                send({"type": "res", "id": m["id"], "ok": False, "error": {"code": "timeout", "message": "nobody answered"}})
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

def otto(*args, stdin=None):
    r = subprocess.run([*AS_AGENT, exe, *args], capture_output=True, text=True, env=env, input=stdin, timeout=30)
    return r.returncode, (r.stdout + r.stderr).strip()

ok = fail = 0
def check(what, cond, extra=""):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ") + what + (f"  [{extra}]" if extra and not cond else ""))
    ok, fail = ok + bool(cond), fail + (not cond)

def entry(name):
    return next(e for e in call("entries") if e["name"] == name)

call("unlock", {"password": "test-key", "create": True})
otp = "JBSWY3DPEHPK3PXP"
call("upsert", {"patch": {"name": "hetzner-deny", "username": "alfa", "password": "pw", "otp": otp, "sites": ["hetzner.com"],
                          "apps": ["com.example.vpn"], "policy": "ask"}})
call("upsert", {"patch": {"name": "bank-nobypass", "password": "pw", "otp": otp, "sites": ["bank.example"], "policy": "ask"}})
call("upsert", {"patch": {"name": "secret-never", "password": "pw", "otp": otp, "sites": ["never.example"], "policy": "never"}})

print("1. away from the Mac: an \"ask\" entry can't be used")
rc, out = otto("code", "hetzner-deny")
check("refused", rc == 3, out)
check("the error points to answering from the phone, not to bypass", "from their phone" in out and "bypass" not in out, out)

print("2. the agent asks for bypass from the chat; the user confirms (Touch ID + box) in the app")
rc, out = otto("bypass", "hetzner-deny")
check("a reason is required", rc != 0 and "reason" in out, out)
rc, out = otto("bypass", "hetzner-deny", "--reason", "TEST: you asked me to keep the server up while you travel", "--hours", "72")
check("bypass on", rc == 0 and "bypass on" in out, out)
check("the consent window got the agent's reason and hours", [h for o, _, h in asked if o == "consent_bypass"] == [72])
e = entry("hetzner-deny")
check("the entry carries a sealed consent, with who asked and why", e["bypass"] and len(e["bypass"]["seal"]) == 64
      and e["bypass"]["asked_by"] and e["bypass"]["reason"].startswith("TEST"), json.dumps(e["bypass"]))
check("it records what the user ticked and how they confirmed", e["bypass"]["statement"] == "TEST: i understand" and e["bypass"]["auth"] == "touch_id")
rc, out = otto("ls", "hetzner-deny")
check("agents see policy bypass", "[bypass]" in out, out)

print("3. with bypass on nothing asks")
before = len(asked)
rc, out = otto("code", "hetzner-deny")
check("2FA code given", rc == 0 and out.split()[0].isdigit(), out)
rc, out = otto("type", "hetzner-deny", "password")
check("typed without asking", rc == 0, out)
check("into whatever app is in front", typed and typed[-1]["any"] is True)
check("no approval was asked for", len(asked) == before, str(asked[before:]))
log = call("log", {"limit": 20})
uses = [l for l in log if l["op"] in ("code", "type") and l["ok"]]
check("each use is logged as bypass", uses and all(l["detail"].endswith("(bypass)") for l in uses), json.dumps(uses))

print("4. the consent is in the log, sealed; a line otto didn't write isn't")
on = [l for l in log if l["op"] == "bypass_on"]
check("bypass_on by you, with the consent", on and on[0]["agent"] == "you" and on[0]["consent"]["statement"] == "TEST: i understand")
check("sealed", on and on[0]["sealed"] is True)
forged = dict(on[0])
forged["entry"] = "bank-nobypass"
forged["consent"] = dict(on[0]["consent"], name="bank-nobypass", entry=entry("bank-nobypass")["id"])
forged.pop("sealed", None)
with open(os.path.join(home, "activity.jsonl"), "a") as f:
    f.write(json.dumps(forged) + "\n")
log = call("log", {"limit": 5})
check("a hand-written bypass line shows as not sealed", log[0]["op"] == "bypass_on" and log[0]["sealed"] is False)
rc, out = otto("code", "bank-nobypass")
check("and grants nothing", rc == 3, out)

print("5. agents can't write the consent themselves")
rc, out = otto("save", "bank-nobypass", "otto.bypass", stdin=json.dumps(forged["consent"]))
check("save refuses otto.* fields", rc != 0, out)
rc, out = otto("bypass", "bank-nobypass", "--reason", "TEST")
check("the user saying no in the window is a no", rc == 3, out)
check("bank still asks", entry("bank-nobypass")["bypass"] is None)

print("6. turning it off from the chat needs nobody")
before = len(asked)
rc, out = otto("bypass", "hetzner-deny", "--off")
check("bypass off, back to ask", rc == 0 and "back to ask" in out, out)
check("no window for that", len(asked) == before)
rc, out = otto("code", "hetzner-deny")
check("asks (and is refused) again", rc == 3, out)
check("logged as an agent op", any(l["op"] == "end_bypass" and l["ok"] for l in call("log", {"limit": 5})))

print("7. bypass on a \"never\" entry from the app, then off: hidden again")
check("hidden at first", "secret-never" not in otto("ls")[1])
call("bypass_on", {"id": entry("secret-never")["id"], "statement": "TEST", "auth": "touch_id"})
check("visible with bypass", "secret-never" in otto("ls")[1])
call("bypass_off", {"id": entry("secret-never")["id"]})
check("hidden again", "secret-never" not in otto("ls")[1])
check("the user's off is logged", any(l["op"] == "bypass_off" and l["agent"] == "you" for l in call("log", {"limit": 5})))

print("8. a bypass with an end date ends by itself")
soon = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=3)).strftime("%Y-%m-%dT%H:%M:%SZ")
call("bypass_on", {"id": entry("hetzner-deny")["id"], "statement": "TEST", "auth": "touch_id", "until": soon})
rc, out = otto("code", "hetzner-deny")
check("works before", rc == 0, out)
time.sleep(4)
rc, out = otto("code", "hetzner-deny")
check("asks again after", rc == 3, out)
try:
    call("bypass_on", {"id": entry("hetzner-deny")["id"], "statement": "TEST", "auth": "touch_id", "until": "2020-01-01T00:00:00Z"})
    check("a date in the past is refused", False)
except RuntimeError:
    check("a date in the past is refused", True)

print("9. changing a saved secret still needs Touch ID with bypass on")
call("bypass_on", {"id": entry("hetzner-deny")["id"], "statement": "TEST", "auth": "touch_id"})
rc, out = otto("save", "hetzner-deny", "password", stdin="new-pw")
check("overwrite refused while away", rc == 3, out)

print("10. the seal survives a restart")
p.stdin.close()
p.wait(5)
p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=env, text=True, bufsize=1)
threading.Thread(target=reader, daemon=True).start()
call("unlock", {"password": "test-key"})
check("still on after reopening", entry("hetzner-deny")["bypass"] is not None)
p.stdin.close()
p.wait(5)
shutil.rmtree(home, ignore_errors=True)
print(f"{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
