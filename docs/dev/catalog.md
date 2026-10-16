# Submitting to the catalog
<!-- desc: Get your plugin listed on plugins.viviplayer.app and in Vivi's Browse tab: pull request checklist and review. -->

The catalog is `plugins/index.json` in
[Loafer19/vivi-plugins](https://github.com/Loafer19/vivi-plugins), served at
[plugins.viviplayer.app/index.json](https://plugins.viviplayer.app/index.json) (fallback
`loafer19.github.io/vivi-plugins/index.json`). Vivi's Browse tab and this marketplace are both
generated from it.

## Checklist

1. Fork the repository and add `plugins/<id>/` (id = folder name, lowercase-with-dashes).
2. `manifest.toml` with honest `permissions`; `store.toml` with categories, tags, screenshots and a
   changelog entry.
3. Screenshots in `docs/screenshots/plugins/<name>.png` plus `webp/<name>.webp`.
4. A test in `tests/plugins/test-<id>.lua` for non-trivial logic.
5. `python3 scripts/package-plugins.py` and commit the updated `plugins/index.json`.
6. Open a pull request. CI must be green.

Review checks that the plugin does what it says, asks only for the permissions it needs, does
not block the player and downloads only pinned, checksummed files. After merge CI releases it and
it appears here within minutes.

## Entry format

```json
{
  "id": "night-mode", "kind": "package", "version": "1.0.0", "min_vivi": "0.8.0",
  "runtime": "mpv-lua", "permissions": [], "size": 2731,
  "url": "https://github.com/Loafer19/vivi-plugins/releases/download/plugin-night-mode-v1.0.0/night-mode-1.0.0.zip",
  "sha256": "…"
}
```

Built-in plugins are listed with `kind: "builtin"`. Package entries are generated, never edited by
hand. Preview the marketplace locally with `python3 scripts/build-marketplace.py _site &&
python3 -m http.server -d _site`.
