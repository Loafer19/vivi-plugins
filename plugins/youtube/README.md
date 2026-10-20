# YouTube & yt-dlp

Search YouTube, list, size and download videos and playlists from YouTube and the other sites yt-dlp supports. Needs Vivi 0.13 or newer (1.2.2 stays the version for Vivi 0.9.1–0.12).

- **Search**: *YouTube* in the sidebar, *Search YouTube* in the command palette or *Search…* in the settings opens Vivi's own dialog. Type words to search YouTube (`ytsearch30:`, *More* loads up to 150 results) or paste a video, playlist or channel link to list it. Rows show thumbnail, channel, views and duration; list or grid view (remembered). *Play* plays a video or opens a playlist row (*‹ Back* returns), *Queue* / *Queue all* append to the Vivi playlist, *Download* / *Download audio* add the row to the downloads. Queued videos get their title, channel, duration and thumbnail in Vivi right away (`vivi-media-meta`), before mpv has opened them.
- **URL**: paste it into the settings, or copy it and press `Alt+U` in the player (mpv `clipboard/text`).
- **Add to playlist**: playlist entries (`yt-dlp --flat-playlist -J`) are appended to the Vivi playlist with their titles; a single video is appended too.
- **Show sizes**: estimated size per quality and for audio only, from the formats' `filesize` / `filesize_approx` (bitrate × duration when both are missing); the same estimate is shown when a download starts. For a playlist URL the first video is measured.
- **Download**: video at the chosen quality (`bv*[height<=H]+ba/b[height<=H]`) or audio only (original, or mp3/m4a/opus via `-x`), into the folder from *Choose…* (default `~/Downloads/Vivi`), named `[NN - ]Title [id].ext`. Audio files get a ` (audio)` suffix. The URL setting downloads what it points to (a playlist URL: the whole playlist); with it empty, the playing video.
- **Download this video** (player right-click menu, palette, settings): only the playing video, even when its URL carries a `list=` (`--no-playlist`).
- **Downloads**: one download runs at a time, the others wait in a queue. Each one is a row in Vivi's Downloads panel (thumbnail, progress, speed, Cancel / Retry, open the file when done); in a plain mpv progress is shown on the OSD every 2 s (percentage, size, ETA, entry n/N) on Linux and macOS, on Windows only start and end. *Cancel* stops the running download and the queued ones. yt-dlp's output goes to `plugin-data/youtube/logs/`.

## Which yt-dlp

*yt-dlp to use*:
- **Auto** (default): a system yt-dlp released within the last 90 days (found in `PATH` and in `~/.local/bin`, `/usr/local/bin`, `/usr/bin`, Homebrew, Snap, WinGet/Scoop/Chocolatey folders), otherwise the managed copy. The Flatpak cannot see host programs, so it always uses the managed copy.
- **System**: always the system one (warns when it is old).
- **Managed copy**: always the plugin's own.

The managed copy is downloaded on first use from <https://github.com/yt-dlp/yt-dlp/releases/latest> (`yt-dlp_linux`, `yt-dlp_linux_aarch64`, `yt-dlp_macos`, `yt-dlp.exe`, …; 18–40 MB), checked against the release's `SHA2-256SUMS` (needs `sha256sum`, `shasum` or `certutil`) and kept in `$XDG_DATA_HOME/vivi/plugin-data/youtube/bin/`. It updates itself with `yt-dlp -U` once a day (*Update the managed yt-dlp daily*) or with *Update*; a system yt-dlp is never touched. *Which yt-dlp is used → Show* tells which one and its version.

The chosen yt-dlp is also given to mpv's ytdl_hook (`ytdl_hook-ytdl_path`), so streaming URLs use it. Vivi itself appends the managed folder to `PATH`, which is how the Flatpak (no yt-dlp of its own) streams YouTube once this plugin has downloaded yt-dlp.

## ffmpeg

Merging separate best video + audio streams and converting audio need ffmpeg. A system `ffmpeg` (PATH, `/usr/bin`, `/usr/local/bin`, Homebrew, MacPorts, Snap) is used when there is one; the Flatpak has none. Otherwise a static build is downloaded **only when a download needs it**: video at 1080p or above (or *Best available*), or audio converted to mp3/m4a/opus. Below 1080p without ffmpeg, single-file formats are used.

| Platform | Source | Verified with |
| --- | --- | --- |
| Linux x86_64 / aarch64, Windows x64, macOS arm64 | Vivi's own minimal build, release [`helper-ffmpeg-v8.0-1`](https://github.com/Loafer19/vivi-plugins/releases/tag/helper-ffmpeg-v8.0-1) (`ffmpeg-<platform>`, `ffprobe-<platform>`, about 6 MB for both; built by `helpers/ffmpeg/build.sh`) | sha256 pinned in `youtube.lua` (`FF_BUILD`), checked before it is installed |

`ffmpeg` and `ffprobe` (about 6 MB) go to `$XDG_DATA_HOME/vivi/plugin-data/youtube/ffmpeg/` and are passed to yt-dlp with `--ffmpeg-location`. The download size is announced before it starts. Only this managed copy is updated: *Update the managed ffmpeg* re-downloads when a plugin update pins a new build, and with auto-update on that is checked every 30 days. Windows arm64 and Intel Macs have no managed build: install ffmpeg there for 1080p+ and audio conversion. *Which yt-dlp and ffmpeg are used → Show* tells which copies are used.

Needs `curl` and `tar` (and `sh` on Linux/macOS).

## Version history

- **1.3.0** (2026-10-20): needs Vivi 0.13.0 (Vivi 0.12 and older keep 1.2.2 and see this version as needing a newer Vivi).
  - New: search YouTube and browse links, playlists and channels in Vivi's own dialog, from the sidebar, the palette or the settings; play, queue or download from it.
  - New: Downloads panel rows with progress, Cancel and Retry, and a download queue; *Download this video* in the player menu; queued videos show their title, channel and thumbnail at once.
  - Fix: a URL setting starting with `-` (or any non-http value) could be read by yt-dlp as an option (for example `--exec`); URLs are now checked and always passed after `--`.
  - Fix: downloading the playing video from a playlist page downloaded the whole playlist.
  - Fix: sizes and the download estimate read the whole playlist; now only its first entry.
  - Fix: progress logs were predictable files in `/tmp`; they now live in the plugin's data folder.
  - Fix: a failed download of the managed yt-dlp no longer leaves a `.part` file behind; playlist entries that are not http(s) links are skipped.
  - Inside Vivi messages are Vivi toasts instead of mpv's OSD.
- **1.2.2** (2026-10-19): own icon in Vivi 0.13+.
- **1.2.1** (2026-10-16): the ffmpeg helper comes from the Loafer19/vivi-plugins releases.
- **1.2.0** (2026-10-15): managed ffmpeg is Vivi's minimal static build (about 6 MB), checksums pinned.
- **1.1.x** (2026-10-15): ffmpeg on demand; pkgdir option declared; shorter size note.
- **1.0.0** (2026-10-15): first release.
