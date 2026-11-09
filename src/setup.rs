//! Installer and uninstaller.
//!
//! The installer is doga.exe with a payload appended (see pack.rs). It unpacks the engine
//! and UI to a temp folder, opens a window drawn by the same engine as the player
//! (ui/installer.lua), and installs per-user — no admin rights, no UAC prompt:
//!   %LOCALAPPDATA%\Programs\Doga\  doga.exe · libmpv-2.dll · ui\
//!   Start menu shortcut, optional desktop shortcut, optional "Open with" registration,
//!   and an entry in Settings › Apps (uninstall).
//! Set DOGA_SETUP_DRYRUN=1 to install into a folder without touching shortcuts or the registry.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::mpv::{Ev, Mpv};
use crate::pack::Payload;
use crate::{series, sys, win};

const UNINSTALL_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Doga";
const PROGID: &str = "Doga.Video";
const MARKER: &str = ".doga-install";
const VERSION: &str = env!("CARGO_PKG_VERSION");

fn dry_run() -> bool {
    std::env::var_os("DOGA_SETUP_DRYRUN").is_some_and(|v| v == "1")
}

fn default_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("DOGA_SETUP_DIR") {
        return PathBuf::from(d);
    }
    if let Some(prev) = sys::reg_get_str(UNINSTALL_KEY, "InstallLocation") {
        return PathBuf::from(prev);
    }
    std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_default().join(r"Programs\Doga")
}

fn fwd(p: &Path) -> String {
    p.to_string_lossy().replace('\\', "/")
}

// ------------------------------------------------------------------ installer

pub fn run_installer(pl: Payload) {
    let tmp = std::env::temp_dir().join(format!("doga-setup-{}", std::process::id()));
    // Unpack on a worker while a native placeholder window is already on screen.
    let k = sys::dpi_scale();
    let (cw, ch) = ((880.0 * k).round() as i32, (560.0 * k).round() as i32);
    let splash = crate::splash::Splash::show("Dōga Setup", cw, ch);
    let pl = Arc::new(pl);
    let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let worker = {
        let (pl, tmp, done) = (pl.clone(), tmp.clone(), done.clone());
        std::thread::spawn(move || {
            let r = unpack(&pl, &tmp);
            done.store(true, std::sync::atomic::Ordering::Release);
            r
        })
    };
    if let Some(s) = &splash {
        s.pump_until(&done);
    }
    let unpacked = worker.join().unwrap_or_else(|_| Err("unpack crashed".into()));
    if let Err(e) = unpacked {
        drop(splash);
        win::message_box("Dōga Setup", &format!("The installer could not unpack itself:\n{e}"));
        return;
    }
    let dll = tmp.join("libmpv-2.dll");
    let ui = tmp.join("ui");
    let mpv = match Mpv::load(&dll) {
        Ok(m) => m,
        Err(e) => {
            win::message_box("Dōga Setup", &format!("Could not start:\n{e}"));
            return;
        }
    };
    let dir = default_dir();
    let has_font = |p: &str| std::fs::read_dir(ui.join("fonts")).map(|rd| rd.filter_map(|e| e.ok()).any(|e| e.file_name().to_string_lossy().starts_with(p))).unwrap_or(false);
    for (k, v) in [
        ("config", "no"),
        ("load-scripts", "no"),
        ("osc", "no"),
        ("ytdl", "no"),
        ("load-stats-overlay", "no"),
        ("load-console", "no"),
        ("load-auto-profiles", "no"),
        ("load-select", "no"),
        ("load-positioning", "no"),
        ("load-commands", "no"),
        ("load-context-menu", "no"),
        ("idle", "yes"),
        ("force-window", "yes"),
        ("keep-open", "yes"),
        ("auto-window-resize", "no"),
        ("keepaspect-window", "no"),
        ("title", "Dōga Setup"),
        ("background-color", "#0b0912"),
        ("vo", "gpu-next"),
        ("gpu-api", "d3d11"),
        ("window-dragging", "no"),
        ("cursor-autohide", "no"),
        ("osd-level", "0"),
        ("input-default-bindings", "yes"),
        ("input-builtin-bindings", "no"),
        ("input-vo-keyboard", "yes"),
        ("ao", "null"),
    ] {
        mpv.opt(k, v);
    }
    if cfg!(debug_assertions) {
        mpv.opt("terminal", "yes");
    }
    let k = sys::dpi_scale();
    mpv.opt("geometry", &format!("{}x{}", (880.0 * k).round(), (560.0 * k).round()));
    let ui_font = if has_font("ChakraPetch") { "Chakra Petch" } else { "Segoe UI" };
    let mono_font = if has_font("JetBrainsMono") { "JetBrains Mono" } else { "Consolas" };
    mpv.opt("osd-fonts-dir", &fwd(&ui.join("fonts")));
    mpv.opt("osd-font", ui_font);
    mpv.opt("scripts", &fwd(&ui.join("installer.lua")));
    let existing = dir.join("doga.exe").is_file();
    mpv.opt(
        "script-opts",
        &format!(
            "doga-uidir={},doga-uifont={ui_font},doga-monofont={mono_font},setup-dir={},setup-version={VERSION},setup-existing={},setup-dryrun={}",
            fwd(&ui),
            fwd(&dir),
            if existing { "yes" } else { "no" },
            if dry_run() { "yes" } else { "no" }
        ),
    );
    if let Err(e) = mpv.initialize() {
        win::message_box("Dōga Setup", &format!("Could not start:\n{e}"));
        return;
    }
    let mpv = Arc::new(mpv);
    // hand over: keep the placeholder until the engine's window exists
    let t0 = std::time::Instant::now();
    while mpv.get_prop("window-id").is_none() && t0.elapsed().as_millis() < 1500 {
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    std::thread::sleep(std::time::Duration::from_millis(60));
    drop(splash);
    let mut dev = crate::DevScript::from_env();
    sys::com_init();

    loop {
        let ev = mpv.wait(dev.timeout());
        dev.run(&mpv);
        match ev {
            Ev::Shutdown => break,
            Ev::ClientMessage(args) => match args.first().map(String::as_str) {
                Some("setup-browse") => {
                    let owner: isize = mpv.get_prop("window-id").and_then(|s| s.parse().ok()).unwrap_or(0);
                    if let Some(mut d) = sys::pick_folder(owner, "Choose where to install Dōga") {
                        if !d.ends_with("Doga") {
                            d.push("Doga");
                        }
                        let _ = mpv.command(&["script-message-to", "installer", "setup-dir", &fwd(&d)]);
                    }
                }
                Some("setup-install") if args.len() >= 4 => {
                    let (m, p, t) = (mpv.clone(), pl.clone(), tmp.clone());
                    let dir = PathBuf::from(args[1].replace('/', "\\"));
                    let (desktop, assoc) = (args[2] == "1", args[3] == "1");
                    std::thread::spawn(move || {
                        sys::com_init();
                        let r = install(&m, &p, &t, &dir, desktop, assoc);
                        let (state, msg) = match r {
                            Ok(()) => ("ok", String::new()),
                            Err(e) => ("error", e),
                        };
                        let _ = m.command(&["script-message-to", "installer", "setup-done", state, &msg]);
                    });
                }
                Some("setup-launch") if args.len() >= 2 => {
                    let exe = PathBuf::from(args[1].replace('/', "\\")).join("doga.exe");
                    let _ = std::process::Command::new(exe).spawn();
                    let _ = mpv.command(&["quit"]);
                }
                Some("setup-default-apps") => sys::shell_open("ms-settings:defaultapps"),
                _ => {}
            },
            _ => {}
        }
    }
    drop(mpv);
    sys::unload(&dll);
    for _ in 0..10 {
        if std::fs::remove_dir_all(&tmp).is_ok() || !tmp.exists() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(150));
    }
}

fn unpack(pl: &Payload, to: &Path) -> Result<(), String> {
    for e in &pl.entries {
        let dst = to.join(e.path.replace('/', "\\"));
        if let Some(d) = dst.parent() {
            std::fs::create_dir_all(d).map_err(|x| x.to_string())?;
        }
        let data = pl.read(e).ok_or_else(|| format!("damaged entry {}", e.path))?;
        std::fs::write(&dst, data).map_err(|x| format!("{}: {x}", dst.display()))?;
    }
    Ok(())
}

fn progress(m: &Mpv, frac: f64, label: &str) {
    let _ = m.command(&["script-message-to", "installer", "setup-progress", &format!("{frac:.4}"), label]);
}

fn install(m: &Mpv, pl: &Payload, unpacked: &Path, dir: &Path, desktop: bool, assoc: bool) -> Result<(), String> {
    let dry = dry_run();
    let exe = pl.exe_bytes().ok_or("could not read the installer")?;
    let files: Vec<(String, u64)> = pl.entries.iter().map(|e| (e.path.clone(), e.raw)).collect();
    let total: u64 = exe.len() as u64 + files.iter().map(|f| f.1).sum::<u64>();
    let mut done = 0u64;
    let file_share = 0.9;

    std::fs::create_dir_all(dir).map_err(|e| format!("Could not create {}: {e}", dir.display()))?;
    progress(m, 0.0, "Copying the player");
    let target_exe = dir.join("doga.exe");
    std::fs::write(&target_exe, &exe).map_err(|e| {
        if e.kind() == std::io::ErrorKind::PermissionDenied {
            "Dōga is running. Close it and try again.".to_string()
        } else {
            format!("Could not write doga.exe: {e}")
        }
    })?;
    done += exe.len() as u64;

    for (rel, size) in &files {
        let label = if rel == "libmpv-2.dll" { "Copying the playback engine" } else { "Copying the interface" };
        progress(m, file_share * done as f64 / total as f64, label);
        let src = unpacked.join(rel.replace('/', "\\"));
        let dst = dir.join(rel.replace('/', "\\"));
        if let Some(d) = dst.parent() {
            std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
        }
        copy_with_progress(&src, &dst, |n| progress(m, file_share * (done + n) as f64 / total as f64, label))
            .map_err(|e| format!("Could not copy {rel}: {e}"))?;
        done += size;
    }
    std::fs::write(dir.join(MARKER), VERSION).map_err(|e| e.to_string())?;

    let steps: Vec<&str> = [Some("Adding to the Start menu"), desktop.then_some("Adding a desktop shortcut"), assoc.then_some("Registering video file types"), Some("Registering the uninstaller")]
        .into_iter()
        .flatten()
        .collect();
    for (i, step) in steps.iter().enumerate() {
        progress(m, file_share + (1.0 - file_share) * i as f64 / steps.len() as f64, step);
        if dry {
            continue;
        }
        match *step {
            "Adding to the Start menu" => {
                if let Some(sm) = sys::start_menu_dir() {
                    sys::create_shortcut(&sm.join("Dōga.lnk"), &target_exe, dir, "Plays the file exactly as it was made.");
                }
            }
            "Adding a desktop shortcut" => {
                if let Some(d) = sys::desktop_dir() {
                    sys::create_shortcut(&d.join("Dōga.lnk"), &target_exe, dir, "Plays the file exactly as it was made.");
                }
            }
            "Registering video file types" => register_types(&target_exe),
            _ => register_uninstall(dir, &target_exe, total, desktop),
        }
    }
    progress(m, 1.0, "Done");
    Ok(())
}

fn copy_with_progress(src: &Path, dst: &Path, mut tick: impl FnMut(u64)) -> std::io::Result<()> {
    use std::io::{Read, Write};
    let mut r = std::fs::File::open(src)?;
    let mut w = std::fs::File::create(dst)?;
    let mut buf = vec![0u8; 4 << 20];
    let mut n = 0u64;
    loop {
        let k = r.read(&mut buf)?;
        if k == 0 {
            break;
        }
        w.write_all(&buf[..k])?;
        n += k as u64;
        tick(n);
    }
    Ok(())
}

fn register_types(exe: &Path) {
    let exe_s = exe.to_string_lossy();
    let open = format!("\"{exe_s}\" \"%1\"");
    let icon = format!("\"{exe_s}\",0");
    let cls = format!(r"Software\Classes\{PROGID}");
    sys::reg_str(&cls, "", "Video (Dōga)");
    sys::reg_str(&format!(r"{cls}\DefaultIcon"), "", &icon);
    sys::reg_str(&format!(r"{cls}\shell\open\command"), "", &open);
    let app = r"Software\Classes\Applications\doga.exe";
    sys::reg_str(app, "FriendlyAppName", "Dōga");
    sys::reg_str(&format!(r"{app}\shell\open\command"), "", &open);
    let caps = r"Software\Doga\Capabilities";
    sys::reg_str(caps, "ApplicationName", "Dōga");
    sys::reg_str(caps, "ApplicationDescription", "Plays the file exactly as it was made.");
    for ext in series::VIDEO_EXTS {
        sys::reg_none(&format!(r"Software\Classes\.{ext}\OpenWithProgids"), PROGID);
        sys::reg_str(&format!(r"{app}\SupportedTypes"), &format!(".{ext}"), "");
        sys::reg_str(&format!(r"{caps}\FileAssociations"), &format!(".{ext}"), PROGID);
    }
    sys::reg_str(r"Software\RegisteredApplications", "Dōga", caps);
    sys::assoc_changed();
}

fn register_uninstall(dir: &Path, exe: &Path, bytes: u64, desktop: bool) {
    let exe_s = exe.to_string_lossy();
    sys::reg_str(UNINSTALL_KEY, "DisplayName", "Dōga");
    sys::reg_str(UNINSTALL_KEY, "DisplayVersion", VERSION);
    sys::reg_str(UNINSTALL_KEY, "Publisher", "Dōga");
    sys::reg_str(UNINSTALL_KEY, "DisplayIcon", &format!("\"{exe_s}\",0"));
    sys::reg_str(UNINSTALL_KEY, "InstallLocation", &dir.to_string_lossy());
    sys::reg_str(UNINSTALL_KEY, "UninstallString", &format!("\"{exe_s}\" --uninstall"));
    sys::reg_str(UNINSTALL_KEY, "DesktopShortcut", if desktop { "1" } else { "0" });
    sys::reg_dword(UNINSTALL_KEY, "NoModify", 1);
    sys::reg_dword(UNINSTALL_KEY, "NoRepair", 1);
    sys::reg_dword(UNINSTALL_KEY, "EstimatedSize", (bytes / 1024) as u32);
}

// ------------------------------------------------------------------ uninstaller

/// `doga.exe --uninstall`: relaunch from a temp copy (an exe can't delete itself),
/// confirm, then remove exactly what the installer created.
pub fn run_uninstaller(args: &[String]) {
    let me = std::env::current_exe().unwrap_or_default();
    let dir = match args.iter().position(|a| a == "--dir").and_then(|i| args.get(i + 1)) {
        Some(d) => PathBuf::from(d),
        None => {
            let here = me.parent().map(Path::to_path_buf).unwrap_or_default();
            let tmp = std::env::temp_dir().join(format!("doga-uninstall-{}.exe", std::process::id()));
            if std::fs::copy(&me, &tmp).is_ok() {
                let _ = std::process::Command::new(&tmp).arg("--uninstall").arg("--dir").arg(&here).spawn();
            }
            return;
        }
    };
    // Only ever remove a folder the installer made, and that Windows lists as Dōga's.
    let registered = sys::reg_get_str(UNINSTALL_KEY, "InstallLocation").map(PathBuf::from);
    if !dir.join(MARKER).is_file() || registered.as_deref().is_some_and(|r| r != dir) {
        sys::info("Dōga", &format!("{} doesn't look like a Dōga installation, so nothing was removed.", dir.display()));
        return;
    }
    if !sys::ask("Uninstall Dōga", "Remove Dōga from this PC?\n\nYour settings, recent files and resume positions in %APPDATA%\\Doga are kept.") {
        return;
    }
    std::thread::sleep(std::time::Duration::from_millis(600));
    sys::com_init();
    if let Some(sm) = sys::start_menu_dir() {
        let _ = std::fs::remove_file(sm.join("Dōga.lnk"));
    }
    if let Some(d) = sys::desktop_dir() {
        let _ = std::fs::remove_file(d.join("Dōga.lnk"));
    }
    sys::reg_delete_tree(&format!(r"Software\Classes\{PROGID}"));
    sys::reg_delete_tree(r"Software\Classes\Applications\doga.exe");
    sys::reg_delete_tree(r"Software\Doga");
    for ext in series::VIDEO_EXTS {
        sys::reg_delete_value(&format!(r"Software\Classes\.{ext}\OpenWithProgids"), PROGID);
    }
    sys::reg_delete_value(r"Software\RegisteredApplications", "Dōga");
    sys::reg_delete_tree(UNINSTALL_KEY);
    sys::assoc_changed();

    // Remove only what we installed, then the folder if it's empty.
    let mut ok = true;
    for _ in 0..20 {
        ok = true;
        for f in ["doga.exe", "libmpv-2.dll", MARKER] {
            let p = dir.join(f);
            if p.exists() && std::fs::remove_file(&p).is_err() {
                ok = false;
            }
        }
        let ui = dir.join("ui");
        if ui.exists() && std::fs::remove_dir_all(&ui).is_err() {
            ok = false;
        }
        if ok {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    let _ = std::fs::remove_dir(&dir);
    if ok {
        sys::info("Dōga", "Dōga was removed.");
    } else {
        sys::info("Dōga", &format!("Dōga was unregistered, but some files in {} are in use. Close Dōga and delete the folder.", dir.display()));
    }
}
