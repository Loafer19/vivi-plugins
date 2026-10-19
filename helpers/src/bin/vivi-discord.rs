//! Discord Rich Presence helper of the `discord` plugin.
//!
//! `vivi-discord --ipc <mpv socket> --app-id <id> [--hide-names] [--image <key or URL>]
//!  [--show all|music] [--art yes|no] [--button yes|no] [--display app|title|artist]`
//!
//! Polls mpv every second; sends the activity when the title, picture, pause state or
//! position (seek) changes, at most 5 updates per 20 s (Discord's limit). Retries Discord
//! every 15 s. Status goes to `user-data/discord/status`. Exits when mpv closes the IPC
//! connection. Logs only connection states, never titles or paths.

use std::io;
use std::time::{Duration, Instant};
use vivi_helpers::discord::{now_ms, presence, Client, Limiter, Opts, Playing, Presence};
use vivi_helpers::{args, Mpv};

fn playing(m: &mut Mpv) -> io::Result<Playing> {
    let path = m.get_str("path")?;
    if path.is_empty() {
        return Ok(Playing::default());
    }
    let vid = m.get("current-tracks/video/id")?;
    let cover = m.get_bool("current-tracks/video/albumart")?;
    let picture = m.get_bool("current-tracks/video/image")?;
    let has_audio = m.get("current-tracks/audio/id")?.is_some();
    let mut title = m.get_str("metadata/by-key/title")?;
    if title.is_empty() {
        title = m.get_str("media-title")?;
    }
    let mut artist = m.get_str("metadata/by-key/artist")?;
    if artist.is_empty() {
        artist = m.get_str("metadata/by-key/icy-name")?;
    }
    Ok(Playing {
        title,
        artist,
        album: m.get_str("metadata/by-key/album")?,
        path,
        audio: vid.is_none() || cover || picture,
        // A picture file (not a song's cover art) without sound.
        image_only: picture && !cover && !has_audio,
        paused: m.get_bool("pause")?,
        eof: m.get_bool("eof-reached")?,
        pos: m.get_f64("time-pos")?,
        dur: m.get_f64("duration")?,
        speed: m.get_f64("speed")?,
    })
}

fn opts(a: &std::collections::HashMap<String, String>) -> Opts {
    let yes = |k: &str, d: bool| a.get(k).map_or(d, |v| v == "yes");
    Opts {
        hide: yes("hide-names", false),
        music_only: a.get("show").is_some_and(|v| v == "music"),
        image: a.get("image").cloned().unwrap_or_default(),
        art: yes("art", true),
        button: yes("button", false),
        display: match a.get("display").map(String::as_str) {
            Some("artist") => 1,
            Some("title") => 2,
            _ => 0,
        },
    }
}

fn main() {
    let a = args();
    let ipc = a.get("ipc").cloned().unwrap_or_default();
    let id = a
        .get("app-id")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    let o = opts(&a);
    let mut m = match Mpv::connect(&ipc) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("vivi-discord: mpv IPC {ipc}: {e}");
            std::process::exit(1);
        }
    };
    let status = |m: &mut Mpv, s: &str| {
        eprintln!("vivi-discord: {s}");
        m.set_status("discord/status", s)
    };
    if id.is_empty() || !id.chars().all(|c| c.is_ascii_digit()) {
        let _ = m.toast(
            "Discord Rich Presence: enter your Discord application ID in Settings → Extensions → Discord Rich Presence",
        );
        let _ = status(&mut m, "No Discord application ID set");
        return;
    }
    let _ = status(&mut m, "Connecting to Discord…");
    let mut client: Option<Client> = None;
    let mut sent: Option<Option<Presence>> = None;
    let mut next_try = Instant::now();
    let mut limit = Limiter::default();
    // Ends when mpv quits (IPC error).
    while let Ok(p) = playing(&mut m) {
        let now = now_ms();
        let cur = presence(&p, &o, now);
        let same = match (&sent, &cur) {
            (Some(Some(a)), Some(b)) => a.same(b),
            (Some(None), None) => true,
            _ => false,
        };
        if !same {
            if client.is_none() && Instant::now() >= next_try {
                match Client::connect(&id) {
                    Ok(c) => {
                        client = Some(c);
                        if status(&mut m, "Connected to Discord").is_err() {
                            break;
                        }
                    }
                    Err(e) => {
                        next_try = Instant::now() + Duration::from_secs(15);
                        if status(&mut m, &format!("Discord not reachable: {e}")).is_err() {
                            break;
                        }
                    }
                }
            }
            // Over the limit the update waits; the next poll sends the then current state.
            if let (Some(c), true) = (client.as_mut(), limit.allow(now)) {
                match c.set(cur.as_ref()) {
                    Ok(()) => {
                        limit.note(now);
                        sent = Some(cur);
                    }
                    Err(e) => {
                        client = None;
                        sent = None;
                        next_try = Instant::now() + Duration::from_secs(5);
                        if status(&mut m, &format!("Discord connection lost: {e}")).is_err() {
                            break;
                        }
                    }
                }
            }
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    if let Some(mut c) = client {
        let _ = c.set(None);
    }
}
