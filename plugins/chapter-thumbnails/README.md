# Chapter Thumbnails

Seek-bar hover previews and chapter pictures for local videos. This plugin is what provides
the seek-bar previews in Vivi (Vivi suggests installing it once, the first time you hover the
seek bar without it). Implements #75 (follow-up to #62). Needs Vivi 0.9.2 or later, which
displays the images.

![Hover preview on the seek bar and chapter pictures in the Chapters tab (Big Buck Bunny, © Blender Foundation, CC BY 3.0)](../../docs/screenshots/plugins/chapter-thumbnails-player.png)

* **Seek bar**: 192×108 frames, evenly spaced; hovering the seek bar shows the nearest one.
  *Auto* makes one every 10 seconds (25 to 200 per file: 63 for a 10-minute video, 200 for
  a film); 25, 50, 100 or 200 can be chosen instead, and short clips get at most one per
  second. Frames are made with fast keyframe seeks, two at a time, coarse to fine, so a few
  spread-out previews appear within a second and the rest fill in.
* **When**: *On hover* (default) starts when the pointer first goes over the seek bar of a
  file. *On open* prepares them in the background instead, after 10 seconds of playback of a
  video longer than 3 minutes, with ffmpeg at the lowest CPU and disk priority (`nice` /
  `ionice` on Linux, `nice` on macOS). Opening another file stops the work; an unfinished
  set is redone next time. Vivi versions that still make their own built-in previews don't
  report the hover: use *On open* or *Generate* there.
* **Chapters**: one 320 px picture per chapter (one second after its start) in the side
  panel's Chapters tab, made when the file opens, also for chapters added later by Scene
  Chapters or SponsorBlock (pictures whose chapter moved are redone). `Alt+H` shows the
  chapter list (time, title, current chapter) on screen.
* **Cache**: `~/.local/share/vivi/plugin-data/chapter-thumbnails/<key>/` (`seek-NN.jpg` +
  `seek.meta`, `chapter-N.jpg` + `chapters.meta`), key = hash of path, size and
  modification time, so an opened-again file shows its previews instantly. The least
  recently used files are removed beyond 200 files or 500 MB (both adjustable; a file
  takes about 0.5 MB). *Clear* deletes the current file's thumbnails, *Clear all* the whole
  cache.
* **ffmpeg**: a system `ffmpeg` is used when present. Otherwise (and in the Flatpak)
  Vivi's **media ffmpeg build** is downloaded once from release `helper-ffmpeg-v8.0-2`
  (Linux x86_64 / ARM64, Windows x64, macOS Apple silicon; about 15 MB for ffmpeg +
  ffprobe, checked against the sha256 pinned in the script) into
  `plugin-data/shared/ffmpeg-media`, shared with Subtitle Auto-Sync. It decodes H.264,
  HEVC, VP8/VP9, MPEG-1/2/4 and MJPEG; for other codecs such as **AV1** the plugin says so
  once instead of failing silently: install ffmpeg on the system (with dav1d) for those.
* Audio files (also with cover art), streams and videos shorter than a second are skipped.

## Settings

| Setting | Default | |
| --- | --- | --- |
| Seek-bar hover thumbnails | on | |
| Chapter thumbnails (Chapters tab) | on | |
| Generate seek-bar thumbnails | On hover | or On open |
| Seek-bar thumbnails per file | Auto | one per 10 s, 25 to 200; or 25 / 50 / 100 / 200 |
| Download ffmpeg when none is installed | on | |
| Files kept in the thumbnail cache | 200 | 50 / 1000 |
| Thumbnail cache size limit (MB) | 500 | 100 / 2000 |

Actions: **Generate** (this file, now), **Show** (chapter list, `Alt+H`), **Clear** (this
file), **Clear all** (the whole cache, with the space freed).
