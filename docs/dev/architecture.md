# Architecture overview
<!-- desc: How Vivi distributes plugins: built-in vs downloadable, package format, catalog, install, update and rollback, and why mpv scripts now and WASM later. -->

## Built in vs downloadable

A small core ships inside the Vivi binary because it draws Slint UI a script cannot render:
Music Visualizer, Skip Intro & Credits, Lyrics, Subtitle Search, Auto-tagger, Free Music and
Network Streams. Everything else is a downloadable package, so the app stays small and plugins
update on their own schedule. Discord Rich Presence and Remote Control are packages with a native
helper that talks to mpv over JSON IPC.

## Why mpv scripts

| Option | Status | Notes |
| --- | --- | --- |
| mpv Lua / JS packages | **now** | Zero extra binary size, full player API, key bindings, filters. No sandbox; scripts cannot be unloaded. |
| WASM (Extism) | later | Real sandbox with enforced permissions and a declarative UI host API; `kind = "wasm"` is reserved. |
| Native libraries | rejected | No stable Rust ABI, cannot be sandboxed or kept from crashing the player. |

## Flow

```text
plugins/<id>/ ──package-plugins.py──▶ <id>-<ver>.zip + index.json entry (sha256)
      push ──plugins.yml──▶ release plugin-<id>-v<ver> (+ attestation)
      push ──Dokploy──▶ plugins.viviplayer.app (marketplace + /index.json)
Vivi ──daily / Check now──▶ index.json ──▶ download ▶ verify ▶ stage ▶ switch `current`
```

## Client

* **Install dir**: `$XDG_DATA_HOME/vivi/plugins/<id>/<version>/`, with `<id>/current` naming the
  active version.
* **Install / update** (background thread): download → sha256 must match → unpack into a staging
  folder (no absolute paths, `..` or symlinks) → manifest id, version and `min_vivi` checked →
  rename → atomically switch `current`. A failure leaves the previous version untouched.
* **Updates**: the catalog cache (`$XDG_CACHE_HOME/vivi/plugin-index.json`) is refreshed daily
  and on *Check now*; a toast lists available updates.
* **Rollback** keeps the previous version; **uninstall** removes `<id>/` but keeps settings.
* Catalog URL override for testing: `VIVI_PLUGIN_INDEX`.

Full design notes, including the built-in plugins:
[docs/plugins-architecture.md](https://github.com/Loafer19/vivi/blob/master/docs/plugins-architecture.md)
in the vivi repository.
