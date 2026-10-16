# Manifest & store.toml
<!-- desc: Reference for manifest.toml (what Vivi installs) and store.toml (marketplace listing) of Vivi plugins. -->

Every package has two files next to its script. `manifest.toml` goes into the zip and is read by
Vivi; `store.toml` only feeds [plugins.viviplayer.app](https://plugins.viviplayer.app/) and is
**not** packaged, so editing it needs no new version.

## manifest.toml

```toml
id = "night-mode"          # lowercase-with-dashes, equals the folder name
name = "Night Mode"
version = "1.0.0"          # semver; bump it for every change
description = "..."        # one or two sentences, shown on the card
author = "You"
kind = "mpv-lua"           # mpv-lua | mpv-js (wasm reserved)
entry = "night-mode.lua"   # file name = mpv script name = id
min_vivi = "0.8.0"         # older Vivi shows "Needs Vivi x"
icon = "night"             # Settings icon key (optional)
lucide = "moon"            # marketplace icon from lucide.dev
permissions = []           # network | filesystem | subprocess
binaries = []              # native helpers built from helpers/ (optional)
size_note = "+ ffmpeg if needed"   # extra note next to the size in Browse (optional)

[[settings]]
key = "strength"
title = "Strength"
type = "choice"            # toggle | choice | text | secret | action
options = ["Medium", "Light", "Strong"]
default = "Medium"
```

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Stable id, also the config key `[plugins.<id>]` and the script-opts prefix. |
| `name`, `description`, `author` | yes | Shown in Settings and the marketplace. |
| `version` | yes | Semver. A released version is immutable. |
| `kind` | yes | `mpv-lua` or `mpv-js`. |
| `entry` | yes | Entry script inside the package. |
| `min_vivi` | yes | Lowest Vivi version that can run it. |
| `permissions` | no | Declared capabilities, see [Permissions & sandbox](../permissions/). |
| `settings` | no | Setting specs, see [Settings](../settings/). |
| `binaries` | no | Native helper names, see [System binaries & ffmpeg](../binaries/). |
| `icon`, `lucide`, `size_note` | no | Presentation. |

`scripts/package-plugins.py` validates the required fields and fails on anything missing.

## store.toml

```toml
# Marketplace listing (plugins.viviplayer.app). Not part of the package zip.
categories = ["Video", "Tools"]
tags = ["audio", "dynamic-range", "dialogue"]
screenshots = ["night-mode-settings"]   # docs/screenshots/plugins/<name>.png (+ webp/)

[[changelog]]
version = "1.0.0"
date = "2026-10-14"
notes = "First release."
```

Add a `[[changelog]]` entry for every version; the marketplace shows it on the plugin page and in
the [update feed](https://plugins.viviplayer.app/feed.xml). Prefer real in-player screenshots over
settings cards.
