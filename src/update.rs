//! Quiet daily update check.
//!
//! A few seconds after launch, at most once every 24 hours, ask GitHub for the latest
//! release. If it's newer, tell the UI (it shows "Update to x.y.z"). Nothing is downloaded
//! until the user clicks. Then: download the installer and its .sig, verify the signature
//! against the public key built into this exe (ECDSA P-256, Windows CNG), and only if it
//! matches, run the installer in update mode and quit so it can replace us.
//!
//! The only network traffic is these HTTPS requests to GitHub. Set "updates": false in
//! %APPDATA%\Doga\settings.json to switch the check off.

use std::ffi::{c_void, OsStr};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::mpv::Mpv;
use crate::sys;
use crate::win::wide;

const REPO: &str = "invictus-1/Doga";
const USER_AGENT: &str = "Doga-Updater";
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
/// Public half of the release signing key (empty when built without one: updates off).
const PUBLIC_KEY: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/update.pub"));

// ------------------------------------------------------------------ WinHTTP

type H = *mut c_void;

#[link(name = "winhttp")]
extern "system" {
    fn WinHttpOpen(agent: *const u16, access: u32, proxy: *const u16, bypass: *const u16, flags: u32) -> H;
    fn WinHttpConnect(s: H, host: *const u16, port: u16, r: u32) -> H;
    fn WinHttpOpenRequest(c: H, verb: *const u16, path: *const u16, ver: *const u16, referrer: *const u16, accept: *const *const u16, flags: u32) -> H;
    fn WinHttpSetTimeouts(h: H, resolve: i32, connect: i32, send: i32, receive: i32) -> i32;
    fn WinHttpAddRequestHeaders(r: H, headers: *const u16, len: u32, mods: u32) -> i32;
    fn WinHttpSendRequest(r: H, headers: *const u16, hlen: u32, opt: *const c_void, olen: u32, total: u32, ctx: usize) -> i32;
    fn WinHttpReceiveResponse(r: H, reserved: *mut c_void) -> i32;
    fn WinHttpQueryHeaders(r: H, level: u32, name: *const u16, buf: *mut c_void, len: *mut u32, index: *mut u32) -> i32;
    fn WinHttpQueryDataAvailable(r: H, n: *mut u32) -> i32;
    fn WinHttpReadData(r: H, buf: *mut c_void, n: u32, read: *mut u32) -> i32;
    fn WinHttpCloseHandle(h: H) -> i32;
}

struct Handle(H);
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { WinHttpCloseHandle(self.0) };
        }
    }
}

/// HTTPS GET (follows redirects). `progress(done, total)` is called while reading.
fn https_get(url: &str, accept: Option<&str>, mut progress: impl FnMut(u64, u64)) -> Result<Vec<u8>, String> {
    let rest = url.strip_prefix("https://").ok_or("only https is allowed")?;
    let (host, path) = rest.split_once('/').map(|(h, p)| (h, format!("/{p}"))).unwrap_or((rest, "/".into()));
    unsafe {
        let agent = wide(OsStr::new(USER_AGENT));
        let s = Handle(WinHttpOpen(agent.as_ptr(), 4, std::ptr::null(), std::ptr::null(), 0)); // automatic proxy
        if s.0.is_null() {
            return Err("network unavailable".into());
        }
        WinHttpSetTimeouts(s.0, 10_000, 10_000, 15_000, 30_000);
        let h = wide(OsStr::new(host));
        let c = Handle(WinHttpConnect(s.0, h.as_ptr(), 443, 0));
        if c.0.is_null() {
            return Err("could not connect".into());
        }
        let verb = wide(OsStr::new("GET"));
        let p = wide(OsStr::new(&path));
        let r = Handle(WinHttpOpenRequest(c.0, verb.as_ptr(), p.as_ptr(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0x0080_0000)); // SECURE
        if r.0.is_null() {
            return Err("could not open request".into());
        }
        if let Some(a) = accept {
            let hdr = wide(OsStr::new(&format!("Accept: {a}")));
            WinHttpAddRequestHeaders(r.0, hdr.as_ptr(), u32::MAX, 0x2000_0000); // ADD
        }
        if WinHttpSendRequest(r.0, std::ptr::null(), 0, std::ptr::null(), 0, 0, 0) == 0 || WinHttpReceiveResponse(r.0, std::ptr::null_mut()) == 0 {
            return Err("request failed".into());
        }
        let mut status = 0u32;
        let mut len = 4u32;
        WinHttpQueryHeaders(r.0, 19 | 0x2000_0000, std::ptr::null(), &mut status as *mut u32 as *mut c_void, &mut len, std::ptr::null_mut());
        if status != 200 {
            return Err(format!("HTTP {status}"));
        }
        let mut total = 0u32;
        let mut len = 4u32;
        WinHttpQueryHeaders(r.0, 5 | 0x2000_0000, std::ptr::null(), &mut total as *mut u32 as *mut c_void, &mut len, std::ptr::null_mut());
        let mut out = Vec::with_capacity(total as usize);
        loop {
            let mut n = 0u32;
            if WinHttpQueryDataAvailable(r.0, &mut n) == 0 {
                return Err("download interrupted".into());
            }
            if n == 0 {
                break;
            }
            let start = out.len();
            out.resize(start + n as usize, 0);
            let mut read = 0u32;
            if WinHttpReadData(r.0, out[start..].as_mut_ptr() as *mut c_void, n, &mut read) == 0 {
                return Err("download interrupted".into());
            }
            out.truncate(start + read as usize);
            progress(out.len() as u64, total as u64);
            if out.len() > 512 << 20 {
                return Err("download too large".into());
            }
        }
        Ok(out)
    }
}

// ------------------------------------------------------------------ versions & release info

fn parse_version(v: &str) -> Option<(u32, u32, u32)> {
    let v = v.trim().trim_start_matches('v');
    let mut it = v.split(['.', '-', '+']).map(|p| p.parse::<u32>());
    Some((it.next()?.ok()?, it.next()?.ok()?, it.next().unwrap_or(Ok(0)).ok()?))
}

/// This build's version (debug builds may pretend to be older to test the updater).
fn current() -> String {
    if cfg!(debug_assertions) {
        if let Ok(v) = std::env::var("DOGA_FAKE_VERSION") {
            return v;
        }
    }
    VERSION.to_string()
}

pub fn is_newer(candidate: &str, current: &str) -> bool {
    matches!((parse_version(candidate), parse_version(current)), (Some(a), Some(b)) if a > b)
}

fn json_field<'a>(json: &'a str, key: &str) -> Option<&'a str> {
    let pat = format!("\"{key}\":");
    let i = json.find(&pat)? + pat.len();
    let rest = json[i..].trim_start().strip_prefix('"')?;
    Some(&rest[..rest.find('"')?])
}

#[derive(Clone, Debug, PartialEq)]
pub struct Release {
    pub version: String,
    pub installer: String,
    pub signature: String,
}

/// Pick out the version and the signed installer from GitHub's "latest release" JSON.
pub fn parse_release(json: &str) -> Option<Release> {
    let version = json_field(json, "tag_name")?.trim_start_matches('v').to_string();
    let urls: Vec<&str> = json.match_indices("\"browser_download_url\":").filter_map(|(i, _)| json_field(&json[i..], "browser_download_url")).collect();
    let installer = urls.iter().find(|u| u.contains("/Doga-Setup") && u.ends_with(".exe"))?.to_string();
    let signature = urls.iter().find(|u| **u == format!("{installer}.sig"))?.to_string();
    Some(Release { version, installer, signature })
}

// ------------------------------------------------------------------ the check

fn state_file(data: &Path) -> PathBuf {
    data.join("update.json")
}

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn notify(m: &Mpv, args: &[&str]) {
    let mut v = vec!["script-message-to", "doga", "doga-update"];
    v.extend_from_slice(args);
    let _ = m.command(&v);
}

/// Background thread: check at most daily; remember the result so a known update shows at
/// once on the next launch without asking the network again.
pub fn spawn_daily_check(m: Arc<Mpv>, data: PathBuf) {
    if PUBLIC_KEY.is_empty() {
        return;
    }
    let settings = std::fs::read_to_string(data.join("settings.json")).unwrap_or_default().replace(' ', "");
    if settings.contains("\"updates\":false") {
        return;
    }
    std::thread::spawn(move || {
        let saved = std::fs::read_to_string(state_file(&data)).unwrap_or_default();
        let last: u64 = saved.split("\"checked\":").nth(1).and_then(|s| s.split([',', '}']).next()).and_then(|s| s.trim().parse().ok()).unwrap_or(0);
        let known = json_field(&saved, "latest").map(str::to_string);
        if let Some(v) = known.as_deref().filter(|v| is_newer(v, &current())) {
            std::thread::sleep(std::time::Duration::from_secs(2));
            notify(&m, &["available", v]);
        }
        if now().saturating_sub(last) < 24 * 3600 && std::env::var_os("DOGA_UPDATE_FORCE").is_none() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_secs(8)); // never compete with startup
        let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
        let Ok(body) = https_get(&url, Some("application/vnd.github+json"), |_, _| {}) else { return };
        let Some(rel) = parse_release(&String::from_utf8_lossy(&body)) else { return };
        let _ = std::fs::write(state_file(&data), format!("{{\"checked\":{},\"latest\":\"{}\"}}", now(), rel.version));
        if is_newer(&rel.version, &current()) && known.as_deref() != Some(rel.version.as_str()) {
            notify(&m, &["available", &rel.version]);
        }
    });
}

/// Settings › About › "Check now": always asks, always answers (available / current / error).
pub fn spawn_check_now(m: Arc<Mpv>, data: PathBuf) {
    std::thread::spawn(move || {
        let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
        let body = match https_get(&url, Some("application/vnd.github+json"), |_, _| {}) {
            Ok(b) => b,
            Err(e) => return notify(&m, &["error", &format!("couldn't reach GitHub ({e})")]),
        };
        match parse_release(&String::from_utf8_lossy(&body)) {
            Some(rel) => {
                let _ = std::fs::write(state_file(&data), format!("{{\"checked\":{},\"latest\":\"{}\"}}", now(), rel.version));
                if is_newer(&rel.version, &current()) {
                    notify(&m, &["available", &rel.version]);
                } else {
                    notify(&m, &["current", &current()]);
                }
            }
            None => notify(&m, &["current", &current()]),
        }
    });
}

/// User clicked "Update": download, verify, hand over to the installer, quit.
pub fn spawn_install(m: Arc<Mpv>) {
    std::thread::spawn(move || {
        let fail = |m: &Mpv, why: &str| notify(m, &["error", why]);
        let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
        let rel = match https_get(&url, Some("application/vnd.github+json"), |_, _| {}).ok().and_then(|b| parse_release(&String::from_utf8_lossy(&b))) {
            Some(r) => r,
            None => return fail(&m, "couldn't reach GitHub"),
        };
        if !is_newer(&rel.version, &current()) {
            return notify(&m, &["current", &current()]);
        }
        let mut last_pct = u64::MAX;
        let exe = match https_get(&rel.installer, None, |done, total| {
            let pct = if total > 0 { done * 100 / total } else { 0 };
            if pct / 5 != last_pct / 5 {
                last_pct = pct;
                notify(&m, &["downloading", &rel.version, &pct.to_string()]);
            }
        }) {
            Ok(b) => b,
            Err(e) => return fail(&m, &format!("download failed ({e})")),
        };
        let sig = match https_get(&rel.signature, None, |_, _| {}) {
            Ok(b) => b,
            Err(_) => return fail(&m, "signature missing"),
        };
        notify(&m, &["verifying", &rel.version]);
        if !sys::ecdsa_verify(PUBLIC_KEY, &exe, &sig) {
            return fail(&m, "signature check failed, so nothing was installed");
        }
        let path = std::env::temp_dir().join(format!("Doga-Setup-{}.exe", rel.version));
        if std::fs::write(&path, &exe).is_err() {
            return fail(&m, "couldn't save the installer");
        }
        if std::env::var_os("DOGA_UPDATE_DRYRUN").is_some() {
            return notify(&m, &["verified", &rel.version]);
        }
        if std::process::Command::new(&path).arg("--update").spawn().is_err() {
            return fail(&m, "couldn't start the installer");
        }
        let _ = m.command(&["quit"]);
    });
}

// ------------------------------------------------------------------ release tooling

fn key_path() -> Option<PathBuf> {
    std::env::var_os("USERPROFILE").map(|p| PathBuf::from(p).join(".doga-release").join("update.key"))
}

/// `doga.exe --gen-update-key <project root>`: new signing key. The private half goes to
/// %USERPROFILE%\.doga-release\update.key (never in the repo), the public half to
/// assets/update.pub (committed, built into the exe).
pub fn gen_key(root: &Path) -> Result<(), String> {
    let kp = key_path().ok_or("no USERPROFILE")?;
    if kp.exists() {
        return Err(format!("{} already exists; refusing to overwrite it", kp.display()));
    }
    let (private, public) = sys::ecdsa_generate().ok_or("key generation failed")?;
    std::fs::create_dir_all(kp.parent().unwrap()).map_err(|e| e.to_string())?;
    std::fs::write(&kp, private).map_err(|e| e.to_string())?;
    std::fs::write(root.join("assets").join("update.pub"), public).map_err(|e| e.to_string())?;
    eprintln!("private key: {} (back this up; never commit it)", kp.display());
    eprintln!("public key:  assets/update.pub");
    Ok(())
}

/// `doga.exe --sign <file>`: write <file>.sig with the release key.
pub fn sign(file: &Path) -> Result<(), String> {
    let kp = key_path().ok_or("no USERPROFILE")?;
    let private = std::fs::read(&kp).map_err(|_| format!("no signing key at {}", kp.display()))?;
    let data = std::fs::read(file).map_err(|e| e.to_string())?;
    let sig = sys::ecdsa_sign(&private, &data).ok_or("signing failed")?;
    let out = PathBuf::from(format!("{}.sig", file.display()));
    std::fs::write(&out, &sig).map_err(|e| e.to_string())?;
    if !PUBLIC_KEY.is_empty() && !sys::ecdsa_verify(PUBLIC_KEY, &data, &sig) {
        return Err("signature doesn't match the public key built into this exe".into());
    }
    eprintln!("wrote {}", out.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions() {
        assert!(is_newer("0.2.0", "0.1.0"));
        assert!(is_newer("v1.0.0", "0.9.9"));
        assert!(is_newer("0.1.10", "0.1.9"));
        assert!(!is_newer("0.1.0", "0.1.0"));
        assert!(!is_newer("0.0.9", "0.1.0"));
        assert!(!is_newer("garbage", "0.1.0"));
    }

    // Network: read-only GET of the public "latest release" JSON. Run with --ignored.
    #[test]
    #[ignore]
    fn live_latest_release_fetch() {
        let url = format!("https://api.github.com/repos/{REPO}/releases/latest");
        let body = https_get(&url, Some("application/vnd.github+json"), |_, _| {}).expect("GitHub reachable over WinHTTP");
        let json = String::from_utf8_lossy(&body);
        let tag = json_field(&json, "tag_name").expect("tag_name present");
        eprintln!("latest release on GitHub: {tag}; signed installer: {}", parse_release(&json).is_some());
    }

    #[test]
    fn picks_signed_installer_from_release_json() {
        let json = r#"{"tag_name":"v0.2.0","assets":[
            {"name":"Doga-Setup-0.2.0.exe","browser_download_url":"https://github.com/invictus-1/Doga/releases/download/v0.2.0/Doga-Setup-0.2.0.exe"},
            {"name":"Doga-Setup-0.2.0.exe.sig","browser_download_url":"https://github.com/invictus-1/Doga/releases/download/v0.2.0/Doga-Setup-0.2.0.exe.sig"}]}"#;
        let r = parse_release(json).unwrap();
        assert_eq!(r.version, "0.2.0");
        assert!(r.installer.ends_with("Doga-Setup-0.2.0.exe"));
        assert!(r.signature.ends_with("Doga-Setup-0.2.0.exe.sig"));
        // no signature asset → no update offered
        let unsigned = r#"{"tag_name":"v0.2.0","assets":[{"browser_download_url":"https://x/Doga-Setup-0.2.0.exe"}]}"#;
        assert!(parse_release(unsigned).is_none());
    }
}
