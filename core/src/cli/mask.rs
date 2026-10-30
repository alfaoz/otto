//! What `otto run` puts between the command and the terminal: every secret it handed the command, in
//! the forms a program is likely to print it in, turns into "••••" before the output reaches the agent.
//! It's for accidents (a debug print, `printenv`, `curl -v`), not for a program set on leaking a value.

use data_encoding::{Encoding, BASE64, BASE64URL, BASE64URL_NOPAD, BASE64_NOPAD, HEXLOWER, HEXUPPER};
use std::{collections::BTreeSet, fmt::Write, sync::Arc};

pub const MASK: &str = "••••";
/// Shorter values aren't masked: a 3 digit CVC or a 4 digit PIN would turn every "123" in the output
/// into dots, and a value that short is easy to guess anyway.
pub const MIN_LEN: usize = 6;
/// Base64 cut out of a longer stream is only masked from this many characters, so a short run that
/// happens to show up in ordinary output isn't hidden.
const MIN_B64: usize = 8;

pub struct Patterns {
    list: Vec<Vec<u8>>,
    /// pattern indexes by their first byte
    first: Vec<Vec<usize>>,
    longest: usize,
}

impl Patterns {
    pub fn new(secrets: &[&str]) -> Patterns {
        let mut set = BTreeSet::new();
        for s in secrets.iter().filter(|s| s.len() >= MIN_LEN) {
            forms(s, &mut set);
        }
        set.retain(|p: &Vec<u8>| !p.is_empty());
        let list: Vec<Vec<u8>> = set.into_iter().collect();
        let mut first = vec![vec![]; 256];
        for (i, p) in list.iter().enumerate() {
            first[p[0] as usize].push(i);
        }
        let longest = list.iter().map(Vec::len).max().unwrap_or(0);
        Patterns { list, first, longest }
    }

    pub fn is_empty(&self) -> bool {
        self.list.is_empty()
    }

    /// Mark every byte that's part of a whole pattern in `buf`.
    fn cover(&self, buf: &[u8], cov: &mut [bool]) {
        for i in 0..buf.len() {
            for &k in &self.first[buf[i] as usize] {
                let p = &self.list[k];
                if buf[i..].starts_with(p) {
                    cov[i..i + p.len()].fill(true);
                }
            }
        }
    }

    /// Where the tail of `buf` that could still grow into a pattern starts (`buf.len()` if none does).
    fn cut(&self, buf: &[u8]) -> usize {
        for i in buf.len().saturating_sub(self.longest.saturating_sub(1))..buf.len() {
            let tail = &buf[i..];
            if self.first[buf[i] as usize].iter().any(|&k| self.list[k].len() > tail.len() && self.list[k].starts_with(tail)) {
                return i;
            }
        }
        buf.len()
    }
}

/// The ways a value tends to show up in output: as is, JSON-escaped, URL-encoded, hex, base64 (alone,
/// and from inside a longer base64 stream at each of the 3 byte alignments).
fn forms(s: &str, out: &mut BTreeSet<Vec<u8>>) {
    let b = s.as_bytes();
    out.insert(b.to_vec());
    if s.contains('\n') {
        // a terminal turns \n into \r\n
        out.insert(s.replace('\n', "\r\n").into_bytes());
    }
    let json = serde_json::to_string(s).unwrap_or_default();
    out.insert(json.as_bytes()[1..json.len() - 1].to_vec());
    out.insert(json_ascii(s).into_bytes());
    let unreserved = |c: u8| c.is_ascii_alphanumeric() || b"-._~".contains(&c);
    out.insert(pct(b, |c| unreserved(c), true, false));
    out.insert(pct(b, |c| unreserved(c), false, false));
    // Python's quote() keeps "/", JavaScript's encodeURIComponent keeps !'()*, forms turn spaces into +
    out.insert(pct(b, |c| unreserved(c) || c == b'/', true, false));
    out.insert(pct(b, |c| unreserved(c) || b"!'()*".contains(&c), true, false));
    out.insert(pct(b, |c| unreserved(c), true, true));
    out.insert(HEXLOWER.encode(b).into_bytes());
    out.insert(HEXUPPER.encode(b).into_bytes());
    for (padded, bare) in [(&BASE64, &BASE64_NOPAD), (&BASE64URL, &BASE64URL_NOPAD)] {
        out.insert(padded.encode(b).into_bytes());
        out.insert(bare.encode(b).into_bytes());
        cores(bare, b, out);
    }
}

/// The part of a value's base64 that comes out the same wherever the value sits in a longer stream:
/// whole 3 byte groups only, starting at each of the 3 alignments.
fn cores(enc: &Encoding, b: &[u8], out: &mut BTreeSet<Vec<u8>>) {
    for skip in 0..3.min(b.len()) {
        let rest = &b[skip..];
        let core = enc.encode(&rest[..rest.len() / 3 * 3]);
        if core.len() >= MIN_B64 {
            out.insert(core.into_bytes());
        }
    }
}

/// Percent-encoding with uppercase or lowercase hex; `plus` writes spaces as "+".
fn pct(b: &[u8], keep: impl Fn(u8) -> bool, upper: bool, plus: bool) -> Vec<u8> {
    let mut o = String::new();
    for &c in b {
        if keep(c) {
            o.push(c as char);
        } else if plus && c == b' ' {
            o.push('+');
        } else if upper {
            let _ = write!(o, "%{c:02X}");
        } else {
            let _ = write!(o, "%{c:02x}");
        }
    }
    o.into_bytes()
}

/// JSON with everything outside ASCII as \u escapes (Python's json.dumps default).
fn json_ascii(s: &str) -> String {
    let mut o = String::new();
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            '\n' => o.push_str("\\n"),
            '\r' => o.push_str("\\r"),
            '\t' => o.push_str("\\t"),
            '\u{8}' => o.push_str("\\b"),
            '\u{c}' => o.push_str("\\f"),
            c if (c as u32) < 0x20 || (c as u32) >= 0x80 => {
                for u in c.encode_utf16(&mut [0; 2]) {
                    let _ = write!(o, "\\u{u:04x}");
                }
            }
            c => o.push(c),
        }
    }
    o
}

/// One output stream's masker. Output goes on as soon as it arrives, except a tail that could be the
/// start of a secret: that waits for the next write (or the end), so a value printed in two pieces is
/// still caught.
pub struct Masker {
    pats: Arc<Patterns>,
    held: Vec<u8>,
    /// which held bytes are already known to be part of a secret
    held_cov: Vec<bool>,
    /// the last byte written out was masked, so a secret that goes on in the next write adds no
    /// second "••••"
    in_mask: bool,
}

impl Masker {
    pub fn new(pats: Arc<Patterns>) -> Masker {
        Masker { pats, held: vec![], held_cov: vec![], in_mask: false }
    }

    /// What can be written out now, given the next chunk of output.
    pub fn feed(&mut self, chunk: &[u8]) -> Vec<u8> {
        if self.pats.is_empty() {
            return chunk.to_vec();
        }
        self.held.extend_from_slice(chunk);
        self.step(false)
    }

    /// The rest, at the end of the stream.
    pub fn finish(&mut self) -> Vec<u8> {
        self.step(true)
    }

    fn step(&mut self, end: bool) -> Vec<u8> {
        let buf = std::mem::take(&mut self.held);
        let mut cov = std::mem::take(&mut self.held_cov);
        cov.resize(buf.len(), false);
        self.pats.cover(&buf, &mut cov);
        let cut = if end { buf.len() } else { self.pats.cut(&buf) };
        let mut out = Vec::with_capacity(cut);
        for i in 0..cut {
            if !cov[i] {
                out.push(buf[i]);
            } else if !self.in_mask {
                out.extend_from_slice(MASK.as_bytes());
            }
            self.in_mask = cov[i];
        }
        self.held = buf[cut..].to_vec();
        self.held_cov = cov[cut..].to_vec();
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "sk-TEST-a1b2c3d4e5f6";

    fn mask(secrets: &[&str], text: &[u8]) -> Vec<u8> {
        let mut m = Masker::new(Arc::new(Patterns::new(secrets)));
        let mut out = m.feed(text);
        out.extend(m.finish());
        out
    }

    fn masked(secrets: &[&str], text: &str) -> String {
        String::from_utf8(mask(secrets, text.as_bytes())).unwrap()
    }

    /// byte by byte, as if each one came in its own write
    fn trickle(secrets: &[&str], text: &[u8]) -> Vec<u8> {
        let mut m = Masker::new(Arc::new(Patterns::new(secrets)));
        let mut out = vec![];
        for b in text {
            out.extend(m.feed(&[*b]));
        }
        out.extend(m.finish());
        out
    }

    #[test]
    fn the_value_itself() {
        assert_eq!(masked(&[KEY], &format!("OPENAI_API_KEY={KEY}\n")), "OPENAI_API_KEY=••••\n");
        assert_eq!(masked(&[KEY], &format!("{KEY}{KEY} and {KEY}")), "•••• and ••••");
        assert_eq!(masked(&[KEY], "nothing to see\n"), "nothing to see\n");
    }

    #[test]
    fn encodings() {
        let s = "TEST p@ss/\"wörd\"\\x!(1)";
        let b = s.as_bytes();
        let json = serde_json::to_string(s).unwrap();
        for (what, shown) in [
            ("json", json[1..json.len() - 1].to_string()),
            ("json ascii", json_ascii(s)),
            ("url", String::from_utf8(pct(b, |c| c.is_ascii_alphanumeric() || b"-._~".contains(&c), true, false)).unwrap()),
            ("url lower", String::from_utf8(pct(b, |c| c.is_ascii_alphanumeric() || b"-._~".contains(&c), false, false)).unwrap()),
            ("python quote", "TEST%20p%40ss/%22w%C3%B6rd%22%5Cx%21%281%29".to_string()),
            ("encodeURIComponent", "TEST%20p%40ss%2F%22w%C3%B6rd%22%5Cx!(1)".to_string()),
            ("form", "TEST+p%40ss%2F%22w%C3%B6rd%22%5Cx%21%281%29".to_string()),
            ("hex", HEXLOWER.encode(b)),
            ("HEX", HEXUPPER.encode(b)),
            ("base64", BASE64.encode(b)),
            ("base64 url", BASE64URL.encode(b)),
            ("base64 bare", BASE64_NOPAD.encode(b)),
        ] {
            assert_ne!(shown, s, "{what} should differ from the raw value");
            assert_eq!(masked(&[s], &format!("[{shown}]")), "[••••]", "{what}: {shown}");
        }
        assert_eq!(masked(&[s], r#"{"password":"TEST p@ss/\"wörd\"\\x!(1)"}"#), r#"{"password":"••••"}"#);
    }

    #[test]
    fn base64_inside_a_longer_stream() {
        // the value sits at each byte alignment inside other data, the way `base64` of a whole file or
        // an HTTP basic auth header ("user:KEY") shows it
        for before in ["", "u", "us", "use", "user:"] {
            for after in ["", "x", "xy"] {
                let whole = format!("{before}{KEY}{after}");
                for enc in [&BASE64, &BASE64URL] {
                    let shown = enc.encode(whole.as_bytes());
                    let out = masked(&[KEY], &shown);
                    assert!(out.contains(MASK), "{before}|{after}: {shown} -> {out}");
                    // what's left on either side is at most the group or two that also hold other bytes
                    assert!(out.len() - MASK.len() <= 8 + 4, "{before}|{after}: {out}");
                }
            }
        }
    }

    #[test]
    fn split_across_writes() {
        let text = format!("start {KEY} mid {} end", BASE64.encode(KEY.as_bytes()));
        assert_eq!(String::from_utf8(trickle(&[KEY], text.as_bytes())).unwrap(), "start •••• mid •••• end");
        // two writes, cut in the middle of the value
        let mut m = Masker::new(Arc::new(Patterns::new(&[KEY])));
        let first = m.feed(b"key: sk-TEST-a1");
        assert_eq!(first, b"key: ", "the start of the value waits for the rest");
        let mut out = first;
        out.extend(m.feed(b"b2c3d4e5f6\n"));
        assert_eq!(out, "key: ••••\n".as_bytes());
    }

    #[test]
    fn output_is_not_held_back_needlessly() {
        let mut m = Masker::new(Arc::new(Patterns::new(&[KEY])));
        assert_eq!(m.feed(b"progress 10%\r"), b"progress 10%\r");
        assert_eq!(m.feed(b"line\n"), b"line\n");
        // a tail that only might be the start of the value waits, and comes out as is when it isn't
        assert_eq!(m.feed(b"ask"), b"a");
        assert_eq!(m.feed(b"ed\n"), b"sked\n");
        assert_eq!(m.feed(b"sk-"), b"");
        assert_eq!(m.finish(), b"sk-");
    }

    #[test]
    fn overlapping_and_adjacent_values() {
        let (a, b) = ("abcdefgh", "efghijkl");
        assert_eq!(masked(&[a, b], "<abcdefghijkl>"), "<••••>");
        assert_eq!(masked(&[a, b], "<abcdefghefghijkl>"), "<••••>");
        assert_eq!(masked(&[a, b], "<abcdefgh efghijkl>"), "<•••• ••••>");
        // the end of one value is the start of another, and the second never finishes
        let (a, b) = ("abcdefgh", "ghijklmn");
        for chunks in [vec!["abcdefgh", "xy"], vec!["abcdefgh", "ij", "xy"], vec!["abcdefgh", "ijklmn"]] {
            let mut m = Masker::new(Arc::new(Patterns::new(&[a, b])));
            let mut out = vec![];
            for c in &chunks {
                out.extend(m.feed(c.as_bytes()));
            }
            out.extend(m.finish());
            let out = String::from_utf8(out).unwrap();
            assert!(!out.contains("gh"), "{chunks:?}: {out}");
            assert!(out.starts_with(MASK) && out.matches(MASK).count() == 1, "{chunks:?}: {out}");
        }
    }

    #[test]
    fn binary_passes_through() {
        let bytes: Vec<u8> = (0..=255u8).cycle().take(4096).collect();
        assert_eq!(mask(&[KEY], &bytes), bytes);
        assert_eq!(trickle(&[KEY], &bytes), bytes);
        let mut with = bytes.clone();
        with.splice(100..100, KEY.bytes());
        let out = mask(&[KEY], &with);
        assert_eq!(&out[..100], &bytes[..100]);
        assert_eq!(&out[100..100 + MASK.len()], MASK.as_bytes());
        assert_eq!(&out[100 + MASK.len()..], &bytes[100..]);
    }

    #[test]
    fn short_values_pass_through() {
        assert_eq!(masked(&["737", "12345"], "cvc 737, pin 12345"), "cvc 737, pin 12345");
        assert_eq!(masked(&["737", KEY], &format!("737 {KEY}")), "737 ••••");
        assert!(Patterns::new(&["12345"]).is_empty());
    }

    #[test]
    fn lines_on_a_terminal() {
        let note = "TEST line one\nTEST line two";
        assert_eq!(masked(&[note], "a\r\nTEST line one\r\nTEST line two\r\nb"), "a\r\n••••\r\nb");
    }
}
