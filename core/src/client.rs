//! Blocking client for the otto socket, used by the CLI and the MCP server.

use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Write},
    os::unix::net::UnixStream,
};

use crate::{paths, proto::*};

pub fn call(op: &str, args: Value) -> OpResult {
    let mut s = UnixStream::connect(paths::socket_path()).map_err(|e| match e.kind() {
        // a sandboxed shell (Codex runs commands in one) may not open local sockets
        std::io::ErrorKind::PermissionDenied => Fail::new(
            "sandboxed",
            "a sandbox is keeping this command away from otto (Codex's shell sandbox does that). use otto's MCP tools, \
             or run the command outside the sandbox (ask for escalated permissions)",
        ),
        _ => Fail::new("not_running", "otto isn't running. open Otto.app, it unlocks the vault and starts the service"),
    })?;
    let line = json!({ "id": 1, "op": op, "args": args }).to_string();
    s.write_all(line.as_bytes()).and_then(|_| s.write_all(b"\n")).map_err(|e| Fail::new("io", e.to_string()))?;
    let mut buf = String::new();
    BufReader::new(s).read_line(&mut buf).map_err(|e| Fail::new("io", e.to_string()))?;
    if buf.trim().is_empty() {
        return Err(Fail::new("gone", "otto closed the connection"));
    }
    let v: Value = serde_json::from_str(&buf).map_err(|e| Fail::new("io", format!("bad reply: {e}")))?;
    parse_response(&v)
}
