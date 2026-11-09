//! A native placeholder window shown the instant the installer starts, while it unpacks the
//! engine (≈1 s). Same size, title and dark frame as the real installer window, with a thin
//! violet loading line, so the hand-over to the engine-drawn UI is seamless.

use std::ffi::{c_void, OsStr};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use crate::win::wide;

type Hwnd = *mut c_void;

#[repr(C)]
struct WndClassExW {
    size: u32,
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
    icon_sm: *mut c_void,
}

#[repr(C)]
#[derive(Default)]
struct Rect {
    l: i32,
    t: i32,
    r: i32,
    b: i32,
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

#[repr(C)]
struct PaintStruct {
    hdc: *mut c_void,
    erase: i32,
    rc: Rect,
    restore: i32,
    inc_update: i32,
    reserved: [u8; 32],
}

#[link(name = "user32")]
extern "system" {
    fn RegisterClassExW(c: *const WndClassExW) -> u16;
    fn CreateWindowExW(ex: u32, cls: *const u16, title: *const u16, style: u32, x: i32, y: i32, w: i32, h: i32, parent: Hwnd, menu: *mut c_void, inst: *mut c_void, param: *mut c_void) -> Hwnd;
    fn DefWindowProcW(h: Hwnd, m: u32, w: usize, l: isize) -> isize;
    fn ShowWindow(h: Hwnd, cmd: i32) -> i32;
    fn UpdateWindow(h: Hwnd) -> i32;
    fn DestroyWindow(h: Hwnd) -> i32;
    fn PeekMessageW(m: *mut Msg, h: Hwnd, a: u32, b: u32, remove: u32) -> i32;
    fn TranslateMessage(m: *const Msg) -> i32;
    fn DispatchMessageW(m: *const Msg) -> isize;
    fn GetSystemMetrics(i: i32) -> i32;
    fn AdjustWindowRectEx(r: *mut Rect, style: u32, menu: i32, ex: u32) -> i32;
    fn BeginPaint(h: Hwnd, ps: *mut PaintStruct) -> *mut c_void;
    fn EndPaint(h: Hwnd, ps: *const PaintStruct) -> i32;
    fn FillRect(dc: *mut c_void, r: *const Rect, brush: *mut c_void) -> i32;
    fn GetClientRect(h: Hwnd, r: *mut Rect) -> i32;
    fn InvalidateRect(h: Hwnd, r: *const Rect, erase: i32) -> i32;
    fn LoadIconW(inst: *mut c_void, name: *const u16) -> *mut c_void;
    fn LoadCursorW(inst: *mut c_void, name: *const u16) -> *mut c_void;
}

#[link(name = "gdi32")]
extern "system" {
    fn CreateSolidBrush(c: u32) -> *mut c_void;
    fn DeleteObject(o: *mut c_void) -> i32;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleHandleW(n: *const u16) -> *mut c_void;
}

#[link(name = "dwmapi")]
extern "system" {
    fn DwmSetWindowAttribute(h: Hwnd, attr: u32, v: *const c_void, n: u32) -> i32;
}

const WS_OVERLAPPEDWINDOW: u32 = 0x00CF_0000;
const WM_PAINT: u32 = 0x000F;
const WM_ERASEBKGND: u32 = 0x0014;
const BG: u32 = 0x0012_090b; // #0b0912 as COLORREF (0x00BBGGRR)
const ACCENT: u32 = 0x00ff_7bb5; // #b57bff
const TRACK: u32 = 0x0042_262e; // #2e2642

static PHASE: AtomicU32 = AtomicU32::new(0);

unsafe extern "system" fn proc_(h: Hwnd, m: u32, w: usize, l: isize) -> isize {
    match m {
        WM_ERASEBKGND => 1,
        WM_PAINT => {
            let mut ps: PaintStruct = std::mem::zeroed();
            let dc = BeginPaint(h, &mut ps);
            let mut rc = Rect::default();
            GetClientRect(h, &mut rc);
            let bg = CreateSolidBrush(BG);
            FillRect(dc, &rc, bg);
            DeleteObject(bg);
            // a short violet segment sweeping along a faint track, near the bottom
            let pad = (rc.r / 18).max(24);
            let y = rc.b - pad;
            let track = Rect { l: pad, t: y, r: rc.r - pad, b: y + 3 };
            let tb = CreateSolidBrush(TRACK);
            FillRect(dc, &track, tb);
            DeleteObject(tb);
            let span = track.r - track.l;
            let p = (PHASE.load(Ordering::Relaxed) % 100) as i32;
            let seg = span / 4;
            let x = track.l + (span + seg) * p / 100 - seg;
            let s = Rect { l: x.max(track.l), t: y, r: (x + seg).min(track.r), b: y + 3 };
            if s.r > s.l {
                let ab = CreateSolidBrush(ACCENT);
                FillRect(dc, &s, ab);
                DeleteObject(ab);
            }
            EndPaint(h, &ps);
            0
        }
        _ => DefWindowProcW(h, m, w, l),
    }
}

pub struct Splash(Hwnd);

impl Splash {
    /// Client size in physical pixels, centred on the primary screen.
    pub fn show(title: &str, w: i32, h: i32) -> Option<Splash> {
        unsafe {
            let inst = GetModuleHandleW(std::ptr::null());
            let cls = wide(OsStr::new("DogaSplash"));
            let wc = WndClassExW {
                size: std::mem::size_of::<WndClassExW>() as u32,
                style: 0,
                proc_,
                cls_extra: 0,
                wnd_extra: 0,
                instance: inst,
                icon: LoadIconW(inst, 1 as *const u16),
                cursor: LoadCursorW(std::ptr::null_mut(), 32514 as *const u16), // IDC_APPSTARTING
                background: std::ptr::null_mut(),
                menu: std::ptr::null(),
                class_name: cls.as_ptr(),
                icon_sm: std::ptr::null_mut(),
            };
            RegisterClassExW(&wc);
            let mut r = Rect { l: 0, t: 0, r: w, b: h };
            AdjustWindowRectEx(&mut r, WS_OVERLAPPEDWINDOW, 0, 0);
            let (ww, wh) = (r.r - r.l, r.b - r.t);
            let x = (GetSystemMetrics(0) - ww) / 2;
            let y = (GetSystemMetrics(1) - wh) / 2;
            let t = wide(OsStr::new(title));
            let hwnd = CreateWindowExW(0, cls.as_ptr(), t.as_ptr(), WS_OVERLAPPEDWINDOW, x, y, ww, wh, std::ptr::null_mut(), std::ptr::null_mut(), inst, std::ptr::null_mut());
            if hwnd.is_null() {
                return None;
            }
            let dark: i32 = 1;
            DwmSetWindowAttribute(hwnd, 20, &dark as *const i32 as *const c_void, 4); // immersive dark mode
            ShowWindow(hwnd, 5);
            UpdateWindow(hwnd);
            Some(Splash(hwnd))
        }
    }

    /// Keep the window alive and animating until `done` is set.
    pub fn pump_until(&self, done: &AtomicBool) {
        let mut last = std::time::Instant::now();
        while !done.load(Ordering::Acquire) {
            unsafe {
                let mut m: Msg = std::mem::zeroed();
                while PeekMessageW(&mut m, std::ptr::null_mut(), 0, 0, 1) != 0 {
                    TranslateMessage(&m);
                    DispatchMessageW(&m);
                }
                if last.elapsed().as_millis() >= 16 {
                    last = std::time::Instant::now();
                    PHASE.fetch_add(2, Ordering::Relaxed);
                    InvalidateRect(self.0, std::ptr::null(), 0);
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(4));
        }
    }
}

impl Drop for Splash {
    fn drop(&mut self) {
        unsafe { DestroyWindow(self.0) };
    }
}
