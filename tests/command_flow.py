"""What's new for agents, on a throwaway vault: asking the user about a command (otto approve, MCP run_command),
entries limited to some projects or agents, the vault locking itself, the trash, an agent's own log.
This script plays Otto.app while the CLI and `otto mcp` play the agent.
Usage: python3 tests/command_flow.py <otto binary>"""
import json, os, subprocess, sys, tempfile, threading, time

exe = os.path.abspath(sys.argv[1])
home = tempfile.mkdtemp(prefix="oc-", dir="/tmp")  # short: the socket path must fit in 104 bytes
work = tempfile.mkdtemp(prefix="oc-work-")
env = dict(os.environ, OTTO_HOME=home)
p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=env, text=True, bufsize=1)
lock = threading.Lock()
waiting, nid = {}, [0]
seen = []  # what the "app" was asked: (op, args)
filled_in = []  # what the user types into blanks
reuses = []  # which blanks they choose to use a secret saved for another command in
marks = []  # which of them they tick remember on
locked = [False]

def send(obj):
    with lock:
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()

def answer(m):
    op, a = m["op"], m["args"]
    seen.append((op, a))
    if op == "approve_command" and a.get("blanks"):
        # the user fills in the blanks of commands that say allowed
        if "allowed" not in a["command"]:
            return {"approved": False, "declined": True}
        return dict({"approved": True, "values": filled_in[:len(a["blanks"])]}, **({"remember": marks[:len(a["blanks"])]} if marks else {}), **({"reuse": reuses[:len(a["blanks"])]} if reuses else {}))
    if op == "approve_command":
        # the user allows commands that say so, and says no to the rest
        return {"approved": "allowed" in a.get("command", "")} if "allowed" in a.get("command", "") else {"approved": False, "declined": True}
    if op == "unlock":
        # Touch ID yes: the app unlocks over its channel, then answers
        call("unlock", {"password": "test-key"})
        locked[0] = False
        return {"unlocked": True}
    if op == "approve":
        return {"approved": True}
    raise RuntimeError("unexpected " + op)

def reader():
    for line in p.stdout:
        m = json.loads(line)
        if m["type"] == "res" and m["id"] in waiting:
            waiting[m["id"]][1] = m
            waiting[m["id"]][0].set()
        elif m["type"] == "req":
            def go(m=m):
                try:
                    send({"type": "res", "id": m["id"], "ok": True, "result": answer(m)})
                except Exception as e:
                    send({"type": "res", "id": m["id"], "ok": False, "error": {"code": "x", "message": str(e)}})
            threading.Thread(target=go, daemon=True).start()

threading.Thread(target=reader, daemon=True).start()

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

ok = fail = 0
def check(what, cond, extra=""):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ") + what + (f"  [{extra!r}]" if not cond else ""))
    ok, fail = ok + bool(cond), fail + (not cond)

def otto(*args, cwd=work):
    return subprocess.run([exe, *args], capture_output=True, text=True, env=env, timeout=30, cwd=cwd)

call("unlock", {"password": "test-key", "create": True})
def tilde(path):
    path, h = os.path.realpath(path), os.path.realpath(os.environ["HOME"])
    return "~" + path[len(h):] if path == h or path.startswith(h + "/") else path
here = tilde(work)

print("1. otto approve: the user sees the command, and only then does it run")
r = otto("approve", "--why", "make the marker you asked for", "--", "/bin/sh", "-c", "echo allowed > marker; exit 7")
asked = [a for op, a in seen if op == "approve_command"]
check("it ran after the yes, with its exit code", r.returncode == 7 and open(os.path.join(work, "marker")).read() == "allowed\n", r.stderr)
check("the app was shown the exact command, the folder it runs in and why",
      asked and asked[-1]["command"] == "echo allowed > marker; exit 7" and asked[-1]["why"] == "make the marker you asked for" and asked[-1]["folder"] == here, (asked[-1:], here))
r = otto("approve", "--", "rm", "-rf", "build dir")
check("a no: it doesn't run, exit 3, says not to try another way",
      r.returncode == 3 and "didn't allow `rm -rf 'build dir'`" in r.stderr and "don't run it some other way" in r.stderr, r.stderr)
r = otto("approve", "--", "/bin/sh", "-c", "echo allowed")
r2 = otto("approve", "--", "/bin/sh", "-c", "echo allowed")
check("each run asks again", len([1 for op, _ in seen if op == "approve_command"]) == 4 and r2.stdout == "allowed\n", r2.stdout)
failed = [json.loads(l) for l in open(os.path.join(home, "activity.jsonl")) if '"op":"approve_command"' in l and '"ok":false' in l][-1]
check("the log says it to the user: no instructions meant for the agent", failed["detail"].startswith("you didn't allow `rm -rf 'build dir'`") and "don't run it" not in failed["detail"] and "the user" not in failed["detail"], failed["detail"])
r = otto("approve", "--why", "x")
check("no command: usage", r.returncode == 1 and "usage" in r.stderr, r.stderr)

print("2. MCP run_command: allowed, run, output back")
m = subprocess.Popen([exe, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1, cwd=work)
def mcp(i, method, params):
    m.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": method, "params": params}) + "\n")
    m.stdin.flush()
    return json.loads(m.stdout.readline())
mcp(1, "initialize", {"protocolVersion": "2025-06-18"})
tools = [t["name"] for t in mcp(2, "tools/list", {})["result"]["tools"]]
check("the tool is listed", "run_command" in tools, tools)
res = mcp(3, "tools/call", {"name": "run_command", "arguments": {"command": "echo allowed; pwd; echo warn >&2", "why": "show the folder"}})["result"]
text = res["content"][0]["text"]
check("it ran in the project folder and returned its output",
      not res["isError"] and text.startswith("allowed by the user; it ran and exited 0") and f"allowed\n{os.path.realpath(work)}" in text and "--- errors ---\nwarn" in text, text)
res = mcp(4, "tools/call", {"name": "run_command", "arguments": {"command": "touch nope", "why": "x"}})["result"]
check("declined: an error, nothing ran", res["isError"] and "didn't allow" in res["content"][0]["text"] and not os.path.exists(os.path.join(work, "nope")), res)
m.stdin.close()
m.wait(5)

print("2b. a command with blanks: the user fills them in, the service runs it, the agent doesn't see the values")
m = subprocess.Popen([exe, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, text=True, bufsize=1, cwd=work)
mcp(1, "initialize", {"protocolVersion": "2025-06-18"})
schema = next(t for t in mcp(2, "tools/list", {})["result"]["tools"] if t["name"] == "run_command")["inputSchema"]["properties"]
check("run_command says how", "blanks" in schema, schema)
SECRET = "hunter2-very-secret"
ATTACK = "me you; touch hacked; $(touch hacked2)"
filled_in[:] = [ATTACK, SECRET]
before = len(seen)
res = mcp(3, "tools/call", {"name": "run_command", "arguments": {
    "command": "echo allowed; printf 'id=[%s]\\n' {{apple id}}; echo \"pw={{app password}}\"; printf '%s' {{app password}} | base64; pwd; echo warn {{app password}} >&2; exit 4",
    "why": "store the login", "blanks": [{"name": "apple id"}, {"name": "app password", "secret": True}]}})["result"]
text = res["content"][0]["text"]
asked = seen[before][1]
check("the app sees the command with its blanks, and which are secret",
      "{{app password}}" in asked["command"] and asked["blanks"] == [{"name": "apple id", "secret": False, "saved": False}, {"name": "app password", "secret": True, "saved": False}], asked)
check("it ran in the project folder, with its exit code", text.startswith("allowed by the user; it ran and exited 4") and os.path.realpath(work) in text, text)
check("what the agent gets hides the secret, as is and in base64", SECRET not in text and "hunter2" not in text and "pw=••••" in text and "warn ••••" in text, text)
check("what the user typed is hidden too", ATTACK not in text, text)
check("what the user typed is one argument and nothing in it runs", "id=[••••]" in text and not os.path.exists(os.path.join(work, "hacked")) and not os.path.exists(os.path.join(work, "hacked2")), text)
logged = open(os.path.join(home, "activity.jsonl")).read()
check("the log has the blank's name, never the value", "{{app password}}" in logged and SECRET not in logged and "touch hacked" not in logged, logged[-400:])
filled_in[:] = ["somebody"]
r = otto("approve", "--why", "x", "--blank", "who", "--", "/bin/sh", "-c", "echo allowed {{who}}; echo oops >&2; exit 7")
check("otto approve: the same, with its exit code and streams", r.returncode == 7 and r.stdout == "allowed ••••\n" and r.stderr == "oops\n", (r.returncode, r.stdout, r.stderr))
filled_in[:] = ["two words", "hunter2-very-secret"]
r = otto("approve", "--blank", "who", "--secret-blank", "pw", "--", "/usr/bin/printf", "allowed %s|%s", "{{who}}", "--x={{pw}}")
check("otto approve without a shell: the command reads like one, each blank one argument",
      seen[-1][1]["command"] == "/usr/bin/printf 'allowed %s|%s' {{who}} --x={{pw}}" and r.stdout.strip() == "allowed ••••|--x=••••", (seen[-1][1]["command"], r.stdout, r.stderr))
filled_in[:] = ["somebody"]
agent_env = dict(env, PATH="/tmp/agent-bin")
r = subprocess.run([exe, "approve", "--blank", "who", "--", "/bin/sh", "-c", "echo allowed {{who}} \"$PATH\""], capture_output=True, text=True, env=agent_env, cwd=work, timeout=30)
check("the PATH is the user's, not the agent's", "/usr/bin" in r.stdout and "agent-bin" not in r.stdout, r.stdout + r.stderr)
before = len(seen)
r = otto("approve", "--blank", "who", "--", "/bin/sh", "-c", "touch nope2 {{who}}")
check("declined: nothing runs", r.returncode == 3 and not os.path.exists(os.path.join(work, "nope2")), r.stderr)
before = len(seen)
r = otto("approve", "--blank", "who", "--", "/bin/sh", "-c", "echo allowed '{{who}}'")
check("a blank in single quotes is refused before anyone's asked", r.returncode != 0 and "single quotes" in r.stderr and len(seen) == before, r.stderr)
r = otto("approve", "--blank", "who", "--", "/bin/sh", "-c", "echo allowed")
check("a blank that isn't in the command too", r.returncode != 0 and "no {{who}}" in r.stderr and len(seen) == before, r.stderr)
r = otto("approve", "--", "/bin/sh", "-c", "echo allowed '{{.State}}'")
check("without blanks, braces are just braces, and otto approve runs it itself", r.stdout == "allowed {{.State}}\n" and "blanks" in seen[-1][1] and seen[-1][1]["blanks"] == [], r.stdout)
m.stdin.close()
m.wait(5)

print("2c. remembering what was typed: in the vault, never for the agent")
filled_in[:], marks[:] = ["kept@example.com", "kept-secret-123"], [True, True]
T1 = ["--blank", "apple id", "--secret-blank", "the pw", "--", "/bin/sh", "-c", "echo allowed {{apple id}} {{the pw}}"]
r = otto("approve", *T1)
check("the first time nothing is saved, and it runs", seen[-1][1]["blanks"] == [{"name": "apple id", "secret": False, "saved": False}, {"name": "the pw", "secret": True, "saved": False}] and r.stdout == "allowed •••• ••••\n", (seen[-1][1]["blanks"], r.stdout))
filled_in[:] = ["", ""]
r = otto("approve", *T1)
b = seen[-1][1]["blanks"]
check("next time the window is told: the value when it isn't secret, only that it's there when it is", b == [{"name": "apple id", "secret": False, "saved": True, "value": "kept@example.com"}, {"name": "the pw", "secret": True, "saved": True}], b)
check("left empty, what's saved is used, and hidden from the agent", r.returncode == 0 and r.stdout == "allowed •••• ••••\n", (r.stdout, r.stderr))
r = otto("approve", "--blank", "apple id", "--secret-blank", "the pw", "--", "/bin/sh", "-c", "echo allowed elsewhere {{apple id}} {{the pw}}")
b = seen[-1][1]["blanks"]
check("in another command the name still comes back, the secret doesn't", b[0]["saved"] and not b[1]["saved"] and r.returncode != 0 and "fill in the pw" in r.stderr, (b, r.stderr))
r = otto("approve", "--blank", "the pw", "--blank", "apple id", "--", "/bin/sh", "-c", "echo allowed {{apple id}} {{the pw}}")
b = seen[-1][1]["blanks"]
check("calling the secret not secret doesn't bring it out", not b[0]["saved"] and "value" not in b[0], b)
import socket as _s
def agent_op(op, args={}):
    s = _s.socket(_s.AF_UNIX); s.connect(os.path.join(home, "otto.sock")); s.sendall((json.dumps({"id": 1, "op": op, "args": args}) + "\n").encode())
    return json.loads(s.makefile().readline())
def kept():
    return {x["name"]: x for x in call("entries") if x["kind"] == "value"}
listed = kept()
check("they're entries in the vault: the app gets the plain one's value, not the secret's", set(listed) == {"apple id", "the pw"} and "kept-secret-123" not in json.dumps(listed) and listed["apple id"]["value"] == "kept@example.com" and listed["the pw"]["secret"] and listed["the pw"]["commands"] == ["echo allowed {{apple id}} {{the pw}}"], listed)
got = agent_op("list")["result"]
check("an agent sees their names and where they come back, never what's in them", {x["name"] for x in got} >= {"apple id", "the pw"} and "kept-secret-123" not in json.dumps(got) and "kept@example.com" not in json.dumps(got) and next(x for x in got if x["name"] == "the pw")["commands"] == listed["the pw"]["commands"] and "value" not in next(x for x in got if x["name"] == "apple id"), got)
for op, a in [("env", {"entry": "the pw"}), ("type", {"entry": "the pw", "field": "value"}), ("code", {"entry": "apple id"}), ("fill", {"entry": "apple id"})]:
    got = agent_op(op, a)
    check(f"an agent can't get at one by name: {op}", not got.get("ok") and got["error"]["code"] == "not_found", got)
for op, a in [("env", {"entry": listed["the pw"]["id"]}), ("type", {"entry": listed["the pw"]["id"], "field": "value"})]:
    got = agent_op(op, a)
    check(f"or by its id: {op}", not got.get("ok") and got["error"]["code"] == "wrong_kind" and "kept-secret-123" not in json.dumps(got), got)
got = agent_op("save", {"entry": listed["the pw"]["id"], "field": "value", "value": "kept-secret-123"})
check("guessing at one by saving over it gets refused, whatever the guess", not got.get("ok") and got["error"]["code"] == "exists" and kept()["the pw"]["commands"] == listed["the pw"]["commands"], got)
logged = open(os.path.join(home, "activity.jsonl")).read()
check("the log says what was remembered, by name only", "kept-secret-123" not in logged and "kept@example.com" not in logged and '"op":"remembered"' in logged, logged[-300:])
filled_in[:], marks[:] = ["", "new-secret-456"], [True, True]
r = otto("approve", *T1)
filled_in[:] = ["", ""]
r = otto("approve", "--blank", "apple id", "--secret-blank", "the pw", "--", "/bin/sh", "-c", "echo allowed {{apple id}} {{the pw}} | tr -d '•' ; printf %s {{the pw}} | wc -c")
filled_in[:] = ["", ""]
marks[:] = [True, False]
r = otto("approve", *T1)
check("unticking uses it once more, then forgets it", r.returncode == 0 and "the pw" not in kept(), (r.stderr, kept()))
check("into the trash, so it can come back", any(x["name"] == "the pw" and x["kind"] == "value" for x in call("trash")))
r = otto("approve", *T1)
check("and then it has to be typed again", r.returncode != 0 and "fill in the pw" in r.stderr, r.stderr)

print("2c2. changing what's kept")
id_ = kept()["apple id"]["id"]
filled_in[:], marks[:] = ["", "typed-1"], [True, True]
call("upsert", {"patch": {"id": id_, "fields": {"value": "edited@example.com"}}})
r = otto("approve", *T1)
check("an edited value is what comes back", seen[-1][1]["blanks"][0]["value"] == "edited@example.com" and r.returncode == 0, seen[-1][1]["blanks"])
call("upsert", {"patch": {"id": kept()["the pw"]["id"], "name": "the password"}})
check("a new name takes the commands along", kept()["the password"]["commands"] == ["echo allowed {{apple id}} {{the password}}"], kept())
call("upsert", {"patch": {"id": kept()["the password"]["id"], "name": "the pw"}})
def refused(patch):
    try:
        call("upsert", {"patch": patch})
        return ""
    except BaseException as e:
        return str(e)
got = refused({"id": kept()["the pw"]["id"], "commands": ["no blank here"]})
check("a command without its blank is refused", "no blank here" in got and "never come back" in got, got)
got = refused({"name": "apple id", "kind": "value", "secret": False, "fields": {"value": "second"}})
check("two plain values can't share a name", "already have a value" in got, got)
call("upsert", {"patch": {"name": "the pw", "kind": "value", "secret": True, "fields": {"value": "other-tool-pw"}, "commands": ["other {{the pw}}"]}})
check("two secrets can, for different commands", sum(x["name"] == "the pw" and x["kind"] == "value" for x in call("entries")) == 2)
call("delete", {"id": next(x["id"] for x in call("entries") if x["name"] == "the pw" and x["commands"] == ["other {{the pw}}"])})
call("upsert", {"patch": {"name": "github", "password": "login-pw", "sites": ["github.example"], "policy": "auto", "scripts": True}})
call("upsert", {"patch": {"name": "github", "kind": "value", "secret": False, "fields": {"value": "my-org"}}})
got = agent_op("env", {"entry": "github"})
check("a value doesn't get in a login's way, even with the same name", got.get("ok") and got["result"]["values"][""] == "login-pw", got)
call("delete", {"id": next(x["id"] for x in call("entries") if x["name"] == "github" and x["kind"] == "value")})
call("delete", {"id": next(x["id"] for x in call("entries") if x["name"] == "github")})
call("upsert", {"patch": {"id": kept()["apple id"]["id"], "policy": "never"}})
filled_in[:], marks[:] = ["", "typed-1"], [False, True]
r = otto("approve", *T1)
check("set to Never it doesn't come back", not seen[-1][1]["blanks"][0]["saved"] and r.returncode != 0 and "fill in apple id" in r.stderr, (seen[-1][1]["blanks"], r.stderr))
check("nor shows to agents", "apple id" not in {x["name"] for x in agent_op("list")["result"]})
filled_in[:], marks[:] = ["me", "typed-1"], [False, True]
r = otto("approve", *T1)
check("and leaving remember unticked doesn't throw it away", r.returncode == 0 and "apple id" in kept(), r.stderr)
call("delete", {"id": kept()["apple id"]["id"]})

print("2c3. a secret you saved, in a command it isn't for")
call("upsert", {"patch": {"name": "the key", "kind": "value", "secret": True, "fields": {"value": "typed-by-hand"}}})
check("a secret typed in by hand comes back for nothing yet", kept()["the key"]["commands"] == [], kept())
K1 = ["--secret-blank", "the key", "--", "/bin/sh", "-c", "echo allowed one {{the key}}"]
filled_in[:], marks[:], reuses[:] = [""], [False], [False]
r = otto("approve", *K1)
check("the window says it's there, and otto doesn't use it on its own", seen[-1][1]["blanks"][0].get("elsewhere") == [] and not seen[-1][1]["blanks"][0]["saved"] and r.returncode != 0 and "fill in the key" in r.stderr, (seen[-1][1]["blanks"], r.stderr))
reuses[:] = [True]
r = otto("approve", *K1)
check("the user chooses to use it: it runs, hidden", r.returncode == 0 and r.stdout == "allowed one ••••\n", (r.stdout, r.stderr))
check("once, unless they tick remember", kept()["the key"]["commands"] == [], kept())
marks[:] = [True]
r = otto("approve", *K1)
check("with remember it comes back for this command from now on", kept()["the key"]["commands"] == ["echo allowed one {{the key}}"], kept())
reuses[:], filled_in[:] = [], [""]
r = otto("approve", *K1)
check("no choice needed anymore", seen[-1][1]["blanks"][0]["saved"] and "elsewhere" not in seen[-1][1]["blanks"][0] and r.returncode == 0, seen[-1][1]["blanks"])
K2 = ["--secret-blank", "the key", "--", "/bin/sh", "-c", "echo allowed two {{the key}}"]
filled_in[:], marks[:] = ["typed-by-hand"], [True]
r = otto("approve", *K2)
check("typing the same secret for another command doesn't make a second one", kept()["the key"]["commands"] == ["echo allowed one {{the key}}", "echo allowed two {{the key}}"], kept())
filled_in[:], marks[:] = [""], [False]
r = otto("approve", *K2)
check("unticking only takes that command off", kept()["the key"]["commands"] == ["echo allowed one {{the key}}"] and r.returncode == 0, kept())
filled_in[:], marks[:] = ["a-different-secret"], [True]
r = otto("approve", *K2)
check("a different secret under the name is its own value", sum(x["name"] == "the key" for x in call("entries")) == 2 and r.returncode == 0, kept())
for x in call("entries"):
    if x["kind"] == "value":
        call("delete", {"id": x["id"]})
check("all gone", kept() == {}, kept())
marks[:], filled_in[:] = [], []

print("2c4. keeping something from agents when saving it")
r = subprocess.run([exe, "save", "signing key", "key", "--kind", "key", "--policy", "auto"], input="abc", env=env, text=True, capture_output=True)
check("an agent can't save it open with --policy auto", r.returncode != 0 and "only the user" in r.stderr, r.stderr)
r = subprocess.run([exe, "save", "signing key", "notes", "--kind", "key"], input="how to restore it", env=env, text=True, capture_output=True)
r = subprocess.run([exe, "save", "signing key", "key"], input="abc", env=env, text=True, capture_output=True)
check("saved", r.returncode == 0 and r.stdout.startswith("saved key"), r.stdout)
r = subprocess.run([exe, "save", "signing key", "key", "--policy", "never"], input="abc", env=env, text=True, capture_output=True)
check("saving the same value again says so, and it can still be locked", r.stdout.startswith("already had key") and next(x for x in call("entries") if x["name"] == "signing key")["policy"] == "never", (r.stdout, r.stderr))
r = subprocess.run([exe, "save", "signing key", "key", "--policy", "ask"], input="abc", env=env, text=True, capture_output=True)
check("then an agent can't touch it", r.returncode != 0 and "off-limits" in r.stderr and next(x for x in call("entries") if x["name"] == "signing key")["policy"] == "never", r.stderr)
call("delete", {"id": next(x["id"] for x in call("entries") if x["name"] == "signing key")})
for x in call("trash"):
    call("purge", {"id": x["id"]})

print("2e. the browser helper leaves when otto is updated or moved, so the browser starts the new one")
import shutil
def helper_dies_when(change):
    d = tempfile.mkdtemp(prefix="oh-", dir="/tmp")
    copy = os.path.join(d, "otto")
    shutil.copy(exe, copy)
    # no service in that home, so it just keeps trying, like during an update
    h = subprocess.Popen([copy, "chrome-extension://abc/"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=dict(env, OTTO_HOME=d))
    time.sleep(3)
    alive = h.poll() is None
    change(copy)
    try:
        h.wait(6)
    except subprocess.TimeoutExpired:
        h.kill()
        return alive, False
    return alive, True
def replace(copy):
    shutil.copy(exe, copy + ".new")
    os.replace(copy + ".new", copy)
alive, gone = helper_dies_when(replace)
check("it keeps trying while its binary stays put", alive)
check("a new binary in its place: it leaves", gone)
alive, gone = helper_dies_when(lambda copy: os.rename(copy, copy + ".moved"))
check("its binary moved away: it leaves", alive and gone)

print("2d. how long otto waits is the user's setting")
w = call("waits")
check("the usual times", w == {"blanks": 900, "save": 900, "approve": 300, "mac_password": 270, "browser": 180, "phone": 900}, w)
r = otto("approve", "--", "/bin/sh", "-c", "echo allowed")
check("the window is told how long it has", seen[-1][1]["expires_in"] == 300, seen[-1][1].get("expires_in"))
filled_in[:] = ["somebody"]
r = otto("approve", "--blank", "who", "--", "/bin/sh", "-c", "echo allowed {{who}}")
check("longer with blanks to fill in", seen[-1][1]["expires_in"] == 900, seen[-1][1].get("expires_in"))
call("set_waits", {"waits": dict(w, approve=60, blanks=1800)})
r = otto("approve", "--", "/bin/sh", "-c", "echo allowed")
check("changed in Settings: a new time", seen[-1][1]["expires_in"] == 60, seen[-1][1].get("expires_in"))
r = otto("approve", "--blank", "who", "--", "/bin/sh", "-c", "echo allowed {{who}}")
check("each kind its own", seen[-1][1]["expires_in"] == 1800, seen[-1][1].get("expires_in"))
for bad, why in ((dict(w, approve=5), "too short"), (dict(w, phone=99999), "too long")):
    try:
        call("set_waits", {"waits": bad})
        check(f"refused: {why}", False, bad)
    except RuntimeError:
        check(f"refused: {why}", True)
got = agent_op("set_waits", {"waits": dict(w, approve=3600)})
check("an agent can't change them", not got.get("ok") and call("waits")["approve"] == 60, got)
call("set_waits", {"waits": w})

print("3. entries limited to some projects or agents")
# a limit is about the folder the agent's session works in (where it started), whatever folder one command runs in
session = next(l["folder"] for l in call("log", {"limit": 50}) if l.get("op") == "approve_command")
me = next(l["agent"] for l in call("log", {"limit": 50}) if l.get("op") == "approve_command")
call("upsert", {"patch": {"name": "open", "password": "pw", "policy": "auto"}})
call("upsert", {"patch": {"name": "elsewhere", "password": "pw", "policy": "auto", "folders": ["~/some-other-project"]}})
call("upsert", {"patch": {"name": "here", "password": "pw", "policy": "auto", "folders": [session]}})
other = "codex" if me != "codex" else "claude"
call("upsert", {"patch": {"name": f"{other} only", "password": "pw", "policy": "auto", "agents": [other]}})
ls = otto("ls").stdout
names = [l.split()[0] for l in ls.splitlines() if l.strip()]
check(f"ls shows what's open to {me} in {session}", sorted(names) == ["here", "open"], ls)
r = otto("code", "elsewhere")
check("using one limited to another project: denied, saying why", r.returncode == 3 and "limited it to certain projects or agents" in r.stderr, r.stderr)
call("upsert", {"patch": {"id": next(e["id"] for e in call("entries") if e["name"] == "here"), "folders": [session + "-not"]}})
names = [l.split()[0] for l in otto("ls").stdout.splitlines() if l.strip()]
check("a folder that only starts the same isn't inside", "here" not in names and "open" in names, names)
st = otto("status").stdout
check("status counts only what it could use", "entries: 1" in st and len(call("entries")) == 4, st)

print("4. the vault locks itself; an agent's request asks the user to unlock it")
call("lock")
seen.clear()
ls = otto("ls").stdout
check("an agent's request made the app ask to unlock", any(op == "unlock" for op, _ in seen) and "open" in ls, (seen, ls))

print("5. the trash")
ids = {e["name"]: e["id"] for e in call("entries")}
call("delete", {"id": ids["open"]})
check("deleted: gone for agents", "open" not in otto("ls").stdout.split())
t = call("trash")
check("in the trash, with when", [x["name"] for x in t] == ["open"] and t[0]["deleted"], t)
call("restore", {"id": ids["open"]})
check("restored: back for agents", "open" in otto("ls").stdout.split() and call("trash") == [])
call("delete", {"id": ids["open"]})
call("empty_trash")
check("emptied", call("trash") == [] and "open" not in [e["name"] for e in call("entries")])
backups = call("backups")
check("backups were made along the way", len(backups) >= 1 and backups[0]["name"].startswith("vault-"), backups)

print("6. an agent's log is its own")
# another agent's line, in another folder
with open(os.path.join(home, "activity.jsonl"), "a") as f:
    f.write(json.dumps({"ts": "2026-10-20T10:00:00Z", "agent": other, "op": "code", "entry": "secret-project", "ok": True, "detail": "got a code", "folder": "~/secret-project"}) + "\n")
check("the app's log has it", any(l["agent"] == other for l in call("log", {"limit": 500})))
out = otto("log", "500").stdout
cols = {line.split()[1] for line in out.splitlines() if line.strip()}
check(f"{me}'s own log doesn't", cols == {me} and "secret-project" not in out, (cols, out[-300:]))

p.stdin.close()
p.wait(5)
print(f"{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
