# Settings
<!-- desc: Declare settings in a Vivi plugin manifest and read them live from Lua with mp.options. -->

Settings declared in `manifest.toml` appear under the plugin's card in Settings → Extensions while
it is enabled. Nothing else needs to be registered.

```toml
[[settings]]
key = "languages"
title = "Languages"
info = "Comma-separated ISO codes"   # tooltip (optional)
type = "text"
default = "en"
```

| `type` | Row | Extra fields | Value in Lua |
| --- | --- | --- | --- |
| `toggle` | ON/OFF switch | `default = true` | `yes` / `no` (boolean with `mp.options`) |
| `choice` | Dropdown | `options = [...]`, `default` | the chosen string |
| `text` | Text field | `default`, `placeholder` | string |
| `secret` | Hidden field (API keys) | – | string |
| `action` | Button | `label` (default "Run") | a script message named `key` |

## Reading them

```lua
local o = { languages = "en", enabled_osd = true }
require("mp.options").read_options(o, "subtitle-search", function(changed)
    if changed.languages then reload() end
end)
```

Values are stored in `~/.config/vivi/config.toml` and survive updates and uninstall:

```toml
[plugins.subtitle-search]
enabled = true

[plugins.subtitle-search.settings]
languages = "en,uk"
```

To write a setting from the script (a generated token, a picked folder) use
`vivi-setting` or `vivi-pick-folder`, see the [Lua API](../lua-api/).
