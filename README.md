# Dōga

A video player for Windows that plays the file exactly as it was made: no colour "enhancement", no gain tricks, no feature bloat.

- **Engine:** libmpv (`gpu-next` / libplacebo on D3D11), the same engine as mpv.
- **Host:** a small Rust program with no dependencies (`src/`). It loads libmpv, applies the fidelity settings, fills the playlist with the opened file's series, and owns the Open dialog.
- **Scrub thumbnails:** `src/thumbs.rs`. A second, hidden libmpv instance (no window, no audio, created on first hover) decodes only the nearest keyframe, scales it to preview size and hands the UI a memory pointer. The hovered position goes first, and neighbouring slots fill in while idle. The main video never waits on it.
- **Chrome:** `ui/doga.lua`, drawn inside mpv's OSD layer so controls never lag or tear against the video.
- **Look:** four dark themes and the drawing kit live in `ui/kit.lua`; the app icon is `assets/icon.svg`.

## Keys

| Key | Does |
| --- | --- |
| **B** / Shift+B | next / previous audio track |
| **V** / Shift+V | next / previous subtitle track (Off is part of the cycle) |
| Space, click | play / pause |
| Right-click | menu: open, audio, subtitles (+ delay), video (aspect, rotate, deinterlace), speed, theme, playlist, info, fullscreen |
| ← / → | 5 seconds back / forward |
| Shift+← / → or , / . | one frame |
| ↑ / ↓, wheel | volume |
| M | mute |
| Enter, F, double-click | fullscreen |
| P | playlist panel |
| Page Down / Page Up | next / previous in playlist |
| I | info (Exact / Passthrough / Tone-mapped) |
| O | open files |
| Z / X | subtitle delay −/+ 50 ms |
| Ctrl+Z / Ctrl+X | audio delay −/+ 50 ms (remembered; for Bluetooth headphones) |
| Home | back to the start |
| S / Shift+S | screenshot of the exact frame / with subtitles, PNG in Pictures\Dōga |
| Ctrl+T | next theme (Nightshade, Glacier, Redline, Carbon) |
| Ctrl+, | Settings |
| Esc | close menu / leave fullscreen |
| Media keys | play/pause, next/previous, stop (keyboards, headphones, the Windows media overlay) |

## Settings

Open with right-click › Settings… or **Ctrl+,**. The video keeps playing dimmed behind it.

- **General:** theme; resume where you stopped; build the playlist from the folder; the Skip opening/ending button.
- **Playback:** seek step for ← → (3–30 s); hardware decoding (the picture is identical either way); your preferred audio and subtitle languages, with Clear.
- **Subtitles:** size (80–130%); whether dialogue moves above the controls.
- **Audio:** volume on launch (remember or always 100%); output device.
- **Hotkeys:** click a key, press the new one, Esc cancels. A key that's already taken moves over, and the old action shows "—". Reset all brings back the defaults.
- **About:** version and engine versions; update status with Check now and Daily/Never; the settings folder; GitHub and licenses.

Everything is saved in `%APPDATA%\Doga\settings.json`.

## Little things that just work

- **Same monitor:** Dōga opens on the screen it was last on, and so does fullscreen.
- **Resume:** files pick up where you stopped, with a short "Resumed at 12:34 · Start over" chip. Home goes back to the start.
- **When something can't play:** a broken or unsupported file gets a plain message saying which file and why, and the playlist carries on.
- **One window:** opening a video while Dōga is already open plays it in that window. Several files opened together from Explorer become one playlist.
- **Preferred languages:** right-click › Audio or Subtitles › "For every file" › "Prefer Japanese" (or whichever language is playing). New files then pick that track automatically. Files you've already watched keep the tracks you chose for them.
- **Skip opening / ending:** when a file has chapters named like an opening or ending (OP, Opening, Intro, ED, Ending, Credits…), a "Skip" button appears for that chapter. Files without chapters never show it.
- **Drops:** drop videos on the playlist panel to insert them at that row. Drop them anywhere else to play them, or drop subtitle files to add them to the current video.

## Install

Run `dist\Doga-Setup.exe`. It installs just for you, with no admin rights, into `%LOCALAPPDATA%\Programs\Doga`. You can add:
- a Start menu shortcut (always) and a desktop shortcut,
- "Open with" registration for video files (Windows then asks you to confirm Dōga in Default apps),
- an entry in Settings › Apps. Uninstalling there removes exactly what setup created and keeps your settings in `%APPDATA%\Doga`.

Build the installer yourself:

```bash
powershell -File tools/build-installer.ps1
```

The installer is `doga.exe` with a compressed payload appended (`src/pack.rs`; Windows' built-in XPRESS-Huffman compression). On launch it shows a native placeholder window at once, unpacks the engine to a temp folder, and draws its UI with the same engine and kit as the player (`ui/installer.lua`, `ui/kit.lua`). Run with `DOGA_SETUP_DRYRUN=1` (and optionally `DOGA_SETUP_DIR=<folder>`) to test without touching shortcuts or the registry.

## Updates

A few seconds after launch, at most once a day, Dōga asks GitHub whether there's a newer release. That request is the only thing it ever sends over the network. If a newer release exists, "Update to x.y.z" appears on the start screen and at the top of the right-click menu, and nothing interrupts what you're watching. Clicking it:
1. downloads the installer and its signature,
2. checks the signature against the key built into Dōga, and refuses anything that doesn't match,
3. updates in place, keeping your settings and choices, and reopens Dōga.

To switch the check off, go to Settings › About › Updates › Never. "Check now" still works whenever you click it.

### Releasing (maintainers)

- One time: `doga.exe --gen-update-key`. This writes the private key to `%USERPROFILE%\.doga-release\update.key` and the public key to `assets/update.pub`. Back up the private key and never commit it. Losing it means a new key, and everyone has to update by hand once.
- Each release: bump `version` in `Cargo.toml`, then run `tools/build-installer.ps1`. It builds, packs and signs `dist/Doga-Setup-<version>.exe(.sig)`. Upload both files to a GitHub release tagged `v<version>`.

## Startup animation

- **No file:** the start screen assembles itself in about 1.3 s, and a click skips it:
  - a scanline sweep,
  - HUD corner brackets drawing in, with labels typing beside them,
  - the colour blocks sliding in and the seek-bar line filling,
  - the name glitching in, with a divider drawing under it.

  It's laid out on a proportional canvas, so a small window, a maximized one and fullscreen 4K all look the same.
- **Opening a file:** the video starts immediately, and a neon frame traces the window edge over the first ~0.6 s.

Nothing waits on either.

## Build and run

```bash
cargo build --release
```

At runtime Dōga needs `libmpv-2.dll`. Put it next to `doga.exe`, or in `vendor/mpv/` while developing. Get it from the `mpv-dev-x86_64-*.7z` archive of [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake/releases). Optional fonts go in `ui/fonts/`: Chakra Petch, JetBrains Mono and Noto Sans (all OFL). Without them the UI falls back to Segoe UI and Consolas.

```bash
cargo run -- "D:\Anime\Show - 01.mkv"
```

Settings, resume positions and recent files are stored in `%APPDATA%\Doga`. The window opens the way you last left it: maximized, or windowed and fitted to the video. Fullscreen is always manual.

## Series detection

When you open one file, Dōga lists the other videos in its folder that are the same series: same name, with only the episode number or letter changing. `Anime 1`, `Anime 2`, `Anime 3` join; `Car 5` doesn't. Bracket tags like `[SubsPlease]`, `(1080p)` and `[A1B2C3D4]` are ignored, and when a name has several numbers, the one that changes across the folder is the episode. Tests are in `src/series.rs` (`cargo test`).
