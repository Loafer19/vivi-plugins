# Quick start
<!-- desc: Write your first Vivi plugin in five minutes: a hello-world mpv Lua package with a manifest, a setting and a toast. -->

Vivi plugins are **mpv Lua (or JavaScript) scripts** with a small `manifest.toml`. They run inside
Vivi's mpv, see every player property, can bind keys and show toasts, and are installed from
**Settings → Extensions → Browse**. No Rust and no rebuild of Vivi are needed.

## 1. Try a bare script

Any mpv script dropped into `~/.config/vivi/scripts/` becomes a plugin with its own card and toggle
in Settings → Extensions (press **Rescan** to pick it up without restarting):

```lua
-- @name Now Playing OSD
-- @description Shows the title on mpv's OSD when a file starts
-- @version 1.0
-- @author You

mp.register_event("file-loaded", function()
    mp.osd_message(mp.get_property("media-title", ""), 3)
end)
```

The `@name`, `@description`, `@version` and `@author` header comments fill in the card
(`// @name …` in JavaScript). This is the fastest way to experiment.

## 2. Turn it into a package

A package is a folder `plugins/<id>/` in [vivi-plugins](https://github.com/Loafer19/vivi-plugins)
with a manifest, the entry script `<id>.lua` and an optional `store.toml` for the marketplace:

```text
plugins/hello/
├── manifest.toml   # what Vivi installs (see Manifest reference)
├── hello.lua       # entry script: file name = mpv script name = id
└── store.toml      # marketplace listing only, not in the zip
```

`manifest.toml`:

```toml
id = "hello"
name = "Hello"
version = "1.0.0"
description = "Greets every file you open."
author = "You"
kind = "mpv-lua"
entry = "hello.lua"
min_vivi = "0.9.0"
lucide = "hand"
permissions = []

[[settings]]
key = "greeting"
title = "Greeting"
type = "text"
default = "Hello"
```

`hello.lua`:

```lua
local o = { greeting = "Hello" }
require("mp.options").read_options(o, "hello")   -- live values of your settings

mp.register_event("file-loaded", function()
    local title = mp.get_property("media-title", "")
    mp.commandv("script-message", "vivi-toast", o.greeting .. ", " .. title)
end)
```

## 3. Test it locally

Copy the folder to `~/.config/vivi/scripts/hello/` (the directory needs `main.lua` or a script
named after it), enable it in Settings → Extensions and open a file. Logs go to Vivi's terminal
(`mp.msg.info`).

## 4. Publish

Run `python3 scripts/package-plugins.py`, commit the folder together with the updated
`plugins/index.json` and open a pull request. See [Packaging & release](packaging/) and
[Submitting to the catalog](catalog/).

Next: [Manifest reference](manifest/) · [Lua API](lua-api/) · [Settings](settings/)
