//! Remote Control helper of the `remote-control` plugin.
//!
//! `vivi-remote --ipc <mpv socket> --port 8765 --pin-stdin [--lan-only no]`
//!
//! The PIN comes on the first line of stdin (`--pin-stdin`, so other users cannot read it
//! from the process list) or, where mpv cannot feed stdin (Windows), as `--pin <PIN>`.
//!
//! Serves the phone page, refreshes the snapshot from mpv four times a second (pushing it
//! to the page's live-update streams when something changed) and applies the page's
//! commands. Publishes `user-data/remote/url` (address and PIN, for the settings) and
//! `user-data/remote/pair` (the address with the PIN in the fragment, for the QR code).
//! Exits when mpv closes the IPC connection.

use serde_json::Value;
use std::io::{self, BufRead};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;
use std::time::{Duration, Instant};
use vivi_helpers::remote::{
    lan_ip, parse_chapters, parse_queue, parse_tracks, repeat_mode, serve, vivi_socket, Cmd, Place,
    Shared, Snapshot, SHUFFLE_PROP,
};
use vivi_helpers::{args, Mpv};

fn snapshot(m: &mut Mpv) -> io::Result<Snapshot> {
    let (queue, queue_total) = parse_queue(&m.get("playlist")?.unwrap_or(Value::Null));
    let (audio, subs, has_video) = parse_tracks(&m.get("track-list")?.unwrap_or(Value::Null));
    let chapters = parse_chapters(&m.get("chapter-list")?.unwrap_or(Value::Null));
    let path = m.get_str("path")?;
    let mut title = m.get_str("metadata/by-key/title")?;
    if title.is_empty() && !path.is_empty() {
        title = m.get_str("media-title")?;
    }
    let speed = m.get_f64("speed")?;
    let shuffle = m.get_str(SHUFFLE_PROP)?;
    let repeat = repeat_mode(&m.get_str("loop-file")?, &m.get_str("loop-playlist")?).to_string();
    Ok(Snapshot {
        repeat,
        shuffle: shuffle == "yes",
        loop_sync: !shuffle.is_empty(),
        title,
        artist: m.get_str("metadata/by-key/artist")?,
        album: m.get_str("metadata/by-key/album")?,
        paused: m.get_bool("pause")?,
        position: m.get_f64("time-pos")?,
        duration: m.get_f64("duration")?,
        volume: m.get_f64("volume")?,
        volume_max: m.get_f64("volume-max")?,
        muted: m.get_bool("mute")?,
        speed: if speed > 0.0 { speed } else { 1.0 },
        queue,
        queue_total,
        current: m
            .get("playlist-pos")?
            .and_then(|v| v.as_i64())
            .unwrap_or(-1),
        chapter: m.get("chapter")?.and_then(|v| v.as_i64()).unwrap_or(-1),
        chapters,
        audio,
        subs,
        has_video,
        path,
        library: vivi_socket().is_some(),
        has_art: false,
        art_id: 0,
        sleep: 0.0,
        sleep_eof: false,
    })
}

/// Private folder for one extracted cover (mode 0700, a fresh name each time, removed right
/// after), so another local user cannot plant a symlink where mpv writes the screenshot.
fn private_dir() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .filter(|d| d.is_dir())
        .unwrap_or_else(std::env::temp_dir);
    for _ in 0..8 {
        let d = base.join(format!(
            "vivi-remote-{}-{}",
            std::process::id(),
            vivi_helpers::remote::random_pin()
        ));
        #[cfg_attr(not(unix), allow(unused_mut))]
        let mut b = std::fs::DirBuilder::new();
        #[cfg(unix)]
        std::os::unix::fs::DirBuilderExt::mode(&mut b, 0o700);
        if b.create(&d).is_ok() {
            return Some(d);
        }
    }
    None
}

/// Cover for a local file: the embedded picture (mpv decodes it as an album-art video
/// track, saved with `screenshot-to-file … video`) or cover/folder/front next to it.
fn art(m: &mut Mpv, path: &str) -> io::Result<Option<(Vec<u8>, &'static str)>> {
    if path.is_empty() || path.contains("://") {
        return Ok(None);
    }
    let albumart = m.get_bool("current-tracks/video/albumart")?;
    if !albumart && m.get("current-tracks/video/id")?.is_some() {
        return Ok(None); // a video: a folder.jpg next to it is not its cover
    }
    if let Some(dir) = albumart.then(private_dir).flatten() {
        let tmp = dir.join("cover.jpg");
        let t = tmp.to_string_lossy().into_owned();
        let shot = m.cmd(&["screenshot-to-file", &t, "video"]);
        let b = std::fs::read(&tmp);
        let _ = std::fs::remove_dir_all(&dir);
        if let (Ok(_), Ok(b)) = (shot, b) {
            return Ok(Some((b, "image/jpeg")));
        }
    }
    let Some(dir) = Path::new(path).parent() else {
        return Ok(None);
    };
    for n in [
        "cover", "folder", "front", "Cover", "Folder", "Front", "AlbumArt",
    ] {
        for (ext, mime) in [
            ("jpg", "image/jpeg"),
            ("jpeg", "image/jpeg"),
            ("png", "image/png"),
            ("webp", "image/webp"),
        ] {
            if let Ok(b) = std::fs::read(dir.join(format!("{n}.{ext}"))) {
                return Ok(Some((b, mime)));
            }
        }
    }
    Ok(None)
}

/// Sleep timer state: pause at a time, or when the current file ends.
#[derive(Default)]
struct Sleep {
    at: Option<Instant>,
    /// Path of the file whose end pauses playback.
    eof: Option<String>,
}

/// mpv errors (kind `Other`) are ignored; `Err` only when mpv is gone.
fn ok(r: io::Result<serde_json::Value>) -> io::Result<()> {
    match r {
        Err(e) if e.kind() != io::ErrorKind::Other => Err(e),
        _ => Ok(()),
    }
}

fn apply(m: &mut Mpv, c: Cmd, sleep: &mut Sleep) -> io::Result<()> {
    if let Cmd::Sleep(min) = c {
        *sleep = Sleep::default();
        if min == -1.0 {
            let p = m.get_str("path")?;
            if !p.is_empty() {
                sleep.eof = Some(p);
            }
        } else if min > 0.0 {
            sleep.at = Some(Instant::now() + Duration::from_secs_f64(min * 60.0));
        }
        let msg = match (&sleep.at, &sleep.eof) {
            (Some(_), _) => format!("Remote Control: sleep timer, pausing in {min:.0} min"),
            (_, Some(_)) => "Remote Control: sleep timer, pausing at the end of this file".into(),
            _ => "Remote Control: sleep timer off".into(),
        };
        return m.toast(&msg).or_else(|e| ok(Err(e)));
    }
    let a = c.mpv_args();
    let a: Vec<&str> = a.iter().map(String::as_str).collect();
    if let Cmd::Repeat(_) | Cmd::Shuffle(_) = c {
        // Older Vivi does not follow these (its buttons would be wrong): the page hides them.
        if m.get_str(SHUFFLE_PROP)?.is_empty() {
            return Ok(());
        }
        if let Cmd::Repeat(_) = c {
            ok(m.cmd(&a[..3]))?;
            return ok(m.cmd(&["set", a[3], a[4]]));
        }
    }
    match (m.cmd(&a), &c) {
        // mpv older than 0.38 has no insert-next: append, then move it after the current entry.
        (Err(e), Cmd::Open(t, Place::Next)) if e.kind() == io::ErrorKind::Other => {
            ok(m.cmd(&["loadfile", t, "append-play"]))?;
            let n = m
                .get("playlist-count")?
                .and_then(|v| v.as_i64())
                .unwrap_or(0);
            let pos = m
                .get("playlist-pos")?
                .and_then(|v| v.as_i64())
                .unwrap_or(-1);
            if n > 1 && pos >= 0 && pos + 1 < n - 1 {
                ok(m.cmd(&[
                    "playlist-move",
                    &(n - 1).to_string(),
                    &(pos + 1).to_string(),
                ]))?;
            }
            Ok(())
        }
        (r, _) => ok(r),
    }
}

/// Pause when the sleep timer runs out; updates the snapshot's countdown.
fn sleep_tick(m: &mut Mpv, sleep: &mut Sleep, s: &mut Snapshot) -> io::Result<()> {
    let due = match (&sleep.at, &sleep.eof) {
        (Some(at), _) => *at <= Instant::now(),
        // The file ended (another one started, or the player went idle), or is about to:
        // the poll runs every 250 ms, so stop just before the last half second.
        (_, Some(p)) => {
            *p != s.path
                || (s.duration > 0.0
                    && !s.paused
                    && (s.duration - s.position) / s.speed.max(0.01) < 0.5)
        }
        _ => false,
    };
    if due {
        *sleep = Sleep::default();
        if !s.path.is_empty() && !s.paused {
            ok(m.cmd(&["set", "pause", "yes"]))?;
            s.paused = true;
        }
        let _ = m.toast("Remote Control: sleep timer, playback paused");
    }
    s.sleep = sleep
        .at
        .map(|at| at.saturating_duration_since(Instant::now()).as_secs_f64())
        .unwrap_or(0.0);
    s.sleep_eof = sleep.eof.is_some();
    Ok(())
}

fn run(m: &mut Mpv, sh: &Shared, rx: &Receiver<Cmd>) -> io::Result<()> {
    let mut art_for = None::<String>;
    let mut art_id = 0u64;
    let mut sent = None::<(Snapshot, Instant)>;
    let mut sleep = Sleep::default();
    loop {
        while let Ok(c) = rx.try_recv() {
            apply(m, c, &mut sleep)?;
        }
        let mut s = snapshot(m)?;
        sleep_tick(m, &mut sleep, &mut s)?;
        // The cover is read once the file is loaded (duration known or a stream).
        if art_for.as_deref() != Some(&s.path) && (s.duration > 0.0 || s.path.is_empty()) {
            let a = art(m, &s.path)?;
            *sh.art.lock().unwrap_or_else(|e| e.into_inner()) = a;
            art_for = Some(s.path.clone());
            art_id += 1;
        }
        // Until the new file's cover is read, the old one must not show.
        s.has_art = art_for.as_deref() == Some(&s.path)
            && sh.art.lock().unwrap_or_else(|e| e.into_inner()).is_some();
        s.art_id = art_id;
        let push = match &sent {
            None => true,
            Some((p, at)) => s.differs(p, at.elapsed()) || at.elapsed() > Duration::from_secs(10),
        };
        if push {
            sent = Some((s.clone(), Instant::now()));
        }
        sh.publish(s, push);
        // Commands are applied at once, the snapshot refreshes every 250 ms.
        // A command shows its effect right away.
        if let Ok(c) = rx.recv_timeout(Duration::from_millis(250)) {
            apply(m, c, &mut sleep)?;
        }
    }
}

fn main() {
    let a = args();
    let ipc = a.get("ipc").cloned().unwrap_or_default();
    let port: u16 = a
        .get("port")
        .and_then(|p| p.trim().parse().ok())
        .unwrap_or(8765);
    let pin = if a.contains_key("pin-stdin") {
        let mut l = String::new();
        let _ = io::stdin().lock().read_line(&mut l);
        l.trim().to_string()
    } else {
        a.get("pin")
            .map(|p| p.trim().to_string())
            .unwrap_or_default()
    };
    let lan_only = a.get("lan-only").is_none_or(|v| v != "no" && v != "false");
    let mut m = match Mpv::connect(&ipc) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("vivi-remote: mpv IPC {ipc}: {e}");
            std::process::exit(1);
        }
    };
    if pin.is_empty() {
        let _ = m.toast("Remote Control: no PIN set");
        return;
    }
    // After a restart (port, PIN or network setting changed) the previous helper may not
    // have released the port yet: retry for a few seconds.
    let mut tries = 0;
    let bound = loop {
        match TcpListener::bind(("0.0.0.0", port)) {
            Err(e) if e.kind() == io::ErrorKind::AddrInUse && tries < 15 => {
                tries += 1;
                std::thread::sleep(Duration::from_millis(200));
            }
            r => break r,
        }
    };
    let l = match bound {
        Ok(l) => l,
        Err(e) => {
            let _ = m.toast(&format!("Remote Control: port {port}: {e}"));
            let _ = m.set_status("remote/url", &format!("Port {port} unavailable: {e}"));
            let _ = m.set_status("remote/pair", "");
            std::process::exit(1);
        }
    };
    let sh = Arc::new(Shared::new(&pin, lan_only));
    let (tx, rx) = channel();
    let s2 = sh.clone();
    std::thread::spawn(move || serve(l, s2, tx));
    let host = lan_ip()
        .map(|i| i.to_string())
        .unwrap_or("<this computer>".into());
    let url = format!("http://{host}:{port}");
    eprintln!("vivi-remote: serving {url}");
    let _ = m.set_status("remote/url", &format!("{url} · PIN {pin}"));
    let _ = m.set_status("remote/pair", &format!("{url}/#pin={pin}"));
    let _ = run(&mut m, &sh, &rx);
    sh.stop.store(true, Ordering::Relaxed);
    sh.changed.notify_all();
}
