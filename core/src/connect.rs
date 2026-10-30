//! Adds otto's MCP server to other agents' config files (`otto connect`), plus otto's skill where the
//! agent reads skills (Codex, opencode). Claude Code gets the plugin instead, which brings both.

use serde_json::{json, Value};
use std::{fs, path::PathBuf};

use crate::proto::Fail;

/// otto asks the user itself where an entry says so; Codex asking again would only get in the way
/// (and defeat bypass while the user is away)
const CODEX_APPROVE: &str = "# otto asks you itself (Touch ID, new sites, bypass), so Codex doesn't ask again\ndefault_tools_approval_mode = \"approve\"\n";

/// the same skill the Claude Code plugin ships
const SKILL: &str = include_str!("../../plugin/skills/otto/SKILL.md");

struct Agent {
    id: &'static str,
    name: &'static str,
    /// config file(s), relative to the home folder: the first that exists, else the first
    files: &'static [&'static str],
    /// where the agent reads skills (relative to home), if it does
    skills: Option<&'static str>,
    /// a folder (relative to home) or app that shows it's installed
    signs: &'static [&'static str],
    kind: Kind,
}

enum Kind {
    /// `{"mcpServers": {"otto": {"command", "args"}}}`
    McpServers,
    /// opencode: `{"mcp": {"otto": {"type": "local", "command": [..]}}}`, often JSONC with comments
    OpenCode,
    /// Codex: a `[mcp_servers.otto]` table in config.toml
    CodexToml,
    /// T3 Code runs other agents (Claude Code, Codex, opencode...): it has otto when they do
    Through(&'static [&'static str]),
}

const AGENTS: &[Agent] = &[
    Agent { id: "codex", name: "Codex", files: &[".codex/config.toml"], skills: Some(".codex/skills"), signs: &[".codex"], kind: Kind::CodexToml },
    Agent {
        id: "opencode",
        name: "opencode",
        files: &[".config/opencode/opencode.jsonc", ".config/opencode/opencode.json"],
        skills: Some(".config/opencode/skills"),
        signs: &[".config/opencode"],
        kind: Kind::OpenCode,
    },
    Agent {
        id: "t3code",
        name: "T3 Code",
        files: &[],
        skills: None,
        signs: &[".t3", "/Applications/T3 Code (Alpha).app", "/Applications/T3 Code.app"],
        kind: Kind::Through(&["codex", "opencode"]),
    },
    Agent { id: "cursor", name: "Cursor", files: &[".cursor/mcp.json"], skills: None, signs: &[".cursor", "/Applications/Cursor.app"], kind: Kind::McpServers },
    Agent { id: "gemini", name: "Gemini CLI", files: &[".gemini/settings.json"], skills: None, signs: &[".gemini"], kind: Kind::McpServers },
    Agent {
        id: "windsurf",
        name: "Windsurf",
        files: &[".codeium/windsurf/mcp_config.json"],
        skills: None,
        signs: &[".codeium/windsurf", "/Applications/Windsurf.app"],
        kind: Kind::McpServers,
    },
    Agent {
        id: "claude-desktop",
        name: "Claude (desktop app)",
        files: &["Library/Application Support/Claude/claude_desktop_config.json"],
        skills: None,
        signs: &["Library/Application Support/Claude", "/Applications/Claude.app"],
        kind: Kind::McpServers,
    },
];

fn agent(id: &str) -> Result<&'static Agent, Fail> {
    AGENTS
        .iter()
        .find(|a| a.id == id)
        .ok_or_else(|| Fail::bad(format!("unknown agent `{id}`. known: {}", AGENTS.iter().map(|a| a.id).collect::<Vec<_>>().join(", "))))
}

fn config_path(a: &Agent) -> PathBuf {
    a.files.iter().map(|f| home().join(f)).find(|p| p.exists()).unwrap_or_else(|| home().join(a.files.first().copied().unwrap_or_default()))
}

/// Claude Code lists its plugins here; "otto@<marketplace>" means ours is in.
pub fn claude_plugin() -> bool {
    fs::read_to_string(home().join(".claude/plugins/installed_plugins.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .is_some_and(|v| v["plugins"].as_object().is_some_and(|p| p.keys().any(|k| k.starts_with("otto@"))))
}

fn home() -> PathBuf {
    std::env::var("HOME").map(PathBuf::from).unwrap_or_default()
}

fn installed(a: &Agent) -> bool {
    a.signs.iter().any(|s| if s.starts_with('/') { PathBuf::from(s).exists() } else { home().join(s).exists() })
}

fn connected(a: &Agent) -> bool {
    if let Kind::Through(ids) = a.kind {
        // the ones T3 Code can run that are installed, plus Claude Code through its plugin
        let others: Vec<&Agent> = ids.iter().filter_map(|i| agent(i).ok()).filter(|o| installed(o)).collect();
        return claude_plugin() && others.iter().all(|o| connected(o));
    }
    let Ok(text) = fs::read_to_string(config_path(a)) else { return false };
    match a.kind {
        Kind::CodexToml => text.lines().any(|l| l.trim() == "[mcp_servers.otto]"),
        Kind::McpServers => serde_json::from_str::<Value>(&text).is_ok_and(|v| v["mcpServers"]["otto"].is_object()),
        Kind::OpenCode => parse_jsonc(&text).is_some_and(|v| v["mcp"]["otto"].is_object()),
        Kind::Through(_) => false,
    }
}

/// Which agents are on this Mac and which already have otto.
pub fn list() -> Value {
    json!(AGENTS
        .iter()
        .map(|a| json!({ "id": a.id, "name": a.name, "installed": installed(a), "connected": connected(a), "file": config_path(a) }))
        .collect::<Vec<_>>())
}

/// Keep otto's skill current for every connected agent that reads skills (the app calls this on launch).
pub fn refresh_skills() {
    for a in AGENTS.iter().filter(|a| a.skills.is_some() && connected(a)) {
        let _ = write_skill(a);
    }
}

fn write_skill(a: &Agent) -> Result<(), Fail> {
    let Some(dir) = a.skills else { return Ok(()) };
    let file = home().join(dir).join("otto/SKILL.md");
    if fs::read_to_string(&file).ok().as_deref() == Some(SKILL) {
        return Ok(());
    }
    fs::create_dir_all(file.parent().unwrap_or(&file)).map_err(|e| Fail::new("io", e.to_string()))?;
    fs::write(&file, SKILL).map_err(|e| Fail::new("io", format!("couldn't write {}: {e}", file.display())))
}

/// Add otto to one agent's config, keeping everything else in it (and a copy of the old file).
/// Returns what was set up, for the user.
pub fn connect(id: &str) -> Result<String, Fail> {
    let a = agent(id)?;
    if let Kind::Through(ids) = a.kind {
        let mut done = vec![];
        for o in ids.iter().filter_map(|i| agent(i).ok()).filter(|o| installed(o)) {
            connect(o.id)?;
            done.push(o.name);
        }
        let claude = if claude_plugin() {
            "Claude Code has the otto plugin".to_string()
        } else {
            "for its Claude: in Claude Code run /plugin marketplace add <otto repo> and /plugin install otto@otto".to_string()
        };
        return Ok(format!("{} runs {} with otto now; {claude}", a.name, if done.is_empty() { "no other agent".into() } else { done.join(" and ") }));
    }
    let exe = std::env::current_exe().and_then(|p| p.canonicalize()).map_err(|e| Fail::new("io", e.to_string()))?;
    let exe = exe.to_string_lossy().into_owned();
    let path = config_path(a);
    let old = fs::read_to_string(&path).ok();
    if connected(a) {
        if let (Kind::CodexToml, Some(old)) = (&a.kind, &old) {
            if !old.contains("default_tools_approval_mode") {
                let _ = fs::write(&path, old.replacen("[mcp_servers.otto]\n", &format!("[mcp_servers.otto]\n{CODEX_APPROVE}"), 1));
            }
        }
        write_skill(a)?;
        return Ok(format!("{} already has otto ({})", a.name, path.display()));
    }
    let new = match a.kind {
        Kind::CodexToml => {
            let mut t = old.clone().unwrap_or_default();
            if !t.is_empty() && !t.ends_with('\n') {
                t.push('\n');
            }
            let quoted = serde_json::to_string(&exe).unwrap_or_default(); // a TOML basic string is JSON-compatible here
            t.push_str(&format!("\n[mcp_servers.otto]\ncommand = {quoted}\nargs = [\"mcp\"]\n{CODEX_APPROVE}"));
            t
        }
        Kind::OpenCode if old.as_deref().is_some_and(|t| !t.trim().is_empty()) => {
            let server = json!({ "type": "local", "command": [exe, "mcp"], "enabled": true });
            insert_jsonc(old.as_deref().unwrap_or_default(), "mcp", "otto", &server)
                .ok_or_else(|| Fail::new("bad_config", format!("couldn't read {} as JSON, so otto left it alone", path.display())))?
        }
        Kind::Through(_) => unreachable!(),
        Kind::McpServers | Kind::OpenCode => {
            let mut v: Value = match old.as_deref().map(str::trim) {
                None | Some("") => json!({}),
                Some(t) => serde_json::from_str(t).map_err(|e| Fail::new("bad_config", format!("{} isn't valid JSON ({e}), so otto left it alone", path.display())))?,
            };
            if !v.is_object() {
                return Err(Fail::new("bad_config", format!("{} isn't a JSON object, so otto left it alone", path.display())));
            }
            let (key, server) = match a.kind {
                Kind::OpenCode => ("mcp", json!({ "type": "local", "command": [exe, "mcp"], "enabled": true })),
                _ => ("mcpServers", json!({ "command": exe, "args": ["mcp"] })),
            };
            if !v[key].is_object() {
                v[key] = json!({});
            }
            v[key]["otto"] = server;
            serde_json::to_string_pretty(&v).unwrap_or_default() + "\n"
        }
    };
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| Fail::new("io", e.to_string()))?;
    }
    if let Some(old) = &old {
        let _ = fs::write(path.with_extension(format!("{}.before-otto", path.extension().and_then(|e| e.to_str()).unwrap_or("bak"))), old);
    }
    fs::write(&path, new).map_err(|e| Fail::new("io", format!("couldn't write {}: {e}", path.display())))?;
    write_skill(a)?;
    if matches!(a.kind, Kind::OpenCode) {
        // opencode 2 keeps a background server with the old config: have it read the file again
        let _ = std::process::Command::new("opencode").arg("reload").stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).status();
    }
    let skill = a.skills.map(|d| format!(" and its skill to ~/{d}/otto")).unwrap_or_default();
    Ok(format!("added otto to {}{skill}. restart {} to pick it up", path.display(), a.name))
}

/// The text with comments blanked out (same length, so positions still match the original).
fn blank_comments(t: &str) -> Vec<u8> {
    let b = t.as_bytes();
    let mut out = b.to_vec();
    let (mut i, mut in_str) = (0, false);
    while i < b.len() {
        if in_str {
            if b[i] == b'\\' {
                i += 2;
                continue;
            }
            in_str = b[i] != b'"';
        } else if b[i] == b'"' {
            in_str = true;
        } else if b[i..].starts_with(b"//") {
            while i < b.len() && b[i] != b'\n' {
                out[i] = b' ';
                i += 1;
            }
            continue;
        } else if b[i..].starts_with(b"/*") {
            let end = t[i + 2..].find("*/").map(|e| i + 2 + e + 2).unwrap_or(b.len());
            for c in &mut out[i..end] {
                if *c != b'\n' {
                    *c = b' ';
                }
            }
            i = end;
            continue;
        }
        i += 1;
    }
    out
}

/// JSON with comments and trailing commas (opencode.jsonc), read for checking.
fn parse_jsonc(t: &str) -> Option<Value> {
    let plain = String::from_utf8(blank_comments(t)).ok()?;
    let mut s = String::with_capacity(plain.len());
    let chars: Vec<char> = plain.chars().collect();
    let mut in_str = false;
    for (i, &c) in chars.iter().enumerate() {
        if in_str {
            in_str = !(c == '"' && chars[..i].iter().rev().take_while(|&&p| p == '\\').count() % 2 == 0);
        } else if c == '"' {
            in_str = true;
        } else if c == ',' && chars[i + 1..].iter().find(|c| !c.is_whitespace()).is_some_and(|n| *n == '}' || *n == ']') {
            continue;
        }
        s.push(c);
    }
    serde_json::from_str(&s).ok()
}

/// Add `"name": value` inside the top-level object's `section` object (creating it), editing the
/// text in place so the file's comments and layout survive.
fn insert_jsonc(t: &str, section: &str, name: &str, value: &Value) -> Option<String> {
    parse_jsonc(t)?.as_object()?;
    let plain = blank_comments(t);
    let start = plain.iter().position(|&c| c == b'{')?;
    // find `"section": {` at depth 1
    let (mut depth, mut i, mut in_str) = (0, start, false);
    let mut target = None;
    while i < plain.len() {
        let c = plain[i];
        if in_str {
            if c == b'\\' {
                i += 2;
                continue;
            }
            if c == b'"' {
                in_str = false;
            }
        } else if c == b'"' {
            if depth == 1 {
                let end = i + 1 + plain[i + 1..].iter().position(|&c| c == b'"')?;
                let key = &t[i + 1..end];
                let after = end + 1 + plain[end + 1..].iter().position(|c| !c.is_ascii_whitespace())?;
                if key == section && plain[after] == b':' {
                    let open = after + 1 + plain[after + 1..].iter().position(|c| !c.is_ascii_whitespace())?;
                    if plain[open] != b'{' {
                        return None;
                    }
                    target = Some(open);
                    break;
                }
                i = end + 1;
                continue;
            }
            in_str = true;
        } else if c == b'{' || c == b'[' {
            depth += 1;
        } else if c == b'}' || c == b']' {
            depth -= 1;
        }
        i += 1;
    }
    let pretty = |v: &Value, indent: &str| serde_json::to_string_pretty(v).unwrap_or_default().replace('\n', &format!("\n{indent}"));
    let empty_after = |at: usize| plain[at + 1..].iter().find(|c| !c.is_ascii_whitespace()) == Some(&b'}');
    let (at, text) = match target {
        Some(open) => {
            let comma = if empty_after(open) { "" } else { "," };
            (open + 1, format!("\n    \"{name}\": {}{comma}", pretty(value, "    ")))
        }
        None => {
            let comma = if empty_after(start) { "" } else { "," };
            (start + 1, format!("\n  \"{section}\": {{\n    \"{name}\": {}\n  }}{comma}", pretty(value, "    ")))
        }
    };
    let mut out = t.to_string();
    out.insert_str(at, &text);
    parse_jsonc(&out).filter(|v| v[section][name] == *value).map(|_| out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn jsonc_insert_keeps_comments() {
        let v = json!({ "type": "local", "command": ["/x/otto", "mcp"], "enabled": true });
        let t = "{\n  // my model\n  \"model\": \"m4rzipan/qwen\", /* trailing */\n  \"plugin\": [\"a\",],\n}\n";
        let out = insert_jsonc(t, "mcp", "otto", &v).unwrap();
        assert!(out.contains("// my model") && out.contains("/* trailing */"));
        let p = parse_jsonc(&out).unwrap();
        assert_eq!(p["mcp"]["otto"], v);
        assert_eq!(p["model"], "m4rzipan/qwen");
        // an existing mcp section, empty or not
        let t = "{ \"mcp\": { \"other\": { \"type\": \"remote\" } }, \"x\": 1 }";
        let p = parse_jsonc(&insert_jsonc(t, "mcp", "otto", &v).unwrap()).unwrap();
        assert_eq!(p["mcp"]["otto"], v);
        assert_eq!(p["mcp"]["other"]["type"], "remote");
        let p = parse_jsonc(&insert_jsonc("{\"mcp\": {}}", "mcp", "otto", &v).unwrap()).unwrap();
        assert_eq!(p["mcp"]["otto"], v);
        let p = parse_jsonc(&insert_jsonc("{}", "mcp", "otto", &v).unwrap()).unwrap();
        assert_eq!(p["mcp"]["otto"], v);
        // a "//" inside a string isn't a comment
        let t = "{ \"$schema\": \"https://opencode.ai/config.json\" }";
        let p = parse_jsonc(&insert_jsonc(t, "mcp", "otto", &v).unwrap()).unwrap();
        assert_eq!(p["$schema"], "https://opencode.ai/config.json");
        assert!(insert_jsonc("not json", "mcp", "otto", &v).is_none());
    }
}
