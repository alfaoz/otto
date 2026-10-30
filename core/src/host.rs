//! Chrome native messaging host. Chrome starts `otto chrome-extension://<id>/` when the
//! extension connects; this relays between the extension (length-prefixed JSON on stdio)
//! and the otto service (JSON lines on the socket), reconnecting when the app restarts.

use serde_json::{json, Value};
use std::{
    io::{BufRead, BufReader, Read, Write},
    os::unix::net::UnixStream,
    path::Path,
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

use crate::paths;

type Out = Arc<Mutex<std::io::Stdout>>;

fn send_native(out: &Out, v: &Value) {
    let bytes = v.to_string().into_bytes();
    if bytes.len() > 1024 * 1024 {
        return; // Chrome's limit for host -> extension
    }
    let mut o = out.lock().unwrap();
    let _ = o.write_all(&(bytes.len() as u32).to_ne_bytes());
    let _ = o.write_all(&bytes);
    let _ = o.flush();
}

pub fn run(origin: &str) -> anyhow::Result<()> {
    let out: Out = Arc::new(Mutex::new(std::io::stdout()));
    let sock: Arc<Mutex<Option<UnixStream>>> = Arc::new(Mutex::new(None));

    let (o2, s2, origin) = (out.clone(), sock.clone(), origin.to_string());
    thread::spawn(move || loop {
        let mut wait = Duration::from_secs(2);
        let mut refused = false;
        if let Ok(stream) = UnixStream::connect(paths::socket_path()) {
            if let Ok(mut w) = stream.try_clone() {
                let hello = json!({ "id": 0, "op": "hello", "args": { "role": "bridge", "origin": origin } });
                if writeln!(w, "{hello}").is_ok() {
                    *s2.lock().unwrap() = Some(w);
                    for line in BufReader::new(stream).lines() {
                        let Ok(line) = line else { break };
                        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                        if v["id"] == 0 && v["type"] == "res" {
                            let ok = v["ok"].as_bool() == Some(true);
                            refused = !ok;
                            if !ok && v["error"]["code"] != "locked" {
                                wait = Duration::from_secs(60); // refused: don't hammer the service
                            }
                            send_native(&o2, &json!({ "type": "event", "event": "service", "data": { "connected": ok, "error": v["error"], "browser": v["result"]["browser"] } }));
                            continue;
                        }
                        send_native(&o2, &v);
                    }
                    *s2.lock().unwrap() = None;
                }
            }
        }
        // a refusal already said why; the service hanging up after it isn't news
        if !refused {
            send_native(&o2, &json!({ "type": "event", "event": "service", "data": { "connected": false } }));
        }
        thread::sleep(wait);
    });

    let mut stdin = std::io::stdin().lock();
    loop {
        let mut len = [0u8; 4];
        if stdin.read_exact(&mut len).is_err() {
            break; // the extension closed the port
        }
        let n = u32::from_ne_bytes(len) as usize;
        if n > 64 * 1024 * 1024 {
            break;
        }
        let mut buf = vec![0u8; n];
        stdin.read_exact(&mut buf)?;
        let Ok(v) = serde_json::from_slice::<Value>(&buf) else { continue };
        // the popup's "open otto": this helper runs without the app, so it can start it
        if v["type"] == "open_app" {
            open_app();
            continue;
        }
        if let Some(w) = sock.lock().unwrap().as_mut() {
            let _ = writeln!(w, "{v}");
        }
    }
    Ok(())
}

/// Opens the Otto.app this binary ships in (Otto.app/Contents/MacOS/otto). Nothing of `open`'s may reach
/// stdout: that's Chrome's channel.
fn open_app() {
    let Some(app) = std::env::current_exe().ok().and_then(|p| p.ancestors().nth(3).map(Path::to_path_buf)) else { return };
    if app.extension().is_none_or(|e| e != "app") {
        return;
    }
    thread::spawn(move || {
        let _ = Command::new("/usr/bin/open").arg(app).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status();
    });
}
