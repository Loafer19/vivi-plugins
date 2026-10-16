# Subtitle Auto-Sync

Aligns the selected **external** subtitle to the audio track with
[alass](https://github.com/kaegi/alass) or [ffsubsync](https://github.com/smacke/ffsubsync),
and keeps manual subtitle offsets per file. Implements #56 and #72.

## Automatic sync

- `Alt+Y` or Settings → Extensions → *Sync current subtitle*: runs in the background (a
  toast says when it starts and finishes) and loads `<name>.synced.<ext>`, saved next to
  the original.
- Tools, in this order: an installed `alass` / `alass-cli`, `ffsubsync` (PATH, `~/.cargo/bin`,
  `~/.local/bin`, Homebrew…), or the one picked in *Sync tool*.
- Nothing installed: alass 2.0.0 is downloaded once from its official GitHub release and
  checked against the sha256 pinned in the script: **3 MB** on Linux x86_64, **26 MB** on
  Windows (the Windows build bundles its own ffmpeg). It lives in
  `~/.local/share/vivi/plugin-data/subtitle-sync/alass`. Turn off *Download alass* to
  never download.
- alass decodes the audio with ffmpeg + ffprobe: a system ffmpeg is used when present,
  otherwise Vivi's **media ffmpeg build** (`helper-ffmpeg-v8.0-2`, about 15 MB for both,
  shared with the Chapter Thumbnails plugin in `plugin-data/shared/ffmpeg-media`).
- macOS and Linux ARM have no alass build: `cargo install alass-cli` or
  `pip install ffsubsync`.
- *Which sync tool and ffmpeg are used* shows what was found.

Embedded subtitle tracks are not supported (extract them first).

## Manual offset

| Key | |
| --- | --- |
| `Alt+Z` / `Alt+X` | subtitle 0.1 s earlier / later (step configurable) |
| `Alt+Shift+Z` / `Alt+Shift+X` | 1 s earlier / later |
| `Alt+Backspace` | reset |

The offset is saved per file (path + size) in `plugin-data/subtitle-sync/offsets.json`
and applied as `sub-delay` every time the file is opened again.

**Vivi 0.11 and newer** keep the per-file subtitle offset themselves (Subtitle Search
plugin: `z` / `x`, side panel → Subtitles → Offset, MCP `set_subtitle_offset`). Vivi tells
the plugin with the script-opt `vivi-sub-offsets=1`; the Alt keys then send
`script-message vivi-sub-offset set:<seconds>` to Vivi, which saves and shows the value,
and an offset saved here by an older version is handed over once and removed. The side
panel's *Auto-sync to audio* button (and MCP `sync_subtitles`) runs this plugin's sync.
