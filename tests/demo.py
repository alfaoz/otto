"""Builds a throwaway vault full of made-up entries and agent activity, for working on the UI
without touching the real vault.
Usage: python3 tests/demo.py <otto binary> <home dir>
Then: OTTO_HOME=<home dir> OTTO_DEV_KEY=demo-key-not-secret Otto.app/Contents/MacOS/OttoApp"""
import base64, datetime, json, os, random, shutil, subprocess, sys

exe, home = sys.argv[1], sys.argv[2]
KEY = "demo-key-not-secret"
shutil.rmtree(home, ignore_errors=True)
os.makedirs(home)
p = subprocess.Popen([exe, "daemon"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
                     env=dict(os.environ, OTTO_HOME=home))
nid = [0]

def call(op, args):
    nid[0] += 1
    p.stdin.write(json.dumps({"type": "req", "id": nid[0], "op": op, "args": args}) + "\n")
    p.stdin.flush()
    for line in p.stdout:
        m = json.loads(line)
        if m["type"] == "res" and m["id"] == nid[0]:
            if not m["ok"]:
                raise SystemExit(f"{op}: {m['error']}")
            return m["result"]

def secret():
    return base64.b32encode(random.randbytes(20)).decode().rstrip("=")

def otp(issuer, account):
    return f"otpauth://totp/{issuer}:{account}?secret={secret()}&issuer={issuer}"

call("unlock", {"password": KEY, "create": True})

def login(name, user, site=None, policy="auto", tfa="app", app=None, **kw):
    e = dict(name=name, username=user, policy=policy, **kw)
    if site:
        e["sites"] = site if isinstance(site, list) else [site]
    if app:
        e["apps"] = [app]
    if tfa == "app":
        e["otp"] = otp(name, user)
    elif tfa:
        e["two_factor"] = tfa
    return e

# everything below is made up; card numbers are the networks' public test numbers
logins = [
    login("GitHub", "alfaoz", "github.com"),
    login("Vercel", "alfa@example.com", "vercel.com", notes="team plan, billing on the company card"),
    login("Stripe", "alfa@example.com", "dashboard.stripe.com", "ask", notes="live mode. test keys are under the vercel project"),
    login("AWS", "alfa-admin", "signin.aws.amazon.com", "ask", scripts=True, notes="IAM admin, not root. root lives on the yubikey"),
    login("Linear", "alfa@example.com", "linear.app", tfa="delivered"),
    login("Figma", "alfa@example.com", "figma.com", tfa="none"),
    login("Cloudflare", "alfa@example.com", "dash.cloudflare.com", "never"),
    login("Slack", "alfa@example.com", policy="ask", tfa="none", app="com.tinyspeck.slackmacgap"),
    login("Google", "alfa.demo@example.com", "accounts.google.com", "ask", notes="also youtube, drive, gmail"),
    login("Apple Account", "alfa.demo@example.com", "account.apple.com", "ask", tfa="delivered"),
    login("Microsoft", "alfa.demo@example.com", "login.live.com"),
    login("Netflix", "alfa.demo@example.com", "netflix.com", tfa="none", notes="profile: alfa. pin 0000 (demo)"),
    login("Spotify", "alfademo", "spotify.com", tfa="none"),
    login("Amazon", "alfa.demo@example.com", "amazon.com.tr", "ask"),
    login("Trendyol", "+90 555 000 00 00", "trendyol.com", tfa="delivered"),
    login("Hepsiburada", "alfa.demo@example.com", "hepsiburada.com", tfa="delivered"),
    login("Getir", "+90 555 000 00 00", "getir.com", tfa="delivered"),
    login("Garanti BBVA", "12345678950", "garantibbva.com.tr", "never", tfa="delivered", notes="customer no. 00000000 (demo)"),
    login("İş Bankası", "12345678950", "isbank.com.tr", "never", tfa="delivered"),
    login("Papara", "+90 555 000 00 00", "papara.com", "ask", tfa="delivered"),
    login("Binance", "alfa.demo@example.com", "binance.com", "ask", notes="withdrawals whitelisted to the ledger only"),
    login("e-Devlet", "12345678950", "turkiye.gov.tr", "never", tfa="delivered"),
    login("Turkish Airlines", "TK000000000", "turkishairlines.com", tfa="none", notes="Miles&Smiles classic"),
    login("Booking.com", "alfa.demo@example.com", "booking.com", tfa="none"),
    login("Airbnb", "alfa.demo@example.com", "airbnb.com", tfa="delivered"),
    login("Discord", "alfademo", "discord.com"),
    login("X", "@alfademo", "x.com"),
    login("Instagram", "alfa.demo", "instagram.com"),
    login("LinkedIn", "alfa.demo@example.com", "linkedin.com", tfa="none"),
    login("Notion", "alfa@example.com", "notion.so", tfa="none"),
    login("Dropbox", "alfa.demo@example.com", "dropbox.com"),
    login("Steam", "alfademo", "store.steampowered.com", "ask", tfa="delivered"),
    login("Epic Games", "alfademo", "epicgames.com"),
    login("ChatGPT", "alfa.demo@example.com", "chatgpt.com", tfa="none"),
    login("Claude", "alfa.demo@example.com", "claude.ai", tfa="none"),
    login("Hetzner", "alfa", "accounts.hetzner.com", "ask"),
    login("npm", "alfaoz", "npmjs.com", scripts=True),
    login("Home router", "admin", "192.168.1.1", tfa="none", notes="modem: zyxel, bridge mode off"),
    login("Docker Desktop", "alfademo", tfa="none", app="com.docker.docker"),
    login("Zoom", "alfa.demo@example.com", "zoom.us", tfa="none", app="us.zoom.xos"),
]
for e in logins:
    e.setdefault("password", "demo-" + secret()[:12])
    call("upsert", {"patch": e})

def card(name, number, expiry, cvc, holder=None, postal=None, sites=None):
    digits = number.replace(" ", "")
    total = sum((d * 2 - 9 if d * 2 > 9 else d * 2) if i % 2 else d for i, d in enumerate(int(c) for c in reversed(digits)))
    assert total % 10 == 0, name
    f = {"number": number, "expiry": expiry, "cvc": cvc}
    if holder: f["cardholder"] = holder
    if postal: f["postal_code"] = postal
    return dict(name=name, kind="card", policy="ask", sites=sites or [], fields=f)

def key(name, value, env, site, policy="auto"):
    return dict(name=name, kind="key", policy=policy, scripts=True, sites=[site], fields={"key": value, "env": env})

def value(name, text, secret=False, commands=(), notes=None):
    e = dict(name=name, kind="value", secret=secret, fields={"value": text}, commands=list(commands))
    if notes:
        e["notes"] = notes
    return e

def note(name, text, policy="never"):
    return dict(name=name, kind="note", policy=policy, notes=text)

others = [
    card("Personal Visa", "4242 4242 4242 4242", "08/28", "123", "ALFA DEMO", "34710"),
    card("Company Mastercard", "5555 5555 5555 4444", "03/27", "321", "DEMO LTD", sites=["vercel.com", "aws.amazon.com"]),
    card("Troy debit", "9792 0303 0000 0007", "11/29", "456", "ALFA DEMO", sites=["trendyol.com", "hepsiburada.com"]),
    card("Amex Gold", "3782 822463 10005", "04/24", "1234"),
    card("Bonus Platinum", "2223 0031 2200 3222", "09/30", "789", "ALFA DEMO", "34710"),
    card("Travel Discover", "6011 1111 1111 1117", "01/29", "111", "ALFA DEMO", sites=["booking.com", "airbnb.com"]),
    card("JCB Tokyo", "3566 0020 2036 0505", "06/28", "222", "ALFA DEMO"),
    card("UnionPay", "6200 0000 0000 0005", "12/27", "333", "ALFA DEMO"),
    card("Diners Club", "3622 720627 1667", "10/29", "444", "ALFA DEMO"),
    dict(name="Sparkle update key", kind="key", policy="never", fields={"key": "demo" + secret()}, notes="signs otto's updates. if it's lost, nobody gets an update again\nput back with: generate_keys --account otto -f <file>"),
    key("OpenAI", "sk-proj-demo" + secret()[:28], "OPENAI_API_KEY", "platform.openai.com"),
    key("Anthropic", "sk-ant-api03-demo" + secret()[:24], "ANTHROPIC_API_KEY", "console.anthropic.com", "ask"),
    key("Stripe live secret", "sk_live_demo" + secret()[:24], "STRIPE_SECRET_KEY", "dashboard.stripe.com", "ask"),
    key("Stripe test secret", "sk_test_demo" + secret()[:24], "STRIPE_SECRET_KEY", "dashboard.stripe.com"),
    key("GitHub token", "ghp_demo" + secret()[:28], "GITHUB_TOKEN", "github.com"),
    key("AWS access key", "AKIADEMO" + secret()[:12], "AWS_ACCESS_KEY_ID", "aws.amazon.com", "ask"),
    key("Google Maps", "AIzaDemo" + secret()[:28], "GOOGLE_MAPS_API_KEY", "console.cloud.google.com"),
    key("OpenRouter", "sk-or-v1-demo" + secret()[:28], "OPENROUTER_API_KEY", "openrouter.ai"),
    key("Hugging Face", "hf_demo" + secret()[:24], "HF_TOKEN", "huggingface.co"),
    key("Resend", "re_demo" + secret()[:20], "RESEND_API_KEY", "resend.com"),
    key("Groq", "gsk_demo" + secret()[:28], "GROQ_API_KEY", "groq.com"),
    key("Slack bot", "xoxb-demo-" + secret()[:20], "SLACK_BOT_TOKEN", "slack.com"),
    note("Passport", "Alfa Demo\npassport no. U00000000 (demo)\nissued 14 Mar 2022, İstanbul\nexpires 13 Mar 2032"),
    note("Kimlik", "TC kimlik no. 12345678950 (demo)\nseri no. A00Z00000\nbirth date 01.01.2000"),
    note("Home address", "Alfa Demo\nÖrnek Sok. No:7 D:3\nKadıköy 34710 İstanbul\nTürkiye\n+90 555 000 00 00", "ask"),
    note("Driver's license", "license no. 000000 (demo)\nclass B, valid until 2034"),
    note("Health insurance", "policy no. DEMO-0000-0000\nprovider: Demo Sigorta\nemergency line +90 850 000 00 00", "ask"),
    note("Wi-Fi", "home: demo-home-wifi-pass\noffice guest: demo-guest-2026\nmom's: demo-annem-wifi", "auto"),
    note("Recovery codes", "github: demo-1111 demo-2222 demo-3333\nnpm: demo-4444\ngoogle: demo-5555 demo-6666"),
    note("Server notes", "hetzner cx22, fsn1\nssh: deploy@203.0.113.10 (demo address)\nbackups nightly at 03:00", "auto"),
    value("apple id", "alfa.demo@example.com", notes="the developer account"),
    value("team id", "DEMO123456"),
    value("app-specific password", "demo-abcd-efgh-ijkl", True,
          ["xcrun notarytool store-credentials otto-notary --apple-id {{apple id}} --team-id {{team id}} --password {{app-specific password}}"],
          "from account.apple.com, under sign-in and security"),
    value("npm token", "npm_demo" + secret()[:20], True),
    dict(name="Mac password", kind="mac", policy="ask", password="demo-" + secret()[:12]),
]
for e in others:
    call("upsert", {"patch": e})
library = [("Coinbase", "alfa@example.com"), ("Proton", "alfademo@proton.me"), ("Bitwarden", "alfa@example.com"),
           ("Twitch", "alfademo"), ("Reddit", "u/alfademo"), ("PlayStation", "alfademo")]
call("import_save", {"tokens": [{"issuer": i, "account": a, "uri": otp(i, a)} for i, a in library]})
stripe = next(e for e in call("entries", {}) if e["name"] == "Stripe")
call("bypass_on", {"id": stripe["id"], "statement": "i understand an agent can use my Stripe login anywhere without asking me, "
                   "and an agent that's been tricked could hand it to the wrong site.", "auth": "touch_id"})
p.stdin.close()
p.wait(5)

now = datetime.datetime.now(datetime.timezone.utc)
log = [
    (3 * 86400, "claude", "request_save", "Linear", True, "saved by you"),
    (3 * 86400 - 60, "claude", "fill", "Linear", True, "linear.app"),
    (2 * 86400 + 7200, "codex", "fill", "Vercel", True, "vercel.com"),
    (2 * 86400 + 7180, "codex", "fill_code", "Vercel", True, "vercel.com"),
    (2 * 86400, "opencode", "env", "Hugging Face", True, "gave key to `python train.py`"),
    (30 * 3600, "claude", "fill_card", "Troy debit", True, "filled Troy •••• 0007 (number + exp + cvc) on trendyol.com"),
    (29 * 3600, "cursor", "fill", "Figma", True, "figma.com"),
    (28 * 3600, "claude", "fill", "Amazon", False, "you declined Touch ID"),
    (26 * 3600, "claude", "fill_on_site", "Microsoft", True, "filled on login.microsoftonline.com, you allowed it once"),
    (25 * 3600, "gemini", "code", "Google", False, "nobody answered in time"),
    (24 * 3600, "codex", "env", "OpenAI", True, "gave key to `python`"),
    (6 * 3600, "claude", "fill", "Hetzner", True, "accounts.hetzner.com"),
    (6 * 3600 - 15, "claude", "fill_code", "Hetzner", True, "accounts.hetzner.com"),
    (3 * 3600, "claude", "code", "Stripe", False, "you declined Touch ID"),
    (2 * 3600, "claude", "env", "AWS", True, "AWS_SECRET_ACCESS_KEY for terraform"),
    (100 * 60, "claude", "fill_card", "Company Mastercard", True, "filled Mastercard •••• 4444 (number + exp + cvc) on vercel.com"),
    (90 * 60, "claude", "fill_card", "Personal Visa", True, "filled Visa •••• 4242 (number + exp + cvc) on shop.example.com"),
    (70 * 60, "opencode", "fill", "Garanti BBVA", False, "agents can't use this entry"),
    (50 * 60, "claude", "sudo", "Mac password", True, "ran `sudo launchctl kickstart -k system/com.example.agent` as root"),
    (40 * 60, "claude", "fill", "GitHub", True, "github.com"),
    (40 * 60 - 12, "claude", "fill_code", "GitHub", True, "github.com"),
    (25 * 60, "codex", "type", "Docker Desktop", True, "typed password into Docker Desktop"),
    (20 * 60, "codex", "env", "Stripe test secret", True, "gave key to `npm run test:e2e`"),
    (60, "claude", "approve_command", None, True, "you allowed `ssh deploy@203.0.113.7 'sudo systemctl restart caddy && sudo journalctl -u caddy --since \"5 min ago\" --no-pager | tail -n 40'` in ~/site",
     {"command": "ssh deploy@203.0.113.7 'sudo systemctl restart caddy && sudo journalctl -u caddy --since \"5 min ago\" --no-pager | tail -n 40'",
      "why": "the new Caddyfile is on the server; restarting caddy picks it up, then the last log lines show whether the certificate renewed"}),
    (10 * 60, "claude", "fill", "Router", False, "192.168.1.1 isn't using https, otto won't fill it"),
    (9 * 60, "claude", "fill", "Cloudflare", False, "agents can't use this entry"),
    (5 * 60, "claude", "fill", "Stripe", True, "dashboard.stripe.com (bypass)"),
    (3 * 60, "codex", "code", "Vercel", True, ""),
]
path = os.path.join(home, "activity.jsonl")
real = open(path).read() if os.path.exists(path) else ""  # what the service logged (the sealed bypass line)
with open(path, "w") as f:
    for ago, agent, op, entry, ok, detail, *extra in log:
        ts = (now - datetime.timedelta(seconds=ago)).strftime("%Y-%m-%dT%H:%M:%SZ")
        line = {"ts": ts, "agent": agent, "op": op, "entry": entry, "ok": ok, "detail": detail, "folder": "~/site"}
        f.write(json.dumps({**line, **(extra[0] if extra else {})}) + "\n")
    f.write(real)
print(f"demo vault in {home}, key {KEY}")
