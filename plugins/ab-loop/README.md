# A-B Loop & Frame Step

> **Deprecated — built into Vivi since 0.13.0.** Vivi now has these keys itself:
> `Alt+A` / `Alt+B` set the loop points (a point set on the wrong side of the other one
> swaps them), `Alt+C` clears, `Alt+←` / `Alt+→` move the point set last by one frame,
> `,` / `.` step one frame while paused (1 s while playing), and `Shift+L` still cycles
> set A / set B / clear. The loop is drawn on the seek bar (drag its edges) and in the
> side panel, with a toast for each change; points no longer carry over to the next
> file. Uninstall this plugin in Extensions → All / Marketplace; it stays here for older
> Vivi versions and is no longer listed in the marketplace (its page remains). With
> Vivi 0.13.0 or newer the core takes these keys before this script sees them, and the
> script draws nothing (it checks `user-data/vivi/ab-loop`).

Set and clear A-B loop points from the keyboard, nudge them by a frame, step frame by frame while paused and see the loop on an on-screen bar.

Install: Vivi → Settings → Extensions → Browse → **Install**. Requires Vivi 0.9.0+. Implements #59.

- `Alt+A` / `Alt+B`: set A / B at the current position
- `Alt+C`: clear the loop
- `Alt+Left` / `Alt+Right`: move the last set point by one frame
- `,` / `.`: one frame back / forward while paused (1 s seek while playing)

The loop bar is an mpv OSD overlay above the controls. Binding names for `script-binding ab_loop/<name>` (`set-a`, `set-b`, `clear`, `nudge-back`, `nudge-forward`, `frame-back`, `frame-forward`).
