//! The few Win32 calls the host needs, declared by hand so the project has no dependencies.

use std::ffi::{c_void, OsStr, OsString};
use std::os::windows::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};

type Hmodule = *mut c_void;
type Hwnd = *mut c_void;

#[link(name = "kernel32")]
extern "system" {
    fn LoadLibraryExW(name: *const u16, file: *mut c_void, flags: u32) -> Hmodule;
    fn GetProcAddress(m: Hmodule, name: *const u8) -> *mut c_void;
}

#[link(name = "user32")]
extern "system" {
    fn MessageBoxW(hwnd: Hwnd, text: *const u16, caption: *const u16, kind: u32) -> i32;
    fn SetProcessDpiAwarenessContext(ctx: isize) -> i32;
}

/// Per-monitor DPI awareness (v2). Without it Windows renders the window at 96 DPI and
/// bitmap-stretches it, which would soften every video pixel on a scaled display.
pub fn dpi_aware() {
    const PER_MONITOR_AWARE_V2: isize = -4;
    unsafe { SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2) };
}

#[repr(C)]
struct OpenFileNameW {
    struct_size: u32,
    owner: Hwnd,
    instance: *mut c_void,
    filter: *const u16,
    custom_filter: *mut u16,
    max_cust_filter: u32,
    filter_index: u32,
    file: *mut u16,
    max_file: u32,
    file_title: *mut u16,
    max_file_title: u32,
    initial_dir: *const u16,
    title: *const u16,
    flags: u32,
    file_offset: u16,
    file_extension: u16,
    def_ext: *const u16,
    cust_data: isize,
    hook: *const c_void,
    template_name: *const u16,
    reserved_ptr: *mut c_void,
    reserved: u32,
    flags_ex: u32,
}

#[link(name = "comdlg32")]
extern "system" {
    fn GetOpenFileNameW(ofn: *mut OpenFileNameW) -> i32;
}

const LOAD_WITH_ALTERED_SEARCH_PATH: u32 = 0x8;

pub fn wide(s: &OsStr) -> Vec<u16> {
    s.encode_wide().chain(std::iter::once(0)).collect()
}

pub fn load_library(path: &Path) -> Option<Hmodule> {
    let w = wide(path.as_os_str());
    let h = unsafe { LoadLibraryExW(w.as_ptr(), std::ptr::null_mut(), LOAD_WITH_ALTERED_SEARCH_PATH) };
    (!h.is_null()).then_some(h)
}

pub fn get_proc(m: Hmodule, name: &str) -> Option<*mut c_void> {
    let mut n = name.as_bytes().to_vec();
    n.push(0);
    let p = unsafe { GetProcAddress(m, n.as_ptr()) };
    (!p.is_null()).then_some(p)
}

pub fn message_box(title: &str, text: &str) {
    let (t, c) = (wide(OsStr::new(text)), wide(OsStr::new(title)));
    unsafe { MessageBoxW(std::ptr::null_mut(), t.as_ptr(), c.as_ptr(), 0x10) };
}

/// Native "Open" dialog. Returns the chosen files (several when multi-selected).
pub fn open_files(owner: isize, initial_dir: Option<&Path>) -> Vec<PathBuf> {
    const OFN_ALLOWMULTISELECT: u32 = 0x200;
    const OFN_EXPLORER: u32 = 0x80000;
    const OFN_FILEMUSTEXIST: u32 = 0x1000;
    const OFN_NOCHANGEDIR: u32 = 0x8;
    let exts = crate::series::VIDEO_EXTS.iter().map(|e| format!("*.{e}")).collect::<Vec<_>>().join(";");
    let filter_s = format!("Video files\0{exts}\0All files\0*.*\0\0");
    let filter: Vec<u16> = filter_s.encode_utf16().collect();
    let mut buf = vec![0u16; 64 * 1024];
    let dir = initial_dir.map(|d| wide(d.as_os_str()));
    let title = wide(OsStr::new("Open video"));
    let mut ofn = OpenFileNameW {
        struct_size: std::mem::size_of::<OpenFileNameW>() as u32,
        owner: owner as Hwnd,
        instance: std::ptr::null_mut(),
        filter: filter.as_ptr(),
        custom_filter: std::ptr::null_mut(),
        max_cust_filter: 0,
        filter_index: 1,
        file: buf.as_mut_ptr(),
        max_file: buf.len() as u32,
        file_title: std::ptr::null_mut(),
        max_file_title: 0,
        initial_dir: dir.as_ref().map_or(std::ptr::null(), |d| d.as_ptr()),
        title: title.as_ptr(),
        flags: OFN_ALLOWMULTISELECT | OFN_EXPLORER | OFN_FILEMUSTEXIST | OFN_NOCHANGEDIR,
        file_offset: 0,
        file_extension: 0,
        def_ext: std::ptr::null(),
        cust_data: 0,
        hook: std::ptr::null(),
        template_name: std::ptr::null(),
        reserved_ptr: std::ptr::null_mut(),
        reserved: 0,
        flags_ex: 0,
    };
    if unsafe { GetOpenFileNameW(&mut ofn) } == 0 {
        return Vec::new();
    }
    // Explorer-style result: "dir\0file1\0file2\0\0", or "fullpath\0\0" for one file.
    let parts: Vec<OsString> = buf
        .split(|&c| c == 0)
        .take_while(|p| !p.is_empty())
        .map(OsString::from_wide)
        .collect();
    match parts.len() {
        0 => Vec::new(),
        1 => vec![PathBuf::from(&parts[0])],
        _ => parts[1..].iter().map(|f| Path::new(&parts[0]).join(f)).collect(),
    }
}
