use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// One line on any otto channel (socket, app pipe, browser bridge).
#[derive(Debug, Serialize, Deserialize)]
pub struct Request {
    #[serde(default)]
    pub id: u64,
    pub op: String,
    #[serde(default)]
    pub args: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Fail {
    pub code: String,
    /// for the agent: what went wrong and what to do about it
    pub message: String,
    /// for the user, in the activity log, when `message` isn't for them to read
    #[serde(skip)]
    pub noted: Option<String>,
}

impl Fail {
    pub fn new(code: &str, message: impl Into<String>) -> Self {
        Fail { code: code.into(), message: message.into(), noted: None }
    }
    /// What the activity log says instead of `message`.
    pub fn noted(mut self, line: impl Into<String>) -> Self {
        self.noted = Some(line.into());
        self
    }
    pub fn for_log(&self) -> String {
        self.noted.clone().unwrap_or_else(|| self.message.clone())
    }
    pub fn bad(message: impl Into<String>) -> Self {
        Fail::new("bad_request", message)
    }
    pub fn from_value(v: &Value) -> Self {
        Fail {
            code: v["code"].as_str().unwrap_or("error").to_string(),
            message: v["message"].as_str().unwrap_or("unknown error").to_string(),
            noted: None,
        }
    }
}

impl std::fmt::Display for Fail {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Fail {}

impl From<anyhow::Error> for Fail {
    fn from(e: anyhow::Error) -> Self {
        Fail::new("internal", format!("{e:#}"))
    }
}

pub type OpResult = Result<Value, Fail>;

pub fn response(id: u64, r: &OpResult) -> Value {
    match r {
        Ok(v) => json!({ "type": "res", "id": id, "ok": true, "result": v }),
        Err(e) => json!({ "type": "res", "id": id, "ok": false, "error": e }),
    }
}

/// Parse a response line back into a result.
pub fn parse_response(v: &Value) -> OpResult {
    if v["ok"].as_bool() == Some(true) {
        Ok(v.get("result").cloned().unwrap_or(Value::Null))
    } else {
        Err(Fail::from_value(&v["error"]))
    }
}

pub fn arg_str<'a>(args: &'a Value, key: &str) -> Result<&'a str, Fail> {
    args[key]
        .as_str()
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| Fail::bad(format!("missing `{key}`")))
}

pub fn opt_str<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args[key].as_str().filter(|s| !s.trim().is_empty())
}

pub fn str_list(args: &Value, key: &str) -> Vec<String> {
    match &args[key] {
        Value::Array(a) => a.iter().filter_map(|v| v.as_str()).map(String::from).collect(),
        Value::String(s) => s.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect(),
        _ => vec![],
    }
}
