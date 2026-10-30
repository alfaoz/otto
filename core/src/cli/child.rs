//! `otto run`'s command, with otto staying in between so its output can be masked. On a terminal the
//! command gets a pseudo-terminal of its own (colors, progress bars and prompts keep working); otherwise
//! plain pipes. Signals sent to otto go on to the command, and otto exits the way it did.

use super::mask::{Masker, Patterns};
use crate::proto::Fail;
use std::{
    fs::File,
    io::{Read, Write},
    os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
    os::unix::process::{CommandExt, ExitStatusExt},
    process::{Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicI32, Ordering},
        Arc,
    },
    thread,
};

const FORWARDED: [libc::c_int; 4] = [libc::SIGINT, libc::SIGTERM, libc::SIGHUP, libc::SIGQUIT];

/// Runs `cmd` with `env` added and returns the exit code to leave with (128 + signal if a signal ended it).
pub fn run(cmd: &[String], env: &[(String, String)], pats: Patterns) -> Result<i32, Fail> {
    let pats = Arc::new(pats);
    let tty = |fd| unsafe { libc::isatty(fd) == 1 };
    let (tty_in, tty_out, tty_err) = (tty(0), tty(1), tty(2));
    let sig_rx = signals(tty_out)?;
    let mut c = Command::new(&cmd[0]);
    c.args(&cmd[1..]).envs(env.iter().map(|(k, v)| (k, v)));

    // the pty's master end, when the command runs on one
    let mut master: Option<OwnedFd> = None;
    let mut streams: Vec<(OwnedFd, RawFd)> = vec![];
    if tty_out {
        let (m, slave) = openpty(if tty_in { 0 } else { 1 })?;
        let dup = |fd: &OwnedFd| fd.try_clone().map(Stdio::from).map_err(|e| Fail::new("exec", format!("pty: {e}")));
        c.stdin(if tty_in { dup(&slave)? } else { Stdio::inherit() });
        c.stdout(dup(&slave)?);
        c.stderr(if tty_err { dup(&slave)? } else { Stdio::piped() });
        unsafe {
            c.pre_exec(|| {
                // a session of its own, with the pty as its terminal, so ^C and window sizes reach it
                if libc::setsid() < 0 || libc::ioctl(1, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        master = Some(m);
    } else {
        c.stdin(Stdio::inherit()).stdout(Stdio::piped()).stderr(Stdio::piped());
    }
    let mut child = c.spawn().map_err(|e| Fail::new("exec", format!("couldn't run {}: {e}", cmd[0])))?;
    // the command holds the only copies of the pty's slave end now, so the master sees the end
    drop(c);
    let pid = child.id() as i32;
    if let Some(out) = child.stdout.take() {
        streams.push((out.into(), 1));
    }
    if let Some(err) = child.stderr.take() {
        streams.push((err.into(), 2));
    }

    let raw = if master.is_some() && tty_in { Raw::on(0) } else { None };
    if let Some(m) = &master {
        streams.push((m.try_clone().map_err(|e| Fail::new("exec", format!("pty: {e}")))?, 1));
        if tty_in {
            let to = File::from(m.try_clone().map_err(|e| Fail::new("exec", format!("pty: {e}")))?);
            thread::spawn(move || keyboard(to));
        }
    }

    let master_fd = master.as_ref().map(|m| m.as_raw_fd());
    let pty = master.is_some();
    // on pipes the command shares otto's process group, so what the terminal sends the group (^C, ^\,
    // a hangup) reaches it without otto
    let terminal = if pty { None } else { File::open("/dev/tty").ok() };
    thread::spawn(move || {
        while let Ok(sig) = sig_rx.recv() {
            if sig == libc::SIGWINCH {
                if let Some(m) = master_fd {
                    resize(m);
                }
            } else if pty {
                // its own session: nothing reaches it unless otto passes it on
                unsafe { libc::kill(-pid, sig) };
            } else if !terminal.as_ref().is_some_and(|t| from_terminal(t, sig)) {
                unsafe { libc::kill(pid, sig) };
            }
        }
    });

    let exited = Arc::new(AtomicBool::new(false));
    let pumps: Vec<_> = streams
        .into_iter()
        .map(|(fd, to)| {
            let (pats, exited) = (pats.clone(), exited.clone());
            thread::spawn(move || pump(fd, to, Masker::new(pats), if pty { Some(exited) } else { None }))
        })
        .collect();
    let status = child.wait().map_err(|e| Fail::new("exec", format!("waiting for {}: {e}", cmd[0])))?;
    exited.store(true, Ordering::SeqCst);
    for p in pumps {
        let _ = p.join();
    }
    drop(raw);
    drop(master);
    Ok(status.code().or_else(|| status.signal().map(|s| 128 + s)).unwrap_or(1))
}

/// Copy one of the command's outputs to ours (fd `to`), masked. Without `exited` it runs to the end of
/// the stream; on a pty it also stops once the command is gone and nothing more comes for a moment
/// (something it left running in the background may hold the pty open).
fn pump(fd: OwnedFd, to: RawFd, mut m: Masker, exited: Option<Arc<AtomicBool>>) {
    let mut from = File::from(fd);
    let mut buf = vec![0u8; 64 * 1024];
    let mut quiet = 0;
    loop {
        if let Some(exited) = &exited {
            let mut p = libc::pollfd { fd: from.as_raw_fd(), events: libc::POLLIN, revents: 0 };
            let r = unsafe { libc::poll(&mut p, 1, 50) };
            if r == 0 {
                quiet = if exited.load(Ordering::SeqCst) { quiet + 1 } else { 0 };
                if quiet >= 3 {
                    break;
                }
                continue;
            }
            if r < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
        }
        let n = match from.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            // a pty's master reads EIO once the command and everything it started is gone
            Err(_) => break,
        };
        quiet = 0;
        if write(to, &m.feed(&buf[..n])).is_err() {
            // nobody reads our output anymore: closing this end lets the command find out too
            return;
        }
    }
    let _ = write(to, &m.finish());
}

fn write(fd: RawFd, bytes: &[u8]) -> std::io::Result<()> {
    if bytes.is_empty() {
        return Ok(());
    }
    // not std's stdout: its buffer would hold back a line without a newline (a prompt, a progress bar)
    let mut f = std::mem::ManuallyDrop::new(unsafe { File::from_raw_fd(fd) });
    f.write_all(bytes)
}

/// What's typed on our terminal goes to the command's.
fn keyboard(mut to: File) {
    let mut buf = [0u8; 4096];
    let mut from = std::mem::ManuallyDrop::new(unsafe { File::from_raw_fd(0) });
    loop {
        match from.read(&mut buf) {
            Ok(0) => return,
            Ok(n) => {
                if to.write_all(&buf[..n]).is_err() {
                    return;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return,
        }
    }
}

/// A pty with the settings and size of our terminal (`like` is a terminal fd).
fn openpty(like: RawFd) -> Result<(OwnedFd, OwnedFd), Fail> {
    let (mut m, mut s) = (-1, -1);
    let mut t: libc::termios = unsafe { std::mem::zeroed() };
    let mut w: libc::winsize = unsafe { std::mem::zeroed() };
    let has_t = unsafe { libc::tcgetattr(like, &mut t) } == 0;
    let has_w = unsafe { libc::ioctl(1, libc::TIOCGWINSZ, &mut w) } == 0;
    let r = unsafe {
        libc::openpty(
            &mut m,
            &mut s,
            std::ptr::null_mut(),
            if has_t { &mut t } else { std::ptr::null_mut() },
            if has_w { &mut w } else { std::ptr::null_mut() },
        )
    };
    if r != 0 {
        return Err(Fail::new("exec", format!("couldn't open a terminal for the command: {}", std::io::Error::last_os_error())));
    }
    for fd in [m, s] {
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    Ok(unsafe { (OwnedFd::from_raw_fd(m), OwnedFd::from_raw_fd(s)) })
}

/// Whether `sig` most likely came from the terminal to the whole foreground process group (macOS's
/// siginfo can't tell: a ^C carries the pid of whoever wrote it to the terminal, like a kill() does).
fn from_terminal(t: &File, sig: libc::c_int) -> bool {
    let fd = t.as_raw_fd();
    if unsafe { libc::tcgetpgrp(fd) } != unsafe { libc::getpgrp() } {
        return false;
    }
    if sig == libc::SIGHUP {
        return true;
    }
    let mut tio: libc::termios = unsafe { std::mem::zeroed() };
    (sig == libc::SIGINT || sig == libc::SIGQUIT) && unsafe { libc::tcgetattr(fd, &mut tio) } == 0 && tio.c_lflag & libc::ISIG != 0
}

/// Our terminal's size, onto the command's (the kernel then tells it with SIGWINCH).
fn resize(master: RawFd) {
    let mut w: libc::winsize = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(1, libc::TIOCGWINSZ, &mut w) } == 0 {
        unsafe { libc::ioctl(master, libc::TIOCSWINSZ, &w) };
    }
}

/// Our terminal in raw mode while the command has it (keys go straight through, ^C included); the old
/// settings come back when this is dropped.
struct Raw(libc::termios);

impl Raw {
    fn on(fd: RawFd) -> Option<Raw> {
        let mut t: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(fd, &mut t) } != 0 {
            return None;
        }
        let mut raw = t;
        unsafe {
            libc::cfmakeraw(&mut raw);
            libc::tcsetattr(fd, libc::TCSANOW, &raw);
        }
        Some(Raw(t))
    }
}

impl Drop for Raw {
    fn drop(&mut self) {
        unsafe { libc::tcsetattr(0, libc::TCSADRAIN, &self.0) };
    }
}

// ---- signals ---------------------------------------------------------------------------------

static SIG_FD: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(sig: libc::c_int) {
    let errno = unsafe { *errno_ptr() };
    let fd = SIG_FD.load(Ordering::Relaxed);
    if fd >= 0 {
        unsafe { libc::write(fd, [sig as u8].as_ptr() as *const libc::c_void, 1) };
    }
    unsafe { *errno_ptr() = errno };
}

#[cfg(target_os = "macos")]
unsafe fn errno_ptr() -> *mut libc::c_int {
    libc::__error()
}
#[cfg(not(target_os = "macos"))]
unsafe fn errno_ptr() -> *mut libc::c_int {
    libc::__errno_location()
}

/// Catch the signals otto passes on (and SIGWINCH on a pty); the handler only writes to a pipe.
fn signals(pty: bool) -> Result<std::sync::mpsc::Receiver<libc::c_int>, Fail> {
    let mut fds = [-1; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(Fail::new("exec", format!("pipe: {}", std::io::Error::last_os_error())));
    }
    for fd in fds {
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    unsafe { libc::fcntl(fds[1], libc::F_SETFL, libc::O_NONBLOCK) };
    SIG_FD.store(fds[1], Ordering::Relaxed);
    let mut sigs = FORWARDED.to_vec();
    if pty {
        sigs.push(libc::SIGWINCH);
    }
    for sig in sigs {
        unsafe {
            let mut sa: libc::sigaction = std::mem::zeroed();
            sa.sa_sigaction = on_signal as usize;
            sa.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&mut sa.sa_mask);
            libc::sigaction(sig, &sa, std::ptr::null_mut());
        }
    }
    let (tx, rx) = std::sync::mpsc::channel();
    let mut from = unsafe { File::from_raw_fd(fds[0]) };
    thread::spawn(move || {
        let mut msg = [0u8; 1];
        while from.read_exact(&mut msg).is_ok() {
            if tx.send(msg[0] as libc::c_int).is_err() {
                return;
            }
        }
    });
    Ok(rx)
}
