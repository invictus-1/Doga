# Third-party components

Dōga's own code (`src/`, `ui/*.lua`, `build.rs`, `tools/`, `assets/`) is MIT-licensed (see `LICENSE`). The installer also ships:

| Component | Where | License |
| --- | --- | --- |
| **libmpv** (mpv, with FFmpeg, libplacebo, libass and friends), Windows build from [shinchiro/mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake) | `libmpv-2.dll` | GPL-2.0-or-later. Sources: [mpv](https://github.com/mpv-player/mpv), build scripts: [mpv-winbuild-cmake](https://github.com/shinchiro/mpv-winbuild-cmake) |
| Chakra Petch | `ui/fonts/ChakraPetch-*.ttf` | SIL OFL 1.1 (`ui/licenses/OFL-ChakraPetch.txt`) |
| JetBrains Mono | `ui/fonts/JetBrainsMono-*.ttf` | SIL OFL 1.1 (`ui/licenses/OFL-JetBrainsMono.txt`) |
| Noto Sans | `ui/fonts/NotoSans-SemiBold.ttf` | SIL OFL 1.1 (`ui/licenses/OFL-NotoSans.txt`) |

`libmpv-2.dll` isn't in this repository. Put it in `vendor/mpv/` to build (see README). Because the bundled libmpv is GPL, an installer that includes it is distributed under the GPL's terms. Dōga's MIT code is compatible with that, and its full source is here.
