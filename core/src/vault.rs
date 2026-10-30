//! The vault is a standard KeePass (KDBX4) file. otto keeps its own settings per entry in
//! `otto.*` fields, so the same file still opens in KeePassXC, Strongbox or KeePassium.

use anyhow::{Context, Result};
use hmac::{Hmac, Mac};
use keepass::{
    config::{DatabaseConfig, KdfConfig},
    db::{fields, EntryId, EntryRef, GroupId},
    Database, DatabaseKey,
};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use std::{
    collections::{BTreeMap, HashSet},
    fs,
    io::Write,
    path::{Path, PathBuf},
};

use crate::{proto::Fail, totp::Totp};

const F_SITES: &str = "otto.sites";
const F_APPS: &str = "otto.apps";
const F_POLICY: &str = "otto.policy";
const F_SCRIPTS: &str = "otto.scripts";
/// the user doesn't want a notification when agents use this entry without asking
const F_QUIET: &str = "otto.quiet";
/// optional limits the user set: only agents working in these folders ("~/otto") may use the entry...
const F_FOLDERS: &str = "otto.folders";
/// ...and only these agents ("claude", "codex"). Empty: no limit.
const F_AGENTS: &str = "otto.agents";
/// an imported authenticator account that isn't attached to a login yet (private to the user)
const F_LIBRARY: &str = "otto.library";
/// how the site does 2FA when there's no authenticator secret: "delivered" (SMS/email) or "none"
const F_2FA: &str = "otto.2fa";
/// the user's sealed yes to bypass for this entry (a `Consent` as JSON)
const F_BYPASS: &str = "otto.bypass";
/// what the entry is: absent for a login, else one of KINDS
const F_KIND: &str = "otto.kind";
/// card: cardholder, number, expiry (MM/YY), cvc, postal_code; key: key; Mac password: password; value: value
pub const KINDS: &[&str] = &["login", "card", "key", "note", "mac", "value"];
/// a value kept out of sight ("1"): it then only comes back for the commands in F_COMMANDS
const F_SECRET: &str = "otto.secret";
/// a secret value: the exact commands it comes back for, as a JSON list
const F_COMMANDS: &str = "otto.commands";
/// browsers the user allowed (beyond the ones otto pins), in the root group's custom data
const D_BROWSERS: &str = "otto.browsers";
/// remote: the PIN's hash and the paired devices (see remote.rs), in the root group's custom data
const D_REMOTE: &str = "otto.remote";
const D_WAITS: &str = "otto.waits";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Policy {
    /// agents use it without asking
    Auto,
    /// every use needs Touch ID (remembered for a few minutes)
    Ask,
    /// agents can't see or use it
    Never,
}

impl Policy {
    fn parse(s: Option<&str>) -> Policy {
        match s {
            Some("auto") => Policy::Auto,
            Some("never") => Policy::Never,
            _ => Policy::Ask,
        }
    }
    pub fn as_str(self) -> &'static str {
        match self {
            Policy::Auto => "auto",
            Policy::Ask => "ask",
            Policy::Never => "never",
        }
    }
}

/// The user's yes to bypass for one entry: in the app they ticked `statement` and confirmed with
/// `auth` (Touch ID). Bypass means agents use the entry without asking, on any site or app.
/// The record is sealed with a key derived from the vault key, so something without that key (an
/// agent, a hand-edited log line) can't make one, change one, or move one to another entry.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Consent {
    /// the entry's uuid: the seal only fits this entry
    pub entry: String,
    /// its name when the user said yes
    pub name: String,
    pub at: String,
    /// when it ends by itself; None: when the user turns it off
    #[serde(default)]
    pub until: Option<String>,
    /// how the user confirmed: "touch_id", or "password" on a Mac without Touch ID
    pub auth: String,
    /// the sentence the user ticked
    pub statement: String,
    /// the agent that asked for it from the chat, if one did
    #[serde(default)]
    pub asked_by: Option<String>,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub seal: String,
}

impl Consent {
    fn expired(&self) -> bool {
        self.until.as_deref().is_some_and(|u| chrono::DateTime::parse_from_rfc3339(u).map_or(true, |t| t <= chrono::Utc::now()))
    }

    /// what the seal covers: every field but the seal, in a fixed order
    fn sealed_bytes(&self) -> Vec<u8> {
        let mut c = self.clone();
        c.seal = String::new();
        let mut b = b"otto.bypass.v1\n".to_vec();
        b.extend(serde_json::to_vec(&c).unwrap_or_default());
        b
    }
}

/// What can be shown about a card without its secrets.
#[derive(Debug, Clone, Serialize)]
pub struct CardInfo {
    pub brand: String,
    pub last4: String,
    /// MM/YY
    pub expiry: Option<String>,
}

/// "4242 4242 4242 4242" -> Visa
pub fn card_brand(number: &str) -> &'static str {
    let d: String = number.chars().filter(|c| c.is_ascii_digit()).collect();
    let p = |n: usize| d.get(..n).and_then(|s| s.parse::<u32>().ok()).unwrap_or(0);
    match () {
        _ if d.starts_with('4') => "Visa",
        _ if (51..=55).contains(&p(2)) || (2221..=2720).contains(&p(4)) => "Mastercard",
        _ if p(2) == 34 || p(2) == 37 => "American Express",
        _ if d.starts_with("9792") => "Troy",
        _ if d.starts_with("6011") || d.starts_with("65") || (644..=649).contains(&p(3)) => "Discover",
        _ if (3528..=3589).contains(&p(4)) => "JCB",
        _ if d.starts_with("62") => "UnionPay",
        _ if (300..=305).contains(&p(3)) || p(2) == 36 || p(2) == 38 => "Diners Club",
        _ => "Card",
    }
}

/// "08/28", "8/2028", "0828", "08 / 28" -> (8, 2028)
pub fn parse_expiry(s: &str) -> Option<(u32, u32)> {
    let d: Vec<&str> = s.split(|c: char| !c.is_ascii_digit()).filter(|p| !p.is_empty()).collect();
    let (m, y) = match d.as_slice() {
        [m, y] => (m.parse().ok()?, y.parse::<u32>().ok()?),
        [my] if my.len() == 4 || my.len() == 6 => (my[..2].parse().ok()?, my[2..].parse().ok()?),
        _ => return None,
    };
    let y = if y < 100 { 2000 + y } else { y };
    ((1..=12).contains(&m) && (2000..2100).contains(&y)).then_some((m, y))
}

/// The value an entry is mostly for: what `otto run --env VAR=entry` hands over without a field.
pub fn main_field(kind: &str) -> &'static str {
    match kind {
        "card" => "number",
        "key" => "key",
        "note" => "notes",
        "value" => "value",
        _ => "password",
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct TotpInfo {
    pub issuer: Option<String>,
    pub account: Option<String>,
    pub digits: u32,
    pub period: u64,
}

/// Everything about an entry except its secret values.
#[derive(Debug, Clone, Serialize)]
pub struct EntryInfo {
    pub id: String,
    pub name: String,
    /// login, card, key, note, mac (the Mac's password, for sudo), value (for commands' blanks)
    pub kind: String,
    pub card: Option<CardInfo>,
    pub username: Option<String>,
    pub sites: Vec<String>,
    pub apps: Vec<String>,
    /// only for agents working in these folders (and below); empty: any folder
    pub folders: Vec<String>,
    /// only for these (verified) agents; empty: any agent
    pub agents: Vec<String>,
    /// for the caller it was looked up for: outside those limits (so it's "never" to it)
    #[serde(skip)]
    pub out_of_scope: bool,
    pub policy: Policy,
    pub scripts: bool,
    pub quiet: bool,
    pub has_password: bool,
    pub totp: Option<TotpInfo>,
    /// names of extra fields (api keys, recovery codes...)
    pub fields: Vec<String>,
    pub library: bool,
    /// "app" (otto has the secret), "delivered" (SMS/email, ask the user), "none", or unknown
    pub two_factor: Option<String>,
    pub modified: Option<String>,
    /// set while bypass is on: the user's sealed consent (checked against the vault key, not expired)
    pub bypass: Option<Consent>,
    /// a value: kept out of sight, and then only for `commands`
    pub secret: bool,
    pub commands: Vec<String>,
    /// a value that isn't secret, as it is, for the app. `public` doesn't pass it on to agents
    pub value: Option<String>,
}

impl EntryInfo {
    /// invisible to agents: "never", unless the user turned on bypass for it
    pub fn hidden(&self) -> bool {
        self.policy == Policy::Never && self.bypass.is_none()
    }

    /// what agents are told: bypass, or the entry's policy
    pub fn access(&self) -> &'static str {
        if self.bypass.is_some() {
            "bypass"
        } else {
            self.policy.as_str()
        }
    }
}

/// A create/update from the app or an agent. `None` leaves a value alone, `Some("")` clears it.
#[derive(Debug, Default, Clone, Deserialize)]
pub struct EntryPatch {
    pub id: Option<String>,
    pub name: Option<String>,
    /// one of KINDS; "login" clears it
    pub kind: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub otp: Option<String>,
    pub sites: Option<Vec<String>>,
    pub apps: Option<Vec<String>>,
    pub folders: Option<Vec<String>>,
    pub agents: Option<Vec<String>>,
    pub policy: Option<Policy>,
    pub scripts: Option<bool>,
    pub quiet: Option<bool>,
    pub notes: Option<String>,
    /// extra fields; an empty value removes the field
    pub fields: Option<BTreeMap<String, String>>,
    pub library: Option<bool>,
    /// "delivered" or "none" (an authenticator secret goes in `otp`); "" clears it
    pub two_factor: Option<String>,
    /// take the 2FA secret from this (library) entry, which is then removed
    pub otp_from: Option<String>,
    /// a value: see `EntryInfo`
    pub secret: Option<bool>,
    pub commands: Option<Vec<String>>,
}

pub struct Vault {
    path: PathBuf,
    password: String,
    db: Database,
    /// seals bypass consents; derived from the vault key, so only whoever holds that can make one
    seal_key: [u8; 32],
    /// the file as otto last read or wrote it, to notice another program writing it (KeePassXC, a sync)
    seen: Option<Stamp>,
}

/// A file's modification time and length.
type Stamp = (std::time::SystemTime, u64);

fn stamp(path: &Path) -> Option<Stamp> {
    let m = fs::metadata(path).ok()?;
    Some((m.modified().ok()?, m.len()))
}

/// Hourly copies of the vault are kept this long; after that, the first of each day...
const HOURLY_DAYS: i64 = 2;
/// ...for this long.
const DAILY_DAYS: i64 = 60;
/// Deleted entries stay in the trash this long.
pub const TRASH_DAYS: i64 = 30;

/// A deleted entry, in the trash until it's restored, deleted for good, or old enough to go.
#[derive(Debug, Clone, Serialize)]
pub struct Trashed {
    #[serde(flatten)]
    pub entry: EntryInfo,
    pub deleted: Option<String>,
}

/// How long otto waits for the user, in seconds, as set in Settings. In the vault, so nothing without the
/// key can change it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Waits {
    /// a command with blanks to fill in: the user may have to go and find what goes in them
    pub blanks: u64,
    pub save: u64,
    /// a command, a change to a secret, a new site, bypass
    pub approve: u64,
    pub mac_password: u64,
    pub browser: u64,
    /// the links an agent sends to the user's phone
    pub phone: u64,
}

impl Default for Waits {
    fn default() -> Self {
        Waits { blanks: 900, save: 900, approve: 300, mac_password: 270, browser: 180, phone: 900 }
    }
}

impl Waits {
    pub fn check(&self) -> Result<(), Fail> {
        let all = [self.blanks, self.save, self.approve, self.mac_password, self.browser, self.phone];
        if all.iter().any(|w| !(30..=3600).contains(w)) {
            return Err(Fail::bad("a wait is between 30 seconds and an hour"));
        }
        Ok(())
    }
}

/// A value the user keeps for commands' blanks (an entry of kind "value"), with what's in it.
#[derive(Debug, Clone, PartialEq)]
pub struct Remembered {
    pub id: String,
    pub name: String,
    /// comes back only for `commands`, exactly as written; anything else comes back by name
    pub secret: bool,
    pub commands: Vec<String>,
    pub value: String,
    /// set to Never: it doesn't come back at all
    pub off: bool,
}

/// `{{name}}` in a command, whatever the case of the name.
fn has_blank(command: &str, name: &str) -> bool {
    command.to_ascii_lowercase().contains(&format!("{{{{{}}}}}", name.to_ascii_lowercase()))
}

/// The command with its `{{old}}` blank called `{{new}}`.
fn rename_blank(command: &str, old: &str, new: &str) -> String {
    let hay = command.to_ascii_lowercase();
    let mark = format!("{{{{{}}}}}", old.to_ascii_lowercase());
    let (mut out, mut at) = (String::new(), 0);
    while let Some(i) = hay[at..].find(&mark) {
        out += &command[at..at + i];
        out += &format!("{{{{{new}}}}}");
        at += i + mark.len();
    }
    out + &command[at..]
}

/// A copy of the vault in `backups/`.
#[derive(Debug, Clone, Serialize)]
pub struct Backup {
    pub name: String,
    pub at: String,
    pub size: u64,
}

fn seal_key(password: &str) -> [u8; 32] {
    let mut m = <Hmac<Sha256>>::new_from_slice(password.as_bytes()).expect("hmac takes any key");
    m.update(b"otto bypass consent key v1");
    m.finalize().into_bytes().into()
}

impl Vault {
    pub fn open(path: &Path, password: &str) -> Result<Vault> {
        let mut f = fs::File::open(path).with_context(|| format!("opening {}", path.display()))?;
        let db = Database::open(&mut f, DatabaseKey::new().with_password(password)).context("unlocking the vault")?;
        Ok(Vault { path: path.into(), password: password.into(), db, seal_key: seal_key(password), seen: stamp(path) })
    }

    pub fn create(path: &Path, password: &str) -> Result<Vault> {
        let mut config = DatabaseConfig::default();
        // the key is random and long, so this only needs to be a sane KeePass default
        config.kdf_config = KdfConfig::Argon2id {
            iterations: 3,
            memory: 64 * 1024 * 1024,
            parallelism: 4,
            version: argon2::Version::Version13,
        };
        let mut db = Database::with_config(config);
        db.meta.database_name = Some("otto".into());
        db.root_mut().name = "otto".into();
        let mut v = Vault { path: path.into(), password: password.into(), db, seal_key: seal_key(password), seen: None };
        v.save()?;
        Ok(v)
    }

    /// Another program wrote the vault since otto last read or wrote it: read it again, so otto's next
    /// save starts from that instead of writing over it. Err when it can't be opened with otto's key.
    pub fn reload_if_changed(&mut self) -> Result<bool> {
        let now = stamp(&self.path);
        if now.is_none() || now == self.seen {
            return Ok(false);
        }
        let mut f = fs::File::open(&self.path)?;
        self.db = Database::open(&mut f, DatabaseKey::new().with_password(&self.password))
            .context("vault.kdbx was changed by another program and otto's key doesn't open it any more")?;
        self.seen = now;
        Ok(true)
    }

    /// Write to a temp file and rename over the vault, keeping the previous version as `.bak` and copies
    /// in `backups/` (see `snapshot`).
    pub fn save(&mut self) -> Result<()> {
        let mut buf = Vec::new();
        self.db
            .save(&mut buf, DatabaseKey::new().with_password(&self.password))
            .context("encrypting the vault")?;
        // never replace a good vault with one we can't read back
        Database::parse(&buf, DatabaseKey::new().with_password(&self.password)).context("verifying the saved vault")?;
        let dir = self.path.parent().context("vault path has no folder")?;
        fs::create_dir_all(dir)?;
        let tmp = self.path.with_extension("kdbx.tmp");
        {
            let mut f = open_private(&tmp)?;
            f.write_all(&buf)?;
            f.sync_all()?;
        }
        if self.path.exists() {
            let _ = fs::copy(&self.path, self.path.with_extension("kdbx.bak"));
            self.snapshot();
        }
        fs::rename(&tmp, &self.path)?;
        self.seen = stamp(&self.path);
        Ok(())
    }

    fn backups_dir(&self) -> PathBuf {
        self.path.with_file_name("backups")
    }

    /// Before a save: the vault as it is goes into `backups/`, one copy per hour (the first save in it), and
    /// old ones go: hourly copies after a couple of days, the day's first one after a couple of months.
    /// A backup failing never stops the save.
    fn snapshot(&self) {
        let dir = self.backups_dir();
        if fs::create_dir_all(&dir).is_err() {
            return;
        }
        set_private_dir(&dir);
        let name = format!("vault-{}.kdbx", chrono::Utc::now().format("%Y-%m-%dT%H"));
        let to = dir.join(&name);
        if !to.exists() {
            if let Ok(bytes) = fs::read(&self.path) {
                if let Ok(mut f) = open_private(&to) {
                    let _ = f.write_all(&bytes);
                }
            }
        }
        prune_backups(&dir, chrono::Utc::now());
    }

    /// Copies of the vault in `backups/`, newest first.
    pub fn backups(&self) -> Vec<Backup> {
        let mut out: Vec<Backup> = backup_files(&self.backups_dir())
            .into_iter()
            .map(|(name, at, size)| Backup { name, at: at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true), size })
            .collect();
        out.sort_by(|a, b| b.at.cmp(&a.at));
        out
    }

    /// Replaces what's in the vault with a backup (which must open with this vault's key). What was there
    /// goes into `backups/` first, so this can be undone the same way.
    pub fn restore_backup(&mut self, name: &str) -> Result<(), Fail> {
        if !backup_files(&self.backups_dir()).iter().any(|(n, _, _)| n == name) {
            return Err(Fail::new("not_found", format!("no backup named {name}")));
        }
        let mut f = fs::File::open(self.backups_dir().join(name)).map_err(|e| Fail::new("not_found", e.to_string()))?;
        let db = Database::open(&mut f, DatabaseKey::new().with_password(&self.password))
            .map_err(|_| Fail::new("unlock_failed", "that backup doesn't open with this vault's key"))?;
        // keep the current state as its own copy, whatever hour it is
        let keep = self.backups_dir().join(format!("vault-{}-before-restore.kdbx", chrono::Utc::now().format("%Y-%m-%dT%H%M%S")));
        if let (Ok(bytes), Ok(mut out)) = (fs::read(&self.path), open_private(&keep)) {
            let _ = out.write_all(&bytes);
        }
        self.db = db;
        Ok(())
    }

    fn in_recycle_bin(&self, e: &EntryRef<'_>) -> bool {
        let Some(bin) = self.db.recycle_bin() else { return false };
        let bin = bin.id();
        let mut gid = Some(e.parent().id());
        while let Some(id) = gid {
            if id == bin {
                return true;
            }
            gid = self.db.group(id).and_then(|g| g.parent().map(|p| p.id()));
        }
        false
    }

    fn live_entries(&self) -> Vec<EntryRef<'_>> {
        self.db.iter_all_entries().filter(|e| !self.in_recycle_bin(e)).collect()
    }

    pub fn list(&self) -> Vec<EntryInfo> {
        let mut out: Vec<EntryInfo> = self.live_entries().iter().map(|e| info(e, self.bypass_of(e))).collect();
        out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        out
    }

    /// Find an entry by id or (case-insensitive) name.
    pub fn resolve(&self, key: &str) -> Result<EntryId, Fail> {
        let key = key.trim();
        let entries = self.live_entries();
        if let Some(e) = entries.iter().find(|e| e.id().uuid().to_string() == key) {
            return Ok(e.id());
        }
        // a value isn't reached by name: it only comes back through a command's blank
        let matches: Vec<&EntryRef> = entries
            .iter()
            .filter(|e| e.get(F_KIND) != Some("value") && e.get(fields::TITLE).unwrap_or("").eq_ignore_ascii_case(key))
            .collect();
        match matches.len() {
            1 => Ok(matches[0].id()),
            0 => Err(Fail::new("not_found", format!("no entry named \"{key}\""))),
            _ => Err(Fail::new("ambiguous", format!("more than one entry is named \"{key}\"; use its id"))),
        }
    }

    pub fn find(&self, key: &str) -> Option<EntryInfo> {
        self.resolve(key).ok().and_then(|id| self.info(id))
    }

    /// `find` on an agent's behalf: a value isn't there for it, not even by its id.
    pub fn find_open(&self, key: &str) -> Option<EntryInfo> {
        self.find(key).filter(|e| e.kind != "value")
    }

    pub fn info(&self, id: EntryId) -> Option<EntryInfo> {
        self.db.entry(id).map(|e| info(&e, self.bypass_of(&e)))
    }

    fn mac(&self, c: &Consent) -> Hmac<Sha256> {
        let mut m = <Hmac<Sha256>>::new_from_slice(&self.seal_key).expect("hmac takes any key");
        m.update(&c.sealed_bytes());
        m
    }

    /// Whether this vault's key sealed the consent (it may still be expired or for a deleted entry).
    pub fn verify(&self, c: &Consent) -> bool {
        data_encoding::HEXLOWER.decode(c.seal.as_bytes()).is_ok_and(|s| self.mac(c).verify_slice(&s).is_ok())
    }

    /// The entry's consent if it's sealed by this vault, made for this entry, and not expired.
    fn bypass_of(&self, e: &EntryRef<'_>) -> Option<Consent> {
        let c: Consent = serde_json::from_str(e.get(F_BYPASS)?).ok()?;
        (c.entry == e.id().uuid().to_string() && !c.expired() && self.verify(&c)).then_some(c)
    }

    /// Turn on bypass for an entry. Only the app's private channel gets here, after the user's
    /// Touch ID and ticked box; the consent is sealed to this entry. Does not save.
    pub fn grant_bypass(&mut self, id: EntryId, mut c: Consent) -> Result<Consent, Fail> {
        c.entry = id.uuid().to_string();
        c.seal = String::new();
        c.seal = data_encoding::HEXLOWER.encode(&self.mac(&c).finalize().into_bytes());
        let json = serde_json::to_string(&c).map_err(|e| Fail::new("internal", e.to_string()))?;
        let mut entry = self.db.entry_mut(id).ok_or_else(|| Fail::new("not_found", "entry vanished"))?;
        entry.track_changes().set_unprotected(F_BYPASS, &json);
        Ok(c)
    }

    /// Browsers the user allowed to fill logins (beyond the pinned ones).
    pub fn trusted_browsers(&self) -> Vec<crate::peer::BrowserSig> {
        match self.db.root().custom_data.get(D_BROWSERS).and_then(|i| i.value.as_ref()) {
            Some(keepass::db::CustomDataValue::String(s)) => serde_json::from_str(s).unwrap_or_default(),
            _ => vec![],
        }
    }

    /// Does not save.
    pub fn set_trusted_browsers(&mut self, list: &[crate::peer::BrowserSig]) {
        let item = keepass::db::CustomDataItem {
            value: Some(keepass::db::CustomDataValue::String(serde_json::to_string(list).unwrap_or_default())),
            last_modification_time: Some(chrono::Utc::now().naive_utc()),
        };
        self.db.root_mut().custom_data.insert(D_BROWSERS.into(), item);
    }

    pub fn waits(&self) -> Waits {
        match self.db.root().custom_data.get(D_WAITS).and_then(|i| i.value.as_ref()) {
            Some(keepass::db::CustomDataValue::String(s)) => serde_json::from_str(s).unwrap_or_default(),
            _ => Waits::default(),
        }
    }

    /// Does not save.
    pub fn set_waits(&mut self, waits: &Waits) {
        let item = keepass::db::CustomDataItem {
            value: Some(keepass::db::CustomDataValue::String(serde_json::to_string(waits).unwrap_or_default())),
            last_modification_time: Some(chrono::Utc::now().naive_utc()),
        };
        self.db.root_mut().custom_data.insert(D_WAITS.into(), item);
    }

    /// The values the user keeps for commands' blanks, with what's in them. For the service only.
    pub fn remembered(&self) -> Vec<Remembered> {
        self.live_entries()
            .iter()
            .filter(|e| e.get(F_KIND) == Some("value"))
            .map(|e| {
                let i = info(e, None);
                Remembered { off: i.policy == Policy::Never, id: i.id, name: i.name, secret: i.secret, commands: i.commands, value: e.get("value").unwrap_or("").to_string() }
            })
            .collect()
    }

    pub fn remote(&self) -> crate::remote::Conf {
        match self.db.root().custom_data.get(D_REMOTE).and_then(|i| i.value.as_ref()) {
            Some(keepass::db::CustomDataValue::String(s)) => serde_json::from_str(s).unwrap_or_default(),
            _ => Default::default(),
        }
    }

    /// Does not save.
    pub fn set_remote(&mut self, conf: &crate::remote::Conf) {
        let item = keepass::db::CustomDataItem {
            value: Some(keepass::db::CustomDataValue::String(serde_json::to_string(conf).unwrap_or_default())),
            last_modification_time: Some(chrono::Utc::now().naive_utc()),
        };
        self.db.root_mut().custom_data.insert(D_REMOTE.into(), item);
    }

    /// Turn bypass off (anyone may: it only takes access away). True if it was on. Does not save.
    pub fn end_bypass(&mut self, id: EntryId) -> Result<bool, Fail> {
        let was = self.info(id).ok_or_else(|| Fail::new("not_found", "entry vanished"))?.bypass.is_some();
        let mut entry = self.db.entry_mut(id).ok_or_else(|| Fail::new("not_found", "entry vanished"))?;
        if entry.get(F_BYPASS).is_some() {
            entry.track_changes().edit(|e| {
                e.fields.remove(F_BYPASS);
            });
        }
        Ok(was)
    }

    /// Read one field. `username`, `password`, `otp`, `notes`, `url` map to the KeePass standard fields.
    pub fn field(&self, id: EntryId, field: &str) -> Option<String> {
        let e = self.db.entry(id)?;
        e.get(std_field(field)).filter(|v| !v.is_empty()).map(String::from)
    }

    pub fn totp(&self, id: EntryId) -> Result<Totp, Fail> {
        let raw = self.field(id, "otp").ok_or_else(|| Fail::new("no_totp", "this entry has no 2FA secret yet"))?;
        Totp::parse(&raw).map_err(|e| Fail::new("bad_totp", format!("the stored 2FA secret is broken: {e}")))
    }

    /// Create or update an entry and return its id. Does not save.
    pub fn apply(&mut self, p: &EntryPatch) -> Result<EntryId, Fail> {
        let before = p.id.as_deref().map(|id| self.resolve(id)).transpose()?;
        let is_value = p.kind.as_deref() == Some("value") || before.and_then(|id| self.db.entry(id)).is_some_and(|e| e.get(F_KIND) == Some("value"));
        let value_rules = if is_value { Some(self.value_rules(p, before)?) } else { None };
        let id = match before {
            Some(id) => id,
            None => {
                let name = p.name.as_deref().map(str::trim).filter(|n| !n.is_empty()).ok_or_else(|| Fail::bad("an entry needs a name"))?;
                if !is_value && self.resolve(name).is_ok() {
                    return Err(Fail::new("exists", format!("an entry named \"{name}\" already exists")));
                }
                self.db.root_mut().add_entry().id()
            }
        };
        if let Some(name) = &p.name {
            let name = name.trim();
            if name.is_empty() {
                return Err(Fail::bad("an entry needs a name"));
            }
            if let Some(other) = self.resolve(name).ok().filter(|_| !is_value) {
                if other != id {
                    return Err(Fail::new("exists", format!("an entry named \"{name}\" already exists")));
                }
            }
        }
        let source = match (&p.otp, &p.otp_from) {
            (None, Some(src)) => {
                let sid = self.resolve(src)?;
                let uri = self.field(sid, "otp").ok_or_else(|| Fail::new("no_totp", "that 2FA account has no secret"))?;
                Some((sid, uri))
            }
            _ => None,
        };
        let otp = match (&p.otp, &source) {
            (Some(s), _) if !s.trim().is_empty() => Some(Totp::parse(s).map_err(|e| Fail::new("bad_totp", e))?.to_uri()),
            (Some(_), _) => Some(String::new()),
            (None, Some((_, uri))) => Some(uri.clone()),
            (None, None) => None,
        };
        let mut entry = self.db.entry_mut(id).ok_or_else(|| Fail::new("not_found", "entry vanished"))?;
        let mut e = entry.track_changes();
        let mut set = |k: &str, v: &str, protect: bool| {
            if protect {
                e.set_protected(k, v)
            } else {
                e.set_unprotected(k, v)
            }
        };
        if let Some(v) = &p.name {
            set(fields::TITLE, v.trim(), false);
        }
        if let Some(k) = &p.kind {
            if !KINDS.contains(&k.as_str()) {
                return Err(Fail::bad(format!("`kind` is one of {}", KINDS.join(", "))));
            }
            set(F_KIND, if k == "login" { "" } else { k }, false);
        }
        if let Some(v) = &p.username {
            set(fields::USERNAME, v, false);
        }
        if let Some(v) = &p.password {
            set(fields::PASSWORD, v, true);
        }
        if let Some(v) = &otp {
            set(fields::OTP, v, true);
        }
        if let Some(v) = &p.notes {
            set(fields::NOTES, v, false);
        }
        if let Some(sites) = &p.sites {
            let sites: Vec<String> = sites.iter().filter_map(|s| normalize_site(s)).collect();
            set(F_SITES, &sites.join(","), false);
            set(fields::URL, &sites.first().map(|s| format!("https://{s}")).unwrap_or_default(), false);
        }
        if let Some(apps) = &p.apps {
            let apps: Vec<&str> = apps.iter().map(|s| s.trim()).filter(|s| !s.is_empty()).collect();
            set(F_APPS, &apps.join(","), false);
        }
        if let Some(folders) = &p.folders {
            let folders: Vec<String> = folders.iter().map(|s| s.trim().trim_end_matches('/').to_string()).filter(|s| !s.is_empty()).collect();
            set(F_FOLDERS, &folders.join(","), false);
        }
        if let Some(agents) = &p.agents {
            let agents: Vec<String> = agents.iter().map(|s| s.trim().to_lowercase()).filter(|s| !s.is_empty()).collect();
            set(F_AGENTS, &agents.join(","), false);
        }
        if let Some(policy) = p.policy {
            set(F_POLICY, policy.as_str(), false);
        }
        if let Some(scripts) = p.scripts {
            set(F_SCRIPTS, if scripts { "1" } else { "" }, false);
        }
        if let Some(quiet) = p.quiet {
            set(F_QUIET, if quiet { "1" } else { "" }, false);
        }
        if let Some(library) = p.library {
            set(F_LIBRARY, if library { "1" } else { "" }, false);
        }
        if let Some((secret, commands)) = &value_rules {
            set(F_SECRET, if *secret { "1" } else { "" }, false);
            set(F_COMMANDS, &if commands.is_empty() { String::new() } else { serde_json::to_string(commands).unwrap_or_default() }, false);
        }
        if let Some(k) = &p.two_factor {
            let k = match k.as_str() {
                "delivered" | "sms" | "email" => "delivered",
                "none" => "none",
                _ => "",
            };
            set(F_2FA, k, false);
        }
        if let Some(extra) = &p.fields {
            for (k, v) in extra {
                let k = k.trim();
                if k.is_empty() || k.starts_with("otto.") || is_std_field(k) {
                    continue;
                }
                set(k, v, true);
            }
        }
        drop(e);
        // drop empty fields so the entry stays tidy in other KeePass apps
        if let Some(mut entry) = self.db.entry_mut(id) {
            entry.fields.retain(|k, v| !v.get().is_empty() || [fields::TITLE, fields::USERNAME, fields::PASSWORD, fields::URL, fields::NOTES].contains(&k.as_str()));
        }
        if let Some((sid, _)) = source {
            if sid != id {
                if let Some(mut e) = self.db.entry_mut(sid) {
                    e.track_changes().remove();
                }
            }
        }
        Ok(id)
    }

    /// What a value's name, secrecy and commands will be after this change, if that's allowed. The commands
    /// follow a new name, and each has to have its blank in it. Two values can share a name as long as they
    /// never come back for the same blank.
    fn value_rules(&self, p: &EntryPatch, id: Option<EntryId>) -> Result<(bool, Vec<String>), Fail> {
        let old = id.and_then(|id| self.info(id));
        let name = p.name.as_deref().map(str::trim).or(old.as_ref().map(|o| o.name.as_str())).unwrap_or("");
        if name.is_empty() {
            return Err(Fail::bad("an entry needs a name"));
        }
        if name.contains(['{', '}', '\n']) {
            return Err(Fail::bad("a value's name goes in a blank like {{this}}, so no braces or line breaks"));
        }
        let secret = p.secret.or(old.as_ref().map(|o| o.secret)).unwrap_or(true);
        let mut commands: Vec<String> = vec![];
        for c in p.commands.as_ref().or(old.as_ref().map(|o| &o.commands)).into_iter().flatten() {
            let c = match &old {
                Some(o) if o.name != name => rename_blank(c.trim(), &o.name, name),
                _ => c.trim().to_string(),
            };
            if c.is_empty() || commands.contains(&c) {
                continue;
            }
            if !has_blank(&c, name) {
                return Err(Fail::bad(format!("`{c}` has no {{{{{name}}}}} in it, so \"{name}\" would never come back for it")));
            }
            commands.push(c);
        }
        let mine = id.map(|i| i.uuid().to_string());
        let clash = self.remembered().iter().any(|r| {
            Some(&r.id) != mine.as_ref() && r.name.eq_ignore_ascii_case(name) && r.secret == secret && (!secret || r.commands.iter().any(|c| commands.contains(c)))
        });
        if clash {
            return Err(Fail::new("exists", if secret { format!("another \"{name}\" already comes back for that command") } else { format!("you already have a value called \"{name}\"") }));
        }
        Ok((secret, commands))
    }

    /// Moves the entry to the trash (KeePass's recycle bin, so other KeePass apps see it there too). Its bypass
    /// ends: restoring it later doesn't bring back a yes the user gave before deleting it.
    pub fn delete(&mut self, key: &str) -> Result<(), Fail> {
        let id = self.resolve(key)?;
        self.end_bypass(id)?;
        let bin = self.recycle_bin_id();
        if let Some(mut e) = self.db.entry_mut(id) {
            e.track_changes().move_to(bin).map_err(|e| Fail::new("internal", e.to_string()))?;
        }
        Ok(())
    }

    fn recycle_bin_id(&mut self) -> GroupId {
        if let Some(b) = self.db.recycle_bin() {
            return b.id();
        }
        let mut root = self.db.root_mut();
        let mut g = root.add_group();
        g.name = "Recycle Bin".into();
        // KeePass's own trash icon
        g.set_icon_builtin(43);
        let id = g.id();
        self.db.meta.recyclebin_enabled = Some(true);
        self.db.meta.recyclebin_uuid = Some(id.uuid());
        self.db.meta.recyclebin_changed = Some(chrono::Utc::now().naive_utc());
        id
    }

    fn trashed_entries(&self) -> Vec<EntryRef<'_>> {
        self.db.iter_all_entries().filter(|e| self.in_recycle_bin(e)).collect()
    }

    /// What's in the trash, most recently deleted first.
    pub fn trash(&self) -> Vec<Trashed> {
        let mut out: Vec<Trashed> = self
            .trashed_entries()
            .iter()
            .map(|e| Trashed {
                entry: info(e, None),
                deleted: e.times.location_changed.map(|t| t.and_utc().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)),
            })
            .collect();
        out.sort_by(|a, b| b.deleted.cmp(&a.deleted));
        out
    }

    fn trashed(&self, id: &str) -> Result<EntryId, Fail> {
        self.trashed_entries()
            .iter()
            .find(|e| e.id().uuid().to_string() == id)
            .map(|e| e.id())
            .ok_or_else(|| Fail::new("not_found", "that entry isn't in the trash"))
    }

    /// Back out of the trash, to the top of the vault. A live entry with the same name makes this one "<name> (restored)".
    pub fn restore(&mut self, id: &str) -> Result<EntryId, Fail> {
        let eid = self.trashed(id)?;
        let name = self.db.entry(eid).and_then(|e| e.get(fields::TITLE).map(String::from)).unwrap_or_default();
        // a value keeps its name: that's the blank it comes back for
        let is_value = self.db.entry(eid).is_some_and(|e| e.get(F_KIND) == Some("value"));
        let taken = !is_value && self.live_entries().iter().any(|e| e.get(F_KIND) != Some("value") && e.get(fields::TITLE).unwrap_or("").eq_ignore_ascii_case(&name));
        let root = self.db.root().id();
        if let Some(mut e) = self.db.entry_mut(eid) {
            let mut t = e.track_changes();
            t.move_to(root).map_err(|e| Fail::new("internal", e.to_string()))?;
            if taken {
                t.as_mut().set_unprotected(fields::TITLE, format!("{name} (restored)"));
            }
        }
        Ok(eid)
    }

    /// Gone for good (otto's backups still have it until they age out).
    pub fn purge(&mut self, id: &str) -> Result<(), Fail> {
        let eid = self.trashed(id)?;
        if let Some(mut e) = self.db.entry_mut(eid) {
            e.track_changes().remove();
        }
        Ok(())
    }

    /// Deletes for good what's been in the trash longer than `days`, or everything (`None`). Returns how many went.
    pub fn purge_older(&mut self, days: Option<i64>) -> usize {
        let cutoff = days.map(|d| chrono::Utc::now().naive_utc() - chrono::Duration::days(d));
        let old: Vec<EntryId> = self
            .trashed_entries()
            .iter()
            .filter(|e| match cutoff {
                None => true,
                Some(c) => e.times.location_changed.is_some_and(|t| t < c),
            })
            .map(|e| e.id())
            .collect();
        for id in &old {
            if let Some(mut e) = self.db.entry_mut(*id) {
                e.track_changes().remove();
            }
        }
        old.len()
    }
}

fn info(e: &EntryRef<'_>, bypass: Option<Consent>) -> EntryInfo {
    let get = |k: &str| e.get(k).filter(|v| !v.is_empty()).map(String::from);
    let list = |k: &str| get(k).map(|s| s.split(',').map(|a| a.trim().to_string()).filter(|a| !a.is_empty()).collect()).unwrap_or_default();
    let mut sites: Vec<String> = get(F_SITES).map(|s| s.split(',').filter_map(normalize_site).collect()).unwrap_or_default();
    if sites.is_empty() {
        if let Some(host) = get(fields::URL).and_then(|u| normalize_site(&u)) {
            sites.push(host);
        }
    }
    let totp_present = get(fields::OTP).is_some();
    let totp = get(fields::OTP).and_then(|raw| Totp::parse(&raw).ok()).map(|t| TotpInfo {
        issuer: t.issuer.clone(),
        account: t.account.clone(),
        digits: t.digits,
        period: t.period,
    });
    let mut extra: Vec<String> = e
        .fields
        .keys()
        .filter(|k| !k.starts_with("otto.") && !is_std_field(k))
        .cloned()
        .collect();
    extra.sort();
    let kind = get(F_KIND).filter(|k| KINDS.contains(&k.as_str())).unwrap_or_else(|| "login".into());
    let card = (kind == "card").then(|| {
        let number = get("number").unwrap_or_default();
        let digits: String = number.chars().filter(|c| c.is_ascii_digit()).collect();
        CardInfo { brand: card_brand(&digits).into(), last4: digits.chars().rev().take(4).collect::<Vec<_>>().into_iter().rev().collect(), expiry: get("expiry") }
    });
    let is_value = kind == "value";
    let secret = is_value && e.get(F_SECRET) == Some("1");
    let value = if is_value && !secret { get("value") } else { None };
    let commands = if is_value { get(F_COMMANDS).and_then(|c| serde_json::from_str(&c).ok()).unwrap_or_default() } else { vec![] };
    EntryInfo {
        id: e.id().uuid().to_string(),
        name: get(fields::TITLE).unwrap_or_else(|| "(untitled)".into()),
        kind,
        card,
        username: get(fields::USERNAME),
        sites,
        apps: list(F_APPS),
        folders: list(F_FOLDERS),
        agents: list(F_AGENTS),
        out_of_scope: false,
        policy: Policy::parse(e.get(F_POLICY)),
        scripts: e.get(F_SCRIPTS) == Some("1"),
        quiet: e.get(F_QUIET) == Some("1"),
        has_password: get(fields::PASSWORD).is_some(),
        totp,
        fields: extra,
        library: e.get(F_LIBRARY) == Some("1"),
        two_factor: if totp_present { Some("app".into()) } else { get(F_2FA) },
        modified: e.times.last_modification.map(|t| t.and_utc().to_rfc3339()),
        bypass,
        secret,
        commands,
        value,
    }
}

fn std_field(field: &str) -> &str {
    match field.to_ascii_lowercase().as_str() {
        "username" | "user" => fields::USERNAME,
        "password" | "pass" => fields::PASSWORD,
        "otp" | "totp" => fields::OTP,
        "notes" => fields::NOTES,
        "url" => fields::URL,
        "title" | "name" => fields::TITLE,
        _ => field,
    }
}

fn is_std_field(k: &str) -> bool {
    [fields::TITLE, fields::USERNAME, fields::PASSWORD, fields::URL, fields::NOTES, fields::OTP].contains(&k)
        || k.starts_with("KP2A_URL")
        || k.starts_with("TimeOtp-")
}

/// "https://Panel.Example.com:8443/login" -> "panel.example.com"
pub fn normalize_site(s: &str) -> Option<String> {
    let s = s.trim().to_lowercase();
    if s.is_empty() {
        return None;
    }
    let with_scheme = if s.contains("://") { s } else { format!("https://{s}") };
    match url::Url::parse(&with_scheme).ok()?.host()? {
        url::Host::Domain(d) => {
            let d = d.trim_start_matches("www.").trim_end_matches('.');
            // a real domain: letters, digits and dashes (international names arrive as xn--), ending in a word
            let label = |l: &str| !l.is_empty() && l.len() <= 63 && !l.starts_with('-') && !l.ends_with('-') && l.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
            let labels: Vec<&str> = d.split('.').collect();
            let tld = labels.last().copied().unwrap_or_default();
            let ok = d == "localhost"
                || (labels.len() >= 2 && labels.iter().all(|l| label(l)) && (tld.starts_with("xn--") || (tld.len() >= 2 && tld.chars().all(|c| c.is_ascii_alphabetic()))));
            ok.then(|| d.to_string())
        }
        url::Host::Ipv4(ip) => Some(ip.to_string()),
        url::Host::Ipv6(ip) => Some(format!("[{ip}]")),
    }
}

/// A page's host may use an entry when it is one of the entry's sites or a subdomain of one.
/// localhost, 127.x.x.x and ::1 are all this machine, so they count as one site.
pub fn site_matches(host: &str, sites: &[String]) -> bool {
    let host = host.to_lowercase();
    let host = host.trim_start_matches("www.");
    if is_loopback(host) && sites.iter().any(|s| is_loopback(s)) {
        return true;
    }
    sites.iter().any(|s| host == s || host.ends_with(&format!(".{s}")))
}

/// Hosting domains where every name below belongs to someone else, so "you.github.io" and
/// "them.github.io" are different sites.
const SHARED_HOSTS: &[&str] = &[
    "github.io", "gitlab.io", "github.dev", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "herokuapp.com",
    "appspot.com", "web.app", "firebaseapp.com", "azurewebsites.net", "azurestaticapps.net", "cloudfront.net",
    "amazonaws.com", "onrender.com", "fly.dev", "ngrok.io", "ngrok.app", "ngrok.dev", "ngrok-free.app", "glitch.me",
    "repl.co", "replit.app", "replit.dev", "blogspot.com", "wordpress.com", "myshopify.com", "notion.site", "surge.sh",
    "railway.app", "deno.dev", "pythonanywhere.com", "wixsite.com", "webflow.io", "framer.app", "framer.website",
    "carrd.co", "supabase.co", "run.app", "cloudfunctions.net", "trycloudflare.com", "loca.lt", "lovable.app",
    "codesandbox.io", "csb.app", "stackblitz.io", "vusercontent.net",
];

/// second-level names under country domains: co.uk, com.tr, com.au...
const SECOND_LEVEL: &[&str] = &["co", "com", "net", "org", "gov", "edu", "ac", "gen", "web", "or", "ne", "go", "mil", "ltd", "plc", "biz", "info", "nom", "sch", "k12"];

/// The part of a host a person recognizes as the site: "eu-north-1.signin.aws.amazon.com" ->
/// "amazon.com", "shop.bbc.co.uk" -> "bbc.co.uk", "me.github.io" stays whole. None for something
/// that isn't one site, like "co.uk" or "github.io".
pub fn base_domain(host: &str) -> Option<String> {
    let host = host.trim().trim_end_matches('.').to_lowercase();
    let host = host.trim_start_matches("www.");
    if is_loopback(host) || host.parse::<std::net::IpAddr>().is_ok() {
        return Some(host.to_string());
    }
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 || labels.iter().any(|l| l.is_empty()) {
        return None;
    }
    let n = labels.len();
    let tail = |k: usize| labels[n - k..].join(".");
    let suffix = if SHARED_HOSTS.contains(&tail(2).as_str()) || (labels[n - 1].len() == 2 && SECOND_LEVEL.contains(&labels[n - 2])) { 2 } else { 1 };
    (n > suffix).then(|| tail(suffix + 1))
}

pub fn is_loopback(host: &str) -> bool {
    host == "localhost" || host == "::1" || host == "[::1]" || (host.starts_with("127.") && host.split('.').count() == 4 && host.split('.').all(|p| p.parse::<u8>().is_ok()))
}

/// `vault-<UTC hour>.kdbx` files in `dir`: (name, when, size). Others (a manual copy, a "before restore") are listed
/// by their modification time.
fn backup_files(dir: &Path) -> Vec<(String, chrono::DateTime<chrono::Utc>, u64)> {
    let Ok(rd) = fs::read_dir(dir) else { return vec![] };
    rd.filter_map(Result::ok)
        .filter_map(|d| {
            let name = d.file_name().to_string_lossy().into_owned();
            if !name.ends_with(".kdbx") {
                return None;
            }
            let m = d.metadata().ok()?;
            let at = backup_hour(&name).unwrap_or_else(|| m.modified().map(chrono::DateTime::<chrono::Utc>::from).unwrap_or_default());
            Some((name, at, m.len()))
        })
        .collect()
}

/// The hour in `vault-2026-10-20T20.kdbx`.
fn backup_hour(name: &str) -> Option<chrono::DateTime<chrono::Utc>> {
    let stem = name.strip_prefix("vault-")?.strip_suffix(".kdbx")?;
    let t = chrono::NaiveDateTime::parse_from_str(&format!("{stem}:00:00"), "%Y-%m-%dT%H:%M:%S").ok()?;
    Some(t.and_utc())
}

/// Hourly copies older than HOURLY_DAYS go, except each day's first, which goes after DAILY_DAYS.
/// Copies otto didn't name by the hour are left alone.
fn prune_backups(dir: &Path, now: chrono::DateTime<chrono::Utc>) {
    let mut hourly: Vec<(String, chrono::DateTime<chrono::Utc>)> =
        backup_files(dir).into_iter().filter_map(|(n, _, _)| backup_hour(&n).map(|t| (n, t))).collect();
    hourly.sort_by_key(|(_, t)| *t);
    let mut days = HashSet::new();
    for (name, t) in hourly {
        let age = now - t;
        let first_of_day = days.insert(t.date_naive());
        let keep = age < chrono::Duration::days(HOURLY_DAYS) || (first_of_day && age < chrono::Duration::days(DAILY_DAYS));
        if !keep {
            let _ = fs::remove_file(dir.join(name));
        }
    }
}

fn set_private_dir(dir: &Path) {
    use std::os::unix::fs::PermissionsExt;
    let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
}

pub fn open_private(path: &Path) -> std::io::Result<fs::File> {
    let mut o = fs::OpenOptions::new();
    o.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    o.open(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("otto-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir.join("v.kdbx")
    }

    fn login(v: &mut Vault, name: &str) -> EntryId {
        v.apply(&EntryPatch { name: Some(name.into()), password: Some("pw".into()), ..Default::default() }).unwrap()
    }

    #[test]
    fn delete_goes_to_the_trash_and_comes_back() {
        let path = scratch("trash");
        let mut v = Vault::create(&path, "k").unwrap();
        let id = login(&mut v, "GitHub").uuid().to_string();
        v.delete("GitHub").unwrap();
        v.save().unwrap();
        assert!(v.find("GitHub").is_none(), "a deleted entry isn't there for agents");
        assert!(v.list().is_empty());
        let mut v = Vault::open(&path, "k").unwrap();
        let t = v.trash();
        assert_eq!(t.len(), 1);
        assert_eq!(t[0].entry.name, "GitHub");
        assert!(t[0].deleted.is_some());
        // a new entry took the name meanwhile: the restored one says so
        login(&mut v, "GitHub");
        v.restore(&id).unwrap();
        let names: Vec<String> = v.list().into_iter().map(|e| e.name).collect();
        assert_eq!(names, vec!["GitHub".to_string(), "GitHub (restored)".to_string()]);
        assert!(v.trash().is_empty());
        assert_eq!(v.field(v.resolve(&id).unwrap(), "password").as_deref(), Some("pw"), "it comes back with its secrets");
    }

    #[test]
    fn purge_and_empty() {
        let path = scratch("purge");
        let mut v = Vault::create(&path, "k").unwrap();
        let a = login(&mut v, "A").uuid().to_string();
        login(&mut v, "B");
        v.delete("A").unwrap();
        v.delete("B").unwrap();
        assert_eq!(v.purge_older(Some(30)), 0, "nothing's a month old");
        v.purge(&a).unwrap();
        assert_eq!(v.trash().len(), 1);
        assert!(v.restore(&a).is_err(), "gone for good");
        assert_eq!(v.purge_older(None), 1);
        assert!(v.trash().is_empty());
    }

    #[test]
    fn backups_by_the_hour_then_by_the_day() {
        let path = scratch("backups");
        let mut v = Vault::create(&path, "k").unwrap();
        login(&mut v, "A");
        v.save().unwrap();
        let dir = v.backups_dir();
        assert_eq!(v.backups().len(), 1, "the first save of the hour keeps what was there");
        v.save().unwrap();
        assert_eq!(v.backups().len(), 1, "one per hour");
        // pretend copies from the last three months, every 6 hours
        let now = chrono::Utc::now();
        for h in (6..24 * 90).step_by(6) {
            let t = now - chrono::Duration::hours(h);
            fs::write(dir.join(format!("vault-{}.kdbx", t.format("%Y-%m-%dT%H"))), b"x").unwrap();
        }
        fs::write(dir.join("mine.kdbx"), b"x").unwrap();
        prune_backups(&dir, now);
        let left: Vec<(String, chrono::DateTime<chrono::Utc>)> = backup_files(&dir).into_iter().map(|(n, t, _)| (n, t)).collect();
        assert!(left.iter().any(|(n, _)| n == "mine.kdbx"), "a copy otto didn't name is left alone");
        let hourly: Vec<_> = left.iter().filter_map(|(n, _)| backup_hour(n)).collect();
        let old: Vec<_> = hourly.iter().filter(|t| now - **t >= chrono::Duration::days(HOURLY_DAYS)).collect();
        let days: HashSet<_> = old.iter().map(|t| t.date_naive()).collect();
        assert_eq!(old.len(), days.len(), "past two days, one a day");
        assert!(hourly.iter().all(|t| now - *t < chrono::Duration::days(DAILY_DAYS)), "nothing past two months");
        assert!(hourly.iter().filter(|t| now - **t < chrono::Duration::days(HOURLY_DAYS)).count() >= 7, "every copy from the last two days");
    }

    #[test]
    fn restore_a_backup_keeps_the_current_one() {
        let path = scratch("restore");
        let mut v = Vault::create(&path, "k").unwrap();
        login(&mut v, "Old");
        v.save().unwrap();
        // the next save's copy is of the vault with "Old" in it; force a fresh hour's copy
        for b in v.backups() {
            fs::remove_file(v.backups_dir().join(b.name)).unwrap();
        }
        login(&mut v, "New");
        v.save().unwrap();
        let copy = v.backups()[0].name.clone();
        v.restore_backup(&copy).unwrap();
        v.save().unwrap();
        let names: Vec<String> = v.list().into_iter().map(|e| e.name).collect();
        assert_eq!(names, vec!["Old".to_string()]);
        assert!(v.backups().iter().any(|b| b.name.contains("before-restore")));
        assert!(v.restore_backup("../v.kdbx").is_err(), "only files in backups/");
    }

    #[test]
    fn another_programs_write_is_read_not_overwritten() {
        let path = scratch("reload");
        let mut v = Vault::create(&path, "k").unwrap();
        login(&mut v, "Mine");
        v.save().unwrap();
        assert!(!v.reload_if_changed().unwrap());
        // KeePassXC adds an entry while otto runs
        let mut other = Vault::open(&path, "k").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        login(&mut other, "Theirs");
        other.save().unwrap();
        assert!(v.reload_if_changed().unwrap());
        login(&mut v, "Mine too");
        v.save().unwrap();
        let names: Vec<String> = Vault::open(&path, "k").unwrap().list().into_iter().map(|e| e.name).collect();
        assert_eq!(names, vec!["Mine".to_string(), "Mine too".to_string(), "Theirs".to_string()]);
    }

    #[test]
    fn create_edit_reopen() {
        let dir = std::env::temp_dir().join(format!("otto-test-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v.kdbx");
        let mut v = Vault::create(&path, "correct horse").unwrap();
        let id = v
            .apply(&EntryPatch {
                name: Some("Test Site".into()),
                username: Some("demo".into()),
                password: Some("hunter2".into()),
                otp: Some("JBSWY3DPEHPK3PXP".into()),
                sites: Some(vec!["https://www.Example.com/login".into()]),
                policy: Some(Policy::Auto),
                ..Default::default()
            })
            .unwrap();
        v.save().unwrap();
        let v = Vault::open(&path, "correct horse").unwrap();
        let e = v.find("test site").unwrap();
        assert_eq!(e.sites, vec!["example.com".to_string()]);
        assert_eq!(e.policy, Policy::Auto);
        assert!(e.has_password && e.totp.is_some());
        assert_eq!(v.field(id, "password").as_deref(), Some("hunter2"));
        assert!(site_matches("login.example.com", &e.sites));
        assert!(!site_matches("example.com.evil.io", &e.sites));
        assert!(site_matches("localhost", &["127.0.0.1".to_string()]));
        assert!(site_matches("127.0.0.1", &["localhost".to_string()]));
        assert!(!site_matches("localhost", &e.sites));
        assert!(!site_matches("127.0.0.1.evil.io", &["127.0.0.1".to_string()]));
        assert!(Vault::open(&path, "wrong").is_err());
        assert_eq!(base_domain("eu-north-1.signin.aws.amazon.com").as_deref(), Some("amazon.com"));
        assert_eq!(base_domain("www.GitHub.com").as_deref(), Some("github.com"));
        assert_eq!(base_domain("shop.bbc.co.uk").as_deref(), Some("bbc.co.uk"));
        assert_eq!(base_domain("a.b.example.com.tr").as_deref(), Some("example.com.tr"));
        assert_eq!(base_domain("me.github.io").as_deref(), Some("me.github.io"));
        assert_eq!(base_domain("x.ai").as_deref(), Some("x.ai"));
        assert_eq!(base_domain("127.0.0.1").as_deref(), Some("127.0.0.1"));
        assert_eq!(base_domain("co.uk"), None);
        assert_eq!(base_domain("github.io"), None);
        assert_eq!(base_domain("com"), None);
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn kinds_and_cards() {
        let dir = std::env::temp_dir().join(format!("otto-kinds-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let mut v = Vault::create(&dir.join("v.kdbx"), "k").unwrap();
        let id = v
            .apply(&EntryPatch {
                name: Some("Visa".into()),
                kind: Some("card".into()),
                fields: Some(BTreeMap::from([("number".into(), "4242 4242 4242 4242".into()), ("expiry".into(), "08/28".into()), ("cvc".into(), "123".into())])),
                ..Default::default()
            })
            .unwrap();
        let e = v.info(id).unwrap();
        assert_eq!(e.kind, "card");
        let c = e.card.unwrap();
        assert_eq!((c.brand.as_str(), c.last4.as_str(), c.expiry.as_deref()), ("Visa", "4242", Some("08/28")));
        assert_eq!(v.field(id, "cvc").as_deref(), Some("123"));
        assert!(v.apply(&EntryPatch { name: Some("x".into()), kind: Some("bogus".into()), ..Default::default() }).is_err());
        let l = v.apply(&EntryPatch { name: Some("Login".into()), ..Default::default() }).unwrap();
        assert_eq!(v.info(l).unwrap().kind, "login");
        assert_eq!(card_brand("5555555555554444"), "Mastercard");
        assert_eq!(card_brand("378282246310005"), "American Express");
        assert_eq!(card_brand("9792030000000000"), "Troy");
        for s in ["08/28", "8/2028", "0828", "08 / 28", "082028"] {
            assert_eq!(parse_expiry(s), Some((8, 2028)), "{s}");
        }
        assert_eq!(parse_expiry("13/28"), None);
        assert_eq!(parse_expiry("august"), None);
        assert_eq!((main_field("card"), main_field("key"), main_field("login"), main_field("mac")), ("number", "key", "password", "password"));
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn bypass_consent_is_sealed_to_its_entry() {
        let dir = std::env::temp_dir().join(format!("otto-bypass-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let path = dir.join("v.kdbx");
        let mut v = Vault::create(&path, "key one").unwrap();
        let a = v.apply(&EntryPatch { name: Some("A".into()), policy: Some(Policy::Never), ..Default::default() }).unwrap();
        let b = v.apply(&EntryPatch { name: Some("B".into()), policy: Some(Policy::Ask), ..Default::default() }).unwrap();
        let yes = |until: Option<&str>| Consent {
            entry: String::new(),
            name: "A".into(),
            at: "2026-10-11T12:00:00Z".into(),
            until: until.map(String::from),
            auth: "touch_id".into(),
            statement: "i understand".into(),
            asked_by: Some("claude".into()),
            reason: Some("away this weekend".into()),
            seal: String::new(),
        };
        assert!(v.info(a).unwrap().hidden());
        let c = v.grant_bypass(a, yes(None)).unwrap();
        assert!(v.verify(&c));
        let info = v.info(a).unwrap();
        assert!(info.bypass.is_some() && !info.hidden() && info.access() == "bypass");

        // a changed record no longer fits its seal
        let mut changed = c.clone();
        changed.until = Some("2099-01-01T00:00:00Z".into());
        assert!(!v.verify(&changed));
        let mut forged = c.clone();
        forged.seal = "00".repeat(32);
        assert!(!v.verify(&forged));

        // the same record copied onto another entry doesn't count there
        v.db.entry_mut(b).unwrap().set_unprotected(F_BYPASS, serde_json::to_string(&c).unwrap());
        assert!(v.info(b).unwrap().bypass.is_none());
        // and a patch can't write otto.* fields at all
        v.apply(&EntryPatch { id: Some(b.uuid().to_string()), fields: Some(BTreeMap::from([(F_BYPASS.to_string(), "{}".to_string())])), ..Default::default() }).unwrap();
        assert_eq!(v.db.entry(b).unwrap().get(F_BYPASS), Some(serde_json::to_string(&c).unwrap().as_str()));

        // survives a save, and only this vault's key accepts it
        v.save().unwrap();
        let mut v = Vault::open(&path, "key one").unwrap();
        assert!(v.info(a).unwrap().bypass.is_some());
        let other = Vault::create(&dir.join("other.kdbx"), "key two").unwrap();
        assert!(!other.verify(&c));

        // an expired one is off
        v.grant_bypass(b, yes(Some("2020-01-01T00:00:00Z"))).unwrap();
        assert!(v.info(b).unwrap().bypass.is_none());
        v.grant_bypass(b, yes(Some("2099-01-01T00:00:00Z"))).unwrap();
        assert!(v.info(b).unwrap().bypass.is_some());

        // turning it off puts the entry back to its own policy
        assert!(v.end_bypass(a).unwrap());
        assert!(v.info(a).unwrap().hidden());
        assert!(!v.end_bypass(a).unwrap());
        fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn sites_are_real_domains() {
        let n = |s: &str| normalize_site(s);
        assert_eq!(n("https://www.Amazon.com.tr/gp/cart?x=1").as_deref(), Some("amazon.com.tr"));
        assert_eq!(n("alfa@hetzner.com").as_deref(), Some("hetzner.com"));
        assert_eq!(n("127.0.0.1:8765").as_deref(), Some("127.0.0.1"));
        assert_eq!(n("localhost").as_deref(), Some("localhost"));
        assert_eq!(n("bücher.de").as_deref(), Some("xn--bcher-kva.de"));
        for junk in ["dsjknakj109uj80nıpn1j0*opı", "jdopaısjdu89", "amazon", "a.b1", "-x.com", "x..com", ""] {
            assert_eq!(n(junk), None, "{junk}");
        }
    }
}
