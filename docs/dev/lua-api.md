# Lua API reference
<!-- desc: The API available to Vivi plugins: the full mpv Lua API plus Vivi script messages, script-opts and key binding rules. -->

A package is a regular mpv script, so the whole
[mpv Lua API](https://mpv.io/manual/master/#lua-scripting) (`mp`, `mp.msg`, `mp.options`,
`mp.utils`, `mp.input`) is available, and the same holds for
[JavaScript](https://mpv.io/manual/master/#javascript). On top of that Vivi adds a few conventions.

## What Vivi passes in

| Script-opt | Value |
| --- | --- |
| `<id>-<key>` | Each declared setting, updated live (toggles as `yes` / `no`). |
| `<id>-pkgdir` | The package's install folder (`pkgdir` is a reserved key). |

```lua
local o = { strength = "Medium", pkgdir = "" }
require("mp.options").read_options(o, "night-mode", function(changed) apply() end)
```

## Script messages Vivi handles

Send them with `mp.commandv("script-message", name, ...)`.

| Message | Effect |
| --- | --- |
| `vivi-toast <text>` | Show a Vivi toast (mpv's OSD is drawn under Vivi's UI). |
| `vivi-setting <id> <key> <value>` | Save one of your declared settings (e.g. a generated PIN) and apply it. |
| `vivi-pick-folder <id> <key>` | Folder dialog; the result is saved as that setting and sent back as `script-message-to <script> folder-picked <path>`. |
| `vivi-qr <title> <text> [caption]` | Dialog with `text` as a QR code (0.10.1+). |
| `vivi-fullscreen [toggle | on | off]` | Toggle Vivi's window fullscreen (0.10.1+). |
| `vivi-preview-frames <dir>` | Load seek-bar preview frames `seek-NN.jpg` from `<dir>` (0.9.2+). |
| `vivi-chapter-thumbs <dir>` | Reload chapter thumbnails `chapter-N.jpg` from `<dir>` (0.9.2+). |
| `vivi-tagger-acoustid <path> <json>` | Open the auto-tagger review with AcoustID results (0.9.2+). |
| `vivi-sub-offset <delta | set:v | reset>` | Change the per-file subtitle offset. |

`action` settings arrive the other way, as a script message named after the setting key:

```lua
mp.register_script_message("clear", clear)   -- action setting with key "clear"
```

## Key bindings

Vivi disables mpv's default key bindings and forwards keys it does not use itself (and every
`Alt` combination) to mpv. Bind keys with **`mp.add_forced_key_binding`**; plain
`add_key_binding` lands in mpv's disabled default section and is ignored.

```lua
mp.add_forced_key_binding("Alt+n", "night-toggle", toggle)
```

## Lifecycle

* Enabled packages are loaded with `load-script` at startup (unless *Load add-ons on startup* is
  off) and right after install.
* mpv cannot unload a script: disable, update, rollback and uninstall take effect after a restart.
* Keep work asynchronous: use `mp.command_native_async` with `subprocess` for programs and HTTP
  (`curl`), never block the player.
* Store data under `$XDG_DATA_HOME/vivi/plugin-data/<id>/`, caches under `$XDG_CACHE_HOME`.
