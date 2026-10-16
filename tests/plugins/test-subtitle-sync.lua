local T = dofile("tests/plugins/stub.lua")
-- run.sh points XDG_DATA_HOME at a temporary folder (offsets.json is written there).
local P = T.load("plugins/subtitle-sync/subtitle-sync.lua")
T.eq(P.out_path("/m/movie.en.srt"), "/m/movie.en.synced.srt", "synced name")
T.eq(P.out_path("/m/movie.en.synced.srt"), "/m/movie.en.synced.srt", "no double suffix")
T.eq(P.out_path("/m/noext"), "/m/noext.synced.srt", "no extension")
T.eq(P.round(0.30000000004), 0.3, "round")
-- Nudges go through sub-delay and are saved per file.
T.props.path = "tests/plugins/stub.lua"
T.props["sub-delay"] = 0
P.nudge(1)()
P.nudge(1)()
T.eq(T.props["sub-delay"], 0.2, "two steps later")
P.nudge(-10)()
T.eq(T.props["sub-delay"], -0.8, "one second earlier")
T.ok(P.OFFSETS:find("subtitle-sync", 1, true), "offsets file path")
-- With Vivi 0.11+ (script-opt vivi-sub-offsets=1) the keys hand the offset to Vivi.
T.opts = { ["vivi-sub-offsets"] = "1" }
T.calls = {}
T.props["sub-delay"] = 0.5
P.nudge(1)()
local last = T.calls[#T.calls]
T.eq(last and last[2], "vivi-sub-offset", "offset message to Vivi")
T.eq(last and last[3], "set:0.6", "absolute offset sent")
T.eq(T.props["sub-delay"], 0.5, "Vivi sets sub-delay itself")
T.opts = nil
T.done("subtitle-sync")
