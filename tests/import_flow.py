"""Login import through the service's private channel, the way Otto.app does it, on a throwaway vault.
Usage: python3 tests/import_flow.py <otto binary>"""
import json, os, subprocess, sys, tempfile

exe = sys.argv[1]
here = os.path.dirname(os.path.abspath(__file__))
home = tempfile.mkdtemp(prefix="oi-", dir="/tmp")  # short: the socket path must fit in 104 bytes
p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     env=dict(os.environ, OTTO_HOME=home), text=True, bufsize=1)
n = [0]

def call(op, args=None):
    n[0] += 1
    p.stdin.write(json.dumps({"type": "req", "id": n[0], "op": op, "args": args or {}}) + "\n")
    p.stdin.flush()
    for line in p.stdout:
        m = json.loads(line)
        if m.get("type") == "res" and m["id"] == n[0]:
            if not m["ok"]:
                raise SystemExit(f"{op} failed: {m['error']}")
            return m["result"]

ok = fail = 0
def check(what, cond):
    global ok, fail
    print(("  ok   " if cond else "  FAIL ") + what)
    ok, fail = ok + bool(cond), fail + (not cond)

call("unlock", {"password": "test", "create": True})
# Hetzner's 2FA is already here as an imported code; importing the login should move it in
hetzner = "otpauth://totp/Hetzner:alfa?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Hetzner"
call("import_save", {"tokens": [{"issuer": "Hetzner", "account": "alfa", "uri": hetzner}]})
call("upsert", {"patch": {"name": "GitHub", "username": "alfaoz", "password": "x", "sites": ["github.com"], "policy": "auto"}})

text = open(os.path.join(here, "fixtures", "passwords.csv")).read()
parsed = call("import_parse", {"text": text})
logins, tokens = parsed["logins"], parsed["tokens"]
check(f"6 logins and 1 code found ({len(logins)}, {len(tokens)})", len(logins) == 6 and len(tokens) == 1)
check("no passwords sent back to the app", "made-up-pw" not in json.dumps(parsed))
check("GitHub marked as already in otto", [l["exists"] for l in logins if l["site"] == "github.com"] == [True])
check("the Android app login has no website", [l["site"] for l in logins if l["name"] == "Bank App"] == [None])

pick = [l["index"] for l in logins if not l["exists"]]
r = call("import_save", {"tokens": [], "text": text, "logins": pick, "policy": "ask"})
check(f"5 logins added ({r['logins_added']})", r["logins_added"] == 5)
entries = {e["name"]: e for e in call("entries")}
check("names cleaned up (news.ycombinator.com, Notion)", "news.ycombinator.com" in entries and "Notion" in entries)
check("imported logins ask for Touch ID", all(entries[k]["policy"] == "ask" for k in ["Notion", "Proton", "Hetzner"]))
check("Proton's 2FA came along", entries["Proton"]["totp"] is not None)
check("Hetzner's code moved into the login", entries["Hetzner"]["totp"] is not None and not entries["Hetzner"]["library"]
      and not any(e["library"] for e in entries.values()))
check("passwords stored", call("secret", {"id": entries["Notion"]["id"], "field": "password"}) == "made-up-pw-4")
check("sites set", entries["Notion"]["sites"] == ["notion.so"] and entries["Hetzner"]["sites"] == ["accounts.hetzner.com"])
p.stdin.close()
p.wait(5)
print(f"{ok} passed, {fail} failed")
sys.exit(1 if fail else 0)
