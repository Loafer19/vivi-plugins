local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/chapter-thumbnails/chapter-thumbnails.lua")
local t = P.seek_times(100, 50)
T.eq(#t, 50, "50 frames")
T.eq(t[1], 1, "first frame at the centre of slice 0")
T.eq(t[50], 99, "last frame")
local a = P.frame_args("ffmpeg", "/v.mkv", 12.345, "/o.jpg", 192, 108)
T.eq(a[9], "12.35", "seek time")
T.ok(table.concat(a, " "):find("pad=192:108", 1, true), "padded seek frame")
T.ok(table.concat(P.frame_args("ffmpeg", "/v", 1, "/o", 320), " "):find("scale=320:-2", 1, true), "chapter frame")
T.eq(P.fmt_time(3725), "1:02:05", "hours")
T.eq(P.fmt_time(65), "1:05", "minutes")
-- Key must match src/scenes.rs (test there: key("/v/a.mkv", 1234, 1700000000)).
T.ok(P.key("tests/plugins/stub.lua"):match("^%x%x%x%x%x%x%x%x$"), "hex key")

-- frame count: Auto = one per ~10 s, 25..200; fixed counts; short files
T.eq(P.frame_count(634, "Auto"), 63, "auto, 10 min")
T.eq(P.frame_count(7200, "Auto"), 200, "auto capped at 200")
T.eq(P.frame_count(60, "Auto"), 25, "auto at least 25")
T.eq(P.frame_count(600, "100"), 100, "fixed count")
T.eq(P.frame_count(600, "5000"), 200, "fixed count capped")
T.eq(P.frame_count(12.5, "Auto"), 12, "short file: one per second")
T.eq(P.frame_count(3, "50"), 10, "very short file: Vivi's minimum of 10")

-- coarse to fine
local ord = P.order(50)
T.eq(#ord, 50, "every frame once")
T.eq(table.concat({ ord[1], ord[2], ord[3], ord[4], ord[5] }, ","), "0,16,32,48,8", "every 16th, then every 8th")
local seen = {}
for _, k in ipairs(ord) do seen[k] = true end
local all = true
for k = 0, 49 do all = all and seen[k] end
T.ok(all, "no frame missing")

-- low priority
T.eq(table.concat(P.low_priority({ "ffmpeg", "-i" }, "/usr/bin/nice", "/usr/bin/ionice"), " "),
  "/usr/bin/nice -n 19 /usr/bin/ionice -c3 ffmpeg -i", "nice + ionice")
T.eq(table.concat(P.low_priority({ "ffmpeg" }, "/usr/bin/nice", nil), " "), "/usr/bin/nice -n 19 ffmpeg", "nice only")
T.eq(table.concat(P.low_priority({ "ffmpeg" }), " "), "ffmpeg", "neither")

-- codecs of the media build
T.ok(P.managed_decodes("h264"), "h264")
T.ok(P.managed_decodes("vp9"), "vp9")
T.ok(not P.managed_decodes("av1"), "no av1")
T.ok(P.managed_decodes(nil), "unknown codec: try")

-- pruning: newest kept within both limits, the current folder never deleted
local MB = 1048576
local del = P.select_prune({ { "a", 1, MB }, { "b", 2, MB }, { "c", 3, MB }, { "d", 4, MB } }, 2, 100 * MB, nil)
table.sort(del)
T.eq(table.concat(del, ","), "a,b", "file limit drops the oldest")
del = P.select_prune({ { "a", 1, 3 * MB }, { "b", 2, 3 * MB }, { "c", 3, 3 * MB } }, 100, 5 * MB, nil)
table.sort(del)
T.eq(table.concat(del, ","), "a,b", "size limit drops the oldest")
del = P.select_prune({ { "a", 1, MB }, { "b", 2, MB }, { "c", 3, MB } }, 1, 100 * MB, "a")
table.sort(del)
T.eq(table.concat(del, ","), "b,c", "current folder kept")

-- flow: a 10-minute local video with two chapters
local function ffmpeg_calls()
  local n = 0
  for _, c in ipairs(T.calls) do
    if type(c) == "table" and c.name == "subprocess" then
      for _, x in ipairs(c.args) do if x == "ffmpeg" then n = n + 1 break end end
    end
  end
  return n
end
local function low_calls()
  local n = 0
  for _, c in ipairs(T.calls) do
    if type(c) == "table" and c.name == "subprocess" and c.args[2] == "-n" and c.args[3] == "19" then n = n + 1 end
  end
  return n
end
T.props.path = "tests/plugins/stub.lua"
T.props["track-list"] = { { type = "video", codec = "h264" } }
T.props.duration = 600
T.props["chapter-list"] = { { time = 0, title = "A" }, { time = 300, title = "B" } }
P.set_ffmpeg({ ffmpeg = "ffmpeg", ffprobe = "ffprobe", kind = "system" })
T.calls = {}
P.on_file_loaded()
-- chapter frames at once (each tried twice: keyframe seek, then full decode), no seek frames yet
T.eq(ffmpeg_calls(), 4, "chapter frames when the file opens")
local _, st = P.state()
T.eq(st, nil, "seek frames wait for the hover")
T.calls = {}
P.hover()
T.eq(ffmpeg_calls(), 2 * 60, "60 seek frames on hover (Auto, 10 min)")
T.eq(low_calls(), 0, "hover: normal priority")
_, st = P.state()
T.eq(st, nil, "nothing decoded (stub): not marked done, can retry")

-- On open: nothing before 10 s of playback, then at low priority
P = T.load("plugins/chapter-thumbnails/chapter-thumbnails.lua", { when = "On open" })
T.props.path = "tests/plugins/stub.lua"
T.props["track-list"] = { { type = "video", codec = "h264" } }
T.props.duration = 600
T.props["chapter-list"] = {}
P.set_ffmpeg({ ffmpeg = "ffmpeg", ffprobe = "ffprobe", kind = "system" })
P.on_file_loaded()
T.calls = {}
for _ = 1, 9 do P.on_tick() end
T.eq(ffmpeg_calls(), 0, "on open: waits 10 s")
T.props.pause = true
P.on_tick()
T.eq(ffmpeg_calls(), 0, "paused time does not count")
T.props.pause = false
P.on_tick()
T.eq(ffmpeg_calls(), 120, "on open: starts after 10 s of playback")
T.ok(low_calls() > 0 or not io.open("/usr/bin/nice"), "on open: low priority")

-- On open skips short videos; audio-only files are ignored
T.props.duration = 120
P.on_file_loaded()
T.calls = {}
for _ = 1, 20 do P.on_tick() end
T.eq(ffmpeg_calls(), 0, "on open: not for videos under 3 minutes")
T.props["track-list"] = { { type = "audio" }, { type = "video", albumart = true } }
P.on_file_loaded()
T.eq((P.state()), nil, "audio with cover art: not a video")

-- AV1 with the media build: a clear message instead of failed frames
P = T.load("plugins/chapter-thumbnails/chapter-thumbnails.lua")
T.props.path = "tests/plugins/stub.lua"
T.props["track-list"] = { { type = "video", codec = "av1" } }
T.props.duration = 600
T.props["chapter-list"] = {}
P.set_ffmpeg({ ffmpeg = "ffmpeg-media", ffprobe = "ffprobe-media", kind = "managed" })
P.on_file_loaded()
T.calls, T.osd = {}, {}
P.hover()
T.eq(ffmpeg_calls(), 0, "av1: no frames with the media build")
T.ok((T.osd[#T.osd] or ""):find("AV1 video needs ffmpeg installed", 1, true), "av1 message")
T.done("chapter-thumbnails")
