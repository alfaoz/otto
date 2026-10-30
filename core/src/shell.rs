//! Running a command the user allowed: `/bin/sh -c` in a folder, in its own process group, with both
//! outputs read while it runs.

use crate::{
    cli::mask::{Masker, Patterns},
    proto::Fail,
};
use std::{
    io::Read,
    os::unix::process::CommandExt,
    path::Path,
    process::{Command, ExitStatus, Stdio},
    sync::{Arc, OnceLock},
    thread,
    time::{Duration, Instant},
};

/// where to look when the user's shell doesn't say
const USUAL_PATH: &[&str] = &["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"];

pub struct Ran {
    /// None: it was stopped after `limit`
    status: Option<ExitStatus>,
    limit: Duration,
    pub out: String,
    pub err: String,
}

impl Ran {
    pub fn code(&self) -> Option<i32> {
        self.status.and_then(|s| s.code())
    }

    /// How it ended and what it printed, for the agent.
    pub fn text(&self) -> String {
        let mut text = match self.status {
            Some(s) => match s.code() {
                Some(c) => format!("allowed by the user; it ran and exited {c}"),
                None => "allowed by the user; it ran and was stopped by a signal".to_string(),
            },
            None => format!("allowed by the user; it ran and was stopped after {} s", self.limit.as_secs()),
        };
        if !self.out.is_empty() {
            text += &format!("\n--- output ---\n{}", self.out);
        }
        if !self.err.is_empty() {
            text += &format!("\n--- errors ---\n{}", self.err);
        }
        text
    }
}

/// Runs `cmd` with `env` added. Whatever it prints shows the `hide` values as ••••.
pub fn run(cmd: &str, cwd: &Path, limit: Duration, env: &[(String, String)], hide: &[&str]) -> Result<Ran, Fail> {
    let mut c = Command::new("/bin/sh");
    c.arg("-c").arg(cmd).current_dir(cwd).envs(env.iter().map(|(k, v)| (k, v)));
    let (status, out, err) = collect(c, limit).map_err(|e| Fail::new("exec", format!("couldn't start it: {e}")))?;
    let pats = Arc::new(Patterns::new(hide));
    Ok(Ran { status, limit, out: tail(&masked(&out, &pats)), err: tail(&masked(&err, &pats)) })
}

/// The PATH the user's own shell has, so a command the service runs finds the programs it would in their
/// terminal. It doesn't come from the agent: an agent's PATH could point at a program of its own, and that
/// program would get what the user typed.
pub fn user_path() -> String {
    static PATH: OnceLock<String> = OnceLock::new();
    PATH.get_or_init(|| {
        let mut dirs: Vec<String> = shell_path().map(|p| p.split(':').map(String::from).collect()).unwrap_or_default();
        for d in USUAL_PATH {
            if !dirs.iter().any(|x| x == d) {
                dirs.push((*d).to_string());
            }
        }
        dirs.join(":")
    })
    .clone()
}

fn shell_path() -> Option<String> {
    let shell = std::env::var("SHELL").ok().filter(|s| !s.is_empty()).unwrap_or_else(|| "/bin/zsh".into());
    let mut c = Command::new(shell);
    // interactive too: plenty of people set PATH in .zshrc. the last line, since those files can print things
    c.args(["-lic", "printf '\\n%s\\n' \"$PATH\""]);
    let (status, out, _) = collect(c, Duration::from_secs(5)).ok()?;
    status?;
    String::from_utf8_lossy(&out).lines().last().filter(|l| l.starts_with('/')).map(String::from)
}

/// Its own process group, so stopping it stops what it started too. Both outputs are read while it runs,
/// so a chatty command doesn't fill a pipe and stall.
fn collect(mut c: Command, limit: Duration) -> std::io::Result<(Option<ExitStatus>, Vec<u8>, Vec<u8>)> {
    let mut child = c.process_group(0).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn()?;
    let read = |mut r: Box<dyn Read + Send>| {
        thread::spawn(move || {
            let mut buf = Vec::new();
            let _ = r.read_to_end(&mut buf);
            buf
        })
    };
    let out = read(Box::new(child.stdout.take().expect("piped")));
    let err = read(Box::new(child.stderr.take().expect("piped")));
    let start = Instant::now();
    let status = loop {
        if let Some(s) = child.try_wait()? {
            break Some(s);
        }
        if start.elapsed() > limit {
            unsafe { libc::kill(-(child.id() as i32), libc::SIGKILL) };
            let _ = child.wait();
            break None;
        }
        thread::sleep(Duration::from_millis(50));
    };
    Ok((status, out.join().unwrap_or_default(), err.join().unwrap_or_default()))
}

fn masked(b: &[u8], pats: &Arc<Patterns>) -> Vec<u8> {
    let mut m = Masker::new(pats.clone());
    let mut out = m.feed(b);
    out.extend(m.finish());
    out
}

/// What it printed, the end of it when there's a lot.
fn tail(b: &[u8]) -> String {
    const MAX: usize = 30_000;
    let s = String::from_utf8_lossy(b);
    if s.len() <= MAX {
        return s.trim_end().to_string();
    }
    let cut = s.len() - MAX;
    let cut = (cut..s.len()).find(|&i| s.is_char_boundary(i)).unwrap_or(cut);
    format!("[… {} bytes before this left out]\n{}", cut, s[cut..].trim_end())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_hides_what_it_was_told_to() {
        let env = [("V".to_string(), "hunter2-secret".to_string())];
        let r = run("printf 'got %s\\n' \"$V\"; printf '%s\\n' \"$V\" >&2; exit 3", Path::new("/tmp"), Duration::from_secs(5), &env, &["hunter2-secret"]).unwrap();
        assert_eq!((r.code(), r.out.as_str(), r.err.as_str()), (Some(3), "got ••••", "••••"));
        assert!(r.text().starts_with("allowed by the user; it ran and exited 3"));
    }

    #[test]
    fn an_allowed_command_runs_and_reports() {
        let (dir, ten) = (std::env::temp_dir(), Duration::from_secs(10));
        let r = run("echo hi; echo oops >&2; exit 3", &dir, ten, &[], &[]).unwrap();
        assert_eq!(r.text(), "allowed by the user; it ran and exited 3\n--- output ---\nhi\n--- errors ---\noops");
        let t = Instant::now();
        // what it started is stopped too, so its open output doesn't keep the tool waiting
        let r = run("sleep 30 & sleep 30", &dir, Duration::from_secs(1), &[], &[]).unwrap();
        assert!(r.text().starts_with("allowed by the user; it ran and was stopped after 1 s"), "{}", r.text());
        assert_eq!(r.code(), None);
        assert!(t.elapsed() < Duration::from_secs(5));
        let r = run("yes | head -c 100000", &dir, ten, &[], &[]).unwrap();
        assert!(r.text().contains("bytes before this left out") && r.text().len() < 31_000);
    }

    #[test]
    fn the_path_is_the_users_not_the_callers() {
        let p = user_path();
        assert!(p.split(':').any(|d| d == "/usr/bin"), "{p}");
    }
}
