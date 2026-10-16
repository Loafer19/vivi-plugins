# Packaging & CI release
<!-- desc: Package a Vivi plugin into a deterministic zip and release it with GitHub Actions, sha256 checks and build provenance attestation. -->

```sh
python3 scripts/package-plugins.py          # validate, build dist/plugins/*.zip, update index.json
python3 scripts/package-plugins.py --check  # CI: fail if index.json is stale
luajit -bl plugins/<id>/<id>.lua > /dev/null # Lua syntax check
```

The packager builds a **deterministic** zip `<id>-<version>.zip` (sorted entries, stored, fixed
timestamps, `store.toml` excluded), so the sha256 it writes into `plugins/index.json` equals the
asset CI builds. Commit the index together with your change.

## What CI does

`.github/workflows/plugins.yml` runs on pushes and pull requests touching `plugins/`, `helpers/`
or `tests/plugins/`:

1. Lua syntax check and tests in `tests/plugins/test-<id>.lua`.
2. `package-plugins.py --check`.
3. For each package whose tag `plugin-<id>-v<version>` does not exist yet: create the release with
   the zip (never marked *latest*) and a **build provenance attestation**.
4. Download every published asset and compare its sha256 with the index.

Verify any asset yourself:

```sh
gh attestation verify night-mode-1.0.0.zip -R Loafer19/vivi-plugins
```

A released version is immutable: change anything, bump `version` and add a changelog entry in
`store.toml`. The marketplace redeploys on the same push; Vivi picks the update up on its daily
check or on *Check now*.
