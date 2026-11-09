//! Single-file installer payload.
//!
//! `Dōga-Setup.exe` is doga.exe with a compressed payload appended:
//!   [doga.exe bytes][blob 0][blob 1]…[index][footer]
//! index:  per entry  u32 path_len · path (utf-8, '/'-separated) · u64 raw · u64 packed · u64 offset · u8 algo
//! footer: u64 index_offset · u32 count · u64 exe_len · b"DOGAPAK1"
//! When doga.exe finds a footer on itself it runs as the installer.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use crate::sys;

const MAGIC: &[u8; 8] = b"DOGAPAK1";
const FOOTER: u64 = 8 + 4 + 8 + 8;

pub struct Entry {
    pub path: String,
    pub raw: u64,
    packed: u64,
    offset: u64,
    algo: u8,
}

pub struct Payload {
    file: PathBuf,
    pub exe_len: u64,
    pub entries: Vec<Entry>,
}

fn u32le(b: &[u8]) -> u32 {
    u32::from_le_bytes(b[..4].try_into().unwrap())
}
fn u64le(b: &[u8]) -> u64 {
    u64::from_le_bytes(b[..8].try_into().unwrap())
}

impl Payload {
    /// The payload appended to this executable, if any.
    pub fn open_self() -> Option<Payload> {
        let exe = std::env::current_exe().ok()?;
        Payload::open(&exe)
    }

    pub fn open(file: &Path) -> Option<Payload> {
        let mut f = File::open(file).ok()?;
        let len = f.metadata().ok()?.len();
        if len < FOOTER {
            return None;
        }
        let mut foot = [0u8; FOOTER as usize];
        f.seek(SeekFrom::Start(len - FOOTER)).ok()?;
        f.read_exact(&mut foot).ok()?;
        if &foot[20..28] != MAGIC {
            return None;
        }
        let (index_off, count, exe_len) = (u64le(&foot[0..]), u32le(&foot[8..]) as usize, u64le(&foot[12..]));
        if index_off >= len || exe_len > index_off {
            return None;
        }
        let mut index = vec![0u8; (len - FOOTER - index_off) as usize];
        f.seek(SeekFrom::Start(index_off)).ok()?;
        f.read_exact(&mut index).ok()?;
        let mut entries = Vec::with_capacity(count);
        let mut p = 0usize;
        for _ in 0..count {
            let n = u32le(index.get(p..)?) as usize;
            p += 4;
            let path = String::from_utf8(index.get(p..p + n)?.to_vec()).ok()?;
            p += n;
            let b = index.get(p..p + 25)?;
            entries.push(Entry { path, raw: u64le(&b[0..]), packed: u64le(&b[8..]), offset: u64le(&b[16..]), algo: b[24] });
            p += 25;
        }
        Some(Payload { file: file.to_path_buf(), exe_len, entries })
    }

    pub fn read(&self, e: &Entry) -> Option<Vec<u8>> {
        let mut f = File::open(&self.file).ok()?;
        f.seek(SeekFrom::Start(e.offset)).ok()?;
        let mut buf = vec![0u8; e.packed as usize];
        f.read_exact(&mut buf).ok()?;
        match e.algo {
            0 => Some(buf),
            a => sys::decompress(a as u32, &buf, e.raw as usize),
        }
    }

    /// The plain doga.exe this installer was built from.
    pub fn exe_bytes(&self) -> Option<Vec<u8>> {
        let mut f = File::open(&self.file).ok()?;
        let mut buf = vec![0u8; self.exe_len as usize];
        f.read_exact(&mut buf).ok()?;
        Some(buf)
    }
}

fn walk(dir: &Path, base: &Path, out: &mut Vec<(String, PathBuf)>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    let mut items: Vec<_> = rd.filter_map(|e| e.ok()).collect();
    items.sort_by_key(|e| e.file_name());
    for e in items {
        let p = e.path();
        if p.is_dir() {
            walk(&p, base, out);
        } else {
            let rel = p.strip_prefix(base).unwrap().to_string_lossy().replace('\\', "/");
            out.push((rel, p));
        }
    }
}

/// `doga.exe --pack <out.exe>`: this exe + libmpv + ui/ → a single installer.
pub fn build(out: &Path, root: &Path) -> Result<(), String> {
    let me = std::env::current_exe().map_err(|e| e.to_string())?;
    // never nest payloads: if this exe is itself an installer, take only its exe part
    let exe = match Payload::open(&me) {
        Some(p) => p.exe_bytes().ok_or("could not read exe")?,
        None => std::fs::read(&me).map_err(|e| e.to_string())?,
    };
    let mut files: Vec<(String, PathBuf)> = vec![("libmpv-2.dll".into(), root.join("vendor/mpv/libmpv-2.dll"))];
    walk(&root.join("ui"), root, &mut files);
    for (_, p) in &files {
        if !p.is_file() {
            return Err(format!("missing {}", p.display()));
        }
    }

    let mut blob = exe;
    let exe_len = blob.len() as u64;
    let mut index = Vec::new();
    for (rel, p) in &files {
        let raw = std::fs::read(p).map_err(|e| format!("{}: {e}", p.display()))?;
        let t = std::time::Instant::now();
        let (algo, data) = match sys::compress(sys::XPRESS_HUFF, &raw) {
            Some(c) if c.len() < raw.len() => (sys::XPRESS_HUFF as u8, c),
            _ => (0u8, raw.clone()),
        };
        eprintln!("  {rel:<40} {:>10} → {:>10}  ({:.1}s)", raw.len(), data.len(), t.elapsed().as_secs_f32());
        let offset = blob.len() as u64;
        blob.extend_from_slice(&data);
        index.extend((rel.len() as u32).to_le_bytes());
        index.extend(rel.as_bytes());
        index.extend((raw.len() as u64).to_le_bytes());
        index.extend((data.len() as u64).to_le_bytes());
        index.extend(offset.to_le_bytes());
        index.push(algo);
    }
    let index_off = blob.len() as u64;
    blob.extend(index);
    blob.extend(index_off.to_le_bytes());
    blob.extend((files.len() as u32).to_le_bytes());
    blob.extend(exe_len.to_le_bytes());
    blob.extend(MAGIC);
    std::fs::write(out, &blob).map_err(|e| e.to_string())?;
    eprintln!("wrote {} ({:.1} MB)", out.display(), blob.len() as f64 / 1e6);
    Ok(())
}
