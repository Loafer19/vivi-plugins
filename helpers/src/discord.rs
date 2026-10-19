//! Discord Rich Presence over Discord's local IPC (`discord-ipc-N` socket or named pipe).
//! Frames are `op: u32 LE, len: u32 LE, JSON`; op 0 = handshake, 1 = frame, 2 = close.

use serde_json::{json, Value};
use std::io;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::pipe::Stream;

/// What mpv plays right now (read by `vivi-discord` over mpv's IPC).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Playing {
    /// `metadata/by-key/title`, else `media-title` (may be a file name or a URL).
    pub title: String,
    pub artist: String,
    pub album: String,
    /// mpv `path` (file path or URL).
    pub path: String,
    /// Music: no video track, or the video track is cover art.
    pub audio: bool,
    /// A still image without sound (nothing to show).
    pub image_only: bool,
    pub paused: bool,
    /// The end of the file was reached (keep-open), nothing is playing any more.
    pub eof: bool,
    pub pos: f64,
    pub dur: f64,
    pub speed: f64,
    /// Opened but not started yet (no `time-pos`): no timer, as the start would move.
    pub loading: bool,
}

/// Plugin settings that shape the presence.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Opts {
    /// Only "Listening to music" / "Watching a video", no titles, art or links.
    pub hide: bool,
    /// Show nothing while a video plays.
    pub music_only: bool,
    /// Large image: an asset key of the Discord application or an https URL.
    pub image: String,
    /// YouTube thumbnail as the large image for YouTube streams.
    pub art: bool,
    /// A link button for streams from well-known public sites.
    pub button: bool,
    /// Discord `status_display_type`: 0 application name, 1 state (artist), 2 details (title).
    pub display: u8,
}

/// What to show (`None` clears the activity).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Presence {
    pub details: String,
    pub state: String,
    pub audio: bool,
    pub paused: bool,
    /// Unix ms when playback (re)started at position 0, while playing.
    pub start: Option<i64>,
    pub end: Option<i64>,
    pub image: String,
    pub image_text: String,
    pub small_image: String,
    pub button: Option<(String, String)>,
    pub display: u8,
}

/// Turns what plays into a presence, `None` when there is nothing to show.
pub fn presence(p: &Playing, o: &Opts, now_ms: i64) -> Option<Presence> {
    if p.path.is_empty() || p.eof || p.image_only || (o.music_only && !p.audio) {
        return None;
    }
    let (details, state) = if o.hide {
        let d = if p.audio {
            "Listening to music"
        } else {
            "Watching a video"
        };
        (d.to_string(), String::new())
    } else {
        let mut t = clean_title(&p.title, &p.path);
        if t.is_empty() {
            t = if p.audio { "Music" } else { "Video" }.into();
        }
        (t, p.artist.trim().to_string())
    };
    let state = match (p.paused, state.is_empty()) {
        (true, true) => "Paused".into(),
        (true, false) => format!("{state} · Paused"),
        _ => state,
    };
    let (start, end) = if p.paused || p.loading {
        (None, None)
    } else {
        // Real time, so 1.5× playback ends earlier and the timer does not drift.
        let speed = if p.speed > 0.01 { p.speed } else { 1.0 };
        let start = now_ms - (p.pos.max(0.0) / speed * 1000.0) as i64;
        (
            Some(start),
            (p.dur > 0.0).then(|| start + (p.dur / speed * 1000.0) as i64),
        )
    };
    let own = o.image.trim().to_string();
    let thumb = (o.art && !o.hide)
        .then(|| youtube_id(&p.path))
        .flatten()
        .map(|id| format!("https://i.ytimg.com/vi/{id}/hqdefault.jpg"));
    let (image, small_image) = match thumb {
        Some(t) => (t, own),
        None => (own, String::new()),
    };
    let image_text = if p.audio && !o.hide && !p.album.trim().is_empty() {
        clip(p.album.trim())
    } else {
        "Vivi".into()
    };
    let button = if o.button && !o.hide {
        public_link(&p.path)
    } else {
        None
    };
    Some(Presence {
        details: clip(&details),
        state: if state.is_empty() {
            state
        } else {
            clip(&state)
        },
        audio: p.audio,
        paused: p.paused,
        start,
        end,
        image,
        image_text,
        small_image,
        button,
        // "Artist" in the member list only with an artist (not "Listening to Paused").
        display: match o.display.min(2) {
            _ if o.hide => 0,
            1 if p.artist.trim().is_empty() => 0,
            d => d,
        },
    })
}

impl Presence {
    /// Same text, picture and pause state, start within 2 s (no seek).
    pub fn same(&self, o: &Self) -> bool {
        self.details == o.details
            && self.state == o.state
            && self.paused == o.paused
            && self.image == o.image
            && self.button == o.button
            && match (self.start, o.start) {
                (Some(x), Some(y)) => (x - y).abs() < 2000,
                (None, None) => true,
                _ => false,
            }
            && self.end.is_some() == o.end.is_some()
    }

    pub fn activity(&self) -> Value {
        let mut a = json!({
            "details": self.details,
            "type": if self.audio { 2 } else { 3 },
        });
        if !self.state.is_empty() {
            a["state"] = json!(self.state);
        }
        if let Some(s) = self.start {
            a["timestamps"] = json!({"start": s});
            if let Some(e) = self.end {
                a["timestamps"]["end"] = json!(e);
            }
        }
        if !self.image.is_empty() {
            a["assets"] = json!({"large_image": self.image, "large_text": self.image_text});
            if !self.small_image.is_empty() {
                a["assets"]["small_image"] = json!(self.small_image);
                a["assets"]["small_text"] = json!("Vivi");
            }
        }
        if let Some((label, url)) = &self.button {
            a["buttons"] = json!([{"label": label, "url": url}]);
        }
        if self.display > 0 {
            a["status_display_type"] = json!(self.display);
        }
        a
    }
}

/// Discord limits these fields to 128 characters (and needs at least 2).
pub fn clip(s: &str) -> String {
    let mut s: String = s.chars().take(128).collect();
    while s.chars().count() < 2 {
        s.push(' ');
    }
    s
}

const MEDIA_EXT: &[&str] = &[
    "mkv", "mp4", "webm", "avi", "mov", "m4v", "wmv", "flv", "ts", "m2ts", "mpg", "mpeg", "mp3",
    "flac", "ogg", "opus", "m4a", "aac", "wav", "wma", "alac", "ape", "mka", "aiff",
];

fn strip_ext(name: &str) -> &str {
    match name.rsplit_once('.') {
        Some((stem, ext))
            if !stem.is_empty() && MEDIA_EXT.contains(&ext.to_ascii_lowercase().as_str()) =>
        {
            stem
        }
        _ => name,
    }
}

/// The title to show: never a raw URL (stream URLs can carry tokens or private hosts), and
/// a bare file name without its media extension.
pub fn clean_title(title: &str, path: &str) -> String {
    let t = title.trim();
    if t.contains("://") {
        return url_label(t);
    }
    // Without tags mpv names a URL after its last part, query and fragment included
    // ("stream.mp3?api_key=…#t"): label the URL instead.
    if path.contains("://") && (t.is_empty() || path.ends_with(t)) {
        return url_label(path);
    }
    let file = path.rsplit(['/', '\\']).next().unwrap_or("");
    if !t.is_empty() && t == file {
        return strip_ext(t).to_string();
    }
    t.to_string()
}

struct Url<'a> {
    scheme: String,
    host: String,
    path: &'a str,
    query: &'a str,
}

fn parse_url(u: &str) -> Option<Url<'_>> {
    let (scheme, rest) = u.trim().split_once("://")?;
    let rest = rest.split('#').next().unwrap_or("");
    let (rest, query) = rest.split_once('?').unwrap_or((rest, ""));
    let (auth, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, ""),
    };
    let hostport = auth.rsplit('@').next().unwrap_or("");
    let host = match hostport.strip_prefix('[') {
        Some(v6) => v6.split(']').next().unwrap_or(""),
        None => hostport.split(':').next().unwrap_or(""),
    };
    Some(Url {
        scheme: scheme.to_ascii_lowercase(),
        host: host.to_ascii_lowercase(),
        path,
        query,
    })
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let hex = |c: u8| (c as char).to_digit(16).map(|d| d as u8);
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        out.push(if b[i] == b'+' { b' ' } else { b[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// A short label for a URL without user info, query or fragment: the file name when the
/// last path part looks like one ("song.mp3" → "song"), else the host ("radio.example.org").
pub fn url_label(u: &str) -> String {
    let Some(url) = parse_url(u) else {
        return String::new();
    };
    let last = url.path.rsplit('/').find(|s| !s.is_empty()).unwrap_or("");
    let name = percent_decode(last);
    if name.contains('.') && strip_ext(&name) != name {
        return strip_ext(&name).to_string();
    }
    url.host
        .strip_prefix("www.")
        .unwrap_or(&url.host)
        .to_string()
}

fn yt_id_ok(id: &str) -> bool {
    id.len() == 11
        && id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}

/// The video id of a YouTube / YouTube Music URL.
pub fn youtube_id(path: &str) -> Option<String> {
    let url = parse_url(path)?;
    if url.scheme != "https" && url.scheme != "http" {
        return None;
    }
    let id = match url.host.as_str() {
        "youtu.be" => url
            .path
            .trim_start_matches('/')
            .split('/')
            .next()?
            .to_string(),
        "youtube.com" | "www.youtube.com" | "m.youtube.com" | "music.youtube.com" => {
            if url.path == "/watch" {
                url.query
                    .split('&')
                    .find_map(|kv| kv.strip_prefix("v="))?
                    .to_string()
            } else {
                let mut it = url.path.trim_start_matches('/').split('/');
                match it.next()? {
                    "shorts" | "live" | "embed" => it.next()?.to_string(),
                    _ => return None,
                }
            }
        }
        _ => return None,
    };
    yt_id_ok(&id).then_some(id)
}

/// A link button for streams from public sites, as a clean URL (no query, user info or
/// fragment; YouTube rebuilt from the video id). `None` for local files, other hosts
/// (a private server, a URL with an access token) and non-https links.
pub fn public_link(path: &str) -> Option<(String, String)> {
    if let Some(id) = youtube_id(path) {
        let music = parse_url(path).is_some_and(|u| u.host == "music.youtube.com");
        return Some(if music {
            (
                "Listen on YouTube Music".into(),
                format!("https://music.youtube.com/watch?v={id}"),
            )
        } else {
            (
                "Watch on YouTube".into(),
                format!("https://www.youtube.com/watch?v={id}"),
            )
        });
    }
    let url = parse_url(path)?;
    if url.scheme != "https" {
        return None;
    }
    let h = url.host.strip_prefix("www.").unwrap_or(&url.host);
    let site = match h {
        "soundcloud.com" => "SoundCloud",
        "vimeo.com" => "Vimeo",
        "twitch.tv" => "Twitch",
        "archive.org" => "Internet Archive",
        _ if h.ends_with(".bandcamp.com") => "Bandcamp",
        _ => return None,
    };
    let p = url.path.trim_end_matches('/');
    if p.is_empty() || p.len() > 400 || !p.bytes().all(|c| c.is_ascii_graphic()) {
        return None;
    }
    Some((
        format!("Open on {site}"),
        format!("https://{}{p}", url.host),
    ))
}

pub fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Candidate IPC paths, most likely first.
pub fn candidates() -> Vec<String> {
    let mut v = Vec::new();
    #[cfg(unix)]
    {
        let mut dirs: Vec<String> = ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"]
            .iter()
            .filter_map(|k| std::env::var(k).ok())
            .filter(|d| !d.is_empty())
            .collect();
        dirs.push("/tmp".into());
        dirs.dedup();
        for d in dirs {
            let d = d.trim_end_matches('/');
            for sub in [
                "",
                "app/com.discordapp.Discord/",
                "snap.discord/",
                ".flatpak/dev.vencord.Vesktop/xdg-run/",
            ] {
                for i in 0..10 {
                    v.push(format!("{d}/{sub}discord-ipc-{i}"));
                }
            }
        }
    }
    #[cfg(windows)]
    for i in 0..10 {
        v.push(format!(r"\\.\pipe\discord-ipc-{i}"));
    }
    v
}

/// Open a Discord IPC endpoint. On Unix reads and writes time out, so a Discord that
/// hangs cannot block the helper (it would stop noticing that mpv quit).
fn open(path: &str) -> io::Result<Box<dyn Stream>> {
    #[cfg(unix)]
    {
        let s = std::os::unix::net::UnixStream::connect(path)?;
        s.set_read_timeout(Some(Duration::from_secs(10)))?;
        s.set_write_timeout(Some(Duration::from_secs(10)))?;
        Ok(Box::new(s))
    }
    #[cfg(not(unix))]
    {
        let _ = Duration::from_secs(0);
        crate::pipe::connect(path)
    }
}

pub struct Client {
    s: Box<dyn Stream>,
    nonce: u64,
}

fn write_frame(s: &mut dyn Stream, op: u32, v: &Value) -> io::Result<()> {
    let b = v.to_string().into_bytes();
    let mut f = Vec::with_capacity(8 + b.len());
    f.extend_from_slice(&op.to_le_bytes());
    f.extend_from_slice(&(b.len() as u32).to_le_bytes());
    f.extend_from_slice(&b);
    s.write_all(&f)?;
    s.flush()
}

fn read_frame(s: &mut dyn Stream) -> io::Result<(u32, Value)> {
    let mut h = [0u8; 8];
    s.read_exact(&mut h)?;
    let op = u32::from_le_bytes([h[0], h[1], h[2], h[3]]);
    let n = u32::from_le_bytes([h[4], h[5], h[6], h[7]]) as usize;
    if n > 1 << 20 {
        return Err(io::Error::other("frame too large"));
    }
    let mut b = vec![0; n];
    s.read_exact(&mut b)?;
    Ok((op, serde_json::from_slice(&b).unwrap_or(Value::Null)))
}

/// Plain words for the errors people see in *Connection status*.
fn friendly(e: io::Error) -> io::Error {
    use io::ErrorKind::*;
    match e.kind() {
        WouldBlock | TimedOut => io::Error::new(TimedOut, "Discord did not answer"),
        ConnectionRefused | ConnectionReset | BrokenPipe | UnexpectedEof => {
            io::Error::new(e.kind(), "Discord closed the connection or is not running")
        }
        _ => e,
    }
}

impl Client {
    /// Connect and handshake with the first reachable Discord.
    pub fn connect(app_id: &str) -> io::Result<Self> {
        let mut last = io::Error::new(io::ErrorKind::NotFound, "Discord is not running");
        for p in candidates() {
            match open(&p).and_then(|s| Self::handshake(s, app_id)) {
                Ok(c) => return Ok(c),
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => last = friendly(e),
            }
        }
        Err(last)
    }
    pub fn handshake(mut s: Box<dyn Stream>, app_id: &str) -> io::Result<Self> {
        write_frame(&mut *s, 0, &json!({"v": 1, "client_id": app_id}))?;
        let (op, v) = read_frame(&mut *s)?;
        if op == 2 || v["evt"] != "READY" {
            return Err(io::Error::other(format!(
                "Discord refused: {}",
                v["message"].as_str().unwrap_or("bad application ID?")
            )));
        }
        Ok(Self { s, nonce: 0 })
    }
    pub fn set(&mut self, p: Option<&Presence>) -> io::Result<()> {
        self.send(p).map_err(friendly)
    }
    fn send(&mut self, p: Option<&Presence>) -> io::Result<()> {
        self.nonce += 1;
        let f = json!({
            "cmd": "SET_ACTIVITY",
            "args": {"pid": std::process::id(), "activity": p.map(Presence::activity)},
            "nonce": format!("vivi-{}-{}", std::process::id(), self.nonce),
        });
        write_frame(&mut *self.s, 1, &f)?;
        let (op, v) = read_frame(&mut *self.s)?;
        if op == 2 {
            return Err(io::Error::other("Discord closed the connection"));
        }
        if v["evt"] == "ERROR" {
            return Err(io::Error::other(
                v["data"]["message"].as_str().unwrap_or("error").to_string(),
            ));
        }
        Ok(())
    }
}

/// Discord drops activity updates beyond 5 per 20 s; this keeps the helper under that.
#[derive(Default)]
pub struct Limiter {
    sent: std::collections::VecDeque<i64>,
}

impl Limiter {
    pub fn allow(&mut self, now_ms: i64) -> bool {
        while self.sent.front().is_some_and(|&t| now_ms - t >= 20_000) {
            self.sent.pop_front();
        }
        self.sent.len() < 5
    }
    pub fn note(&mut self, now_ms: i64) {
        self.sent.push_back(now_ms);
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    fn song() -> Playing {
        Playing {
            title: "Song".into(),
            artist: "Band".into(),
            album: "Album".into(),
            path: "/music/song.flac".into(),
            audio: true,
            pos: 10.0,
            dur: 100.0,
            speed: 1.0,
            ..Default::default()
        }
    }

    #[test]
    fn presence_fields() {
        let p = presence(&song(), &Opts::default(), 1_000_000).unwrap();
        assert_eq!(p.start, Some(990_000));
        assert_eq!(p.end, Some(1_090_000));
        let v = p.activity();
        assert_eq!(v["details"], "Song");
        assert_eq!(v["state"], "Band");
        assert_eq!(v["type"], 2);
        assert!(v.get("assets").is_none());
        assert!(v.get("buttons").is_none());
        assert!(v.get("status_display_type").is_none());
        let mut s = song();
        s.pos = 11.0;
        let q = presence(&s, &Opts::default(), 1_001_500).unwrap();
        assert!(p.same(&q));
        let video = Playing {
            title: "secret.mkv".into(),
            path: "/home/me/secret.mkv".into(),
            paused: true,
            pos: 5.0,
            speed: 1.0,
            ..Default::default()
        };
        let o = Opts {
            hide: true,
            image: "logo".into(),
            art: true,
            button: true,
            display: 2,
            ..Default::default()
        };
        let p = presence(&video, &o, 0).unwrap();
        assert_eq!(p.details, "Watching a video");
        assert_eq!(p.state, "Paused");
        let v = p.activity();
        assert_eq!(v["type"], 3);
        assert_eq!(v["assets"]["large_image"], "logo");
        assert_eq!(v["assets"]["large_text"], "Vivi");
        assert!(v.get("timestamps").is_none());
        assert!(
            v.get("status_display_type").is_none(),
            "hidden names keep the app name"
        );
        assert!(!v.to_string().contains("secret"));
        assert_eq!(clip("x"), "x ");
    }

    #[test]
    fn nothing_to_show() {
        let o = Opts::default();
        let mut s = song();
        s.eof = true;
        assert!(presence(&s, &o, 0).is_none(), "finished file");
        let mut s = song();
        s.path.clear();
        assert!(presence(&s, &o, 0).is_none(), "idle");
        let mut s = song();
        s.image_only = true;
        assert!(presence(&s, &o, 0).is_none(), "picture");
        let mut s = song();
        s.audio = false;
        let mo = Opts {
            music_only: true,
            ..Default::default()
        };
        assert!(presence(&s, &mo, 0).is_none(), "music only hides videos");
        assert!(
            presence(&song(), &mo, 0).is_some(),
            "music only shows music"
        );
    }

    #[test]
    fn speed_and_display() {
        let mut s = song();
        s.speed = 2.0;
        let p = presence(&s, &Opts::default(), 100_000).unwrap();
        assert_eq!(p.start, Some(95_000));
        assert_eq!(p.end, Some(145_000));
        // A second later at 2× the position moved 2 s: still the same presence.
        s.pos = 12.0;
        assert!(p.same(&presence(&s, &Opts::default(), 101_000).unwrap()));
        let o = Opts {
            display: 2,
            ..Default::default()
        };
        assert_eq!(
            presence(&song(), &o, 0).unwrap().activity()["status_display_type"],
            2
        );
        let o = Opts {
            display: 1,
            ..Default::default()
        };
        let mut s = song();
        s.artist.clear();
        s.paused = true;
        assert_eq!(
            presence(&song(), &o, 0).unwrap().activity()["status_display_type"],
            1
        );
        assert!(presence(&s, &o, 0)
            .unwrap()
            .activity()
            .get("status_display_type")
            .is_none());
    }

    #[test]
    fn loading_has_no_timer() {
        let mut s = song();
        s.loading = true;
        let a = presence(&s, &Opts::default(), 1_000).unwrap();
        let b = presence(&s, &Opts::default(), 3_000).unwrap();
        assert_eq!(a.start, None);
        assert!(a.same(&b), "no resend while the start time would move");
    }

    #[test]
    fn titles() {
        assert_eq!(
            clean_title("Movie.2020.1080p.mkv", "/v/Movie.2020.1080p.mkv"),
            "Movie.2020.1080p"
        );
        assert_eq!(clean_title("Real Title", "/v/file.mkv"), "Real Title");
        assert_eq!(
            clean_title(
                "https://user:pw@media.local:8096/Items/1/stream.mp3?api_key=SECRET",
                ""
            ),
            "stream"
        );
        assert_eq!(
            clean_title("", "http://10.0.0.5:8000/live?token=abc"),
            "10.0.0.5"
        );
        assert_eq!(
            clean_title("https://www.radio.example/", ""),
            "radio.example"
        );
        assert_eq!(url_label("https://a.b/My%20Song.ogg"), "My Song");
        assert!(!clean_title("http://h/x?api_key=SECRET", "").contains("SECRET"));
        // mpv's media-title of an untagged URL (seen live): last part with query and fragment.
        assert_eq!(
            clean_title(
                "untagged.mp3?api_key=SECRET123#frag",
                "http://user:pw@127.0.0.1:18765/untagged.mp3?api_key=SECRET123#frag"
            ),
            "untagged"
        );
        assert_eq!(
            clean_title("live?token=abc", "https://radio.example/live?token=abc"),
            "radio.example"
        );
        // A real stream title (icy / tags) stays.
        assert_eq!(
            clean_title("Artist - Song", "https://radio.example/live"),
            "Artist - Song"
        );
    }

    #[test]
    fn youtube_and_links() {
        assert_eq!(
            youtube_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1&t=3").as_deref(),
            Some("dQw4w9WgXcQ")
        );
        assert_eq!(
            youtube_id("https://youtu.be/dQw4w9WgXcQ?si=track").as_deref(),
            Some("dQw4w9WgXcQ")
        );
        assert_eq!(
            youtube_id("https://music.youtube.com/watch?v=dQw4w9WgXcQ").as_deref(),
            Some("dQw4w9WgXcQ")
        );
        assert_eq!(
            youtube_id("https://www.youtube.com/shorts/dQw4w9WgXcQ").as_deref(),
            Some("dQw4w9WgXcQ")
        );
        assert_eq!(youtube_id("https://www.youtube.com/watch?v=bad"), None);
        assert_eq!(youtube_id("https://evil.com/watch?v=dQw4w9WgXcQ"), None);
        assert_eq!(youtube_id("/home/me/dQw4w9WgXcQ.mkv"), None);
        assert_eq!(
            public_link("https://youtu.be/dQw4w9WgXcQ?si=track")
                .unwrap()
                .1,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        );
        assert_eq!(
            public_link("https://music.youtube.com/watch?v=dQw4w9WgXcQ&si=x").unwrap(),
            (
                "Listen on YouTube Music".into(),
                "https://music.youtube.com/watch?v=dQw4w9WgXcQ".into()
            )
        );
        assert_eq!(
            public_link("https://soundcloud.com/artist/track?secret_token=s-abc#t=1").unwrap(),
            (
                "Open on SoundCloud".into(),
                "https://soundcloud.com/artist/track".into()
            )
        );
        assert_eq!(
            public_link("https://band.bandcamp.com/track/x").unwrap().0,
            "Open on Bandcamp"
        );
        assert_eq!(
            public_link("https://jellyfin.home/Audio/1/stream?api_key=k"),
            None
        );
        assert_eq!(public_link("http://soundcloud.com/a/b"), None);
        assert_eq!(public_link("/music/song.flac"), None);
        let s = Playing {
            title: "Clip".into(),
            path: "https://www.youtube.com/watch?v=dQw4w9WgXcQ".into(),
            speed: 1.0,
            ..Default::default()
        };
        let o = Opts {
            image: "vivi".into(),
            art: true,
            button: true,
            ..Default::default()
        };
        let v = presence(&s, &o, 0).unwrap().activity();
        assert_eq!(
            v["assets"]["large_image"],
            "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"
        );
        assert_eq!(v["assets"]["small_image"], "vivi");
        assert_eq!(v["buttons"][0]["label"], "Watch on YouTube");
        let o = Opts { hide: true, ..o };
        let v = presence(&s, &o, 0).unwrap().activity();
        assert_eq!(v["assets"]["large_image"], "vivi");
        assert!(v.get("buttons").is_none());
    }

    #[test]
    fn limiter() {
        let mut l = Limiter::default();
        for i in 0..5 {
            assert!(l.allow(i * 1000));
            l.note(i * 1000);
        }
        assert!(!l.allow(5_000));
        assert!(l.allow(20_000));
    }

    /// Handshake and SET_ACTIVITY against a fake Discord on a socketpair.
    #[test]
    fn talks_ipc() {
        let (a, b) = std::os::unix::net::UnixStream::pair().unwrap();
        let srv = std::thread::spawn(move || {
            let mut b: Box<dyn Stream> = Box::new(b);
            let (op, hello) = read_frame(&mut *b).unwrap();
            assert_eq!((op, hello["client_id"].as_str()), (0, Some("1234")));
            write_frame(
                &mut *b,
                1,
                &json!({"cmd":"DISPATCH","evt":"READY","data":{}}),
            )
            .unwrap();
            let (op, set) = read_frame(&mut *b).unwrap();
            assert_eq!(op, 1);
            write_frame(&mut *b, 1, &json!({"cmd":"SET_ACTIVITY","evt":null})).unwrap();
            let (_, clear) = read_frame(&mut *b).unwrap();
            write_frame(&mut *b, 1, &json!({"cmd":"SET_ACTIVITY"})).unwrap();
            (set, clear)
        });
        let mut c = Client::handshake(Box::new(a), "1234").unwrap();
        let mut s = song();
        s.pos = 0.0;
        s.dur = 60.0;
        let p = presence(&s, &Opts::default(), 5_000).unwrap();
        c.set(Some(&p)).unwrap();
        c.set(None).unwrap();
        let (set, clear) = srv.join().unwrap();
        assert_eq!(set["cmd"], "SET_ACTIVITY");
        assert_eq!(set["args"]["activity"]["details"], "Song");
        assert_eq!(set["args"]["activity"]["timestamps"]["start"], 5000);
        assert!(clear["args"]["activity"].is_null());
    }
}
