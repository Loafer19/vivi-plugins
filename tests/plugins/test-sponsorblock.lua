local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/sponsorblock/sponsorblock.lua")
T.eq(P.youtube_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1"), "dQw4w9WgXcQ", "watch url")
T.eq(P.youtube_id("https://youtu.be/aqz-KE-bpKQ"), "aqz-KE-bpKQ", "short url")
T.eq(P.youtube_id("https://x.org/a"), nil, "other url")
T.eq(P.file_id("/home/u/Downloads/Vivi/Big Buck Bunny [aqz-KE-bpKQ].mp4"), "aqz-KE-bpKQ", "downloaded file")
T.eq(P.file_id("/m/03 - Song [aqz-KE-bpKQ] (audio).m4a"), "aqz-KE-bpKQ", "audio download")
T.eq(P.file_id("/m/Movie [1080p].mkv"), nil, "not an id")
T.eq(P.file_id("https://youtu.be/aqz-KE-bpKQ"), nil, "urls are not files")
local p = P.parse('[{"videoID":"aqz-KE-bpKQ","segments":[{"category":"outro","actionType":"skip","segment":[494.6,618.7]},{"category":"sponsor","actionType":"mute","segment":[1,2]}]}]', "aqz-KE-bpKQ")
T.eq(#p, 2, "skip and mute segments")
T.eq(p[1][3], "sponsor", "sorted by start")
T.eq(p[1][4], "mute", "mute action")
T.eq(p[2][3], "outro", "category")
T.eq(p[2][4], "skip", "skip action")
T.eq(P.action_types(), '["skip","mute"]', "asks for mute segments")
P.opts.mute = false
T.eq(#P.parse('[{"videoID":"aqz-KE-bpKQ","segments":[{"category":"sponsor","actionType":"mute","segment":[1,2]}]}]', "aqz-KE-bpKQ"), 0, "mute off: ignored")
T.eq(P.action_types(), '["skip"]', "mute off: skip only")
P.opts.mute = true
-- per-category overrides
T.eq(P.categories(), '["interaction","selfpromo","sponsor"]', "default categories")
P.opts.per_category = "selfpromo=off intro=ask sponsor=skip bogus=maybe"
T.eq(P.categories(), '["interaction","intro","sponsor"]', "off removes, ask adds")
T.eq(P.action_for("intro"), "ask", "intro asks")
T.eq(P.action_for("sponsor"), "skip", "sponsor skips")
T.eq(P.action_for("interaction"), "skip", "others follow the mode")
P.opts.mode = "Ask (Alt+K skips)"
T.eq(P.action_for("interaction"), "ask", "mode ask")
T.eq(P.action_for("sponsor"), "skip", "override beats mode")
P.opts.mode, P.opts.per_category = "Skip automatically", ""
-- skip, notice, undo, then the segment plays through
T.props["time-pos"] = 10
P.set_segments({ { 10, 40, "sponsor" } })
P.on_time(nil, 10.2)
T.eq(T.props["time-pos"], 40, "skipped to the end")
T.ok(T.osd[#T.osd]:find("undo"), "notice mentions undo")
P.undo()
T.eq(T.props["time-pos"], 10, "undo seeks back")
P.on_time(nil, 11)
T.eq(T.props["time-pos"], 10, "undone segment is not skipped again")
-- undo has no time limit: much later it still goes back
P.set_segments({ { 10, 40, "sponsor", "skip" } })
P.on_time(nil, 10.2)
P.on_time(nil, 300)
P.undo()
T.eq(T.props["time-pos"], 10, "undo long after the skip")
-- ask: a toast, no seek; Alt+K skips
P.set_segments({ { 100, 130, "intro", "skip" } })
P.opts.per_category = "intro=ask"
T.props["time-pos"] = 100.5
P.on_time(nil, 100.5)
T.eq(T.props["time-pos"], 100.5, "ask does not seek")
T.ok(T.osd[#T.osd]:find("Alt%+K"), "ask toast")
P.skip_key()
T.eq(T.props["time-pos"], 130, "Alt+K skips the announced segment")
P.opts.per_category = ""
-- mute segments: muted inside, sound back after, undo unmutes
T.props.mute = false
P.set_segments({ { 50, 60, "sponsor", "mute" } })
P.on_time(nil, 50.2)
T.eq(T.props.mute, true, "muted in a mute segment")
T.ok(T.osd[#T.osd]:find("unmute"), "mute notice")
P.on_time(nil, 61)
T.eq(T.props.mute, false, "sound back after it")
P.on_time(nil, 50.5)
T.eq(T.props.mute, true, "muted again on re-entry")
P.undo()
T.eq(T.props.mute, false, "undo unmutes")
P.on_time(nil, 51)
T.eq(T.props.mute, false, "unmuted segment stays audible")
-- a user who already muted keeps control
P.set_segments({ { 50, 60, "sponsor", "mute" } })
T.props.mute = true
P.on_time(nil, 50.2)
P.on_time(nil, 61)
T.eq(T.props.mute, true, "user mute is not undone")
T.props.mute = false
-- chapters
T.props["chapter-list"] = {}
P.set_segments({ { 5, 9, "sponsor", "skip" }, { 20, 25, "selfpromo", "mute" } })
P.add_chapters()
local ch = T.props["chapter-list"]
T.eq(#ch, 4, "two chapters per segment")
T.eq(ch[3].title, "Self-promotion (muted)", "muted chapter title")
-- Vivi 0.13+ (user-data/vivi/skip-api = 1): segments go to the core Skip button,
-- no own skip / ask / mute / keys.
T.props["chapter-list"] = {}
T.props["user-data/vivi/skip-api"] = 1
P.opts.per_category = "intro=ask"
P.set_segments({ { 10, 40, "sponsor", "skip" }, { 50, 60, "selfpromo", "mute" }, { 70, 90, "intro", "skip" } })
local r = P.core_ranges()
T.eq(#r, 3, "core: all segments")
T.eq(r[1].start, 10, "core: start")
T.eq(r[1]["end"], 40, "core: end")
T.eq(r[1].label, "sponsor", "core: label")
T.eq(r[1].action, "skip", "core: auto mode -> skip")
T.eq(r[2].action, "mute", "core: mute action")
T.eq(r[2].label, "self-promotion", "core: label name")
T.eq(r[3].action, "ask", "core: per-category ask")
T.calls = {}
T.ok(P.send_core(), "core: sent")
local sent = T.calls[#T.calls]
T.eq(sent[1], "script-message", "core: script-message")
T.eq(sent[2], "vivi-skip-ranges", "core: message name")
T.eq(sent[3], "sponsorblock", "core: source")
local back = T.json_decode(sent[4])
T.eq(#back, 3, "core: json array")
T.eq(back[3].category, "intro", "core: category in json")
T.props["time-pos"], T.props.mute = 10.2, false
P.on_time(nil, 10.2)
T.eq(T.props["time-pos"], 10.2, "core: no own skip")
P.on_time(nil, 50.5)
T.eq(T.props.mute, false, "core: no own mute")
P.skip_key()
T.eq(T.props["time-pos"], 10.2, "core: Alt+K is Vivi's")
T.calls = {}
P.undo()
T.eq(T.calls[1] and T.calls[1][2], "vivi-skip-undo", "core: Undo goes to Vivi")
P.set_segments({})
T.calls = {}
P.send_core()
T.eq(T.calls[1] and T.calls[1][2], "vivi-skip-ranges-clear", "core: no segments clears")
-- Skip Intro & Credits off (0) or older Vivi (unset): own skipping again.
T.props["user-data/vivi/skip-api"] = 0
T.ok(not P.send_core(), "fallback: nothing sent")
P.opts.per_category = ""
P.set_segments({ { 10, 40, "sponsor", "skip" } })
P.on_time(nil, 10.2)
T.eq(T.props["time-pos"], 40, "fallback: skips itself")
T.props["user-data/vivi/skip-api"] = nil
T.done("sponsorblock")
