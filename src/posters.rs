//! Posters for the Continue watching tab: one small frame per file, taken where it was left off.
//!
//! Like the scrub thumbnails (`thumbs.rs`) this runs a hidden libmpv instance on its own thread,
//! but one that hops from file to file: for each request it opens the file at that moment
//! (nearest keyframe), scales the first frame into the requested box (letterboxed in black) and
//! hands the UI a pointer it can show with `overlay-add`. The scrub thumbnails keep their own
//! instance, so hovering the seek bar and filling the tab never undo each other's work.
//!
//! Nothing is written to disk. Posters live for the session; the engine is shut down again
//! after a minute without requests.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, RecvTimeoutError, Sender};
use std::sync::Arc;
use std::time::Duration;

use crate::mpv::{Ev, Mpv};
use crate::thumbs::{start_engine, wait_for};

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Req {
    pub path: String,
    pub t: i64,
    pub w: u32,
    pub h: u32,
}

impl Req {
    /// `doga-poster <path> <seconds> <w> <h>` from the UI script.
    pub fn parse(args: &[String]) -> Option<Req> {
        Some(Req {
            path: args.get(1)?.clone(),
            t: args.get(2)?.parse::<f64>().ok()? as i64,
            w: args.get(3)?.parse().ok()?,
            h: args.get(4)?.parse().ok()?,
        })
    }
}

/// Requests waiting beyond this are dropped (the oldest first); the UI asks again for rows in view.
const MAX_QUEUED: usize = 64;

pub fn spawn(main: Arc<Mpv>, dll: PathBuf) -> Sender<Req> {
    let (tx, rx) = channel();
    let _ = std::thread::Builder::new().name("doga-posters".into()).spawn(move || run(main, dll, rx));
    tx
}

fn run(main: Arc<Mpv>, dll: PathBuf, rx: Receiver<Req>) {
    let mut eng: Option<Mpv> = None;
    let mut size = (0u32, 0u32);
    // Buffers are kept for the session; the UI may be showing any of them. It asks once per
    // file and size (a 144×81 poster is ~46 KB), so this stays small.
    let mut cache: HashMap<Req, Option<Box<[u8]>>> = HashMap::new();
    let mut queue: VecDeque<Req> = VecDeque::new();
    let mut queued: HashSet<Req> = HashSet::new();

    loop {
        // Take everything that has arrived; sleep when there is nothing to do.
        if queue.is_empty() {
            match rx.recv_timeout(Duration::from_secs(60)) {
                Ok(r) => {
                    queued.insert(r.clone());
                    queue.push_back(r);
                }
                Err(RecvTimeoutError::Timeout) => {
                    eng = None; // idle: give the memory back
                    continue;
                }
                Err(RecvTimeoutError::Disconnected) => return,
            }
        }
        while let Ok(r) = rx.try_recv() {
            if queued.insert(r.clone()) {
                queue.push_back(r);
            }
        }
        while queue.len() > MAX_QUEUED {
            if let Some(old) = queue.pop_front() {
                queued.remove(&old);
            }
        }
        let Some(job) = queue.pop_front() else { continue };
        queued.remove(&job);
        if job.w == 0 || job.h == 0 || job.w > 1024 || job.h > 1024 {
            continue;
        }

        if let Some(done) = cache.get(&job) {
            match done {
                Some(buf) => notify(&main, &job, Some((buf.as_ptr() as usize, job.w, job.h))),
                None => notify(&main, &job, None),
            }
            continue;
        }

        if eng.is_none() {
            match start_engine(&dll) {
                Some(m) => {
                    eng = Some(m);
                    size = (0, 0);
                }
                None => return,
            }
        }
        let m = eng.as_ref().unwrap();
        if size != (job.w, job.h) {
            m.set_prop(
                "vf",
                &format!(
                    "lavfi=[scale={w}:{h}:force_original_aspect_ratio=decrease:flags=bilinear,pad={w}:{h}:-1:-1:color=black]",
                    w = job.w,
                    h = job.h
                ),
            );
            size = (job.w, job.h);
        }
        // Open the file straight at the moment wanted (keyframe before it), so one decode does.
        m.set_prop("start", &job.t.max(0).to_string());
        let _ = m.command(&["loadfile", &job.path, "replace"]);
        let loaded = wait_for(m, Duration::from_secs(8), |ev| match ev {
            Ev::FileLoaded => Some(true),
            Ev::EndFile => Some(false),
            _ => None,
        });
        let frame = if loaded && wait_for(m, Duration::from_secs(4), |ev| matches!(ev, Ev::PlaybackRestart).then_some(true)) {
            m.screenshot_bgra().filter(|f| f.w == job.w && f.h == job.h)
        } else {
            None
        };
        if loaded {
            // Close it and take its end-of-file event here, or the next request would read it
            // as its own file failing to open.
            let _ = m.command(&["stop"]);
            wait_for(m, Duration::from_secs(2), |ev| matches!(ev, Ev::EndFile).then_some(true));
        }

        match frame {
            Some(f) => {
                let buf = f.data.into_boxed_slice();
                let addr = buf.as_ptr() as usize;
                cache.insert(job.clone(), Some(buf));
                notify(&main, &job, Some((addr, job.w, job.h)));
            }
            None => {
                cache.insert(job.clone(), None);
                notify(&main, &job, None);
            }
        }
    }
}

fn notify(main: &Mpv, job: &Req, img: Option<(usize, u32, u32)>) {
    let t = job.t.to_string();
    let _ = match img {
        Some((addr, w, h)) => main.command(&[
            "script-message-to",
            "doga",
            "doga-poster-ready",
            &job.path,
            &t,
            &addr.to_string(),
            &w.to_string(),
            &h.to_string(),
        ]),
        None => main.command(&["script-message-to", "doga", "doga-poster-ready", &job.path, &t, "0", "0", "0"]),
    };
}
