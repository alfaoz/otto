//! Remote: an agent can give the user a link to save a login or approve a use from their phone when
//! they're away from the Mac. otto serves a small page on the Mac's Tailscale address, and only to
//! devices on the user's own Tailscale account (never this Mac itself). A device pairs once with the
//! PIN the user set at the Mac; saving needs a paired device, approving needs one and the PIN, each time.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    io::Read,
    net::IpAddr,
    path::PathBuf,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

/// "otto" on a phone keypad
pub const DEFAULT_PORT: u16 = 6886;
/// wrong PINs in a row before remote turns itself off
pub const MAX_TRIES: u32 = 5;

pub fn port() -> u16 {
    std::env::var("OTTO_REMOTE_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(DEFAULT_PORT)
}

/// What the vault keeps about remote (in the root group's custom data, so it's encrypted with the rest).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Conf {
    #[serde(default)]
    pub pin: Option<PinHash>,
    #[serde(default)]
    pub devices: Vec<Device>,
    /// wrong PINs since the last right one
    #[serde(default)]
    pub failures: u32,
    /// off after too many wrong PINs, until the user sets the PIN again at the Mac
    #[serde(default)]
    pub locked: bool,
}

impl Conf {
    pub fn on(&self) -> bool {
        self.pin.is_some() && !self.locked
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PinHash {
    pub salt: String,
    pub hash: String,
}

/// A phone (or other device) the user paired by typing the PIN on it.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Device {
    pub id: String,
    /// sha256 of the key in the device's cookie (the key itself only lives there)
    pub key: String,
    /// the Tailscale node that paired it: the cookie only counts from there
    pub node: String,
    pub name: String,
    pub os: String,
    pub paired: String,
}

pub fn valid_pin(pin: &str) -> bool {
    pin.len() == 6 && pin.bytes().all(|b| b.is_ascii_digit())
}

fn argon() -> argon2::Config<'static> {
    argon2::Config { variant: argon2::Variant::Argon2id, hash_length: 32, ..argon2::Config::default() }
}

pub fn hash_pin(pin: &str) -> PinHash {
    let salt = random(16);
    let hash = argon2::hash_raw(pin.as_bytes(), &salt, &argon()).unwrap_or_default();
    PinHash { salt: hex(&salt), hash: hex(&hash) }
}

pub fn check_pin(pin: &str, h: &PinHash) -> bool {
    let (Ok(salt), Ok(hash)) = (unhex(&h.salt), unhex(&h.hash)) else { return false };
    argon2::verify_raw(pin.as_bytes(), &salt, &hash, &argon()).unwrap_or(false)
}

pub fn random(n: usize) -> Vec<u8> {
    let mut b = vec![0u8; n];
    std::fs::File::open("/dev/urandom").and_then(|mut f| f.read_exact(&mut b)).expect("reading /dev/urandom");
    b
}

/// A request's id, which is also the capability in its link.
pub fn new_id() -> String {
    data_encoding::BASE32_NOPAD.encode(&random(15)).to_lowercase()
}

pub fn hex(b: &[u8]) -> String {
    data_encoding::HEXLOWER.encode(b)
}

fn unhex(s: &str) -> Result<Vec<u8>, data_encoding::DecodeError> {
    data_encoding::HEXLOWER.decode(s.as_bytes())
}

pub fn sha256_hex(s: &str) -> String {
    use sha2::Digest;
    hex(&sha2::Sha256::digest(s.as_bytes()))
}

// ---- tailscale ------------------------------------------------------------------------

/// This Mac on Tailscale.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Tailnet {
    /// running, stopped, missing (not installed) or error
    pub state: String,
    pub ip: Option<IpAddr>,
    /// this Mac's stable node id
    pub node: String,
    /// the Tailscale user this Mac belongs to
    pub user: String,
    pub error: Option<String>,
}

/// Who's on the other end of a connection, according to Tailscale.
#[derive(Debug, Clone, PartialEq)]
pub struct Peer {
    pub node: String,
    pub user: String,
    pub tagged: bool,
    pub name: String,
    pub os: String,
}

/// The tailscale command line: the Mac app ships one inside its bundle. Tests point OTTO_TAILSCALE at
/// a stand-in, only for a throwaway vault.
fn cli() -> Option<PathBuf> {
    if std::env::var_os("OTTO_HOME").is_some() {
        if let Some(p) = std::env::var_os("OTTO_TAILSCALE") {
            return Some(p.into());
        }
    }
    ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/usr/bin/tailscale"]
        .iter()
        .map(PathBuf::from)
        .find(|p| p.exists())
}

async fn tailscale(args: &[&str]) -> Result<Value, String> {
    let exe = cli().ok_or("Tailscale isn't installed")?;
    let out = tokio::time::timeout(Duration::from_secs(5), tokio::process::Command::new(exe).args(args).kill_on_drop(true).output())
        .await
        .map_err(|_| "tailscale didn't answer".to_string())?
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(err.lines().next().unwrap_or("tailscale failed").trim().to_string());
    }
    serde_json::from_slice(&out.stdout).map_err(|e| format!("tailscale said something otto can't read: {e}"))
}

pub async fn tailnet() -> Tailnet {
    if cli().is_none() {
        return Tailnet { state: "missing".into(), ..Default::default() };
    }
    match tailscale(&["status", "--json"]).await {
        Err(e) => Tailnet { state: "stopped".into(), error: Some(e), ..Default::default() },
        Ok(v) => {
            let me = &v["Self"];
            let ip = me["TailscaleIPs"].as_array().into_iter().flatten().filter_map(|i| i.as_str()?.parse::<IpAddr>().ok()).find(IpAddr::is_ipv4);
            let running = v["BackendState"] == "Running" && ip.is_some();
            Tailnet {
                state: if running { "running" } else { "stopped" }.into(),
                ip: ip.filter(|_| running),
                node: me["ID"].as_str().unwrap_or_default().to_string(),
                user: id_str(&me["UserID"]),
                error: None,
            }
        }
    }
}

pub async fn whois(ip: IpAddr) -> Result<Peer, String> {
    let v = tailscale(&["whois", "--json", &ip.to_string()]).await?;
    let n = &v["Node"];
    let first_label = n["Name"].as_str().and_then(|s| s.split('.').next()).filter(|s| !s.is_empty());
    let name = n["ComputedName"].as_str().filter(|s| !s.is_empty()).or(first_label).or(n["Hostinfo"]["Hostname"].as_str()).unwrap_or("a device");
    Ok(Peer {
        node: n["StableID"].as_str().unwrap_or_default().to_string(),
        user: id_str(&n["User"]),
        tagged: n["Tags"].as_array().is_some_and(|t| !t.is_empty()),
        name: name.to_string(),
        os: n["Hostinfo"]["OS"].as_str().unwrap_or_default().to_string(),
    })
}

/// Tailscale's ids come as numbers or strings.
fn id_str(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => String::new(),
    }
}

// ---- http -----------------------------------------------------------------------------

pub struct HttpReq {
    pub method: String,
    pub path: String,
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

impl HttpReq {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.get(name).map(String::as_str)
    }

    pub fn cookie(&self, name: &str) -> Option<&str> {
        self.header("cookie")?.split(';').filter_map(|c| c.trim().split_once('=')).find(|(k, _)| *k == name).map(|(_, v)| v)
    }
}

pub struct HttpRes {
    pub status: u16,
    pub kind: &'static str,
    pub body: Vec<u8>,
    pub cookie: Option<String>,
}

impl HttpRes {
    pub fn json(status: u16, v: &Value) -> HttpRes {
        HttpRes { status, kind: "application/json", body: v.to_string().into_bytes(), cookie: None }
    }

    pub fn fail(status: u16, code: &str, message: impl Into<String>) -> HttpRes {
        HttpRes::json(status, &serde_json::json!({ "error": code, "message": message.into() }))
    }
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

/// One request, small and complete or nothing: headers up to 16 KB, a body up to 64 KB.
pub async fn read_req(s: &mut TcpStream) -> Option<HttpReq> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let end = loop {
        if let Some(i) = find(&buf, b"\r\n\r\n") {
            break i;
        }
        if buf.len() > 16 * 1024 {
            return None;
        }
        let n = s.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
    };
    let head = std::str::from_utf8(&buf[..end]).ok()?;
    let mut lines = head.split("\r\n");
    let mut first = lines.next()?.split(' ');
    let method = first.next()?.to_string();
    let target = first.next()?;
    let path = target.split(['?', '#']).next().unwrap_or("/").to_string();
    let headers: HashMap<String, String> = lines.filter_map(|l| l.split_once(':')).map(|(k, v)| (k.trim().to_ascii_lowercase(), v.trim().to_string())).collect();
    let len: usize = headers.get("content-length").and_then(|l| l.parse().ok()).unwrap_or(0);
    if len > 64 * 1024 {
        return None;
    }
    let mut body = buf[end + 4..].to_vec();
    while body.len() < len {
        let n = s.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(len);
    Some(HttpReq { method, path, headers, body })
}

pub async fn write_res(s: &mut TcpStream, r: HttpRes) {
    let reason = match r.status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        410 => "Gone",
        421 => "Misdirected Request",
        423 => "Locked",
        _ => "Error",
    };
    let mut head = format!(
        "HTTP/1.1 {} {reason}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\nCache-Control: no-store\r\n\
         Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; manifest-src 'self'; form-action 'none'; frame-ancestors 'none'; base-uri 'none'\r\n\
         Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\n",
        r.status,
        r.kind,
        r.body.len()
    );
    if let Some(c) = &r.cookie {
        head.push_str(&format!("Set-Cookie: {c}\r\n"));
    }
    head.push_str("\r\n");
    let _ = s.write_all(head.as_bytes()).await;
    let _ = s.write_all(&r.body).await;
    let _ = s.flush().await;
    let _ = s.shutdown().await;
}

/// The page's own files, built into the binary.
pub fn asset(path: &str) -> Option<HttpRes> {
    let path = if path.len() > 1 { path.trim_end_matches('/') } else { path };
    let (kind, body): (&'static str, &'static [u8]) = match path {
        "/" | "/index.html" => ("text/html; charset=utf-8", include_bytes!("remote/page.html")),
        p if p.starts_with("/r/") && !p[3..].contains('/') => ("text/html; charset=utf-8", include_bytes!("remote/page.html")),
        "/app.css" => ("text/css; charset=utf-8", include_bytes!("remote/app.css")),
        "/app.js" => ("text/javascript; charset=utf-8", include_bytes!("remote/app.js")),
        "/icon.svg" => ("image/svg+xml", include_bytes!("remote/icon.svg")),
        "/touch-icon.png" | "/apple-touch-icon.png" => ("image/png", include_bytes!("remote/touch-icon.png")),
        _ => return None,
    };
    Some(HttpRes { status: 200, kind, body: body.to_vec(), cookie: None })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pins_hash_and_check() {
        assert!(valid_pin("012345") && !valid_pin("12345") && !valid_pin("12345a") && !valid_pin("1234567"));
        let h = hash_pin("482913");
        assert!(check_pin("482913", &h));
        assert!(!check_pin("482914", &h));
        // a fresh salt each time
        assert_ne!(hash_pin("482913").hash, h.hash);
    }

    #[test]
    fn ids_are_long_and_url_safe() {
        let id = new_id();
        assert_eq!(id.len(), 24);
        assert!(id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit()));
        assert_ne!(new_id(), id);
    }
}
