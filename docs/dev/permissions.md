# Permissions & sandbox
<!-- desc: How Vivi plugin permissions (network, filesystem, subprocess) are declared, shown and reviewed. -->

```toml
permissions = ["network", "subprocess"]
```

| Permission | Declare it when the plugin… |
| --- | --- |
| `network` | makes HTTP requests (usually `curl` through `subprocess`) or downloads tools. |
| `filesystem` | reads or writes files outside its package and `plugin-data` folders. |
| `subprocess` | runs any program (`ffmpeg`, `curl`, `yt-dlp`, a native helper). |

Users see the permissions on the card before installing (*Allow & install* / *Cancel*), and again
when an update **adds** a permission.

## What is (and is not) enforced

mpv scripts are **not sandboxed**: a Lua script can do anything mpv can. Permissions are therefore
honest declarations that are reviewed when a plugin is accepted into the catalog, not an enforced
boundary. Ask only for what you need; a plugin that does more than it declares is rejected.

What Vivi does enforce for every package:

* the zip's sha256 must match the catalog, downloads are capped (20 MB zip, 50 MB unpacked);
* no absolute paths, `..` or symlinks in the archive;
* manifest `id` / `version` must match the catalog entry and `min_vivi` must be met;
* each release asset carries a build provenance attestation (see [Packaging](../packaging/)).

A future `kind = "wasm"` runtime (Extism) will turn permissions into an enforced sandbox with an
allow-listed host API; the catalog format already reserves it.
