# SponsorBlock

Skips crowd-sourced segments ([SponsorBlock](https://sponsor.ajay.app)) in YouTube videos: sponsors, self-promotion, interaction reminders, intros and more. No account or key. Implements #64 and #73.

Install: Vivi → Settings → Extensions → Browse → **Install**. Requires Vivi 0.9.0+; Vivi 0.13.0+ shows the segments on its own Skip button (below).

## One Skip button (Vivi 0.13.0+)

In Vivi 0.13.0 and later SponsorBlock only finds the segments: it hands them to **Skip Intro & Credits**, the player's one Skip button, and marks them as chapters. The button then says *Skip sponsor*, *Skip self-promotion*, … (or *Unmute sponsor* inside a muted segment), automatic skips leave *Skipped sponsor · Undo* on it for a few seconds, and `Alt+K` / `Alt+Shift+K` are the player's keys. An intro that both the file's chapters and SponsorBlock know about gets one button, not two. Your SponsorBlock settings (categories, *When a segment starts*, *Per category*, *Mute segments*) still decide what happens; Skip Intro & Credits' *Per category or source* setting can override them (`sponsorblock=ask`, `sponsorblock:filler=off`, `sponsor=skip`).

![Vivi 0.13: the SponsorBlock outro segment on the player's Skip button (Big Buck Bunny, © Blender Foundation, CC BY 3.0)](../../docs/screenshots/plugins/skip-intro-sponsorblock.png)

With Skip Intro & Credits switched off, or on older Vivi, SponsorBlock skips, asks and mutes by itself with its own toasts and keys, as described below. (It checks `user-data/vivi/skip-api`, which Vivi sets to 1 while the button is on.)

![Older Vivi: outro skipped with an undo toast; the segment is marked as chapters on the seek bar (Big Buck Bunny, © Blender Foundation, CC BY 3.0)](../../docs/screenshots/plugins/sponsorblock-player.png)

## What it works on

- YouTube videos opened as a stream (Open Network Stream with a `youtube.com/watch?v=`, `youtu.be/`, `/shorts/`, `/live/`, `/embed/` or `music.youtube.com` URL; needs yt-dlp), including the entries the YouTube plugin adds to the playlist.
- Downloaded files named like yt-dlp output, `Title [aqz-KE-bpKQ].mkv`: looked up by the id in brackets (setting *Also for downloaded files…*).

## Keys

Vivi 0.13.0+: `Alt+K` presses the Skip button and `Alt+Shift+K` undoes the last skip or unmutes (Vivi's shortcuts). Older Vivi / Skip Intro & Credits off:

| Key | |
| --- | --- |
| `Alt+K` | skip the current (or announced) segment |
| `Alt+Shift+K` | undo the last skip: back to where it happened, the segment then plays through. No time limit, it always undoes the most recent skip. Inside a muted segment it unmutes it. |

The *Undo* button in the plugin's settings does the same as `Alt+Shift+K`.

## Settings

- **Categories**: space-separated, default `sponsor selfpromo interaction`; also `intro`, `outro`, `preview`, `music_offtopic`, `filler`.
- **When a segment starts**: *Skip automatically* or *Ask*. Vivi 0.13+: the Skip button skips automatically (then offers Undo) or shows *Skip sponsor* and waits. Older Vivi: a toast says what was skipped and offers undo, or a toast offers `Alt+K` to skip.
- **Per category**: overrides the mode for single categories, e.g. `intro=ask outro=skip filler=off`. `skip` and `ask` work for any category (it is fetched even when not in *Categories*); `off` ignores it.
- **Mute segments**: segments the community marked for muting (actionType `mute`, e.g. a short spoken ad over the video) are muted instead of skipped, and the sound comes back right after. If you muted Vivi yourself, it is left alone. On by default.
- **Mark segments as chapters**: adds chapters at segment start/end so they show on the seek bar (`Sponsor`, `End of sponsor`, `Self-promotion (muted)`, …).
- **Show a notice with undo**: the toast after each skip (off: skip silently). Older Vivi only; Vivi 0.13+ shows Undo on the Skip button.
- **API server**: another SponsorBlock-compatible server.

## Privacy

Lookups use the hash-prefix API (`/api/skipSegments/<first 4 hex of sha256(video id)>`), so the server does not learn which video you watch. Hashing uses `sha256sum` / `shasum` when present, else the plain `?videoID=` API. Requests go through `curl` (permissions: `network`, `subprocess`).
