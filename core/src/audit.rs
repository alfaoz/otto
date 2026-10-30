//! Activity log: one JSON line per agent request (and per bypass the user turns on or off).
//! Never contains secret values.

use serde::Serialize;
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, Write},
    path::PathBuf,
};

#[derive(Debug, Clone, Serialize)]
pub struct Event {
    pub ts: String,
    pub agent: String,
    pub op: String,
    pub entry: Option<String>,
    pub ok: bool,
    pub detail: String,
    /// the sealed consent, on the line where the user turned on bypass
    #[serde(skip_serializing_if = "Option::is_none")]
    pub consent: Option<Value>,
    /// the app that started the agent ("T3 Code")
    #[serde(skip_serializing_if = "Option::is_none")]
    pub via: Option<String>,
    /// the agent's working folder
    #[serde(skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    /// the caller isn't an agent otto could verify by its signature
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub unverified: bool,
    /// the request waits for the user (remote on): it isn't done, and didn't fail either
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub pending: bool,
    /// a command line in full (`detail` shows a short one) and the reason the agent gave for it
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub why: Option<String>,
}

impl Event {
    pub fn new(agent: &str, op: &str, entry: Option<&str>, ok: bool, detail: impl Into<String>) -> Event {
        Event {
            ts: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            agent: agent.into(),
            op: op.into(),
            entry: entry.map(String::from),
            ok,
            detail: detail.into(),
            consent: None,
            via: None,
            folder: None,
            unverified: false,
            pending: false,
            command: None,
            why: None,
        }
    }
}

pub struct Audit {
    path: PathBuf,
}

impl Audit {
    pub fn new(path: PathBuf) -> Self {
        Audit { path }
    }

    pub fn record(&self, agent: &str, op: &str, entry: Option<&str>, ok: bool, detail: impl Into<String>) -> Event {
        self.write(Event::new(agent, op, entry, ok, detail))
    }

    pub fn record_consent(&self, entry: &str, detail: impl Into<String>, consent: Value) -> Event {
        self.write(Event { consent: Some(consent), ..Event::new("you", "bypass_on", Some(entry), true, detail) })
    }

    pub fn write(&self, ev: Event) -> Event {
        if fs::metadata(&self.path).map(|m| m.len() > 4_000_000).unwrap_or(false) {
            let _ = fs::rename(&self.path, self.path.with_extension("jsonl.1"));
        }
        let mut o = fs::OpenOptions::new();
        o.create(true).append(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            o.mode(0o600);
        }
        if let Ok(mut f) = o.open(&self.path) {
            let _ = writeln!(f, "{}", json!(ev));
        }
        ev
    }

    pub fn recent(&self, limit: usize) -> Vec<Value> {
        self.recent_where(limit, |_| true)
    }

    /// The newest `limit` lines that pass `keep`.
    pub fn recent_where(&self, limit: usize, keep: impl Fn(&Value) -> bool) -> Vec<Value> {
        let Ok(f) = fs::File::open(&self.path) else { return vec![] };
        let lines: Vec<String> = std::io::BufReader::new(f).lines().map_while(Result::ok).collect();
        lines
            .iter()
            .rev()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .filter(|v| keep(v))
            .take(limit)
            .collect()
    }
}
