//! Requests that wait on the user while they're away from the Mac (the agent says so, from what they told
//! it): a login to save, or a use to approve. Nothing pops up on the Mac: the agent gets a link for the
//! user's phone and waits for the answer with `wait`, and the Mac shows a notification that opens the
//! window or Touch ID prompt when clicked, so the user can still answer there. Also the phone's side:
//! the page and its small API, served on the Mac's Tailscale address (see remote.rs).

use super::*;
use crate::remote::{self, Conf, Device, HttpReq, HttpRes, Peer, Tailnet};
use std::net::{IpAddr, SocketAddr};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::watch,
};

/// how long a yes from elsewhere waits for the agent's next call
pub(super) const YES_LIFE: Duration = Duration::from_secs(10 * 60);
/// What a command's yes is kept under in place of an entry id (see `approve_command`).
pub(super) const COMMAND_ENTRY: &str = "otto.command";
/// how long an answered request is kept, so a late `wait` or a reloaded page still gets the answer
const KEEP_DONE: Duration = Duration::from_secs(15 * 60);
const WHOIS_TTL: Duration = Duration::from_secs(30);
/// what the Mac is called where the phone says who answered
const AT_MAC: &str = "the Mac";

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Outcome {
    /// the entry as agents may see it
    Saved(Value),
    Approved,
    Declined,
    Expired,
}

/// What a change to a stored secret would write, so the user sees it before saying yes (at the Mac and
/// on the phone). The yes covers this exact value only.
#[derive(Debug, Clone)]
pub(super) struct Change {
    /// "password", "username", a custom field's name, "2FA secret"
    pub field: String,
    /// the new value, when reading it means something (not for a 2FA secret)
    pub value: Option<String>,
    /// said in place of the value: "a new 2FA secret from example.com"
    pub label: Option<String>,
    /// hidden until the user asks to see it (everything but a username)
    pub secret: bool,
    digest: String,
}

impl Change {
    pub(super) fn new(field: &str, value: Option<String>, label: Option<String>, binds: &str) -> Change {
        let secret = !field.eq_ignore_ascii_case("username");
        Change { field: field.to_string(), value, label, secret, digest: remote::sha256_hex(binds) }
    }

    pub(super) fn json(&self) -> Value {
        json!({ "field": self.field, "value": self.value, "label": self.label, "secret": self.secret })
    }

    /// What a yes from a pending request is kept under: the action, and for a change, the value too, so
    /// the agent can't get a different one through with it.
    pub(super) fn grant(action: &str, change: Option<&Change>) -> String {
        match change {
            Some(ch) => format!("{action} {}", ch.digest),
            None => action.to_string(),
        }
    }
}

impl Outcome {
    fn state(&self) -> &'static str {
        match self {
            Outcome::Saved(_) => "saved",
            Outcome::Approved => "approved",
            Outcome::Declined => "declined",
            Outcome::Expired => "expired",
        }
    }
}

pub(super) struct Ask {
    /// "save" or "approve"
    kind: &'static str,
    link: String,
    /// the agent session that asked: only it may wait for the answer
    thread: String,
    who: String,
    folder: Option<String>,
    created: Instant,
    life: Duration,
    /// what the phone page shows, beyond the common fields
    info: Value,
    entry_id: String,
    entry: String,
    /// approve: what the yes is for, and whether it covers one use only (cards, changes)
    action: String,
    /// what the yes is kept under for the agent's next call (see Change::grant)
    grant: String,
    once: bool,
    /// save: what the agent asked for, and the entry it would update
    needs: Vec<String>,
    existing: Option<EntryInfo>,
    /// what the app shows to answer it at the Mac, once the user asks for that from the notification
    mac: Option<(&'static str, Value)>,
    /// someone's saving it right now
    busy: bool,
    done: Option<(Outcome, String, Instant)>,
    tx: watch::Sender<Option<Outcome>>,
}

impl Ask {
    fn expired(&self) -> bool {
        self.done.is_none() && self.created.elapsed() > self.life
    }
}

/// The phone page's server and what it knows about Tailscale.
#[derive(Default)]
pub(super) struct RemoteRt {
    addr: Option<SocketAddr>,
    task: Option<tokio::task::JoinHandle<()>>,
    tailnet: Tailnet,
    error: Option<String>,
    whois: HashMap<IpAddr, (Instant, Result<Peer, String>)>,
    /// paired device id -> when it last opened something
    seen: HashMap<String, String>,
    /// the status the app last heard about
    last: Value,
}

/// macOS's Touch ID wording: "otto is trying to let claude fill GitHub’s login in the browser."
pub(super) fn prompt(agent: &str, action: &str, entry: &str) -> String {
    if action.contains("its ") {
        return format!("let {agent} {}", action.replace("its ", &format!("{entry}’s ")));
    }
    format!("let {agent} {action} for {entry}")
}

/// What a request has left, from what `ask_here` told its window.
fn left_of(args: &Value) -> Duration {
    Duration::from_secs(args["expires_in"].as_u64().unwrap_or(60))
}

fn now() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

fn place(from: &str) -> String {
    if from == AT_MAC {
        "at the Mac".into()
    } else {
        format!("from {from}")
    }
}

impl State {
    pub(super) fn arc(&self) -> Arc<State> {
        self.me.get().and_then(std::sync::Weak::upgrade).expect("the service's state")
    }

    /// A line in the activity log that the user did (from the phone or at the Mac).
    pub(super) fn you(&self, op: &str, entry: Option<&str>, ok: bool, detail: String) {
        let ev = self.audit.record("you", op, entry, ok, detail);
        self.event("activity", json!(ev));
    }

    // ---- requests -------------------------------------------------------------------

    fn add_ask(&self, c: &Client, kind: &'static str, base: &str, life: Duration, e: (&str, &str), info: Value) -> (String, Ask) {
        let id = remote::new_id();
        let (tx, _) = watch::channel(None);
        let ask = Ask {
            kind,
            link: format!("{base}/r/{id}"),
            thread: c.thread.clone(),
            who: c.who(),
            folder: c.folder.clone(),
            created: Instant::now(),
            life,
            info,
            entry_id: e.0.to_string(),
            entry: e.1.to_string(),
            action: String::new(),
            grant: String::new(),
            once: false,
            needs: vec![],
            existing: None,
            mac: None,
            busy: false,
            done: None,
            tx,
        };
        (id, ask)
    }

    /// request_save while the user is away: a link for the phone, a notification on the Mac.
    pub(super) fn ask_save(&self, c: &Client, base: &str, req: &Value, existing: Option<EntryInfo>, life: Duration) -> String {
        let name = req["name"].as_str().unwrap_or_default();
        let info = json!({
            "name": name, "site": req["site"], "app": req["app"], "username": req["username"], "needs": req["needs"], "note": req["note"],
            "existing": existing.as_ref().map(|e| json!({ "username": e.username, "has_password": e.has_password, "has_2fa": e.totp.is_some() })),
        });
        let (id, mut ask) = self.add_ask(c, "save", base, life, (existing.as_ref().map(|e| e.id.as_str()).unwrap_or(""), name), info);
        ask.needs = str_list(req, "needs");
        ask.existing = existing;
        let mut args = req.clone();
        args["ask"] = json!(id);
        ask.mac = Some(("save_dialog", args));
        let title = format!("{} needs your {name} login", c.who());
        self.asks.lock().unwrap().insert(id.clone(), ask);
        self.event("ask", json!({ "ask": id, "kind": "save", "title": title, "entry": name }));
        id
    }

    async fn save_at_mac(&self, id: &str, args: Value) {
        let wait = left_of(&args);
        match self.ask_app("save_dialog", args, wait).await {
            Ok(r) if r["saved"] == true => {
                if let Ok(patch) = serde_json::from_value::<EntryPatch>(r["patch"].clone()) {
                    if let Err(f) = self.finish_save(id, patch, AT_MAC).await {
                        self.log_you_failed(id, &f);
                    }
                }
            }
            // Not now, or the window was closed (when the phone answered first, this changes nothing)
            Ok(_) => {
                self.settle(id, Outcome::Declined, AT_MAC);
            }
            // nobody at the Mac, or the app went away: the link still works
            Err(_) => {}
        }
    }

    fn log_you_failed(&self, id: &str, f: &Fail) {
        let entry = self.asks.lock().unwrap().get(id).map(|a| a.entry.clone());
        self.you("saved", entry.as_deref(), false, f.message.clone());
    }

    /// Save what the user entered (at the Mac or on the phone), unless the other side already did.
    async fn finish_save(&self, id: &str, patch: EntryPatch, from: &str) -> Result<Value, Fail> {
        {
            let mut asks = self.asks.lock().unwrap();
            let a = asks.get_mut(id).ok_or_else(|| Fail::new("not_found", "this request is gone"))?;
            if a.done.is_some() {
                return Err(Fail::new("answered", "it was already answered"));
            }
            if a.expired() {
                return Err(Fail::new("expired", "this request has expired"));
            }
            if a.busy {
                return Err(Fail::new("answered", "it's being saved from somewhere else right now"));
            }
            a.busy = true;
        }
        let r = self
            .with_vault_mut(|v| {
                let id = v.apply(&patch)?;
                v.info(id).ok_or_else(|| Fail::new("not_found", "entry vanished"))
            })
            .await;
        match r {
            Ok(info) => {
                let entry = public(&info);
                self.settle(id, Outcome::Saved(entry.clone()), from);
                Ok(entry)
            }
            Err(f) => {
                if let Some(a) = self.asks.lock().unwrap().get_mut(id) {
                    a.busy = false;
                }
                Err(f)
            }
        }
    }

    /// An approval while the user is away: a link for the phone, a notification on the Mac.
    pub(super) async fn ask_approve(&self, c: &Client, e: &EntryInfo, action: &str, once: bool, shown: Option<String>, change: Option<&Change>) -> Result<String, Fail> {
        let base = self.remote_base().await?;
        let base = base.as_str();
        let who = c.who();
        let shown = shown.unwrap_or_else(|| prompt(&who, action, &e.name));
        let info = json!({ "entry": e.name, "entry_kind": e.kind, "sites": e.sites, "action": action, "prompt": shown, "change": change.map(Change::json) });
        let (id, mut ask) = self.add_ask(c, "approve", base, Duration::from_secs(self.waits().await.phone), (&e.id, &e.name), info);
        ask.action = action.to_string();
        ask.grant = Change::grant(action, change);
        ask.once = once;
        ask.mac = Some((
            "approve",
            json!({
                "entry": e.name, "entry_id": e.id, "action": action, "agent": who, "chain": c.chain, "force": once, "prompt": shown,
                "verified": c.verified, "folder": c.folder, "ask": id, "change": change.map(Change::json), "sites": e.sites, "entry_kind": e.kind,
            }),
        ));
        // "let codex change phone-test’s test" -> "codex wants to change phone-test’s test"
        let title = shown.strip_prefix(&format!("let {who} ")).map(|rest| format!("{who} wants to {rest}")).unwrap_or_else(|| shown.clone());
        self.asks.lock().unwrap().insert(id.clone(), ask);
        self.event("ask", json!({ "ask": id, "kind": "approve", "title": title, "entry": e.name }));
        Ok(id)
    }

    /// A command the agent wants the user's yes for, while they're away. `grant` is what the yes is kept
    /// under (the command's digest), for exactly one run.
    pub(super) async fn ask_command(&self, c: &Client, shown: &str, why: Option<&str>, grant: &str, mac: Value) -> Result<String, Fail> {
        let base = self.remote_base().await?;
        let who = c.who();
        let info = json!({ "command": shown, "why": why, "prompt": format!("let {who} run this command"), "blanks": mac["blanks"] });
        let (id, mut ask) = self.add_ask(c, "approve", &base, Duration::from_secs(self.waits().await.phone), (COMMAND_ENTRY, "a command"), info);
        ask.action = format!("run `{}`", super::shorten(shown, 120));
        ask.grant = grant.to_string();
        ask.once = true;
        // where it runs, which can be other than where the agent started
        if let Some(f) = mac["folder"].as_str() {
            ask.folder = Some(f.to_string());
        }
        let mut mac = mac;
        mac["ask"] = json!(id);
        ask.mac = Some(("approve_command", mac));
        self.asks.lock().unwrap().insert(id.clone(), ask);
        self.event("ask", json!({ "ask": id, "kind": "approve", "title": format!("{who} wants to run a command"), "entry": "a command" }));
        Ok(id)
    }

    /// The user clicked the request's notification on the Mac: show the window or Touch ID prompt there,
    /// and whichever answer comes first (here or the phone) counts.
    pub(super) fn ask_here(&self, id: &str) -> bool {
        let mac = {
            let mut asks = self.asks.lock().unwrap();
            match asks.get_mut(id) {
                Some(a) if a.done.is_none() && !a.expired() => {
                    // the window shows how long it has left
                    let left = a.life.saturating_sub(a.created.elapsed()).as_secs();
                    a.mac.take().map(|(op, mut args)| {
                        args["expires_in"] = json!(left);
                        (op, args)
                    })
                }
                _ => None,
            }
        };
        let Some((op, args)) = mac else { return false };
        let (st, id) = (self.arc(), id.to_string());
        tokio::spawn(async move {
            match op {
                "save_dialog" => st.save_at_mac(&id, args).await,
                op => st.approve_at_mac(&id, op, args).await,
            }
        });
        true
    }

    async fn approve_at_mac(&self, id: &str, op: &str, mut args: Value) {
        if !args["change"].is_null() || op == "approve_command" {
            args["pin"] = json!(self.pin_ready().await);
        }
        let blanks = blanks::parse(&args).unwrap_or_default();
        let template = args["command"].as_str().unwrap_or_default().to_string();
        let wait = left_of(&args);
        match self.ask_app(op, args, wait).await {
            Ok(r) if r["approved"] == true => {
                if !blanks.is_empty() {
                    let Ok(values) = self.resolve_filled(&template, &blanks, &r).await else { return };
                    self.apply_remember(&template, &blanks, &values, &r).await;
                    self.keep_for_ask(id, values);
                }
                self.settle(id, Outcome::Approved, AT_MAC);
            }
            // only a real no ends it: a prompt that couldn't show (the screen locked) leaves the link working
            Ok(r) if r["declined"] == true => {
                self.settle(id, Outcome::Declined, AT_MAC);
            }
            _ => {}
        }
    }

    /// What the user typed into a command's blanks, kept until the agent's next call. The first answer wins.
    fn keep_for_ask(&self, id: &str, values: Vec<String>) {
        let key = self.asks.lock().unwrap().get(id).filter(|a| a.done.is_none()).map(|a| (a.thread.clone(), a.grant.clone()));
        if let Some((thread, grant)) = key {
            self.keep_filled(thread, grant, values);
        }
    }

    /// The first answer wins; the other side is told to close its window or prompt.
    pub(super) fn settle(&self, id: &str, out: Outcome, from: &str) -> bool {
        let (kind, who, entry, action) = {
            let mut asks = self.asks.lock().unwrap();
            let Some(a) = asks.get_mut(id) else { return false };
            if a.done.is_some() {
                return false;
            }
            a.busy = false;
            a.done = Some((out.clone(), from.to_string(), Instant::now()));
            a.tx.send_replace(Some(out.clone()));
            if out == Outcome::Approved {
                // the agent calls again: that one call counts as asked, and a plain yes covers the
                // thread for a while like Touch ID does
                self.once.lock().unwrap().insert((a.entry_id.clone(), a.thread.clone(), a.grant.clone()), Instant::now());
                if !a.once {
                    self.approvals.lock().unwrap().insert((a.entry_id.clone(), a.thread.clone()), Instant::now());
                }
            }
            (a.kind, a.who.clone(), a.entry.clone(), a.action.clone())
        };
        self.event("ask_done", json!({ "ask": id }));
        let at = place(from);
        match (&out, kind) {
            (Outcome::Saved(_), _) => self.you("saved", Some(&entry), true, format!("{at}, {who} asked")),
            (Outcome::Approved, _) => self.you("approved", Some(&entry), true, format!("{who}: {action}, {at}")),
            (Outcome::Declined, "save") => self.you("declined", Some(&entry), true, format!("didn't save it for {who}, {at}")),
            (Outcome::Declined, _) => self.you("declined", Some(&entry), true, format!("{who}: {action}, {at}")),
            (Outcome::Expired, _) => {}
        }
        true
    }

    /// A yes from a request that came back pending, for exactly this call.
    pub(super) fn take_once(&self, entry_id: &str, thread: &str, action: &str) -> bool {
        let mut once = self.once.lock().unwrap();
        once.retain(|_, t| t.elapsed() < YES_LIFE);
        once.remove(&(entry_id.to_string(), thread.to_string(), action.to_string())).is_some()
    }

    /// What the agent gets back while the user decides.
    pub(super) fn pending(&self, id: &str) -> Option<Value> {
        let asks = self.asks.lock().unwrap();
        let a = asks.get(id)?;
        Some(json!({ "pending": true, "request": id, "kind": a.kind, "link": a.link, "expires_in": a.life.as_secs(), "entry": a.entry }))
    }

    pub(super) async fn op_wait(&self, c: &Client, args: &Value) -> OpResult {
        let id = arg_str(args, "request")?;
        let (mut rx, left, kind) = {
            let asks = self.asks.lock().unwrap();
            let a = asks.get(id).ok_or_else(|| Fail::new("not_found", "no such request (it may have ended a while ago)"))?;
            if a.thread != c.thread {
                return Err(Fail::new("denied", "that request belongs to another session"));
            }
            (a.tx.subscribe(), a.life.saturating_sub(a.created.elapsed()), a.kind)
        };
        let out = match tokio::time::timeout(left + Duration::from_secs(2), rx.wait_for(Option::is_some)).await {
            Ok(Ok(v)) => v.clone().unwrap_or(Outcome::Expired),
            _ => Outcome::Expired,
        };
        let from = self.asks.lock().unwrap().get(id).and_then(|a| a.done.as_ref().map(|d| d.1.clone())).unwrap_or_default();
        match out {
            Outcome::Saved(entry) => Ok(json!({ "saved": true, "entry": entry, "from": from })),
            Outcome::Approved => Ok(json!({ "approved": true, "from": from })),
            Outcome::Declined if kind == "save" => Err(Fail::new("cancelled", format!("the user didn't save it ({})", place(&from))).noted(format!("you didn't save it ({})", place(&from)))),
            Outcome::Declined => Err(Fail::new("denied", format!("the user said no ({})", place(&from))).noted(format!("you said no ({})", place(&from)))),
            Outcome::Expired => Err(Fail::new("expired", "nobody answered in time: the request and its link have expired").noted("nobody answered in time")),
        }
    }

    /// Expire what nobody answered, forget what was answered a while ago.
    pub(super) fn sweep(&self) {
        let expired: Vec<String> = self.asks.lock().unwrap().iter().filter(|(_, a)| a.expired()).map(|(id, _)| id.clone()).collect();
        for id in expired {
            self.settle(&id, Outcome::Expired, "nobody");
        }
        self.asks.lock().unwrap().retain(|_, a| a.done.as_ref().is_none_or(|d| d.2.elapsed() < KEEP_DONE));
    }

    // ---- the phone page's server ------------------------------------------------------

    async fn remote_conf(&self) -> Option<Conf> {
        self.with_vault(|v| Ok(v.remote())).await.ok()
    }

    /// Where links point, when the user can answer from their phone right now.
    async fn link_base(&self) -> Option<String> {
        if !self.remote_conf().await?.on() {
            return None;
        }
        self.remote.lock().unwrap().addr.map(|a| format!("http://{a}"))
    }

    pub(super) async fn remote_base(&self) -> Result<String, Fail> {
        self.link_base().await.ok_or_else(|| {
            Fail::new(
                "no_remote",
                "the user hasn't set up answering from their phone (otto Settings → Remote, with Tailscale on the Mac and the phone), or Tailscale is off. without `remote` it asks them at the Mac",
            )
        })
    }

    /// Serve the page on the Mac's Tailscale address while remote is set up and Tailscale is up.
    pub(super) async fn remote_tick(&self, check_tailnet: bool) {
        let want = self.remote_conf().await.is_some_and(|c| c.pin.is_some());
        let tn = if want || check_tailnet { Some(remote::tailnet().await) } else { None };
        {
            let mut rt = self.remote.lock().unwrap();
            if let Some(tn) = tn {
                rt.tailnet = tn;
            }
            let target = if want && rt.tailnet.state == "running" { rt.tailnet.ip.map(|ip| SocketAddr::new(ip, remote::port())) } else { None };
            let dead = rt.task.as_ref().is_some_and(|t| t.is_finished());
            if rt.addr != target || dead {
                if let Some(t) = rt.task.take() {
                    t.abort();
                }
                rt.addr = None;
                rt.error = None;
                rt.whois.clear();
                if let Some(a) = target {
                    match listen(a) {
                        Ok(l) => {
                            rt.task = Some(tokio::spawn(self.arc().accept(l)));
                            rt.addr = Some(a);
                        }
                        Err(e) => rt.error = Some(format!("couldn't listen on {a}: {e}")),
                    }
                }
            }
        }
        self.remote_changed().await;
    }

    pub(super) async fn remote_status(&self) -> Value {
        let conf = self.remote_conf().await.unwrap_or_default();
        let rt = self.remote.lock().unwrap();
        let devices: Vec<Value> = conf
            .devices
            .iter()
            .map(|d| json!({ "id": d.id, "name": d.name, "os": d.os, "paired": d.paired, "seen": rt.seen.get(&d.id) }))
            .collect();
        json!({
            "pin_set": conf.pin.is_some(),
            "on": conf.on(),
            "locked": conf.locked,
            "tailscale": if rt.tailnet.state.is_empty() { "stopped" } else { rt.tailnet.state.as_str() },
            "ip": rt.tailnet.ip,
            "port": remote::port(),
            "url": rt.addr.map(|a| format!("http://{a}")),
            "listening": rt.addr.is_some(),
            "error": rt.error.clone().or_else(|| rt.tailnet.error.clone()),
            "devices": devices,
        })
    }

    /// Tell the app when anything it shows about remote changed.
    async fn remote_changed(&self) {
        let status = self.remote_status().await;
        let changed = {
            let mut rt = self.remote.lock().unwrap();
            let changed = rt.last != status;
            rt.last = status.clone();
            changed
        };
        if changed {
            self.event("remote", status);
        }
    }

    /// The app's Remote settings.
    pub(super) async fn handle_remote(&self, op: &str, args: &Value) -> OpResult {
        match op {
            "remote_status" => {}
            "remote_set_pin" => {
                let pin = arg_str(args, "pin")?.to_string();
                if !remote::valid_pin(&pin) {
                    return Err(Fail::bad("the PIN is 6 digits"));
                }
                let hash = tokio::task::spawn_blocking(move || remote::hash_pin(&pin)).await.map_err(|e| Fail::new("internal", e.to_string()))?;
                let was = self
                    .with_vault_mut(|v| {
                        let mut c = v.remote();
                        let was = (c.pin.is_some(), c.locked);
                        c.pin = Some(hash);
                        c.failures = 0;
                        c.locked = false;
                        v.set_remote(&c);
                        Ok(was)
                    })
                    .await?;
                let detail = match was {
                    (_, true) => "set the PIN again, remote is back on",
                    (true, false) => "changed the PIN",
                    (false, false) => "set a PIN",
                };
                self.you("remote_on", None, true, detail.into());
            }
            "remote_off" => {
                let had = self
                    .with_vault_mut(|v| {
                        let c = v.remote();
                        v.set_remote(&Conf::default());
                        Ok(c.pin.is_some() || !c.devices.is_empty())
                    })
                    .await?;
                if had {
                    self.you("remote_off", None, true, "forgot the PIN and every device".into());
                }
            }
            "remote_forget" => {
                let id = arg_str(args, "id")?.to_string();
                let gone = self
                    .with_vault_mut(|v| {
                        let mut c = v.remote();
                        let gone = c.devices.iter().find(|d| d.id == id).map(|d| d.name.clone());
                        c.devices.retain(|d| d.id != id);
                        v.set_remote(&c);
                        Ok(gone)
                    })
                    .await?;
                if let Some(name) = gone {
                    self.remote.lock().unwrap().seen.remove(&id);
                    self.you("remote_forget", None, true, name);
                }
            }
            _ => return Err(Fail::bad(format!("unknown app operation `{op}`"))),
        }
        self.remote_tick(true).await;
        Ok(self.remote_status().await)
    }

    async fn accept(self: Arc<Self>, l: TcpListener) {
        loop {
            match l.accept().await {
                Ok((s, peer)) => {
                    let st = self.clone();
                    tokio::spawn(async move { st.serve_phone(s, peer).await });
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(200)).await,
            }
        }
    }

    async fn serve_phone(&self, mut s: TcpStream, peer: SocketAddr) {
        let Ok(Some(req)) = tokio::time::timeout(Duration::from_secs(15), remote::read_req(&mut s)).await else { return };
        let res = self.phone(&req, peer.ip()).await;
        let _ = tokio::time::timeout(Duration::from_secs(15), remote::write_res(&mut s, res)).await;
    }

    async fn phone(&self, req: &HttpReq, ip: IpAddr) -> HttpRes {
        let Some(addr) = self.remote.lock().unwrap().addr else { return HttpRes::fail(404, "off", "remote is off") };
        let origin = format!("http://{addr}");
        // a page on another name that resolves here (DNS rebinding) gets nothing
        if req.header("host") != Some(addr.to_string().as_str()) {
            return HttpRes::fail(421, "wrong_host", format!("open {origin} itself"));
        }
        if req.method == "GET" {
            if let Some(a) = remote::asset(&req.path) {
                return a;
            }
        }
        let Some(api) = req.path.strip_prefix("/api/") else { return HttpRes::fail(404, "not_found", "nothing here") };
        if req.method == "POST" {
            if !req.header("content-type").is_some_and(|t| t.starts_with("application/json")) {
                return HttpRes::fail(400, "bad_request", "send JSON");
            }
            if req.header("origin").is_some_and(|o| o != origin) {
                return HttpRes::fail(403, "bad_origin", "that page isn't otto's");
            }
        }
        let peer = match self.peer(ip).await {
            Ok(p) => p,
            Err(r) => return r,
        };
        let Some(conf) = self.remote_conf().await else { return HttpRes::fail(423, "vault_locked", "otto is locked on the Mac") };
        if conf.locked {
            return HttpRes::fail(423, "locked", "too many wrong PINs: remote is off until you set the PIN again in otto on your Mac");
        }
        let device = paired(&conf, req, &peer);
        if let Some(d) = &device {
            self.remote.lock().unwrap().seen.insert(d.id.clone(), now());
        }
        let body: Value = serde_json::from_slice(&req.body).unwrap_or(Value::Null);
        let parts: Vec<&str> = api.split('/').collect();
        match (req.method.as_str(), parts.as_slice()) {
            ("GET", ["r", id]) => self.ask_info(id, device.is_some(), &peer),
            ("POST", ["pair"]) => self.pair(body["pin"].as_str().unwrap_or(""), &peer).await,
            ("POST", ["r", id, what]) => {
                let Some(d) = device else { return HttpRes::fail(401, "not_paired", "pair this device with your PIN first") };
                match *what {
                    "save" => self.save_from_phone(id, &body, &d).await,
                    "approve" => self.approve_from_phone(id, &body, &d, &peer).await,
                    "decline" => match self.check_open(id, None) {
                        Err(r) => r,
                        Ok(()) if self.settle(id, Outcome::Declined, &d.name) => HttpRes::json(200, &json!({ "declined": true })),
                        Ok(()) => HttpRes::fail(409, "answered", "it was already answered"),
                    },
                    _ => HttpRes::fail(404, "not_found", "nothing here"),
                }
            }
            ("GET" | "POST", _) => HttpRes::fail(404, "not_found", "nothing here"),
            _ => HttpRes::fail(405, "bad_method", "not like that"),
        }
    }

    /// Tailscale says who's connecting: one of the user's own devices, and not this Mac.
    async fn peer(&self, ip: IpAddr) -> Result<Peer, HttpRes> {
        let cached = {
            let rt = self.remote.lock().unwrap();
            rt.whois.get(&ip).filter(|(t, _)| t.elapsed() < WHOIS_TTL).map(|(_, p)| p.clone())
        };
        let p = match cached {
            Some(p) => p,
            None => {
                let p = remote::whois(ip).await;
                self.remote.lock().unwrap().whois.insert(ip, (Instant::now(), p.clone()));
                p
            }
        };
        let me = self.remote.lock().unwrap().tailnet.clone();
        match p {
            Ok(p) if !me.node.is_empty() && p.node == me.node => Err(HttpRes::fail(403, "this_mac", "this is the Mac itself: open the link on your phone")),
            Ok(p) if p.tagged || me.user.is_empty() || p.user != me.user => {
                Err(HttpRes::fail(403, "not_yours", "otto only opens on your own devices on Tailscale"))
            }
            Ok(p) => Ok(p),
            Err(_) => Err(HttpRes::fail(403, "not_yours", "otto only opens on your own devices on Tailscale")),
        }
    }

    fn ask_info(&self, id: &str, paired: bool, peer: &Peer) -> HttpRes {
        let asks = self.asks.lock().unwrap();
        let Some(a) = asks.get(id) else { return HttpRes::fail(404, "not_found", "this link isn't valid (any more)") };
        let (state, from) = match &a.done {
            Some((o, f, _)) => (o.state(), Some(f.clone())),
            None if a.expired() => ("expired", None),
            None => ("pending", None),
        };
        let mut v = a.info.clone();
        // what a change would write shows only while it's still a question
        if state != "pending" && v["change"].is_object() {
            v["change"]["value"] = Value::Null;
        }
        // a remembered value too, and what else a secret is saved for: only to a paired device
        if state != "pending" || !paired {
            for b in v["blanks"].as_array_mut().into_iter().flatten() {
                if let Some(o) = b.as_object_mut() {
                    o.remove("value");
                    o.remove("elsewhere");
                }
            }
        }
        v["kind"] = json!(a.kind);
        v["state"] = json!(state);
        v["paired"] = json!(paired);
        v["device"] = json!(peer.name);
        v["agent"] = json!(a.who);
        v["folder"] = json!(a.folder);
        v["expires_in"] = json!(a.life.saturating_sub(a.created.elapsed()).as_secs());
        v["answered_from"] = json!(from.filter(|f| f != "nobody"));
        HttpRes::json(200, &v)
    }

    /// Still waiting for an answer (and of this kind)?
    fn check_open(&self, id: &str, kind: Option<&str>) -> Result<(), HttpRes> {
        let asks = self.asks.lock().unwrap();
        let a = asks.get(id).ok_or_else(|| HttpRes::fail(404, "not_found", "this link isn't valid (any more)"))?;
        if kind.is_some_and(|k| k != a.kind) {
            return Err(HttpRes::fail(400, "bad_request", "that's not what this link is for"));
        }
        if a.done.is_some() || a.busy {
            return Err(HttpRes::fail(409, "answered", "it was already answered"));
        }
        if a.expired() {
            return Err(HttpRes::fail(410, "expired", "this link has expired"));
        }
        Ok(())
    }

    async fn check_pin(&self, pin: &str, peer: &Peer) -> Result<(), HttpRes> {
        self.verify_pin(pin, &peer.name).await.map_err(|e| match e {
            PinErr::VaultLocked => HttpRes::fail(423, "vault_locked", "otto is locked on the Mac"),
            PinErr::Off => HttpRes::fail(423, "locked", "remote is off. set the PIN again in otto on your Mac"),
            PinErr::Locked => HttpRes::fail(423, "locked", "too many wrong PINs: remote is off until you set the PIN again in otto on your Mac"),
            PinErr::Wrong(left) => HttpRes::json(403, &json!({ "error": "wrong_pin", "message": "that's not the PIN", "left": left })),
        })
    }

    /// Whether the Mac can ask for the PIN (in place of Touch ID, on a Mac without it).
    pub(super) async fn pin_ready(&self) -> bool {
        self.remote_conf().await.is_some_and(|c| c.pin.is_some() && !c.locked)
    }

    /// The PIN typed at the Mac, in a change window on a Mac without Touch ID. Wrong ones count with the phone's.
    pub(super) async fn mac_pin(&self, pin: &str) -> OpResult {
        match self.verify_pin(pin, "this Mac").await {
            Ok(()) => Ok(json!({ "ok": true })),
            Err(PinErr::Wrong(left)) => Ok(json!({ "ok": false, "left": left })),
            Err(PinErr::VaultLocked) => Err(Fail::new("locked", "otto is locked")),
            Err(PinErr::Off | PinErr::Locked) => Err(Fail::new("pin_off", "too many wrong PINs: the PIN is off until you set it again in Settings, Remote")),
        }
    }

    /// The PIN the user set at the Mac. Wrong ones count, all devices together; too many and remote
    /// turns itself off until the user sets the PIN again at the Mac.
    async fn verify_pin(&self, pin: &str, from: &str) -> Result<(), PinErr> {
        let conf = self.remote_conf().await.ok_or(PinErr::VaultLocked)?;
        let Some(hash) = conf.pin.clone().filter(|_| !conf.locked) else {
            return Err(PinErr::Off);
        };
        let pin = pin.to_string();
        let ok = remote::valid_pin(&pin) && tokio::task::spawn_blocking(move || remote::check_pin(&pin, &hash)).await.unwrap_or(false);
        if ok {
            if conf.failures > 0 {
                let _ = self
                    .with_vault_mut(|v| {
                        let mut c = v.remote();
                        c.failures = 0;
                        v.set_remote(&c);
                        Ok(())
                    })
                    .await;
            }
            return Ok(());
        }
        let counted = self
            .with_vault_mut(|v| {
                let mut c = v.remote();
                c.failures += 1;
                if c.failures >= remote::MAX_TRIES {
                    c.locked = true;
                }
                v.set_remote(&c);
                Ok((c.failures, c.locked))
            })
            .await;
        // slows guessing down a little more
        tokio::time::sleep(Duration::from_millis(800)).await;
        let Ok((failures, locked)) = counted else { return Err(PinErr::VaultLocked) };
        if locked {
            self.you("remote_locked", None, false, format!("{} wrong PINs, the last from {from}", remote::MAX_TRIES));
            self.event("remote_notice", json!({ "kind": "locked", "device": from }));
            self.remote_changed().await;
            return Err(PinErr::Locked);
        }
        let left = remote::MAX_TRIES - failures;
        self.you("remote_pin", None, false, format!("wrong PIN from {from}, {left} {} left", if left == 1 { "try" } else { "tries" }));
        Err(PinErr::Wrong(left))
    }

    async fn pair(&self, pin: &str, peer: &Peer) -> HttpRes {
        if let Err(r) = self.check_pin(pin, peer).await {
            return r;
        }
        let key = remote::hex(&remote::random(32));
        let device = Device {
            id: remote::hex(&remote::random(6)),
            key: remote::sha256_hex(&key),
            node: peer.node.clone(),
            name: peer.name.clone(),
            os: peer.os.clone(),
            paired: now(),
        };
        let cookie = format!("otto_device={}.{key}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Strict", device.id);
        let r = self
            .with_vault_mut(|v| {
                let mut c = v.remote();
                // pairing again (Safari forgot the cookie) replaces the old one
                c.devices.retain(|d| d.node != device.node);
                c.devices.push(device.clone());
                v.set_remote(&c);
                Ok(())
            })
            .await;
        if let Err(f) = r {
            return HttpRes::fail(500, &f.code, f.message);
        }
        self.remote.lock().unwrap().seen.insert(device.id.clone(), now());
        let os = if peer.os.is_empty() { String::new() } else { format!(" ({})", peer.os) };
        self.you("remote_pair", None, true, format!("{}{os}", peer.name));
        self.event("remote_notice", json!({ "kind": "paired", "device": peer.name, "os": peer.os }));
        self.remote_changed().await;
        let mut res = HttpRes::json(200, &json!({ "paired": true, "device": peer.name }));
        res.cookie = Some(cookie);
        res
    }

    async fn save_from_phone(&self, id: &str, body: &Value, d: &Device) -> HttpRes {
        if let Err(r) = self.check_open(id, Some("save")) {
            return r;
        }
        let (needs, existing, name, site, app) = {
            let asks = self.asks.lock().unwrap();
            let Some(a) = asks.get(id) else { return HttpRes::fail(404, "not_found", "this link isn't valid (any more)") };
            (a.needs.clone(), a.existing.clone(), a.entry.clone(), a.info["site"].as_str().map(String::from), a.info["app"].as_str().map(String::from))
        };
        let patch = match save_patch(&needs, existing.as_ref(), &name, site, app, body) {
            Ok(p) => p,
            Err(f) => return HttpRes::fail(400, &f.code, f.message),
        };
        match self.finish_save(id, patch, &d.name).await {
            Ok(_) => HttpRes::json(200, &json!({ "saved": true })),
            Err(f) if f.code == "answered" => HttpRes::fail(409, "answered", f.message),
            Err(f) if f.code == "expired" => HttpRes::fail(410, "expired", f.message),
            Err(f) => HttpRes::fail(400, &f.code, f.message),
        }
    }

    async fn approve_from_phone(&self, id: &str, body: &Value, d: &Device, peer: &Peer) -> HttpRes {
        // a dead link, or a blank left empty, shouldn't cost a try
        if let Err(r) = self.check_open(id, Some("approve")) {
            return r;
        }
        let (blanks, template) = {
            let asks = self.asks.lock().unwrap();
            let a = asks.get(id);
            (a.and_then(|a| blanks::parse(&a.info).ok()).unwrap_or_default(), a.and_then(|a| a.info["command"].as_str().map(String::from)).unwrap_or_default())
        };
        let values = if blanks.is_empty() { None } else {
            match self.resolve_filled(&template, &blanks, body).await {
                Ok(v) => Some(v),
                Err(why) => return HttpRes::fail(400, "blank", why),
            }
        };
        if let Err(r) = self.check_pin(body["pin"].as_str().unwrap_or(""), peer).await {
            return r;
        }
        if let Some(values) = values {
            self.apply_remember(&template, &blanks, &values, body).await;
            self.keep_for_ask(id, values);
        }
        if self.settle(id, Outcome::Approved, &d.name) {
            HttpRes::json(200, &json!({ "approved": true }))
        } else {
            HttpRes::fail(409, "answered", "it was already answered")
        }
    }
}

enum PinErr {
    VaultLocked,
    /// no PIN, or it was locked before this try
    Off,
    /// this try was the last one
    Locked,
    /// tries left
    Wrong(u32),
}

fn listen(a: SocketAddr) -> std::io::Result<TcpListener> {
    let s = if a.is_ipv4() { tokio::net::TcpSocket::new_v4()? } else { tokio::net::TcpSocket::new_v6()? };
    s.set_reuseaddr(true)?;
    s.bind(a)?;
    s.listen(64)
}

/// The device behind this request's cookie, if it was paired from this same Tailscale node.
fn paired(conf: &Conf, req: &HttpReq, peer: &Peer) -> Option<Device> {
    let (id, key) = req.cookie("otto_device")?.split_once('.')?;
    let hash = remote::sha256_hex(key);
    conf.devices.iter().find(|d| d.id == id && d.key == hash && d.node == peer.node).cloned()
}

/// What the phone's save form becomes, the way the Mac's save window builds it.
fn save_patch(needs: &[String], existing: Option<&EntryInfo>, name: &str, site: Option<String>, app: Option<String>, body: &Value) -> Result<EntryPatch, Fail> {
    let needs_password = needs.is_empty() || needs.iter().any(|n| n == "password");
    let needs_totp = needs.iter().any(|n| n == "totp");
    let mut p = EntryPatch::default();
    match existing {
        Some(e) => p.id = Some(e.id.clone()),
        None => {
            p.name = Some(name.to_string());
            p.policy = Some(Policy::Auto);
            p.sites = Some(site.into_iter().collect());
            p.apps = Some(app.into_iter().collect());
        }
    }
    if needs_password {
        p.username = Some(body["username"].as_str().unwrap_or("").trim().to_string());
        let password = body["password"].as_str().unwrap_or("");
        if !password.is_empty() {
            p.password = Some(password.to_string());
        } else if !existing.is_some_and(|e| e.has_password) {
            return Err(Fail::bad("type the password"));
        }
    }
    if needs_totp {
        match body["two_factor"].as_str().unwrap_or("app") {
            "app" => {
                let otp = body["otp"].as_str().unwrap_or("").trim();
                if !otp.is_empty() {
                    Totp::parse(otp).map_err(|e| Fail::new("bad_totp", format!("that's not a 2FA setup key otto can read: {e}")))?;
                    p.otp = Some(otp.to_string());
                } else if existing.is_none_or(|e| e.totp.is_none()) {
                    return Err(Fail::new("bad_totp", "paste the 2FA setup key (or the otpauth:// link)"));
                }
                p.two_factor = Some(String::new());
            }
            t @ ("delivered" | "none") => p.two_factor = Some(t.to_string()),
            other => return Err(Fail::bad(format!("2FA is app, delivered or none, not {other}"))),
        }
    }
    Ok(p)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn approval_prompts_read_like_touch_id() {
        assert_eq!(prompt("claude", "fill its login in the browser", "GitHub"), "let claude fill GitHub’s login in the browser");
        assert_eq!(prompt("codex", "get a 2FA code", "AWS"), "let codex get a 2FA code for AWS");
    }

    #[test]
    fn a_yes_to_a_change_covers_that_value_only() {
        let one = Change::new("password", Some("one".into()), None, "one");
        let two = Change::new("password", Some("two".into()), None, "two");
        assert_ne!(Change::grant("change its password", Some(&one)), Change::grant("change its password", Some(&two)));
        assert_eq!(Change::grant("change its password", Some(&one)), Change::grant("change its password", Some(&one.clone())));
        assert_eq!(Change::grant("get a 2FA code", None), "get a 2FA code");
        assert!(one.secret && !Change::new("username", Some("alfa".into()), None, "alfa").secret);
    }

    #[test]
    fn phone_saves_need_what_the_agent_asked_for() {
        let body = json!({ "username": " alfa ", "password": "" });
        assert!(save_patch(&[], None, "github", Some("github.com".into()), None, &body).is_err());
        let p = save_patch(&[], None, "github", Some("github.com".into()), None, &json!({ "username": " alfa ", "password": "pw" })).unwrap();
        assert_eq!((p.name.as_deref(), p.username.as_deref(), p.password.as_deref(), p.sites.clone()), (Some("github"), Some("alfa"), Some("pw"), Some(vec!["github.com".to_string()])));
        assert_eq!(p.policy, Some(Policy::Auto));
        let needs = vec!["totp".to_string()];
        assert!(save_patch(&needs, None, "x", None, None, &json!({ "two_factor": "app", "otp": "not a key!" })).is_err());
        let p = save_patch(&needs, None, "x", None, None, &json!({ "two_factor": "app", "otp": "JBSWY3DPEHPK3PXP" })).unwrap();
        assert_eq!((p.otp.as_deref(), p.two_factor.as_deref(), p.password.as_deref()), (Some("JBSWY3DPEHPK3PXP"), Some(""), None));
        let p = save_patch(&needs, None, "x", None, None, &json!({ "two_factor": "delivered" })).unwrap();
        assert_eq!(p.two_factor.as_deref(), Some("delivered"));
    }
}
