//! Time-based one-time codes (RFC 6238). Accepts otpauth:// URIs, KeeOtp-style
//! `key=...&step=...` strings, or a bare base32 secret.

use hmac::{Hmac, Mac};
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Algo {
    Sha1,
    Sha256,
    Sha512,
}

#[derive(Debug, Clone)]
pub struct Totp {
    secret: Vec<u8>,
    pub digits: u32,
    pub period: u64,
    pub algo: Algo,
    pub issuer: Option<String>,
    pub account: Option<String>,
}

impl Totp {
    pub fn parse(input: &str) -> Result<Totp, String> {
        let s = input.trim();
        if s.len() > 10 && s[..10].eq_ignore_ascii_case("otpauth://") {
            return Self::parse_uri(s);
        }
        if s.contains("key=") {
            return Self::parse_keeotp(s);
        }
        Ok(Totp {
            secret: decode_secret(s)?,
            digits: 6,
            period: 30,
            algo: Algo::Sha1,
            issuer: None,
            account: None,
        })
    }

    fn parse_uri(s: &str) -> Result<Totp, String> {
        let u = url::Url::parse(s).map_err(|e| format!("not a valid otpauth link: {e}"))?;
        match u.host_str() {
            Some(h) if h.eq_ignore_ascii_case("totp") => {}
            Some(h) if h.eq_ignore_ascii_case("hotp") => {
                return Err("counter-based (hotp) codes aren't supported, only time-based ones".into())
            }
            _ => return Err("not an otpauth://totp link".into()),
        }
        let label = percent_decode(u.path().trim_start_matches('/'));
        let (mut issuer, account) = match label.split_once(':') {
            Some((i, a)) => (Some(i.trim().to_string()), Some(a.trim().to_string())),
            None if label.is_empty() => (None, None),
            None => (None, Some(label.clone())),
        };
        let mut t = Totp { secret: vec![], digits: 6, period: 30, algo: Algo::Sha1, issuer: None, account };
        let mut secret = None;
        for (k, v) in u.query_pairs() {
            match k.to_ascii_lowercase().as_str() {
                "secret" => secret = Some(v.to_string()),
                "issuer" if !v.is_empty() => issuer = Some(v.to_string()),
                "digits" => t.digits = v.parse().map_err(|_| "bad digits")?,
                "period" => t.period = v.parse().map_err(|_| "bad period")?,
                "algorithm" => t.algo = parse_algo(&v)?,
                _ => {}
            }
        }
        t.issuer = issuer;
        t.secret = decode_secret(&secret.ok_or("the link has no secret")?)?;
        t.check()?;
        Ok(t)
    }

    fn parse_keeotp(s: &str) -> Result<Totp, String> {
        let mut t = Totp { secret: vec![], digits: 6, period: 30, algo: Algo::Sha1, issuer: None, account: None };
        for (k, v) in url::form_urlencoded::parse(s.as_bytes()) {
            match k.as_ref() {
                "key" => t.secret = decode_secret(&v)?,
                "size" => t.digits = v.parse().map_err(|_| "bad size")?,
                "step" => t.period = v.parse().map_err(|_| "bad step")?,
                "otpHashMode" => t.algo = parse_algo(&v)?,
                _ => {}
            }
        }
        t.check()?;
        Ok(t)
    }

    fn check(&self) -> Result<(), String> {
        if self.secret.is_empty() {
            return Err("empty secret".into());
        }
        if !(6..=10).contains(&self.digits) {
            return Err("digits must be 6 to 10".into());
        }
        if self.period == 0 || self.period > 600 {
            return Err("period must be 1 to 600 seconds".into());
        }
        Ok(())
    }

    pub fn code_at(&self, unix: u64) -> String {
        let counter = (unix / self.period).to_be_bytes();
        let h = hmac_sha(self.algo, &self.secret, &counter);
        let o = (h[h.len() - 1] & 0x0f) as usize;
        let bin = ((h[o] as u64 & 0x7f) << 24) | ((h[o + 1] as u64) << 16) | ((h[o + 2] as u64) << 8) | h[o + 3] as u64;
        let code = bin % 10u64.pow(self.digits);
        format!("{:0width$}", code, width = self.digits as usize)
    }

    /// Current code and the seconds it stays valid.
    pub fn now(&self) -> (String, u64) {
        let t = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        (self.code_at(t), self.period - t % self.period)
    }

    /// Canonical otpauth URI, the form KeePassXC, Strongbox and KeePassium read from the `otp` field.
    pub fn to_uri(&self) -> String {
        let label = match (&self.issuer, &self.account) {
            (Some(i), Some(a)) => format!("{}:{}", percent_encode(i), percent_encode(a)),
            (Some(i), None) => percent_encode(i),
            (None, Some(a)) => percent_encode(a),
            (None, None) => "otto".into(),
        };
        let mut uri = format!(
            "otpauth://totp/{label}?secret={}&period={}&digits={}&algorithm={}",
            data_encoding::BASE32_NOPAD.encode(&self.secret),
            self.period,
            self.digits,
            match self.algo {
                Algo::Sha1 => "SHA1",
                Algo::Sha256 => "SHA256",
                Algo::Sha512 => "SHA512",
            }
        );
        if let Some(i) = &self.issuer {
            uri.push_str("&issuer=");
            uri.push_str(&percent_encode(i));
        }
        uri
    }
}

fn hmac_sha(algo: Algo, key: &[u8], msg: &[u8]) -> Vec<u8> {
    macro_rules! run {
        ($d:ty) => {{
            let mut m = Hmac::<$d>::new_from_slice(key).expect("hmac takes any key length");
            m.update(msg);
            m.finalize().into_bytes().to_vec()
        }};
    }
    match algo {
        Algo::Sha1 => run!(sha1::Sha1),
        Algo::Sha256 => run!(sha2::Sha256),
        Algo::Sha512 => run!(sha2::Sha512),
    }
}

fn parse_algo(v: &str) -> Result<Algo, String> {
    match v.to_ascii_uppercase().replace('-', "").as_str() {
        "SHA1" => Ok(Algo::Sha1),
        "SHA256" => Ok(Algo::Sha256),
        "SHA512" => Ok(Algo::Sha512),
        other => Err(format!("unsupported algorithm {other}")),
    }
}

fn decode_secret(s: &str) -> Result<Vec<u8>, String> {
    let clean: String = s
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-' && *c != '=')
        .map(|c| c.to_ascii_uppercase())
        .collect();
    if clean.is_empty() {
        return Err("empty secret".into());
    }
    data_encoding::BASE32_NOPAD
        .decode(clean.as_bytes())
        .map_err(|_| "the secret isn't valid base32 (letters A-Z and digits 2-7)".to_string())
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = |c: u8| (c as char).to_digit(16);
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc6238_vectors() {
        // RFC 6238 appendix B, 8 digits
        let mk = |secret: &[u8], algo| Totp { secret: secret.to_vec(), digits: 8, period: 30, algo, issuer: None, account: None };
        let s1 = mk(b"12345678901234567890", Algo::Sha1);
        let s256 = mk(b"12345678901234567890123456789012", Algo::Sha256);
        let s512 = mk(b"1234567890123456789012345678901234567890123456789012345678901234", Algo::Sha512);
        assert_eq!(s1.code_at(59), "94287082");
        assert_eq!(s256.code_at(59), "46119246");
        assert_eq!(s512.code_at(59), "90693936");
        assert_eq!(s1.code_at(1111111109), "07081804");
        assert_eq!(s1.code_at(20000000000), "65353130");
    }

    #[test]
    fn parses_uri_and_round_trips() {
        let t = Totp::parse("otpauth://totp/ACME%20Co:jane@acme.com?secret=JBSWY3DPEHPK3PXP&issuer=ACME%20Co&digits=6").unwrap();
        assert_eq!(t.issuer.as_deref(), Some("ACME Co"));
        assert_eq!(t.account.as_deref(), Some("jane@acme.com"));
        let back = Totp::parse(&t.to_uri()).unwrap();
        assert_eq!(back.code_at(1_700_000_000), t.code_at(1_700_000_000));
        let bare = Totp::parse("jbsw y3dp ehpk 3pxp").unwrap();
        assert_eq!(bare.code_at(1_700_000_000), t.code_at(1_700_000_000));
        assert!(Totp::parse("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP").is_err());
        assert!(Totp::parse("not base32 !!").is_err());
    }
}
