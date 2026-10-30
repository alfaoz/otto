"""`otto run` masks what the command prints, on a throwaway vault. This script plays Otto.app (says yes
to approvals) while the CLI plays the agent.
Usage: python3 tests/run_flow.py <otto binary>
(OTTO_TEST_HOME=<short dir> puts the throwaway vault there instead of a new folder in /tmp.)"""
import base64, json, os, pty, select, signal, subprocess, sys, tempfile, threading, time, urllib.parse

exe = os.path.abspath(sys.argv[1])
home = os.environ.get("OTTO_TEST_HOME") or tempfile.mkdtemp(prefix="or-", dir="/tmp")  # short: socket path
os.makedirs(home, exist_ok=True)
env = dict(os.environ, OTTO_HOME=home)
env.pop("OTTO_TEST_HOME", None)
p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=env, text=True, bufsize=1)
lock = threading.Lock()
waiting, nid = {}, [0]

def send(obj):
    with lock:
        p.stdin.write(json.dumps(obj) + "\n")
        p.stdin.flush()

def reader():
    for line in p.stdout:
        m = json.loads(line)
        if m["type"] == "res" and m["id"] in waiting:
            waiting[m["id"]][1] = m
            waiting[m["id"]][0].set()
        elif m["type"] == "req":
            ok = m["op"] == "approve"
            send({"type": "res", "id": m["id"], "ok": ok, "result": {"approved": True}} if ok else
                 {"type": "res", "id": m["id"], "ok": False, "error": {"code": "x", "message": "unexpected " + m["op"]}})

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

ok = fail = 0
def check(what, cond, extra=""):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ") + what + (f"  [{extra!r}]" if not cond else ""))
    ok, fail = ok + bool(cond), fail + (not cond)

KEY = "sk-TEST-run-0123456789abcdef"
ODD = 'TEST p@ss/"wörd"\\x!(1)'
MASK = "••••"
call("unlock", {"password": "test-key", "create": True})
call("upsert", {"patch": {"name": "openai", "kind": "key", "fields": {"key": KEY}, "scripts": True, "policy": "auto"}})
call("upsert", {"patch": {"name": "odd", "kind": "key", "fields": {"key": ODD}, "scripts": True, "policy": "auto"}})
call("upsert", {"patch": {"name": "pin", "kind": "key", "fields": {"key": "4821"}, "scripts": True, "policy": "auto"}})

def run(*cmd, entry="openai", var="K", **kw):
    return subprocess.run([exe, "run", "--env", f"{var}={entry}", "--", *cmd], capture_output=True, text=True, env=env, timeout=30, **kw)

print("1. the command gets the value, its output doesn't show it")
r = run("/bin/sh", "-c", f'[ "$K" = "{KEY}" ] && echo same')
check("the command gets the value as is", r.returncode == 0 and r.stdout == "same\n", r.stdout + r.stderr)
r = run("/usr/bin/printenv", "K")
check("printenv", r.stdout == MASK + "\n", r.stdout)
r = run("/bin/sh", "-c", 'echo "key is $K, ok"')
check("echo", r.stdout == f"key is {MASK}, ok\n", r.stdout)
r = run("/bin/sh", "-c", 'echo "$K" >&2')
check("stderr too", r.stderr == MASK + "\n" and r.stdout == "", r.stderr)
r = run("/bin/sh", "-c", 'printf %s "$K" | base64')
check("base64", r.stdout.strip() == MASK and base64.b64encode(KEY.encode()).decode() not in r.stdout, r.stdout)
r = run("/bin/sh", "-c", 'printf "user:%s" "$K" | base64')
check("base64 of user:KEY (basic auth)", MASK in r.stdout and len(r.stdout.strip()) < 20, r.stdout)
r = run("/bin/sh", "-c", 'printf %s "$K" | xxd -p')
check("hex", r.stdout.strip() == MASK, r.stdout)
r = run("/usr/bin/python3", "-c", "import json,os,urllib.parse as u; k=os.environ['K']; print(json.dumps({'k':k})); print(u.quote(k)); print(u.quote(k, safe=''))", entry="odd")
check("JSON and URL-encoded", r.stdout == f'{{"k": "{MASK}"}}\n{MASK}\n{MASK}\n' and "w\\u00f6rd" not in r.stdout, r.stdout)
r = run("/bin/sh", "-c", 'echo "pin $K"', entry="pin")
check("a value under 6 characters isn't masked", r.stdout == "pin 4821\n", r.stdout)
r = run("/bin/sh", "-c", 'printf %s "$K" | head -c 9; sleep 1; printf %s "$K" | tail -c +10; echo')
check("printed in two pieces a second apart", r.stdout == MASK + "\n", r.stdout)
r = subprocess.run([exe, "run", "--env", "A=openai", "--env", "B=odd", "--", "/bin/sh", "-c", 'echo "$A|$B"'], capture_output=True, text=True, env=env, timeout=30)
check("two entries at once", r.stdout == f"{MASK}|{MASK}\n", r.stdout)
r = run("/bin/sh", "-c", "head -c 3000 /dev/urandom | od -An -tx1 | head -c 100000; printf 'tail\\n'")
check("other output passes untouched", r.stdout.endswith("tail\n") and r.stdout.count("\n") > 100, r.stdout[-200:])
data = bytes(range(256)) * 64
r = subprocess.run([exe, "run", "--env", "K=openai", "--", "/bin/cat"], input=data, capture_output=True, env=env, timeout=30)
check("binary output and stdin pass through", r.stdout == data, len(r.stdout))

print("2. exit codes and signals")
r = run("/bin/sh", "-c", "exit 7")
check("exit code passes through", r.returncode == 7, r.returncode)
r = run("/bin/sh", "-c", "kill -TERM $$")
check("killed by a signal: 128 + signal", r.returncode == 128 + 15, r.returncode)
r = run("/nonexistent/thing")
check("a command that doesn't exist is otto's error", r.returncode != 0 and "couldn't run /nonexistent/thing" in r.stderr, r.stderr)

PROG = r"""
import os, signal, sys, time
got = []
for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(s, lambda n, f: got.append(n))
print("ready", flush=True)
end = time.time() + 1.5
while time.time() < end and not got:
    time.sleep(0.02)
time.sleep(0.3)
open(sys.argv[1], "w").write(",".join(signal.Signals(n).name for n in got))
print("bye", flush=True)
"""
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    out = os.path.join(home, "got")
    if os.path.exists(out):
        os.remove(out)
    q = subprocess.Popen([exe, "run", "--env", "K=openai", "--", "/usr/bin/python3", "-c", PROG, out], stdout=subprocess.PIPE, text=True, env=env)
    first = q.stdout.readline()
    q.send_signal(sig)
    rest = q.stdout.read()
    q.wait(10)
    got = open(out).read() if os.path.exists(out) else ""
    check(f"{sig.name} sent to otto reaches the command once", first == "ready\n" and got == sig.name and rest == "bye\n" and q.returncode == 0, (first, got, rest, q.returncode))

def finish(pid, fd, buf=b""):
    """read the pty until everything on it is gone (a closing terminal waits for its output to be read)"""
    while True:
        try:
            if not select.select([fd], [], [], 5)[0]:
                break
            b = os.read(fd, 4096)
        except OSError:
            break
        if not b:
            break
        buf += b
    return buf, os.waitpid(pid, 0)[1]

# ^C typed on a terminal reaches otto and the command together (same process group): no second copy
out = os.path.join(home, "got")
os.remove(out)
pid, fd = pty.fork()
if pid == 0:
    os.execve("/bin/sh", ["/bin/sh", "-c", f"'{exe}' run --env K=openai -- /usr/bin/python3 -c '{PROG}' {out} | cat"], env)
buf = b""
end = time.time() + 10
while b"ready" not in buf and time.time() < end:
    if select.select([fd], [], [], 0.2)[0]:
        buf += os.read(fd, 1024)
os.write(fd, b"\x03")
buf, _ = finish(pid, fd, buf)
got = open(out).read() if os.path.exists(out) else ""
check("^C on the terminal reaches it once", got == "SIGINT", (got, buf))

print("3. streaming and terminals")
r = subprocess.Popen([exe, "run", "--env", "K=openai", "--", "/usr/bin/python3", "-c",
                      "import time\nfor i in range(5):\n    print(repr(time.time()), flush=True); time.sleep(0.3)"],
                     stdout=subprocess.PIPE, text=True, env=env)
lags = []
for line in r.stdout:
    lags.append(time.time() - float(line))
r.wait()
check("each line arrives as it's printed", len(lags) == 5 and max(lags) < 0.15, [round(x, 3) for x in lags])
r = subprocess.Popen([exe, "run", "--env", "K=openai", "--", "/bin/sh", "-c", "printf 'Password: '; sleep 1; echo"],
                     stdout=subprocess.PIPE, env=env)
t = time.time()
first = r.stdout.read1(100) if hasattr(r.stdout, "read1") else r.stdout.read(10)
check("a prompt without a newline isn't held back", first == b"Password: " and time.time() - t < 0.5, (first, time.time() - t))
r.wait()

TTY = f"""[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo tty-yes; echo "$K"; stty size; printf 'value: %s' "$K" | head -c 12; sleep 0.5; printf %s "$K" | tail -c +6; echo; exit 3"""
r = subprocess.run(["/usr/bin/script", "-q", "/dev/null", exe, "run", "--env", "K=openai", "--", "/bin/sh", "-c", TTY],
                   capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL, timeout=30)
lines = r.stdout.replace("\r", "").split("\n")
# (script itself types ^D into the terminal when its own input ends: that's the "^D" in its output)
check("on a terminal the command gets one too", any(l.endswith("tty-yes") for l in lines), r.stdout)
check("and its output is masked", KEY not in r.stdout and lines.count(MASK) == 1 and f"value: {MASK}" in lines, r.stdout)
check("it gets the terminal's size", any(l and l.split()[0].isdigit() for l in lines), r.stdout)

# a real terminal: color, a key typed into a prompt, the window resized, ^C
pid, fd = pty.fork()
if pid == 0:
    os.execve(exe, [exe, "run", "--env", "K=openai", "--", "/bin/sh", "-c",
                    'trap "echo trapped-int; exit 5" INT; printf "\\033[31mred\\033[0m\\n"; printf "name? "; read n; echo "hi $n $K"; trap "stty size; echo resized" WINCH; echo waiting; sleep 3; sleep 3'], env)
def until(word, t=5):
    global buf
    end = time.time() + t
    while word not in buf and time.time() < end:
        if select.select([fd], [], [], 0.1)[0]:
            try:
                buf += os.read(fd, 4096)
            except OSError:
                break
    return word in buf
buf = b""
until(b"name? ")
os.write(fd, b"alfa\r")
until(b"waiting")
import fcntl, struct, termios
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 33, 101, 0, 0))
os.kill(pid, signal.SIGWINCH)
until(b"resized")
os.write(fd, b"\x03")
buf, status = finish(pid, fd, buf)
text = buf.decode(errors="replace")
check("colors come through", "\x1b[31mred\x1b[0m" in text, text)
check("typing reaches a prompt", "hi alfa " + MASK in text and KEY not in text, text)
check("a resize reaches it", "33 101" in text, text)
check("^C reaches it through the terminal", "trapped-int" in text and os.WEXITSTATUS(status) == 5, (text, status))
pid, fd = pty.fork()
if pid == 0:
    os.execve("/bin/sh", ["/bin/sh", "-c", f"'{exe}' run --env K=openai -- /bin/sh -c 'stty -a | head -c 0'; stty -a"], env)
buf, _ = finish(pid, fd)
text = buf.decode(errors="replace")
check("the terminal's settings come back after", " icanon " in text and " echo " in text and "-icanon" not in text, text)

print(f"\n{ok} ok, {fail} failed")
p.terminate()
sys.exit(1 if fail else 0)
