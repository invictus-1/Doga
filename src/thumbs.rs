//! Scrub-preview thumbnails.
//!
//! A second, hidden libmpv instance (no window, no audio, paused) runs on its own thread.
//! The UI asks for a slot ("key") on the timeline; the worker seeks that instance to the
//! nearest keyframe, scales the frame to preview size in the filter chain, grabs it as BGRA
//! and hands the UI a pointer it can show with `overlay-add`. The newest request always
//! wins; when idle it fills the neighbouring slots so scanning along the bar is instant.
//! The main player never waits on any of this.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant};

use crate::mpv::{Ev, Mpv};

#[derive(Clone, Debug)]
pub struct Req {
    pub path: String,
    pub key: i64,
    pub step: f64,
    pub w: u32,
    pub h: u32,
}

impl Req {
    /// `doga-thumb <path> <key> <step> <w> <h>` from the UI script.
    pub fn parse(args: &[String]) -> Option<Req> {
        Some(Req {
            path: args.get(1)?.clone(),
            key: args.get(2)?.parse().ok()?,
            step: args.get(3)?.parse().ok()?,
            w: args.get(4)?.parse().ok()?,
            h: args.get(5)?.parse().ok()?,
        })
    }
    fn time(&self) -> f64 {
        (self.key as f64 + 0.5) * self.step
    }
}

/// How many slots either side of the last request to fill while idle.
const PREFETCH: i64 = 16;
/// Upper bound on cached thumbnails for one file (a 1.5× preview is ~190 KB each).
const MAX_CACHED: usize = 400;

pub fn spawn(main: Arc<Mpv>, dll: PathBuf) -> Sender<Req> {
    let (tx, rx) = channel();
    let _ = std::thread::Builder::new().name("doga-thumbs".into()).spawn(move || run(main, dll, rx));
    tx
}

struct Engine {
    mpv: Mpv,
    path: String,
    ok: bool,
    dur: f64,
    size: (u32, u32),
}

fn start_engine(dll: &PathBuf) -> Option<Mpv> {
    let m = Mpv::load(dll).ok()?;
    for (k, v) in [
        ("config", "no"),
        ("load-scripts", "no"),
        ("osc", "no"),
        ("ytdl", "no"),
        ("terminal", "no"),
        ("idle", "yes"),
        ("force-window", "no"),
        ("vo", "null"),
        ("ao", "null"),
        ("aid", "no"),
        ("sid", "no"),
        ("pause", "yes"),
        ("keep-open", "always"),
        ("hr-seek", "no"),
        ("hwdec", "auto-copy-safe"),
        ("vd-lavc-skiploopfilter", "all"),
        ("vd-lavc-threads", "2"),
        ("cache", "no"),
        ("demuxer-readahead-secs", "0"),
        ("demuxer-max-bytes", "16MiB"),
        ("demuxer-max-back-bytes", "0"),
        ("load-stats-overlay", "no"),
        ("load-console", "no"),
        ("load-auto-profiles", "no"),
        ("load-select", "no"),
        ("load-positioning", "no"),
        ("load-commands", "no"),
        ("load-context-menu", "no"),
        ("save-position-on-quit", "no"),
        ("resume-playback", "no"),
        ("audio-display", "no"),
        ("sub-auto", "no"),
        ("audio-file-auto", "no"),
    ] {
        m.opt(k, v);
    }
    m.initialize().ok()?;
    Some(m)
}

/// Wait for one of `want` events, up to `timeout`.
fn wait_for(m: &Mpv, timeout: Duration, mut want: impl FnMut(&Ev) -> Option<bool>) -> bool {
    let t0 = Instant::now();
    while t0.elapsed() < timeout {
        let ev = m.wait(0.1);
        if let Some(ok) = want(&ev) {
            return ok;
        }
    }
    false
}

fn run(main: Arc<Mpv>, dll: PathBuf, rx: Receiver<Req>) {
    let mut eng: Option<Engine> = None;
    let mut cache: HashMap<i64, Box<[u8]>> = HashMap::new();
    // Buffers of earlier files/sizes stay alive one generation, in case the UI still shows one.
    let mut graveyard: VecDeque<HashMap<i64, Box<[u8]>>> = VecDeque::new();
    let mut prefetch: VecDeque<i64> = VecDeque::new();
    let mut base: Option<Req> = None;

    loop {
        // Newest explicit request wins; otherwise keep prefetching; otherwise sleep.
        let mut latest: Option<Req> = None;
        if prefetch.is_empty() {
            match rx.recv() {
                Ok(r) => latest = Some(r),
                Err(_) => return,
            }
        }
        while let Ok(r) = rx.try_recv() {
            latest = Some(r);
        }
        let job = if let Some(r) = latest {
            prefetch = (1..=PREFETCH).flat_map(|d| [r.key + d, r.key - d]).collect();
            base = Some(r.clone());
            r
        } else {
            match (prefetch.pop_front(), base.as_ref()) {
                (Some(k), Some(b)) => Req { key: k, ..b.clone() },
                _ => continue,
            }
        };
        if job.key < 0 || job.w == 0 || job.h == 0 || job.w > 1024 || job.h > 1024 {
            continue;
        }

        // Engine up (lazily, so startup never pays for it) and on the right file.
        if eng.is_none() {
            match start_engine(&dll) {
                Some(mpv) => eng = Some(Engine { mpv, path: String::new(), ok: false, dur: 0.0, size: (0, 0) }),
                None => return,
            }
        }
        let e = eng.as_mut().unwrap();
        if e.path != job.path {
            e.path = job.path.clone();
            graveyard.push_back(std::mem::take(&mut cache));
            if graveyard.len() > 2 {
                graveyard.pop_front();
            }
            let _ = e.mpv.command(&["loadfile", &job.path, "replace"]);
            e.ok = wait_for(&e.mpv, Duration::from_secs(8), |ev| match ev {
                Ev::FileLoaded => Some(true),
                Ev::EndFile => Some(false),
                _ => None,
            });
            if e.ok {
                // the first frame after loading also raises a restart; consume it
                wait_for(&e.mpv, Duration::from_secs(3), |ev| matches!(ev, Ev::PlaybackRestart).then_some(true));
                e.dur = e.mpv.get_prop("duration").and_then(|d| d.parse().ok()).unwrap_or(0.0);
            }
            e.size = (0, 0);
        }
        if !e.ok || (e.dur > 0.0 && job.time() > e.dur) {
            continue;
        }
        if e.size != (job.w, job.h) {
            e.mpv.set_prop("vf", &format!("lavfi=[scale={}:{}:flags=bilinear]", job.w, job.h));
            e.size = (job.w, job.h);
            graveyard.push_back(std::mem::take(&mut cache));
            if graveyard.len() > 2 {
                graveyard.pop_front();
            }
        }

        if let Some(buf) = cache.get(&job.key) {
            notify(&main, &job, buf.as_ptr() as usize, job.w, job.h);
            continue;
        }
        if cache.len() >= MAX_CACHED {
            continue;
        }
        let _ = e.mpv.command(&["seek", &format!("{:.3}", job.time()), "absolute+keyframes"]);
        if !wait_for(&e.mpv, Duration::from_secs(3), |ev| matches!(ev, Ev::PlaybackRestart).then_some(true)) {
            continue;
        }
        let Some(f) = e.mpv.screenshot_bgra() else { continue };
        let buf = f.data.into_boxed_slice();
        let addr = buf.as_ptr() as usize;
        cache.insert(job.key, buf);
        notify(&main, &job, addr, f.w, f.h);
    }
}

fn notify(main: &Mpv, job: &Req, addr: usize, w: u32, h: u32) {
    let _ = main.command(&[
        "script-message-to",
        "doga",
        "doga-thumb-ready",
        &job.path,
        &job.key.to_string(),
        &addr.to_string(),
        &w.to_string(),
        &h.to_string(),
    ]);
}
