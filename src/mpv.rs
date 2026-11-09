//! Minimal libmpv binding, loaded at runtime from libmpv-2.dll.
//! Only the handful of client API calls the host needs.

use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::path::Path;

use crate::win;

pub const EVENT_SHUTDOWN: c_int = 1;
pub const EVENT_END_FILE: c_int = 7;
pub const EVENT_FILE_LOADED: c_int = 8;
pub const EVENT_CLIENT_MESSAGE: c_int = 16;
pub const EVENT_PLAYBACK_RESTART: c_int = 21;

const FMT_STRING: c_int = 1;
const FMT_INT64: c_int = 4;
const FMT_NODE_MAP: c_int = 8;
const FMT_BYTE_ARRAY: c_int = 9;

#[repr(C)]
#[derive(Clone, Copy)]
union NodeU {
    s: *mut c_char,
    flag: c_int,
    i: i64,
    d: f64,
    list: *mut NodeList,
    ba: *mut ByteArray,
}

#[repr(C)]
struct Node {
    u: NodeU,
    format: c_int,
}

#[repr(C)]
struct NodeList {
    num: c_int,
    values: *mut Node,
    keys: *mut *mut c_char,
}

#[repr(C)]
struct ByteArray {
    data: *mut c_void,
    size: usize,
}

/// A decoded frame as tightly packed BGRA rows.
pub struct Frame {
    pub w: u32,
    pub h: u32,
    pub data: Vec<u8>,
}

#[repr(C)]
pub struct Event {
    pub event_id: c_int,
    pub error: c_int,
    pub reply_userdata: u64,
    pub data: *mut c_void,
}

#[repr(C)]
struct ClientMessage {
    num_args: c_int,
    args: *const *const c_char,
}

type Handle = *mut c_void;

struct Api {
    create: unsafe extern "C" fn() -> Handle,
    initialize: unsafe extern "C" fn(Handle) -> c_int,
    set_option_string: unsafe extern "C" fn(Handle, *const c_char, *const c_char) -> c_int,
    set_property_string: unsafe extern "C" fn(Handle, *const c_char, *const c_char) -> c_int,
    get_property_string: unsafe extern "C" fn(Handle, *const c_char) -> *mut c_char,
    command: unsafe extern "C" fn(Handle, *mut *const c_char) -> c_int,
    command_string: unsafe extern "C" fn(Handle, *const c_char) -> c_int,
    command_ret: unsafe extern "C" fn(Handle, *mut *const c_char, *mut Node) -> c_int,
    free_node_contents: unsafe extern "C" fn(*mut Node),
    wait_event: unsafe extern "C" fn(Handle, f64) -> *mut Event,
    terminate_destroy: unsafe extern "C" fn(Handle),
    free: unsafe extern "C" fn(*mut c_void),
    error_string: unsafe extern "C" fn(c_int) -> *const c_char,
}

pub struct Mpv {
    api: Api,
    h: Handle,
}

// The libmpv client API is thread-safe; only wait_event must stay on one thread per handle.
unsafe impl Send for Mpv {}
unsafe impl Sync for Mpv {}

pub enum Ev {
    Shutdown,
    FileLoaded,
    EndFile,
    PlaybackRestart,
    ClientMessage(Vec<String>),
    Other,
}

impl Mpv {
    /// Load libmpv-2.dll from `dll` and create (but not yet initialize) a player.
    pub fn load(dll: &Path) -> Result<Mpv, String> {
        let lib = win::load_library(dll).ok_or_else(|| format!("could not load {}", dll.display()))?;
        macro_rules! sym {
            ($name:literal) => {{
                let p = win::get_proc(lib, $name).ok_or_else(|| format!("libmpv is missing {}", $name))?;
                unsafe { std::mem::transmute(p) }
            }};
        }
        let api = Api {
            create: sym!("mpv_create"),
            initialize: sym!("mpv_initialize"),
            set_option_string: sym!("mpv_set_option_string"),
            set_property_string: sym!("mpv_set_property_string"),
            get_property_string: sym!("mpv_get_property_string"),
            command: sym!("mpv_command"),
            command_string: sym!("mpv_command_string"),
            command_ret: sym!("mpv_command_ret"),
            free_node_contents: sym!("mpv_free_node_contents"),
            wait_event: sym!("mpv_wait_event"),
            terminate_destroy: sym!("mpv_terminate_destroy"),
            free: sym!("mpv_free"),
            error_string: sym!("mpv_error_string"),
        };
        let h = unsafe { (api.create)() };
        if h.is_null() {
            return Err("mpv_create failed".into());
        }
        Ok(Mpv { api, h })
    }

    fn err(&self, code: c_int) -> String {
        unsafe { CStr::from_ptr((self.api.error_string)(code)) }.to_string_lossy().into_owned()
    }

    /// Set an option before initialize. Unknown options are logged, not fatal,
    /// so a newer/older libmpv never stops the player from starting.
    pub fn opt(&self, name: &str, value: &str) {
        let (n, v) = (cstr(name), cstr(value));
        let rc = unsafe { (self.api.set_option_string)(self.h, n.as_ptr(), v.as_ptr()) };
        if rc < 0 {
            eprintln!("[doga] option {name}={value}: {}", self.err(rc));
        }
    }

    pub fn initialize(&self) -> Result<(), String> {
        let rc = unsafe { (self.api.initialize)(self.h) };
        if rc < 0 { Err(self.err(rc)) } else { Ok(()) }
    }

    pub fn set_prop(&self, name: &str, value: &str) {
        let (n, v) = (cstr(name), cstr(value));
        let rc = unsafe { (self.api.set_property_string)(self.h, n.as_ptr(), v.as_ptr()) };
        if rc < 0 {
            eprintln!("[doga] set {name}: {}", self.err(rc));
        }
    }

    pub fn get_prop(&self, name: &str) -> Option<String> {
        let n = cstr(name);
        let p = unsafe { (self.api.get_property_string)(self.h, n.as_ptr()) };
        if p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { (self.api.free)(p as *mut c_void) };
        Some(s)
    }

    pub fn command(&self, args: &[&str]) -> Result<(), String> {
        let owned: Vec<CString> = args.iter().map(|a| cstr(a)).collect();
        let mut ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        let rc = unsafe { (self.api.command)(self.h, ptrs.as_mut_ptr()) };
        if rc < 0 { Err(self.err(rc)) } else { Ok(()) }
    }

    /// Run a command written like an input.conf line.
    #[allow(dead_code)]
    pub fn command_str(&self, line: &str) -> Result<(), String> {
        let c = cstr(line);
        let rc = unsafe { (self.api.command_string)(self.h, c.as_ptr()) };
        if rc < 0 { Err(self.err(rc)) } else { Ok(()) }
    }

    /// `screenshot-raw video bgra`: the current (filtered) video frame, no subtitles or OSD.
    pub fn screenshot_bgra(&self) -> Option<Frame> {
        let owned: Vec<CString> = ["screenshot-raw", "video", "bgra"].iter().map(|a| cstr(a)).collect();
        let mut ptrs: Vec<*const c_char> = owned.iter().map(|c| c.as_ptr()).collect();
        ptrs.push(std::ptr::null());
        let mut node = Node { u: NodeU { i: 0 }, format: 0 };
        if unsafe { (self.api.command_ret)(self.h, ptrs.as_mut_ptr(), &mut node) } < 0 {
            return None;
        }
        let frame = unsafe { read_frame(&node) };
        unsafe { (self.api.free_node_contents)(&mut node) };
        frame
    }

    pub fn wait(&self, timeout: f64) -> Ev {
        let e = unsafe { &*(self.api.wait_event)(self.h, timeout) };
        match e.event_id {
            EVENT_SHUTDOWN => Ev::Shutdown,
            EVENT_FILE_LOADED => Ev::FileLoaded,
            EVENT_END_FILE => Ev::EndFile,
            EVENT_PLAYBACK_RESTART => Ev::PlaybackRestart,
            EVENT_CLIENT_MESSAGE if !e.data.is_null() => {
                let m = unsafe { &*(e.data as *const ClientMessage) };
                let args = (0..m.num_args as usize)
                    .map(|i| unsafe { CStr::from_ptr(*m.args.add(i)) }.to_string_lossy().into_owned())
                    .collect();
                Ev::ClientMessage(args)
            }
            _ => Ev::Other,
        }
    }
}

impl Drop for Mpv {
    fn drop(&mut self) {
        unsafe { (self.api.terminate_destroy)(self.h) };
    }
}

/// Pull w/h/stride/format/data out of a screenshot-raw result map.
unsafe fn read_frame(node: &Node) -> Option<Frame> {
    if node.format != FMT_NODE_MAP || node.u.list.is_null() {
        return None;
    }
    let list = &*node.u.list;
    let (mut w, mut h, mut stride, mut data, mut fmt_ok) = (0i64, 0i64, 0i64, None, true);
    for i in 0..list.num as usize {
        let key = CStr::from_ptr(*list.keys.add(i)).to_bytes();
        let v = &*list.values.add(i);
        match (key, v.format) {
            (b"w", FMT_INT64) => w = v.u.i,
            (b"h", FMT_INT64) => h = v.u.i,
            (b"stride", FMT_INT64) => stride = v.u.i,
            (b"format", FMT_STRING) => fmt_ok = CStr::from_ptr(v.u.s).to_bytes() == b"bgra",
            (b"data", FMT_BYTE_ARRAY) if !v.u.ba.is_null() => {
                let ba = &*v.u.ba;
                data = Some(std::slice::from_raw_parts(ba.data as *const u8, ba.size));
            }
            _ => {}
        }
    }
    let data = data?;
    if !fmt_ok || w <= 0 || h <= 0 || stride < w * 4 || (data.len() as i64) < stride * (h - 1) + w * 4 {
        return None;
    }
    let (w, h, stride) = (w as usize, h as usize, stride as usize);
    let mut out = Vec::with_capacity(w * h * 4);
    for row in 0..h {
        out.extend_from_slice(&data[row * stride..row * stride + w * 4]);
    }
    Some(Frame { w: w as u32, h: h as u32, data: out })
}

fn cstr(s: &str) -> CString {
    CString::new(s.replace('\0', "")).unwrap()
}
