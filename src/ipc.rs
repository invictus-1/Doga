//! One Dōga window, and drops that know where they landed.
//!
//! Single instance: the first Dōga owns a named mutex and an invisible message-only window
//! ("DogaIPC"). A second launch finds it, hands over its files with WM_COPYDATA (or just asks
//! it to come forward), and exits. Several files opened at once from Explorer arrive within a
//! moment of each other and are queued as one playlist instead of replacing each other.
//!
//! Drops: mpv's own drag-and-drop is off; the player window is subclassed to accept
//! WM_DROPFILES, so the UI gets the drop point and can insert into the playlist where the
//! files were released.

use std::ffi::{c_void, OsStr, OsString};
use std::os::windows::ffi::OsStringExt;
use std::sync::mpsc::Sender;
use std::sync::{Mutex, OnceLock};

use crate::win::wide;

type Hwnd = *mut c_void;

#[repr(C)]
struct CopyData {
    tag: usize,
    size: u32,
    data: *const c_void,
}

#[repr(C)]
struct WndClassW {
    style: u32,
    proc_: unsafe extern "system" fn(Hwnd, u32, usize, isize) -> isize,
    cls_extra: i32,
    wnd_extra: i32,
    instance: *mut c_void,
    icon: *mut c_void,
    cursor: *mut c_void,
    background: *mut c_void,
    menu: *const u16,
    class_name: *const u16,
}

#[repr(C)]
struct Msg {
    hwnd: Hwnd,
    msg: u32,
    w: usize,
    l: isize,
    time: u32,
    pt: [i32; 2],
    private: u32,
}

#[link(name = "user32")]
extern "system" {
    fn RegisterClassW(c: *const WndClassW) -> u16;
    fn CreateWindowExW(ex: u32, cls: *const u16, title: *const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: Hwnd, menu: *mut c_void, inst: *mut c_void, param: *mut c_void) -> Hwnd;
    fn DefWindowProcW(h: Hwnd, m: u32, w: usize, l: isize) -> isize;
    fn GetMessageW(m: *mut Msg, h: Hwnd, a: u32, b: u32) -> i32;
    fn DispatchMessageW(m: *const Msg) -> isize;
    fn FindWindowExW(parent: Hwnd, after: Hwnd, cls: *const u16, title: *const u16) -> Hwnd;
    fn SendMessageTimeoutW(h: Hwnd, m: u32, w: usize, l: isize, flags: u32, timeout: u32, result: *mut usize) -> isize;
    fn GetWindowThreadProcessId(h: Hwnd, pid: *mut u32) -> u32;
    fn AllowSetForegroundWindow(pid: u32) -> i32;
    fn SetForegroundWindow(h: Hwnd) -> i32;
    fn ShowWindow(h: Hwnd, cmd: i32) -> i32;
    fn IsIconic(h: Hwnd) -> i32;
    fn SetWindowLongPtrW(h: Hwnd, idx: i32, v: isize) -> isize;
    fn GetWindowLongPtrW(h: Hwnd, idx: i32) -> isize;
    fn CallWindowProcW(prev: isize, h: Hwnd, m: u32, w: usize, l: isize) -> isize;
    fn PostMessageW(h: Hwnd, m: u32, w: usize, l: isize) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn CreateMutexW(sa: *const c_void, owner: i32, name: *const u16) -> *mut c_void;
    fn GetLastError() -> u32;
    fn GetModuleHandleW(n: *const u16) -> *mut c_void;
}

#[link(name = "shell32")]
extern "system" {
    fn DragAcceptFiles(h: Hwnd, accept: i32);
    fn DragQueryFileW(drop: *mut c_void, i: u32, buf: *mut u16, n: u32) -> u32;
    fn DragQueryPoint(drop: *mut c_void, pt: *mut [i32; 2]) -> i32;
    fn DragFinish(drop: *mut c_void);
}

#[link(name = "ole32")]
extern "system" {
    fn RevokeDragDrop(h: Hwnd) -> i32;
}

const HWND_MESSAGE: isize = -3;
const WM_COPYDATA: u32 = 0x004A;
const WM_DROPFILES: u32 = 0x0233;
const WM_TAKE_DROPS: u32 = 0x8000 + 0x44; // WM_APP + 'D'
const TAG: usize = 0x444F_4741; // "DOGA"

pub enum Event {
    /// Files from another launch (empty: just come to the front).
    Open(Vec<String>),
    /// Files dropped on the player window at client (x, y).
    Drop(i32, i32, Vec<String>),
}

static TX: OnceLock<Mutex<Sender<Event>>> = OnceLock::new();
static PREV_PROC: OnceLock<isize> = OnceLock::new();

fn send(e: Event) {
    if let Some(tx) = TX.get() {
        let _ = tx.lock().map(|t| t.send(e));
    }
}

/// True when another Dōga is already running.
pub fn another_instance() -> bool {
    let name = wide(OsStr::new(r"Local\DogaPlayerSingleInstance"));
    let h = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
    // the handle is kept open for the life of the process on purpose
    !h.is_null() && unsafe { GetLastError() } == 183 // ERROR_ALREADY_EXISTS
}

/// Hand files to the running instance. Waits briefly for it to finish starting up.
pub fn forward(files: &[String]) -> bool {
    let cls = wide(OsStr::new("DogaIPC"));
    let t0 = std::time::Instant::now();
    let target = loop {
        let h = unsafe { FindWindowExW(HWND_MESSAGE as Hwnd, std::ptr::null_mut(), cls.as_ptr(), std::ptr::null()) };
        if !h.is_null() {
            break h;
        }
        if t0.elapsed().as_secs_f32() > 4.0 {
            return false;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    };
    let mut pid = 0u32;
    unsafe {
        GetWindowThreadProcessId(target, &mut pid);
        AllowSetForegroundWindow(pid);
    }
    let payload: Vec<u16> = files.join("\0").encode_utf16().chain(std::iter::once(0)).collect();
    let cds = CopyData { tag: TAG, size: (payload.len() * 2) as u32, data: payload.as_ptr() as *const c_void };
    let mut res = 0usize;
    unsafe { SendMessageTimeoutW(target, WM_COPYDATA, 0, &cds as *const CopyData as isize, 0x2, 4000, &mut res) != 0 }
}

unsafe extern "system" fn ipc_proc(h: Hwnd, m: u32, w: usize, l: isize) -> isize {
    if m == WM_COPYDATA && l != 0 {
        let cds = &*(l as *const CopyData);
        if cds.tag == TAG && !cds.data.is_null() {
            let n = cds.size as usize / 2;
            let s = std::slice::from_raw_parts(cds.data as *const u16, n);
            let files: Vec<String> = s
                .split(|&c| c == 0)
                .filter(|p| !p.is_empty())
                .map(|p| OsString::from_wide(p).to_string_lossy().into_owned())
                .collect();
            send(Event::Open(files));
            return 1;
        }
    }
    DefWindowProcW(h, m, w, l)
}

/// Start listening for other launches. Events arrive on `tx`.
pub fn serve(tx: Sender<Event>) {
    let _ = TX.set(Mutex::new(tx));
    std::thread::spawn(|| unsafe {
        let inst = GetModuleHandleW(std::ptr::null());
        let cls = wide(OsStr::new("DogaIPC"));
        let wc = WndClassW {
            style: 0,
            proc_: ipc_proc,
            cls_extra: 0,
            wnd_extra: 0,
            instance: inst,
            icon: std::ptr::null_mut(),
            cursor: std::ptr::null_mut(),
            background: std::ptr::null_mut(),
            menu: std::ptr::null(),
            class_name: cls.as_ptr(),
        };
        RegisterClassW(&wc);
        let h = CreateWindowExW(0, cls.as_ptr(), cls.as_ptr(), 0, 0, 0, 0, 0, HWND_MESSAGE as Hwnd, std::ptr::null_mut(), inst, std::ptr::null_mut());
        if h.is_null() {
            return;
        }
        let mut m: Msg = std::mem::zeroed();
        while GetMessageW(&mut m, std::ptr::null_mut(), 0, 0) > 0 {
            DispatchMessageW(&m);
        }
    });
}

/// Drop events only, without claiming the single-instance window (debug test runs).
pub fn serve_drops_only(tx: Sender<Event>) -> bool {
    TX.set(Mutex::new(tx)).is_ok()
}

/// Bring the player window forward (restoring it if minimized).
pub fn raise(hwnd: isize) {
    let h = hwnd as Hwnd;
    unsafe {
        if IsIconic(h) != 0 {
            ShowWindow(h, 9); // SW_RESTORE
        }
        SetForegroundWindow(h);
    }
}

unsafe extern "system" fn player_proc(h: Hwnd, m: u32, w: usize, l: isize) -> isize {
    let prev = *PREV_PROC.get().unwrap_or(&0);
    match m {
        // runs on the window's own thread, which OLE requires
        WM_TAKE_DROPS => {
            RevokeDragDrop(h);
            DragAcceptFiles(h, 1);
            0
        }
        WM_DROPFILES => {
            let drop = w as *mut c_void;
            let mut pt = [0i32; 2];
            DragQueryPoint(drop, &mut pt);
            let n = DragQueryFileW(drop, 0xFFFF_FFFF, std::ptr::null_mut(), 0);
            let mut files = Vec::new();
            for i in 0..n {
                let len = DragQueryFileW(drop, i, std::ptr::null_mut(), 0) as usize;
                let mut buf = vec![0u16; len + 1];
                DragQueryFileW(drop, i, buf.as_mut_ptr(), buf.len() as u32);
                files.push(OsString::from_wide(&buf[..len]).to_string_lossy().into_owned());
            }
            DragFinish(drop);
            send(Event::Drop(pt[0], pt[1], files));
            0
        }
        _ => CallWindowProcW(prev, h, m, w, l),
    }
}

/// Route file drops on the player window to us (call once its window exists).
pub fn take_drops(hwnd: isize) {
    if PREV_PROC.get().is_some() || hwnd == 0 {
        return;
    }
    let h = hwnd as Hwnd;
    unsafe {
        // record the original procedure before ours can receive anything
        let prev = GetWindowLongPtrW(h, -4); // GWLP_WNDPROC
        if prev == 0 || PREV_PROC.set(prev).is_err() {
            return;
        }
        SetWindowLongPtrW(h, -4, player_proc as *const () as isize);
        PostMessageW(h, WM_TAKE_DROPS, 0, 0);
    }
}
