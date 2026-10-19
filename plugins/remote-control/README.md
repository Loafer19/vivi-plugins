# Remote Control

Control Vivi from your phone, tablet or another computer on the same network. The page
follows Vivi's look (dark, orange accent, Inter, Lucide icons) with big touch targets and
layouts for phone portrait, phone landscape and tablets. Implements #58.

**On the page:** cover art and title/artist/album, current chapter, seek bar with
chapter marks and times, play/pause, previous/next, ±10 s, volume and mute, playback
speed, audio and subtitle track pickers, chapters list (tap to jump), the queue (tap to
play, ✕ to remove), library search (play now, play next or add to the queue), fullscreen
toggle, *Open URL* (play now, play next or add to the queue; YouTube links work when yt-dlp
is installed) and a **sleep timer** (15–90 minutes or the end of the current file; Vivi
pauses and shows a toast, the page counts down), plus **repeat** (off → queue → this file)
and **shuffle** on Vivi versions whose buttons follow them (after 0.12.0; hidden on older
ones, where Vivi's own repeat / shuffle buttons would stay out of date).
Changes show up live (a Server-Sent-Events stream; the page falls back to polling).
*Add to Home Screen* installs it like an app (web app manifest + icon).

## Pairing

1. Turn the plugin on (Settings → Extensions). A random 6-digit PIN is made on first start.
2. *Pair a phone → Show QR code* opens a QR code (Vivi 0.11.0+; older versions show the
   address and PIN as a toast instead). Settings → Controls → Remotes → *Phone remote
   control* in newer Vivi installs, enables or opens this extension. Scan it with the phone camera: the link carries the PIN
   after `#`, which the browser keeps to itself, and the page remembers it.
3. Or open `http://<this computer's LAN IP>:8765` and type the PIN.

*New PIN* replaces the PIN, which signs out every paired phone.

## Settings

- **Port** (default 8765, 1024–65535). The helper restarts when it changes.
- **PIN**: at least 4 characters; left empty, a random 6-digit PIN is made and saved. The
  field is masked; *Show QR code* shows it.
- **Only devices on the local network** (on by default): connections from addresses that
  are not loopback, private (RFC 1918 / unique-local) or link-local are dropped. Turn it
  off only for VPN setups with public addresses; the PIN is still required.

## Security

Every API call needs the PIN in the `X-Vivi-Pin` header (never in a URL; the cover
image and live updates are fetched with it too). Five wrong PINs block an address for a
minute. Commands must be JSON posts (a cross-site form cannot send them), requests with a
domain name in `Host` (other than `localhost` / `*.local`) are refused against DNS
rebinding, and the page is served with a strict Content-Security-Policy. *Open URL*
accepts http(s)/rtmp(s)/rtsp(s)/mms/srt/ytdl links and absolute paths only, not mpv's
special protocols. Plain HTTP on the LAN: anyone who can sniff your Wi-Fi can see the PIN.

The server listens on all interfaces but answers nothing without the PIN, and with *Only
devices on the local network* on (the default) it drops other addresses unanswered. On
Linux and macOS the PIN reaches the helper on stdin, so other users of the computer cannot
read it from the process list; the helper logs only the address. Embedded covers are
extracted into a fresh owner-only folder that is removed right away.

## Library

The Library tab uses Vivi's control socket: turn on **Settings → General → Remote control →
Allow AI agents and scripts** in Vivi and restart it (Linux and macOS). Without it the tab
explains what to enable. The helper finds the socket where Vivi puts it (`$VIVI_SOCKET`,
`$XDG_RUNTIME_DIR/vivi.sock`, else `~/.cache/vivi/vivi.sock`).

## How it works

`remote-control.lua` turns on mpv's JSON IPC (`input-ipc-server`) and starts the native
helper `bin/vivi-remote` (sources: `helpers/src/remote.rs`, `helpers/src/bin/vivi-remote.rs`,
page `helpers/src/remote_page.html`, icons and Inter (SIL OFL, `helpers/src/remote_assets/`)).
The helper serves the page, reads the player state over IPC four times a second, pushes it
to open pages when something changed, and sends the page's commands back. Embedded covers
are extracted with mpv's `screenshot-to-file … video`; `cover/folder/front.jpg|png|webp`
next to the file are used otherwise. The QR dialog is Vivi's `script-message vivi-qr
<title> <text> [caption]`, fullscreen is `script-message vivi-fullscreen toggle`
(both Vivi 0.11.0+). *Play next* is mpv's `loadfile … insert-next-play` (mpv 0.38+; older
libmpv: append, then `playlist-move`). The sleep timer runs in the helper. Repeat sets
mpv's `loop-file` / `loop-playlist`; shuffle writes `user-data/vivi/shuffle` (`yes` / `no`),
which Vivi turns into `playlist-shuffle` / `playlist-unshuffle` so its own button follows.
The page offers both only when Vivi publishes that property.

API (all under `/api/`, header `X-Vivi-Pin`): `GET state`, `GET events` (SSE),
`GET art`, `GET library?q=&kind=audio|video`, `POST cmd` with
`{"cmd": "pause|stop|seek|seek-rel|volume|mute|speed|next|prev|play-index|remove|chapter|audio|sub|fullscreen|open|sleep|repeat|shuffle", "value": n}`
(`open` takes `"target"` and `"append"` or `"next"`; `sleep` takes minutes, 0 = off,
-1 = end of the current file; `repeat` 0 = off, 1 = this file, 2 = the queue; `shuffle`
0 / 1). `state` has `sleep` (seconds left), `sleep_eof`, `repeat` (`off` / `one` / `all`),
`shuffle` and `loop_sync` (Vivi follows repeat / shuffle).

Needs Vivi 0.9.1+ (package helpers, `<id>-pkgdir`, `vivi-setting`); the QR dialog and the
fullscreen button need 0.11.0+.
