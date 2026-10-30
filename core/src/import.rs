//! Reads 2FA accounts out of authenticator exports: Google Authenticator transfer QR
//! (otpauth-migration://), plain otpauth:// lists (Ente, Aegis/2FAS text), Aegis / 2FAS / Raivo /
//! Bitwarden JSON, and CSVs with an OTP column (Apple Passwords, 1Password, etc). Password manager
//! CSVs (Apple Passwords, Chrome, Firefox, 1Password, Bitwarden, KeePassXC) also give whole logins.

use serde::Serialize;
use serde_json::Value;

use crate::{proto::Fail, totp::Totp, vault::normalize_site};

#[derive(Debug, Clone, Serialize)]
pub struct Token {
    pub issuer: Option<String>,
    pub account: Option<String>,
    /// canonical otpauth://totp URI
    pub uri: String,
    pub site: Option<String>,
    pub username: Option<String>,
}

/// A saved login from a password manager's CSV export, with its 2FA secret if the export has one.
#[derive(Debug, Clone)]
pub struct Login {
    pub name: String,
    pub site: Option<String>,
    pub username: Option<String>,
    pub password: String,
    /// canonical otpauth://totp URI
    pub otp: Option<String>,
    pub notes: Option<String>,
}

pub struct Parsed {
    pub logins: Vec<Login>,
    /// 2FA accounts that aren't part of a login
    pub tokens: Vec<Token>,
}

/// Logins and 2FA accounts in an export. In a password export, rows with a password become logins
/// (carrying their 2FA secret) and rows with only a 2FA secret become codes.
pub fn parse_all(text: &str) -> Result<Parsed, Fail> {
    let t = text.trim_start_matches('\u{feff}').trim();
    if !t.starts_with('{') && !t.starts_with('[') {
        if let Some((logins, mut tokens)) = csv_logins(t) {
            let mut seen = std::collections::HashSet::new();
            tokens.retain(|tok| seen.insert(secret_of(&tok.uri)));
            if logins.is_empty() && tokens.is_empty() {
                return Err(Fail::new("nothing_found", "no logins or 2FA accounts found in this. it needs an unencrypted export"));
            }
            return Ok(Parsed { logins, tokens });
        }
    }
    Ok(Parsed { logins: vec![], tokens: parse(t)? })
}

/// A CSV with a password column: the logins, plus 2FA-only rows as tokens.
fn csv_logins(text: &str) -> Option<(Vec<Login>, Vec<Token>)> {
    let rows = csv(text);
    let header: Vec<String> = rows.first()?.iter().map(|h| h.trim().to_lowercase()).collect();
    let col = |names: &[&str]| header.iter().position(|h| names.contains(&h.as_str()));
    let pw_col = col(&["password", "login_password", "pass"])?;
    let url_col = col(&["url", "website", "login_uri", "urls", "web site", "origin"]);
    let user_col = col(&["username", "user", "login_username", "email", "login", "user name"]);
    let title_col = col(&["title", "name"]);
    let notes_col = col(&["notes", "note", "comments"]);
    let otp_col = header.iter().position(|h| h == "otpauth" || h.contains("otp") || h.contains("one-time"));
    let (mut logins, mut tokens) = (vec![], vec![]);
    let mut seen = std::collections::HashSet::new();
    for r in rows.iter().skip(1) {
        let get = |c: Option<usize>| c.and_then(|c| r.get(c)).map(|s| s.trim()).filter(|s| !s.is_empty()).map(String::from);
        let site = get(url_col).and_then(|u| web_site(&u));
        let username = get(user_col);
        let otp = get(otp_col).and_then(|raw| Totp::parse(&raw).ok());
        let title = get(title_col);
        match get(Some(pw_col)) {
            Some(password) => {
                // the same login listed twice (Chrome keeps one per page it saw)
                if !seen.insert((site.clone(), username.as_ref().map(|u| u.to_lowercase()))) {
                    continue;
                }
                let name = login_name(title.as_deref(), site.as_deref(), username.as_deref());
                logins.push(Login { name, site, username, password, otp: otp.map(|t| t.to_uri()), notes: get(notes_col) });
            }
            None => {
                if let Some(mut t) = otp {
                    if t.issuer.is_none() {
                        t.issuer = title;
                    }
                    if t.account.is_none() {
                        t.account = username.clone();
                    }
                    tokens.push(token(t, site, username));
                }
            }
        }
    }
    Some((logins, tokens))
}

/// The site of a saved login's URL; app logins (android://...) and the like have none.
fn web_site(u: &str) -> Option<String> {
    let scheme = u.split_once("://").map(|(s, _)| s.to_lowercase());
    if scheme.as_deref().is_some_and(|s| s != "http" && s != "https") {
        return None;
    }
    normalize_site(u)
}

/// "GitHub (alfa)" from Apple Passwords -> "GitHub"; no title -> the site.
fn login_name(title: Option<&str>, site: Option<&str>, username: Option<&str>) -> String {
    let mut name = title.unwrap_or("").trim().to_string();
    if let Some(u) = username {
        if let Some(stripped) = name.strip_suffix(&format!(" ({u})")) {
            name = stripped.trim().to_string();
        }
    }
    if !name.contains(' ') && name.contains('.') {
        name = normalize_site(&name).unwrap_or(name);
    }
    if name.is_empty() {
        name = site.unwrap_or("login").to_string();
    }
    name
}

pub fn parse(text: &str) -> Result<Vec<Token>, Fail> {
    let t = text.trim_start_matches('\u{feff}').trim();
    if t.is_empty() {
        return Err(Fail::bad("the file is empty"));
    }
    let mut out = if t.starts_with('{') || t.starts_with('[') {
        let v: Value = serde_json::from_str(t).map_err(|e| Fail::bad(format!("couldn't read this JSON: {e}")))?;
        from_json(&v)?
    } else if let Some(rows) = csv_with_otp(t) {
        rows
    } else {
        from_uris(t)
    };
    // same secret twice (e.g. two exports of one account): keep the first
    let mut seen = std::collections::HashSet::new();
    out.retain(|tok| seen.insert(secret_of(&tok.uri)));
    if out.is_empty() {
        return Err(Fail::new("nothing_found", "no 2FA accounts found in this. it needs an unencrypted export"));
    }
    Ok(out)
}

/// The base32 secret of a canonical URI, for spotting duplicates.
pub fn secret_of(uri: &str) -> String {
    url::Url::parse(uri)
        .ok()
        .and_then(|u| u.query_pairs().find(|(k, _)| k == "secret").map(|(_, v)| v.to_uppercase()))
        .unwrap_or_default()
}

fn token(t: Totp, site: Option<String>, username: Option<String>) -> Token {
    Token { issuer: t.issuer.clone(), account: t.account.clone(), uri: t.to_uri(), site, username }
}

fn from_uris(text: &str) -> Vec<Token> {
    let mut out = vec![];
    for word in text.split(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == ',' || c == '<' || c == '>') {
        let lower = word.to_ascii_lowercase();
        if lower.starts_with("otpauth-migration://") {
            out.extend(google_migration(word).unwrap_or_default());
        } else if lower.starts_with("otpauth://totp") {
            if let Ok(t) = Totp::parse(word) {
                out.push(token(t, None, None));
            }
        }
    }
    out
}

fn from_json(v: &Value) -> Result<Vec<Token>, Fail> {
    let encrypted = || Fail::new("encrypted", "this export is encrypted. export it again without a password (otto keeps it encrypted itself)");
    let mut out = vec![];
    let mk = |secret: &str, issuer: Option<&str>, account: Option<&str>, digits: Option<u64>, period: Option<u64>, algo: Option<&str>| -> Option<Totp> {
        let mut uri = format!("otpauth://totp/x?secret={}", secret.replace(' ', ""));
        if let Some(d) = digits {
            uri.push_str(&format!("&digits={d}"));
        }
        if let Some(p) = period {
            uri.push_str(&format!("&period={p}"));
        }
        if let Some(a) = algo {
            uri.push_str(&format!("&algorithm={a}"));
        }
        let mut t = Totp::parse(&uri).ok()?;
        t.issuer = issuer.filter(|s| !s.is_empty()).map(String::from);
        t.account = account.filter(|s| !s.is_empty()).map(String::from);
        Some(t)
    };
    // Aegis
    if let Some(db) = v.get("db") {
        if db.is_string() {
            return Err(encrypted());
        }
        for e in db["entries"].as_array().into_iter().flatten() {
            if e["type"].as_str().map(|t| t.eq_ignore_ascii_case("totp")) != Some(true) {
                continue;
            }
            let i = &e["info"];
            if let Some(t) = mk(i["secret"].as_str().unwrap_or(""), e["issuer"].as_str(), e["name"].as_str(), i["digits"].as_u64(), i["period"].as_u64(), i["algo"].as_str()) {
                out.push(token(t, None, None));
            }
        }
        return Ok(out);
    }
    // 2FAS
    if v.get("services").is_some() || v.get("servicesEncrypted").is_some() {
        if v.get("servicesEncrypted").map(|s| !s.is_null()).unwrap_or(false) && v["services"].as_array().map(|a| a.is_empty()).unwrap_or(true) {
            return Err(encrypted());
        }
        for s in v["services"].as_array().into_iter().flatten() {
            let o = &s["otp"];
            if o["tokenType"].as_str().map(|t| !t.eq_ignore_ascii_case("totp")).unwrap_or(false) {
                continue;
            }
            let issuer = o["issuer"].as_str().filter(|x| !x.is_empty()).or(s["name"].as_str());
            if let Some(t) = mk(s["secret"].as_str().unwrap_or(""), issuer, o["account"].as_str(), o["digits"].as_u64(), o["period"].as_u64(), o["algorithm"].as_str()) {
                out.push(token(t, None, None));
            }
        }
        return Ok(out);
    }
    // Bitwarden
    if let Some(items) = v.get("items") {
        if v["encrypted"].as_bool() == Some(true) {
            return Err(encrypted());
        }
        for it in items.as_array().into_iter().flatten() {
            let login = &it["login"];
            let Some(raw) = login["totp"].as_str().filter(|s| !s.is_empty()) else { continue };
            let Ok(mut t) = Totp::parse(raw) else { continue };
            if t.issuer.is_none() {
                t.issuer = it["name"].as_str().map(String::from);
            }
            let username = login["username"].as_str().filter(|s| !s.is_empty()).map(String::from);
            if t.account.is_none() {
                t.account = username.clone();
            }
            let site = login["uris"].as_array().and_then(|u| u.first()).and_then(|u| u["uri"].as_str()).and_then(normalize_site);
            out.push(token(t, site, username));
        }
        return Ok(out);
    }
    // Raivo, or any array of {issuer, account, secret}
    if let Some(arr) = v.as_array() {
        for e in arr {
            if e["kind"].as_str().map(|k| !k.eq_ignore_ascii_case("totp")).unwrap_or(false) {
                continue;
            }
            let digits = e["digits"].as_u64().or_else(|| e["digits"].as_str().and_then(|s| s.parse().ok()));
            let period = e["timer"].as_u64().or_else(|| e["timer"].as_str().and_then(|s| s.parse().ok())).or(e["period"].as_u64());
            if let Some(t) = mk(e["secret"].as_str().unwrap_or(""), e["issuer"].as_str(), e["account"].as_str(), digits, period, e["algorithm"].as_str()) {
                out.push(token(t, None, None));
            }
        }
        return Ok(out);
    }
    Ok(from_uris(&v.to_string()))
}

/// Apple Passwords exports `Title,URL,Username,Password,Notes,OTPAuth`; other managers use similar headers.
fn csv_with_otp(text: &str) -> Option<Vec<Token>> {
    let rows = csv(text);
    let header: Vec<String> = rows.first()?.iter().map(|h| h.trim().to_lowercase()).collect();
    if header.len() < 2 || header.iter().any(|h| h.contains("://")) {
        return None;
    }
    let otp_col = header.iter().position(|h| h == "otpauth" || h.contains("otp") || h.contains("totp") || h.contains("one-time"))?;
    let col = |names: &[&str]| header.iter().position(|h| names.contains(&h.as_str()));
    let (url_col, user_col, title_col) = (col(&["url", "website", "login_uri", "urls"]), col(&["username", "user", "login_username", "email"]), col(&["title", "name"]));
    let mut out = vec![];
    for r in rows.iter().skip(1) {
        let get = |c: Option<usize>| c.and_then(|c| r.get(c)).map(|s| s.trim()).filter(|s| !s.is_empty()).map(String::from);
        let Some(raw) = get(Some(otp_col)) else { continue };
        let Ok(mut t) = Totp::parse(&raw) else { continue };
        let username = get(user_col);
        if t.issuer.is_none() {
            t.issuer = get(title_col);
        }
        if t.account.is_none() {
            t.account = username.clone();
        }
        out.push(token(t, get(url_col).and_then(|u| normalize_site(&u)), username));
    }
    Some(out)
}

fn csv(text: &str) -> Vec<Vec<String>> {
    let mut rows = vec![];
    let mut row = vec![];
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        match (c, quoted) {
            ('"', true) if chars.peek() == Some(&'"') => {
                field.push('"');
                chars.next();
            }
            ('"', true) => quoted = false,
            ('"', false) if field.is_empty() => quoted = true,
            (',', false) => row.push(std::mem::take(&mut field)),
            ('\n', false) => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            ('\r', false) => {}
            (c, _) => field.push(c),
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

/// Google Authenticator "Transfer accounts" QR: otpauth-migration://offline?data=<base64 protobuf>.
fn google_migration(uri: &str) -> Option<Vec<Token>> {
    let u = url::Url::parse(uri).ok()?;
    let data = u.query_pairs().find(|(k, _)| k == "data")?.1.replace(' ', "+");
    let bytes = data_encoding::BASE64.decode(data.as_bytes()).or_else(|_| data_encoding::BASE64_NOPAD.decode(data.trim_end_matches('=').as_bytes())).ok()?;
    let mut out = vec![];
    for (field, val) in proto_fields(&bytes) {
        if field != 1 {
            continue;
        }
        let ProtoVal::Bytes(p) = val else { continue };
        let (mut secret, mut name, mut issuer, mut algo, mut digits, mut kind) = (vec![], String::new(), String::new(), 1u64, 1u64, 2u64);
        for (f, v) in proto_fields(&p) {
            match (f, v) {
                (1, ProtoVal::Bytes(b)) => secret = b,
                (2, ProtoVal::Bytes(b)) => name = String::from_utf8_lossy(&b).into_owned(),
                (3, ProtoVal::Bytes(b)) => issuer = String::from_utf8_lossy(&b).into_owned(),
                (4, ProtoVal::Int(n)) => algo = n,
                (5, ProtoVal::Int(n)) => digits = n,
                (6, ProtoVal::Int(n)) => kind = n,
                _ => {}
            }
        }
        if kind == 1 || secret.is_empty() {
            continue; // counter-based codes aren't supported
        }
        let account = match name.split_once(':') {
            Some((i, a)) if issuer.is_empty() || i == issuer => a.trim().to_string(),
            _ => name.clone(),
        };
        let algo = match algo {
            2 => "SHA256",
            3 => "SHA512",
            _ => "SHA1",
        };
        let uri = format!(
            "otpauth://totp/x?secret={}&digits={}&algorithm={algo}",
            data_encoding::BASE32_NOPAD.encode(&secret),
            if digits == 2 { 8 } else { 6 }
        );
        if let Ok(mut t) = Totp::parse(&uri) {
            t.issuer = (!issuer.is_empty()).then_some(issuer);
            t.account = (!account.is_empty()).then_some(account);
            out.push(token(t, None, None));
        }
    }
    Some(out)
}

enum ProtoVal {
    Int(u64),
    Bytes(Vec<u8>),
}

fn proto_fields(mut b: &[u8]) -> Vec<(u64, ProtoVal)> {
    fn varint(b: &mut &[u8]) -> Option<u64> {
        let mut v = 0u64;
        for i in 0..10 {
            let (&byte, rest) = b.split_first()?;
            *b = rest;
            v |= ((byte & 0x7f) as u64) << (7 * i);
            if byte & 0x80 == 0 {
                return Some(v);
            }
        }
        None
    }
    let mut out = vec![];
    while !b.is_empty() {
        let Some(tag) = varint(&mut b) else { break };
        let (field, wire) = (tag >> 3, tag & 7);
        match wire {
            0 => match varint(&mut b) {
                Some(v) => out.push((field, ProtoVal::Int(v))),
                None => break,
            },
            2 => {
                let Some(len) = varint(&mut b) else { break };
                let len = len as usize;
                if len > b.len() {
                    break;
                }
                out.push((field, ProtoVal::Bytes(b[..len].to_vec())));
                b = &b[len..];
            }
            1 if b.len() >= 8 => b = &b[8..],
            5 if b.len() >= 4 => b = &b[4..],
            _ => break,
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn google_authenticator_transfer_qr() {
        // payload with one TOTP account: secret "Hello!" (JBSWY3DPEE), name "alice@example.com", issuer "Example"
        let mut p = vec![0x0a, 0x06];
        p.extend_from_slice(b"Hello!");
        p.extend_from_slice(&[0x12, 17]);
        p.extend_from_slice(b"alice@example.com");
        p.extend_from_slice(&[0x1a, 7]);
        p.extend_from_slice(b"Example");
        p.extend_from_slice(&[0x20, 1, 0x28, 1, 0x30, 2]);
        let mut payload = vec![0x0a, p.len() as u8];
        payload.extend(p);
        payload.extend_from_slice(&[0x10, 1]);
        let b64 = data_encoding::BASE64.encode(&payload);
        let uri = format!("otpauth-migration://offline?data={}", b64.replace('+', "%2B").replace('/', "%2F").replace('=', "%3D"));
        let toks = parse(&uri).unwrap();
        assert_eq!(toks.len(), 1);
        assert_eq!(toks[0].issuer.as_deref(), Some("Example"));
        assert_eq!(toks[0].account.as_deref(), Some("alice@example.com"));
        assert_eq!(secret_of(&toks[0].uri), "JBSWY3DPEE");
    }

    #[test]
    fn apple_passwords_csv_and_aegis() {
        let csv = "Title,URL,Username,Password,Notes,OTPAuth\n\"GitHub (alfa)\",https://github.com/login,alfa,pw,,\"otpauth://totp/GitHub:alfa?secret=JBSWY3DPEHPK3PXP&issuer=GitHub\"\nNo 2FA,https://x.com,me,pw,,\n";
        let t = parse(csv).unwrap();
        assert_eq!(t.len(), 1);
        assert_eq!(t[0].site.as_deref(), Some("github.com"));
        assert_eq!(t[0].issuer.as_deref(), Some("GitHub"));
        let aegis = r#"{"version":1,"db":{"version":2,"entries":[{"type":"totp","name":"me@x.com","issuer":"Proton","info":{"secret":"JBSWY3DPEHPK3PXP","algo":"SHA1","digits":6,"period":30}}]}}"#;
        let t = parse(aegis).unwrap();
        assert_eq!(t[0].issuer.as_deref(), Some("Proton"));
        assert!(parse(r#"{"version":1,"db":"base64stuff"}"#).is_err());
    }

    #[test]
    fn password_exports() {
        // Apple Passwords: the login keeps its 2FA secret, a row without a password is just a code
        let apple = "Title,URL,Username,Password,Notes,OTPAuth\n\"github.com (alfa)\",https://github.com/login,alfa,pw1,,\"otpauth://totp/GitHub:alfa?secret=JBSWY3DPEHPK3PXP&issuer=GitHub\"\nBank,https://www.bank.com.tr/,me,pw2,\"pin, 1234\",\nDiscord,,,,,otpauth://totp/Discord:me?secret=GEZDGNBVGY3TQOJQ\n";
        let p = parse_all(apple).unwrap();
        assert_eq!(p.logins.len(), 2);
        assert_eq!(p.logins[0].name, "github.com");
        assert_eq!(p.logins[0].site.as_deref(), Some("github.com"));
        assert!(p.logins[0].otp.is_some());
        assert_eq!(p.logins[1].site.as_deref(), Some("bank.com.tr"));
        assert_eq!(p.logins[1].notes.as_deref(), Some("pin, 1234"));
        assert_eq!(p.tokens.len(), 1);
        assert_eq!(p.tokens[0].issuer.as_deref(), Some("Discord"));
        // Chrome: one row per page it saw; android apps have no website
        let chrome = "name,url,username,password,note\ngithub.com,https://github.com/login,alfa,pw,\ngithub.com,https://github.com/session,alfa,pw,\nApp,android://abc@com.example/,me,pw,\n";
        let p = parse_all(chrome).unwrap();
        assert_eq!(p.logins.len(), 2);
        assert_eq!(p.logins[1].site, None);
        // Bitwarden
        let bw = "folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,Vercel,,,0,https://vercel.com/login,me@x.com,pw,JBSWY3DPEHPK3PXP\n";
        let p = parse_all(bw).unwrap();
        assert_eq!(p.logins[0].name, "Vercel");
        assert!(p.logins[0].otp.as_deref().unwrap().starts_with("otpauth://totp/"));
        // authenticator exports still come through as codes
        assert_eq!(parse_all("otpauth://totp/X:me?secret=JBSWY3DPEHPK3PXP").unwrap().tokens.len(), 1);
    }
}
