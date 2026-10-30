//! The background service. Otto.app starts it as a child and talks to it over stdin/stdout
//! (the private channel: unlock, edits, approvals). Agents talk to it over a unix socket and
//! only get the agent-level operations, which never hand out passwords or 2FA secrets.

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fs,
    os::fd::AsRawFd,
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex as StdMutex,
    },
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader, Lines},
    net::{unix::OwnedReadHalf, UnixListener, UnixStream},
    sync::{mpsc, oneshot, Mutex},
};

mod asks;
mod blanks;
use asks::Change;

use crate::{
    audit::{Audit, Event},
    paths,
    peer::{self, BrowserSig, Client, Grant, Verdict},
    proto::*,
    totp::Totp,
    vault::{base_domain, main_field, normalize_site, parse_expiry, site_matches, Consent, EntryInfo, EntryPatch, Policy, Vault, Waits, TRASH_DAYS},
};

/// how long one Touch ID approval covers further requests for the same entry, from the same thread
const APPROVAL_TTL: Duration = Duration::from_secs(10 * 60);
/// how long a site the user allowed once (without adding it to the entry) stays allowed
const SITE_GRANT_TTL: Duration = Duration::from_secs(10 * 60);
/// ops that use an entry; with bypass on, their log line says so
/// After the user turns down unlocking for an agent, requests in this time fail as locked without asking again.
const UNLOCK_QUIET: Duration = Duration::from_secs(30);
const USES: &[&str] = &["code", "fill", "fill_code", "fill_on_site", "fill_card", "type", "env"];
/// Payment providers whose card fields sit in frames on a shop's checkout page (Stripe Elements,
/// Braintree hosted fields...). A card is filled into the shop's own page and into frames from these, nowhere else.
const PAYMENT_HOSTS: &[&str] = &[
    "stripe.com", "braintreegateway.com", "adyen.com", "checkout.com", "paypal.com", "squareup.com", "recurly.com",
    "chargebee.com", "mollie.com", "paddle.com", "shopifyinc.com", "iyzipay.com", "iyzico.com", "paytr.com", "craftgate.io",
];

/// A request/response channel to the app or to a browser bridge.
struct Link {
    tx: mpsc::UnboundedSender<String>,
    pending: StdMutex<HashMap<u64, oneshot::Sender<OpResult>>>,
    next: AtomicU64,
    label: &'static str,
}

impl Link {
    fn new(tx: mpsc::UnboundedSender<String>, label: &'static str) -> Arc<Link> {
        Arc::new(Link { tx, pending: StdMutex::new(HashMap::new()), next: AtomicU64::new(1), label })
    }

    async fn request(&self, op: &str, args: Value, timeout: Duration) -> OpResult {
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(id, tx);
        let line = json!({ "type": "req", "id": id, "op": op, "args": args }).to_string();
        if self.tx.send(line).is_err() {
            self.pending.lock().unwrap().remove(&id);
            return Err(Fail::new("gone", format!("{} isn't connected", self.label)));
        }
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(r)) => r,
            Ok(Err(_)) => Err(Fail::new("gone", format!("{} disconnected", self.label))),
            Err(_) => {
                self.pending.lock().unwrap().remove(&id);
                Err(Fail::new("timeout", format!("{} didn't answer in time", self.label)))
            }
        }
    }

    fn resolve(&self, v: &Value) {
        let Some(id) = v["id"].as_u64() else { return };
        if let Some(tx) = self.pending.lock().unwrap().remove(&id) {
            let _ = tx.send(parse_response(v));
        }
    }

    fn send(&self, v: Value) {
        let _ = self.tx.send(v.to_string());
    }

    fn fail_all(&self) {
        for (_, tx) in self.pending.lock().unwrap().drain() {
            let _ = tx.send(Err(Fail::new("gone", format!("{} disconnected", self.label))));
        }
    }
}

struct Bridge {
    conn: u64,
    link: Arc<Link>,
    browser: String,
    /// (bundle id, team) for a browser the user allowed, so forgetting it can cut it off
    sig: Option<(String, String)>,
}

pub struct State {
    vault: Mutex<Option<Vault>>,
    app: Arc<Link>,
    bridges: StdMutex<Vec<Bridge>>,
    /// (entry id, thread) the user approved with Touch ID
    approvals: StdMutex<HashMap<(String, String), Instant>>,
    /// threads the user stopped from a notification: (pid, start time) of the agent's process
    cut: StdMutex<Vec<(i32, u64)>>,
    /// (entry id, domain) the user allowed once for fill_on_site
    site_grants: StdMutex<HashMap<(String, String), Instant>>,
    /// browsers the user said no to, until the app restarts (so they aren't asked about every minute)
    denied_browsers: StdMutex<HashSet<(String, String)>>,
    /// one "allow this browser?" window at a time
    browser_ask: Mutex<()>,
    /// sudo processes that got the Mac password: asking again means sudo didn't take it
    sudo_asks: StdMutex<HashMap<i32, Instant>>,
    /// when the user last said no to unlocking for an agent: not asked again for a little while
    unlock_declined: StdMutex<Option<Instant>>,
    /// saves and approvals waiting for the user while remote is on, by id (also their link)
    asks: StdMutex<HashMap<String, asks::Ask>>,
    /// (entry id, thread, action): a yes for one call that came back pending, so the agent's next call goes through
    once: StdMutex<HashMap<(String, String, String), Instant>>,
    /// what the user typed into a command's blanks, for the agent's next call: (thread, grant)
    filled: StdMutex<HashMap<(String, String), (Instant, Vec<String>)>>,
    /// the phone page's server
    remote: StdMutex<asks::RemoteRt>,
    me: std::sync::OnceLock<std::sync::Weak<State>>,
    audit: Audit,
    self_exe: PathBuf,
    next_conn: AtomicU64,
}

async fn writer<W: AsyncWrite + Unpin>(mut w: W, mut rx: mpsc::UnboundedReceiver<String>) {
    while let Some(line) = rx.recv().await {
        if w.write_all(line.as_bytes()).await.is_err() || w.write_all(b"\n").await.is_err() || w.flush().await.is_err() {
            break;
        }
    }
}

pub async fn run() -> Result<()> {
    let dir = paths::home_dir();
    fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    set_mode(&dir, 0o700);
    let sock = paths::socket_path();
    if std::os::unix::net::UnixStream::connect(&sock).is_ok() {
        bail!("another otto service is already running at {}", sock.display());
    }
    let _ = fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).with_context(|| format!("listening on {}", sock.display()))?;
    set_mode(&sock, 0o600);

    let (app_tx, app_rx) = mpsc::unbounded_channel();
    let state = Arc::new(State {
        vault: Mutex::new(None),
        app: Link::new(app_tx, "the otto app"),
        bridges: StdMutex::new(Vec::new()),
        approvals: StdMutex::new(HashMap::new()),
        cut: StdMutex::new(Vec::new()),
        site_grants: StdMutex::new(HashMap::new()),
        denied_browsers: StdMutex::new(HashSet::new()),
        browser_ask: Mutex::new(()),
        sudo_asks: StdMutex::new(HashMap::new()),
        unlock_declined: StdMutex::new(None),
        asks: StdMutex::new(HashMap::new()),
        once: StdMutex::new(HashMap::new()),
        filled: StdMutex::new(HashMap::new()),
        remote: StdMutex::new(Default::default()),
        me: std::sync::OnceLock::new(),
        audit: Audit::new(paths::audit_path()),
        self_exe: std::env::current_exe()?,
        next_conn: AtomicU64::new(1),
    });
    let _ = state.me.set(Arc::downgrade(&state));
    tokio::spawn(writer(tokio::io::stdout(), app_rx));

    // expire unanswered requests; keep the phone page up while remote is on (Tailscale can come and go)
    let st = state.clone();
    tokio::spawn(async move {
        for n in 0u64.. {
            tokio::time::sleep(Duration::from_secs(5)).await;
            st.sweep();
            if n % 4 == 3 {
                st.remote_tick(false).await;
            }
        }
    });

    let st = state.clone();
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
            match v["type"].as_str() {
                Some("res") => st.app.resolve(&v),
                Some("req") => {
                    let st = st.clone();
                    tokio::spawn(async move {
                        let id = v["id"].as_u64().unwrap_or(0);
                        let r = st.handle_app(v["op"].as_str().unwrap_or(""), &v["args"]).await;
                        st.app.send(response(id, &r));
                    });
                }
                _ => {}
            }
        }
        // the app quit, so nobody can approve anything: stop
        let _ = fs::remove_file(paths::socket_path());
        std::process::exit(0);
    });

    eprintln!("otto: listening on {}", sock.display());
    loop {
        let (stream, _) = listener.accept().await?;
        let st = state.clone();
        tokio::spawn(async move { st.serve(stream).await });
    }
}

fn set_mode(p: &std::path::Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(p, fs::Permissions::from_mode(mode));
}

/// What agents may know about an entry.
fn public(e: &EntryInfo) -> Value {
    let mut j = json!({
        "name": e.name,
        "kind": e.kind,
        "card": e.card,
        "username": e.username,
        "sites": e.sites,
        "apps": e.apps,
        "policy": e.access(),
        "bypass_until": e.bypass.as_ref().and_then(|b| b.until.clone()),
        "has_password": e.has_password,
        "has_2fa": e.totp.is_some(),
        "two_factor": e.two_factor,
        "scripts": e.scripts,
        "fields": e.fields,
    });
    // what an agent needs to leave a blank for it: the name, and for a secret the exact commands it comes
    // back for. Never what's in it
    if e.kind == "value" {
        j["secret"] = json!(e.secret);
        j["commands"] = json!(e.commands);
    }
    j
}

type Done = Result<(Value, String), Fail>;

impl State {
    async fn serve(self: Arc<Self>, stream: UnixStream) {
        let pid = peer::peer_pid(stream.as_raw_fd());
        // checking the agent's signature runs codesign
        let client = tokio::task::spawn_blocking(move || peer::describe(pid)).await.unwrap_or_else(|_| peer::describe(None));
        let (rd, wr) = stream.into_split();
        let (tx, rx) = mpsc::unbounded_channel::<String>();
        tokio::spawn(writer(wr, rx));
        let mut lines = BufReader::new(rd).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let req: Request = match serde_json::from_str(&line) {
                Ok(r) => r,
                Err(e) => {
                    let _ = tx.send(response(0, &Err(Fail::bad(format!("bad request: {e}")))).to_string());
                    continue;
                }
            };
            if req.op == "hello" && req.args["role"] == "bridge" {
                let exe = self.self_exe.clone();
                let verdict = match pid {
                    Some(p) => tokio::task::spawn_blocking(move || peer::verify_bridge(p, &exe)).await.unwrap_or_else(|e| Err(e.to_string())),
                    None => Err("can't identify the bridge process".into()),
                };
                let verdict = match verdict {
                    Ok(Verdict::Trusted(browser)) => Ok((browser, None)),
                    Ok(Verdict::Unknown(sig)) => self.trust_browser(&sig).await.map(|_| (sig.name.clone(), Some((sig.bundle, sig.team)))),
                    Ok(Verdict::Outdated(name)) => Err(Fail::new("relaunch", format!("{name} updated itself while running. relaunch it and otto can connect."))),
                    Err(why) => Err(Fail::new("denied", why)),
                };
                match verdict {
                    Ok((browser, sig)) => {
                        let _ = tx.send(response(req.id, &Ok(json!({ "bridge": true, "browser": browser }))).to_string());
                        self.run_bridge(lines, tx, browser, sig).await;
                    }
                    Err(f) => {
                        if f.code != "locked" && f.code != "relaunch" {
                            self.log(&client, "bridge", None, false, f.for_log());
                        }
                        let _ = tx.send(response(req.id, &Err(f)).to_string());
                    }
                }
                return;
            }
            let st = self.clone();
            let tx = tx.clone();
            let client = client.clone();
            tokio::spawn(async move {
                let r = st.handle(&client, &req.op, &req.args).await;
                let _ = tx.send(response(req.id, &r).to_string());
            });
        }
    }

    /// A browser otto doesn't pin but that's signed with a Developer ID: fine if the user allowed it
    /// before (kept in the vault, so nothing without the key can add one), else the user decides now.
    async fn trust_browser(&self, sig: &BrowserSig) -> Result<(), Fail> {
        let key = (sig.bundle.clone(), sig.team.clone());
        let known = |list: &[BrowserSig]| list.iter().any(|b| b.bundle == sig.bundle && b.team == sig.team);
        if known(&self.with_vault(|v| Ok(v.trusted_browsers())).await?) {
            return Ok(());
        }
        let refused = || Fail::new("denied", format!("you didn't allow {} ({}) to fill logins", sig.name, sig.signer));
        if self.denied_browsers.lock().unwrap().contains(&key) {
            return Err(refused());
        }
        // several windows or profiles connect at once: ask once
        let _one = self.browser_ask.lock().await;
        if known(&self.with_vault(|v| Ok(v.trusted_browsers())).await?) {
            return Ok(());
        }
        if self.denied_browsers.lock().unwrap().contains(&key) {
            return Err(refused());
        }
        let wait = self.waits().await.browser;
        let r = self.ask_window("approve_browser", json!(sig), wait).await;
        if r.as_ref().is_ok_and(|r| r["approved"] == true) {
            self.with_vault_mut(|v| {
                let mut list = v.trusted_browsers();
                list.retain(|b| b.bundle != sig.bundle);
                list.push(sig.clone());
                v.set_trusted_browsers(&list);
                Ok(())
            })
            .await?;
            let ev = self.audit.record("you", "browser_on", None, true, format!("allowed {} to fill logins, signed by {} ({})", sig.name, sig.signer, sig.team));
            self.event("activity", json!(ev));
            return Ok(());
        }
        // a window nobody answered isn't a no
        if r.is_ok() {
            self.denied_browsers.lock().unwrap().insert(key);
        }
        Err(refused())
    }

    async fn run_bridge(&self, mut lines: Lines<BufReader<OwnedReadHalf>>, tx: mpsc::UnboundedSender<String>, browser: String, sig: Option<(String, String)>) {
        let link = Link::new(tx, "the browser extension");
        let conn = self.next_conn.fetch_add(1, Ordering::SeqCst);
        self.bridges.lock().unwrap().push(Bridge { conn, link: link.clone(), browser: browser.clone(), sig });
        self.browser_event();
        while let Ok(Some(line)) = lines.next_line().await {
            let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
            if v["type"] == "res" {
                link.resolve(&v);
            }
        }
        self.bridges.lock().unwrap().retain(|b| b.conn != conn);
        link.fail_all();
        self.browser_event();
    }

    fn browsers(&self) -> Vec<String> {
        let mut names: Vec<String> = self.bridges.lock().unwrap().iter().map(|b| b.browser.clone()).collect();
        names.dedup();
        names
    }

    fn browser_event(&self) {
        self.event("browser", json!({ "browsers": self.browsers() }));
    }

    fn event(&self, name: &str, data: Value) {
        self.app.send(json!({ "type": "event", "event": name, "data": data }));
    }

    fn log(&self, c: &Client, op: &str, entry: Option<&str>, ok: bool, detail: String) {
        self.log_ev(c, op, entry, ok, detail, false);
    }

    fn log_ev(&self, c: &Client, op: &str, entry: Option<&str>, ok: bool, detail: String, pending: bool) {
        let mut ev = Event::new(&c.agent, op, entry, ok, detail);
        ev.via = c.via.clone();
        ev.folder = c.folder.clone();
        ev.unverified = !c.verified;
        ev.pending = pending;
        if let Some((command, why)) = c.command.lock().unwrap().clone() {
            (ev.command, ev.why) = (Some(command), why);
        }
        let ev = self.audit.write(ev);
        self.event("activity", json!(ev));
    }

    /// A use the user didn't approve right then (Auto, bypass, an earlier yes): the app shows a notification,
    /// with Stop for the thread.
    fn used(&self, c: &Client, e: &EntryInfo, how: &str, what: Vec<String>, place: Option<String>) {
        if e.quiet {
            return;
        }
        let Some(g) = c.grant().filter(|g| *g != Grant::Asked) else { return };
        self.event(
            "used",
            json!({
                "agent": c.agent, "who": c.who(), "via": c.via, "thread": c.thread, "folder": c.folder,
                "entry": e.name, "entry_id": e.id, "kind": e.kind, "how": how, "what": what, "place": place,
                "grant": g.as_str(), "bypass": g == Grant::Bypass,
            }),
        );
    }

    /// Refused: the user pressed Stop on a notification for this thread (or one it runs under).
    fn cut_off(&self, c: &Client) -> Option<Fail> {
        let mut cut = self.cut.lock().unwrap();
        cut.retain(|&(pid, start)| peer::proc_start(pid) == Some(start));
        c.procs.iter().any(|p| cut.contains(p)).then(|| {
            Fail::new(
                "cut_off",
                "the user stopped this session from using otto (Stop on otto's notification). nothing from it goes through until it exits. tell the user, and don't try to get around it",
            )
            .noted("you stopped this session")
        })
    }

    /// Bypass on: the sealed consent goes into the log line, so the record of the user's yes is
    /// there for them to see (and a line otto didn't write shows up as unsealed).
    fn log_consent(&self, c: &Consent) {
        let until = c.until.as_deref().map(|u| format!("until {}", local_time(u))).unwrap_or_else(|| "until you turn it off".into());
        let how = if c.auth == "touch_id" { "Touch ID" } else { "your Mac password" };
        let asked = c.asked_by.as_deref().map(|a| format!(", {a} asked")).unwrap_or_default();
        let ev = self.audit.record_consent(&c.name, format!("{how}, you ticked the box, {until}{asked}"), json!(c));
        let mut v = json!(ev);
        v["sealed"] = json!(true);
        self.event("activity", v);
    }

    /// Ask the browser extension. With several browsers (or profiles) connected, first ask them all
    /// at once which one has a tab for these sites, and use the most recently connected that does.
    async fn browser(&self, op: &str, args: Value, timeout: Duration) -> OpResult {
        let links: Vec<Arc<Link>> = self.bridges.lock().unwrap().iter().rev().map(|b| b.link.clone()).collect();
        if links.is_empty() {
            return Err(Fail::new(
                "no_browser",
                "the otto browser extension isn't connected. it needs a Chromium browser (Chrome, Brave, Edge, Arc, Vivaldi, Opera...) open with the otto extension installed (otto Settings → Browser)",
            ));
        }
        if links.len() == 1 {
            return links[0].request(op, args, timeout).await;
        }
        let probe = json!({ "sites": args["sites"], "http": args["http"] });
        let answers = futures_join(links.iter().map(|l| {
            let (l, probe) = (l.clone(), probe.clone());
            async move { l.request("has_tab", probe, Duration::from_secs(3)).await }
        }))
        .await;
        let mut last = None;
        for (l, a) in links.iter().zip(answers) {
            match a {
                Ok(v) if v["found"] == true => return l.request(op, args, timeout).await,
                Ok(_) => {}
                Err(e) => last = Some(e),
            }
        }
        Err(match last {
            Some(e) if e.code != "no_tab" && e.code != "timeout" && e.code != "gone" => e,
            _ => Fail::new("no_tab", format!("no open tab for {}. open the login page in the browser first", args["sites"])).noted("no tab open on its site"),
        })
    }

    async fn ask_app(&self, op: &str, args: Value, timeout: Duration) -> OpResult {
        self.app.request(op, args, timeout).await
    }

    /// A window for the user: it's told how long the service will wait for it (`expires_in`), and shows that.
    async fn ask_window(&self, op: &str, mut args: Value, secs: u64) -> OpResult {
        args["expires_in"] = json!(secs);
        self.ask_app(op, args, Duration::from_secs(secs)).await
    }

    /// How long to wait for the user, as set in Settings. A locked vault can't say: the usual times.
    async fn waits(&self) -> Waits {
        self.with_vault(|v| Ok(v.waits())).await.unwrap_or_default()
    }

    async fn with_vault<T>(&self, f: impl FnOnce(&Vault) -> Result<T, Fail>) -> Result<T, Fail> {
        let mut g = self.vault.lock().await;
        let v = g.as_mut().ok_or_else(|| Fail::new("locked", "the vault is locked. open the otto app to unlock it"))?;
        self.catch_up(v)?;
        f(v)
    }

    async fn with_vault_mut<T>(&self, f: impl FnOnce(&mut Vault) -> Result<T, Fail>) -> Result<T, Fail> {
        let mut g = self.vault.lock().await;
        let v = g.as_mut().ok_or_else(|| Fail::new("locked", "the vault is locked. open the otto app to unlock it"))?;
        self.catch_up(v)?;
        let r = f(v)?;
        tokio::task::block_in_place(|| v.save()).map_err(Fail::from)?;
        drop(g);
        self.event("changed", json!({}));
        Ok(r)
    }

    /// The user's auto-lock closed the vault: an agent that needs it gets the app to ask for Touch ID, and
    /// carries on if the user unlocks. Away from the Mac (remote), nobody can: the request fails as locked.
    async fn unlock_for(&self, c: &Client) {
        if c.away || self.vault.lock().await.is_some() {
            return;
        }
        if self.unlock_declined.lock().unwrap().is_some_and(|t| t.elapsed() < UNLOCK_QUIET) {
            return;
        }
        let args = json!({ "agent": c.who(), "folder": c.folder });
        let r = self.ask_app("unlock", args, Duration::from_secs(90)).await;
        if !r.is_ok_and(|v| v["unlocked"] == true) {
            *self.unlock_declined.lock().unwrap() = Some(Instant::now());
        }
    }

    /// Another program (KeePassXC, a sync folder) changed vault.kdbx: work from that, and tell the app.
    fn catch_up(&self, v: &mut Vault) -> Result<(), Fail> {
        match tokio::task::block_in_place(|| v.reload_if_changed()) {
            Ok(true) => {
                eprintln!("otto: vault.kdbx changed on disk, read it again");
                self.event("changed", json!({}));
                Ok(())
            }
            Ok(false) => Ok(()),
            Err(e) => Err(Fail::new("vault_changed", format!("{e:#}. otto won't write over it; open the otto app"))),
        }
    }

    /// An entry an agent asked for by name. Entries set to "never" don't exist for agents.
    async fn agent_entry(&self, c: &Client, name: &str) -> Result<EntryInfo, Fail> {
        let e = self
            .with_vault(|v| match v.resolve(name) {
                Ok(id) => v.info(id).map(|e| as_seen(c, e)).ok_or_else(|| Fail::new("not_found", "entry vanished")),
                Err(f) if f.code == "not_found" => {
                    let names: Vec<String> = v.list().into_iter().map(|e| as_seen(c, e)).filter(|e| !e.hidden() && !e.library && e.kind != "value").map(|e| e.name).collect();
                    let hint = if names.is_empty() { "the vault is empty; use request_save to ask the user for it".to_string() } else { format!("entries: {}", names.join(", ")) };
                    Err(Fail::new("not_found", format!("{}. {hint}", f.message)).noted(f.for_log()))
                }
                Err(f) => Err(f),
            })
            .await?;
        if e.out_of_scope {
            return Err(Fail::new("denied", format!("\"{}\" isn't open to this agent here: the user limited it to certain projects or agents", e.name)).noted("you limited it to certain projects or agents"));
        }
        if e.hidden() {
            return Err(Fail::new("denied", format!("\"{}\" is off-limits to agents", e.name)));
        }
        if e.kind == "value" {
            return Err(wrong_kind(&e));
        }
        Ok(e)
    }

    /// Policy gate. Auto and bypass only count for an agent whose signature otto checked; an earlier yes
    /// only for the thread it was given to.
    async fn authorize(&self, c: &Client, e: &EntryInfo, action: &str) -> Result<(), Fail> {
        if e.hidden() {
            return Err(Fail::new("denied", format!("\"{}\" is off-limits to agents", e.name)));
        }
        if c.verified && e.bypass.is_some() {
            c.granted(Grant::Bypass);
            return Ok(());
        }
        if c.verified && e.policy == Policy::Auto {
            c.granted(Grant::Auto);
            return Ok(());
        }
        // the call right after the user said yes to it on their phone (or at the Mac) while it was pending
        if self.take_once(&e.id, &c.thread, action) {
            c.granted(Grant::Asked);
            return Ok(());
        }
        if let Some(t) = self.approvals.lock().unwrap().get(&(e.id.clone(), c.thread.clone())) {
            if t.elapsed() < APPROVAL_TTL {
                c.granted(Grant::Remembered);
                return Ok(());
            }
        }
        self.ask_approval(c, e, action, false, None, None).await
    }

    /// Changing a stored secret: always asked, also for Auto and bypass entries and after an earlier yes.
    /// The user sees what it would become (a window at the Mac, the phone's page) before saying yes, and
    /// the yes covers that value only.
    async fn authorize_change(&self, c: &Client, e: &EntryInfo, action: &str, change: Change) -> Result<(), Fail> {
        if e.hidden() {
            return Err(Fail::new("denied", format!("\"{}\" is off-limits to agents", e.name)));
        }
        self.ask_approval(c, e, action, true, None, Some(change)).await
    }

    /// Cards and the Mac password: each use is its own decision (what gets paid where, which command
    /// runs as root), so an earlier yes doesn't cover it. A card never goes Auto; the Mac password does if
    /// the user set it to (they confirmed that with Touch ID). Bypass still means nobody is asked.
    async fn approve_each(&self, c: &Client, e: &EntryInfo, action: &str, prompt: String) -> Result<(), Fail> {
        if e.hidden() {
            return Err(Fail::new("denied", format!("\"{}\" is off-limits to agents", e.name)));
        }
        if c.verified && e.bypass.is_some() {
            c.granted(Grant::Bypass);
            return Ok(());
        }
        if c.verified && e.kind == "mac" && e.policy == Policy::Auto {
            c.granted(Grant::Auto);
            return Ok(());
        }
        self.ask_approval(c, e, action, true, Some(prompt), None).await
    }

    /// Touch ID in the app (for a change, a window showing it first). `prompt`, when given, is what the user
    /// reads instead of the app's own wording. When the agent says the user is away, nothing pops up on the
    /// Mac: the call comes back pending right away with a link for the user's phone (and the Mac shows a
    /// notification they can answer from).
    async fn ask_approval(&self, c: &Client, e: &EntryInfo, action: &str, force: bool, prompt: Option<String>, change: Option<Change>) -> Result<(), Fail> {
        if self.take_once(&e.id, &c.thread, &Change::grant(action, change.as_ref())) {
            c.granted(Grant::Asked);
            return Ok(());
        }
        if c.away {
            return Err(Fail::new("pending", self.ask_approve(c, e, action, force, prompt, change.as_ref()).await?));
        }
        let mut args = json!({
            "entry": e.name, "entry_id": e.id, "action": action, "agent": c.who(), "chain": c.chain, "force": force, "prompt": prompt,
            "verified": c.verified, "folder": c.folder,
        });
        if let Some(ch) = &change {
            args["change"] = ch.json();
            args["sites"] = json!(e.sites);
            args["entry_kind"] = json!(e.kind);
            args["pin"] = json!(self.pin_ready().await);
        }
        // a change opens a window to read first, so it gets longer than a bare Touch ID prompt
        let wait = if change.is_some() { self.waits().await.approve } else { 120 };
        let remote = self.pin_ready().await;
        let r = self.ask_window("approve", args, wait).await.map_err(|f| match f.code.as_str() {
            "timeout" => Fail::new("denied", away_hint(remote)).noted("nobody answered in time"),
            _ => f,
        })?;
        if r["approved"].as_bool() == Some(true) {
            c.granted(Grant::Asked);
            if !force {
                self.approvals.lock().unwrap().insert((e.id.clone(), c.thread.clone()), Instant::now());
            }
            Ok(())
        } else {
            Err(Fail::new("denied", format!("the user declined: {action} for \"{}\"", e.name)).noted(format!("you said no: {action}")))
        }
    }

    /// A code with at least a few seconds left, so the agent has time to type it.
    async fn fresh_code(&self, id: &str) -> Result<(String, u64), Fail> {
        let t: Totp = self.with_vault(|v| v.totp(v.resolve(id)?)).await?;
        let (code, left) = t.now();
        if left > 4 {
            return Ok((code, left));
        }
        tokio::time::sleep(Duration::from_millis(left * 1000 + 250)).await;
        Ok(t.now())
    }

    async fn field(&self, id: &str, field: &str) -> Result<String, Fail> {
        self.with_vault(|v| v.field(v.resolve(id)?, field).ok_or_else(|| Fail::new("no_value", format!("this entry has no {field}"))))
            .await
    }

    // ---- agent operations -------------------------------------------------------------

    async fn handle(&self, c: &Client, op: &str, args: &Value) -> OpResult {
        let mut c = c.for_request();
        // the agent says the user told it they're away from the Mac
        c.away = args["remote"] == true;
        let c = &c;
        if let Some(f) = self.cut_off(c) {
            if op != "status" {
                self.log(c, op, opt_str(args, "entry").or_else(|| opt_str(args, "name")), false, f.for_log());
            }
            return Err(f);
        }
        // a command's yes needs nothing from the vault
        if !matches!(op, "status" | "wait" | "log" | "approve_command") {
            self.unlock_for(c).await;
        }
        let r: Done = match op {
            "status" => return self.status(Some(c)).await,
            "wait" => return self.op_wait(c, args).await,
            "list" => return self.op_list(c, args).await,
            // an agent reads back its own lines only: what other agents did, and in which folders, isn't its business
            "log" => return Ok(json!(self.audit.recent_where(args["limit"].as_u64().unwrap_or(20).min(500) as usize, |l| l["agent"] == c.agent.as_str()))),
            "code" => self.op_code(c, args).await,
            "fill" => self.op_fill(c, args).await,
            "fill_code" => self.op_fill_code(c, args).await,
            "fill_on_site" => self.op_fill_on_site(c, args).await,
            "fill_card" => self.op_fill_card(c, args).await,
            "askpass" => return self.op_askpass(c).await,
            "type" => self.op_type(c, args).await,
            "request_save" => self.op_request_save(c, args).await,
            "enroll" => self.op_enroll(c, args).await,
            "save" => self.op_save(c, args).await,
            "env" => self.op_env(c, args).await,
            "request_bypass" => self.op_request_bypass(c, args).await,
            "end_bypass" => self.op_end_bypass(c, args).await,
            "approve_command" => self.op_approve_command(c, args).await,
            _ => return Err(Fail::bad(format!("unknown operation `{op}`"))),
        };
        let entry = opt_str(args, "entry").or_else(|| opt_str(args, "name"));
        // waiting for the user: the agent gets the request (and its link) to wait on
        if let Err(f) = &r {
            if f.code == "pending" {
                let p = self.pending(&f.message).ok_or_else(|| Fail::new("internal", "lost the request"))?;
                let detail = if p["kind"] == "save" { "waiting for you to save it from your phone (you're away)" } else { "waiting for your yes from your phone (you're away)" };
                self.log_ev(c, op, entry, false, detail.into(), true);
                return Ok(p);
            }
        }
        let bypassed = c.grant() == Some(Grant::Bypass);
        match &r {
            Ok((_, detail)) if bypassed => self.log(c, op, entry, true, format!("{detail} (bypass)")),
            Ok((_, detail)) => self.log(c, op, entry, true, detail.clone()),
            Err(e) => self.log(c, op, entry, false, e.for_log()),
        }
        if let (Ok((v, _)), true) = (&r, USES.contains(&op)) {
            if let Some(e) = self.with_vault(|vt| Ok(entry.and_then(|n| vt.find(n)))).await.ok().flatten() {
                let (how, what, place) = use_of(op, args, v, &e.kind);
                self.used(c, &e, how, what, place);
            }
        }
        r.map(|(v, _)| v)
    }

    /// `c`: an agent asking, which counts only the entries it could use (not "never" ones, not library ones)
    async fn status(&self, c: Option<&Client>) -> OpResult {
        let g = self.vault.lock().await;
        let count = |v: &Vault| match c {
            Some(c) => v.list().into_iter().map(|e| as_seen(c, e)).filter(|e| !e.hidden() && !e.library).count(),
            None => v.list().len(),
        };
        Ok(json!({
            "unlocked": g.is_some(),
            "entries": g.as_ref().map(count).unwrap_or(0),
            "browsers": self.browsers(),
            "version": env!("CARGO_PKG_VERSION"),
        }))
    }

    async fn op_list(&self, c: &Client, args: &Value) -> OpResult {
        let q = opt_str(args, "query").map(|q| q.to_lowercase());
        let list = self.with_vault(|v| Ok(v.list())).await?;
        let out: Vec<Value> = list
            .into_iter()
            .map(|e| as_seen(c, e))
            .filter(|e| !e.hidden() && !e.library)
            .filter(|e| match &q {
                None => true,
                Some(q) => {
                    e.name.to_lowercase().contains(q)
                        || e.sites.iter().any(|s| s.contains(q.as_str()))
                        || e.username.as_deref().unwrap_or("").to_lowercase().contains(q)
                }
            })
            .map(|e| public(&e))
            .collect();
        Ok(json!(out))
    }

    async fn op_code(&self, c: &Client, args: &Value) -> Done {
        let e = self.agent_entry(c, arg_str(args, "entry")?).await?;
        if e.totp.is_none() {
            return Err(no_totp(&e));
        }
        self.authorize(c, &e, "get a 2FA code").await?;
        let (code, left) = self.fresh_code(&e.id).await?;
        Ok((json!({ "entry": e.name, "code": code, "expires_in": left }), format!("2FA code, valid {left}s")))
    }

    async fn op_fill(&self, c: &Client, args: &Value) -> Done {
        let e = self.agent_entry(c, arg_str(args, "entry")?).await?;
        if e.kind != "login" {
            return Err(wrong_kind(&e));
        }
        if e.sites.is_empty() && e.bypass.is_some() {
            return Err(Fail::new("no_site", format!("\"{}\" has no website set. bypass is on for it, so use fill_on_site with the login page's domain", e.name)).noted("it has no website set"));
        }
        if e.sites.is_empty() {
            return Err(Fail::new("no_site", format!("\"{}\" has no website set, so otto won't fill it anywhere. the user can add the site in otto", e.name)));
        }
        let wanted = login_fields(args)?;
        self.authorize(c, &e, "fill its login in the browser").await?;
        self.fill_login(&e, &e.sites, &wanted, args).await.map_err(moved_hint)
    }

    async fn op_fill_code(&self, c: &Client, args: &Value) -> Done {
        let e = self.agent_entry(c, arg_str(args, "entry")?).await?;
        if e.totp.is_none() {
            return Err(no_totp(&e));
        }
        if e.sites.is_empty() {
            let hint = if e.bypass.is_some() { ". bypass is on for it, so use fill_on_site with the page's domain" } else { "" };
            return Err(Fail::new("no_site", format!("\"{}\" has no website set, so otto won't fill it anywhere{hint}", e.name)));
        }
        self.authorize(c, &e, "fill a 2FA code in the browser").await?;
        self.fill_code(&e, &e.sites, args).await.map_err(moved_hint)
    }

    async fn fill_login(&self, e: &EntryInfo, sites: &[String], wanted: &[String], args: &Value) -> Done {
        let mut values = BTreeMap::new();
        for f in wanted {
            if let Ok(v) = self.field(&e.id, f).await {
                values.insert(f.clone(), v);
            }
        }
        if values.is_empty() {
            return Err(Fail::new("no_value", format!("\"{}\" has no {} stored", e.name, wanted.join(" or "))));
        }
        // submitting right away leaves the password in the page for the shortest time
        let submit = args["submit"].as_bool().unwrap_or(true);
        let http = e.bypass.is_some();
        let r = self.browser("fill", json!({ "sites": sites, "values": values, "submit": submit, "http": http }), Duration::from_secs(20)).await?;
        let host = check_host(&r, sites)?;
        let filled: Vec<String> = r["filled"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
        Ok((
            json!({ "filled": filled, "url": r["url"], "submitted": r["submitted"], "held": r["held"] }),
            format!("filled {} on {host}{}{}", filled.join(" + "), over_http(&r), held(&r)),
        ))
    }

    async fn fill_code(&self, e: &EntryInfo, sites: &[String], args: &Value) -> Done {
        let (code, _) = self.fresh_code(&e.id).await?;
        let submit = args["submit"].as_bool().unwrap_or(true);
        let http = e.bypass.is_some();
        let r = self.browser("fill_code", json!({ "sites": sites, "code": code, "submit": submit, "http": http }), Duration::from_secs(20)).await?;
        let host = check_host(&r, sites)?;
        Ok((json!({ "filled": ["code"], "url": r["url"], "submitted": r["submitted"], "held": r["held"] }), format!("filled 2FA code on {host}{}{}", over_http(&r), held(&r))))
    }

    /// Fill an entry on a site that isn't one of its own, e.g. after the service moved to a new
    /// domain. The first time for a domain the user has to allow it in writing (they type the domain),
    /// and can add it to the entry for good. With bypass on, nobody is asked: the user said yes
    /// to that ahead of time.
    async fn op_fill_on_site(&self, c: &Client, args: &Value) -> Done {
        let e = self.agent_entry(c, arg_str(args, "entry")?).await?;
        if e.kind != "login" {
            return Err(wrong_kind(&e));
        }
        let what = opt_str(args, "what").unwrap_or("login");
        if what != "login" && what != "2fa_code" {
            return Err(Fail::bad(format!("`what` is login or 2fa_code, not {what}")));
        }
        if what == "2fa_code" && e.totp.is_none() {
            return Err(no_totp(&e));
        }
        let wanted = if what == "login" { login_fields(args)? } else { vec![] };
        let host = opt_str(args, "site")
            .and_then(normalize_site)
            .ok_or_else(|| Fail::bad("`site` is the domain of the login page you have open, e.g. github.com"))?;
        let domain = base_domain(&host).ok_or_else(|| Fail::bad(format!("{host} isn't one site (it's shared by many), so otto won't use a login there")))?;
        let action = if what == "login" { "fill its login in the browser" } else { "fill a 2FA code in the browser" };
        let granted = self.site_grants.lock().unwrap().get(&(e.id.clone(), domain.clone())).is_some_and(|t| t.elapsed() < SITE_GRANT_TTL);
        let (sites, how) = if site_matches(&host, &e.sites) || granted {
            self.authorize(c, &e, action).await?;
            (if granted { vec![domain.clone()] } else { e.sites.clone() }, String::new())
        } else if e.bypass.is_some() {
            let tab = self.browser("has_tab", json!({ "sites": [domain], "http": true }), Duration::from_secs(5)).await?;
            if tab["found"] != true {
                return Err(Fail::new("no_tab", format!("no open tab for {domain}. open its login page in the browser first")));
            }
            c.granted(Grant::Bypass);
            let why = opt_str(args, "reason").map(|r| format!(": \"{}\"", r.trim())).unwrap_or_default();
            (vec![domain.clone()], format!(", new site, nobody asked{why}"))
        } else {
            if c.away {
                return Err(Fail::new(
                    "at_the_mac",
                    format!("{domain} is new for \"{}\": allowing a new domain needs the user at the Mac (they type it there). ask them when they're back", e.name),
                ));
            }
            let reason = opt_str(args, "reason")
                .map(str::trim)
                .filter(|r| !r.is_empty())
                .ok_or_else(|| Fail::bad(format!("{domain} is new for \"{}\". say why in `reason`: the user reads it before allowing it", e.name)))?;
            // only bother the user when that page is really open
            let tab = self.browser("has_tab", json!({ "sites": [domain] }), Duration::from_secs(5)).await?;
            if tab["found"] != true {
                return Err(Fail::new("no_tab", format!("no open tab for {domain}. open its login page in the browser first")));
            }
            let r = self
                .ask_window(
                    "approve_site",
                    json!({
                        "entry": e.name, "entry_id": e.id, "site": host, "domain": domain, "known": e.sites,
                        "agent": c.who(), "reason": reason, "what": what,
                    }),
                    self.waits().await.approve,
                )
                .await
                .map_err(|f| if f.code == "timeout" { Fail::new("denied", "the user didn't answer in time").noted("nobody answered in time") } else { f })?;
            if r["approved"] != true {
                return Err(Fail::new("denied", format!("the user didn't allow {domain} for \"{}\"", e.name)).noted(format!("you didn't allow {domain}")));
            }
            // typing the domain is a stronger yes than Touch ID: it covers this entry for a while too
            c.granted(Grant::Asked);
            self.site_grants.lock().unwrap().insert((e.id.clone(), domain.clone()), Instant::now());
            self.approvals.lock().unwrap().insert((e.id.clone(), c.thread.clone()), Instant::now());
            let remember = r["remember"] == true;
            if remember {
                let mut sites = e.sites.clone();
                sites.push(domain.clone());
                self.with_vault_mut(|v| v.apply(&EntryPatch { id: Some(e.id.clone()), sites: Some(sites), ..Default::default() }).map(|_| ())).await?;
            }
            (vec![domain.clone()], if remember { ", you allowed it and added it to the entry" } else { ", you allowed it once" }.to_string())
        };
        let (v, detail) = if what == "login" { self.fill_login(&e, &sites, &wanted, args).await? } else { self.fill_code(&e, &sites, args).await? };
        Ok((v, format!("{detail}{how}")))
    }

    async fn op_type(&self, c: &Client, args: &Value) -> Done {
        let e = self.agent_entry(c, arg_str(args, "entry")?).await?;
        let field = arg_str(args, "field")?.to_lowercase();
        if e.kind == "mac" {
            return Err(wrong_kind(&e));
        }
        // with bypass on it goes to whichever app is in front
        let any = e.bypass.is_some();
        if e.apps.is_empty() && !any {
            return Err(Fail::new("no_app", format!("\"{}\" isn't tied to any app, so otto won't type it. the user can add the app in otto", e.name)));
        }
        self.authorize(c, &e, &format!("type its {field} into an app")).await?;
        let text = if field == "code" || field == "otp" || field == "2fa" { self.fresh_code(&e.id).await?.0 } else { self.field(&e.id, &field).await? };
        let r = self.ask_app("type_text", json!({ "text": text, "apps": e.apps, "any": any, "entry": e.name, "field": field }), Duration::from_secs(20)).await?;
        let app = r["app"].as_str().unwrap_or("?").to_string();
        Ok((json!({ "typed": field, "app": app }), format!("typed {field} into {app}")))
    }

    async fn op_request_save(&self, c: &Client, args: &Value) -> Done {
        let name = arg_str(args, "name")?.trim().to_string();
        let existing = self.with_vault(|v| Ok(v.find_open(&name).map(|e| as_seen(c, e)))).await?;
        if existing.as_ref().is_some_and(|e| e.hidden()) {
            return Err(Fail::new("denied", format!("\"{name}\" is off-limits to agents")));
        }
        let req = json!({
            "name": name,
            "site": opt_str(args, "site").and_then(normalize_site),
            "app": opt_str(args, "app"),
            "username": opt_str(args, "username"),
            "needs": str_list(args, "needs"),
            "note": opt_str(args, "note"),
            "agent": c.who(),
            "existing": existing,
        });
        // the user is away: a link for their phone right away, and only a notification on the Mac
        if c.away {
            let base = self.remote_base().await?;
            let life = Duration::from_secs(self.waits().await.phone);
            return Err(Fail::new("pending", self.ask_save(c, &base, &req, existing, life)));
        }
        let r = self
            .ask_window("save_dialog", req, self.waits().await.save)
            .await
            .map_err(|f| if f.code == "timeout" { Fail::new("cancelled", "the save window was left open too long") } else { f })?;
        if r["saved"].as_bool() != Some(true) {
            return Err(Fail::new("cancelled", "the user closed the save window without saving").noted("you closed the save window without saving"));
        }
        let patch: EntryPatch = serde_json::from_value(r["patch"].clone()).map_err(|e| Fail::bad(format!("bad entry from the app: {e}")))?;
        let info = self.with_vault_mut(|v| {
            let id = v.apply(&patch)?;
            v.info(id).ok_or_else(|| Fail::new("not_found", "entry vanished"))
        })
        .await?;
        Ok((json!({ "saved": true, "entry": public(&info) }), "the user saved it".into()))
    }

    async fn op_enroll(&self, c: &Client, args: &Value) -> Done {
        let name = arg_str(args, "entry")?.trim().to_string();
        let from = opt_str(args, "from").unwrap_or("browser");
        let existing = self.with_vault(|v| Ok(v.find_open(&name).map(|e| as_seen(c, e)))).await?;
        if let Some(e) = &existing {
            if e.hidden() {
                return Err(Fail::new("denied", format!("\"{}\" is off-limits to agents", e.name)));
            }
        }
        let mut sites: Vec<String> = existing.as_ref().map(|e| e.sites.clone()).unwrap_or_default();
        if sites.is_empty() {
            sites.extend(opt_str(args, "site").and_then(normalize_site));
        }
        let (payloads, page) = match from {
            "screen" => {
                let r = self.ask_app("scan_screen", json!({}), Duration::from_secs(30)).await?;
                (r["payloads"].clone(), None)
            }
            "browser" => {
                let r = self.browser("capture_qr", json!({ "sites": sites }), Duration::from_secs(30)).await?;
                let d = self.ask_app("decode_qr", json!({ "png": r["png"] }), Duration::from_secs(20)).await?;
                (d["payloads"].clone(), r["url"].as_str().map(String::from))
            }
            other => return Err(Fail::bad(format!("`from` is browser or screen, not {other}"))),
        };
        let uri = payloads
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|p| p.as_str())
            .find(|p| p.len() > 14 && p[..14].eq_ignore_ascii_case("otpauth://totp"))
            .map(String::from)
            .ok_or_else(|| {
                Fail::new("no_qr", format!("no 2FA setup QR code found on the {}. make sure it's visible, then try again", if from == "screen" { "screen" } else { "page" })).noted("no 2FA setup QR code found")
            })?;
        let t = Totp::parse(&uri).map_err(|e| Fail::new("bad_totp", e))?;
        if let Some(e) = &existing {
            if e.totp.is_some() {
                let from = [t.issuer.as_deref(), t.account.as_deref()].into_iter().flatten().filter(|s| !s.is_empty()).collect::<Vec<_>>().join(", ");
                let label = if from.is_empty() { "from the QR code on screen".to_string() } else { format!("from the QR code for {from}") };
                self.authorize_change(c, e, "replace its 2FA secret", Change::new("2FA secret", None, Some(label), &uri)).await?;
            }
        }
        if sites.is_empty() {
            sites.extend(page.as_deref().and_then(normalize_site));
        }
        let patch = match &existing {
            Some(e) => EntryPatch { id: Some(e.id.clone()), otp: Some(uri), ..Default::default() },
            None => EntryPatch { name: Some(name.clone()), otp: Some(uri), sites: Some(sites.clone()), policy: Some(Policy::Auto), ..Default::default() },
        };
        let info = self.with_vault_mut(|v| {
            let id = v.apply(&patch)?;
            v.info(id).ok_or_else(|| Fail::new("not_found", "entry vanished"))
        })
        .await?;
        let (code, left) = self.fresh_code(&info.id).await?;
        Ok((
            json!({ "entry": info.name, "created": existing.is_none(), "issuer": t.issuer, "account": t.account, "code": code, "expires_in": left }),
            format!("stored a 2FA secret{}", if existing.is_none() { " in a new entry" } else { "" }),
        ))
    }

    async fn op_save(&self, c: &Client, args: &Value) -> Done {
        let name = arg_str(args, "entry")?.trim().to_string();
        let field = arg_str(args, "field")?.trim().to_string();
        let value = args["value"].as_str().filter(|v| !v.is_empty()).ok_or_else(|| Fail::bad("nothing to save (empty value)"))?.to_string();
        let key = field.to_lowercase();
        if key.starts_with("otto.") || key == "title" || key == "name" {
            return Err(Fail::bad(format!("`{field}` can't be set this way")));
        }
        // an agent can keep something away from agents, itself included, but never open it up
        let policy = match opt_str(args, "policy") {
            None => None,
            Some("ask") => Some(Policy::Ask),
            Some("never") => Some(Policy::Never),
            Some(p) => return Err(Fail::bad(format!("`policy` is ask or never, not {p}: only the user can make an entry easier to use"))),
        };
        let tighter = |e: &EntryInfo| policy.filter(|p| *p == Policy::Never || e.policy == Policy::Auto);
        let existing = self.with_vault(|v| Ok(v.find_open(&name).map(|e| as_seen(c, e)))).await?;
        if let Some(e) = &existing {
            let is_otp = matches!(key.as_str(), "otp" | "totp" | "2fa");
            let current = self.field(&e.id, if is_otp { "otp" } else { &key }).await.ok();
            let incoming = if is_otp { Totp::parse(&value).map(|t| t.to_uri()).ok() } else { Some(value.clone()) };
            if !e.hidden() && current.is_some() && current == incoming {
                if let Some(p) = tighter(e) {
                    self.with_vault_mut(|v| v.apply(&EntryPatch { id: Some(e.id.clone()), policy: Some(p), ..Default::default() }).map(|_| ())).await?;
                }
                return Ok((json!({ "saved": true, "entry": e.name, "field": field, "created": false, "unchanged": true }), format!("its {field} was already saved")));
            }
        }
        let value_for_digest = value.clone();
        let mut patch = EntryPatch::default();
        match key.as_str() {
            "username" => patch.username = Some(value),
            "password" => patch.password = Some(value),
            "otp" | "totp" | "2fa" => patch.otp = Some(value),
            "notes" => patch.notes = Some(value),
            _ => patch.fields = Some(BTreeMap::from([(field.clone(), value)])),
        }
        match &existing {
            Some(e) => {
                if e.hidden() {
                    return Err(Fail::new("denied", format!("\"{}\" is off-limits to agents", e.name)));
                }
                let has = self.field(&e.id, &key).await.is_ok() || (matches!(key.as_str(), "otp" | "totp" | "2fa") && e.totp.is_some());
                if has {
                    let is_otp = matches!(key.as_str(), "otp" | "totp" | "2fa");
                    let change = if is_otp {
                        Change::new("2FA secret", None, Some(format!("from {}, not shown: it's only the key codes are made from", c.who())), &value_for_digest)
                    } else {
                        Change::new(&field, Some(value_for_digest.clone()), None, &value_for_digest)
                    };
                    self.authorize_change(c, e, &format!("change its {field}"), change).await?;
                }
                patch.id = Some(e.id.clone());
                patch.policy = tighter(e);
            }
            None => {
                patch.name = Some(name.clone());
                patch.sites = Some(opt_str(args, "site").into_iter().map(String::from).collect());
                patch.apps = Some(opt_str(args, "app").into_iter().map(String::from).collect());
                patch.policy = Some(policy.unwrap_or(Policy::Auto));
                // cards and the Mac password are the user's to enter
                patch.kind = match opt_str(args, "kind") {
                    None | Some("login") => None,
                    Some(k @ ("key" | "note")) => Some(k.into()),
                    Some("value") => return Err(Fail::bad("values are the user's to keep: leave a blank in run_command and they can tick remember")),
                    Some(k) => return Err(Fail::bad(format!("agents can save logins, keys (kind \"key\") and notes, not a {k}"))),
                };
            }
        }
        self.with_vault_mut(|v| v.apply(&patch).map(|_| ())).await?;
        Ok((json!({ "saved": true, "entry": name, "field": field, "created": existing.is_none() }), format!("saved its {field}")))
    }

    async fn op_env(&self, c: &Client, args: &Value) -> Done {
        let e = self.agent_entry(c, arg_str(args, "entry")?).await?;
        if !e.scripts {
            return Err(Fail::new(
                "scripts_off",
                format!("\"{}\" isn't allowed in scripts. the user can switch on \"scripts\" for it in otto", e.name),
            ));
        }
        if e.kind == "mac" {
            return Err(wrong_kind(&e));
        }
        // "" is the entry's main value: a login's password, an API key's key, a card's number
        let mut wanted = str_list(args, "fields");
        if wanted.is_empty() {
            wanted.push(String::new());
        }
        let name = |f: &str| if f.is_empty() { main_field(&e.kind).to_string() } else { f.to_string() };
        let names: Vec<String> = wanted.iter().map(|f| name(f)).collect();
        let command = opt_str(args, "command").unwrap_or("a command");
        self.authorize(c, &e, &format!("hand its {} to `{command}`", names.join(", "))).await?;
        let mut values = BTreeMap::new();
        for f in &wanted {
            let v = if f == "code" { self.fresh_code(&e.id).await?.0 } else { self.field(&e.id, &name(f)).await? };
            values.insert(f.clone(), v);
        }
        Ok((json!({ "values": values }), format!("gave {} to `{command}`", names.join(", "))))
    }

    /// Fill a card into the checkout form of the open tab on `site`: the page itself and the payment
    /// provider frames in it (Stripe, Braintree...). A card isn't tied to one site, so each fill asks the
    /// user, who sees which card goes where (unless the card has bypass).
    /// An agent wants the user's yes for a command: one it shouldn't run on its own say-so (or that its own
    /// rules leave to the user). Every command asks: no Auto, no bypass, no earlier yes. The yes covers this
    /// exact command in this folder, once, and the caller then runs it (`otto approve` execs it, the MCP tool
    /// runs it and returns what it printed). It grants nothing else: no secret, no root.
    async fn op_approve_command(&self, c: &Client, args: &Value) -> Done {
        let argv: Vec<String> = args["argv"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
        if argv.first().is_none_or(|a| a.trim().is_empty()) {
            return Err(Fail::bad("no command"));
        }
        let blanks = blanks::parse(args)?;
        // with blanks, the service runs it (once they're filled in), so it needs to know where
        if !blanks.is_empty() {
            arg_str(args, "cwd")?;
        }
        let shown = if blanks.is_empty() { command_shown(&argv) } else { blanks::template(&argv, &blanks) };
        let script = if blanks.is_empty() { None } else { Some(blanks::script(&shown, &blanks)?) };
        if shown.len() > 8000 {
            return Err(Fail::bad("that command is too long to show the user; put it in a script and ask about running the script").noted("the command was too long to show you"));
        }
        let cwd = opt_str(args, "cwd").map(|p| peer::tilde(std::path::Path::new(p))).or_else(|| c.folder.clone());
        let why = opt_str(args, "why").map(|w| shorten(w.trim(), 400)).filter(|w| !w.is_empty());
        // the blanks are part of what the user said yes to
        let mut keyed = argv.clone();
        keyed.extend(blanks.iter().map(|b| format!("{{{{{}}}}} {}", b.name, b.secret)));
        let grant = format!("run {}", command_digest(&keyed, cwd.as_deref()));
        c.about(&shown, why.as_deref());
        let detail = format!("`{}`{}", shorten(&shown, 200), cwd.as_deref().map(|f| format!(" in {f}")).unwrap_or_default());
        // the call right after the user said yes from their phone
        if self.take_once(asks::COMMAND_ENTRY, &c.thread, &grant) {
            c.granted(Grant::Asked);
            let Some(script) = script else { return Ok((json!({ "approved": true }), format!("you allowed {detail}"))) };
            let values = self.take_filled(&c.thread, &grant).ok_or_else(|| Fail::new("expired", "what the user filled in is gone. ask again").noted("what you filled in was gone"))?;
            return self.run_filled(args, script, values, &detail).await;
        }
        let remote = self.pin_ready().await;
        let mac = json!({ "agent": c.who(), "chain": c.chain, "verified": c.verified, "folder": cwd, "command": shown, "why": why, "pin": remote, "blanks": self.blanks_json(&shown, &blanks).await });
        if c.away {
            return Err(Fail::new("pending", self.ask_command(c, &shown, why.as_deref(), &grant, mac).await?));
        }
        let waits = self.waits().await;
        let wait = if blanks.is_empty() { waits.approve } else { waits.blanks };
        let r = self.ask_window("approve_command", mac, wait).await.map_err(|f| match f.code.as_str() {
            "timeout" => Fail::new("denied", away_hint(remote)).noted("nobody answered in time"),
            _ => f,
        })?;
        if r["approved"] != true {
            return Err(Fail::new(
                "denied",
                format!("the user didn't allow {detail}. don't run it some other way, and don't ask again unless they tell you to"),
            )
            .noted(format!("you didn't allow {detail}")));
        }
        c.granted(Grant::Asked);
        let Some(script) = script else { return Ok((json!({ "approved": true }), format!("you allowed {detail}"))) };
        let values = self.resolve_filled(&shown, &blanks, &r).await.map_err(Fail::bad)?;
        self.apply_remember(&shown, &blanks, &values, &r).await;
        self.run_filled(args, script, values, &detail).await
    }

    async fn op_fill_card(&self, c: &Client, args: &Value) -> Done {
        let e = self.agent_entry(c, arg_str(args, "entry")?).await?;
        if e.kind != "card" {
            return Err(Fail::new("wrong_kind", format!("\"{}\" isn't a card", e.name)));
        }
        let host = opt_str(args, "site")
            .and_then(normalize_site)
            .ok_or_else(|| Fail::bad("`site` is the domain of the checkout page you have open, e.g. shop.example.com"))?;
        if base_domain(&host).is_none() {
            return Err(Fail::bad(format!("{host} isn't one site (it's shared by many), so otto won't fill a card there")));
        }
        // the user can keep a card to some sites
        if !e.sites.is_empty() && e.bypass.is_none() && !site_matches(&host, &e.sites) {
            return Err(Fail::new("wrong_site", format!("the user keeps \"{}\" to {}", e.name, e.sites.join(", "))).noted(format!("you keep it to {}", e.sites.join(", "))));
        }
        let sites = vec![host.clone()];
        // only bother the user when that page has a card form: ask the browser with stand-ins for the values
        let has = |f: &str| e.fields.iter().any(|x| x == f);
        let mut standins: BTreeMap<&str, &str> = ["number", "cardholder", "cvc", "postal_code"].into_iter().filter(|f| has(f)).map(|f| (f, "0")).collect();
        if has("expiry") {
            standins.extend([("exp_month", "01"), ("exp_year", "2030")]);
        }
        let probe = self
            .browser("probe_card", json!({ "sites": sites, "values": standins, "providers": PAYMENT_HOSTS }), Duration::from_secs(10))
            .await
            .map_err(|f| if f.code == "no_tab" { Fail::new("no_tab", format!("no open tab for {host}. open the checkout page in the browser first")).noted(format!("no tab open on {host}")) } else { f })?;
        if probe["fields"].as_array().is_none_or(|a| a.is_empty()) {
            return Err(Fail::new("no_field", format!("no card form on the {host} tab (otto fills the page itself and payment providers' frames in it)")));
        }
        let label = e.card.as_ref().map(|k| format!("{} •••• {}", k.brand, k.last4)).unwrap_or_else(|| e.name.clone());
        self.approve_each(c, &e, &format!("fill {label} on {host}"), format!("let {} fill your {label} on {host}", c.who())).await?;
        let mut values = BTreeMap::new();
        for f in ["number", "cardholder", "cvc", "postal_code"] {
            if let Ok(v) = self.field(&e.id, f).await {
                values.insert(f.to_string(), v);
            }
        }
        if !values.contains_key("number") {
            return Err(Fail::new("no_value", format!("\"{}\" has no card number saved", e.name)));
        }
        if let Some((m, y)) = self.field(&e.id, "expiry").await.ok().as_deref().and_then(parse_expiry) {
            values.insert("exp_month".into(), format!("{m:02}"));
            values.insert("exp_year".into(), y.to_string());
        }
        let r = self.browser("fill_card", json!({ "sites": sites, "values": values, "providers": PAYMENT_HOSTS }), Duration::from_secs(20)).await?;
        // the extension already checked each frame; check again what it reports
        let host_of = |u: &Value| u.as_str().and_then(|u| url::Url::parse(u).ok()).and_then(|u| u.host_str().map(String::from)).unwrap_or_default();
        let tab_host = host_of(&r["url"]);
        if !site_matches(&tab_host, &sites) {
            return Err(Fail::new("wrong_site", format!("the browser reported {tab_host}, not {host}")));
        }
        let providers: Vec<String> = PAYMENT_HOSTS.iter().map(|h| h.to_string()).collect();
        for f in r["frames"].as_array().into_iter().flatten() {
            let h = host_of(f);
            if !site_matches(&h, &sites) && !site_matches(&h, &providers) {
                return Err(Fail::new("wrong_site", format!("the browser reported a frame from {h}, which is neither {host} nor a payment provider")));
            }
        }
        let filled: Vec<String> = r["filled"].as_array().map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
        Ok((json!({ "filled": filled, "url": r["url"] }), format!("filled {label} ({}) on {host}", filled.join(" + "))))
    }

    /// The askpass helper of `otto sudo`, asking for the Mac password on sudo's behalf. It only gets it
    /// if it really is this otto started by Apple's sudo, and after the user saw the command sudo will run
    /// as root. Logged here (not in `handle`): the entry isn't named by the caller.
    async fn op_askpass(&self, c: &Client) -> OpResult {
        let (exe, pid) = (self.self_exe.clone(), c.pid);
        let checked = tokio::task::spawn_blocking(move || peer::askpass_sudo(pid, &exe)).await.unwrap_or_else(|e| Err(e.to_string()));
        let (sudo, command) = match checked {
            Ok(v) => v,
            Err(why) => {
                self.log(c, "sudo", None, false, format!("refused: {why}"));
                return Err(Fail::new("denied", why));
            }
        };
        let shown = sudo_shown(&command);
        let caller = peer::behind_sudo(sudo).unwrap_or_else(|| c.clone());
        let c = &caller;
        c.about(&shown, None);
        if let Some(f) = self.cut_off(c) {
            self.log(c, "sudo", None, false, f.for_log());
            return Err(f);
        }
        let e = match self.with_vault(|v| Ok(v.list().into_iter().find(|e| e.kind == "mac").map(|e| as_seen(c, e)))).await? {
            Some(e) => e,
            None => return self.first_mac_password(c, sudo, &shown).await,
        };
        let r = async {
            self.sudo_asks.lock().unwrap().retain(|_, t| t.elapsed() < Duration::from_secs(5 * 60));
            if self.sudo_asks.lock().unwrap().contains_key(&sudo) {
                return Err(Fail::new("wrong_password", format!("sudo didn't take the Mac password saved in \"{}\". the user can update it in otto", e.name)));
            }
            self.approve_each(c, &e, &format!("run `{shown}` as root"), format!("let {} run “{shown}” as root", c.who())).await?;
            let pw = self.field(&e.id, "password").await?;
            self.sudo_asks.lock().unwrap().insert(sudo, Instant::now());
            Ok(pw)
        }
        .await;
        let bypass = match c.grant() {
            Some(Grant::Bypass) => " (bypass)",
            Some(Grant::Auto) => " (auto)",
            _ => "",
        };
        match r {
            Ok(pw) => {
                self.log(c, "sudo", Some(&e.name), true, format!("ran `{shown}` as root{bypass}"));
                self.used(c, &e, "ran", vec![], Some(shown.clone()));
                Ok(json!({ "password": pw }))
            }
            Err(f) => {
                self.log(c, "sudo", Some(&e.name), false, f.for_log());
                Err(f)
            }
        }
    }

    /// No Mac password in otto yet: the app asks for it right away, showing the command. The app checks
    /// it really is this Mac's password, and typing it in that window is the yes for this one run.
    async fn first_mac_password(&self, c: &Client, sudo: i32, shown: &str) -> OpResult {
        let r = self
            .ask_window("mac_password", json!({ "agent": c.who(), "command": shown }), self.waits().await.mac_password)
            .await
            .map_err(|f| if f.code == "timeout" { Fail::new("not_found", "there's no Mac password in otto, and nobody entered one at the Mac") } else { f });
        let pw = match r {
            Ok(r) if r["saved"] == true => arg_str(&r, "password").map(String::from),
            Ok(_) => Err(Fail::new("not_found", "there's no Mac password in otto: the window was closed without saving it")),
            Err(f) => Err(f),
        };
        let pw = match pw {
            Ok(pw) => pw,
            Err(f) => {
                self.log(c, "sudo", None, false, f.for_log());
                return Err(f);
            }
        };
        let patch = EntryPatch {
            name: Some("Mac password".into()),
            kind: Some("mac".into()),
            password: Some(pw.clone()),
            policy: Some(Policy::Ask),
            ..Default::default()
        };
        let name = self
            .with_vault_mut(|v| {
                let id = v.apply(&patch)?;
                Ok(v.info(id).map(|e| e.name).unwrap_or_default())
            })
            .await?;
        self.sudo_asks.lock().unwrap().insert(sudo, Instant::now());
        self.log(c, "sudo", Some(&name), true, format!("you saved the Mac password and ran `{shown}` as root"));
        Ok(json!({ "password": pw }))
    }

    /// The user asked in the chat for bypass on an entry. The agent can only ask: the app shows the
    /// risks, the user ticks the box and confirms with Touch ID at the Mac, and only then otto seals
    /// the consent. A "yes" typed in the chat passes through the agent, so it never counts by itself.
    async fn op_request_bypass(&self, c: &Client, args: &Value) -> Done {
        if !c.verified {
            return Err(Fail::new(
                "unverified",
                format!("bypass only covers agents otto can verify by their signature (Claude, Codex, opencode...). {} isn't one, so bypass wouldn't let it skip anything", c.who()),
            ));
        }
        let e = self.agent_entry(c, arg_str(args, "entry")?).await?;
        if let Some(b) = &e.bypass {
            return Ok((json!({ "bypass": true, "already": true, "until": b.until }), "bypass was already on".into()));
        }
        if c.away {
            return Err(Fail::new("at_the_mac", "turning on bypass needs the user at the Mac, with Touch ID. ask them when they're back").noted("turning on bypass needs you at the Mac"));
        }
        let reason = opt_str(args, "reason")
            .map(str::trim)
            .ok_or_else(|| Fail::bad("say why in `reason` (what the user asked for in the chat): they read it before deciding"))?;
        let r = self
            .ask_window(
                "consent_bypass",
                json!({
                    "entry": e.name, "entry_id": e.id, "sites": e.sites, "apps": e.apps,
                    "agent": c.who(), "reason": reason, "hours": args["hours"].as_u64(),
                }),
                self.waits().await.approve,
            )
            .await
            .map_err(|f| if f.code == "timeout" { Fail::new("denied", "the user didn't answer in time. turning on bypass needs them at the Mac, with Touch ID").noted("nobody answered in time") } else { f })?;
        if r["granted"] != true {
            return Err(Fail::new("denied", format!("the user didn't turn on bypass for \"{}\"", e.name)).noted("you didn't turn on bypass"));
        }
        let consent = self.grant_bypass(&e.id, &r, Some(&c.agent), Some(reason)).await?;
        let until = consent.until.as_deref().map(|u| format!(" until {}", local_time(u))).unwrap_or_default();
        Ok((json!({ "bypass": true, "until": consent.until }), format!("the user turned on bypass{until}")))
    }

    /// Bypass off needs nobody's yes: it only takes access away. The user can ask for it in the chat.
    async fn op_end_bypass(&self, c: &Client, args: &Value) -> Done {
        let id = self.agent_entry(c, arg_str(args, "entry")?).await?.id;
        // the entry as it is (an unverified caller sees it without bypass, but may still end it)
        let e = self.with_vault(|v| v.info(v.resolve(&id)?).ok_or_else(|| Fail::new("not_found", "entry vanished"))).await?;
        if e.bypass.is_none() {
            return Ok((json!({ "bypass": false, "was_on": false }), "bypass was already off".into()));
        }
        self.with_vault_mut(|v| v.end_bypass(v.resolve(&e.id)?)).await?;
        let back = if e.policy == Policy::Never { "never: agents can't see it now".to_string() } else { e.policy.as_str().to_string() };
        Ok((json!({ "bypass": false, "was_on": true, "policy": e.policy }), format!("turned bypass off, back to {back}")))
    }

    /// Seal and store the user's consent (from the app: they ticked the box and confirmed).
    async fn grant_bypass(&self, id: &str, r: &Value, asked_by: Option<&str>, reason: Option<&str>) -> Result<Consent, Fail> {
        let statement = arg_str(r, "statement")?.trim().to_string();
        let auth = match arg_str(r, "auth")? {
            a @ ("touch_id" | "password") => a.to_string(),
            other => return Err(Fail::bad(format!("unknown confirmation `{other}`"))),
        };
        let until = match opt_str(r, "until") {
            Some(u) => {
                let t = chrono::DateTime::parse_from_rfc3339(u).map_err(|_| Fail::bad(format!("`until` isn't a date: {u}")))?;
                if t <= chrono::Utc::now() {
                    return Err(Fail::bad("`until` is in the past"));
                }
                Some(t.with_timezone(&chrono::Utc).to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
            }
            None => None,
        };
        let consent = self
            .with_vault_mut(|v| {
                let id = v.resolve(id)?;
                let e = v.info(id).ok_or_else(|| Fail::new("not_found", "entry vanished"))?;
                if e.library {
                    return Err(Fail::bad("an imported 2FA code isn't a login; attach it to one first"));
                }
                v.grant_bypass(
                    id,
                    Consent {
                        entry: e.id.clone(),
                        name: e.name.clone(),
                        at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                        until,
                        auth,
                        statement,
                        asked_by: asked_by.map(String::from),
                        reason: reason.map(String::from),
                        seal: String::new(),
                    },
                )
            })
            .await?;
        self.log_consent(&consent);
        Ok(consent)
    }

    // ---- app operations (private channel) ---------------------------------------------

    async fn handle_app(&self, op: &str, args: &Value) -> OpResult {
        match op {
            "unlock" => {
                let password = arg_str(args, "password")?.to_string();
                let path = paths::vault_path();
                let create = args["create"].as_bool().unwrap_or(false);
                let (vault, created) = tokio::task::block_in_place(|| -> Result<(Vault, bool), Fail> {
                    if path.exists() {
                        Ok((Vault::open(&path, &password).map_err(|e| Fail::new("unlock_failed", format!("{e:#}")))?, false))
                    } else if create {
                        Ok((Vault::create(&path, &password)?, true))
                    } else {
                        Err(Fail::new("no_vault", "there's no vault yet"))
                    }
                })?;
                let mut vault = vault;
                // the trash empties itself of what's been there a month
                if vault.purge_older(Some(TRASH_DAYS)) > 0 {
                    tokio::task::block_in_place(|| vault.save()).map_err(Fail::from)?;
                }
                let n = vault.list().len();
                *self.vault.lock().await = Some(vault);
                self.event("changed", json!({}));
                self.remote_tick(false).await;
                Ok(json!({ "entries": n, "created": created, "path": path }))
            }
            "lock" => {
                *self.vault.lock().await = None;
                self.approvals.lock().unwrap().clear();
                self.site_grants.lock().unwrap().clear();
                self.once.lock().unwrap().clear();
                self.remote_tick(false).await;
                Ok(json!({}))
            }
            "status" => self.status(None).await,
            "entries" => Ok(json!(self.with_vault(|v| Ok(v.list())).await?)),
            "codes" => {
                let codes = self
                    .with_vault(|v| {
                        let mut out = serde_json::Map::new();
                        for e in v.list() {
                            if let Ok(t) = v.resolve(&e.id).and_then(|id| v.totp(id)) {
                                let (code, left) = t.now();
                                out.insert(e.id.clone(), json!({ "code": code, "left": left, "period": t.period }));
                            }
                        }
                        Ok(out)
                    })
                    .await?;
                Ok(Value::Object(codes))
            }
            "secret" => {
                let id = arg_str(args, "id")?;
                let field = arg_str(args, "field")?;
                Ok(json!(self.with_vault(|v| Ok(v.field(v.resolve(id)?, field))).await?))
            }
            "upsert" => {
                let patch: EntryPatch = serde_json::from_value(args["patch"].clone()).map_err(|e| Fail::bad(e.to_string()))?;
                let info = self
                    .with_vault_mut(|v| {
                        let id = v.apply(&patch)?;
                        v.info(id).ok_or_else(|| Fail::new("not_found", "entry vanished"))
                    })
                    .await?;
                if let Some(id) = &patch.id {
                    // settings changed: earlier approvals no longer apply
                    self.approvals.lock().unwrap().retain(|(e, _), _| e != id);
                    self.site_grants.lock().unwrap().retain(|(e, _), _| e != id);
                }
                // it takes away a way of noticing what agents do, so it goes on the record
                if let Some(quiet) = patch.quiet {
                    self.you(if quiet { "notify_off" } else { "notify_on" }, Some(&info.name), true, String::new());
                }
                Ok(json!(info))
            }
            "delete" => {
                let id = arg_str(args, "id")?.to_string();
                self.with_vault_mut(|v| v.delete(&id)).await?;
                self.approvals.lock().unwrap().retain(|(e, _), _| *e != id);
                Ok(json!({}))
            }
            "trash" => Ok(json!(self.with_vault(|v| Ok(v.trash())).await?)),
            "restore" => {
                let id = arg_str(args, "id")?.to_string();
                let eid = self.with_vault_mut(|v| v.restore(&id)).await?;
                Ok(json!(self.with_vault(|v| Ok(v.info(eid))).await?))
            }
            "purge" => {
                let id = arg_str(args, "id")?.to_string();
                self.with_vault_mut(|v| v.purge(&id)).await?;
                Ok(json!({}))
            }
            "empty_trash" => {
                let n = self.with_vault_mut(|v| Ok(v.purge_older(None))).await?;
                Ok(json!({ "purged": n }))
            }
            "backups" => Ok(json!(self.with_vault(|v| Ok(v.backups())).await?)),
            "restore_backup" => {
                let name = arg_str(args, "name")?.to_string();
                self.with_vault_mut(|v| v.restore_backup(&name)).await?;
                // what was approved was approved for the vault as it was
                self.approvals.lock().unwrap().clear();
                self.once.lock().unwrap().clear();
                Ok(json!({ "entries": self.with_vault(|v| Ok(v.list().len())).await? }))
            }
            "log" => {
                let mut events = self.audit.recent(args["limit"].as_u64().unwrap_or(100).min(1000) as usize);
                // a bypass line only counts as the user's if its consent carries this vault's seal
                let g = self.vault.lock().await;
                if let Some(v) = g.as_ref() {
                    for ev in events.iter_mut().filter(|ev| ev["op"] == "bypass_on") {
                        let sealed = serde_json::from_value::<Consent>(ev["consent"].clone()).is_ok_and(|c| v.verify(&c));
                        ev["sealed"] = json!(sealed);
                    }
                }
                Ok(json!(events))
            }
            "bypass_on" => {
                let id = arg_str(args, "id")?;
                self.grant_bypass(id, args, None, None).await?;
                Ok(json!(self.with_vault(|v| v.info(v.resolve(id)?).ok_or_else(|| Fail::new("not_found", "entry vanished"))).await?))
            }
            "bypass_off" => {
                let id = arg_str(args, "id")?;
                let (was, name) = self.with_vault_mut(|v| {
                    let id = v.resolve(id)?;
                    let name = v.info(id).map(|e| e.name).unwrap_or_default();
                    Ok((v.end_bypass(id)?, name))
                })
                .await?;
                if was {
                    let ev = self.audit.record("you", "bypass_off", Some(&name), true, "turned bypass off");
                    self.event("activity", json!(ev));
                }
                Ok(json!({ "was_on": was }))
            }
            "parse_otp" => {
                let t = Totp::parse(arg_str(args, "text")?).map_err(|e| Fail::new("bad_totp", e))?;
                let (code, left) = t.now();
                Ok(json!({ "uri": t.to_uri(), "issuer": t.issuer, "account": t.account, "code": code, "left": left }))
            }
            "import_parse" => {
                let text = match (opt_str(args, "text"), opt_str(args, "base64")) {
                    (Some(t), _) => t.to_string(),
                    (None, Some(b)) => {
                        let bytes = data_encoding::BASE64.decode(b.as_bytes()).map_err(|_| Fail::bad("bad file data"))?;
                        String::from_utf8_lossy(&bytes).into_owned()
                    }
                    _ => return Err(Fail::bad("nothing to import")),
                };
                let parsed = crate::import::parse_all(&text)?;
                let have = self.known_secrets().await?;
                let list = self.with_vault(|v| Ok(v.list())).await?;
                // passwords stay here: the app gets names to pick from, and sends the file again to save
                let logins: Vec<Value> = parsed
                    .logins
                    .iter()
                    .enumerate()
                    .map(|(i, l)| {
                        let exists = list.iter().any(|e| {
                            !e.library
                                && l.site.as_ref().is_some_and(|s| e.sites.contains(s))
                                && e.username.as_deref().unwrap_or("").eq_ignore_ascii_case(l.username.as_deref().unwrap_or(""))
                        });
                        json!({ "index": i, "name": l.name, "site": l.site, "username": l.username, "has_2fa": l.otp.is_some(), "exists": exists })
                    })
                    .collect();
                let out: Vec<Value> = parsed
                    .tokens
                    .iter()
                    .map(|t| {
                        let code = Totp::parse(&t.uri).map(|x| x.now().0).unwrap_or_default();
                        json!({
                            "issuer": t.issuer, "account": t.account, "uri": t.uri, "site": t.site, "username": t.username,
                            "code": code, "exists": have.contains(&crate::import::secret_of(&t.uri)),
                        })
                    })
                    .collect();
                Ok(json!({ "tokens": out, "logins": logins }))
            }
            "import_save" => {
                let tokens = args["tokens"].as_array().cloned().unwrap_or_default();
                let have = self.known_secrets().await?;
                let (added, skipped) = self
                    .with_vault_mut(|v| {
                        let (mut added, mut skipped) = (0, 0);
                        let mut seen = have.clone();
                        for t in &tokens {
                            let Some(uri) = t["uri"].as_str() else { continue };
                            if !seen.insert(crate::import::secret_of(uri)) {
                                skipped += 1;
                                continue;
                            }
                            let issuer = t["issuer"].as_str().filter(|s| !s.is_empty());
                            let account = t["account"].as_str().filter(|s| !s.is_empty());
                            let base = issuer.or(account).unwrap_or("2FA").to_string();
                            let mut name = base.clone();
                            let mut n = 2;
                            while v.resolve(&name).is_ok() {
                                name = match (n, account) {
                                    (2, Some(a)) if issuer.is_some() => format!("{base} ({a})"),
                                    _ => format!("{base} {n}"),
                                };
                                n += 1;
                            }
                            v.apply(&EntryPatch {
                                name: Some(name),
                                otp: Some(uri.to_string()),
                                username: t["username"].as_str().or(account).map(String::from),
                                sites: Some(t["site"].as_str().into_iter().map(String::from).collect()),
                                policy: Some(Policy::Never),
                                library: Some(true),
                                ..Default::default()
                            })?;
                            added += 1;
                        }
                        Ok((added, skipped))
                    })
                    .await?;
                let logins_added = match opt_str(args, "text") {
                    Some(text) => self.import_logins(text, &str_list_u64(args, "logins"), args).await?,
                    None => 0,
                };
                Ok(json!({ "added": added, "skipped": skipped, "logins_added": logins_added }))
            }
            "browsers" => Ok(json!({
                "connected": self.browsers(),
                "trusted": self.with_vault(|v| Ok(v.trusted_browsers())).await?,
            })),
            "forget_browser" => {
                let bundle = arg_str(args, "bundle")?.to_string();
                self.with_vault_mut(|v| {
                    let mut list = v.trusted_browsers();
                    list.retain(|b| b.bundle != bundle);
                    v.set_trusted_browsers(&list);
                    Ok(())
                })
                .await?;
                // and it stops getting anything right away
                self.bridges.lock().unwrap().retain(|b| b.sig.as_ref().is_none_or(|(id, _)| *id != bundle));
                self.browser_event();
                Ok(json!({}))
            }
            // Stop on a notification: nothing from that thread (or what it runs) goes through until it exits
            "cut_off" => {
                let thread = arg_str(args, "thread")?;
                let (pid, start) = thread
                    .split_once(':')
                    .and_then(|(p, s)| Some((p.parse::<i32>().ok()?, s.parse::<u64>().ok()?)))
                    .ok_or_else(|| Fail::bad(format!("`thread` is pid:start, not {thread}")))?;
                if pid <= 1 || peer::proc_start(pid) != Some(start) {
                    return Ok(json!({ "cut": false, "gone": true }));
                }
                {
                    let mut cut = self.cut.lock().unwrap();
                    if !cut.contains(&(pid, start)) {
                        cut.push((pid, start));
                    }
                }
                self.approvals.lock().unwrap().retain(|(_, t), _| t != thread);
                let who = opt_str(args, "who").unwrap_or("an agent");
                let folder = opt_str(args, "folder").map(|f| format!(" ({f})")).unwrap_or_default();
                let ev = self.audit.record("you", "cut_off", None, true, format!("{who}{folder}"));
                self.event("activity", json!(ev));
                Ok(json!({ "cut": true }))
            }
            "waits" => Ok(json!(self.with_vault(|v| Ok(v.waits())).await?)),
            "set_waits" => {
                let waits: Waits = serde_json::from_value(args["waits"].clone()).map_err(|e| Fail::bad(e.to_string()))?;
                waits.check()?;
                self.with_vault_mut(|v| {
                    v.set_waits(&waits);
                    Ok(())
                })
                .await?;
                Ok(json!(waits))
            }
            "forget_approvals" => {
                self.approvals.lock().unwrap().clear();
                self.site_grants.lock().unwrap().clear();
                self.once.lock().unwrap().clear();
                Ok(json!({}))
            }
            "remote_status" | "remote_set_pin" | "remote_off" | "remote_forget" => self.handle_remote(op, args).await,
            // the user clicked a request's notification on the Mac: answer it here after all
            "ask_here" => Ok(json!({ "shown": self.ask_here(arg_str(args, "ask")?) })),
            "check_pin" => self.mac_pin(arg_str(args, "pin")?).await,
            _ => Err(Fail::bad(format!("unknown app operation `{op}`"))),
        }
    }
}

impl State {
    /// The chosen logins of a password export (by their index in it), each a new entry. A 2FA secret
    /// that's already in the vault as an imported code moves into the login.
    async fn import_logins(&self, text: &str, picked: &[u64], args: &Value) -> Result<usize, Fail> {
        let parsed = crate::import::parse_all(text)?;
        let policy = match opt_str(args, "policy") {
            Some("auto") => Policy::Auto,
            Some("never") => Policy::Never,
            _ => Policy::Ask,
        };
        self.with_vault_mut(|v| {
            let mut library: HashMap<String, String> = HashMap::new();
            for e in v.list().into_iter().filter(|e| e.library) {
                if let Some(u) = v.resolve(&e.id).ok().and_then(|id| v.field(id, "otp")) {
                    library.insert(crate::import::secret_of(&u), e.id.clone());
                }
            }
            let mut added = 0;
            for &i in picked {
                let Some(l) = parsed.logins.get(i as usize) else { continue };
                // the same secret imported as a code before: the login takes it over (and its name)
                if let Some(id) = l.otp.as_ref().and_then(|u| library.remove(&crate::import::secret_of(u))) {
                    v.delete(&id)?;
                }
                let mut name = l.name.clone();
                let mut n = 2;
                while v.resolve(&name).is_ok() {
                    name = match (n, &l.username) {
                        (2, Some(u)) => format!("{} ({u})", l.name),
                        _ => format!("{} {n}", l.name),
                    };
                    n += 1;
                }
                v.apply(&EntryPatch {
                    name: Some(name),
                    username: l.username.clone(),
                    password: Some(l.password.clone()),
                    otp: l.otp.clone(),
                    sites: Some(l.site.iter().cloned().collect()),
                    notes: l.notes.clone(),
                    policy: Some(policy),
                    ..Default::default()
                })?;
                added += 1;
            }
            Ok(added)
        })
        .await
    }

    /// secrets already in the vault, to skip duplicates on import
    async fn known_secrets(&self) -> Result<std::collections::HashSet<String>, Fail> {
        self.with_vault(|v| {
            Ok(v.list()
                .iter()
                .filter_map(|e| v.resolve(&e.id).ok().and_then(|id| v.field(id, "otp")))
                .map(|u| crate::import::secret_of(&u))
                .collect())
        })
        .await
    }
}

/// An entry as this caller may use it: Auto and bypass only count for an agent whose signature otto
/// checked, so for anything else bypass is off and Auto asks with Touch ID.
fn as_seen(c: &Client, mut e: EntryInfo) -> EntryInfo {
    if !in_scope(c, &e) {
        e.out_of_scope = true;
        e.policy = Policy::Never;
        e.bypass = None;
        return e;
    }
    if !c.verified {
        e.bypass = None;
        if e.policy == Policy::Auto {
            e.policy = Policy::Ask;
        }
    }
    e
}

/// Nobody answered at the Mac: the user may be away, and their phone is the way to reach them there.
fn away_hint(remote: bool) -> String {
    if remote {
        "nobody approved it in time (the user may be away from the Mac). ask the user; if they tell you they're away, call again with remote: true and send them the link, they can answer from their phone with their PIN".into()
    } else {
        "nobody approved it in time (the user may be away from the Mac). ask the user; to answer from their phone while they're away, they can set up Remote in otto's settings (a PIN, over Tailscale)".into()
    }
}

/// The user's optional limits on an entry: only agents working in some folders, only some agents (which
/// otto must have verified, so a program can't take an agent's name).
fn in_scope(c: &Client, e: &EntryInfo) -> bool {
    let folder_ok = e.folders.is_empty() || c.folder.as_deref().is_some_and(|f| e.folders.iter().any(|s| under(f, s)));
    let agent_ok = e.agents.is_empty() || (c.verified && e.agents.iter().any(|a| a.eq_ignore_ascii_case(&c.agent)));
    folder_ok && agent_ok
}

/// `folder` is `scope` or inside it ("~/otto/core" is under "~/otto", "~/otto2" isn't).
fn under(folder: &str, scope: &str) -> bool {
    let s = scope.trim_end_matches('/');
    folder == s || folder.strip_prefix(s).is_some_and(|rest| rest.starts_with('/'))
}

/// The browser filled but didn't submit on purpose (a captcha not done yet, a form that isn't complete).
fn held(r: &Value) -> String {
    r["held"].as_str().map(|h| format!(", didn't submit: {h}")).unwrap_or_default()
}

/// Plain http (only with bypass on, loopback aside) goes in the log line, so the user sees it there.
fn over_http(r: &Value) -> &'static str {
    let plain = ["url", "frame_url"].iter().any(|k| {
        r[*k].as_str().and_then(|u| url::Url::parse(u).ok()).is_some_and(|u| {
            u.scheme() == "http"
                && match u.host() {
                    Some(url::Host::Domain(d)) => d != "localhost",
                    Some(url::Host::Ipv4(ip)) => !ip.is_loopback(),
                    Some(url::Host::Ipv6(ip)) => !ip.is_loopback(),
                    None => false,
                }
        })
    });
    if plain { " over http" } else { "" }
}

/// For the notification: what an agent did with an entry ("filled", ["password"], "github.com").
fn use_of(op: &str, args: &Value, r: &Value, kind: &str) -> (&'static str, Vec<String>, Option<String>) {
    let host = || r["url"].as_str().and_then(|u| url::Url::parse(u).ok()).and_then(|u| u.host_str().map(String::from));
    let names = |v: &Value| -> Vec<String> { v.as_array().into_iter().flatten().filter_map(|x| x.as_str().map(String::from)).collect() };
    let field = |f: &str| match f {
        "" => main_field(kind).to_string(),
        "code" | "otp" | "2fa" => "2FA code".to_string(),
        f => f.to_string(),
    };
    match op {
        "code" => ("got", vec!["2FA code".into()], None),
        "fill_code" => ("filled", vec!["2FA code".into()], host()),
        "fill_on_site" if args["what"] == "2fa_code" => ("filled", vec!["2FA code".into()], host()),
        "fill" | "fill_on_site" => ("filled", names(&r["filled"]), host()),
        "fill_card" => ("filled", vec!["card".into()], host()),
        "type" => ("typed", vec![field(r["typed"].as_str().unwrap_or(""))], r["app"].as_str().map(String::from)),
        // only the names of what was handed over: the values never leave this function
        "env" => (
            "handed",
            r["values"].as_object().map(|m| m.keys().map(|k| field(k)).collect()).unwrap_or_default(),
            opt_str(args, "command").map(String::from),
        ),
        _ => ("used", vec![], None),
    }
}

/// "2026-10-12T09:00:00Z" -> "Oct 12, 12:00" on this Mac's clock
fn local_time(rfc3339: &str) -> String {
    chrono::DateTime::parse_from_rfc3339(rfc3339)
        .map(|t| t.with_timezone(&chrono::Local).format("%b %-d, %H:%M").to_string())
        .unwrap_or_else(|_| rfc3339.to_string())
}

fn str_list_u64(args: &Value, key: &str) -> Vec<u64> {
    args[key].as_array().map(|a| a.iter().filter_map(Value::as_u64).collect()).unwrap_or_default()
}

fn no_totp(e: &EntryInfo) -> Fail {
    match e.two_factor.as_deref() {
        Some("delivered") => Fail::new("delivered_2fa", format!("\"{}\" gets its 2FA code by SMS or email. ask the user for the code they just received", e.name)).noted("it gets its 2FA code by SMS or email"),
        Some("none") => Fail::new("no_2fa", format!("the user says \"{}\" has no 2FA", e.name)),
        _ => Fail::new("no_totp", format!("\"{}\" has no 2FA secret yet. if the site shows a 2FA setup QR, use enroll; if it texts or emails a code, ask the user for it", e.name)).noted("it has no 2FA secret yet"),
    }
}

/// An entry used the wrong way: each kind has its own way in, so say which.
fn wrong_kind(e: &EntryInfo) -> Fail {
    let how = match e.kind.as_str() {
        "card" => "a card: fill it on the checkout page with fill_card".to_string(),
        "key" => format!("an API key: hand it to a program with `otto run --env VAR={} -- <command>`", e.name),
        "note" => "a secure note, which otto doesn't fill anywhere".to_string(),
        "mac" => "the Mac's password: it only goes to sudo, through `otto sudo -- <command>`".to_string(),
        "value" => format!("a value the user keeps for commands: leave a blank called {{{{{}}}}} in run_command", e.name),
        _ => "a login: use fill_login or type_secret".to_string(),
    };
    Fail::new("wrong_kind", format!("\"{}\" is {how}", e.name))
}

/// What sudo is about to run, from its arguments as ps shows them ("/usr/bin/sudo -A <command>").
fn sudo_shown(args: &str) -> String {
    let rest = args.strip_prefix("/usr/bin/sudo ").or_else(|| args.strip_prefix("sudo ")).unwrap_or(args);
    shorten(&format!("sudo {}", rest.strip_prefix("-A ").unwrap_or(rest)), 160)
}

/// A command for a one-line prompt: whitespace collapsed (so padding can't push the end out of sight),
/// and if it's long, its start and its end.
/// How a command reads to the user: what `sh -c` runs as it is, anything else with its arguments quoted
/// where a shell would need it.
fn command_shown(argv: &[String]) -> String {
    if let Some(cmd) = shell_form(argv) {
        return cmd.to_string();
    }
    argv.iter().map(|a| quoted(a)).collect::<Vec<_>>().join(" ")
}

/// `sh -c <this>`: the command is what's in the string.
fn shell_form(argv: &[String]) -> Option<&str> {
    let shell = argv.len() == 3 && matches!(argv[0].as_str(), "/bin/sh" | "sh" | "/bin/zsh" | "zsh" | "/bin/bash" | "bash") && argv[1] == "-c";
    shell.then(|| argv[2].as_str())
}

fn quoted(a: &str) -> String {
    if !a.is_empty() && a.chars().all(|ch| ch.is_ascii_alphanumeric() || "-_./=:,+@%~^".contains(ch)) {
        a.to_string()
    } else {
        format!("'{}'", a.replace('\'', "'\\''"))
    }
}

/// What a command's yes is kept under: its exact arguments and folder, so a yes for one doesn't cover another.
fn command_digest(argv: &[String], cwd: Option<&str>) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    for a in argv {
        h.update(a.as_bytes());
        h.update([0]);
    }
    h.update([0]);
    h.update(cwd.unwrap_or("").as_bytes());
    data_encoding::HEXLOWER.encode(&h.finalize()[..16])
}

fn shorten(s: &str, max: usize) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let n = s.chars().count();
    if n <= max {
        return s;
    }
    let head: String = s.chars().take(max * 2 / 3).collect();
    let tail: String = s.chars().skip(n - max / 3).collect();
    format!("{head} … {tail}")
}

/// The extension already refuses to fill a non-matching page; check again here (the tab and the
/// frame that got the values) and keep the host for the log.
fn check_host(r: &Value, sites: &[String]) -> Result<String, Fail> {
    let host_of = |k: &str| r[k].as_str().and_then(|u| url::Url::parse(u).ok()).and_then(|u| u.host_str().map(String::from));
    let tab = host_of("url").unwrap_or_default();
    let frame = host_of("frame_url").unwrap_or_else(|| tab.clone());
    for h in [&tab, &frame] {
        if !site_matches(h, sites) {
            return Err(Fail::new("wrong_site", format!("the browser reported {h}, which isn't one of this entry's sites")));
        }
    }
    Ok(frame)
}

/// username and/or password, from a fill request
fn login_fields(args: &Value) -> Result<Vec<String>, Fail> {
    let mut wanted = str_list(args, "fields");
    if wanted.is_empty() {
        wanted = vec!["username".into(), "password".into()];
    }
    if let Some(bad) = wanted.iter().find(|f| *f != "username" && *f != "password") {
        return Err(Fail::bad(format!("the browser can fill username and password, not `{bad}`")));
    }
    Ok(wanted)
}

/// When the entry's own sites aren't open, the login may have moved: say what to do about it.
fn moved_hint(f: Fail) -> Fail {
    if f.code == "no_tab" || f.code == "wrong_site" {
        let line = f.for_log();
        return Fail::new(&f.code, format!("{}. if this login now lives on another domain, use fill_on_site with that domain (the user approves it once)", f.message)).noted(line);
    }
    f
}

/// Run futures concurrently and collect their results in order.
async fn futures_join<F: std::future::Future<Output = OpResult> + Send + 'static>(futs: impl Iterator<Item = F>) -> Vec<OpResult> {
    let handles: Vec<_> = futs.map(tokio::spawn).collect();
    let mut out = Vec::new();
    for h in handles {
        out.push(h.await.unwrap_or_else(|e| Err(Fail::new("internal", e.to_string()))));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(name: &str, verified: bool, folder: Option<&str>) -> Client {
        Client {
            pid: 1,
            agent: name.into(),
            chain: vec![],
            verified,
            agent_pid: 1,
            thread: "1:1".into(),
            via: None,
            folder: folder.map(String::from),
            procs: vec![],
            grant: Default::default(),
            command: Default::default(),
            away: false,
        }
    }

    #[test]
    fn commands_read_as_typed_and_each_yes_is_for_one() {
        let v = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(command_shown(&v(&["/bin/sh", "-c", "networksetup -setdnsservers Wi-Fi 1.1.1.1 && echo ok"])), "networksetup -setdnsservers Wi-Fi 1.1.1.1 && echo ok");
        assert_eq!(command_shown(&v(&["rm", "-rf", "build dir", "it's"])), "rm -rf 'build dir' 'it'\\''s'");
        assert_eq!(command_shown(&v(&["git", "push", "--force", "origin", "main"])), "git push --force origin main");
        let a = command_digest(&v(&["rm", "-rf", "build"]), Some("~/otto"));
        assert_eq!(a, command_digest(&v(&["rm", "-rf", "build"]), Some("~/otto")));
        assert_ne!(a, command_digest(&v(&["rm", "-rf", "build"]), Some("~/other")), "another folder is another command");
        assert_ne!(a, command_digest(&v(&["rm", "-rf build"]), Some("~/otto")), "arguments split differently are another command");
        assert_ne!(a, command_digest(&v(&["rm", "-rf", "build", ""]), Some("~/otto")));
    }

    #[test]
    fn limits_to_projects_and_agents() {
        let dir = std::env::temp_dir().join(format!("otto-scope-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut v = Vault::create(&dir.join("v.kdbx"), "k").unwrap();
        let mut add = |name: &str, folders: &[&str], agents: &[&str]| {
            v.apply(&EntryPatch {
                name: Some(name.into()),
                password: Some("pw".into()),
                policy: Some(Policy::Auto),
                folders: Some(folders.iter().map(|s| s.to_string()).collect()),
                agents: Some(agents.iter().map(|s| s.to_string()).collect()),
                ..Default::default()
            })
            .unwrap()
        };
        add("Open", &[], &[]);
        add("Otto only", &["~/otto/"], &[]);
        add("Claude only", &[], &["Claude"]);
        add("Both", &["~/otto"], &["claude"]);
        let seen = |c: &Client| -> Vec<String> {
            v.list().into_iter().map(|e| as_seen(c, e)).filter(|e| !e.hidden()).map(|e| e.name).collect()
        };
        assert_eq!(seen(&agent("claude", true, Some("~/otto/core"))), ["Both", "Claude only", "Open", "Otto only"]);
        assert_eq!(seen(&agent("claude", true, Some("~/otto2"))), ["Claude only", "Open"], "a folder that only starts the same isn't inside");
        assert_eq!(seen(&agent("codex", true, Some("~/otto"))), ["Open", "Otto only"]);
        assert_eq!(seen(&agent("claude", false, Some("~/otto"))), ["Open", "Otto only"], "an unverified program can't take claude's name");
        assert_eq!(seen(&agent("claude", true, None)), ["Claude only", "Open"], "no folder: not in any");
        let e = as_seen(&agent("codex", true, Some("~/x")), v.find("Both").unwrap());
        assert!(e.out_of_scope && e.hidden() && e.bypass.is_none());
        assert_eq!(v.find("Both").unwrap().folders, ["~/otto"]);
        assert_eq!(v.find("Both").unwrap().agents, ["claude"]);
    }

    #[test]
    fn sudo_commands_as_shown() {
        assert_eq!(sudo_shown("/usr/bin/sudo -A -k /usr/bin/true"), "sudo -k /usr/bin/true");
        assert_eq!(sudo_shown("sudo -A launchctl kickstart -k system/com.example"), "sudo launchctl kickstart -k system/com.example");
        // padding can't push the end of a command out of sight
        let sneaky = format!("/usr/bin/sudo -A sh -c echo{}; rm -rf /x", " ".repeat(500));
        assert_eq!(sudo_shown(&sneaky), "sudo sh -c echo ; rm -rf /x");
        let long = format!("/usr/bin/sudo -A cp {} /etc/x", "a/".repeat(200));
        let s = sudo_shown(&long);
        assert!(s.starts_with("sudo cp a/a/") && s.contains(" … ") && s.ends_with(" /etc/x") && s.chars().count() < 170, "{s}");
    }

    #[test]
    fn notifications_name_what_was_used_never_the_value() {
        let (how, what, place) = use_of("env", &json!({ "command": "npm" }), &json!({ "values": { "": "sk-SECRET", "code": "123456" } }), "key");
        assert_eq!((how, what.clone(), place.as_deref()), ("handed", vec!["key".to_string(), "2FA code".to_string()], Some("npm")));
        assert!(!format!("{what:?}").contains("SECRET"));
        let (how, what, place) = use_of("fill", &json!({}), &json!({ "filled": ["username", "password"], "url": "https://github.com/login" }), "login");
        assert_eq!((how, what, place.as_deref()), ("filled", vec!["username".to_string(), "password".to_string()], Some("github.com")));
        let (_, what, _) = use_of("fill_on_site", &json!({ "what": "2fa_code" }), &json!({ "filled": ["code"], "url": "https://x.example/" }), "login");
        assert_eq!(what, vec!["2FA code".to_string()]);
        let (how, what, place) = use_of("type", &json!({}), &json!({ "typed": "code", "app": "Docker" }), "login");
        assert_eq!((how, what, place.as_deref()), ("typed", vec!["2FA code".to_string()], Some("Docker")));
    }

    #[test]
    fn held_fills_say_why() {
        assert_eq!(held(&json!({ "held": "the captcha isn't done" })), ", didn't submit: the captcha isn't done");
        assert_eq!(held(&json!({ "submitted": true })), "");
    }

    #[test]
    fn http_fills_say_so() {
        assert_eq!(over_http(&json!({ "url": "http://192.168.1.1/login" })), " over http");
        assert_eq!(over_http(&json!({ "url": "https://192.168.1.1/", "frame_url": "http://192.168.1.1/f" })), " over http");
        assert_eq!(over_http(&json!({ "url": "http://127.0.0.1:8765/" })), "");
        assert_eq!(over_http(&json!({ "url": "http://localhost/" })), "");
        assert_eq!(over_http(&json!({ "url": "http://[::1]:80/" })), "");
        assert_eq!(over_http(&json!({ "url": "https://github.com/login" })), "");
    }
}
