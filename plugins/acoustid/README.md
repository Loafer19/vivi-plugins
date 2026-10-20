# AcoustID Tagger

> **Deprecated — built into Vivi since 0.13.0.** Vivi's built-in **Auto-tagger**
> (Settings → Extensions) fingerprints songs with Chromaprint itself (an
> installed `fpcalc` or the bundled fingerprinter), looks them up on AcoustID with Vivi's
> own application key (no key of your own needed) and on MusicBrainz, shows the same
> before/after review, tags whole folders, and since 0.13.0 also identifies untagged songs
> as they start (shown as now playing, the file is not changed until you apply the review)
> and caches each file's answer (*Forget cached results*). Uninstall this plugin in
> Extensions → All / Marketplace; it stays here, unchanged, for older Vivi versions.

Identifies a song by its sound and hands the result to Vivi's Auto-tagger review.
Implements #76 (follow-up to #65). Needs Vivi 0.10 or later and the built-in Auto-tagger
turned on; the automatic mode and the private key file need Vivi 0.13.

1. `Alt+I` (or *Identify*, the player's right-click menu → Plugins, or the command palette)
   fingerprints the playing local file with **fpcalc** (Chromaprint): an installed
   `fpcalc` is used first (`chromaprint` / `libchromaprint-tools` /
   `brew install chromaprint`). Otherwise the official static Chromaprint 1.6.2 build is
   downloaded once from <https://github.com/acoustid/chromaprint/releases> and checked
   against the sha256 pinned in the script: 2.4 MB (Linux x86_64), 1.4 MB (Linux ARM64),
   2.7 MB (macOS universal), 1.8 MB (Windows x64). Stored in
   `~/.local/share/vivi/plugin-data/acoustid/`.
2. The fingerprint is looked up on **AcoustID** (`/v2/lookup`, `meta=recordings+releasegroups`).
3. The Auto-tagger looks the recordings up on **MusicBrainz** (title, artist, album,
   album artist, date, track, genre per release, cover candidates) and shows its
   candidates list and **before/after review**. A **File name** row proposes the new name
   from *New file name* (default `{artist} - {title}`; fields `{artist}`, `{title}`,
   `{album}`, `{albumartist}`, `{year}`, `{date}`, `{track}` (two digits), `{genre}`).
   Characters not allowed in file names become `_`; the extension is kept and an
   existing file is never replaced. Untick the row to keep the name. *Undo* restores the
   tags and renames the file back.

Each answer is cached per file (path, size and modification time) in
`plugin-data/acoustid/cache.json`, so identifying a file again asks AcoustID only once; a
retagged or re-encoded file is looked up again. *Forget cached AcoustID results* clears it.

## Identify untagged songs automatically (Vivi 0.13+)

With *Identify untagged songs when they start* on, a local song that Vivi knows nothing
about (no title / artist tags, not in the library, no other plugin's metadata, as reported
by Vivi's shared now playing) is fingerprinted in the background. When AcoustID is at least
70% sure, the match (artist, title, album, MusicBrainz id) becomes the track's now-playing
metadata: the now-playing card, MPRIS and extensions that read now playing (such as the
Scrobbler) show it, and a toast says
*Identified: … · Alt+I to review and write the tags*. The file itself is not changed. Off by
default; files with tags are never looked up.

## API key

AcoustID only answers registered applications, and Vivi does not ship a key. Register a
free application at <https://acoustid.org/new-application> (name: anything, e.g. "Vivi
for me") and paste its **API key** into *AcoustID application API key*. It is only sent
to api.acoustid.org. curl gets the request from a private file
(`plugin-data/acoustid/req-*.form`, 0600, deleted right after) rather than on its command
line or standard input, because mpv writes both to its debug log.

On Vivi 0.13 and later the key is not given to mpv as a script option (mpv writes those
to its log with their values): the manifest sets `secrets_file = true`, so Vivi writes it to
`plugin-data/acoustid/vivi-secrets.json` (mode 0600, folder 0700) and the plugin reads it
from there. A key you entered before stays in Vivi's settings and moves to that file by
itself; nothing to do. Older Vivi versions keep passing it as before, and a key set in
mpv's own `script-opts/acoustid.conf` (`api-key=…`) is still used when Vivi has none.

## Built-in Auto-tagger

The built-in Auto-tagger can fingerprint on its own (fpcalc or its bundled Rust
Chromaprint) with its own key setting (*Auto-tag the playing file* in the palette and the
right-click menu). This package adds the one-key identify, the per-file answer cache, the
automatic now-playing identification of untagged songs and the managed fpcalc download.

## Version history

- **1.1.0** (2026-10-20): API key in a private file on Vivi 0.13+ (`secrets_file`),
  existing keys move over by themselves; automatic identification of untagged songs into
  now playing; per-file answer cache; Vivi toasts instead of mpv's OSD (OSD only in a plain
  mpv); palette and right-click entries; best match by score; fpcalc gets an absolute path
  (a relative file name starting with `-` was read as an option); the request with the key no
  longer reaches mpv's debug log (it was in the logged `stdin_data` of the curl call); declares the `pkgdir`
  option (no "unknown key" warning); `min_vivi` 0.10.0 (the first release with the
  Auto-tagger hook; there was no 0.9.2 release).
- **1.0.0** (2026-10-15): first release.
