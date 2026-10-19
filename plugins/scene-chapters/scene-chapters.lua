-- @name Scene Chapters
-- @version 1.1.1
-- @author Vivi
-- @description Chapters at scene changes for local videos without chapters, via ffmpeg (Vivi plugin package).
--
-- DEPRECATED: scene detection is part of Chapters & Previews (chapter-thumbnails 1.2.0).
-- When that plugin is loaded it says `scene-chapters-superseded`; this one then steps
-- aside: Alt+J and automatic scans are left to it, Detect / Forget are forwarded to it,
-- and non-default settings are copied over once (vivi-setting). Without it, this works
-- as before.
--
-- Keys: Alt+j  detect (again while it runs: cancel)
-- Script messages: detect, clear.
--
-- ffmpeg's scene score (`select='gt(scene,T)',showinfo` on a 160 px wide copy, no audio)
-- marks the cuts; they become "Scene 1", "Scene 2", … at least `min_gap` seconds apart
-- (also from the start and the end). "Keyframes only" decodes just the keyframes, about
-- ten times faster; encoders put a keyframe at most cuts, so it finds fewer but real ones.
-- The scan runs in the background at the lowest CPU / disk priority (nice / ionice).
--
-- Chapters the file brings are left alone. Chapters other plugins add (SponsorBlock) are
-- kept: the scenes are merged with them, whichever comes first. Pictures for the chapters
-- come from the Chapter Thumbnails plugin, which follows chapter changes.
--
-- Cache: plugin-data/scene-chapters/<key>/scenes.json, <key> = hash of "path|size|mtime"
-- (same as Vivi's src/scenes.rs), { version = 2, threshold, scan, times = raw cut times }.
-- The minimum length is applied when the chapters are made, so changing it needs no new
-- scan; another threshold does. A 1.0.x cache (a plain list of times) is still used.
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

local o = {
  auto = false, threshold = "0.4", min_gap = "30", scan = "Every frame",
  thumbnails = true, -- 1.0.x setting (pictures are Chapter Thumbnails' job now); declared so saved values do not warn
  pkgdir = "",       -- set by Vivi; declared so mp.options does not warn about it
}

-- Vivi's own toast (no mpv OSD text over the video).
local function toast(msg) mp.commandv("script-message", "vivi-toast", msg) end

local windows = package.config:sub(1, 1) == "\\"
local SEP = windows and "\\" or "/"
local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
local data = os.getenv("XDG_DATA_HOME")
if not data or data == "" then data = windows and (os.getenv("APPDATA") or home) or (home .. "/.local/share") end
local PLUGIN_DATA = data .. SEP .. "vivi" .. SEP .. "plugin-data"
local root = PLUGIN_DATA .. SEP .. "scene-chapters"
-- Vivi's media ffmpeg, when Chapter Thumbnails or Subtitle Auto-Sync downloaded it.
local MANAGED_FF = PLUGIN_DATA .. SEP .. "shared" .. SEP .. "ffmpeg-media" .. SEP .. "ffmpeg" .. (windows and ".exe" or "")

local NICE, IONICE
if not windows then
  for _, d in ipairs({ "/usr/bin/", "/bin/" }) do
    NICE = NICE or (utils.file_info(d .. "nice") and d .. "nice") or nil
    IONICE = IONICE or (utils.file_info(d .. "ionice") and d .. "ionice") or nil
  end
end

local function mkdir(d)
  if windows then
    utils.subprocess({ args = { "cmd", "/c", "mkdir", (d:gsub("/", "\\")) }, playback_only = false })
  else
    utils.subprocess({ args = { "mkdir", "-p", d }, playback_only = false })
  end
end

-- Stable key (32-bit polynomial hash, hex) of path, size and mtime.
local function key(path)
  local fi = utils.file_info(path)
  if not fi then return nil end
  local s = path .. "|" .. tostring(fi.size) .. "|" .. tostring(math.floor(fi.mtime or 0))
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

-- Threshold and minimum length from the settings, kept in a sane range.
local function threshold()
  return math.max(0.05, math.min(0.95, tonumber(o.threshold) or 0.4))
end
local function min_gap() return math.max(1, tonumber(o.min_gap) or 30) end
local function scan_mode() return tostring(o.scan):lower():find("key", 1, true) and "keyframes" or "full" end

-- Cut times from ffmpeg's showinfo output, relative to the input's start time (the
-- "start:" of the Duration line; mpv's time starts at 0), sorted.
local function parse_scenes(text)
  text = text or ""
  local start = tonumber(text:match("Duration:[^\n]-, start: (%-?[%d%.]+)")) or 0
  local out = {}
  for t in text:gmatch("pts_time:(%-?[%d%.]+)") do
    t = tonumber(t)
    if t then
      t = t - start
      if t > 0 then out[#out + 1] = t end
    end
  end
  table.sort(out)
  return out
end

-- Chapter starts from cut times: at least `gap` s apart, from 0 and (when the duration
-- is known) from the end, so no chapter is shorter than the minimum.
local function pick(times, gap, duration)
  local out, last = {}, 0
  for _, t in ipairs(times or {}) do
    if t - last >= gap and not (duration and duration > 0 and duration - t < gap) then
      out[#out + 1] = t
      last = t
    end
  end
  return out
end

-- ffmpeg arguments of a scan.
local function scan_args(ff, path, th, mode)
  local a = {}
  if NICE then a[#a + 1] = NICE a[#a + 1] = "-n" a[#a + 1] = "19" end
  if IONICE then a[#a + 1] = IONICE a[#a + 1] = "-c3" end
  for _, x in ipairs({ ff, "-nostdin", "-hide_banner" }) do a[#a + 1] = x end
  if mode == "keyframes" then a[#a + 1] = "-skip_frame" a[#a + 1] = "nokey" end
  for _, x in ipairs({ "-i", path, "-an", "-sn", "-dn",
    "-vf", string.format("scale=160:-2,select='gt(scene,%.2f)',showinfo", th), "-f", "null", "-" }) do
    a[#a + 1] = x
  end
  return a
end

local function read_cache(dir)
  local f = io.open(dir .. SEP .. "scenes.json", "r")
  if not f then return nil end
  local v = utils.parse_json(f:read("*a"))
  f:close()
  if type(v) ~= "table" then return nil end
  if v.version == 2 and type(v.times) == "table" then return v end
  if #v > 0 or next(v) == nil then return { legacy = true, times = v } end -- 1.0.x: chapter times, already spaced
  return nil
end

-- Is the cache good for a scan with threshold `th` and `mode`? A full scan also serves
-- "Keyframes only". 1.0.x caches (no threshold recorded) only for automatic runs.
local function cache_fits(c, th, mode, manual)
  if not c then return false end
  if c.legacy then return not manual end
  return math.abs((tonumber(c.threshold) or -1) - th) < 0.001 and (c.scan == mode or c.scan == "full")
end

local function write_cache(dir, th, mode, times)
  mkdir(dir)
  local f = io.open(dir .. SEP .. "scenes.json", "w")
  if f then
    f:write(utils.format_json({ version = 2, threshold = th, scan = mode, times = times }))
    f:close()
  end
end

-- Chapter pictures 1.0.x saved here: Vivi falls back to them when Chapter Thumbnails has
-- none, and they are not redone when chapters move, so they go.
local function drop_old_pictures(dir)
  for _, f in ipairs(utils.readdir(dir, "files") or {}) do
    if f:match("^chapter%-%d+%.jpg$") then os.remove(dir .. SEP .. f) end
  end
end

-- ---------- state of the current file ----------
local cur_path = nil  -- path of the loaded file
local file_chapters = 0 -- chapters the file itself has (counted when it loaded)
local ours = {}       -- chapters we added: { {time, title}, … }
local job = nil       -- running scan: { path, id, cancelled }
local gen = 0         -- bumped on every file, so a late timer or scan result is ignored
local ff_warned = false -- "needs ffmpeg" was shown (automatic runs show it once)
local superseded = false -- Chapters & Previews 1.2+ is loaded and does scene detection
local NEW = "chapter_thumbnails" -- its script name

local function is_ours(c)
  for _, x in ipairs(ours) do
    if c.title == x.title and math.abs((c.time or -1) - x.time) < 0.001 then return true end
  end
  return false
end

-- Put `starts` in as "Scene 1" (at 0), "Scene 2", …, replacing the scenes added before and
-- keeping every other chapter (SponsorBlock's), sorted by time.
local function apply(starts)
  local list = {}
  for _, c in ipairs(mp.get_property_native("chapter-list") or {}) do
    if not is_ours(c) then list[#list + 1] = c end
  end
  ours = { { time = 0, title = "Scene 1" } }
  for i, t in ipairs(starts) do ours[#ours + 1] = { time = t, title = "Scene " .. (i + 1) } end
  for _, c in ipairs(ours) do list[#list + 1] = { time = c.time, title = c.title } end
  table.sort(list, function(a, b) return a.time < b.time end)
  mp.set_property_native("chapter-list", list)
end

-- Take our scenes out again (other chapters stay).
local function remove_ours()
  if #ours == 0 then return false end
  local list = {}
  for _, c in ipairs(mp.get_property_native("chapter-list") or {}) do
    if not is_ours(c) then list[#list + 1] = c end
  end
  ours = {}
  mp.set_property_native("chapter-list", list)
  return true
end

local function local_video()
  local path = mp.get_property("path")
  if not path or path:find("://") or not utils.file_info(path) then return nil, "local files only" end
  for _, t in ipairs(mp.get_property_native("track-list") or {}) do
    if t.type == "video" and not t.albumart and not t.image then return path end
  end
  return nil, "no video track"
end

-- Chapters from cut times; returns how many scene chapters there are (0: none found).
local function use(times)
  local starts = pick(times, min_gap(), mp.get_property_number("duration"))
  if #starts == 0 then remove_ours() return 0 end
  apply(starts)
  return #starts + 1
end

local function cancel(quiet)
  if not job then return false end
  job.cancelled = true
  if job.id and mp.abort_async_command then mp.abort_async_command(job.id) end
  job = nil
  if not quiet then toast("Scene detection cancelled") end
  return true
end

-- Run ffmpeg `ff` (then the next of `rest` when it cannot be started); cb(result | nil).
local function run_scan(list, path, th, mode, cb)
  local ff = table.remove(list, 1)
  if not ff then return cb(nil) end
  local me = job
  me.id = mp.command_native_async({ name = "subprocess", playback_only = false, capture_stderr = true,
    capture_stdout = true, args = scan_args(ff, path, th, mode) },
    function(ok, r)
      if job ~= me or me.cancelled then return end
      if (not r or r.error_string == "init") and #list > 0 then return run_scan(list, path, th, mode, cb) end
      if not r or r.error_string == "init" then return cb(nil) end
      cb(r, ok)
    end)
end

local function detect(manual)
  if superseded then
    if manual then mp.commandv("script-message-to", NEW, "scenes-detect") end
    return
  end
  local path, why = local_video()
  if not path then if manual then toast("Scene detection: " .. why) end return end
  if job then
    if manual then cancel(false) end
    return
  end
  if file_chapters > 0 then
    if manual then toast("This video has its own chapters") end
    return
  end
  local dir = root .. SEP .. key(path)
  local th, mode = threshold(), scan_mode()
  local cached = read_cache(dir)
  drop_old_pictures(dir)
  if cache_fits(cached, th, mode, manual) then
    local n = use(cached.times)
    if manual then toast(n > 0 and string.format("%d scene chapters (cached)", n) or "No scene changes found (cached)") end
    return
  end
  job = { path = path }
  local my = gen
  if manual then toast(mode == "keyframes" and "Detecting scenes (keyframes)…" or "Detecting scenes…") end
  local t0 = mp.get_time()
  local list = { "ffmpeg" }
  if utils.file_info(MANAGED_FF) then list[#list + 1] = MANAGED_FF end
  run_scan(list, path, th, mode, function(r, ok)
    job = nil
    if not r then
      -- Automatic runs say it once per session, not for every video.
      if manual or not ff_warned then
        toast("Scene detection needs ffmpeg (install it, or let Chapter Thumbnails download it)")
      end
      ff_warned = true
      return
    end
    if not ok or r.status ~= 0 then
      local why = ok and ("exit " .. tostring(r.status)) or tostring(r.error_string)
      mp.msg.warn("ffmpeg failed: " .. why .. " " .. tostring(r.stderr):sub(-300))
      if manual then toast("Scene detection failed (ffmpeg " .. why .. ")") end
      return
    end
    local times = parse_scenes(r.stderr)
    write_cache(dir, th, mode, times)
    mp.msg.info(string.format("%d cuts in %.1f s (%s, threshold %.2f)", #times, mp.get_time() - t0, mode, th))
    if my ~= gen or path ~= mp.get_property("path") then return end
    if file_chapters > 0 then return end
    local n = use(times)
    if n > 0 then toast(string.format("%d scene chapters", n))
    elseif manual then toast("No scene changes found (try a lower threshold)") end
  end)
end

local function clear()
  if superseded and #ours == 0 then mp.commandv("script-message-to", NEW, "scenes-forget") return end
  local path = mp.get_property("path")
  local k = path and key(path)
  if not k then toast("Scene detection: play a local video first") return end
  cancel(true)
  local dir = root .. SEP .. k
  for _, f in ipairs(utils.readdir(dir, "files") or {}) do os.remove(dir .. SEP .. f) end
  os.remove(dir)
  local had = remove_ours()
  toast(had and "Scene chapters removed" or "Cached scenes removed")
end

local function on_file_loaded()
  cancel(true)
  gen = gen + 1
  cur_path = mp.get_property("path")
  ours = {}
  file_chapters = #(mp.get_property_native("chapter-list") or {})
  if o.auto then
    local my = gen
    mp.add_timeout(1, function() if my == gen then detect(false) end end)
  end
end

-- Settings changed: a new minimum length (or a threshold with a cached scan) applies to
-- the scenes on screen right away.
local function on_settings()
  if #ours == 0 or job or not cur_path then return end
  local k = key(cur_path)
  local c = k and read_cache(root .. SEP .. k)
  if cache_fits(c, threshold(), scan_mode(), false) then use(c.times) end
end

options.read_options(o, "scene-chapters", on_settings)
mp.register_event("file-loaded", on_file_loaded)
mp.register_event("end-file", function() cancel(true) gen = gen + 1 end)
mp.add_forced_key_binding("Alt+j", "detect", function() detect(true) end)
mp.register_script_message("detect", function() detect(true) end)
mp.register_script_message("clear", clear)

-- Settings of this plugin that differ from the defaults, as Chapters & Previews settings.
local function migrated_settings()
  local out = {}
  if o.auto then out[#out + 1] = { "scenes", "true" } end
  if scan_mode() == "keyframes" then out[#out + 1] = { "scenes-scan", "Keyframes only" } end
  if tostring(o.threshold) ~= "0.4" then out[#out + 1] = { "scenes-threshold", tostring(o.threshold) } end
  if tostring(o.min_gap) ~= "30" then out[#out + 1] = { "scenes-min-length", tostring(o.min_gap) } end
  return out
end

local function on_superseded()
  if superseded then return end
  superseded = true
  cancel(true)
  mp.remove_key_binding("detect")
  local mark = root .. SEP .. "migrated"
  if not utils.file_info(mark) then
    local list = migrated_settings()
    for _, kv in ipairs(list) do mp.commandv("script-message", "vivi-setting", "chapter-thumbnails", kv[1], kv[2]) end
    mkdir(root)
    local f = io.open(mark, "w")
    if f then f:write("settings copied to chapter-thumbnails\n") f:close() end
    if #list > 0 then mp.msg.info(#list .. " setting(s) copied to Chapters & Previews") end
  end
end
mp.register_script_message("scene-chapters-superseded", on_superseded)
mp.commandv("script-message", "scene-chapters-hello") -- in case Chapters & Previews loaded first

if VIVI_TEST then
  return { key = key, parse_scenes = parse_scenes, pick = pick, scan_args = scan_args,
    cache_fits = cache_fits, read_cache = read_cache, write_cache = write_cache, threshold = threshold,
    scan_mode = scan_mode, apply = apply, detect = detect, clear = clear, on_file_loaded = on_file_loaded,
    on_settings = on_settings, opts = o, root = root, ours = function() return ours end,
    running = function() return job end, on_superseded = on_superseded,
    migrated_settings = migrated_settings }
end
