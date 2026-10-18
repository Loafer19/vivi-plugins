# Offline Downloads

A download queue. Paste a URL in the settings and press **Add**, press **Alt+D** with a URL
in the clipboard (or while an online item plays), or send
`script-message-to offline_downloads enqueue <url>` from another script.

| URL | How |
| --- | --- |
| YouTube, SoundCloud, Bandcamp, Jamendo / archive.org pages, … | yt-dlp |
| Direct files (`.mp3`, `.flac`, `.ogg`, `.mp4`, …, Jamendo storage, `archive.org/download/…`) | curl, resumable, progress from Content-Length |
| Radio (Icecast/Shoutcast, `.pls` / `.m3u`) | recorded with curl for the set length |
| HLS (`.m3u8`) | recorded with ffmpeg (needs one already installed) |

One download runs at a time. **Show** (Alt+Shift+D) lists the queue with its state
(pending / active / paused / done / failed) and progress; **Pause / Resume**, **Cancel**,
**Retry**, **Clear** and **Open** act on it. The queue is saved in
`plugin-data/offline-downloads/queue.json`.

## In Vivi's Downloads panel (Vivi 0.13+)

Vivi 0.13 has one **Downloads** panel for every extension (Library → Downloads, also from
the tray). This plugin reports its whole queue there (`vivi-download` messages): title,
progress, size, speed and time left, "Recording · 12:30 of 30 min" for radio, and the
error of a failed download. The row buttons act on that one download: **Pause / Resume**
(not for recordings, which cannot continue), **Cancel** (the row stays as *Cancelled*),
**Retry**; Play now, Open file, Show in folder, Remove and Clear finished are Vivi's.
The panel's *paste a link* field and its **Record stream** (the playing radio / live
stream, or the copied URL, for the set length) and **Add URL from clipboard** buttons
add to this queue (also in the command palette), Alt+D still adds the clipboard URL, and **Show** / Alt+Shift+D open
the panel instead of the on-screen list. Free Music's *Offline Downloads* downloader
setting sends its tracks here too. Older Vivi versions ignore the reports and keep the
on-screen list.

Nothing extra is downloaded: yt-dlp is your system copy or the one the YouTube & yt-dlp
plugin manages (`plugin-data/youtube/bin`); ffmpeg (for merging best video + audio) is a
system one or one another Vivi plugin already installed.
