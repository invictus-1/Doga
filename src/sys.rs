//! Win32 pieces for the installer: compression, registry, shortcuts, known folders,
//! folder picker, shell notifications. Declared by hand (no dependencies).

use std::ffi::{c_void, OsStr, OsString};
use std::os::windows::ffi::OsStringExt;
use std::path::{Path, PathBuf};

use crate::win::wide;

type Handle = *mut c_void;
type Hkey = isize;
const HKCU: Hkey = 0x8000_0001u32 as i32 as isize;

#[repr(C)]
struct Guid(u32, u16, u16, [u8; 8]);

#[link(name = "cabinet")]
extern "system" {
    fn CreateCompressor(algo: u32, alloc: *const c_void, h: *mut Handle) -> i32;
    fn Compress(h: Handle, src: *const u8, n: usize, dst: *mut u8, cap: usize, out: *mut usize) -> i32;
    fn CloseCompressor(h: Handle) -> i32;
    fn CreateDecompressor(algo: u32, alloc: *const c_void, h: *mut Handle) -> i32;
    fn Decompress(h: Handle, src: *const u8, n: usize, dst: *mut u8, cap: usize, out: *mut usize) -> i32;
    fn CloseDecompressor(h: Handle) -> i32;
}

#[link(name = "advapi32")]
extern "system" {
    fn RegCreateKeyExW(k: Hkey, sub: *const u16, r: u32, class: *const u16, opts: u32, sam: u32, sa: *const c_void, out: *mut Hkey, disp: *mut u32) -> i32;
    fn RegSetValueExW(k: Hkey, name: *const u16, r: u32, ty: u32, data: *const u8, n: u32) -> i32;
    fn RegCloseKey(k: Hkey) -> i32;
    fn RegDeleteTreeW(k: Hkey, sub: *const u16) -> i32;
    fn RegDeleteKeyValueW(k: Hkey, sub: *const u16, name: *const u16) -> i32;
    fn RegGetValueW(k: Hkey, sub: *const u16, name: *const u16, flags: u32, ty: *mut u32, data: *mut c_void, n: *mut u32) -> i32;
}

#[link(name = "ole32")]
extern "system" {
    fn CoInitializeEx(r: *const c_void, flags: u32) -> i32;
    fn CoCreateInstance(clsid: *const Guid, outer: *const c_void, ctx: u32, iid: *const Guid, out: *mut *mut c_void) -> i32;
    fn CoTaskMemFree(p: *mut c_void);
}

#[repr(C)]
struct BrowseInfoW {
    owner: *mut c_void,
    root: *const c_void,
    display: *mut u16,
    title: *const u16,
    flags: u32,
    callback: *const c_void,
    lparam: isize,
    image: i32,
}

#[link(name = "shell32")]
extern "system" {
    fn SHChangeNotify(event: i32, flags: u32, a: *const c_void, b: *const c_void);
    fn SHGetKnownFolderPath(id: *const Guid, flags: u32, token: Handle, out: *mut *mut u16) -> i32;
    fn SHBrowseForFolderW(bi: *const BrowseInfoW) -> *mut c_void;
    fn SHGetPathFromIDListW(pidl: *const c_void, out: *mut u16) -> i32;
    fn ShellExecuteW(hwnd: *mut c_void, op: *const u16, file: *const u16, params: *const u16, dir: *const u16, show: i32) -> isize;
}

#[link(name = "kernel32")]
extern "system" {
    fn GetModuleHandleW(name: *const u16) -> *mut c_void;
    fn FreeLibrary(m: *mut c_void) -> i32;
}

#[link(name = "user32")]
extern "system" {
    fn MessageBoxW(hwnd: *mut c_void, text: *const u16, caption: *const u16, kind: u32) -> i32;
    fn GetDpiForSystem() -> u32;
}

/// Display scale (1.0 at 96 DPI, 1.5 at 144 DPI…).
pub fn dpi_scale() -> f64 {
    let d = unsafe { GetDpiForSystem() };
    if d == 0 { 1.0 } else { d as f64 / 96.0 }
}

// ---------------------------------------------------------------- compression

/// Densest, slow to decompress (~60 MB/s).
#[allow(dead_code)]
pub const LZMS: u32 = 5;
/// A little bigger, decompresses at ~1 GB/s — used so the installer window opens fast.
pub const XPRESS_HUFF: u32 = 4;

pub fn compress(algo: u32, data: &[u8]) -> Option<Vec<u8>> {
    unsafe {
        let mut h: Handle = std::ptr::null_mut();
        if CreateCompressor(algo, std::ptr::null(), &mut h) == 0 {
            return None;
        }
        let mut need = 0usize;
        Compress(h, data.as_ptr(), data.len(), std::ptr::null_mut(), 0, &mut need);
        let mut out = vec![0u8; need.max(64)];
        let mut n = 0usize;
        let ok = Compress(h, data.as_ptr(), data.len(), out.as_mut_ptr(), out.len(), &mut n) != 0;
        CloseCompressor(h);
        ok.then(|| {
            out.truncate(n);
            out
        })
    }
}

pub fn decompress(algo: u32, data: &[u8], raw_len: usize) -> Option<Vec<u8>> {
    unsafe {
        let mut h: Handle = std::ptr::null_mut();
        if CreateDecompressor(algo, std::ptr::null(), &mut h) == 0 {
            return None;
        }
        let mut out = vec![0u8; raw_len];
        let mut n = 0usize;
        let ok = Decompress(h, data.as_ptr(), data.len(), out.as_mut_ptr(), out.len(), &mut n) != 0;
        CloseDecompressor(h);
        (ok && n == raw_len).then_some(out)
    }
}

// ---------------------------------------------------------------- registry (HKCU)

fn with_key<T>(sub: &str, f: impl FnOnce(Hkey) -> T) -> Option<T> {
    const KEY_WRITE: u32 = 0x20006;
    let w = wide(OsStr::new(sub));
    let mut k: Hkey = 0;
    let rc = unsafe { RegCreateKeyExW(HKCU, w.as_ptr(), 0, std::ptr::null(), 0, KEY_WRITE, std::ptr::null(), &mut k, std::ptr::null_mut()) };
    if rc != 0 {
        return None;
    }
    let r = f(k);
    unsafe { RegCloseKey(k) };
    Some(r)
}

/// Set a string value ("" name = the key's default value).
pub fn reg_str(sub: &str, name: &str, value: &str) -> bool {
    with_key(sub, |k| {
        let n = wide(OsStr::new(name));
        let v = wide(OsStr::new(value));
        unsafe { RegSetValueExW(k, if name.is_empty() { std::ptr::null() } else { n.as_ptr() }, 0, 1, v.as_ptr() as *const u8, (v.len() * 2) as u32) == 0 }
    })
    .unwrap_or(false)
}

pub fn reg_dword(sub: &str, name: &str, value: u32) -> bool {
    with_key(sub, |k| {
        let n = wide(OsStr::new(name));
        unsafe { RegSetValueExW(k, n.as_ptr(), 0, 4, value.to_le_bytes().as_ptr(), 4) == 0 }
    })
    .unwrap_or(false)
}

/// An empty REG_NONE value (how OpenWithProgids entries are written).
pub fn reg_none(sub: &str, name: &str) -> bool {
    with_key(sub, |k| {
        let n = wide(OsStr::new(name));
        unsafe { RegSetValueExW(k, n.as_ptr(), 0, 0, std::ptr::null(), 0) == 0 }
    })
    .unwrap_or(false)
}

pub fn reg_get_str(sub: &str, name: &str) -> Option<String> {
    const RRF_RT_REG_SZ: u32 = 0x2;
    let (s, n) = (wide(OsStr::new(sub)), wide(OsStr::new(name)));
    let mut buf = vec![0u16; 2048];
    let mut len = (buf.len() * 2) as u32;
    let rc = unsafe { RegGetValueW(HKCU, s.as_ptr(), n.as_ptr(), RRF_RT_REG_SZ, std::ptr::null_mut(), buf.as_mut_ptr() as *mut c_void, &mut len) };
    if rc != 0 {
        return None;
    }
    let chars = (len as usize / 2).saturating_sub(1);
    Some(String::from_utf16_lossy(&buf[..chars]))
}

/// Remove HKCU\<sub> and everything under it. `sub` must be a specific key of ours.
pub fn reg_delete_tree(sub: &str) {
    if sub.trim_matches('\\').is_empty() {
        return;
    }
    let w = wide(OsStr::new(sub));
    unsafe { RegDeleteTreeW(HKCU, w.as_ptr()) };
}

pub fn reg_delete_value(sub: &str, name: &str) {
    let (s, n) = (wide(OsStr::new(sub)), wide(OsStr::new(name)));
    unsafe { RegDeleteKeyValueW(HKCU, s.as_ptr(), n.as_ptr()) };
}

pub fn assoc_changed() {
    const SHCNE_ASSOCCHANGED: i32 = 0x0800_0000;
    unsafe { SHChangeNotify(SHCNE_ASSOCCHANGED, 0, std::ptr::null(), std::ptr::null()) };
}

// ---------------------------------------------------------------- shell

pub fn com_init() {
    unsafe { CoInitializeEx(std::ptr::null(), 0x2) };
}

pub fn desktop_dir() -> Option<PathBuf> {
    let id = Guid(0xB4BFCC3A, 0xDB2C, 0x424C, [0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41]);
    let mut p: *mut u16 = std::ptr::null_mut();
    if unsafe { SHGetKnownFolderPath(&id, 0, std::ptr::null_mut(), &mut p) } != 0 || p.is_null() {
        return None;
    }
    let mut n = 0;
    while unsafe { *p.add(n) } != 0 {
        n += 1;
    }
    let s = OsString::from_wide(unsafe { std::slice::from_raw_parts(p, n) });
    unsafe { CoTaskMemFree(p as *mut c_void) };
    Some(PathBuf::from(s))
}

pub fn start_menu_dir() -> Option<PathBuf> {
    std::env::var_os("APPDATA").map(|a| PathBuf::from(a).join(r"Microsoft\Windows\Start Menu\Programs"))
}

/// Create a .lnk via IShellLinkW + IPersistFile (call com_init on this thread first).
pub fn create_shortcut(lnk: &Path, target: &Path, workdir: &Path, description: &str) -> bool {
    let clsid = Guid(0x00021401, 0, 0, [0xC0, 0, 0, 0, 0, 0, 0, 0x46]);
    let iid_link = Guid(0x000214F9, 0, 0, [0xC0, 0, 0, 0, 0, 0, 0, 0x46]);
    let iid_file = Guid(0x0000010B, 0, 0, [0xC0, 0, 0, 0, 0, 0, 0, 0x46]);
    unsafe {
        let mut link: *mut c_void = std::ptr::null_mut();
        if CoCreateInstance(&clsid, std::ptr::null(), 1, &iid_link, &mut link) != 0 || link.is_null() {
            return false;
        }
        let vt = *(link as *const *const usize);
        type SetW = unsafe extern "system" fn(*mut c_void, *const u16) -> i32;
        type SetIcon = unsafe extern "system" fn(*mut c_void, *const u16, i32) -> i32;
        type Qi = unsafe extern "system" fn(*mut c_void, *const Guid, *mut *mut c_void) -> i32;
        type Rel = unsafe extern "system" fn(*mut c_void) -> u32;
        type Save = unsafe extern "system" fn(*mut c_void, *const u16, i32) -> i32;
        let call = |i: usize| *vt.add(i);
        let t = wide(target.as_os_str());
        let d = wide(workdir.as_os_str());
        let desc = wide(OsStr::new(description));
        std::mem::transmute::<usize, SetW>(call(20))(link, t.as_ptr()); // SetPath
        std::mem::transmute::<usize, SetW>(call(9))(link, d.as_ptr()); // SetWorkingDirectory
        std::mem::transmute::<usize, SetW>(call(7))(link, desc.as_ptr()); // SetDescription
        std::mem::transmute::<usize, SetIcon>(call(17))(link, t.as_ptr(), 0); // SetIconLocation
        let mut pf: *mut c_void = std::ptr::null_mut();
        let ok = std::mem::transmute::<usize, Qi>(call(0))(link, &iid_file, &mut pf) == 0 && !pf.is_null();
        let mut saved = false;
        if ok {
            let pvt = *(pf as *const *const usize);
            let l = wide(lnk.as_os_str());
            saved = std::mem::transmute::<usize, Save>(*pvt.add(6))(pf, l.as_ptr(), 1) == 0;
            std::mem::transmute::<usize, Rel>(*pvt.add(2))(pf);
        }
        std::mem::transmute::<usize, Rel>(call(2))(link);
        saved
    }
}

/// Folder picker. Returns the chosen folder.
pub fn pick_folder(owner: isize, title: &str) -> Option<PathBuf> {
    let mut name = vec![0u16; 260];
    let t = wide(OsStr::new(title));
    let bi = BrowseInfoW {
        owner: owner as *mut c_void,
        root: std::ptr::null(),
        display: name.as_mut_ptr(),
        title: t.as_ptr(),
        flags: 0x1 | 0x10 | 0x40, // RETURNONLYFSDIRS | EDITBOX | NEWDIALOGSTYLE
        callback: std::ptr::null(),
        lparam: 0,
        image: 0,
    };
    let pidl = unsafe { SHBrowseForFolderW(&bi) };
    if pidl.is_null() {
        return None;
    }
    let mut buf = vec![0u16; 1024];
    let ok = unsafe { SHGetPathFromIDListW(pidl, buf.as_mut_ptr()) } != 0;
    unsafe { CoTaskMemFree(pidl) };
    if !ok {
        return None;
    }
    let n = buf.iter().position(|&c| c == 0).unwrap_or(0);
    Some(PathBuf::from(OsString::from_wide(&buf[..n])))
}

pub fn shell_open(target: &str) {
    let op = wide(OsStr::new("open"));
    let t = wide(OsStr::new(target));
    unsafe { ShellExecuteW(std::ptr::null_mut(), op.as_ptr(), t.as_ptr(), std::ptr::null(), std::ptr::null(), 1) };
}

/// Unload a DLL this process loaded (by path), so its file can be deleted.
pub fn unload(path: &Path) {
    let w = wide(path.as_os_str());
    for _ in 0..4 {
        let m = unsafe { GetModuleHandleW(w.as_ptr()) };
        if m.is_null() {
            break;
        }
        unsafe { FreeLibrary(m) };
    }
}

/// Yes/No question box; true for Yes.
pub fn ask(title: &str, text: &str) -> bool {
    let (t, c) = (wide(OsStr::new(text)), wide(OsStr::new(title)));
    unsafe { MessageBoxW(std::ptr::null_mut(), t.as_ptr(), c.as_ptr(), 0x4 | 0x20) == 6 }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compression_round_trip() {
        let data: Vec<u8> = (0..200_000u32).flat_map(|i| (i % 251).to_le_bytes()).collect();
        for algo in [LZMS, XPRESS_HUFF] {
            let c = compress(algo, &data).unwrap();
            assert!(c.len() < data.len());
            assert_eq!(decompress(algo, &c, data.len()).unwrap(), data);
        }
    }

    // Uses a throwaway key under HKCU\Software and removes it again.
    #[test]
    fn registry_write_read_delete() {
        let key = r"Software\DogaSelfTest\Sub";
        assert!(reg_str(key, "Name", "Dōga ✓"));
        assert!(reg_dword(key, "Num", 7));
        assert!(reg_none(key, "Empty"));
        assert_eq!(reg_get_str(key, "Name").as_deref(), Some("Dōga ✓"));
        reg_delete_value(key, "Name");
        assert_eq!(reg_get_str(key, "Name"), None);
        reg_delete_tree(r"Software\DogaSelfTest");
        assert_eq!(reg_get_str(key, "Num"), None);
        assert!(!with_key_exists(r"Software\DogaSelfTest"));
    }

    fn with_key_exists(sub: &str) -> bool {
        const KEY_READ: u32 = 0x20019;
        #[link(name = "advapi32")]
        extern "system" {
            fn RegOpenKeyExW(k: Hkey, sub: *const u16, o: u32, sam: u32, out: *mut Hkey) -> i32;
        }
        let w = wide(OsStr::new(sub));
        let mut k: Hkey = 0;
        let rc = unsafe { RegOpenKeyExW(HKCU, w.as_ptr(), 0, KEY_READ, &mut k) };
        if rc == 0 {
            unsafe { RegCloseKey(k) };
        }
        rc == 0
    }

    #[test]
    fn shortcut_is_written() {
        com_init();
        let dir = std::env::temp_dir().join(format!("doga-lnk-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let lnk = dir.join("Dōga.lnk");
        let target = std::env::current_exe().unwrap();
        assert!(create_shortcut(&lnk, &target, &dir, "test"));
        assert!(std::fs::metadata(&lnk).unwrap().len() > 0);
        let _ = std::fs::remove_file(&lnk);
        let _ = std::fs::remove_dir(&dir);
    }
}

pub fn info(title: &str, text: &str) {
    let (t, c) = (wide(OsStr::new(text)), wide(OsStr::new(title)));
    unsafe { MessageBoxW(std::ptr::null_mut(), t.as_ptr(), c.as_ptr(), 0x40) };
}
