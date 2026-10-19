local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/ab-loop/ab-loop.lua")

T.eq(P.fmt(65.25), "1:05.25", "fmt")
T.eq(P.fmt(nil), "--:--", "fmt unset")

-- Older Vivi (no user-data/vivi/ab-loop): the script does the work.
T.ok(not P.builtin(), "no built-in A-B loop")
T.props["time-pos"] = 10
T.bindings["Alt+a"]()
T.eq(T.props["ab-loop-a"], 10, "Alt+A sets A")
T.props["time-pos"] = 14
T.bindings["Alt+b"]()
T.eq(T.props["ab-loop-b"], 14, "Alt+B sets B")
T.eq(T.osd[#T.osd], "B: 0:14.00", "B toast")
T.props["container-fps"] = 50
T.bindings["Alt+RIGHT"]()
T.ok(math.abs(T.props["ab-loop-b"] - 14.02) < 1e-9, "nudge B by one frame")
T.props["pause"] = true
T.bindings["."]()
T.eq(T.calls[#T.calls][1], "frame-step", "frame step while paused")
T.props["pause"] = false
T.bindings[","]()
T.eq(T.calls[#T.calls][2], "-1", "1 s seek back while playing")
T.bindings["Alt+c"]()
T.eq(T.props["ab-loop-a"], "no", "clear A")
T.eq(T.props["ab-loop-b"], "no", "clear B")
T.eq(T.osd[#T.osd], "A-B loop cleared", "clear toast")

-- Vivi 0.13.0+: the core owns the keys; the script stays quiet but "Clear loop" works.
T.props["user-data/vivi/ab-loop"] = 1
T.ok(P.builtin(), "built-in detected")
local n = #T.osd
T.bindings["Alt+a"]()
T.eq(T.props["ab-loop-a"], "no", "Alt+A does nothing with the built-in keys")
T.bindings["."]()
T.eq(#T.osd, n, "no toast either")
T.props["ab-loop-a"] = 3
T.messages["clear"]()
T.eq(T.props["ab-loop-a"], "no", "Clear loop action still clears")
T.done("ab-loop")
