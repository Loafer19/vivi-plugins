local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/scene-chapters/scene-chapters.lua")

-- showinfo parsing: times relative to the input start, sorted
local log = [[
Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'v.mp4':
  Duration: 00:10:34.62, start: 1.400000, bitrate: 2031 kb/s
[Parsed_showinfo_2 @ 0x1] n:   0 pts: 1 pts_time:41.4 duration: 1
[Parsed_showinfo_2 @ 0x1] n:   1 pts: 2 pts_time:11.4 duration: 1
[Parsed_showinfo_2 @ 0x1] n:   2 pts: 3 pts_time:81.65 duration: 1
]]
local s = P.parse_scenes(log)
T.eq(table.concat(s, ","), "10,40,80.25", "start time subtracted, sorted")
T.eq(#P.parse_scenes("x pts_time:1.0 pts_time:40.5"), 2, "no Duration line: start 0")
T.eq(#P.parse_scenes(nil), 0, "no output")

-- minimum length from the start, between cuts and before the end
T.eq(table.concat(P.pick({ 1, 40.5, 50, 80.25 }, 30), ","), "40.5,80.25", "30 s apart")
T.eq(table.concat(P.pick({ 40, 80, 618 }, 30, 634), ","), "40,80", "no chapter shorter than the minimum at the end")
T.eq(table.concat(P.pick({ 40, 80, 600 }, 30, 634), ","), "40,80,600", "a long enough last chapter stays")

-- settings in range
P.opts.threshold = "5"
T.eq(P.threshold(), 0.95, "threshold capped")
P.opts.threshold = "abc"
T.eq(P.threshold(), 0.4, "bad threshold: default")
P.opts.threshold = "0.3"
T.eq(P.scan_mode(), "full", "every frame by default")
P.opts.scan = "Keyframes only"
T.eq(P.scan_mode(), "keyframes", "keyframes")

-- ffmpeg arguments: low priority, keyframes only when asked
local a = table.concat(P.scan_args("ffmpeg", "/v.mkv", 0.3, "keyframes"), " ")
T.ok(a:find("-skip_frame nokey -i /v.mkv", 1, true), "keyframes: skip_frame before -i")
T.ok(a:find("select='gt(scene,0.30)'", 1, true), "threshold in the filter")
T.ok(a:find("-an -sn -dn", 1, true), "video only")
T.ok(not table.concat(P.scan_args("ffmpeg", "/v", 0.4, "full"), " "):find("skip_frame", 1, true), "full scan")
if io.open("/usr/bin/nice") then T.eq(P.scan_args("ffmpeg", "/v", 0.4, "full")[1], "/usr/bin/nice", "lowest priority") end

-- cache: v2 records threshold and scan; a full scan serves keyframes; 1.0.x lists only for auto
local v2 = { version = 2, threshold = 0.4, scan = "full", times = { 1 } }
T.ok(P.cache_fits(v2, 0.4, "keyframes", true), "full scan serves keyframes")
T.ok(not P.cache_fits({ version = 2, threshold = 0.4, scan = "keyframes", times = {} }, 0.4, "full", true), "keyframes do not serve full")
T.ok(not P.cache_fits(v2, 0.3, "full", true), "other threshold: scan again")
T.ok(P.cache_fits({ legacy = true, times = {} }, 0.4, "full", false), "1.0.x cache: automatic")
T.ok(not P.cache_fits({ legacy = true, times = {} }, 0.4, "full", true), "1.0.x cache: manual scans again")
local dir = os.getenv("XDG_DATA_HOME") .. "/sc-test"
os.execute("mkdir -p " .. dir)
P.write_cache(dir, 0.4, "full", { 12.5, 40 })
local c = P.read_cache(dir)
T.eq(c and c.version, 2, "v2 written")
T.eq(c and #c.times, 2, "raw times kept")
local f = io.open(dir .. "/scenes.json", "w") f:write("[39.7,73.8]") f:close()
c = P.read_cache(dir)
T.ok(c and c.legacy and #c.times == 2, "1.0.x cache read")

-- chapters: merged with other plugins' chapters, ours replaced, file chapters respected
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
T.props["chapter-list"] = { { time = 494.6, title = "Outro" }, { time = 618.7, title = "End of outro" } }
P.apply({ 100, 300 })
T.eq(titles(), "Scene 1,Scene 2,Scene 3,Outro,End of outro", "SponsorBlock chapters kept, sorted")
P.apply({ 200 })
T.eq(titles(), "Scene 1,Scene 2,Outro,End of outro", "new scenes replace ours only")
T.eq(#T.osd, 0, "no mpv OSD text")

-- file with its own chapters: left alone
T.props.path = "tests/plugins/stub.lua"
T.props["track-list"] = { { type = "video", codec = "h264" } }
T.props["chapter-list"] = { { time = 0, title = "Opening" } }
P.on_file_loaded()
T.calls = {}
P.detect(true)
T.eq(toasts()[1], "This video has its own chapters", "own chapters respected")
T.eq(titles(), "Opening", "own chapters untouched")

-- no ffmpeg (stub: every subprocess fails to start)
T.props["chapter-list"] = {}
P.on_file_loaded()
T.calls = {}
P.detect(true)
T.ok((toasts()[#toasts()] or ""):find("failed", 1, true) or (toasts()[#toasts()] or ""):find("needs ffmpeg", 1, true), "ffmpeg problem reported")
T.eq(P.running(), nil, "not left running")

-- audio only / streams
T.props["track-list"] = { { type = "audio" }, { type = "video", albumart = true } }
T.calls = {}
P.detect(true)
T.eq(toasts()[1], "Scene detection: no video track", "cover art is not a video")
T.props.path = "https://youtu.be/aqz-KE-bpKQ"
T.calls = {}
P.detect(true)
T.eq(toasts()[1], "Scene detection: local files only", "streams")

-- a successful scan, via a stub ffmpeg answer
T.props.path = "tests/plugins/stub.lua"
T.props["track-list"] = { { type = "video" } }
T.props.duration = 634
T.props["chapter-list"] = { { time = 494.6, title = "Outro" } }
P.opts.scan, P.opts.threshold, P.opts.min_gap = "Every frame", "0.4", "30"
P.on_file_loaded()
T.props["chapter-list"] = {} -- SponsorBlock's chapters came later: not the file's own
P.on_file_loaded()
os.execute("mkdir -p '" .. P.root .. "/" .. P.key("tests/plugins/stub.lua") .. "'") -- the stub runs no mkdir
local pending
T.set_async(function(t, cb) pending = cb return 7 end)
P.detect(true)
T.ok(P.running(), "scan running")
T.props["chapter-list"] = { { time = 494.6, title = "Outro" }, { time = 618.7, title = "End of outro" } } -- arrives meanwhile
pending(true, { status = 0, stderr = "Duration: 00:10:34.62, start: 0.000000,\npts_time:39.7\npts_time:50\npts_time:73.8\npts_time:620\n" })
T.eq(titles(), "Scene 1,Scene 2,Scene 3,Outro,End of outro", "scenes merged with chapters added during the scan")
T.eq(P.running(), nil, "done")
-- the minimum length changes: applied from the cache, no new scan
pending = nil
P.opts.min_gap = "40"
P.on_settings()
T.eq(titles(), "Scene 1,Scene 2,Outro,End of outro", "new minimum applied from the cache")
T.eq(pending, nil, "no new scan")
-- detect again: cached
T.calls = {}
P.detect(true)
T.eq(toasts()[1], "2 scene chapters (cached)", "cached result")
-- cancel: Alt+J again while running
P.clear()
T.eq(titles(), "Outro,End of outro", "Forget removes our scenes only")
os.remove(P.root .. "/" .. P.key("tests/plugins/stub.lua") .. "/scenes.json") -- the stub's readdir lists nothing
P.detect(true)
T.ok(P.running(), "running again")
T.calls = {}
P.detect(true)
T.eq(toasts()[1], "Scene detection cancelled", "second press cancels")
T.eq(P.running(), nil, "cancelled")
pending(false, { error_string = "killed" })
T.eq(titles(), "Outro,End of outro", "a cancelled scan changes nothing")
T.set_async(nil)

-- deprecated: Chapters & Previews 1.2 takes over (Alt+J, automatic scans, settings copied once)
P = T.load("plugins/scene-chapters/scene-chapters.lua", { auto = true, scan = "Keyframes only", min_gap = "45" })
local hello = false
for _, c in ipairs(T.calls) do if c[2] == "scene-chapters-hello" then hello = true end end
T.ok(hello, "asks whether Chapters & Previews is there")
T.calls = {}
P.on_superseded()
local set = {}
for _, c in ipairs(T.calls) do
  if c[1] == "script-message" and c[2] == "vivi-setting" and c[3] == "chapter-thumbnails" then set[c[4]] = c[5] end
end
T.eq(set.scenes, "true", "automatic setting copied")
T.eq(set["scenes-scan"], "Keyframes only", "scan copied")
T.eq(set["scenes-min-length"], "45", "minimum length copied")
T.eq(set["scenes-threshold"], nil, "default threshold not copied")
T.ok(T.removed and T.removed.detect, "Alt+J left to Chapters & Previews")
T.calls = {}
P.detect(true)
T.eq(T.calls[1] and table.concat(T.calls[1], " "), "script-message-to chapter_thumbnails scenes-detect", "Detect forwarded")
T.calls = {}
P.on_superseded()
T.eq(#T.calls, 0, "once")
P = T.load("plugins/scene-chapters/scene-chapters.lua", { auto = true })
T.calls = {}
P.on_superseded()
local n = 0
for _, c in ipairs(T.calls) do if c[2] == "vivi-setting" then n = n + 1 end end
T.eq(n, 0, "settings copied only the first time (marker file)")
T.done("scene-chapters")
