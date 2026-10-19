//! Remote Control server (`remote-control` plugin): a phone page (now playing with cover,
//! seek, play/pause/previous/next, volume/mute, speed, audio and subtitle tracks,
//! chapters, the queue, library search, fullscreen, open URL) served on the local network.
//!
//! * LAN only by default: connections from addresses that are not loopback, private
//!   (RFC 1918 / unique-local) or link-local are dropped before reading the request.
//!   Requests whose `Host` is a domain name (other than `localhost` / `*.local`) are
//!   refused, which stops DNS-rebinding pages from reaching the API.
//! * Every API call needs the PIN (`X-Vivi-Pin` header); five wrong PINs from one
//!   address block it for a minute. The QR code in Vivi carries it in the URL fragment
//!   (`#pin=…`), which browsers never send to a server.
//! * Live updates: `GET /api/events` is a Server-Sent-Events stream (read with `fetch`,
//!   so the PIN stays in a header); the page falls back to polling `/api/state`.
//!
//! Server threads only read the [`Snapshot`]; commands go back over a channel to the
//! helper's main loop, which owns the mpv IPC connection.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{IpAddr, TcpListener, TcpStream, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

const PAGE: &str = include_str!("remote_page.html");
const ICON_SVG: &[u8] = include_bytes!("remote_assets/icon.svg");
const ICON_192: &[u8] = include_bytes!("remote_assets/icon-192.png");
const ICON_512: &[u8] = include_bytes!("remote_assets/icon-512.png");
const INTER_LATIN: &[u8] = include_bytes!("remote_assets/inter-latin.woff2");
const INTER_CYRILLIC: &[u8] = include_bytes!("remote_assets/inter-cyrillic.woff2");
const MANIFEST: &str = r##"{"name":"Vivi Remote","short_name":"Vivi Remote","description":"Control Vivi from your phone","start_url":"/","scope":"/","display":"standalone","orientation":"any","background_color":"#0E0E0E","theme_color":"#0E0E0E","icons":[{"src":"/icon-192.png","sizes":"192x192","type":"image/png","purpose":"any maskable"},{"src":"/icon-512.png","sizes":"512x512","type":"image/png","purpose":"any maskable"},{"src":"/icon.svg","sizes":"any","type":"image/svg+xml"}]}"##;
const CSP: &str = "default-src 'self'; img-src 'self' blob: data:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; font-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

pub const MAX_QUEUE: usize = 500;
/// Live-update streams open at once (each holds a thread).
pub const MAX_STREAMS: usize = 12;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Track {
    pub id: i64,
    pub title: String,
    pub lang: String,
    pub codec: String,
    pub selected: bool,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Chapter {
    pub title: String,
    pub time: f64,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Snapshot {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub path: String,
    pub paused: bool,
    pub position: f64,
    pub duration: f64,
    pub volume: f64,
    pub volume_max: f64,
    pub muted: bool,
    pub speed: f64,
    pub queue: Vec<String>,
    /// Entries in the playlist (the queue list is capped at [`MAX_QUEUE`]).
    pub queue_total: usize,
    pub current: i64,
    pub has_art: bool,
    /// Changes whenever the cover changes (cache key for the page).
    pub art_id: u64,
    pub chapters: Vec<Chapter>,
    pub chapter: i64,
    pub audio: Vec<Track>,
    pub subs: Vec<Track>,
    pub has_video: bool,
    /// Vivi's library search is reachable (control socket on).
    pub library: bool,
    /// Sleep timer: seconds until playback pauses (0 = off).
    pub sleep: f64,
    /// Sleep timer set to "end of this file".
    pub sleep_eof: bool,
    /// `off`, `one` (loop-file) or `all` (loop-playlist).
    pub repeat: String,
    pub shuffle: bool,
    /// Vivi follows repeat / shuffle changes (it publishes `user-data/vivi/shuffle`).
    pub loop_sync: bool,
}

fn tracks_json(t: &[Track]) -> Value {
    t.iter()
        .map(|t| json!({"id": t.id, "title": t.title, "lang": t.lang, "codec": t.codec, "selected": t.selected}))
        .collect()
}

impl Snapshot {
    pub fn to_json(&self) -> Value {
        json!({
            "title": self.title, "artist": self.artist, "album": self.album, "path": self.path,
            "idle": self.path.is_empty(),
            "paused": self.paused, "position": self.position, "duration": self.duration,
            "volume": self.volume, "volume_max": self.volume_max, "muted": self.muted,
            "speed": self.speed, "queue": self.queue, "queue_total": self.queue_total,
            "current": self.current, "has_art": self.has_art, "art_id": self.art_id,
            "chapters": self.chapters.iter().map(|c| json!({"title": c.title, "time": c.time})).collect::<Vec<_>>(),
            "chapter": self.chapter, "audio": tracks_json(&self.audio), "subs": tracks_json(&self.subs),
            "has_video": self.has_video, "library": self.library,
            "sleep": self.sleep.max(0.0).round(), "sleep_eof": self.sleep_eof,
            "repeat": self.repeat, "shuffle": self.shuffle, "loop_sync": self.loop_sync,
        })
    }

    /// Whether the page must be told: anything but the playing position and the sleep
    /// countdown changed, the position is more than a second away from where it would be
    /// by now (seek, stall), or the sleep timer was set, changed or ran out.
    pub fn differs(&self, sent: &Snapshot, since: Duration) -> bool {
        let a = Snapshot {
            position: 0.0,
            sleep: 0.0,
            ..self.clone()
        };
        let b = Snapshot {
            position: 0.0,
            sleep: 0.0,
            ..sent.clone()
        };
        if a != b || (self.sleep > 0.0) != (sent.sleep > 0.0) {
            return true;
        }
        if self.sleep > 0.0 && (self.sleep - (sent.sleep - since.as_secs_f64())).abs() > 2.0 {
            return true;
        }
        let expected = if sent.paused {
            sent.position
        } else {
            sent.position + since.as_secs_f64() * sent.speed.max(0.01)
        };
        (self.position - expected).abs() > 1.0
    }
}

/// `track-list` → (audio, subtitles, has a real video track).
pub fn parse_tracks(v: &Value) -> (Vec<Track>, Vec<Track>, bool) {
    let (mut audio, mut subs, mut video) = (Vec::new(), Vec::new(), false);
    for t in v.as_array().into_iter().flatten() {
        let tr = Track {
            id: t["id"].as_i64().unwrap_or(0),
            title: t["title"].as_str().unwrap_or("").to_string(),
            lang: t["lang"].as_str().unwrap_or("").to_string(),
            codec: t["codec"].as_str().unwrap_or("").to_string(),
            selected: t["selected"].as_bool().unwrap_or(false),
        };
        match t["type"].as_str() {
            Some("audio") => audio.push(tr),
            Some("sub") => subs.push(tr),
            Some("video") if !t["albumart"].as_bool().unwrap_or(false) => video = true,
            _ => {}
        }
    }
    (audio, subs, video)
}

pub fn parse_chapters(v: &Value) -> Vec<Chapter> {
    v.as_array()
        .into_iter()
        .flatten()
        .enumerate()
        .map(|(i, c)| Chapter {
            title: c["title"]
                .as_str()
                .filter(|t| !t.trim().is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| format!("Chapter {}", i + 1)),
            time: c["time"].as_f64().unwrap_or(0.0),
        })
        .collect()
}

/// `playlist` → display names (title, else the file name) and the total count.
pub fn parse_queue(v: &Value) -> (Vec<String>, usize) {
    let all = v.as_array().map(|a| a.as_slice()).unwrap_or(&[]);
    let names = all
        .iter()
        .take(MAX_QUEUE)
        .map(|e| match e["title"].as_str().filter(|t| !t.is_empty()) {
            Some(t) => t.to_string(),
            None => {
                let f = e["filename"].as_str().unwrap_or("");
                let f = f.trim_end_matches(['/', '\\']);
                if f.contains("://") {
                    f.to_string()
                } else {
                    let name = f.rsplit(['/', '\\']).next().unwrap_or(f);
                    // "01 Song.flac" → "01 Song" (keeps names like "a.b" without a short extension)
                    match name.rsplit_once('.') {
                        Some((stem, ext))
                            if !stem.is_empty()
                                && (1..=4).contains(&ext.len())
                                && ext.chars().all(|c| c.is_ascii_alphanumeric()) =>
                        {
                            stem.to_string()
                        }
                        _ => name.to_string(),
                    }
                }
            }
        })
        .collect();
    (names, all.len())
}

#[derive(Debug, Clone, PartialEq)]
pub enum Cmd {
    Pause,
    Stop,
    Seek(f64),
    SeekRel(f64),
    Volume(f64),
    Mute,
    Speed(f64),
    Next,
    Prev,
    PlayIndex(i64),
    Remove(i64),
    Chapter(i64),
    /// Audio track id, 0 = off.
    Audio(i64),
    /// Subtitle track id, 0 = off.
    Sub(i64),
    Fullscreen,
    /// Load a URL or a library path: play now, add to the queue, or play next.
    Open(String, Place),
    /// Sleep timer in minutes (0 = off, -1 = at the end of the current file). Handled by
    /// the helper, not mpv.
    Sleep(f64),
    /// 0 = off, 1 = repeat the file, 2 = repeat the queue.
    Repeat(i64),
    /// Ask Vivi to shuffle (true) or unshuffle the queue.
    Shuffle(bool),
}

/// Vivi's shuffle state and request (Vivi after 0.12.0, `src/loopsync.rs` in Loafer19/vivi).
pub const SHUFFLE_PROP: &str = "user-data/vivi/shuffle";

/// `loop-file` / `loop-playlist` values → `off` / `one` / `all`.
pub fn repeat_mode(loop_file: &str, loop_playlist: &str) -> &'static str {
    let on = |v: &str| !v.is_empty() && v != "no" && v != "0" && v != "false";
    if on(loop_file) {
        "one"
    } else if on(loop_playlist) {
        "all"
    } else {
        "off"
    }
}

/// Where [`Cmd::Open`] puts the file.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Place {
    Now,
    Queue,
    Next,
}

/// URL or absolute path the page may open: common streaming schemes or a local path
/// (from the library). mpv's special protocols (`av://`, `lavfi://`, `memory://`, …)
/// and option-like strings are refused.
pub fn valid_target(t: &str) -> bool {
    const SCHEMES: [&str; 10] = [
        "http://", "https://", "rtmp://", "rtmps://", "rtsp://", "rtsps://", "mms://", "srt://",
        "ytdl://", "file://",
    ];
    if t.is_empty() || t.len() > 4096 || t.chars().any(char::is_control) || t.starts_with('-') {
        return false;
    }
    let lower = t.to_ascii_lowercase();
    if SCHEMES.iter().any(|s| lower.starts_with(s)) {
        return lower.len() > lower.find("://").unwrap_or(0) + 3;
    }
    if t.contains("://") {
        return false;
    }
    let b = t.as_bytes();
    t.starts_with('/')
        || (b.len() > 2
            && b[0].is_ascii_alphabetic()
            && b[1] == b':'
            && matches!(b[2], b'\\' | b'/'))
}

impl Cmd {
    pub fn parse(v: &Value) -> Option<Self> {
        let n = v["value"].as_f64().unwrap_or(0.0);
        if !n.is_finite() {
            return None;
        }
        let i = n as i64;
        Some(match v["cmd"].as_str()? {
            "pause" => Self::Pause,
            "stop" => Self::Stop,
            "seek" => Self::Seek(n.max(0.0)),
            "seek-rel" => Self::SeekRel(n.clamp(-600.0, 600.0)),
            "volume" => Self::Volume(n.clamp(0.0, 1000.0)),
            "mute" => Self::Mute,
            "speed" => Self::Speed(n.clamp(0.25, 4.0)),
            "next" => Self::Next,
            "prev" => Self::Prev,
            "play-index" if i >= 0 => Self::PlayIndex(i),
            "remove" if i >= 0 => Self::Remove(i),
            "chapter" if i >= 0 => Self::Chapter(i),
            "audio" if i >= 0 => Self::Audio(i),
            "sub" if i >= 0 => Self::Sub(i),
            "fullscreen" => Self::Fullscreen,
            "open" => {
                let t = v["target"].as_str()?.trim();
                if !valid_target(t) {
                    return None;
                }
                let place = if v["next"].as_bool() == Some(true) {
                    Place::Next
                } else if v["append"].as_bool() == Some(true) {
                    Place::Queue
                } else {
                    Place::Now
                };
                Self::Open(t.to_string(), place)
            }
            "sleep" if n == -1.0 || (0.0..=24.0 * 60.0).contains(&n) => Self::Sleep(n),
            "repeat" if (0..=2).contains(&i) && n == i as f64 => Self::Repeat(i),
            "shuffle" => Self::Shuffle(n != 0.0),
            _ => return None,
        })
    }

    /// The mpv command for it (empty for [`Cmd::Sleep`], which the helper handles).
    pub fn mpv_args(&self) -> Vec<String> {
        let s = |a: &[&str]| a.iter().map(|x| x.to_string()).collect::<Vec<_>>();
        match self {
            Self::Pause => s(&["cycle", "pause"]),
            Self::Stop => s(&["stop"]),
            Self::Seek(t) => s(&["seek", &format!("{t:.2}"), "absolute"]),
            Self::SeekRel(t) => s(&["seek", &format!("{t:.2}"), "relative"]),
            Self::Volume(v) => s(&["set", "volume", &format!("{v:.0}")]),
            Self::Mute => s(&["cycle", "mute"]),
            Self::Speed(v) => s(&["set", "speed", &format!("{v:.2}")]),
            Self::Next => s(&["playlist-next"]),
            Self::Prev => s(&["playlist-prev"]),
            Self::PlayIndex(i) => s(&["playlist-play-index", &i.to_string()]),
            Self::Remove(i) => s(&["playlist-remove", &i.to_string()]),
            Self::Chapter(i) => s(&["set", "chapter", &i.to_string()]),
            Self::Audio(0) => s(&["set", "aid", "no"]),
            Self::Audio(i) => s(&["set", "aid", &i.to_string()]),
            Self::Sub(0) => s(&["set", "sid", "no"]),
            Self::Sub(i) => s(&["set", "sid", &i.to_string()]),
            // Vivi (0.11.0+) owns the window: it handles this broadcast.
            Self::Fullscreen => s(&["script-message", "vivi-fullscreen", "toggle"]),
            Self::Open(t, Place::Now) => s(&["loadfile", t, "replace"]),
            Self::Open(t, Place::Queue) => s(&["loadfile", t, "append-play"]),
            // mpv 0.38+; the helper falls back to append + playlist-move on older ones.
            Self::Open(t, Place::Next) => s(&["loadfile", t, "insert-next-play"]),
            Self::Sleep(_) => Vec::new(),
            Self::Repeat(m) => {
                let (file, list) = match m {
                    1 => ("inf", "no"),
                    2 => ("no", "inf"),
                    _ => ("no", "no"),
                };
                // Two properties: the helper sends the second one itself (see apply).
                s(&["set", "loop-file", file, "loop-playlist", list])
            }
            Self::Shuffle(on) => s(&["set", SHUFFLE_PROP, if *on { "yes" } else { "no" }]),
        }
    }
}

/// Loopback, private, unique-local or link-local address.
pub fn is_lan(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v) => v.is_loopback() || v.is_private() || v.is_link_local(),
        IpAddr::V6(v) => {
            if let Some(v4) = v.to_ipv4_mapped() {
                return is_lan(IpAddr::V4(v4));
            }
            let s = v.segments()[0];
            v.is_loopback() || (s & 0xfe00) == 0xfc00 || (s & 0xffc0) == 0xfe80
        }
    }
}

/// `Host` header the page can legitimately be opened with: an IP address, `localhost`
/// or an mDNS `*.local` name (with an optional port). Domain names are refused so a
/// DNS-rebinding website cannot talk to the server.
pub fn host_ok(host: Option<&str>) -> bool {
    let Some(h) = host.map(str::trim).filter(|h| !h.is_empty()) else {
        return true; // HTTP/1.0 clients
    };
    let name = if let Some(r) = h.strip_prefix('[') {
        return r
            .split(']')
            .next()
            .is_some_and(|ip| ip.parse::<IpAddr>().is_ok());
    } else {
        h.rsplit_once(':')
            .filter(|(_, p)| p.chars().all(|c| c.is_ascii_digit()))
            .map_or(h, |(n, _)| n)
    };
    let name = name.trim_end_matches('.').to_ascii_lowercase();
    name.parse::<IpAddr>().is_ok() || name == "localhost" || name.ends_with(".local")
}

/// Length-independent comparison of the PIN.
fn same(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let mut d = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        d |= (*a.get(i).unwrap_or(&0) ^ *b.get(i).unwrap_or(&1)) as usize;
    }
    d == 0
}

/// The address phones should open (the LAN IP of the default route; no packet is sent).
pub fn lan_ip() -> Option<IpAddr> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("192.168.255.255:9").ok()?;
    Some(s.local_addr().ok()?.ip())
}

pub fn random_pin() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut h = std::collections::hash_map::RandomState::new().build_hasher();
    h.write_u128(
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0),
    );
    format!("{:06}", h.finish() % 1_000_000)
}

/// Vivi's control socket (Settings → General → Remote control → Allow AI agents and
/// scripts; keep in sync with `socket_path` in Loafer19/vivi `src/ipc.rs`). Unix only.
#[cfg(unix)]
pub fn vivi_socket() -> Option<std::path::PathBuf> {
    let p = socket_path_from(|k| std::env::var_os(k))?;
    p.exists().then_some(p)
}

/// `$VIVI_SOCKET`, else `$XDG_RUNTIME_DIR/vivi.sock`, else `<cache dir>/vivi/vivi.sock`
/// (`$XDG_CACHE_HOME` when absolute, else `~/.cache`), as Vivi and vivi-mcp do.
pub fn socket_path_from(
    env: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> Option<std::path::PathBuf> {
    use std::path::PathBuf;
    if let Some(p) = env("VIVI_SOCKET").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(p));
    }
    if let Some(d) = env("XDG_RUNTIME_DIR").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(d).join("vivi.sock"));
    }
    let cache = env("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| env("HOME").map(|h| PathBuf::from(h).join(".cache")))?;
    Some(cache.join("vivi").join("vivi.sock"))
}
#[cfg(not(unix))]
pub fn vivi_socket() -> Option<std::path::PathBuf> {
    None
}

/// Library search through Vivi's control socket (`search` command).
#[cfg(unix)]
pub fn library_search(q: &str, kind: &str) -> Result<Value, String> {
    let p = vivi_socket().ok_or("Turn on Settings → General → Remote control → Allow AI agents and scripts in Vivi and restart it")?;
    let mut s = std::os::unix::net::UnixStream::connect(p).map_err(|e| e.to_string())?;
    let _ = s.set_read_timeout(Some(Duration::from_secs(8)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(2)));
    let req = json!({"cmd": "search", "args": {"query": q, "kind": kind, "limit": 80}});
    s.write_all(format!("{req}\n").as_bytes())
        .map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(s.take(4 << 20))
        .read_line(&mut line)
        .map_err(|e| e.to_string())?;
    let v: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
    if v["ok"].as_bool() == Some(true) {
        Ok(v["result"].clone())
    } else {
        Err(v["error"].as_str().unwrap_or("library error").to_string())
    }
}
#[cfg(not(unix))]
pub fn library_search(_: &str, _: &str) -> Result<Value, String> {
    Err("The library is available on Linux and macOS".into())
}

pub struct Shared {
    pub snap: Mutex<Snapshot>,
    /// Bumped by the main loop whenever the page should hear about a change.
    pub version: Mutex<u64>,
    pub changed: Condvar,
    /// Cover of the current file (bytes, MIME type).
    pub art: Mutex<Option<(Vec<u8>, &'static str)>>,
    pub pin: Mutex<String>,
    /// Accept only LAN addresses (setting "Local network only").
    pub lan_only: bool,
    pub stop: AtomicBool,
    pub streams: AtomicUsize,
    pub fails: Mutex<HashMap<IpAddr, (u32, Instant)>>,
}

impl Shared {
    pub fn new(pin: &str, lan_only: bool) -> Self {
        Self {
            snap: Mutex::new(Snapshot::default()),
            version: Mutex::new(0),
            changed: Condvar::new(),
            art: Mutex::new(None),
            pin: Mutex::new(pin.to_string()),
            lan_only,
            stop: AtomicBool::new(false),
            streams: AtomicUsize::new(0),
            fails: Mutex::new(HashMap::new()),
        }
    }
    /// Store a new snapshot; `notify` wakes the live-update streams.
    pub fn publish(&self, s: Snapshot, notify: bool) {
        *lock(&self.snap) = s;
        if notify {
            *lock(&self.version) += 1;
            self.changed.notify_all();
        }
    }
}

struct Request {
    method: String,
    path: String,
    query: HashMap<String, String>,
    headers: HashMap<String, String>,
    body: Vec<u8>,
}

fn decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < b.len() => match s
                .get(i + 1..i + 3)
                .and_then(|h| u8::from_str_radix(h, 16).ok())
            {
                Some(v) => {
                    out.push(v);
                    i += 2;
                }
                None => out.push(b'%'),
            },
            c => out.push(c),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn read_request(s: &mut TcpStream) -> Option<Request> {
    let mut r = BufReader::new(s.take(64 * 1024));
    let mut line = String::new();
    r.read_line(&mut line).ok()?;
    let mut it = line.split_whitespace();
    let method = it.next()?.to_string();
    let target = it.next()?.to_string();
    let mut headers = HashMap::new();
    loop {
        let mut h = String::new();
        if r.read_line(&mut h).ok()? == 0 {
            break;
        }
        let h = h.trim_end();
        if h.is_empty() {
            break;
        }
        if let Some((k, v)) = h.split_once(':') {
            headers.insert(k.trim().to_ascii_lowercase(), v.trim().to_string());
        }
    }
    let n: usize = headers
        .get("content-length")
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
        .min(16384);
    let mut body = vec![0; n];
    r.read_exact(&mut body).ok()?;
    let (path, q) = target.split_once('?').unwrap_or((&target, ""));
    let query = q
        .split('&')
        .filter_map(|kv| kv.split_once('='))
        .map(|(k, v)| (decode(k), decode(v)))
        .collect();
    Some(Request {
        method,
        path: path.to_string(),
        query,
        headers,
        body,
    })
}

fn respond_with(s: &mut TcpStream, status: &str, ctype: &str, cache: &str, body: &[u8]) {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nCache-Control: {cache}\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: {CSP}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = s.write_all(head.as_bytes());
    let _ = s.write_all(body);
}

fn respond(s: &mut TcpStream, status: &str, ctype: &str, body: &[u8]) {
    respond_with(s, status, ctype, "no-store", body)
}

fn json_reply(s: &mut TcpStream, v: &Value) {
    let j = serde_json::to_vec(v).unwrap_or_default();
    respond(s, "200 OK", "application/json", &j);
}

/// Static files that need no PIN (the page and its assets).
fn asset(path: &str) -> Option<(&'static str, &'static [u8], bool)> {
    Some(match path {
        "/" | "/index.html" => ("text/html; charset=utf-8", PAGE.as_bytes(), false),
        "/manifest.webmanifest" => ("application/manifest+json", MANIFEST.as_bytes(), true),
        "/icon.svg" | "/favicon.svg" => ("image/svg+xml", ICON_SVG, true),
        "/icon-192.png" | "/apple-touch-icon.png" | "/favicon.ico" => ("image/png", ICON_192, true),
        "/icon-512.png" => ("image/png", ICON_512, true),
        "/inter-latin.woff2" => ("font/woff2", INTER_LATIN, true),
        "/inter-cyrillic.woff2" => ("font/woff2", INTER_CYRILLIC, true),
        _ => return None,
    })
}

/// Server-Sent Events: the snapshot now and after every change, a comment every 15 s.
fn events(mut s: TcpStream, sh: &Shared) {
    if sh.streams.fetch_add(1, Ordering::SeqCst) >= MAX_STREAMS {
        sh.streams.fetch_sub(1, Ordering::SeqCst);
        return respond(&mut s, "503 Service Unavailable", "text/plain", b"busy");
    }
    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Accel-Buffering: no\r\nConnection: close\r\n\r\n";
    let mut seen = u64::MAX;
    let mut ok = s.write_all(head.as_bytes()).is_ok();
    while ok && !sh.stop.load(Ordering::Relaxed) {
        let v = {
            let g = lock(&sh.version);
            let (g, _) = sh
                .changed
                .wait_timeout_while(g, Duration::from_secs(15), |v| {
                    *v == seen && !sh.stop.load(Ordering::Relaxed)
                })
                .unwrap_or_else(|e| e.into_inner());
            *g
        };
        let msg = if v != seen {
            seen = v;
            format!("data: {}\n\n", lock(&sh.snap).to_json())
        } else {
            ": ping\n\n".into()
        };
        ok = s.write_all(msg.as_bytes()).and_then(|_| s.flush()).is_ok();
    }
    sh.streams.fetch_sub(1, Ordering::SeqCst);
}

fn handle(mut s: TcpStream, sh: &Shared, tx: &Sender<Cmd>) {
    let Ok(peer) = s.peer_addr() else { return };
    if sh.lan_only && !is_lan(peer.ip()) {
        return; // dropped without an answer
    }
    let _ = s.set_read_timeout(Some(Duration::from_secs(5)));
    let _ = s.set_write_timeout(Some(Duration::from_secs(10)));
    let Some(req) = read_request(&mut s) else {
        return;
    };
    if !host_ok(req.headers.get("host").map(String::as_str)) {
        return respond(
            &mut s,
            "421 Misdirected Request",
            "text/plain",
            b"open the page by its IP address",
        );
    }
    if req.method == "GET" {
        if let Some((ctype, body, cache)) = asset(&req.path) {
            let c = if cache {
                "public, max-age=86400"
            } else {
                "no-cache"
            };
            return respond_with(&mut s, "200 OK", ctype, c, body);
        }
    }
    if !req.path.starts_with("/api/") {
        return respond(&mut s, "404 Not Found", "text/plain", b"not found");
    }
    {
        let mut f = lock(&sh.fails);
        if f.len() > 256 {
            f.retain(|_, (_, t)| t.elapsed() < Duration::from_secs(60));
        }
        if let Some((n, t)) = f.get(&peer.ip()) {
            if *n >= 5 && t.elapsed() < Duration::from_secs(60) {
                return respond(&mut s, "429 Too Many Requests", "text/plain", b"wait");
            }
        }
        let given = req.headers.get("x-vivi-pin").cloned().unwrap_or_default();
        let pin = lock(&sh.pin).clone();
        if pin.is_empty() || !same(given.trim(), &pin) {
            let e = f.entry(peer.ip()).or_insert((0, Instant::now()));
            if e.1.elapsed() > Duration::from_secs(60) {
                *e = (0, Instant::now());
            }
            e.0 += 1;
            e.1 = Instant::now();
            return respond(&mut s, "401 Unauthorized", "text/plain", b"pin");
        }
        f.remove(&peer.ip());
    }
    match (req.method.as_str(), req.path.as_str()) {
        ("GET", "/api/state") => json_reply(&mut s, &lock(&sh.snap).to_json()),
        ("GET", "/api/events") => {
            let _ = s.set_read_timeout(None);
            events(s, sh)
        }
        ("GET", "/api/art") => match lock(&sh.art).clone() {
            Some((b, m)) => respond_with(&mut s, "200 OK", m, "private, max-age=3600", &b),
            None => respond(&mut s, "404 Not Found", "text/plain", b"no art"),
        },
        ("GET", "/api/library") => {
            let q = req.query.get("q").map(String::as_str).unwrap_or("");
            let kind = req
                .query
                .get("kind")
                .map(String::as_str)
                .filter(|k| matches!(*k, "audio" | "video"))
                .unwrap_or("");
            match library_search(q, kind) {
                Ok(v) => json_reply(&mut s, &v),
                Err(e) => respond(
                    &mut s,
                    "503 Service Unavailable",
                    "text/plain",
                    e.as_bytes(),
                ),
            }
        }
        ("POST", "/api/cmd") => {
            // JSON body only: a cross-site form post cannot send application/json.
            let json = req
                .headers
                .get("content-type")
                .is_some_and(|c| c.starts_with("application/json"));
            match serde_json::from_slice(&req.body)
                .ok()
                .filter(|_| json)
                .as_ref()
                .and_then(Cmd::parse)
            {
                Some(c) => {
                    let _ = tx.send(c);
                    respond(&mut s, "204 No Content", "text/plain", b"");
                }
                None => respond(&mut s, "400 Bad Request", "text/plain", b"bad command"),
            }
        }
        _ => respond(&mut s, "404 Not Found", "text/plain", b"not found"),
    }
}

pub fn serve(l: TcpListener, sh: Arc<Shared>, tx: Sender<Cmd>) {
    let _ = l.set_nonblocking(true);
    while !sh.stop.load(Ordering::Relaxed) {
        match l.accept() {
            Ok((s, _)) => {
                let _ = s.set_nonblocking(false);
                let (sh, tx) = (sh.clone(), tx.clone());
                std::thread::spawn(move || handle(s, &sh, &tx));
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                std::thread::sleep(Duration::from_millis(100))
            }
            Err(_) => std::thread::sleep(Duration::from_millis(500)),
        }
    }
    sh.changed.notify_all();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc::channel;

    #[test]
    fn lan_only() {
        for a in [
            "127.0.0.1",
            "10.1.2.3",
            "192.168.1.5",
            "172.20.0.1",
            "169.254.1.1",
            "::1",
            "fd00::1",
            "fe80::1",
            "::ffff:192.168.0.2",
        ] {
            assert!(is_lan(a.parse().unwrap()), "{a}");
        }
        for a in ["8.8.8.8", "172.32.0.1", "2001:db8::1", "::ffff:1.1.1.1"] {
            assert!(!is_lan(a.parse().unwrap()), "{a}");
        }
    }

    #[test]
    fn hosts() {
        for h in [
            "192.168.1.5:8765",
            "127.0.0.1",
            "[fe80::1]:8765",
            "localhost:8765",
            "my-pc.local:8765",
        ] {
            assert!(host_ok(Some(h)), "{h}");
        }
        assert!(host_ok(None));
        for h in ["evil.example.com:8765", "rebind.attacker.net", "[nope]:1"] {
            assert!(!host_ok(Some(h)), "{h}");
        }
    }

    #[test]
    fn commands_and_pin() {
        let c = |s: &str| Cmd::parse(&serde_json::from_str(s).unwrap());
        assert_eq!(c(r#"{"cmd":"seek","value":12.5}"#), Some(Cmd::Seek(12.5)));
        assert_eq!(
            c(r#"{"cmd":"volume","value":5000}"#),
            Some(Cmd::Volume(1000.0))
        );
        assert_eq!(c(r#"{"cmd":"speed","value":9}"#), Some(Cmd::Speed(4.0)));
        assert_eq!(c(r#"{"cmd":"pause"}"#), Some(Cmd::Pause));
        assert_eq!(c(r#"{"cmd":"quit"}"#), None);
        assert_eq!(c(r#"{"cmd":"remove","value":-1}"#), None);
        assert_eq!(c(r#"{"cmd":"sub","value":0}"#), Some(Cmd::Sub(0)));
        assert_eq!(Cmd::Sub(0).mpv_args(), ["set", "sid", "no"]);
        assert_eq!(Cmd::Audio(2).mpv_args(), ["set", "aid", "2"]);
        assert_eq!(Cmd::Remove(3).mpv_args(), ["playlist-remove", "3"]);
        assert_eq!(
            Cmd::Fullscreen.mpv_args(),
            ["script-message", "vivi-fullscreen", "toggle"]
        );
        assert_eq!(
            c(r#"{"cmd":"open","target":" https://example.com/a.mp4 ","append":true}"#),
            Some(Cmd::Open("https://example.com/a.mp4".into(), Place::Queue))
        );
        assert_eq!(
            Cmd::Open("/m/a.flac".into(), Place::Now).mpv_args(),
            ["loadfile", "/m/a.flac", "replace"]
        );
        assert_eq!(
            c(r#"{"cmd":"open","target":"/m/b.flac","next":true}"#),
            Some(Cmd::Open("/m/b.flac".into(), Place::Next))
        );
        assert_eq!(
            Cmd::Open("/m/b.flac".into(), Place::Next).mpv_args(),
            ["loadfile", "/m/b.flac", "insert-next-play"]
        );
        assert_eq!(c(r#"{"cmd":"sleep","value":30}"#), Some(Cmd::Sleep(30.0)));
        assert_eq!(c(r#"{"cmd":"sleep","value":-1}"#), Some(Cmd::Sleep(-1.0)));
        assert_eq!(c(r#"{"cmd":"sleep","value":0}"#), Some(Cmd::Sleep(0.0)));
        assert_eq!(c(r#"{"cmd":"sleep","value":-5}"#), None);
        assert_eq!(c(r#"{"cmd":"sleep","value":100000}"#), None);
        assert!(Cmd::Sleep(5.0).mpv_args().is_empty());
        assert_eq!(c(r#"{"cmd":"repeat","value":2}"#), Some(Cmd::Repeat(2)));
        assert_eq!(c(r#"{"cmd":"repeat","value":3}"#), None);
        assert_eq!(c(r#"{"cmd":"repeat","value":1.5}"#), None);
        assert_eq!(
            Cmd::Repeat(1).mpv_args(),
            ["set", "loop-file", "inf", "loop-playlist", "no"]
        );
        assert_eq!(
            c(r#"{"cmd":"shuffle","value":1}"#),
            Some(Cmd::Shuffle(true))
        );
        assert_eq!(
            Cmd::Shuffle(false).mpv_args(),
            ["set", "user-data/vivi/shuffle", "no"]
        );
        assert_eq!(repeat_mode("inf", "no"), "one");
        assert_eq!(repeat_mode("no", "inf"), "all");
        assert_eq!(repeat_mode("no", "no"), "off");
        assert_eq!(repeat_mode("", ""), "off");
        for bad in [
            "",
            "lavfi://sine",
            "av://v4l2:/dev/video0",
            "memory://x",
            "--script=/x.lua",
            "relative/file.mp4",
            "https://",
            "http://a\nb",
        ] {
            assert!(!valid_target(bad), "{bad:?}");
        }
        for good in [
            "https://youtu.be/x",
            "rtsp://cam.local/s",
            "/home/me/Music/a.flac",
            "C:\\Music\\a.mp3",
        ] {
            assert!(valid_target(good), "{good}");
        }
        assert!(same("123456", "123456"));
        assert!(!same("123456", "12345"));
        assert!(!same("", "1"));
        assert_eq!(random_pin().len(), 6);
        assert_eq!(decode("a%20b+c%2"), "a b c%2");
    }

    #[test]
    fn parses_mpv_lists() {
        let (a, s, v) = parse_tracks(&json!([
            {"id": 1, "type": "video", "albumart": true},
            {"id": 1, "type": "audio", "lang": "eng", "title": "Stereo", "selected": true},
            {"id": 2, "type": "audio", "lang": "ukr"},
            {"id": 1, "type": "sub", "lang": "eng", "codec": "subrip"},
        ]));
        assert_eq!(a.len(), 2);
        assert!(a[0].selected && a[0].title == "Stereo");
        assert_eq!(s[0].codec, "subrip");
        assert!(!v, "cover art is not a video");
        assert!(parse_tracks(&json!([{"id": 1, "type": "video"}])).2);
        let c = parse_chapters(&json!([{"time": 0.0, "title": "Intro"}, {"time": 60.5}]));
        assert_eq!(c[1].title, "Chapter 2");
        assert_eq!(c[1].time, 60.5);
        let (q, n) = parse_queue(&json!([
            {"filename": "/m/Album/01 Song.flac"},
            {"filename": "C:\\v\\movie.mkv", "title": "Movie"},
            {"filename": "https://x.org/live.m3u8"},
        ]));
        assert_eq!(q, ["01 Song", "Movie", "https://x.org/live.m3u8"]);
        assert_eq!(n, 3);
    }

    #[test]
    fn push_only_on_real_changes() {
        let a = Snapshot {
            position: 10.0,
            speed: 1.0,
            ..Default::default()
        };
        let t = Duration::from_secs(2);
        // Playing normally: position moved as expected, nothing to send.
        assert!(!Snapshot {
            position: 12.1,
            ..a.clone()
        }
        .differs(&a, t));
        // A seek.
        assert!(Snapshot {
            position: 40.0,
            ..a.clone()
        }
        .differs(&a, t));
        // Paused: the position should not have moved.
        let p = Snapshot {
            paused: true,
            ..a.clone()
        };
        assert!(Snapshot {
            position: 12.0,
            ..p.clone()
        }
        .differs(&p, t));
        assert!(Snapshot {
            volume: 50.0,
            ..a.clone()
        }
        .differs(&a, t));
        // Sleep timer: set, counting down as expected (no push), changed, run out.
        let s = Snapshot {
            position: 12.0,
            sleep: 600.0,
            ..a.clone()
        };
        assert!(s.differs(&a, t));
        assert!(!Snapshot {
            position: 14.0,
            sleep: 598.0,
            ..s.clone()
        }
        .differs(&s, t));
        assert!(Snapshot {
            position: 14.0,
            sleep: 1800.0,
            ..s.clone()
        }
        .differs(&s, t));
        assert!(Snapshot {
            position: 14.0,
            ..a.clone()
        }
        .differs(&s, t));
        assert!(Snapshot {
            sleep_eof: true,
            ..a.clone()
        }
        .differs(&a, t));
    }

    #[test]
    fn control_socket_path() {
        use std::ffi::OsString;
        use std::path::PathBuf;
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |k: &str| {
                pairs
                    .iter()
                    .find(|(n, _)| *n == k)
                    .map(|(_, v)| OsString::from(v))
            }
        };
        let p = |pairs| socket_path_from(env(pairs));
        assert_eq!(
            p(&[("VIVI_SOCKET", "/s/v.sock"), ("XDG_RUNTIME_DIR", "/run/u")]),
            Some(PathBuf::from("/s/v.sock"))
        );
        assert_eq!(
            p(&[("XDG_RUNTIME_DIR", "/run/u"), ("HOME", "/h")]),
            Some(PathBuf::from("/run/u/vivi.sock"))
        );
        // Like Vivi's cache_dir(): <cache>/vivi/vivi.sock (macOS has no XDG_RUNTIME_DIR).
        assert_eq!(
            p(&[("XDG_RUNTIME_DIR", ""), ("HOME", "/h")]),
            Some(PathBuf::from("/h/.cache/vivi/vivi.sock"))
        );
        assert_eq!(
            p(&[("XDG_CACHE_HOME", "/c"), ("HOME", "/h")]),
            Some(PathBuf::from("/c/vivi/vivi.sock"))
        );
        assert_eq!(
            p(&[("XDG_CACHE_HOME", "rel"), ("HOME", "/h")]),
            Some(PathBuf::from("/h/.cache/vivi/vivi.sock"))
        );
        assert_eq!(p(&[]), None);
    }

    fn http(port: u16, req: &str) -> String {
        let mut s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        s.write_all(req.as_bytes()).unwrap();
        let mut out = Vec::new();
        let _ = s.read_to_end(&mut out);
        String::from_utf8_lossy(&out).into_owned()
    }

    /// The real server on localhost: page and assets without PIN, API with PIN, live
    /// updates, Host check, lockout, commands.
    #[test]
    fn server_end_to_end() {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let sh = Arc::new(Shared::new("4242", true));
        sh.publish(
            Snapshot {
                title: "Song".into(),
                ..Default::default()
            },
            true,
        );
        let (tx, rx) = channel();
        let s2 = sh.clone();
        std::thread::spawn(move || serve(l, s2, tx));
        let page = http(port, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n");
        assert!(page.contains("Vivi Remote") && page.contains("Content-Security-Policy"));
        let m = http(port, "GET /manifest.webmanifest HTTP/1.1\r\n\r\n");
        assert!(m.contains("\"display\":\"standalone\""), "{m}");
        assert!(http(port, "GET /icon-192.png HTTP/1.1\r\n\r\n").starts_with("HTTP/1.1 200"));
        let r = http(port, "GET / HTTP/1.1\r\nHost: evil.example.com\r\n\r\n");
        assert!(r.starts_with("HTTP/1.1 421"), "{r}");
        assert!(http(port, "GET /api/state HTTP/1.1\r\n\r\n").starts_with("HTTP/1.1 401"));
        // The PIN is accepted only in the header, not in the URL.
        assert!(http(port, "GET /api/state?pin=4242 HTTP/1.1\r\n\r\n").starts_with("HTTP/1.1 401"));
        let ok = http(port, "GET /api/state HTTP/1.1\r\nX-Vivi-Pin: 4242\r\n\r\n");
        assert!(
            ok.starts_with("HTTP/1.1 200") && ok.contains("\"title\":\"Song\""),
            "{ok}"
        );
        // Live updates: first event now, the next one after a change.
        let mut ev = TcpStream::connect(("127.0.0.1", port)).unwrap();
        ev.write_all(b"GET /api/events HTTP/1.1\r\nX-Vivi-Pin: 4242\r\n\r\n")
            .unwrap();
        ev.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let mut r = BufReader::new(ev);
        let mut got = Vec::new();
        let mut line = String::new();
        while got.len() < 2 && r.read_line(&mut line).unwrap_or(0) > 0 {
            if let Some(d) = line.strip_prefix("data: ") {
                got.push(serde_json::from_str::<Value>(d).unwrap());
                if got.len() == 1 {
                    sh.publish(
                        Snapshot {
                            title: "Next".into(),
                            ..Default::default()
                        },
                        true,
                    );
                }
            }
            line.clear();
        }
        assert_eq!(got[0]["title"], "Song");
        assert_eq!(got[1]["title"], "Next");
        let body = r#"{"cmd":"seek","value":30}"#;
        let r = http(port, &format!("POST /api/cmd HTTP/1.1\r\nX-Vivi-Pin: 4242\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()));
        assert!(r.starts_with("HTTP/1.1 204"), "{r}");
        assert_eq!(
            rx.recv_timeout(Duration::from_secs(2)).unwrap(),
            Cmd::Seek(30.0)
        );
        // Form posts (no JSON content type) are refused.
        let r = http(port, &format!("POST /api/cmd HTTP/1.1\r\nX-Vivi-Pin: 4242\r\nContent-Type: text/plain\r\nContent-Length: {}\r\n\r\n{body}", body.len()));
        assert!(r.starts_with("HTTP/1.1 400"), "{r}");
        for _ in 0..5 {
            http(port, "GET /api/state HTTP/1.1\r\nX-Vivi-Pin: 0000\r\n\r\n");
        }
        let r = http(port, "GET /api/state HTTP/1.1\r\nX-Vivi-Pin: 4242\r\n\r\n");
        assert!(r.starts_with("HTTP/1.1 429"), "{r}");
        sh.stop.store(true, Ordering::Relaxed);
    }
}
