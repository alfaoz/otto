use serde_json::{json, Value};
use std::{collections::BTreeMap, io::Read, path::PathBuf};

use crate::{client, proto::Fail};

mod child;
pub mod mask;

/// The extensions Chrome lets start otto's helper: the one loaded unpacked (its id pinned by the `key` in
/// extension/manifest.json) and the Chrome Web Store's.
pub const EXTENSION_IDS: &[&str] = &[
    "iphednfmmkainniibplfpnchaigilkgg",
    "paeiedncdfmlcnnaaibflehbffpbnbpi",
];
pub const HOST_NAME: &str = "dev.alfaoz.otto";

const USAGE: &str = "otto: a vault your agents can use without seeing the secrets

agents:
  otto ls [query]                       list entries (no secrets)
  otto code <entry>                     print the current 2FA code
  otto fill <entry> [--only username|password] [--no-submit]
                                         fill the login into the matching browser tab and submit it
                                         (unless a captcha or the form isn't ready; it says why)
  otto fill-code <entry> [--no-submit]  fill the 2FA code into the matching browser tab and submit it
      add --site <domain> --reason <text> to either to fill on a site that isn't the
      entry's (it moved); a new domain waits for the user to allow it by typing it
  otto fill-card <card> --site <domain>  fill a card into the checkout form of the open tab on that
                                         site (and its payment provider's frames); the user approves
                                         each fill
  otto type <entry> <field>             type a field into the focused Mac app
                                         (username, password, code, or a custom field)
  otto request-save <name> [--site host] [--app bundle.id] [--username u]
                    [--needs password,2fa] [--note text]
                                         ask the user to save a login; waits for them
  otto enroll <entry> [--from browser|screen] [--site host]
                                         store the 2FA setup QR that's showing, print the first code
  otto save <entry> <field> [--site host] [--kind key|note] [--policy ask|never]
                                         store a value read from stdin (e.g. an api key you just made:
                                         otto save openai key --kind key)
  otto bypass <entry> --reason <text> [--hours n]
                                         ask the user to turn on bypass for the entry (they confirm
                                         with Touch ID at the Mac); waits for them
  otto bypass <entry> --off             turn bypass off again
  otto run --env VAR=entry[:field] ... -- <command> [args]
                                         run a command with secrets in its environment
                                         (the entry must allow scripts; without a field: a login's
                                         password, an API key's key, a card's number); what it
                                         prints shows those values as ••••
  otto sudo -- <command> [args]         run a command with sudo; otto gives sudo the Mac password
                                         after the user approves that command (or right away, if
                                         they set the Mac password to Auto)
  otto approve [--why <text>] -- <command> [args]
                                         for a command you'd want the user to OK themselves, or that
                                         you won't run on your own say-so: the user sees exactly this
                                         command (and why) and allows it with Touch ID, or their PIN
                                         from their phone (--remote); then otto runs it, here, once.
                                         not for something the user already said no to
      --blank <name> / --secret-blank <name>, with {{name}} in the command: something only the user
                                         should supply. they fill it in; otto runs the command itself and
                                         prints its output with what they typed as ••••. no terminal, so
                                         it can't prompt. --timeout <seconds> (default 300)
  otto wait <request>                   wait for the user to answer a request that came back waiting
      add --remote to a command when the user said they're away from the Mac: otto doesn't ask
      there, it prints a link for their phone (exit 5); then `otto wait <request>`
  otto status
  otto log [count]

plumbing:
  otto mcp                              MCP server on stdio
  otto daemon                           the background service (Otto.app starts it)
  otto install-browser [--dir path]     register the browser extension's helper
  otto connect [agent]                  add otto to Codex, opencode, T3 Code, Cursor, Gemini CLI, Windsurf
                                         or the Claude desktop app (lists them without an agent)
";

/// `--remote`: the user told the agent they're away from the Mac
static AWAY: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub fn main(mut args: Vec<String>) -> i32 {
    // anywhere before a command's own `--`
    let end = args.iter().position(|a| a == "--").unwrap_or(args.len());
    if let Some(i) = args.get(1..end).and_then(|a| a.iter().position(|a| a == "--remote")) {
        args.remove(i + 1);
        AWAY.store(true, std::sync::atomic::Ordering::Relaxed);
    }
    let rest: Vec<String> = args.iter().skip(2).cloned().collect();
    let cmd = args.get(1).map(String::as_str).unwrap_or("help");
    let r = match cmd {
        "daemon" => {
            let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio");
            match rt.block_on(crate::daemon::run()) {
                Ok(()) => return 0,
                Err(e) => Err(Fail::new("daemon", format!("{e:#}"))),
            }
        }
        "mcp" => crate::mcp::run().map_err(Fail::from).map(|_| ()),
        "install-browser" => install_browser(&rest),
        "connect" => connect(&rest),
        "ls" | "list" => ls(&rest),
        "code" => code(&rest),
        "fill" => fill(&rest),
        "fill-code" => fill_code(&rest),
        "fill-card" => fill_card(&rest),
        "sudo" => sudo(&rest),
        "approve" => approve(&rest),
        "type" => type_field(&rest),
        "request-save" => request_save(&rest),
        "enroll" => enroll(&rest),
        "save" => save(&rest),
        "bypass" => bypass(&rest),
        "run" => run(&rest),
        "wait" => wait(&rest),
        "status" => status(),
        "log" => log(&rest),
        "help" | "-h" | "--help" => {
            print!("{USAGE}");
            Ok(())
        }
        "version" | "--version" | "-V" => {
            println!("otto {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        other => Err(Fail::bad(format!("unknown command `{other}`. run `otto help`"))),
    };
    match r {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("otto: {}", e.message);
            match e.code.as_str() {
                "denied" | "cancelled" => 3,
                "not_running" | "locked" => 4,
                "pending" => 5,
                _ => 1,
            }
        }
    }
}

/// An agent operation. With `--remote` (the user is away) anything that waits for them comes back with a
/// request and a link for their phone: in a terminal, say so and wait, then (for an approval) run it again;
/// under an agent, which only sees the output at the end, print what to do with the link and stop (exit 5).
fn call(op: &str, mut args: Value) -> Result<Value, Fail> {
    use std::io::IsTerminal;
    if AWAY.load(std::sync::atomic::Ordering::Relaxed) {
        args["remote"] = json!(true);
    }
    let r = client::call(op, args.clone())?;
    if r["pending"] != true {
        return Ok(r);
    }
    let id = r["request"].as_str().unwrap_or("?");
    let link = r["link"].as_str().unwrap_or("?");
    let save = r["kind"] == "save";
    if !std::io::stderr().is_terminal() {
        let then = if save { "it prints the saved entry" } else { "then run this command again (with --remote): it goes through" };
        return Err(Fail::new(
            "pending",
            format!("waiting for the user. send them this link, as it is (it opens only on their own devices, over Tailscale): {link}\nthen run `otto wait {id}`; {then}"),
        ));
    }
    eprintln!("waiting for you: open {link} on your phone");
    let w = client::call("wait", json!({ "request": id }))?;
    if save {
        return Ok(w);
    }
    client::call(op, args)
}

fn wait(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &[]);
    let r = client::call("wait", json!({ "request": need(&a, 0, "request")? }))?;
    let from = match r["from"].as_str() {
        Some("the Mac") | None => "at the Mac".to_string(),
        Some(d) => format!("from {d}"),
    };
    if r["saved"] == true {
        println!("saved \"{}\" ({from})", r["entry"]["name"].as_str().unwrap_or("?"));
    } else {
        println!("allowed ({from}). run the command again: it goes through");
    }
    Ok(())
}

/// Positional args plus `--flag value` / `--switch` options.
struct Args {
    pos: Vec<String>,
    opts: BTreeMap<String, String>,
}

fn parse(rest: &[String], switches: &[&str]) -> Args {
    let mut a = Args { pos: vec![], opts: BTreeMap::new() };
    let mut i = 0;
    while i < rest.len() {
        let s = &rest[i];
        if let Some(name) = s.strip_prefix("--") {
            if let Some((k, v)) = name.split_once('=') {
                a.opts.insert(k.into(), v.into());
            } else if switches.contains(&name) {
                a.opts.insert(name.into(), "true".into());
            } else {
                a.opts.insert(name.into(), rest.get(i + 1).cloned().unwrap_or_default());
                i += 1;
            }
        } else {
            a.pos.push(s.clone());
        }
        i += 1;
    }
    a
}

fn need<'a>(a: &'a Args, i: usize, what: &str) -> Result<&'a str, Fail> {
    a.pos.get(i).map(String::as_str).ok_or_else(|| Fail::bad(format!("missing <{what}>. run `otto help`")))
}

fn ls(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &["json"]);
    let r = client::call("list", json!({ "query": a.pos.first() }))?;
    if a.opts.contains_key("json") {
        println!("{}", serde_json::to_string_pretty(&r).unwrap_or_default());
        return Ok(());
    }
    let list = r.as_array().cloned().unwrap_or_default();
    if list.is_empty() {
        println!("no entries");
    }
    for e in list {
        let mut tags = vec![];
        let card = e["card"]["last4"].as_str().map(|l| format!("{} ••{l}", e["card"]["brand"].as_str().unwrap_or("card")));
        match e["kind"].as_str() {
            Some("card") => tags.push(card.as_deref().unwrap_or("card")),
            Some(k @ ("key" | "note" | "mac" | "value")) => tags.push(match k {
                "key" => "api-key",
                "note" => "note",
                "value" => "value",
                _ => "mac-password",
            }),
            _ if e["has_password"] == true => tags.push("password"),
            _ => {}
        }
        if e["has_2fa"] == true {
            tags.push("2fa");
        }
        if e["scripts"] == true {
            tags.push("scripts");
        }
        let place: Vec<String> = e["sites"].as_array().into_iter().flatten().chain(e["apps"].as_array().into_iter().flatten()).filter_map(|v| v.as_str().map(String::from)).collect();
        println!(
            "{:<20} {:<26} {:<28} {} [{}]",
            e["name"].as_str().unwrap_or(""),
            e["username"].as_str().unwrap_or("-"),
            if place.is_empty() { "-".into() } else { place.join(",") },
            tags.join(" "),
            e["policy"].as_str().unwrap_or("")
        );
    }
    Ok(())
}

fn code(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &[]);
    let r = call("code", json!({ "entry": need(&a, 0, "entry")? }))?;
    println!("{}", r["code"].as_str().unwrap_or(""));
    eprintln!("valid {}s", r["expires_in"]);
    Ok(())
}

/// `--no-submit` / `--submit`; with neither the service decides (it submits unless something's in the way).
fn submit_arg(a: &Args, args: &mut Value) {
    if a.opts.contains_key("no-submit") {
        args["submit"] = json!(false);
    } else if a.opts.contains_key("submit") {
        args["submit"] = json!(true);
    }
}

/// " and submitted", or why it wasn't (a captcha still going, a form that isn't ready...).
fn submitted(r: &Value) -> String {
    match (r["submitted"] == true, r["held"].as_str()) {
        (true, _) => " and submitted".into(),
        (false, Some(why)) => format!(", didn't submit: {why}"),
        _ => String::new(),
    }
}

fn fill(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &["submit", "no-submit"]);
    let fields: Vec<&str> = a.opts.get("only").map(|s| s.split(',').collect()).unwrap_or_default();
    let mut args = json!({ "entry": need(&a, 0, "entry")?, "fields": fields });
    submit_arg(&a, &mut args);
    let r = match a.opts.get("site") {
        Some(site) => {
            args["site"] = json!(site);
            args["reason"] = json!(a.opts.get("reason"));
            call("fill_on_site", args)?
        }
        None => call("fill", args)?,
    };
    let filled: Vec<&str> = r["filled"].as_array().into_iter().flatten().filter_map(|v| v.as_str()).collect();
    println!("filled {} on {}{}", filled.join(" + "), r["url"].as_str().unwrap_or("?"), submitted(&r));
    Ok(())
}

fn fill_code(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &["submit", "no-submit"]);
    let mut args = json!({ "entry": need(&a, 0, "entry")? });
    submit_arg(&a, &mut args);
    let r = match a.opts.get("site") {
        Some(site) => {
            args["site"] = json!(site);
            args["reason"] = json!(a.opts.get("reason"));
            args["what"] = json!("2fa_code");
            call("fill_on_site", args)?
        }
        None => call("fill_code", args)?,
    };
    println!("filled the 2FA code on {}{}", r["url"].as_str().unwrap_or("?"), submitted(&r));
    Ok(())
}

fn fill_card(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &[]);
    let site = a.opts.get("site").ok_or_else(|| Fail::bad("say where with --site <domain of the checkout page>"))?;
    eprintln!("waiting for the user to approve it on their Mac...");
    let r = call("fill_card", json!({ "entry": need(&a, 0, "card")?, "site": site }))?;
    let filled: Vec<&str> = r["filled"].as_array().into_iter().flatten().filter_map(|v| v.as_str()).collect();
    println!("filled {} on {}", filled.join(" + "), r["url"].as_str().unwrap_or("?"));
    Ok(())
}

fn type_field(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &[]);
    let r = call("type", json!({ "entry": need(&a, 0, "entry")?, "field": need(&a, 1, "field")? }))?;
    println!("typed {} into {}", r["typed"].as_str().unwrap_or("?"), r["app"].as_str().unwrap_or("?"));
    Ok(())
}

fn request_save(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &[]);
    let needs: Vec<String> = a
        .opts
        .get("needs")
        .map(|s| s.split(',').map(|n| if n.trim() == "2fa" { "totp".to_string() } else { n.trim().to_string() }).collect())
        .unwrap_or_default();
    eprintln!("waiting for the user to save it in otto...");
    let r = call(
        "request_save",
        json!({
            "name": need(&a, 0, "name")?,
            "site": a.opts.get("site"),
            "app": a.opts.get("app"),
            "username": a.opts.get("username"),
            "needs": needs,
            "note": a.opts.get("note"),
        }),
    )?;
    println!("saved \"{}\"", r["entry"]["name"].as_str().unwrap_or("?"));
    Ok(())
}

fn enroll(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &[]);
    let r = call("enroll", json!({ "entry": need(&a, 0, "entry")?, "from": a.opts.get("from"), "site": a.opts.get("site") }))?;
    println!("{}", r["code"].as_str().unwrap_or(""));
    eprintln!(
        "2FA stored in \"{}\"{}; code valid {}s",
        r["entry"].as_str().unwrap_or("?"),
        if r["created"] == true { " (new entry)" } else { "" },
        r["expires_in"]
    );
    Ok(())
}

fn save(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &[]);
    let mut value = String::new();
    std::io::stdin().read_to_string(&mut value).map_err(|e| Fail::new("io", e.to_string()))?;
    let value = value.trim_end_matches(['\n', '\r']);
    let r = call(
        "save",
        json!({
            "entry": need(&a, 0, "entry")?, "field": need(&a, 1, "field")?, "value": value,
            "site": a.opts.get("site"), "app": a.opts.get("app"), "kind": a.opts.get("kind"), "policy": a.opts.get("policy"),
        }),
    )?;
    let verb = if r["unchanged"] == true { "already had" } else { "saved" };
    println!("{verb} {} in \"{}\"", r["field"].as_str().unwrap_or("?"), r["entry"].as_str().unwrap_or("?"));
    Ok(())
}

fn bypass(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &["off"]);
    let entry = need(&a, 0, "entry")?;
    if a.opts.contains_key("off") {
        let r = client::call("end_bypass", json!({ "entry": entry }))?;
        println!("{}", if r["was_on"] == true { format!("bypass off; \"{entry}\" is back to {}", r["policy"].as_str().unwrap_or("ask")) } else { "bypass was already off".into() });
        return Ok(());
    }
    let hours: Option<u64> = a.opts.get("hours").and_then(|h| h.parse().ok());
    eprintln!("waiting for the user to confirm on their Mac...");
    let r = client::call("request_bypass", json!({ "entry": entry, "reason": a.opts.get("reason"), "hours": hours }))?;
    let until = r["until"].as_str().map(|u| format!(" until {u}")).unwrap_or_default();
    println!("{}{until}", if r["already"] == true { "bypass was already on" } else { "bypass on" });
    Ok(())
}

fn run(rest: &[String]) -> Result<(), Fail> {
    let split = rest.iter().position(|s| s == "--").ok_or_else(|| Fail::bad("usage: otto run --env VAR=entry[:field] ... -- <command>"))?;
    let (flags, cmd) = (&rest[..split], &rest[split + 1..]);
    if cmd.is_empty() {
        return Err(Fail::bad("no command after --"));
    }
    // VAR=entry[:field], grouped per entry so each entry is one approval
    let mut wants: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
    let mut i = 0;
    while i < flags.len() {
        let spec = match flags[i].as_str() {
            "--env" | "-e" => {
                i += 1;
                flags.get(i).cloned().unwrap_or_default()
            }
            s if s.starts_with("--env=") => s[6..].to_string(),
            s => return Err(Fail::bad(format!("unexpected `{s}`"))),
        };
        let (var, target) = spec.split_once('=').ok_or_else(|| Fail::bad(format!("`{spec}` should look like VAR=entry or VAR=entry:field")))?;
        // no field: the entry's main value (the service picks it by the entry's kind)
        let (entry, field) = target.rsplit_once(':').unwrap_or((target, ""));
        wants.entry(entry.to_string()).or_default().push((var.to_string(), field.to_string()));
        i += 1;
    }
    let label = PathBuf::from(&cmd[0]).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| cmd[0].clone());
    let mut env = vec![];
    for (entry, pairs) in &wants {
        let fields: Vec<&str> = pairs.iter().map(|(_, f)| f.as_str()).collect();
        let r = call("env", json!({ "entry": entry, "fields": fields, "command": label }))?;
        for (var, field) in pairs {
            let v = r["values"][field].as_str().ok_or_else(|| Fail::new("no_value", format!("\"{entry}\" has no {field}")))?;
            env.push((var.clone(), v.to_string()));
        }
    }
    // otto stays in between: whatever the command prints shows the values as ••••
    let secrets: Vec<&str> = env.iter().map(|(_, v)| v.as_str()).collect();
    let code = child::run(cmd, &env, mask::Patterns::new(&secrets))?;
    std::process::exit(code)
}

/// sudo with otto as its askpass helper: sudo asks otto for the Mac password, otto asks the user (showing
/// the command) and hands it to sudo. The password never passes through this process or the agent.
fn sudo(rest: &[String]) -> Result<(), Fail> {
    let cmd = match rest.first().map(String::as_str) {
        Some("--") => &rest[1..],
        _ => rest,
    };
    if cmd.is_empty() {
        return Err(Fail::bad("usage: otto sudo -- <command> [args]"));
    }
    // fail here, with otto's own message, rather than as a sudo that got no password
    if client::call("status", json!({}))?["unlocked"] != true {
        return Err(Fail::new("locked", "the vault is locked. open the otto app to unlock it"));
    }
    let exe = std::env::current_exe().and_then(|p| p.canonicalize()).map_err(|e| Fail::new("io", e.to_string()))?;
    let mut c = std::process::Command::new("/usr/bin/sudo");
    c.arg("-A").args(cmd).env("SUDO_ASKPASS", exe).env("OTTO_ASKPASS", "1");
    use std::os::unix::process::CommandExt;
    let err = c.exec();
    Err(Fail::new("exec", format!("couldn't run sudo: {err}")))
}

/// The user's yes for one exact command, then that command, run in place of this process (same folder,
/// environment and terminal; its exit code is otto's).
fn approve(rest: &[String]) -> Result<(), Fail> {
    let split = rest.iter().position(|s| s == "--").ok_or_else(|| Fail::bad("usage: otto approve [--why <text>] -- <command> [args]"))?;
    let (flags, cmd) = (&rest[..split], &rest[split + 1..]);
    if cmd.is_empty() {
        return Err(Fail::bad("no command after --"));
    }
    // these two can come more than once, which `parse` isn't for
    let (mut blanks, mut others, mut i) = (vec![], vec![], 0);
    while i < flags.len() {
        match flags[i].as_str() {
            f @ ("--blank" | "--secret-blank") => {
                let name = flags.get(i + 1).ok_or_else(|| Fail::bad(format!("{f} needs a name")))?;
                blanks.push(json!({ "name": name, "secret": f == "--secret-blank" }));
                i += 2;
            }
            _ => {
                others.push(flags[i].clone());
                i += 1;
            }
        }
    }
    let a = parse(&others, &[]);
    if let Some(p) = a.pos.first() {
        return Err(Fail::bad(format!("unexpected `{p}` before --")));
    }
    let cwd = std::env::current_dir().map(|p| p.display().to_string()).unwrap_or_default();
    let timeout = a.opts.get("timeout").and_then(|t| t.parse::<u64>().ok());
    let r = call("approve_command", json!({ "argv": cmd, "cwd": cwd, "why": a.opts.get("why"), "blanks": blanks, "timeout_seconds": timeout }))?;
    // it had blanks, so the service ran it: what the user typed never came through here
    if r["ran"] == true {
        for (key, line) in [("stdout", false), ("stderr", true)] {
            match r[key].as_str().filter(|s| !s.is_empty()) {
                Some(s) if line => eprintln!("{s}"),
                Some(s) => println!("{s}"),
                None => {}
            }
        }
        std::process::exit(r["exit"].as_i64().unwrap_or(1) as i32);
    }
    use std::os::unix::process::CommandExt;
    let err = std::process::Command::new(&cmd[0]).args(&cmd[1..]).exec();
    Err(Fail::new("exec", format!("couldn't run {}: {err}", cmd[0])))
}

/// Started by sudo (see `sudo` above): print the Mac password for sudo to read, or fail so it gives up.
pub fn askpass() -> i32 {
    match client::call("askpass", json!({})) {
        Ok(r) => match r["password"].as_str() {
            Some(p) => {
                println!("{p}");
                0
            }
            None => 1,
        },
        Err(e) => {
            eprintln!("otto: {}", e.message);
            1
        }
    }
}

fn connect(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &["json", "refresh"]);
    if a.opts.contains_key("refresh") {
        crate::connect::refresh_skills();
        return Ok(());
    }
    match a.pos.first() {
        Some(id) => println!("{}", crate::connect::connect(id)?),
        None if a.opts.contains_key("json") => println!("{}", crate::connect::list()),
        None => {
            for g in crate::connect::list().as_array().into_iter().flatten() {
                let state = if g["connected"] == true { "connected" } else if g["installed"] == true { "not connected" } else { "not installed" };
                println!("{:<16} {:<22} {}", g["id"].as_str().unwrap_or(""), g["name"].as_str().unwrap_or(""), state);
            }
            println!("\notto connect <agent> adds otto's MCP server to its config");
        }
    }
    Ok(())
}

fn status() -> Result<(), Fail> {
    let r = client::call("status", json!({}))?;
    let browsers: Vec<&str> = r["browsers"].as_array().into_iter().flatten().filter_map(|v| v.as_str()).collect();
    println!("otto {} ({})", r["version"].as_str().unwrap_or("?"), if r["unlocked"] == true { "unlocked" } else { "locked" });
    println!("entries: {}", r["entries"]);
    println!("browser: {}", if browsers.is_empty() { "not connected".into() } else { browsers.join(", ") });
    Ok(())
}

fn log(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &[]);
    let n: u64 = a.pos.first().and_then(|s| s.parse().ok()).unwrap_or(20);
    let r = client::call("log", json!({ "limit": n }))?;
    let mut events: Vec<Value> = r.as_array().cloned().unwrap_or_default();
    events.reverse();
    for e in events {
        println!(
            "{}  {:<8} {:<12} {:<16} {}{}",
            e["ts"].as_str().unwrap_or(""),
            e["agent"].as_str().unwrap_or(""),
            e["op"].as_str().unwrap_or(""),
            e["entry"].as_str().unwrap_or("-"),
            if e["ok"] == true || e["pending"] == true { "" } else { "✗ " },
            e["detail"].as_str().unwrap_or("")
        );
    }
    Ok(())
}

/// Each Chromium browser's profile folder (macOS); it looks for native messaging hosts in
/// <folder>/NativeMessagingHosts. Only folders that exist get the helper.
pub const BROWSER_DIRS: &[&str] = &[
    "Google/Chrome",
    "Google/Chrome Beta",
    "Google/Chrome Dev",
    "Google/Chrome Canary",
    "Google/Chrome for Testing",
    "Chromium",
    "BraveSoftware/Brave-Browser",
    "BraveSoftware/Brave-Browser-Beta",
    "BraveSoftware/Brave-Browser-Nightly",
    "Microsoft Edge",
    "Microsoft Edge Beta",
    "Microsoft Edge Dev",
    "Microsoft Edge Canary",
    "Arc/User Data",
    "Dia/User Data",
    "Vivaldi",
    "com.operasoftware.Opera",
    "com.operasoftware.OperaGX",
    "com.operasoftware.OperaDeveloper",
    "Comet",
    "com.openai.atlas/browser-data/host",
    "net.imput.helium",
    "Thorium",
    "Yandex/YandexBrowser",
    "Naver/Whale",
];

fn browser_dirs() -> Vec<PathBuf> {
    let home = std::env::var("HOME").map(PathBuf::from).unwrap_or_default();
    let base = home.join("Library/Application Support");
    BROWSER_DIRS
    .iter()
    .map(|d| base.join(d))
    .filter(|d| d.is_dir())
    .map(|d| d.join("NativeMessagingHosts"))
    .collect()
}

fn install_browser(rest: &[String]) -> Result<(), Fail> {
    let a = parse(rest, &[]);
    let exe = std::env::current_exe().and_then(|p| p.canonicalize()).map_err(|e| Fail::new("io", e.to_string()))?;
    let ids: Vec<&str> = match a.opts.get("extension-id") {
        Some(id) => vec![id.as_str()],
        None => EXTENSION_IDS.to_vec(),
    };
    let manifest = json!({
        "name": HOST_NAME,
        "description": "otto vault bridge",
        "path": exe,
        "type": "stdio",
        "allowed_origins": ids.iter().map(|id| format!("chrome-extension://{id}/")).collect::<Vec<_>>(),
    });
    let dirs = match a.opts.get("dir") {
        Some(d) => vec![PathBuf::from(d).join("NativeMessagingHosts")],
        None => browser_dirs(),
    };
    if dirs.is_empty() {
        return Err(Fail::new("no_browser", "no Chromium browser found"));
    }
    for d in dirs {
        std::fs::create_dir_all(&d).map_err(|e| Fail::new("io", e.to_string()))?;
        let f = d.join(format!("{HOST_NAME}.json"));
        std::fs::write(&f, serde_json::to_string_pretty(&manifest).unwrap_or_default()).map_err(|e| Fail::new("io", e.to_string()))?;
        println!("{}", f.display());
    }
    Ok(())
}
