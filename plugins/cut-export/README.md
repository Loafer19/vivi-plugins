# Cut & Export Clip

Cuts a fragment of the playing local file into a new file with ffmpeg.

1. Set **In** and **Out** (`Alt+[` / `Alt+]`, *Set clip start / end here* in the player's
   right-click menu → Plugins, the settings buttons, or type `1:02.5`). Without them the
   A-B loop points (Vivi's built-in A-B loop, `Alt+A` / `Alt+B`) are used, else the whole
   file. Vivi 0.11+ draws In / Out on the seek bar.
2. Pick **Stream copy** (fast, lossless, starts at the keyframe before In) or
   **Re-encode** (frame-accurate, H.264/AAC `.mp4`, or AAC `.m4a` for audio files).
3. `Alt+W`, **Export** or *Export clip* in the command palette. The clip is saved next to
   the original (or in the chosen folder) as `name [1m02.5s-1m10.0s].ext`.

**Export audio** (`Alt+Shift+W`, *Export clip audio (lossless)* in the palette): copies only
the playing audio track of the range, without re-encoding, into a file of its own type
(`.m4a` for AAC / ALAC, `.mp3`, `.opus`, `.ogg`, `.flac`, `.ac3`, `.wav` for PCM, else
`.mka`). Handy for a song from a concert video or a line from a film; the media ffmpeg build
is enough for it.

An existing file is never replaced: a second clip of the same range is saved as
`name [1m02.5s-1m10.0s] (2).ext` (ffmpeg runs with `-n`).

**Progress** (Vivi 0.13+): each export is a row in Vivi's **Downloads** panel (Library →
Downloads) with its progress, *Cancel* and *Retry*, and *Play* / *Show in folder* once it is
saved. Older Vivi versions show a toast every 5 seconds instead. *Stop the running export*
in the settings cancels too.

ffmpeg: your system ffmpeg is used first. Otherwise Vivi's media ffmpeg build
(`helper-ffmpeg-v8.0-2`, about 15 MB, sha256 pinned) is downloaded once into
`plugin-data/shared/ffmpeg-media`, the same copy Chapter Thumbnails and Subtitle Auto-Sync
use. It has no video encoders, so video re-encoding falls back to stream copy (with a
notice) unless a system ffmpeg is installed. Re-encoding uses the first of libx264,
libopenh264, h264_videotoolbox (macOS) and mpeg4 that the ffmpeg has.

## Version history

- **1.1.0** (2026-10-20): *Export audio* (the playing audio track of the clip, lossless);
  exports show in Vivi's Downloads panel with progress, Cancel, Retry, Play and Show in
  folder; an existing file is never overwritten (it was replaced with `-y`, and a failed
  export then deleted it); stream copy leaves out data streams (timecode / telemetry tracks
  made the export fail); video re-encoding falls back to libopenh264 / VideoToolbox / mpeg4
  when there is no libx264; a video played with its video track off is no longer cut as
  audio; Vivi toasts instead of mpv's OSD; palette and right-click entries; declares the
  `pkgdir` option (no "unknown key" warning); `min_vivi` 0.9.1 (all it needs:
  `vivi-setting`, `vivi-pick-folder`; the seek-bar range needs 0.11, the Downloads panel
  0.13, both optional).
- **1.0.2** (2026-10-17): shows the In/Out range on Vivi's seekbar (Vivi 0.11.0+).
- **1.0.1** (2026-10-16): downloads the ffmpeg helper from the Loafer19/vivi-plugins releases.
- **1.0.0** (2026-10-15): first release.
