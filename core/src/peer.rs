//! Who is on the other end of the socket: which agent asked (and whether its code signature says it
//! really is that agent), and whether a browser bridge really was started by a browser.

use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
};

#[derive(Debug, Clone, Serialize)]
pub struct Client {
    pub pid: i32,
    /// the agent we think is asking ("claude", "codex"...), or the nearest parent process
    pub agent: String,
    /// process names from the caller upwards
    pub chain: Vec<String>,
    /// the agent's code signature is one otto pins: only then do Auto and bypass apply
    pub verified: bool,
    /// the agent's process (0: no agent found): its requests, and its shell commands', are one thread
    pub agent_pid: i32,
    /// "pid:start" of the agent, or of the caller's parent when it isn't a verified agent: what
    /// approvals are remembered for and what Stop cuts off
    pub thread: String,
    /// the app that started the agent, when otto knows it ("T3 Code")
    pub via: Option<String>,
    /// the agent's working folder, "~/otto"
    pub folder: Option<String>,
    /// (pid, start time) from the caller upwards, so a cut-off thread's children are refused too
    #[serde(skip)]
    pub procs: Vec<(i32, u64)>,
    /// how this request's use got through (set by the policy gate, read for the notification)
    #[serde(skip)]
    pub grant: Arc<Mutex<Option<Grant>>>,
    /// the command this request is about, in full, and the agent's reason: for its log line
    #[serde(skip)]
    pub command: Arc<Mutex<Option<(String, Option<String>)>>>,
    /// this request says the user is away from the Mac (they told the agent): a link for their
    /// phone instead of a window or Touch ID on the Mac
    #[serde(skip)]
    pub away: bool,
}

/// How a use of an entry was allowed. Everything but `Asked` happened without the user seeing a prompt
/// right then, so the app tells them afterwards.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Grant {
    Auto,
    Bypass,
    /// an earlier Touch ID yes for this thread
    Remembered,
    Asked,
}

impl Grant {
    pub fn as_str(self) -> &'static str {
        match self {
            Grant::Auto => "auto",
            Grant::Bypass => "bypass",
            Grant::Remembered => "remembered",
            Grant::Asked => "asked",
        }
    }
}

impl Client {
    fn unknown() -> Client {
        Client {
            pid: 0,
            agent: "unknown".into(),
            chain: vec![],
            verified: false,
            agent_pid: 0,
            thread: String::new(),
            via: None,
            folder: None,
            procs: vec![],
            grant: Default::default(),
            command: Default::default(),
            away: false,
        }
    }

    /// The same caller with a fresh grant, for one request.
    pub fn for_request(&self) -> Client {
        Client { grant: Default::default(), command: Default::default(), ..self.clone() }
    }

    pub fn about(&self, command: &str, why: Option<&str>) {
        *self.command.lock().unwrap() = Some((command.into(), why.map(String::from)));
    }

    pub fn granted(&self, g: Grant) {
        *self.grant.lock().unwrap() = Some(g);
    }

    pub fn grant(&self) -> Option<Grant> {
        *self.grant.lock().unwrap()
    }

    /// How the user is told who's asking: "claude", "claude via T3 Code", "an unverified program (python3)".
    pub fn who(&self) -> String {
        if !self.verified {
            return format!("an unverified program ({})", self.agent);
        }
        match &self.via {
            Some(v) => format!("{} via {v}", self.agent),
            None => self.agent.clone(),
        }
    }
}

const AGENTS: &[&str] = &[
    "claude", "codex", "cursor", "cursor-agent", "opencode", "aider", "gemini", "goose", "amp", "droid", "windsurf", "zed", "crush", "kiro",
];

/// Agents trusted by their code signature: (the name otto knows them by, signing team). An agent by
/// another name, or by this name but signed by someone else (or not at all), counts as unverified.
#[cfg(target_os = "macos")]
const AGENT_PINS: &[(&str, &str)] = &[
    // Anthropic: Claude Code, and Claude for Mac
    ("claude", "Q6L2SF6YDW"),
    // OpenAI: the native codex binary (the npm package's node script only starts it)
    ("codex", "2DC432GLL2"),
    // Anomaly: opencode, and OpenCode.app
    ("opencode", "5NZ4Q7NXJ4"),
    ("cursor", "VDXQ22DGB9"),
    ("zed", "MQ55VZLNZQ"),
];

/// Apps that start agents, named with them ("claude via T3 Code"): (the app's name starts with, team).
#[cfg(target_os = "macos")]
const LAUNCHERS: &[(&str, &str)] = &[("T3 Code", "ARK85ZXQ4Z")];

#[cfg(target_os = "macos")]
pub fn peer_pid(fd: std::os::fd::RawFd) -> Option<i32> {
    const SOL_LOCAL: libc::c_int = 0;
    const LOCAL_PEERPID: libc::c_int = 2;
    let mut pid: libc::pid_t = 0;
    let mut len = std::mem::size_of::<libc::pid_t>() as libc::socklen_t;
    let r = unsafe { libc::getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &mut pid as *mut _ as *mut libc::c_void, &mut len) };
    (r == 0 && pid > 0).then_some(pid)
}

#[cfg(target_os = "linux")]
pub fn peer_pid(fd: std::os::fd::RawFd) -> Option<i32> {
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let r = unsafe { libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_PEERCRED, &mut cred as *mut _ as *mut libc::c_void, &mut len) };
    (r == 0 && cred.pid > 0).then_some(cred.pid)
}

/// (parent pid, short name)
#[cfg(target_os = "macos")]
pub fn proc_info(pid: i32) -> Option<(i32, String)> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let r = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, &mut info as *mut _ as *mut libc::c_void, size) };
    if r != size {
        return None;
    }
    let name = cstr(&info.pbi_name);
    let name = if name.is_empty() { cstr(&info.pbi_comm) } else { name };
    Some((info.pbi_ppid as i32, name))
}

/// When a process started (seconds since 1970), so a reused pid isn't mistaken for the old process.
#[cfg(target_os = "macos")]
pub fn proc_start(pid: i32) -> Option<u64> {
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int;
    let r = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, &mut info as *mut _ as *mut libc::c_void, size) };
    (r == size).then_some(info.pbi_start_tvsec)
}

/// A process's working folder.
#[cfg(target_os = "macos")]
fn proc_cwd(pid: i32) -> Option<PathBuf> {
    let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int;
    let r = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, &mut info as *mut _ as *mut libc::c_void, size) };
    if r != size {
        return None;
    }
    let raw: &[libc::c_char] = unsafe { std::slice::from_raw_parts(info.pvi_cdir.vip_path.as_ptr() as *const libc::c_char, 32 * 32) };
    let p = cstr(raw);
    (!p.is_empty()).then(|| PathBuf::from(p))
}

#[cfg(target_os = "linux")]
pub fn proc_start(pid: i32) -> Option<u64> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    stat[stat.rfind(')')? + 2..].split_whitespace().nth(19)?.parse().ok()
}

#[cfg(target_os = "linux")]
fn proc_cwd(pid: i32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/cwd")).ok()
}

#[cfg(target_os = "linux")]
pub fn proc_info(pid: i32) -> Option<(i32, String)> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let open = stat.find('(')?;
    let close = stat.rfind(')')?;
    let name = stat[open + 1..close].to_string();
    let ppid = stat[close + 2..].split_whitespace().nth(1)?.parse().ok()?;
    Some((ppid, name))
}

#[cfg(target_os = "macos")]
pub fn proc_path(pid: i32) -> Option<PathBuf> {
    let mut buf = vec![0u8; 4096];
    let n = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr() as *mut libc::c_void, buf.len() as u32) };
    if n <= 0 {
        return None;
    }
    buf.truncate(n as usize);
    Some(PathBuf::from(String::from_utf8_lossy(&buf).into_owned()))
}

#[cfg(target_os = "linux")]
pub fn proc_path(pid: i32) -> Option<PathBuf> {
    std::fs::read_link(format!("/proc/{pid}/exe")).ok()
}

#[cfg(target_os = "macos")]
fn cstr(chars: &[libc::c_char]) -> String {
    let bytes: Vec<u8> = chars.iter().take_while(|c| **c != 0).map(|c| *c as u8).collect();
    String::from_utf8_lossy(&bytes).into_owned()
}

/// Claude Code's binary is named after its version (~/.local/share/claude/versions/2.1.x), so look at
/// the path too, not just the process name.
fn agent_name(name: &str, path: Option<&std::path::Path>) -> Option<String> {
    let is_agent = |n: &str| {
        let n = n.to_lowercase();
        // opencode ships its macOS binary as opencode.exe
        let n = n.trim_end_matches(".app").trim_end_matches(".exe");
        AGENTS.iter().find(|a| n == **a || n.starts_with(&format!("{a}-"))).map(|a| a.to_string())
    };
    if let Some(a) = is_agent(name) {
        return Some(a);
    }
    let path = path?;
    let parts: Vec<String> = path.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect();
    parts.iter().rev().take(4).find_map(|p| is_agent(p))
}

pub fn describe(pid: Option<i32>) -> Client {
    describe_from(pid, 1)
}

/// Walk up from `pid`; the nearest process from `depth` up that's a known agent is the one asking
/// (depth 0 is normally otto itself).
fn describe_from(pid: Option<i32>, depth: usize) -> Client {
    let Some(pid) = pid else { return Client::unknown() };
    let mut chain = Vec::new();
    let mut procs = Vec::new();
    let mut paths = Vec::new();
    let mut agent: Option<(usize, String)> = None;
    let mut cur = pid;
    for d in 0..12 {
        let Some((ppid, name)) = proc_info(cur) else { break };
        let path = proc_path(cur);
        let known = agent_name(&name, path.as_deref());
        if d >= depth && agent.is_none() {
            agent = known.clone().map(|a| (d, a));
        }
        chain.push(known.unwrap_or(name));
        procs.push((cur, proc_start(cur).unwrap_or(0)));
        paths.push(path);
        if ppid <= 1 || ppid == cur {
            break;
        }
        cur = ppid;
    }
    let name = agent
        .as_ref()
        .map(|(_, a)| a.clone())
        .or_else(|| chain.get(1).cloned())
        .or_else(|| chain.first().cloned())
        .unwrap_or_else(|| "unknown".into());
    let verified = agent.as_ref().is_some_and(|(d, a)| verify_agent(a, procs[*d], paths[*d].as_deref()));
    // a verified agent is one thread; anything else is grouped by the process that ran it (its shell)
    let at = match &agent {
        Some((d, _)) if verified => *d,
        _ => 1.min(procs.len().saturating_sub(1)),
    };
    let agent_pid = agent.as_ref().map(|(d, _)| procs[*d].0).unwrap_or(0);
    let (tp, ts) = procs.get(at).copied().unwrap_or((pid, 0));
    let via = match &agent {
        Some((d, _)) if verified => launcher(&procs[d + 1..], &paths[d + 1..]),
        _ => None,
    };
    let folder = proc_cwd(if agent_pid > 0 { agent_pid } else { tp }).map(|p| tilde(&p));
    Client { pid, agent: name, chain, verified, agent_pid, thread: format!("{tp}:{ts}"), via, folder, procs, grant: Default::default(), command: Default::default(), away: false }
}

/// "/Users/alfa/otto" -> "~/otto"
pub fn tilde(p: &std::path::Path) -> String {
    match std::env::var("HOME").ok().and_then(|h| p.strip_prefix(h).ok().map(PathBuf::from)) {
        Some(rest) if rest.as_os_str().is_empty() => "~".into(),
        Some(rest) => format!("~/{}", rest.display()),
        None => p.display().to_string(),
    }
}

/// Signature checks take a few hundred milliseconds, so each process is checked once.
static VERIFIED: Mutex<Option<HashMap<(i32, u64), bool>>> = Mutex::new(None);

fn cached(key: (i32, u64), check: impl FnOnce() -> bool) -> bool {
    if let Some(v) = VERIFIED.lock().unwrap().get_or_insert_with(HashMap::new).get(&key) {
        return *v;
    }
    let v = check();
    let mut g = VERIFIED.lock().unwrap();
    let m = g.get_or_insert_with(HashMap::new);
    if m.len() > 500 {
        m.clear();
    }
    m.insert(key, v);
    v
}

/// Tests run fake, unsigned agents: OTTO_DEV_AGENT=<folder> trusts agents run from that folder, but only
/// for a throwaway vault (OTTO_HOME and OTTO_DEV_KEY set, OTTO_HOME not otto's usual place).
fn dev_agent_dir() -> Option<PathBuf> {
    let dir = std::env::var("OTTO_DEV_AGENT").ok().filter(|d| !d.is_empty())?;
    std::env::var("OTTO_DEV_KEY").ok().filter(|k| !k.is_empty())?;
    let home = std::env::var("OTTO_HOME").ok().filter(|h| !h.is_empty())?;
    let usual = std::env::var("HOME").map(|h| PathBuf::from(h).join("Library/Application Support/otto")).ok();
    let same = |a: &std::path::Path, b: &std::path::Path| a.canonicalize().ok().zip(b.canonicalize().ok()).is_some_and(|(a, b)| a == b) || a == b;
    if usual.as_deref().is_some_and(|u| same(std::path::Path::new(&home), u)) {
        return None;
    }
    let dir = PathBuf::from(dir);
    Some(dir.canonicalize().unwrap_or(dir))
}

#[cfg(target_os = "macos")]
fn verify_agent(name: &str, (pid, start): (i32, u64), path: Option<&std::path::Path>) -> bool {
    if let (Some(dir), Some(path)) = (dev_agent_dir(), path) {
        if path.starts_with(&dir) {
            return true;
        }
    }
    let Some((_, team)) = AGENT_PINS.iter().find(|(a, _)| *a == name) else { return false };
    cached((pid, start), || satisfies(pid, &format!(r#"anchor apple generic and certificate leaf[subject.OU] = "{team}""#)))
}

#[cfg(not(target_os = "macos"))]
fn verify_agent(_name: &str, (_pid, _start): (i32, u64), path: Option<&std::path::Path>) -> bool {
    dev_agent_dir().zip(path).is_some_and(|(d, p)| p.starts_with(d))
}

/// The app that started the agent, if it's one otto knows, checked by its signature.
#[cfg(target_os = "macos")]
fn launcher(procs: &[(i32, u64)], paths: &[Option<PathBuf>]) -> Option<String> {
    for (&(pid, start), path) in procs.iter().zip(paths) {
        let Some(path) = path else { continue };
        let (_, app) = app_of(path);
        for (name, team) in LAUNCHERS {
            if app.starts_with(name)
                && cached((pid, start), || satisfies(pid, &format!(r#"anchor apple generic and certificate leaf[subject.OU] = "{team}""#)))
            {
                return Some(name.to_string());
            }
        }
    }
    None
}

#[cfg(not(target_os = "macos"))]
fn launcher(_procs: &[(i32, u64)], _paths: &[Option<PathBuf>]) -> Option<String> {
    None
}

/// Browsers trusted without asking: (bundle id, signing team). Any other browser signed with a
/// Developer ID can still be used once the user allows it (its id and team are then kept in the vault).
#[cfg(target_os = "macos")]
const PINNED: &[(&str, &str)] = &[
    ("com.google.Chrome", "EQHXZ8M8AV"),
    ("com.google.Chrome.beta", "EQHXZ8M8AV"),
    ("com.google.Chrome.dev", "EQHXZ8M8AV"),
    ("com.google.Chrome.canary", "EQHXZ8M8AV"),
    ("com.brave.Browser", "KL8N8XSYF4"),
    ("com.brave.Browser.beta", "KL8N8XSYF4"),
    ("com.brave.Browser.nightly", "KL8N8XSYF4"),
    ("com.microsoft.edgemac", "UBF8T346G9"),
    ("com.microsoft.edgemac.Beta", "UBF8T346G9"),
    ("com.microsoft.edgemac.Dev", "UBF8T346G9"),
    ("com.microsoft.edgemac.Canary", "UBF8T346G9"),
    ("company.thebrowser.Browser", "S6N382Y83G"),
    ("company.thebrowser.dia", "S6N382Y83G"),
];

/// Signed with a Developer ID certificate (not ad hoc, not a free development certificate).
#[cfg(target_os = "macos")]
const DEVELOPER_ID: &str = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists";

/// A browser that isn't pinned: who signed it, for the user to decide on (once).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BrowserSig {
    pub name: String,
    pub bundle: String,
    pub team: String,
    /// "Vivaldi Technologies AS", from the Developer ID certificate
    pub signer: String,
    /// the .app
    pub path: String,
}

pub enum Verdict {
    Trusted(String),
    /// signed with a Developer ID but not one otto knows: the user has to allow it
    Unknown(BrowserSig),
    /// updated itself while running: what's on disk is fine but no longer what's running, so the check
    /// can't pass until it's relaunched
    Outdated(String),
}

#[cfg(target_os = "macos")]
fn satisfies(pid: i32, req: &str) -> bool {
    target_satisfies(&pid.to_string(), req)
}

/// `target` is a pid or a path.
#[cfg(target_os = "macos")]
fn target_satisfies(target: &str, req: &str) -> bool {
    std::process::Command::new("/usr/bin/codesign")
        .args(["--verify", &format!("-R={req}"), target])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// The .app a process runs from, and its name: ".../Vivaldi.app/Contents/MacOS/Vivaldi" -> Vivaldi
fn app_of(exe: &std::path::Path) -> (PathBuf, String) {
    let app = exe.ancestors().find(|p| p.extension().is_some_and(|e| e == "app")).map(PathBuf::from);
    let name = app
        .as_ref()
        .and_then(|a| a.file_stem())
        .or_else(|| exe.file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    (app.unwrap_or_else(|| exe.to_path_buf()), name)
}

/// Identifier, team and signer of a running process, from its code signature.
#[cfg(target_os = "macos")]
fn signature(pid: i32, exe: &std::path::Path) -> Result<BrowserSig, String> {
    let out = std::process::Command::new("/usr/bin/codesign")
        .args(["-dv", "--verbose=2", &pid.to_string()])
        .output()
        .map_err(|e| format!("can't read the browser's signature: {e}"))?;
    let text = String::from_utf8_lossy(&out.stderr);
    let field = |k: &str| text.lines().find_map(|l| l.strip_prefix(k)).map(|v| v.trim().to_string());
    let bundle = field("Identifier=").ok_or("the browser's signature has no identifier")?;
    let team = field("TeamIdentifier=").filter(|t| t != "not set").ok_or("the browser's signature has no team")?;
    let signer = field("Authority=Developer ID Application: ")
        .map(|s| s.trim_end_matches(&format!(" ({team})")).to_string())
        .unwrap_or_else(|| team.clone());
    let (app, name) = app_of(exe);
    Ok(BrowserSig { name, bundle, team, signer, path: app.display().to_string() })
}

/// The bridge must be this very binary, launched directly by a real browser. A process that runs
/// `otto` itself and pretends to be Chrome gets refused, so it can't receive passwords meant for a page.
#[cfg(target_os = "macos")]
pub fn verify_bridge(pid: i32, self_exe: &std::path::Path) -> Result<Verdict, String> {
    let exe = proc_path(pid).ok_or("can't see the bridge process")?;
    let same = |a: &std::path::Path, b: &std::path::Path| a.canonicalize().ok() == b.canonicalize().ok();
    if !same(&exe, self_exe) {
        return Err(format!("bridge is {} instead of otto itself", exe.display()));
    }
    let (ppid, _) = proc_info(pid).ok_or("can't see the bridge's parent")?;
    let parent = proc_path(ppid).ok_or("can't see the browser process")?;
    // test browsers (e.g. Chrome for Testing) can be allowed while developing
    if let Ok(prefix) = std::env::var("OTTO_DEV_BROWSER") {
        if !prefix.is_empty() && parent.starts_with(&prefix) {
            return Ok(Verdict::Trusted(format!("dev browser {}", parent.display())));
        }
    }
    for (bundle, team) in PINNED {
        if satisfies(ppid, &format!(r#"identifier "{bundle}" and anchor apple generic and certificate leaf[subject.OU] = "{team}""#)) {
            return Ok(Verdict::Trusted(app_of(&parent).1));
        }
    }
    if !satisfies(ppid, DEVELOPER_ID) {
        let (app, name) = app_of(&parent);
        if target_satisfies(&app.to_string_lossy(), DEVELOPER_ID) {
            return Ok(Verdict::Outdated(name));
        }
        return Err(format!("{name} isn't from a verified developer, so otto won't trust it with logins"));
    }
    signature(ppid, &parent).map(Verdict::Unknown)
}

#[cfg(target_os = "macos")]
extern "C" {
    fn csops(pid: libc::pid_t, ops: libc::c_uint, useraddr: *mut libc::c_void, usersize: libc::size_t) -> libc::c_int;
}

/// Apple's own code, by the kernel's word: validly signed and part of the OS. (codesign can't check sudo:
/// its file isn't readable by the user.)
#[cfg(target_os = "macos")]
fn platform_binary(pid: i32) -> bool {
    const CS_OPS_STATUS: libc::c_uint = 0;
    const CS_VALID: u32 = 0x1;
    const CS_PLATFORM_BINARY: u32 = 0x0400_0000;
    let mut flags: u32 = 0;
    let r = unsafe { csops(pid, CS_OPS_STATUS, &mut flags as *mut u32 as *mut libc::c_void, 4) };
    r == 0 && flags & CS_VALID != 0 && flags & CS_PLATFORM_BINARY != 0
}

/// `otto sudo` runs Apple's sudo with otto as its askpass helper. The helper asking for the Mac password
/// must be this very binary, started by /usr/bin/sudo itself, so the password can only go into sudo.
/// Returns sudo's pid and the command it's about to run (sudo runs as root, but ps is setuid and can read it).
#[cfg(target_os = "macos")]
pub fn askpass_sudo(pid: i32, self_exe: &std::path::Path) -> Result<(i32, String), String> {
    let exe = proc_path(pid).ok_or("can't see the askpass process")?;
    if exe.canonicalize().ok() != self_exe.canonicalize().ok() {
        return Err(format!("the askpass helper is {} instead of otto itself", exe.display()));
    }
    let (ppid, _) = proc_info(pid).ok_or("can't see the askpass helper's parent")?;
    let parent = proc_path(ppid).ok_or("can't see the askpass helper's parent")?;
    if parent != std::path::Path::new("/usr/bin/sudo") || !platform_binary(ppid) {
        return Err(format!("the Mac password only goes to /usr/bin/sudo, not {}", parent.display()));
    }
    let out = std::process::Command::new("/bin/ps")
        .args(["-ww", "-o", "args=", "-p", &ppid.to_string()])
        .output()
        .map_err(|e| format!("can't read sudo's command: {e}"))?;
    let args = String::from_utf8_lossy(&out.stdout).split_whitespace().collect::<Vec<_>>().join(" ");
    if args.is_empty() {
        return Err("can't read sudo's command".into());
    }
    Ok((ppid, args))
}

#[cfg(not(target_os = "macos"))]
pub fn askpass_sudo(_pid: i32, _self_exe: &std::path::Path) -> Result<(i32, String), String> {
    Err("otto sudo only works on macOS".into())
}

/// Who ran `otto sudo`. The askpass helper's parent is sudo, which runs as root, so its parent (the
/// agent's shell, usually) is read with ps and the agent found from there.
#[cfg(target_os = "macos")]
pub fn behind_sudo(sudo: i32) -> Option<Client> {
    let out = std::process::Command::new("/bin/ps").args(["-o", "ppid=", "-p", &sudo.to_string()]).output().ok()?;
    let ppid: i32 = String::from_utf8_lossy(&out.stdout).trim().parse().ok()?;
    // describe normally passes over its first process (otto itself); here that one already is the caller
    let mut c = describe_from(Some(ppid), 0);
    c.chain.splice(0..0, ["otto".to_string(), "sudo".to_string()]);
    Some(c)
}

#[cfg(not(target_os = "macos"))]
pub fn behind_sudo(_sudo: i32) -> Option<Client> {
    None
}

/// The askpass helper's side of the same check (before it asks the service for anything).
pub fn parent_is_sudo() -> bool {
    let ppid = unsafe { libc::getppid() };
    proc_path(ppid).is_some_and(|p| p == std::path::Path::new("/usr/bin/sudo"))
}

#[cfg(not(target_os = "macos"))]
pub fn verify_bridge(pid: i32, self_exe: &std::path::Path) -> Result<Verdict, String> {
    let exe = proc_path(pid).ok_or("can't see the bridge process")?;
    if exe.canonicalize().ok() != self_exe.canonicalize().ok() {
        return Err("bridge isn't otto itself".into());
    }
    Ok(Verdict::Trusted("browser".into()))
}


#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;

    #[test]
    fn who_is_asking() {
        let mut c = Client::unknown();
        c.agent = "claude".into();
        assert_eq!(c.who(), "an unverified program (claude)");
        c.verified = true;
        assert_eq!(c.who(), "claude");
        c.via = Some("T3 Code".into());
        assert_eq!(c.who(), "claude via T3 Code");
        // a fresh grant per request, not shared with the connection's other requests
        c.granted(Grant::Auto);
        assert_eq!(c.for_request().grant(), None);
        assert_eq!(c.grant(), Some(Grant::Auto));
    }

    #[test]
    fn this_process_has_a_thread_and_a_folder() {
        let c = describe(Some(std::process::id() as i32));
        let (pid, start) = c.thread.split_once(':').unwrap();
        assert!(pid.parse::<i32>().unwrap() > 1 && start.parse::<u64>().unwrap() > 0, "{}", c.thread);
        assert!(c.procs.len() >= 2 && c.procs[0].0 == std::process::id() as i32);
        assert_eq!(proc_cwd(std::process::id() as i32), std::env::current_dir().ok());
        assert_eq!(tilde(&PathBuf::from(std::env::var("HOME").unwrap()).join("otto")), "~/otto");
    }

    #[test]
    fn platform_binaries() {
        assert!(super::platform_binary(1), "launchd is part of the OS");
        assert!(!super::platform_binary(std::process::id() as i32), "this test isn't");
    }
}
