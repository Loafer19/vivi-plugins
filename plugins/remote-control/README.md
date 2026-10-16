# Remote Control

Control Vivi from your phone, tablet or another computer on the same network. The page
follows Vivi's look (dark, orange accent, Inter, Lucide icons) with big touch targets and
layouts for phone portrait, phone landscape and tablets. Implements #58.

**On the page:** cover art and title/artist/album, current chapter, seek bar with
chapter marks and times, play/pause, previous/next, ±10 s, volume and mute, playback
speed, audio and subtitle track pickers, chapters list (tap to jump), the queue (tap to
play, ✕ to remove), library search (play or add to the queue), fullscreen toggle and
*Open URL* (play now or add to the queue; YouTube links work when yt-dlp is installed).
Changes show up live (a Server-Sent-Events stream; the page falls back to polling).
*Add to Home Screen* installs it like an app (web app manifest + icon).

## Pairing

1. Turn the plugin on (Settings → Extensions). A random 6-digit PIN is made on first start.
2. *Pair a phone → Show QR code* opens a QR code (Vivi 0.10.1+; older versions show the
   address and PIN as a toast). Scan it with the phone camera: the link carries the PIN
   after `#`, which the browser keeps to itself, and the page remembers it.
3. Or open `http://<this computer's LAN IP>:8765` and type the PIN.

*New PIN* replaces the PIN, which signs out every paired phone.

## Settings

- **Port** (default 8765, 1024–65535). The helper restarts when it changes.
- **PIN**: at least 4 characters; left empty, a random 6-digit PIN is made and saved.
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

## Library

The Library tab uses Vivi's control socket: turn on **Settings → General → Remote
control** in Vivi (Linux and macOS). Without it the tab explains what to enable.

## How it works

`remote-control.lua` turns on mpv's JSON IPC (`input-ipc-server`) and starts the native
helper `bin/vivi-remote` (sources: `helpers/src/remote.rs`, `helpers/src/bin/vivi-remote.rs`,
page `helpers/src/remote_page.html`, icons and Inter (SIL OFL, `helpers/src/remote_assets/`)).
The helper serves the page, reads the player state over IPC four times a second, pushes it
to open pages when something changed, and sends the page's commands back. Embedded covers
are extracted with mpv's `screenshot-to-file … video`; `cover/folder/front.jpg|png|webp`
next to the file are used otherwise. The QR dialog is Vivi's `script-message vivi-qr
<title> <text> [caption]`, fullscreen is `script-message vivi-fullscreen toggle`
(both Vivi 0.10.1+).

API (all under `/api/`, header `X-Vivi-Pin`): `GET state`, `GET events` (SSE),
`GET art`, `GET library?q=&kind=audio|video`, `POST cmd` with
`{"cmd": "pause|stop|seek|seek-rel|volume|mute|speed|next|prev|play-index|remove|chapter|audio|sub|fullscreen|open", "value": n}`
(`open` takes `"target"` and `"append"`).
