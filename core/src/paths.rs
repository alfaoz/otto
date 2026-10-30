use std::path::PathBuf;

/// Where otto keeps its vault, socket and activity log. `OTTO_HOME` overrides it (tests, multiple vaults).
pub fn home_dir() -> PathBuf {
    if let Ok(p) = std::env::var("OTTO_HOME") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").map(PathBuf::from).unwrap_or_else(|_| PathBuf::from("."));
    if cfg!(target_os = "macos") {
        home.join("Library/Application Support/otto")
    } else {
        std::env::var("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home.join(".local/share"))
            .join("otto")
    }
}

pub fn socket_path() -> PathBuf {
    home_dir().join("otto.sock")
}

pub fn vault_path() -> PathBuf {
    home_dir().join("vault.kdbx")
}

pub fn audit_path() -> PathBuf {
    home_dir().join("activity.jsonl")
}
