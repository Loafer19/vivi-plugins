# UI hooks
<!-- desc: How Vivi plugins show UI: toasts, dialogs, seek-bar previews, chapter thumbnails, and the built-in Rust plugin hooks. -->

Scripts cannot draw Slint widgets, so packages reach Vivi's UI through script messages:

| Need | Use |
| --- | --- |
| Short status / confirmation | `vivi-toast <text>` |
| Pairing link or code | `vivi-qr <title> <text> [caption]` |
| Folder chooser | `vivi-pick-folder <id> <key>` |
| Seek-bar hover previews | write `seek-NN.jpg` and send `vivi-preview-frames <dir>` |
| Chapter pictures in the Chapters tab | write `chapter-N.jpg` and send `vivi-chapter-thumbs <dir>` |
| Buttons in Settings | `action` settings |
| Overlay text | `mp.osd_message` / `mp.create_osd_overlay` (drawn under Vivi's UI) |
| Keys | `mp.add_forced_key_binding` |

Need a widget that does not exist yet? Open an issue in
[Loafer19/vivi](https://github.com/Loafer19/vivi/issues): new hooks are added as script messages.

## Built-in (Rust) plugins

Features with rich UI (visualizer, Skip Intro, Lyrics, Subtitle Search, Auto-tagger, Free Music,
Network Streams) are compiled into Vivi in `src/plugins/`. Each implements the `Plugin` trait and is
listed in `plugins::builtin()`; the `Registry` calls the enabled ones on the UI thread:

| Hook | When |
| --- | --- |
| `enable(cx)` / `disable(cx)` | Switched on / off (and at startup). |
| `file_loaded(cx)` | mpv loaded a new file. |
| `tick(cx)` | Every 100 ms; poll worker-thread channels here. |
| `setting_changed(cx, key)` | A setting changed (already saved). |
| `command(cx, name, args)` | An action button or a Slint `plugin-command(id, name, args)` callback. |

`Ctx` gives `cx.app` (the Slint window), `cx.player` (mpv), `cx.get` / `cx.flag` / `cx.set` for
settings and `cx.toast`. Hooks run on the UI thread: do network and disk work on a thread and send
results through a channel. These live in the [vivi](https://github.com/Loafer19/vivi) repository and
also need an entry in `plugins/index.json` here (`kind = "builtin"`).
