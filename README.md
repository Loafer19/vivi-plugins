# Vivi plugins

Downloadable plugins and the plugin marketplace for [Vivi](https://github.com/Loafer19/vivi),
the media player. The marketplace is live at **https://plugins.viviplayer.app**; Vivi installs
packages from it in *Settings → Extensions → Browse*.

Built-in plugins (visualizer, skip intro, lyrics, …) are compiled into Vivi and live in the
main repository; they are listed in the catalog with `"kind": "builtin"`.

## Layout

| Path | What |
| --- | --- |
| `plugins/<id>/` | One package: `manifest.toml`, the Lua entry script, `README.md`, and `store.toml` (marketplace listing: categories, tags, screenshots, changelog; not shipped in the zip) |
| `plugins/index.json` | The catalog the app downloads (built-in + package entries, URLs, sha256, sizes) |
| `plugins/examples/` | Minimal example scripts |
| `helpers/` | Native helper programs (`vivi-discord`, `vivi-remote`) and the minimal ffmpeg build |
| `tests/plugins/` | LuaJIT unit tests with an mpv API stub (`bash tests/plugins/run.sh`) |
| `scripts/package-plugins.py` | Builds deterministic zips and regenerates `plugins/index.json` |
| `scripts/build-marketplace.py` | Builds the static marketplace (grid, plugin pages, `feed.xml`, `sitemap.xml`) |
| `docs/marketplace/`, `docs/site/icons/`, `docs/screenshots/` | Marketplace CSS/JS, Lucide icons, screenshots |
| `deploy/plugins/` | Dockerfile + nginx config for plugins.viviplayer.app (Dokploy) |

## Publishing a plugin version

1. Change the plugin, bump `version` in `plugins/<id>/manifest.toml` and add a `[[changelog]]`
   entry to `plugins/<id>/store.toml`.
2. Run `python3 scripts/package-plugins.py` and commit the updated `plugins/index.json`.
3. Push to `master`. The **Plugins** workflow tests, packages and publishes
   `plugin-<id>-v<version>` as a release of this repository (helpers included), records helper
   checksums in the index, and Dokploy redeploys plugins.viviplayer.app.

Existing releases are never replaced: bump the version to publish a change.

## Catalog URLs and releases

* Primary: `https://plugins.viviplayer.app/index.json`; fallback:
  `https://loafer19.github.io/vivi-plugins/index.json` (this repository's GitHub Pages).
* Every download (plugin zips `plugin-<id>-v<version>`, native helpers, `helper-ffmpeg-v<build>`)
  is a release asset of this repository, built by CI and checked against the sha256 in the
  catalog. Each asset has a build provenance attestation:
  `gh attestation verify <file> -R Loafer19/vivi-plugins`.
* Only current versions are published here. Releases from before the move (in Loafer19/vivi)
  were removed; changelogs still list those versions, without a download link.

## Local checks

```sh
bash tests/plugins/run.sh                      # needs luajit
python3 scripts/package-plugins.py --check     # index.json up to date
python3 scripts/build-marketplace.py _market   # build the marketplace locally
(cd helpers && cargo test)
```

Writing a plugin: see https://viviplayer.app/plugin-dev.html and
[plugins-architecture.md](https://github.com/Loafer19/vivi/blob/master/docs/plugins-architecture.md).
See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT (see [LICENSE](LICENSE)). Helper builds bundle third-party code under their own licenses (see `helpers/ffmpeg`).
