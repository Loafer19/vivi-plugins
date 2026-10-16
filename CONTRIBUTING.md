# Contributing

* New plugins and fixes are welcome as pull requests. One plugin per directory under
  `plugins/<id>/`; the id is lowercase-with-dashes and matches the directory name.
* Every change to a published plugin needs a version bump in `manifest.toml`, a changelog
  entry in `store.toml` and a regenerated `plugins/index.json`
  (`python3 scripts/package-plugins.py`). CI fails if the index is stale.
* Add or update a test in `tests/plugins/test-<id>.lua` when you change plugin logic.
* Screenshots go to `docs/screenshots/plugins/<name>.png` (plus a `.webp` in `webp/`) and are
  listed in `store.toml`. Prefer real in-player screenshots over settings cards.
* Permissions (`network`, `filesystem`, `subprocess`) must be declared in `manifest.toml`;
  ask only for what the plugin needs.
* Core player changes (plugin API, built-in plugins) belong in
  [Loafer19/vivi](https://github.com/Loafer19/vivi).
