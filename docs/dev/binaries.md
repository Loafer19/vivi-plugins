# System binaries & shared ffmpeg
<!-- desc: Use ffmpeg, alass, yt-dlp and native helpers from Vivi plugins: system tools first, pinned verified downloads, shared media ffmpeg. -->

Plugins that need external programs follow one pattern (see `chapter-thumbnails`, `subtitle-sync`,
`cut-export`, `acoustid`):

1. **Prefer a system program** found in `PATH` (never inside the Flatpak, whose `PATH` has no host
   tools).
2. Otherwise **download a pinned build once** with `curl`, check it against a sha256 written in the
   script, mark it executable and keep it under `$XDG_DATA_HOME/vivi/plugin-data/<dir>/`.
3. Make the download opt-out with a toggle setting and show *which tool is used* as an action or
   text setting. Declare `network`, `filesystem` and `subprocess`.

## Shared media ffmpeg

Vivi publishes its own minimal static ffmpeg builds as releases `helper-ffmpeg-v<build>` of
vivi-plugins (built by `helpers/ffmpeg/build.sh`, with `SHA256SUMS` and attestation):

| Asset | For |
| --- | --- |
| `ffmpeg`, `ffprobe` | remux / audio encode only (YouTube plugin) |
| `ffmpeg-media`, `ffprobe-media` | + common video decoders, swscale, JPEG and PCM output |

Plugins needing video decoding share **one** copy in
`plugin-data/shared/ffmpeg-media/` (about 15 MB), so installing a second plugin downloads nothing.
Copy the `get_ffmpeg` block from `plugins/chapter-thumbnails/chapter-thumbnails.lua`, which pins
the tag and per-platform sha256 (`linux-x86_64`, `linux-aarch64`, `macos-aarch64`,
`windows-x86_64`).

## Native helpers

For what Lua cannot do (sockets, servers, native APIs) a package may ship small programs:

```toml
binaries = ["vivi-discord"]
```

* Sources live in `helpers/` (one Rust crate; `helpers/src/lib.rs` is an mpv JSON-IPC client).
* CI builds them for Linux x86_64/aarch64 (static musl), Windows and macOS and uploads
  `<name>-<platform>[.exe]` to the plugin release; their checksums are written into
  `plugins/index.json` by a bot commit.
* Vivi downloads the helper for the user's platform, verifies it and puts it in
  `<pkgdir>/bin/`. The script enables `input-ipc-server`, starts the helper with mpv's
  `subprocess` command (`playback_only = false`) and passes the socket path; the helper exits when
  the IPC connection closes.
