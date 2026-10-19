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
local last_toast = ""
for _, c in ipairs(T.calls) do if c[1] == "script-message" and c[2] == "vivi-toast" then last_toast = c[3] end end
T.ok(last_toast:find("AV1 video needs ffmpeg installed", 1, true), "av1 message")
T.eq(#T.osd, 0, "Vivi toasts, no mpv OSD text")

-- ---------- scene chapters (merged from Scene Chapters 1.1.0) ----------
P = T.load("plugins/chapter-thumbnails/chapter-thumbnails.lua")
local log = [[
  Duration: 00:10:34.62, start: 1.400000, bitrate: 2031 kb/s
[Parsed_showinfo_2 @ 0x1] n:   0 pts: 1 pts_time:41.4 duration: 1
[Parsed_showinfo_2 @ 0x1] n:   1 pts: 2 pts_time:11.4 duration: 1
[Parsed_showinfo_2 @ 0x1] n:   2 pts: 3 pts_time:81.65 duration: 1
]]
T.eq(table.concat(P.parse_scenes(log), ","), "10,40,80.25", "scenes: start time subtracted, sorted")
T.eq(#P.parse_scenes(nil), 0, "scenes: no output")
T.eq(table.concat(P.pick_scenes({ 1, 40.5, 50, 80.25 }, 30), ","), "40.5,80.25", "scenes: 30 s apart")
T.eq(table.concat(P.pick_scenes({ 40, 80, 618 }, 30, 634), ","), "40,80", "scenes: no short last chapter")
P.opts["scenes-threshold"] = "5"
T.eq(P.scene_threshold(), 0.95, "scenes: threshold capped")
P.opts["scenes-threshold"] = "0.3"
T.eq(P.scene_mode(), "full", "scenes: every frame by default")
P.opts["scenes-scan"] = "Keyframes only"
T.eq(P.scene_mode(), "keyframes", "scenes: keyframes")
local sa = table.concat(P.scene_args("ffmpeg", "/v.mkv", 0.3, "keyframes"), " ")
T.ok(sa:find("-skip_frame nokey -i /v.mkv", 1, true), "scenes: skip_frame before -i")
T.ok(sa:find("select='gt(scene,0.30)'", 1, true), "scenes: threshold in the filter")
T.ok(not table.concat(P.scene_args("ffmpeg", "/v", 0.4, "full"), " "):find("skip_frame", 1, true), "scenes: full scan")
if io.open("/usr/bin/nice") then T.eq(P.scene_args("ffmpeg", "/v", 0.4, "full")[1], "/usr/bin/nice", "scenes: lowest priority") end
local v2 = { version = 2, threshold = 0.4, scan = "full", times = { 1 } }
T.ok(P.scene_cache_fits(v2, 0.4, "keyframes", true), "scenes: full scan serves keyframes")
T.ok(not P.scene_cache_fits(v2, 0.3, "full", true), "scenes: other threshold scans again")
T.ok(P.scene_cache_fits({ legacy = true, times = {} }, 0.4, "full", false), "scenes: 1.0.x cache, automatic")
T.ok(not P.scene_cache_fits({ legacy = true, times = {} }, 0.4, "full", true), "scenes: 1.0.x cache, manual scans")

local function titles()
  local t = {}
  for _, x in ipairs(T.props["chapter-list"] or {}) do t[#t + 1] = x.title end
  return table.concat(t, ",")
end
local function toasts()
  local t = {}
  for _, x in ipairs(T.calls) do if x[1] == "script-message" and x[2] == "vivi-toast" then t[#t + 1] = x[3] end end
  return t
end
local function load_file(chapters)
  T.props.path = "tests/plugins/stub.lua"
  T.props["track-list"] = { { type = "video", codec = "h264" } }
  T.props.duration = 634
  T.props["chapter-list"] = chapters
  P.set_ffmpeg({ ffmpeg = "ffmpeg", ffprobe = "ffprobe", kind = "system" })
  P.on_file_loaded()
  P.scenes_file_loaded()
end
P.opts["scenes-scan"], P.opts["scenes-threshold"], P.opts["scenes-min-length"] = "Every frame", "0.4", "30"
-- own chapters are left alone
load_file({ { time = 0, title = "Opening" } })
T.calls = {}
P.detect_scenes(true)
T.eq(toasts()[1], "This video has its own chapters", "scenes: own chapters respected")
-- streams
T.props.path = "https://youtu.be/aqz-KE-bpKQ"
P.on_file_loaded()
T.calls = {}
P.detect_scenes(true)
T.eq(toasts()[1], "Scene detection: local files only", "scenes: streams")
-- a scan merged with SponsorBlock chapters that arrive meanwhile
load_file({})
local dir = os.getenv("XDG_DATA_HOME") .. "/vivi/plugin-data/chapter-thumbnails/" .. P.key("tests/plugins/stub.lua")
os.execute("mkdir -p '" .. dir .. "'")
os.remove(dir .. "/scenes.json")
local pending
T.set_async(function(t, cb)
  if t.args and table.concat(t.args, " "):find("gt(scene", 1, true) then pending = cb return 7 end
  if cb then cb(true, { status = 0, stdout = "", stderr = "" }) end
end)
T.calls = {}
P.detect_scenes(true)
T.ok(P.scanning(), "scenes: scan running")
T.eq(toasts()[1], "Detecting scenes…", "scenes: toast")
T.props["chapter-list"] = { { time = 494.6, title = "Outro" }, { time = 618.7, title = "End of outro" } }
pending(true, { status = 0, stderr = "Duration: 00:10:34.62, start: 0.000000,\npts_time:39.7\npts_time:50\npts_time:73.8\npts_time:620\n" })
T.eq(titles(), "Scene 1,Scene 2,Scene 3,Outro,End of outro", "scenes: merged with chapters added during the scan")
T.eq(P.scanning(), nil, "scenes: done")
-- written by the mkdir callback (stub answers at once)
T.ok(P.read_scenes(dir) and P.read_scenes(dir).version == 2, "scenes: v2 cache written")
-- new minimum: from the cache, no new scan
pending = nil
P.opts["scenes-min-length"] = "40"
P.scenes_settings()
T.eq(titles(), "Scene 1,Scene 2,Outro,End of outro", "scenes: new minimum applied from the cache")
T.eq(pending, nil, "scenes: no new scan")
T.calls = {}
P.detect_scenes(true)
T.eq(toasts()[1], "2 scene chapters (cached)", "scenes: cached result")
-- forget, scan again, cancel with a second press
P.forget_scenes()
T.eq(titles(), "Outro,End of outro", "scenes: Forget removes our scenes only")
P.detect_scenes(true)
T.ok(P.scanning(), "scenes: running again")
T.calls = {}
P.detect_scenes(true)
T.eq(toasts()[1], "Scene detection cancelled", "scenes: second press cancels")
pending(false, { error_string = "killed" })
T.eq(titles(), "Outro,End of outro", "scenes: a cancelled scan changes nothing")
-- the old Scene Chapters cache (same key) is used
local old = os.getenv("XDG_DATA_HOME") .. "/vivi/plugin-data/scene-chapters/" .. P.key("tests/plugins/stub.lua")
os.execute("mkdir -p '" .. old .. "'")
local f = io.open(old .. "/scenes.json", "w")
f:write('{"version":2,"threshold":0.4,"scan":"full","times":[100,200]}') f:close()
P.opts["scenes-min-length"] = "30"
T.props["chapter-list"] = {}
T.calls = {}
P.scenes_file_loaded()
P.detect_scenes(true)
T.eq(toasts()[1], "3 scene chapters (cached)", "scenes: Scene Chapters cache read")
os.remove(old .. "/scenes.json") -- XDG_DATA_HOME is shared with test-scene-chapters.lua
os.remove(dir .. "/scenes.json")
-- automatic only with the toggle; the old plugin is told to step aside
T.ok(not P.opts.scenes, "scenes: automatic detection off by default")
T.set_async(nil)
T.done("chapter-thumbnails")
