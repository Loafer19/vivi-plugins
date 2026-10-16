//! Remote Control helper of the `remote-control` plugin.
//!
//! `vivi-remote --ipc <mpv socket> --port 8765 --pin 123456 [--lan-only no]`
//!
//! Serves the phone page, refreshes the snapshot from mpv four times a second (pushing it
//! to the page's live-update streams when something changed) and applies the page's
//! commands. Publishes `user-data/remote/url` (address and PIN, for the settings) and
//! `user-data/remote/pair` (the address with the PIN in the fragment, for the QR code).
//! Exits when mpv closes the IPC connection.

use serde_json::Value;
use std::io;
use std::net::TcpListener;
use std::path::Path;
use std::sync::atomic::Ordering;
use std::sync::mpsc::{channel, Receiver};
use std::sync::Arc;
use std::time::{Duration, Instant};
use vivi_helpers::remote::{
    lan_ip, parse_chapters, parse_queue, parse_tracks, serve, vivi_socket, Cmd, Shared, Snapshot,
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
    Ok(Snapshot {
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
    })
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
    if albumart {
        let tmp = std::env::temp_dir().join(format!("vivi-remote-art-{}.jpg", std::process::id()));
        let t = tmp.to_string_lossy().into_owned();
        if m.cmd(&["screenshot-to-file", &t, "video"]).is_ok() {
            if let Ok(b) = std::fs::read(&tmp) {
                let _ = std::fs::remove_file(&tmp);
                return Ok(Some((b, "image/jpeg")));
            }
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

fn apply(m: &mut Mpv, c: Cmd) -> io::Result<()> {
    let a = c.mpv_args();
    let a: Vec<&str> = a.iter().map(String::as_str).collect();
    match m.cmd(&a) {
        Err(e) if e.kind() != io::ErrorKind::Other => Err(e),
        _ => Ok(()),
    }
}

fn run(m: &mut Mpv, sh: &Shared, rx: &Receiver<Cmd>) -> io::Result<()> {
    let mut art_for = None::<String>;
    let mut art_id = 0u64;
    let mut sent = None::<(Snapshot, Instant)>;
    loop {
        while let Ok(c) = rx.try_recv() {
            apply(m, c)?;
        }
        let mut s = snapshot(m)?;
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
            apply(m, c)?;
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
    let pin = a
        .get("pin")
        .map(|p| p.trim().to_string())
        .unwrap_or_default();
    let lan_only = a.get("lan-only").is_none_or(|v| v != "no" && v != "false");
    let mut m = match Mpv::connect(&ipc) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("vivi-remote: mpv IPC {ipc}: {e}");
            std::process::exit(1);
        }
    };
    if pin.is_empty() {
        let _ = m.toast("Remote control: no PIN set");
        return;
    }
    let l = match TcpListener::bind(("0.0.0.0", port)) {
        Ok(l) => l,
        Err(e) => {
            let _ = m.toast(&format!("Remote control: port {port}: {e}"));
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
