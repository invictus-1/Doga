// Dōga — a small native host around libmpv.
// It owns startup, the engine settings that keep picture and sound untouched,
// folder/series detection and the Open dialog. The on-screen chrome lives in ui/doga.lua.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod ipc;
mod mpv;
mod pack;
mod series;
mod setup;
mod splash;
mod sys;
mod thumbs;
mod update;
mod win;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use mpv::{Ev, Mpv};

/// Debug builds only: DOGA_DEV_SCRIPT="1.5|cmd;3|cmd2" runs input.conf-style commands at
/// given seconds after start (used to drive the UI for screenshots during development).
pub struct DevScript {
    steps: Vec<(f64, String)>,
    started: std::time::Instant,
}

impl DevScript {
    pub fn from_env() -> DevScript {
        let steps = if cfg!(debug_assertions) {
            std::env::var("DOGA_DEV_SCRIPT")
                .unwrap_or_default()
                .split(';')
                .filter_map(|s| s.split_once('|'))
                .filter_map(|(t, c)| Some((t.trim().parse().ok()?, c.trim().to_string())))
                .collect()
        } else {
            Vec::new()
        };
        DevScript { steps, started: std::time::Instant::now() }
    }
    /// Event-wait timeout: block forever unless steps are pending.
    pub fn timeout(&self) -> f64 {
        if self.steps.is_empty() { -1.0 } else { 0.05 }
    }
    pub fn run(&mut self, m: &Mpv) {
        while let Some((t, _)) = self.steps.first() {
            if self.started.elapsed().as_secs_f64() < *t {
                break;
            }
            let (_, cmd) = self.steps.remove(0);
            if let Err(e) = m.command_str(&cmd) {
                eprintln!("[doga] dev command '{cmd}': {e}");
            }
        }
    }
}

fn main() {
    win::dpi_aware();
    // (args_os: a stray unpaired surrogate in a file name must not panic the launch)
    let argv: Vec<String> = std::env::args_os().map(|a| a.to_string_lossy().into_owned()).collect();

    // doga.exe --pack <out.exe>   (build step: this exe + libmpv + ui → one installer)
    if argv.get(1).map(String::as_str) == Some("--pack") {
        let out = PathBuf::from(argv.get(2).map(String::as_str).unwrap_or("Doga-Setup.exe"));
        let exe_dir = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)).unwrap_or_default();
        let root = find_up(&exe_dir, &["vendor/mpv/libmpv-2.dll"]).and_then(|p| p.ancestors().nth(3).map(Path::to_path_buf));
        match root.ok_or("vendor/mpv/libmpv-2.dll not found".to_string()).and_then(|r| pack::build(&out, &r)) {
            Ok(()) => {}
            Err(e) => {
                eprintln!("pack failed: {e}");
                std::process::exit(1);
            }
        }
        return;
    }
    // release tooling: doga.exe --gen-update-key   |   doga.exe --sign <file>
    if argv.get(1).map(String::as_str) == Some("--gen-update-key") {
        let exe_dir = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)).unwrap_or_default();
        let root = find_up(&exe_dir, &["Cargo.toml"]).and_then(|p| p.parent().map(Path::to_path_buf));
        if let Err(e) = root.ok_or("project root not found".to_string()).and_then(|r| update::gen_key(&r)) {
            eprintln!("{e}");
            std::process::exit(1);
        }
        return;
    }
    if argv.get(1).map(String::as_str) == Some("--sign") {
        if let Err(e) = argv.get(2).ok_or("usage: --sign <file>".to_string()).and_then(|f| update::sign(Path::new(f))) {
            eprintln!("{e}");
            std::process::exit(1);
        }
        return;
    }
    if argv.get(1).map(String::as_str) == Some("--uninstall") {
        setup::run_uninstaller(&argv);
        return;
    }
    // An installer is this same exe with a payload appended.
    if let Some(payload) = pack::Payload::open_self() {
        setup::run_installer(payload);
        return;
    }
    run_player();
}

fn run_player() {
    let exe = std::env::current_exe().unwrap_or_default();
    let exe_dir = exe.parent().map(Path::to_path_buf).unwrap_or_default();

    let Some(dll) = find_up(&exe_dir, &["libmpv-2.dll", "vendor/mpv/libmpv-2.dll"]) else {
        win::message_box(
            "Dōga",
            "libmpv-2.dll was not found.\n\nPut it next to doga.exe (or in vendor\\mpv\\ while developing).",
        );
        return;
    };
    let Some(ui) = find_up(&exe_dir, &["ui/doga.lua"]).and_then(|p| p.parent().map(Path::to_path_buf)) else {
        win::message_box("Dōga", "The ui folder (ui\\doga.lua) was not found next to doga.exe.");
        return;
    };
    let data = std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| exe_dir.clone()).join("Doga");
    let _ = std::fs::create_dir_all(data.join("watch_later"));

    // Files from the command line / "Open with" / a drop onto the exe.
    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|a| {
            let p = PathBuf::from(&a);
            if p.exists() { std::path::absolute(&p).unwrap_or(p).to_string_lossy().into_owned() } else { a.to_string_lossy().into_owned() }
        })
        .collect();

    // One window: if Dōga is already open, hand it the files (or bring it forward) and leave.
    // (Debug UI test runs opt out so they never touch a Dōga you have open.)
    let dev_run = cfg!(debug_assertions) && std::env::var_os("DOGA_DEV_SCRIPT").is_some();
    if !dev_run && ipc::another_instance() && ipc::forward(&args) {
        return;
    }

    // Listen for further launches before the engine loads, so a second file opened while this
    // one is still starting is handed over instead of timing out and opening a second window.
    // (Test runs only get the drop handling.)
    let (tx, rx) = std::sync::mpsc::channel();
    if dev_run {
        let _ = ipc::serve_drops_only(tx);
    } else {
        ipc::serve(tx);
    }

    let mpv = match Mpv::load(&dll) {
        Ok(m) => m,
        Err(e) => {
            win::message_box("Dōga", &format!("Could not start the playback engine:\n{e}"));
            return;
        }
    };
    configure(&mpv, &ui, &data);
    if let Err(e) = mpv.initialize() {
        win::message_box("Dōga", &format!("Could not start the playback engine:\n{e}"));
        return;
    }
    let mpv = Arc::new(mpv);
    let thumbs = thumbs::spawn(mpv.clone(), dll.clone());

    for (i, f) in args.iter().enumerate() {
        let _ = mpv.command(&["loadfile", f, if i == 0 { "replace" } else { "append" }]);
    }
    // quiet daily update check (debug test runs only with DOGA_UPDATE_TEST set)
    if !cfg!(debug_assertions) || std::env::var_os("DOGA_UPDATE_TEST").is_some() {
        update::spawn_daily_check(mpv.clone(), data.clone());
    }
    {
        let m = mpv.clone();
        let had_args = !args.is_empty();
        std::thread::spawn(move || ipc_loop(m, rx, had_args));
    }

    let mut dev = DevScript::from_env();
    loop {
        let ev = mpv.wait(dev.timeout());
        dev.run(&mpv);
        match ev {
            Ev::Shutdown => break,
            Ev::FileLoaded => on_file_loaded(&mpv, &data),
            Ev::ClientMessage(args) => match args.first().map(String::as_str) {
                Some("doga-open") => open_dialog(&mpv),
                Some("doga-update-install") => update::spawn_install(mpv.clone()),
                Some("doga-update-check") => update::spawn_check_now(mpv.clone(), data.clone()),
                Some("doga-open-data") => sys::shell_open(&data.to_string_lossy()),
                Some("doga-open-shots") => {
                    if let Some(dir) = screenshot_dir() {
                        let _ = std::fs::create_dir_all(&dir);
                        sys::shell_open(&dir.to_string_lossy());
                    }
                }
                // only Dōga's own pages, never an arbitrary URL from a message
                Some("doga-open-url") if args.get(1).is_some_and(|u| u.starts_with("https://github.com/invictus-1/Doga")) => {
                    sys::shell_open(&args[1])
                }
                Some("doga-thumb") => {
                    if let Some(r) = thumbs::Req::parse(&args) {
                        let _ = thumbs.send(r);
                    }
                }
                _ => {}
            },
            _ => {}
        }
    }
    // mpv is closing. The core keeps serving its clients until they have all left, so give the
    // UI script a moment to finish writing settings and recents: it says "doga-bye" when done.
    // (Returning straight away ended the process in the middle of those writes.)
    let t0 = std::time::Instant::now();
    while t0.elapsed().as_millis() < 2000 {
        if let Ev::ClientMessage(args) = mpv.wait(0.05) {
            if args.first().map(String::as_str) == Some("doga-bye") {
                break;
            }
        }
    }
}

/// settings.json as the UI script wrote it, spaces removed, for the simple `"key":value` checks
/// the host does. Falls back to the previous copy if the file is missing or was cut short.
pub fn read_settings(data: &Path) -> String {
    for name in ["settings.json", "settings.json.bak"] {
        let s = std::fs::read_to_string(data.join(name)).unwrap_or_default().replace(' ', "");
        let t = s.trim();
        if t.starts_with('{') && t.ends_with('}') {
            return s;
        }
    }
    String::new()
}

/// One value inside mpv's comma-separated `script-opts`, length-quoted (`%n%text`) so a path
/// with a comma or quote in it arrives whole.
pub fn opt_quote(v: &str) -> String {
    format!("%{}%{}", v.len(), v)
}

/// Files from other launches, and drops on the player window.
/// `had_args`: this launch opened files itself (the first of an Explorer multi-select).
fn ipc_loop(m: Arc<Mpv>, rx: std::sync::mpsc::Receiver<ipc::Event>, had_args: bool) {
    // take over drops once the player window exists
    let t0 = std::time::Instant::now();
    let hwnd = loop {
        if let Some(h) = m.get_prop("window-id").and_then(|s| s.parse::<isize>().ok()) {
            break h;
        }
        if t0.elapsed().as_secs() > 10 {
            break 0;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    ipc::take_drops(hwnd);

    // Selecting several files and pressing Enter with Dōga closed starts one launch per file:
    // this one has the first, the rest arrive here a moment later and must queue behind it.
    let mut last_open = std::time::Instant::now();
    if !had_args {
        last_open -= std::time::Duration::from_secs(60);
    }
    for ev in rx {
        match ev {
            ipc::Event::Open(files) => {
                // several files opened together from Explorer arrive as separate launches
                // a moment apart: queue them instead of each replacing the last
                let together = last_open.elapsed().as_millis() < 800;
                for (i, f) in files.iter().enumerate() {
                    let mode = if i == 0 && !together { "replace" } else { "append" };
                    let _ = m.command(&["loadfile", f, mode]);
                }
                if !files.is_empty() {
                    last_open = std::time::Instant::now();
                }
                if hwnd != 0 {
                    ipc::raise(hwnd);
                }
            }
            ipc::Event::Drop(x, y, files) => {
                let mut args = vec!["script-message-to".to_string(), "doga".into(), "doga-drop".into(), x.to_string(), y.to_string()];
                args.extend(files);
                let refs: Vec<&str> = args.iter().map(String::as_str).collect();
                let _ = m.command(&refs);
            }
        }
    }
}

/// Look for any of `rels` next to the exe, then in up to four parent folders
/// (so `target\debug\doga.exe` finds the project's `ui` and `vendor`).
fn find_up(start: &Path, rels: &[&str]) -> Option<PathBuf> {
    start.ancestors().take(5).flat_map(|d| rels.iter().map(move |r| d.join(r))).find(|p| p.is_file())
}

fn has_font(ui: &Path, prefix: &str) -> bool {
    std::fs::read_dir(ui.join("fonts"))
        .map(|rd| rd.filter_map(|e| e.ok()).any(|e| e.file_name().to_string_lossy().starts_with(prefix)))
        .unwrap_or(false)
}

fn configure(m: &Mpv, ui: &Path, data: &Path) {
    let p = |x: &Path| x.to_string_lossy().replace('\\', "/");
    let ui_font = if has_font(ui, "ChakraPetch") { "Chakra Petch" } else { "Segoe UI" };
    let mono_font = if has_font(ui, "JetBrainsMono") { "JetBrains Mono" } else { "Consolas" };
    let sub_font = if has_font(ui, "NotoSans") { "Noto Sans" } else { "Segoe UI Semibold" };

    // Isolation: ignore any mpv.conf / scripts on this machine. Dōga's behaviour is defined here.
    m.opt("config", "no");
    m.opt("load-scripts", "no");
    m.opt("osc", "no");
    m.opt("ytdl", "no");
    for o in ["load-stats-overlay", "load-console", "load-auto-profiles", "load-select", "load-positioning", "load-commands", "load-context-menu"] {
        m.opt(o, "no");
    }
    if cfg!(debug_assertions) {
        m.opt("terminal", "yes");
        m.opt("msg-level", "all=info");
    }

    // Window: fit the video to the screen, never upscale the window past 100%.
    m.opt("force-window", "yes");
    m.opt("idle", "yes");
    m.opt("keep-open", "yes");
    m.opt("autofit-larger", "90%x90%");
    // Open the way it was last left: maximized, or windowed and fitted to the video.
    // (Fullscreen is never restored.) Applied before the window exists, so no jump.
    let settings = read_settings(data);
    if settings.contains("\"maximized\":true") {
        m.opt("window-maximized", "yes");
    }
    // Open on the monitor it was last on (fullscreen too). mpv on Windows numbers screens in
    // EnumDisplayMonitors order, so find the saved device's number in that same list.
    if let Some(d) = json_str_field(&settings, "display").map(|v| v.replace("\\\\", "\\")) {
        if let Some(i) = sys::monitors().iter().position(|n| n.eq_ignore_ascii_case(&d)) {
            m.opt("screen", &i.to_string());
            m.opt("fs-screen", &i.to_string());
        }
    }
    // Screenshots: the exact frame as PNG, into Pictures\Dōga.
    if let Some(dir) = screenshot_dir() {
        m.opt("screenshot-directory", &p(&dir));
    }
    m.opt("screenshot-format", "png");
    m.opt("screenshot-template", "%{filename/no-ext} %wH.%wM.%wS");
    m.opt("screenshot-tag-colorspace", "yes");
    // Settings that must be in place before the first file loads.
    let resume = !settings.contains("\"resume\":false");
    let hwdec = !settings.contains("\"hwdec\":false");
    if !resume {
        m.opt("resume-playback", "no");
    }
    // Preferred languages (set from the right-click menu), applied before the first file loads.
    for (key, opt) in [("alang", "alang"), ("slang", "slang")] {
        if let Some(v) = json_str_field(&settings, key).filter(|v| v.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == ',')) {
            if !v.is_empty() {
                m.opt(opt, &v);
            }
        }
    }
    m.opt("geometry", "50%:50%");
    m.opt("cursor-autohide", "1500");
    // The chrome owns left-drag (seek bar, volume, playlist rows); the title bar moves the window.
    m.opt("window-dragging", "no");
    // Drops are handled by the host (src/ipc.rs) so the UI knows where they landed.
    m.opt("drag-and-drop", "no");
    m.opt("title", "${?media-title:${media-title} — }Dōga");
    m.opt("background-color", "#000000");

    // Picture: honour the file's tags, no enhancements. Scaling is the only pixel change.
    m.opt("vo", "gpu-next");
    m.opt("gpu-api", "d3d11");
    m.opt("hwdec", if hwdec { "auto-safe" } else { "no" });
    m.opt("scale", "ewa_lanczossharp");
    m.opt("cscale", "ewa_lanczossharp");
    m.opt("dscale", "mitchell");
    m.opt("deband", "no");
    m.opt("icc-profile-auto", "no");
    m.opt("target-colorspace-hint", "auto");
    m.opt("tone-mapping", "bt.2390");
    m.opt("hdr-compute-peak", "no");
    m.opt("dither-depth", "auto");

    // Sound: unity gain, no normalisation, real channel layout.
    m.opt("volume", "100");
    m.opt("volume-max", "150");
    m.opt("audio-normalize-downmix", "no");
    m.opt("audio-channels", "auto-safe");
    m.opt("replaygain", "no");

    // Speed: big caches both ways so scrubbing back never touches the disk.
    m.opt("cache", "yes");
    m.opt("demuxer-max-bytes", "512MiB");
    m.opt("demuxer-max-back-bytes", "512MiB");
    m.opt("demuxer-readahead-secs", "30");

    // Subtitles: styled subs as authored; plain-text subs in the Dōga default.
    // "scale" (mpv's default) keeps ASS styling and lets sub-pos lift dialogue above the
    // controls; \pos-placed signs never move.
    m.opt("sub-auto", "fuzzy");
    m.opt("sub-ass-override", "scale");
    m.opt("sub-font", sub_font);
    m.opt("sub-font-size", "30");
    m.opt("sub-border-size", "2");
    m.opt("sub-shadow-offset", "0");
    m.opt("sub-color", "#FFFFFFFF");
    m.opt("sub-border-color", "#FF000000");
    m.opt("sub-fonts-dir", &p(&ui.join("fonts")));
    m.opt("osd-fonts-dir", &p(&ui.join("fonts")));
    m.opt("osd-font", ui_font);
    m.opt("osd-bar", "no");
    m.opt("osd-level", "1");

    // Resume where you stopped, with the tracks you picked.
    m.opt("save-position-on-quit", if resume { "yes" } else { "no" });
    m.opt("watch-later-dir", &p(&data.join("watch_later")));
    m.opt("watch-later-options", "start,aid,sid,sub-delay");

    // Keys and chrome.
    m.opt("input-default-bindings", "yes");
    m.opt("input-builtin-bindings", "no");
    m.opt("input-conf", &p(&ui.join("input.conf")));
    m.opt("input-vo-keyboard", "yes");
    // Media keys and the Windows media overlay (play/pause/next from keyboards & headphones)
    m.opt("input-media-keys", "yes");
    m.opt("media-controls", "yes");
    m.opt("scripts", &p(&ui.join("doga.lua")));
    let has_file = std::env::args_os().len() > 1;
    m.opt(
        "script-opts",
        &format!(
            "doga-datadir={},doga-uidir={},doga-uifont={ui_font},doga-monofont={mono_font},doga-hasfile={},doga-version={}",
            opt_quote(&p(data)),
            opt_quote(&p(ui)),
            if has_file { "yes" } else { "no" },
            update::VERSION
        ),
    );
}

/// When a single file is opened, fill the playlist with the rest of its series.
fn on_file_loaded(m: &Mpv, data: &Path) {
    // Settings › General › "Build the playlist from the folder"
    if read_settings(data).contains("\"autoplaylist\":false") {
        return;
    }
    let count: usize = m.get_prop("playlist-count").and_then(|s| s.parse().ok()).unwrap_or(0);
    let Some(path) = m.get_prop("path") else { return };
    let file = Path::new(&path);
    if count != 1 || !file.is_file() {
        return;
    }
    let dir_total = file
        .parent()
        .and_then(|d| std::fs::read_dir(d).ok())
        .map(|rd| rd.filter_map(|e| e.ok()).filter(|e| series::is_video(&e.path())).count())
        .unwrap_or(1);

    let Some(s) = series::detect(file) else {
        publish_series(m, None, dir_total, &[(path.clone(), String::new())]);
        return;
    };
    let mut entries = Vec::with_capacity(s.files.len());
    for (i, f) in s.files.iter().enumerate() {
        let fs = f.to_string_lossy().into_owned();
        if i == s.current {
            entries.push((path.clone(), s.labels[i].clone()));
            continue;
        }
        if i < s.current {
            // insert before the playing file, keeping order
            if m.command(&["loadfile", &fs, "insert-at", &i.to_string()]).is_err() {
                let _ = m.command(&["loadfile", &fs, "append"]);
                let last = m.get_prop("playlist-count").unwrap_or_default();
                let last: usize = last.parse().unwrap_or(1);
                let _ = m.command(&["playlist-move", &(last - 1).to_string(), &i.to_string()]);
            }
        } else {
            let _ = m.command(&["loadfile", &fs, "append"]);
        }
        entries.push((fs, s.labels[i].clone()));
    }
    publish_series(m, Some(&s.name), s.total, &entries);
}

/// Hand the detection result to the UI script as JSON in user-data/doga/series.
fn publish_series(m: &Mpv, name: Option<&str>, total: usize, entries: &[(String, String)]) {
    let mut j = String::from("{");
    j += &format!("\"name\":{},", name.map_or("null".to_string(), json_str));
    j += &format!("\"matched\":{},\"total\":{},\"entries\":{{", entries.len(), total);
    for (i, (p, l)) in entries.iter().enumerate() {
        if i > 0 {
            j.push(',');
        }
        j += &format!("{}:{}", json_str(p), json_str(l));
    }
    j += "}}";
    m.set_prop("user-data/doga/series", &j);
    let _ = m.command(&["script-message-to", "doga", "doga-series", &j]);
}

fn screenshot_dir() -> Option<PathBuf> {
    sys::pictures_dir().map(|p| p.join("Dōga"))
}

/// `"key":"value"` from flat JSON written by the UI script (simple values only).
fn json_str_field(json: &str, key: &str) -> Option<String> {
    let pat = format!("\"{key}\":\"");
    let start = json.find(&pat)? + pat.len();
    let end = json[start..].find('"')? + start;
    Some(json[start..end].to_string())
}

fn json_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o += "\\\"",
            '\\' => o += "\\\\",
            '\n' => o += "\\n",
            '\r' => o += "\\r",
            '\t' => o += "\\t",
            c if (c as u32) < 0x20 => o += &format!("\\u{:04x}", c as u32),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn open_dialog(m: &Mpv) {
    let owner: isize = m.get_prop("window-id").and_then(|s| s.parse().ok()).unwrap_or(0);
    let dir = m.get_prop("path").and_then(|p| Path::new(&p).parent().map(Path::to_path_buf)).filter(|d| d.is_dir());
    let files = win::open_files(owner, dir.as_deref());
    for (i, f) in files.iter().enumerate() {
        let _ = m.command(&["loadfile", &f.to_string_lossy(), if i == 0 { "replace" } else { "append" }]);
    }
}
