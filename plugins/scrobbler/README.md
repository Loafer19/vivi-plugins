# Scrobbler (Last.fm & ListenBrainz)

Scrobbles the music you play in Vivi to [Last.fm](https://www.last.fm) and/or
[ListenBrainz](https://listenbrainz.org). Either service, or both, can be set up.

* **Now playing** is sent when a track starts (can be turned off).
* A **scrobble** is sent once the track has played for half its length or 4 minutes,
  whichever comes first. Tracks under 30 seconds are skipped; seeking and pausing do not
  count as listening. Playing a track again from the start (repeat one) is a new listen.
* **What is sent**: artist, title, album, album artist, track number and duration, plus
  MusicBrainz recording / release / artist ids when the file has them (e.g. after the
  Auto-tagger). On Vivi 0.13+ these come from Vivi's shared now-playing track
  (`user-data/vivi/now-playing`), which merges the file tags, the library and what a music
  package (YouTube Music) says about its streams; on older Vivi the plugin reads the tags
  and the packages' `vivi-media-meta` itself. Live radio streams are not scrobbled.
* **Love** the playing track with **Alt+L** (or *Love* in the settings): `track.love` on
  Last.fm, and a ♥ on ListenBrainz when the file has a MusicBrainz recording id
  (ListenBrainz feedback needs one).
* **Skipped**: videos (unless *Only music* is off), files whose genre tag matches *Skip
  these genres* (default Podcast, Audiobook, Speech, Spoken Word; Audiobook also skips
  `.m4b` files) and files under the folders in *Skip files in these folders*. *Status*
  tells you why the current file is not scrobbled.
* **Offline queue**: scrobbles that cannot be sent (offline, server error, wrong token or
  secret) are kept in `~/.local/share/vivi/plugin-data/scrobbler/queue.jsonl`
  (ListenBrainz) and `lastfm-queue.jsonl` (Last.fm) and sent in batches (100 / 50) at
  start, after the next successful scrobble, every 10 minutes, or with *Send now*. If the
  server rejects a batch, it is split so only the bad entry is dropped. Last.fm ignores
  scrobbles older than 14 days; *Status* shows the reason it gives.
* Feedback comes as Vivi toasts (on every screen in Vivi 0.13+; on older Vivi only in the
  player view, so close Settings to see the result of *Connect*, *Status* or *Send now*).

## ListenBrainz

1. Sign in at listenbrainz.org and copy your **user token** from
   <https://listenbrainz.org/settings/>.
2. Settings → Extensions → Scrobbler → paste it into *ListenBrainz user token*.
3. *Status* checks the token (`/1/validate-token`) and shows whether it works.

*ListenBrainz API server* can point to another ListenBrainz-compatible server (for example
a self-hosted Maloja at `https://maloja.example/apis/listenbrainz`). It must use https
(plain http only to `localhost`), so the token never crosses the network in clear.

## Last.fm

Last.fm only hands out user sessions to registered API applications, and Vivi does not
ship a shared key, so you use your own (free, takes a minute):

1. Create an API account at <https://www.last.fm/api/account/create> (any name, no
   callback URL needed) and copy the **API key** and **shared secret** into the settings.
2. Press **Connect Last.fm**: your browser opens Last.fm's authorisation page. Allow
   access; Vivi notices within a few seconds and connects (*Finish connecting* checks
   right away). Your password never passes through Vivi.
3. **Disconnect** forgets the session (queued scrobbles are kept). Connecting with a new
   API key needs a new authorisation.

Requests are signed (`api_sig`, MD5 implemented in the script) and sent to
`https://ws.audioscrobbler.com/2.0/` (`auth.getToken`, `auth.getSession`,
`track.updateNowPlaying`, `track.scrobble`, `track.love`).

## Privacy and security

* The Last.fm **session key** is stored in `~/.local/share/vivi/plugin-data/scrobbler/
  lastfm-session.json` (folder 0700, file 0600), not in Vivi's config file, and is never
  shown or logged. A key pasted into *Last.fm session key* (or left there by Scrobbler 1.1)
  is moved into that file and the setting is cleared (Vivi 0.9.1+).
* The ListenBrainz token and the Last.fm secret are Vivi settings (`secret` fields, stored
  in `~/.config/vivi/config.toml`, which Vivi 0.13+ writes 0600). Vivi 0.13+ hands them to
  the plugin in a private file (`plugin-data/scrobbler/vivi-secrets.json`, 0600) instead
  of mpv's script-opts, which mpv writes to its log with the values; older Vivi still
  passes them as script-opts.
* Tokens never appear on a command line or in mpv's log: each request is a short-lived
  private curl config file (`curl -K`) in the plugin's data folder, deleted after the request.
* The queue files (your listening history while offline) are 0600 too.
* Only the two services you set up are contacted, and only with track metadata.

Needs `curl` (preinstalled on Linux, macOS and Windows 10+). Works with Vivi 0.9.0 and newer.
