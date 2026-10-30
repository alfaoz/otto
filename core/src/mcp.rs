//! MCP server over stdio (`otto mcp`). Each tool maps to one agent operation on the socket.

use serde_json::{json, Value};
use std::{
    io::{BufRead, Write},
    sync::{Arc, Mutex},
    thread,
};

use crate::{client, proto::Fail};

/// The instructions, and where the `otto` command is: the app only links it into ~/.local/bin when that
/// folder exists, so an agent's shell may not find it.
fn instructions() -> String {
    match std::env::current_exe().and_then(|p| p.canonicalize()) {
        Ok(p) => format!("{INSTRUCTIONS} If a shell can't find `otto`, it's at `{}`.", p.display()),
        Err(_) => INSTRUCTIONS.to_string(),
    }
}

const INSTRUCTIONS: &str = "otto is the user's vault for agents. Use it to log in and get 2FA codes without ever seeing passwords. \
To log into a website: open the login page in the browser, call fill_login (it types username+password into the matching tab \
and submits the form, unless you pass submit:false), and when the site asks for a 2FA code call fill_2fa_code (or get_2fa_code \
and type the digits yourself). If a fill says it didn't submit (a captcha like Cloudflare Turnstile isn't done, or the form needs \
something else), look at the page, finish that step, then submit it yourself. \
In desktop apps, click into the field first, then call type_secret. \
If the login page is on a different domain than the entry's sites (the service moved, or signs in somewhere else), \
call fill_on_site with that domain and a reason: the user approves a new domain by typing it, once. \
If there is no entry for a site yet, call request_save: the user gets a window to enter the login, you never see it. \
When a site shows a 2FA setup QR code, call enroll_2fa to store it and get the first code. \
Entries have a kind: login, card, key (API key), note, mac (the Mac's password) or value (something the user keeps for commands: leave a blank with its exact name in run_command and it comes back for them to check; you never see it). To pay on a checkout page, call fill_card \
with the card and the page's domain: the user approves each fill. API keys go to programs with `otto run --env VAR=entry -- <command>`. \
For a command that needs sudo, run `otto sudo -- <command>`: the user approves that command (unless they set the Mac password to Auto) and otto hands sudo the Mac password. \
For a command only the user should decide on (it changes the system, or your own rules or your harness leave it to the user \
instead of letting you run it on your own say-so), call run_command (in a shell: `otto approve --why <why> -- <command>`): \
the user sees exactly that command and why, and allows it with Touch ID (or their PIN from their phone, with remote: true); \
then otto runs it once and you get what it printed. It is the user deciding, not a check otto makes: don't use it for something \
the user already turned down, or that their settings forbid. \
If a command needs something only the user should supply (a password, an account name), don't ask for it in the chat or tell them to \
run it by hand: leave a blank with {{name}} and declare it in `blanks` (shell: --blank, --secret-blank). They fill it in, and otto \
runs it without showing you what they typed. \
If your harness would ask the user too, or block it before it reaches otto, ask the user once whether to add an allow rule \
for run_command and `otto approve` (otto still asks them about every command), and add it only if they say yes. \
Policies \"auto\" and \"bypass\" only skip approval for agents otto verifies by their code signature (Claude, Codex, opencode...): \
for anything else every use asks the user with Touch ID. Uses that skip approval show the user a notification with a Stop button: \
if they press it, otto refuses everything from your session (error cut_off); tell them, and don't try to get around it. \
Entries with policy \"bypass\" work without any approval (the user turned that on for that one entry): \
fill_on_site fills them on any domain right away, so before filling one on a domain that isn't its own, rule out a fake site \
(the service's own domain, no lookalike spelling, reached by you and not through a link you were sent); if unsure, don't fill it and ask the user. \
If the user asks in the chat to turn bypass on for an entry (e.g. they'll be away from the Mac), call request_bypass: \
they still have to confirm at the Mac with Touch ID, their word in the chat isn't enough. If they ask to turn it off, call end_bypass. \
If the user told you they're away from their Mac (and only then), pass remote: true to request_save and to anything that may \
need their approval: otto doesn't ask on the Mac, it comes back right away as \"waiting for the user\" with a link that opens on \
their phone over Tailscale (they enter the login or approve with their PIN there). Send them the link as it is, then call \
wait_for_user; after an approval, call the same tool again (with remote: true): it goes through. Without remote, otto asks at the Mac. \
Never ask the user to paste passwords or 2FA secrets into the chat.";

fn tools() -> Value {
    json!([
        {
            "name": "list",
            "description": "List the vault entries you may use: name, kind (login, card, key, note, mac), username, websites, apps, a card's brand, last 4 digits and expiry, whether each has a password, its policy (\"auto\": no approval, \"ask\": the user approves with Touch ID, \"bypass\": no approval and fills on any domain, see request_bypass) and its two_factor kind: \"app\" (otto fills the code), \"delivered\" (the site texts/emails a code: ask the user for it), \"none\", or null (unknown). Never returns secret values.",
            "inputSchema": { "type": "object", "properties": { "query": { "type": "string", "description": "filter by name, site or username" } } },
            "annotations": { "readOnlyHint": true }
        },
        {
            "name": "get_2fa_code",
            "description": "Get the current 2FA (authenticator) code for an entry. Codes are only valid for ~30 seconds, so type it right away. Prefer fill_2fa_code in the browser. If the entry's 2FA is delivered by SMS/email, this tells you to ask the user instead.",
            "inputSchema": { "type": "object", "properties": { "remote": { "type": "boolean", "description": "true when the user told you they're away from their Mac: you get a link for their phone instead of otto asking on the Mac" }, "entry": { "type": "string", "description": "entry name" } }, "required": ["entry"] }
        },
        {
            "name": "fill_login",
            "description": "Fill the entry's username and password into the login form of the open browser tab for its website (through the otto browser extension). You never see the password. otto refuses if the tab's site doesn't match the entry (if the login moved to another domain, use fill_on_site). Multi-step logins: call with fields [\"username\"] on the first page and [\"password\"] on the next.",
            "inputSchema": {
                "type": "object",
                "properties": { "remote": { "type": "boolean", "description": "true when the user told you they're away from their Mac: you get a link for their phone instead of otto asking on the Mac" },
                    "entry": { "type": "string" },
                    "fields": { "type": "array", "items": { "type": "string", "enum": ["username", "password"] }, "description": "default: both" },
                    "submit": { "type": "boolean", "description": "submits after filling unless you pass submit:false (e.g. a two-step login's username page, or a box to tick first)" }
                },
                "required": ["entry"]
            }
        },
        {
            "name": "fill_2fa_code",
            "description": "Fill the current 2FA code into the code field of the open browser tab for the entry's website.",
            "inputSchema": {
                "type": "object",
                "properties": { "remote": { "type": "boolean", "description": "true when the user told you they're away from their Mac: you get a link for their phone instead of otto asking on the Mac" }, "entry": { "type": "string" }, "submit": { "type": "boolean", "description": "submits after filling unless you pass submit:false" } },
                "required": ["entry"]
            }
        },
        {
            "name": "fill_on_site",
            "description": "Fill an entry's login (or its 2FA code) on a site that isn't one of the entry's sites: the service moved to a new domain, or its login page lives on another one. For a domain that's new for this entry, otto opens a window where the user has to type the domain to allow it (they can also add it to the entry for good); the call waits for them. Only use it for a domain you have good reason to believe belongs to the same service, and say why in `reason`. Domains already on the entry fill right away, and so does any domain for an entry with bypass on (nobody checks it then: rule out a lookalike or phishing page first, and if in doubt ask the user).",
            "inputSchema": {
                "type": "object",
                "properties": { "remote": { "type": "boolean", "description": "true when the user told you they're away from their Mac: you get a link for their phone instead of otto asking on the Mac" },
                    "entry": { "type": "string" },
                    "site": { "type": "string", "description": "domain (or URL) of the login page open in the browser" },
                    "reason": { "type": "string", "description": "one line for the user: why this domain belongs to the entry, e.g. \"github's enterprise login moved to github.acme.com\"" },
                    "what": { "type": "string", "enum": ["login", "2fa_code"], "description": "default login" },
                    "fields": { "type": "array", "items": { "type": "string", "enum": ["username", "password"] }, "description": "for logins, default: both" },
                    "submit": { "type": "boolean", "description": "submits after filling unless you pass submit:false" }
                },
                "required": ["entry", "site", "reason"]
            }
        },
        {
            "name": "fill_card",
            "description": "Fill a saved card (number, expiry, CVC, cardholder, postal code) into the checkout form of the open browser tab on `site`, including card fields in the payment provider's frames (Stripe, Braintree, Adyen, iyzico, PayTR...). You never see the card. Each fill waits for the user to approve it with Touch ID on their Mac (they see the card and the site), unless the card has bypass. It doesn't press pay: check the order, then submit it yourself. Only fill a card on a checkout the user asked you to complete.",
            "inputSchema": {
                "type": "object",
                "properties": { "remote": { "type": "boolean", "description": "true when the user told you they're away from their Mac: you get a link for their phone instead of otto asking on the Mac" },
                    "entry": { "type": "string", "description": "the card's entry name (list shows kind \"card\")" },
                    "site": { "type": "string", "description": "domain (or URL) of the checkout page open in the browser" }
                },
                "required": ["entry", "site"]
            }
        },
        {
            "name": "type_secret",
            "description": "Type one of the entry's fields into the focused field of a Mac app (computer use). Click into the field first. Only works if the frontmost app is one of the entry's apps. field: username, password, code (current 2FA code) or a custom field name.",
            "inputSchema": {
                "type": "object",
                "properties": { "remote": { "type": "boolean", "description": "true when the user told you they're away from their Mac: you get a link for their phone instead of otto asking on the Mac" }, "entry": { "type": "string" }, "field": { "type": "string" } },
                "required": ["entry", "field"]
            }
        },
        {
            "name": "request_save",
            "description": "Ask the user to save a login in otto. A window opens on their Mac with what you prefill; they type the secrets and save. Waits until they're done (up to 15 minutes) and returns the saved entry without secrets. With remote: true (the user said they're away), it returns right away with a link for their phone instead: send it to them, then call wait_for_user. Use when there's no entry for a site you need to log into.",
            "inputSchema": {
                "type": "object",
                "properties": { "remote": { "type": "boolean", "description": "true when the user told you they're away from their Mac: you get a link for their phone instead of otto asking on the Mac" },
                    "name": { "type": "string", "description": "short entry name, e.g. \"github\"" },
                    "site": { "type": "string", "description": "website host, e.g. github.com" },
                    "app": { "type": "string", "description": "Mac app bundle id, for desktop logins" },
                    "username": { "type": "string" },
                    "needs": { "type": "array", "items": { "type": "string", "enum": ["password", "2fa"] }, "description": "what you need; include 2fa when the site asks for a code. the user can answer: authenticator app, codes sent by SMS/email, or no 2FA" },
                    "note": { "type": "string", "description": "one line telling the user why you need it" }
                },
                "required": ["name"]
            }
        },
        {
            "name": "enroll_2fa",
            "description": "Store a 2FA secret from the setup QR code currently shown in the browser tab for the entry's site (from=browser) or anywhere on screen (from=screen). Creates the entry if needed (pass site). Returns the first code so you can finish the site's setup. Replacing an existing 2FA secret asks the user.",
            "inputSchema": {
                "type": "object",
                "properties": { "remote": { "type": "boolean", "description": "true when the user told you they're away from their Mac: you get a link for their phone instead of otto asking on the Mac" },
                    "entry": { "type": "string" },
                    "from": { "type": "string", "enum": ["browser", "screen"], "description": "default browser" },
                    "site": { "type": "string", "description": "website host, needed for a new entry" }
                },
                "required": ["entry"]
            }
        },
        {
            "name": "save_secret",
            "description": "Store a secret you created or were shown, like a new API key or recovery codes, so you don't keep it in the conversation. Creates the entry if needed (kind \"key\" for an API key). Overwriting an existing value asks the user.",
            "inputSchema": {
                "type": "object",
                "properties": { "remote": { "type": "boolean", "description": "true when the user told you they're away from their Mac: you get a link for their phone instead of otto asking on the Mac" },
                    "entry": { "type": "string" },
                    "field": { "type": "string", "description": "password, username, otp, notes, key (an API key's own field), or any custom name" },
                    "value": { "type": "string" },
                    "site": { "type": "string", "description": "website host for a new entry" },
                    "kind": { "type": "string", "enum": ["login", "key", "note"], "description": "for a new entry: key for an API key or signing key (save it in field \"key\"), note for a secure note (field \"notes\"). default login" },
                    "policy": { "type": "string", "enum": ["ask", "never"], "description": "keep it from agents: ask needs the user's Touch ID for each use, never hides it, from you too. only the user can open it up again" }
                },
                "required": ["entry", "field", "value"]
            }
        },
        {
            "name": "request_bypass",
            "description": "Only when the user asks for it in the chat: ask them to turn on bypass for one entry, e.g. because they'll be away from their Mac and want you to log in without them approving anything. With bypass on, you use that entry with no Touch ID and no windows: fill_on_site fills it on any domain, type_secret types it into any app. You can't turn it on yourself and the user's yes in the chat doesn't count by itself: a window opens on their Mac where they read the risks, tick a box and confirm with Touch ID. The call waits for them (up to 5 minutes), so tell them to look at their Mac.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "entry": { "type": "string" },
                    "reason": { "type": "string", "description": "one line for the user: what they asked you to do that needs it, e.g. \"you asked me to keep the hetzner box running while you're travelling\"" },
                    "hours": { "type": "integer", "description": "how long, if the user said (e.g. 72 for \"over the weekend\"); they can change it in the window" }
                },
                "required": ["entry", "reason"]
            }
        },
        {
            "name": "end_bypass",
            "description": "Turn bypass off for an entry, so it asks for approval again like before. Call it when the user asks you to (no approval needed: it only takes access away).",
            "inputSchema": { "type": "object", "properties": { "entry": { "type": "string" } }, "required": ["entry"] }
        },
        {
            "name": "run_command",
            "description": "For a command only the user should decide on: one that changes the system, or that your own rules or your harness won't let you run on your own say-so. The user sees exactly this command, the folder and your reason, and allows it at their Mac (Touch ID), or from their phone with their PIN when you pass remote: true. Then otto runs it once with /bin/sh in that folder and returns its exit code and output. Each command asks; a yes covers that one run. Not for something the user already said no to, or that their settings forbid: if they decline, don't run it another way. If it needs something only the user should supply (a password, an account name), don't ask for it in the chat: write {{name}} where it goes and declare it in `blanks`. The user fills it in, and the output you get shows what they typed as ••••. It runs without a terminal, so pass values as flags instead of leaving a program to prompt.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "command": { "type": "string", "description": "the shell command, exactly as it should run. a blank goes in as {{name}}, not inside single quotes" },
                    "blanks": { "type": "array", "description": "what the user fills in: each {{name}} in the command. set secret for a password or a key, so it's typed into a hidden field", "items": { "type": "object", "properties": { "name": { "type": "string", "description": "says what to type, e.g. \"apple id\". keep it plain and the same each time: the user can have otto remember what they typed, by this name" }, "secret": { "type": "boolean" } }, "required": ["name"] } },
                    "why": { "type": "string", "description": "one line for the user: what it does and why you need it, e.g. \"point Wi-Fi DNS at 1.1.1.1, like you asked\"" },
                    "cwd": { "type": "string", "description": "the folder to run it in (default: your project folder)" },
                    "timeout_seconds": { "type": "integer", "description": "stop it after this long (default 300, at most 3600)" },
                    "remote": { "type": "boolean", "description": "the user said they're away from the Mac" }
                },
                "required": ["command", "why"]
            }
        },
        {
            "name": "wait_for_user",
            "description": "Wait for the user to answer a request that came back as \"waiting for the user\" (you passed remote: true): a login to save, or a use to approve. Returns when they've answered from the link on their phone (or at the Mac, from otto's notification) (saves: the saved entry; approvals: allowed, then call the original tool again and it goes through), or fails when they said no or it expired. If this call itself times out, call it again.",
            "inputSchema": { "type": "object", "properties": { "request": { "type": "string", "description": "the request id from the waiting answer" } }, "required": ["request"] }
        },
        {
            "name": "status",
            "description": "Whether otto is running and unlocked, how many entries it has, and which browsers are connected.",
            "inputSchema": { "type": "object", "properties": {} },
            "annotations": { "readOnlyHint": true }
        }
    ])
}

/// One agent operation. A request that waits for the user (remote on) comes back as `pending`: its
/// text tells the agent what to do with the link.
fn call(tool: &str, op: &str, args: Value) -> Result<Value, Fail> {
    let r = client::call(op, args)?;
    if r["pending"] != true {
        return Ok(r);
    }
    Err(Fail::new("pending", pending_text(tool, &r)))
}

fn pending_text(tool: &str, r: &Value) -> String {
    let minutes = r["expires_in"].as_u64().unwrap_or(600).div_ceil(60);
    let id = r["request"].as_str().unwrap_or("?");
    let link = r["link"].as_str().unwrap_or("?");
    let then = if r["kind"] == "save" {
        "it returns the saved entry".to_string()
    } else {
        format!("when it says allowed, call {tool} again (with remote: true): it goes through")
    };
    format!(
        "waiting for the user. send them this link, as it is (it opens only on their own devices, over Tailscale): {link}\n\
         then call wait_for_user with request \"{id}\"; {then}. the link expires in {minutes} minutes."
    )
}

fn call_tool(name: &str, a: &Value) -> Result<String, Fail> {
    let pick = |keys: &[&str]| {
        let mut m = serde_json::Map::new();
        for k in keys {
            if let Some(v) = a.get(*k) {
                m.insert((*k).into(), v.clone());
            }
        }
        Value::Object(m)
    };
    match name {
        "list" => {
            let r = call(name, "list", pick(&["query"]))?;
            Ok(serde_json::to_string_pretty(&r).unwrap_or_default())
        }
        "get_2fa_code" => {
            let r = call(name, "code", pick(&["entry", "remote"]))?;
            Ok(format!("{} (valid for {} more seconds)", r["code"].as_str().unwrap_or(""), r["expires_in"]))
        }
        "fill_login" => {
            let r = call(name, "fill", pick(&["entry", "fields", "submit", "remote"]))?;
            Ok(format!("filled {} on {}{}", join(&r["filled"]), r["url"].as_str().unwrap_or("?"), submitted(&r, "click sign in")))
        }
        "fill_2fa_code" => {
            let r = call(name, "fill_code", pick(&["entry", "submit", "remote"]))?;
            Ok(format!("filled the 2FA code on {}{}", r["url"].as_str().unwrap_or("?"), submitted(&r, "submit it")))
        }
        "fill_on_site" => {
            let r = call(name, "fill_on_site", pick(&["entry", "site", "reason", "what", "fields", "submit", "remote"]))?;
            Ok(format!("filled {} on {}{}", join(&r["filled"]), r["url"].as_str().unwrap_or("?"), submitted(&r, "submit it")))
        }
        "fill_card" => {
            let r = call(name, "fill_card", pick(&["entry", "site", "remote"]))?;
            Ok(format!("filled {} on {}. check the order, then submit it yourself", join(&r["filled"]), r["url"].as_str().unwrap_or("?")))
        }
        "type_secret" => {
            let r = call(name, "type", pick(&["entry", "field", "remote"]))?;
            Ok(format!("typed {} into {}", r["typed"].as_str().unwrap_or("?"), r["app"].as_str().unwrap_or("?")))
        }
        "request_save" => {
            let mut args = pick(&["name", "site", "app", "username", "note", "remote"]);
            if let Some(needs) = a["needs"].as_array() {
                let needs: Vec<Value> = needs.iter().map(|n| if n == "2fa" { json!("totp") } else { n.clone() }).collect();
                args["needs"] = json!(needs);
            }
            let r = call(name, "request_save", args)?;
            Ok(format!("saved. entry: {}", serde_json::to_string(&r["entry"]).unwrap_or_default()))
        }
        "enroll_2fa" => {
            let r = call(name, "enroll", pick(&["entry", "from", "site", "remote"]))?;
            Ok(format!(
                "2FA stored in \"{}\"{}. current code: {} (valid {} more seconds); type it into the site's setup form to confirm",
                r["entry"].as_str().unwrap_or("?"),
                if r["created"] == true { " (new entry)" } else { "" },
                r["code"].as_str().unwrap_or(""),
                r["expires_in"]
            ))
        }
        "save_secret" => {
            let r = call(name, "save", pick(&["entry", "field", "value", "site", "kind", "policy", "remote"]))?;
            Ok(format!("saved {} in \"{}\"", r["field"].as_str().unwrap_or("?"), r["entry"].as_str().unwrap_or("?")))
        }
        "request_bypass" => {
            let r = call(name, "request_bypass", pick(&["entry", "reason", "hours"]))?;
            let until = r["until"].as_str().map(|u| format!(" until {u}")).unwrap_or_else(|| " until they turn it off".into());
            Ok(if r["already"] == true { format!("bypass was already on{until}") } else { format!("the user turned on bypass{until}") })
        }
        "end_bypass" => {
            let r = call(name, "end_bypass", pick(&["entry"]))?;
            Ok(if r["was_on"] == true { format!("bypass is off; the entry is back to \"{}\"", r["policy"].as_str().unwrap_or("ask")) } else { "bypass was already off".into() })
        }
        "wait_for_user" => {
            let r = call(name, "wait", pick(&["request"]))?;
            Ok(if r["saved"] == true {
                format!("saved ({}). entry: {}", from(&r), serde_json::to_string(&r["entry"]).unwrap_or_default())
            } else {
                format!("allowed ({}). call the tool again: it goes through", from(&r))
            })
        }
        "status" => {
            let r = call(name, "status", json!({}))?;
            Ok(serde_json::to_string_pretty(&r).unwrap_or_default())
        }
        "run_command" => {
            let cmd = a["command"].as_str().filter(|c| !c.trim().is_empty()).ok_or_else(|| Fail::bad("no command"))?;
            let cwd = match a["cwd"].as_str() {
                Some(d) => std::path::PathBuf::from(d),
                None => std::env::current_dir().map_err(|e| Fail::new("io", e.to_string()))?,
            };
            let argv = ["/bin/sh", "-c", cmd];
            let mut args = pick(&["why", "remote", "blanks", "timeout_seconds"]);
            args["argv"] = json!(argv);
            args["cwd"] = json!(cwd.display().to_string());
            let r = call(name, "approve_command", args)?;
            // it had blanks, so the service ran it: what the user typed never came through here
            if r["ran"] == true {
                return Ok(r["text"].as_str().unwrap_or_default().to_string());
            }
            let secs = a["timeout_seconds"].as_u64().unwrap_or(300).clamp(1, 3600);
            Ok(crate::shell::run(cmd, &cwd, std::time::Duration::from_secs(secs), &[], &[])?.text())
        }
        _ => Err(Fail::bad(format!("unknown tool {name}"))),
    }
}

/// ", submitted", or why the browser held back (a captcha not done yet...) and what to do about it.
fn submitted(r: &Value, then: &str) -> String {
    match r["held"].as_str() {
        Some(h) => format!(", didn't submit: {h}. look at the page, finish that step, then {then} yourself"),
        None if r["submitted"] == true => ", submitted".into(),
        None => String::new(),
    }
}

/// "from iphone" or "at the Mac"
fn from(r: &Value) -> String {
    match r["from"].as_str() {
        Some("the Mac") | None => "at the Mac".into(),
        Some(d) => format!("from {d}"),
    }
}

fn join(v: &Value) -> String {
    v.as_array().map(|a| a.iter().filter_map(|x| x.as_str()).collect::<Vec<_>>().join(" + ")).unwrap_or_default()
}

pub fn run() -> anyhow::Result<()> {
    let out = Arc::new(Mutex::new(std::io::stdout()));
    let reply = |out: &Arc<Mutex<std::io::Stdout>>, v: Value| {
        let mut o = out.lock().unwrap();
        let _ = writeln!(o, "{v}");
        let _ = o.flush();
    };
    for line in std::io::stdin().lock().lines() {
        let line = line?;
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        let Some(id) = msg.get("id").cloned() else { continue }; // notifications need no answer
        let method = msg["method"].as_str().unwrap_or("");
        match method {
            "initialize" => reply(
                &out,
                json!({ "jsonrpc": "2.0", "id": id, "result": {
                    "protocolVersion": msg["params"]["protocolVersion"].as_str().unwrap_or("2025-06-18"),
                    "capabilities": { "tools": {} },
                    "serverInfo": { "name": "otto", "version": env!("CARGO_PKG_VERSION") },
                    "instructions": instructions(),
                }}),
            ),
            "ping" => reply(&out, json!({ "jsonrpc": "2.0", "id": id, "result": {} })),
            "tools/list" => reply(&out, json!({ "jsonrpc": "2.0", "id": id, "result": { "tools": tools() } })),
            "tools/call" => {
                let out = out.clone();
                let name = msg["params"]["name"].as_str().unwrap_or("").to_string();
                let args = msg["params"]["arguments"].clone();
                // calls can wait on the user (Touch ID, save window), so don't block the loop
                thread::spawn(move || {
                    let (text, is_error) = match call_tool(&name, &args) {
                        Ok(t) => (t, false),
                        // waiting for the user isn't a failure
                        Err(e) if e.code == "pending" => (e.message, false),
                        Err(e) => (format!("{} ({})", e.message, e.code), true),
                    };
                    reply(&out, json!({ "jsonrpc": "2.0", "id": id, "result": { "content": [{ "type": "text", "text": text }], "isError": is_error } }));
                });
            }
            _ => reply(&out, json!({ "jsonrpc": "2.0", "id": id, "error": { "code": -32601, "message": format!("unknown method {method}") } })),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_held_fill_tells_the_agent_what_to_do() {
        assert_eq!(
            submitted(&json!({ "submitted": false, "held": "the Cloudflare Turnstile check isn't done" }), "click sign in"),
            ", didn't submit: the Cloudflare Turnstile check isn't done. look at the page, finish that step, then click sign in yourself"
        );
        assert_eq!(submitted(&json!({ "submitted": true, "held": null }), "click sign in"), ", submitted");
        assert_eq!(submitted(&json!({ "submitted": false }), "submit it"), "");
    }
}
