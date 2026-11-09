//! Series detection: given the file you opened, find the other videos in the same folder
//! that belong to the same run ("Anime 1", "Anime 2", … but not "Car 5"), in order.
//!
//! 1. Clean each name: drop the extension, [bracket]/(paren)/{brace} groups and release tags.
//! 2. Find index-token candidates in the opened file: S01E04 / 1x04, plain numbers,
//!    or one trailing letter ("… A", "… B").
//! 3. Pick the candidate that actually varies across the folder (so "Mob Psycho 100 - 03"
//!    uses 03, not 100). The text before it is the series key.
//! 4. Every file with the same key joins, sorted by the token.

use std::cmp::Ordering;
use std::path::{Path, PathBuf};

pub const VIDEO_EXTS: &[&str] = &[
    "mkv", "mp4", "m4v", "avi", "mov", "webm", "wmv", "flv", "ts", "m2ts", "mts", "mpg", "mpeg",
    "ogv", "3gp", "vob", "rmvb", "divx", "f4v", "asf", "mxf",
];

/// Release tags that are noise in a title. Matching stops the title at the first one,
/// since scene names put everything after it in tag form ("Show 2019 1080p WEB-DL x264-GRP").
const TAGS: &[&str] = &[
    "2160p", "1440p", "1080p", "1080i", "720p", "576p", "480p", "360p", "4k", "uhd", "hdr", "hdr10",
    "hdr10+", "dovi", "x264", "x265", "h264", "h265", "h.264", "h.265", "hevc", "avc", "av1", "vp9",
    "xvid", "aac", "flac", "opus", "ac3", "eac3", "ddp5.1", "dd5.1", "truehd", "atmos", "10bit",
    "10-bit", "8bit", "8-bit", "hi10p", "web-dl", "webdl", "webrip", "bluray", "blu-ray", "bdrip",
    "brrip", "remux", "hdtv", "dvdrip", "repack", "proper",
];

/// Words that may sit right before an episode number with no separator: "EP04", "E12", "Vol3".
const NUM_PREFIXES: &[&str] = &["e", "ep", "eps", "episode", "ch", "chapter", "part", "pt", "vol", "no", "disc", "cd"];

pub fn is_video(p: &Path) -> bool {
    p.extension()
        .and_then(|e| e.to_str())
        .map(|e| VIDEO_EXTS.contains(&e.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Key {
    /// (season, episode × 1000 + decimal part) — plain numbers use season 0.
    Num(u64, u64),
    Letter(char),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    SeasonEp,
    Number,
    Letter,
}

#[derive(Clone, Debug)]
struct Cand {
    start: usize, // byte offset in the cleaned name
    kind: Kind,
    key: Key,
    label: String,
}

/// Kana, kanji and hangul. These are written without spaces, so a number right next to one
/// ("タイトル01", "第01話") is still a number on its own, unlike the "264" in "x264".
fn cjk(c: char) -> bool {
    matches!(c as u32, 0x3000..=0x30FF | 0x3400..=0x4DBF | 0x4E00..=0x9FFF | 0xAC00..=0xD7AF | 0xF900..=0xFAFF | 0xFF66..=0xFF9F)
}

/// A letter or digit that glues onto its neighbours to make one word.
fn glue(c: char) -> bool {
    c.is_alphanumeric() && !cjk(c)
}

/// File name → readable title: no extension, no bracket groups, no release tags.
pub fn clean(name: &str) -> String {
    let stem = match name.rfind('.') {
        Some(i) if i > 0 && name[i + 1..].chars().all(|c| c.is_ascii_alphanumeric()) && name.len() - i <= 6 => &name[..i],
        _ => name,
    };
    // drop bracket groups (non-nested is enough for release names)
    let mut s = String::with_capacity(stem.len());
    let mut depth: Vec<char> = Vec::new();
    for c in stem.chars() {
        // fullwidth digits (０１) count as digits
        let c = match c {
            '０'..='９' => char::from(b'0' + (c as u32 - '０' as u32) as u8),
            c => c,
        };
        match c {
            '[' | '(' | '{' | '【' | '（' => depth.push(c),
            ']' | ')' | '}' | '】' | '）' if !depth.is_empty() => {
                depth.pop();
                s.push(' ');
            }
            _ if depth.is_empty() => s.push(c),
            _ => {}
        }
    }
    // '_' always separates; '.' separates unless it's a decimal point (12.5)
    let chars: Vec<char> = s.chars().collect();
    let mut t = String::with_capacity(s.len());
    for (i, &c) in chars.iter().enumerate() {
        // a decimal is "12.5": 1–2 digits after the dot and nothing glued on ("2019.1080p" is not one)
        let frac_len = chars[i + 1..].iter().take_while(|n| n.is_ascii_digit()).count();
        let decimal = c == '.'
            && i > 0
            && chars[i - 1].is_ascii_digit()
            && (1..=2).contains(&frac_len)
            && !chars.get(i + 1 + frac_len).is_some_and(|&n| glue(n));
        t.push(if c == '_' || (c == '.' && !decimal) { ' ' } else { c });
    }
    // stop at the first release tag
    let mut words: Vec<&str> = Vec::new();
    for w in t.split_whitespace() {
        let lw = w.to_ascii_lowercase();
        let head = lw.split('-').next().unwrap_or("");
        if TAGS.contains(&lw.as_str()) || (lw.contains('-') && TAGS.contains(&head)) {
            break;
        }
        words.push(w);
    }
    trim_seps(&words.join(" ")).to_string()
}

fn trim_seps(s: &str) -> &str {
    s.trim_matches(|c: char| c.is_whitespace() || matches!(c, '-' | '–' | '—' | '_' | '.' | ',' | ':' | '~' | '|' | '·'))
}

fn norm_key(s: &str) -> String {
    let mut out = String::new();
    let mut gap = false;
    for c in s.chars().flat_map(|c| c.to_lowercase()) {
        if c.is_alphanumeric() {
            if gap && !out.is_empty() {
                out.push(' ');
            }
            out.push(c);
            gap = false;
        } else {
            gap = true;
        }
    }
    out
}

fn candidates(cleaned: &str) -> Vec<Cand> {
    let ch: Vec<(usize, char)> = cleaned.char_indices().collect();
    let n = ch.len();
    let at = |i: usize| ch.get(i).map(|x| x.1);
    let alnum = |c: Option<char>| c.is_some_and(glue);
    let letter = |c: char| c.is_alphabetic() && !cjk(c);
    let digit = |c: Option<char>| c.is_some_and(|c| c.is_ascii_digit());
    let digits_from = |mut i: usize| -> (usize, u64) {
        let mut v = 0u64;
        while i < n && ch[i].1.is_ascii_digit() {
            v = v.saturating_mul(10).saturating_add(ch[i].1 as u64 - '0' as u64);
            i += 1;
        }
        (i, v)
    };
    let mut out = Vec::new();
    let mut covered = vec![false; n];

    // S01E04 / s1e4 / 1x04
    for i in 0..n {
        if i > 0 && alnum(at(i - 1)) {
            continue;
        }
        let (season, ep_start) = if matches!(at(i), Some('s' | 'S')) && digit(at(i + 1)) {
            let (j, s) = digits_from(i + 1);
            if !matches!(at(j), Some('e' | 'E')) || !digit(at(j + 1)) {
                continue;
            }
            (s, j + 1)
        } else if digit(at(i)) {
            let (j, s) = digits_from(i);
            if !matches!(at(j), Some('x' | 'X')) || !digit(at(j + 1)) || j - i > 2 {
                continue;
            }
            (s, j + 1)
        } else {
            continue;
        };
        let (end, ep) = digits_from(ep_start);
        if alnum(at(end)) && !matches!(at(end), Some('v' | 'V' | 'e' | 'E')) {
            continue;
        }
        for c in covered.iter_mut().take(end).skip(i) {
            *c = true;
        }
        let label = if season <= 1 { format!("E{ep:02}") } else { format!("S{season:02}E{ep:02}") };
        out.push(Cand { start: ch[i].0, kind: Kind::SeasonEp, key: Key::Num(season, ep * 1000), label });
    }

    // plain numbers
    let mut i = 0;
    while i < n {
        if covered[i] || !ch[i].1.is_ascii_digit() || (i > 0 && ch[i - 1].1.is_ascii_digit()) {
            i += 1;
            continue;
        }
        // what's directly before: nothing, a separator, or an episode-ish word
        let ok_before = if i == 0 || !glue(ch[i - 1].1) {
            true
        } else {
            let mut k = i;
            while k > 0 && letter(ch[k - 1].1) {
                k -= 1;
            }
            let word: String = ch[k..i].iter().map(|x| x.1.to_ascii_lowercase()).collect();
            (k == 0 || !glue(ch[k - 1].1)) && NUM_PREFIXES.contains(&word.as_str())
        };
        let (mut end, whole) = digits_from(i);
        let mut frac = 0u64;
        if at(end) == Some('.') && digit(at(end + 1)) {
            let (e2, f) = digits_from(end + 1);
            let places = (e2 - end - 1).min(3) as u32;
            frac = f / 10u64.pow((e2 - end - 1).saturating_sub(3) as u32) * 10u64.pow(3 - places);
            end = e2;
        }
        let ok_after = !alnum(at(end)) || (matches!(at(end), Some('v' | 'V')) && digit(at(end + 1)));
        if ok_before && ok_after {
            // "EP04" → the series key ends before "EP"
            let mut s = i;
            while s > 0 && letter(ch[s - 1].1) {
                s -= 1;
            }
            // "第01話" → the key ends before the ordinal mark
            if s == i && s > 0 && matches!(ch[s - 1].1, '第' | '제') {
                s -= 1;
            }
            let text: String = ch[i..end].iter().map(|x| x.1).collect();
            out.push(Cand { start: ch[s].0, kind: Kind::Number, key: Key::Num(0, whole.saturating_mul(1000) + frac), label: text });
        }
        i = end.max(i + 1);
    }

    // one trailing letter: "Long Title A"
    let trimmed = trim_seps(cleaned);
    if let Some(sp) = trimmed.rfind(|c: char| c.is_whitespace() || c == '-') {
        let last = &trimmed[sp + 1..];
        let mut it = last.chars();
        if let (Some(c), None) = (it.next(), it.next()) {
            if c.is_ascii_alphabetic() && !trim_seps(&trimmed[..sp]).is_empty() {
                let u = c.to_ascii_uppercase();
                out.push(Cand { start: sp + 1, kind: Kind::Letter, key: Key::Letter(u), label: u.to_string() });
            }
        }
    }
    out
}

struct Parsed {
    cleaned: String,
    cands: Vec<Cand>,
}

fn parse(name: &str) -> Parsed {
    let cleaned = clean(name);
    let cands = candidates(&cleaned);
    Parsed { cleaned, cands }
}

/// Result of detection over a list of names.
#[derive(Debug, PartialEq)]
pub struct Found {
    /// Series name as written in the opened file ("Neon Drift").
    pub name: String,
    /// (index into the input names, display label) in play order.
    pub members: Vec<(usize, String)>,
}

/// Pure detection over file names (no disk access) — `current` indexes into `names`.
pub fn detect_names(current: usize, names: &[String]) -> Option<Found> {
    let parsed: Vec<Parsed> = names.iter().map(|n| parse(n)).collect();
    let me = &parsed[current];
    let mut best: Option<(usize, &Cand, String)> = None; // (score, cand, key)
    for c in &me.cands {
        let key = norm_key(&me.cleaned[..c.start]);
        let score = parsed
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != current)
            .filter(|(_, p)| {
                p.cands.iter().any(|o| o.kind == c.kind && o.key != c.key && norm_key(&p.cleaned[..o.start]) == key)
            })
            .count();
        // more varying siblings wins; on a tie the later (rightmost) token wins
        if best.as_ref().map_or(true, |(s, b, _)| score > *s || (score == *s && c.start > b.start)) {
            best = Some((score, c, key));
        }
    }
    let (score, cand, key) = best?;
    if score == 0 {
        return None;
    }
    let mut members: Vec<(usize, &Cand)> = parsed
        .iter()
        .enumerate()
        .filter_map(|(i, p)| {
            p.cands
                .iter()
                .find(|o| o.kind == cand.kind && norm_key(&p.cleaned[..o.start]) == key)
                .map(|o| (i, o))
        })
        .collect();
    members.sort_by(|a, b| a.1.key.cmp(&b.1.key).then_with(|| natural_cmp(&names[a.0], &names[b.0])));
    // Names that only *start* with a number ("12 Angry Men", "300", "2001 A Space Odyssey") share
    // an empty title. Treat them as episodes only when the numbers look like a run: close
    // together ("1" … "12", gaps allowed) or zero-padded to one width ("01", "02").
    if key.is_empty() && cand.kind == Kind::Number {
        let nums: Vec<u64> = members.iter().map(|(_, c)| if let Key::Num(_, v) = c.key { v / 1000 } else { 0 }).collect();
        let (lo, hi) = (nums.iter().min().copied().unwrap_or(0), nums.iter().max().copied().unwrap_or(0));
        let dense = hi - lo < 3 * nums.len() as u64 + 3;
        let width = |c: &Cand| c.label.split('.').next().map_or(0, str::len);
        let padded = members.iter().all(|(_, c)| width(c) == width(members[0].1)) && members.iter().any(|(_, c)| c.label.starts_with('0'));
        if !dense && !padded {
            return None;
        }
    }
    let name = trim_seps(&me.cleaned[..cand.start]).to_string();
    // "S01E04" labels collapse to "E04" only when every member is season 1
    let multi_season = members.iter().any(|(_, c)| matches!(c.key, Key::Num(s, _) if s > 1 && c.kind == Kind::SeasonEp));
    Some(Found {
        name,
        members: members
            .into_iter()
            .map(|(i, c)| {
                let label = match (c.kind, &c.key) {
                    (Kind::SeasonEp, Key::Num(s, e)) if multi_season => format!("S{:02}E{:02}", s, e / 1000),
                    _ => c.label.clone(),
                };
                (i, label)
            })
            .collect(),
    })
}

pub struct Series {
    pub name: String,
    pub files: Vec<PathBuf>,
    pub labels: Vec<String>,
    /// Position of the opened file in `files`.
    pub current: usize,
    /// Video files in the folder in total.
    pub total: usize,
}

/// Look at the opened file's folder and return its series, if it has one.
pub fn detect(path: &Path) -> Option<Series> {
    let dir = path.parent()?;
    let me = path.file_name()?.to_string_lossy().into_owned();
    let mut names: Vec<String> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.') && is_video(Path::new(n)))
        .collect();
    names.sort_by(|a, b| natural_cmp(a, b));
    let current = names.iter().position(|n| n.eq_ignore_ascii_case(&me))?;
    let total = names.len();
    let found = detect_names(current, &names)?;
    let cur_pos = found.members.iter().position(|(i, _)| *i == current)?;
    Some(Series {
        name: if found.name.is_empty() { dir.file_name().map(|d| d.to_string_lossy().into_owned()).unwrap_or_default() } else { found.name },
        files: found.members.iter().map(|(i, _)| dir.join(&names[*i])).collect(),
        labels: found.members.into_iter().map(|(_, l)| l).collect(),
        current: cur_pos,
        total,
    })
}

/// "Ep 2" < "Ep 10": compare digit runs by value.
pub fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, _) => return Ordering::Less,
            (_, None) => return Ordering::Greater,
            (Some(c), Some(d)) if c.is_ascii_digit() && d.is_ascii_digit() => {
                let mut na = String::new();
                while let Some(c) = x.peek().copied().filter(|c| c.is_ascii_digit()) {
                    na.push(c);
                    x.next();
                }
                let mut nb = String::new();
                while let Some(d) = y.peek().copied().filter(|d| d.is_ascii_digit()) {
                    nb.push(d);
                    y.next();
                }
                let (ta, tb) = (na.trim_start_matches('0'), nb.trim_start_matches('0'));
                let o = ta.len().cmp(&tb.len()).then_with(|| ta.cmp(tb)).then_with(|| na.len().cmp(&nb.len()));
                if o != Ordering::Equal {
                    return o;
                }
            }
            (Some(c), Some(d)) => {
                let o = c.to_lowercase().cmp(d.to_lowercase());
                if o != Ordering::Equal {
                    return o;
                }
                x.next();
                y.next();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(current: &str, names: &[&str]) -> Option<(String, Vec<String>, Vec<String>)> {
        let names: Vec<String> = names.iter().map(|s| s.to_string()).collect();
        let cur = names.iter().position(|n| n == current).unwrap();
        detect_names(cur, &names).map(|f| {
            (
                f.name,
                f.members.iter().map(|(i, _)| names[*i].clone()).collect(),
                f.members.into_iter().map(|(_, l)| l).collect(),
            )
        })
    }

    #[test]
    fn simple_numbers_exclude_other_series() {
        let (name, files, labels) =
            run("Anime 2.mkv", &["Anime 1.mkv", "Car 5.mkv", "Anime 10.mkv", "Anime 3.mkv", "Anime 2.mkv"]).unwrap();
        assert_eq!(name, "Anime");
        assert_eq!(files, ["Anime 1.mkv", "Anime 2.mkv", "Anime 3.mkv", "Anime 10.mkv"]);
        assert_eq!(labels, ["1", "2", "3", "10"]);
    }

    #[test]
    fn trailing_letters() {
        let t = "sdafohasdfjaosjdfi";
        let names = [format!("{t} C.mp4"), format!("{t} A.mp4"), format!("{t} B.mp4"), "other thing.mp4".to_string()];
        let refs: Vec<&str> = names.iter().map(|s| s.as_str()).collect();
        let (name, files, labels) = run(&names[1], &refs).unwrap();
        assert_eq!(name, t);
        assert_eq!(files, [names[1].clone(), names[2].clone(), names[0].clone()]);
        assert_eq!(labels, ["A", "B", "C"]);
    }

    #[test]
    fn fansub_names_with_tags_and_hashes() {
        let names = [
            "[SubsPlease] Frieren - 05 (1080p) [A1B2C3D4].mkv",
            "[SubsPlease] Frieren - 04 (1080p) [99887766].mkv",
            "[SubsPlease] Frieren - 06 (1080p) [0F0F0F0F].mkv",
            "[SubsPlease] Dandadan - 05 (1080p) [12345678].mkv",
        ];
        let (name, files, labels) = run(names[0], &names).unwrap();
        assert_eq!(name, "Frieren");
        assert_eq!(files, [names[1], names[0], names[2]]);
        assert_eq!(labels, ["04", "05", "06"]);
    }

    #[test]
    fn picks_the_number_that_varies() {
        let names = ["Mob Psycho 100 - 03.mkv", "Mob Psycho 100 - 01.mkv", "Mob Psycho 100 - 02.mkv"];
        let (name, _, labels) = run(names[0], &names).unwrap();
        assert_eq!(name, "Mob Psycho 100");
        assert_eq!(labels, ["01", "02", "03"]);
    }

    #[test]
    fn season_episode_with_episode_titles() {
        let names = [
            "Neon Drift — S01E04 — Static Bloom.mkv",
            "Neon Drift — S01E01 — Cold Boot.mkv",
            "Neon Drift — S01E02 — Packet Loss.mkv",
            "Neon Drift — S02E01 — Reboot.mkv",
            "Harbor Lights (2024).mkv",
        ];
        let (name, files, labels) = run(names[0], &names).unwrap();
        assert_eq!(name, "Neon Drift");
        assert_eq!(files, [names[1], names[2], names[0], names[3]]);
        assert_eq!(labels, ["S01E01", "S01E02", "S01E04", "S02E01"]);
    }

    #[test]
    fn scene_style_names() {
        let names = [
            "Some.Show.S01E02.1080p.WEB-DL.DDP5.1.H.264-GRP.mkv",
            "Some.Show.S01E01.1080p.WEB-DL.DDP5.1.H.264-GRP.mkv",
            "Some.Show.S01E03.720p.HDTV.x264-OTHER.mkv",
        ];
        let (name, files, labels) = run(names[0], &names).unwrap();
        assert_eq!(name, "Some Show");
        assert_eq!(files, [names[1], names[0], names[2]]);
        assert_eq!(labels, ["E01", "E02", "E03"]);
    }

    #[test]
    fn ep_prefix_and_versions() {
        let names = ["Show EP02v2.mkv", "Show EP01.mkv", "Show EP03.mkv"];
        let (_, files, _) = run(names[0], &names).unwrap();
        assert_eq!(files, [names[1], names[0], names[2]]);
    }

    #[test]
    fn japanese_numbering() {
        // a number written straight after kana/kanji, with or without 第…話
        for (a, b) in [
            ("タイトル 第01話.mkv", "タイトル 第02話.mkv"),
            ("タイトル 01話.mkv", "タイトル 02話.mkv"),
            ("タイトル01.mkv", "タイトル02.mkv"),
            ("タイトル第01話.mkv", "タイトル第02話.mkv"),
            ("タイトル ０１.mkv", "タイトル ０２.mkv"),
        ] {
            let (name, files, labels) = run(a, &[a, b, "べつのさくひん 01.mkv"]).unwrap_or_else(|| panic!("{a}"));
            assert_eq!(name, "タイトル", "{a}");
            assert_eq!(files, vec![a, b], "{a}");
            assert_eq!(labels, vec!["01", "02"], "{a}");
        }
        // still not fooled by codec numbers glued to latin letters
        assert_eq!(run("Movie x264.mkv", &["Movie x264.mkv", "Movie x265.mkv"]), None);
    }

    #[test]
    fn titles_that_start_with_a_number_are_not_a_series() {
        let all = ["12 Angry Men.mkv", "300.mkv", "2001 A Space Odyssey.mkv"];
        for f in all {
            assert_eq!(run(f, &all), None, "{f}");
        }
        // but bare episode numbers are
        let eps = ["1.mkv", "2.mkv", "3.mkv", "10.mkv"];
        assert_eq!(run("2.mkv", &eps).map(|r| r.1.join("|")), Some("1.mkv|2.mkv|3.mkv|10.mkv".to_string()));
        let pad = ["01 - Pilot.mkv", "02 - Second.mkv", "24 - Finale.mkv"];
        assert_eq!(run("01 - Pilot.mkv", &pad).map(|r| r.2.join("|")), Some("01|02|24".to_string()));
    }

    #[test]
    fn standalone_movie_is_alone() {
        assert!(run("Harbor Lights (2024).mkv", &["Harbor Lights (2024).mkv", "Anime 1.mkv", "Anime 2.mkv"]).is_none());
        assert!(run("Car 5.mkv", &["Anime 1.mkv", "Car 5.mkv", "Anime 2.mkv"]).is_none());
    }

    #[test]
    fn clean_titles() {
        assert_eq!(clean("[Group] Long Title - 12 [1080p][HEVC].mkv"), "Long Title - 12");
        assert_eq!(clean("Movie.Name.2019.1080p.BluRay.x264-SPARKS.mkv"), "Movie Name 2019");
        assert_eq!(clean("Show 12.5.mkv"), "Show 12.5");
    }

    #[test]
    fn natural_order() {
        let mut v = vec!["a10", "a2", "a1"];
        v.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(v, ["a1", "a2", "a10"]);
    }
}
