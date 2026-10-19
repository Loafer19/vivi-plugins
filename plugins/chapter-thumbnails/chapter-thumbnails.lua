-- @name Chapters & Previews
-- @version 1.2.0
-- @author Vivi
-- @description Seek-bar hover thumbnails, chapter thumbnails and scene chapters, cached per file (Vivi plugin package).
--
-- Keys: Alt+h  chapter list (titles, times; thumbnails are in the side panel's Chapters tab)
--       Alt+j  detect scene chapters (again while it runs: cancel)
-- Script messages: generate, list, clear, clear-all, scenes-detect, scenes-forget;
-- preview-wanted / vivi-preview-wanted (from Vivi: the pointer went over the seek bar).
--
-- For every local video it writes, with ffmpeg (fast keyframe seeks):
--   plugin-data/chapter-thumbnails/<key>/seek-00.jpg … seek-<n-1>.jpg  192×108, evenly spaced
--   plugin-data/chapter-thumbnails/<key>/seek.meta                     "frames=<n>" once complete
--   plugin-data/chapter-thumbnails/<key>/chapter-<i>.jpg               320 px wide, i from 1
--   plugin-data/chapter-thumbnails/<key>/chapters.meta                 start of each pictured chapter
-- where <key> is the hash of "path|size|mtime" used by Vivi (src/scenes.rs). Vivi shows
-- the seek frames when hovering the seek bar and the chapter images in the Chapters tab
-- (`script-message vivi-preview-frames` / `vivi-chapter-thumbs` tell it to reload). Cached
-- folders are reused when the file is opened again; the least recently used are pruned
-- (max-cache files, max-cache-mb).
--
-- Seek frames: n = one per ~10 s (Auto, 25 to 200) or the chosen count; made coarse to fine
-- on the first seek-bar hover (default) or, with "On open", after 10 s of playback of a
-- video longer than 3 minutes at the lowest CPU / disk priority. Chapter pictures are made
-- when the file opens and when its chapters change.
--
-- Scene chapters (merged from the Scene Chapters plugin 1.1.0, which is deprecated): for
-- local videos without chapters of their own, ffmpeg's scene score
-- (`select='gt(scene,T)',showinfo` on a 160 px wide copy, every frame or keyframes only)
-- marks the cuts; they become "Scene 1", "Scene 2", … at least scenes-min-length seconds
-- apart (also from the start and the end), merged with chapters other plugins add
-- (SponsorBlock). Automatic with `scenes` (off by default), otherwise Alt+J / Video menu.
-- Cache: <key>/scenes.json { version = 2, threshold, scan, times = raw cut times }; the
-- Scene Chapters cache (plugin-data/scene-chapters/<key>/scenes.json, same key) is read too.
--
-- ffmpeg: a system ffmpeg first; otherwise Vivi's media ffmpeg build (about 15 MB with
-- ffprobe, downloaded once and shared with Subtitle Auto-Sync; no AV1).
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

local o = { seekbar = true, chapters = true, when = "On hover", frames = "Auto", ["max-cache"] = "200",
  ["max-cache-mb"] = "500", download = true,
  scenes = false, ["scenes-scan"] = "Every frame", ["scenes-threshold"] = "0.4", ["scenes-min-length"] = "30",
  pkgdir = "" } -- pkgdir: set by Vivi; declared so mp.options does not warn about it

-- ---------- managed helpers (same block in subtitle-sync, chapter-thumbnails, acoustid) ----------
-- A system program is always preferred. Otherwise a pinned build is downloaded once
-- (curl), checked against the sha256 in this file and kept under
-- $XDG_DATA_HOME/vivi/plugin-data/<dir>. Vivi's media ffmpeg build (release
-- helper-ffmpeg-v<build>, ffmpeg-media + ffprobe-media) is shared by the plugins that
-- need video decoding: plugin-data/shared/ffmpeg-media.
local windows = package.config:sub(1, 1) == "\\"
local SEP = windows and "\\" or "/"
local EXE = windows and ".exe" or ""
local HOME = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
local DATA_HOME = os.getenv("XDG_DATA_HOME")
if not DATA_HOME or DATA_HOME == "" then
  DATA_HOME = windows and (os.getenv("APPDATA") or HOME) or (HOME .. "/.local/share")
end
local PLUGIN_DATA = DATA_HOME .. SEP .. "vivi" .. SEP .. "plugin-data"
local FLATPAK = utils.file_info("/.flatpak-info") ~= nil

local function run(args, cb, extra)
  local t = { name = "subprocess", args = args, playback_only = false, capture_stdout = true, capture_stderr = true }
  for k, v in pairs(extra or {}) do t[k] = v end
  return mp.command_native_async(t, function(_, r) cb(r or {}) end)
end

local function mkdir(dir, cb)
  if windows then run({ "cmd", "/c", "if not exist \"" .. dir .. "\" mkdir \"" .. dir .. "\"" }, cb)
  else run({ "mkdir", "-p", dir }, cb) end
end

local function human(n)
  if not n then return "?" end
  if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
  return string.format("%.0f KB", n / 1024)
end

local function sha256(file, cb)
  local function first_hex(s)
    for line in (s or ""):gmatch("[^\r\n]+") do
      local h = line:gsub("%s", ""):lower():match("^(%x+)")
      if h and #h >= 64 then return h:sub(1, 64) end
    end
  end
  if windows then
    return run({ "certutil", "-hashfile", file, "SHA256" }, function(r)
      cb(first_hex((r.stdout or ""):gsub("^[^\n]*\n", "")))
    end)
  end
  run({ "sha256sum", file }, function(r)
    if r.status == 0 then return cb(first_hex(r.stdout)) end
    run({ "shasum", "-a", "256", file }, function(r2) cb(r2.status == 0 and first_hex(r2.stdout) or nil) end)
  end)
end

-- "linux-x86_64", "linux-aarch64", "macos-aarch64", "macos-x86_64", "windows-x86_64", …
local platform_cache
local function platform(cb)
  if platform_cache then return cb(platform_cache) end
  if windows then
    local a = (os.getenv("PROCESSOR_ARCHITEW6432") or os.getenv("PROCESSOR_ARCHITECTURE") or ""):upper()
    platform_cache = a == "ARM64" and "windows-aarch64" or "windows-x86_64"
    return cb(platform_cache)
  end
  run({ "uname", "-sm" }, function(r)
    local s = r.stdout or ""
    local arch = (s:match("x86_64") and "x86_64") or ((s:match("aarch64") or s:match("arm64")) and "aarch64") or "unknown"
    platform_cache = (s:match("Darwin") and "macos-" or s:match("Linux") and "linux-" or "other-") .. arch
    cb(platform_cache)
  end)
end

-- First runnable program called one of `names` in PATH or the usual folders
-- (never inside the Flatpak, whose PATH has no host tools): cb(path | nil, output).
local function find_program(names, args, cb)
  if FLATPAK or os.getenv("VIVI_TEST_NO_SYSTEM_TOOLS") then return cb(nil) end
  local list, seen = {}, {}
  local function add(dir)
    if not dir or dir == "" or dir:find(PLUGIN_DATA, 1, true) then return end
    for _, n in ipairs(names) do
      local p = dir .. SEP .. n .. EXE
      if not seen[p] and utils.file_info(p) then seen[p] = true list[#list + 1] = p end
    end
  end
  for d in (os.getenv("PATH") or ""):gmatch(windows and "[^;]+" or "[^:]+") do add(d) end
  if not windows then
    for _, d in ipairs({ HOME .. "/.local/bin", HOME .. "/.cargo/bin", "/usr/local/bin", "/usr/bin",
                         "/opt/homebrew/bin", "/opt/local/bin", "/snap/bin" }) do add(d) end
  end
  local i = 0
  local function nxt()
    i = i + 1
    if not list[i] then return cb(nil) end
    local a = { list[i] }
    for _, x in ipairs(args) do a[#a + 1] = x end
    run(a, function(r)
      if r.status == 0 then cb(list[i], (r.stdout or "") .. (r.stderr or "")) else nxt() end
    end)
  end
  nxt()
end

local function remote_size(url, cb)
  run({ "curl", "-sIL", url }, function(r)
    local n
    for v in (r.stdout or ""):gmatch("[Cc]ontent%-[Ll]ength:%s*(%d+)") do n = tonumber(v) end
    cb(n)
  end)
end

-- Download `url` into `dir`, verify `sha`; archives (.zip/.tar.gz, `unpack = true`) are
-- unpacked there with tar (bsdtar on Windows 10+ reads zip too). cb(file | nil, err)
local function fetch_verified(what, url, sha, dir, name, unpack, cb)
  mkdir(dir, function()
    local tmp = dir .. SEP .. name .. ".part"
    remote_size(url, function(sz)
      mp.commandv("script-message", "vivi-toast", "Downloading " .. what .. " (" .. human(sz) .. ")…")
      run({ "curl", "-fsSL", "--retry", "2", "-o", tmp, url }, function(r)
        if r.status ~= 0 then os.remove(tmp) return cb(nil, what .. " download failed: " .. (r.stderr or "")) end
        sha256(tmp, function(got)
          if not got then os.remove(tmp) return cb(nil, "no sha256 tool to verify " .. what) end
          if got ~= sha then os.remove(tmp) return cb(nil, what .. " checksum mismatch, not installed") end
          local dst = dir .. SEP .. name
          if unpack then
            run({ "tar", "-xf", tmp, "-C", dir }, function(t)
              os.remove(tmp)
              if t.status ~= 0 then return cb(nil, "could not unpack " .. what .. ": " .. (t.stderr or "")) end
              cb(dst)
            end)
            return
          end
          os.remove(dst)
          local ok, e = os.rename(tmp, dst)
          if not ok then return cb(nil, e) end
          if windows then return cb(dst) end
          run({ "chmod", "755", dst }, function() cb(dst) end)
        end)
      end)
    end)
  end)
end

-- Vivi's media ffmpeg build (helpers/ffmpeg/build.sh FLAVOR=media).
local FF_MEDIA = {
  tag = "helper-ffmpeg-v8.0-2",
  base = "https://github.com/Loafer19/vivi-plugins/releases/download/",
  sha = {
      ["ffmpeg-media-linux-aarch64"] = "a356a2facd9a1bdf420a3dbc5edee6ce7480dff90b0f058dcb7d6259cd6fc707",
      ["ffmpeg-media-linux-x86_64"] = "64cb79d4007f78afaaf3f7cdd126dbc8937857efb4724741296aedba90eb264e",
      ["ffmpeg-media-macos-aarch64"] = "39b1c49229fd237e84e85d9c175a71f05ae4597a1253c2e060a85ac8e78b9548",
      ["ffmpeg-media-windows-x86_64.exe"] = "62d2b260aa526213f4533311e490fc83155d560244ce53d65ba7e5428d5a3f35",
      ["ffprobe-media-linux-aarch64"] = "fad8553efe177d15e95ba79e46347c03172d9e1c4bda309cb9468886a3d3f2e4",
      ["ffprobe-media-linux-x86_64"] = "e1fe69e50aaf4bf82cc41b610a2f3b45cfd37a3735a9516f8cb2d88d38385264",
      ["ffprobe-media-macos-aarch64"] = "03e3f0357a56c6984c6759d3b90c3c2e9b9a7e3384ae5b7a0480572aa731cbe1",
      ["ffprobe-media-windows-x86_64.exe"] = "944b6f8e40d3060023bf9a3faa3ca0878f8fb0e19d1784d5d91454a1545404cc",
  },
}
local FF_DIR = PLUGIN_DATA .. SEP .. "shared" .. SEP .. "ffmpeg-media"

local ff_cache, ff_wait = nil, nil
-- ffmpeg (+ ffprobe) with video decoders: { ffmpeg, ffprobe, kind }. With `need`, the
-- media build is downloaded when there is no system one. cb(ff | nil, err)
local function get_ffmpeg(need, cb)
  if ff_cache then return cb(ff_cache) end
  if ff_wait then ff_wait[#ff_wait + 1] = { need, cb } return end
  ff_wait = { { need, cb } }
  local function finish(f, err)
    ff_cache = f
    local w = ff_wait
    ff_wait = nil
    for _, x in ipairs(w) do x[2](f, err) end
  end
  local managed = { ffmpeg = FF_DIR .. SEP .. "ffmpeg" .. EXE, ffprobe = FF_DIR .. SEP .. "ffprobe" .. EXE, kind = "managed" }
  find_program({ "ffmpeg" }, { "-hide_banner", "-version" }, function(p)
    if p then
      local dir = p:match("^(.*)[/\\][^/\\]+$")
      local probe = dir .. SEP .. "ffprobe" .. EXE
      return finish({ ffmpeg = p, ffprobe = utils.file_info(probe) and probe or "ffprobe", kind = "system" })
    end
    if utils.file_info(managed.ffmpeg) and utils.file_info(managed.ffprobe) then return finish(managed) end
    local any = false
    for _, x in ipairs(ff_wait) do any = any or x[1] end
    if not any then return finish(nil, "no ffmpeg") end
    platform(function(plat)
      local files = {}
      for _, prog in ipairs({ "ffmpeg", "ffprobe" }) do
        local asset = prog .. "-media-" .. plat .. EXE
        if not FF_MEDIA.sha[asset] then return finish(nil, "no ffmpeg build for " .. plat .. " yet; install ffmpeg") end
        files[#files + 1] = { prog, asset }
      end
      local function nxt(i)
        local f = files[i]
        if not f then return finish(managed) end
        fetch_verified("ffmpeg (" .. f[1] .. ")", FF_MEDIA.base .. FF_MEDIA.tag .. "/" .. f[2], FF_MEDIA.sha[f[2]],
          FF_DIR, f[1] .. EXE, false, function(ok, e)
            if not ok then return finish(nil, e) end
            nxt(i + 1)
          end)
      end
      nxt(1)
    end)
  end)
end
-- ---------- end of managed helpers ----------

local ROOT = PLUGIN_DATA .. SEP .. "chapter-thumbnails"
local SEEK_W, SEEK_H = 192, 108
local ON_OPEN_DELAY = 10  -- s of playback before "On open" starts
local ON_OPEN_MIN = 180   -- "On open" only for videos longer than this (s)
local WORKERS = 2         -- ffmpeg processes at a time

-- Vivi's own toast (no mpv OSD text over the video). `secs` is ignored: Vivi times its toasts.
local function toast(msg, secs) mp.commandv("script-message", "vivi-toast", msg) end

-- Same key as Vivi's scenes::key: 32-bit "h*33 + byte" hash of path|size|mtime, hex.
local function key(path)
  local fi = utils.file_info(path)
  if not fi then return nil end
  local s = path .. "|" .. tostring(fi.size) .. "|" .. tostring(math.floor(fi.mtime or 0))
  local h = 5381
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
  return string.format("%08x", h)
end

-- Number of seek-bar frames for a file: "Auto" is one every ~10 s, 25 to 200; a number is
-- used as is (10 to 200). Never more than one per second of video, never fewer than the 10
-- Vivi needs.
local function frame_count(duration, choice)
  local n = tonumber(choice)
  if not n then n = math.max(25, math.min(200, math.floor(duration / 10 + 0.5))) end
  n = math.max(10, math.min(200, n))
  return math.max(10, math.min(n, math.floor(duration)))
end

-- Times (s) of the seek-bar frames: centre of each of `n` equal slices.
local function seek_times(duration, n)
  local t = {}
  for i = 0, n - 1 do t[#t + 1] = duration * (i + 0.5) / n end
  return t
end

-- Frame indices coarse to fine (every 16th first, then every 8th, …), so a few spread-out
-- frames are ready first and the preview fills in.
local function order(n)
  local function level(i) for k, s in ipairs({ 16, 8, 4, 2 }) do if i % s == 0 then return k end end return 5 end
  local v = {}
  for i = 0, n - 1 do v[#v + 1] = i end
  table.sort(v, function(a, b)
    local la, lb = level(a), level(b)
    if la ~= lb then return la < lb end
    return a < b
  end)
  return v
end

local function frame_args(ff, path, t, out, w, h)
  local vf = h and string.format("scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2", w, h, w, h)
    or string.format("scale=%d:-2", w)
  return { ff, "-nostdin", "-v", "error", "-y", "-skip_frame", "nokey", "-ss", string.format("%.2f", t),
    "-i", path, "-an", "-sn", "-dn", "-frames:v", "1", "-vf", vf, "-q:v", "5", out }
end

-- Prefix a command with `nice -n 19` / `ionice -c3` (lowest CPU and disk priority) when
-- those programs exist (Linux, macOS has nice only).
local function low_priority(args, nice, ionice)
  local a = {}
  if nice then a[#a + 1] = nice a[#a + 1] = "-n" a[#a + 1] = "19" end
  if ionice then a[#a + 1] = ionice a[#a + 1] = "-c3" end
  for _, x in ipairs(args) do a[#a + 1] = x end
  return a
end
local NICE, IONICE
if not windows then
  for _, d in ipairs({ "/usr/bin/", "/bin/" }) do
    NICE = NICE or (utils.file_info(d .. "nice") and d .. "nice") or nil
    IONICE = IONICE or (utils.file_info(d .. "ionice") and d .. "ionice") or nil
  end
end

-- Video codecs (mpv's `codec` names) Vivi's media ffmpeg build decodes; anything else
-- (AV1, VC-1, ProRes, …) needs a system ffmpeg.
local MEDIA_CODECS = { h264 = true, hevc = true, vp8 = true, vp9 = true, mpeg1video = true,
  mpeg2video = true, mpeg4 = true, mjpeg = true }
local function managed_decodes(codec) return codec == nil or codec == "" or MEDIA_CODECS[codec] == true end

-- Which cache folders to delete: `list` = { { name, mtime, bytes } }, newest kept first
-- while under both limits; `keep` (the current file's folder) is never deleted.
local function select_prune(list, max_files, max_bytes, keep)
  table.sort(list, function(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end)
  local out, files, bytes = {}, 0, 0
  for _, d in ipairs(list) do
    if d[1] == keep then files, bytes = files + 1, bytes + d[3] end
  end
  for _, d in ipairs(list) do
    if d[1] ~= keep then
      if files < max_files and bytes + d[3] <= max_bytes then
        files, bytes = files + 1, bytes + d[3]
      else
        out[#out + 1] = d[1]
      end
    end
  end
  return out
end

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

-- Write via a temporary file and rename, so a reader never sees half a file (and the
-- folder's mtime records the use, for pruning).
local function write_file(p, data)
  local tmp = p .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write(data)
  f:close()
  os.remove(p)
  return os.rename(tmp, p) ~= nil
end

local function seek_name(dir, k) return string.format("%s%sseek-%02d.jpg", dir, SEP, k) end
local function chap_name(dir, i) return string.format("%s%schapter-%d.jpg", dir, SEP, i) end
local function chap_line(t) return string.format("%.2f", t) end

-- Every seek frame must exist (Vivi maps the hover position onto the frame count):
-- a missing one borrows its nearest earlier (or later) neighbour.
local function fill_gaps(dir, n)
  for k = 0, n - 1 do
    if not utils.file_info(seek_name(dir, k)) then
      for d = 1, n do
        local src = (k - d >= 0 and utils.file_info(seek_name(dir, k - d)) and seek_name(dir, k - d))
          or (k + d < n and utils.file_info(seek_name(dir, k + d)) and seek_name(dir, k + d))
        if src then
          local data = read_file(src)
          if data then write_file(seek_name(dir, k), data) end
          break
        end
      end
    end
  end
end

-- Frames of `dir` the last complete run made: seek.meta holds "frames=<n>".
local function seek_done(dir)
  return tonumber(((read_file(dir .. SEP .. "seek.meta") or ""):match("frames=(%d+)")))
end

-- Seek frames of another count (or from 1.0.x, which kept them across count changes) would
-- be mapped onto the wrong times: they are deleted before new ones are made.
local function clear_seek(dir)
  os.remove(dir .. SEP .. "seek.meta")
  for _, f in ipairs(utils.readdir(dir, "files") or {}) do
    if f:match("^seek%-%d+%.jpg$") or f:match("^seek%-%d+%.part%.jpg$") then os.remove(dir .. SEP .. f) end
  end
end

local function rm(p, cb)
  if windows then run({ "cmd", "/c", "rmdir", "/s", "/q", p }, cb or function() end)
  else run({ "rm", "-rf", p }, cb or function() end) end
end

local function dir_size(p)
  local n = 0
  for _, f in ipairs(utils.readdir(p, "files") or {}) do
    local fi = utils.file_info(p .. SEP .. f)
    n = n + (fi and fi.size or 0)
  end
  return n
end

-- ---------- job queue ----------
local gen = 0       -- bumped on every file so stale jobs stop
local queue, running, inflight = {}, 0, {}

-- One frame: ffmpeg writes <out>.part.jpg, renamed over <out> when it worked. A job whose
-- keyframe-only seek produced nothing (past the last keyframe) is retried once with
-- normal decoding. j.done(ok) afterwards.
local pump
local function start_job(j)
  running = running + 1
  local tmp = j.out:gsub("%.jpg$", ".part.jpg")
  local args = {}
  for _, x in ipairs(j.args) do args[#args + 1] = (x == j.out) and tmp or x end
  local function go(a, retry)
    local id, finished
    id = run(a, function()
      finished = true
      if id then inflight[id] = nil end
      if j.gen ~= gen then os.remove(tmp) running = running - 1 return pump() end
      if not utils.file_info(tmp) and retry then
        local b = {}
        for _, x in ipairs(a) do if x ~= "-skip_frame" and x ~= "nokey" then b[#b + 1] = x end end
        return go(b, false)
      end
      local ok = false
      if utils.file_info(tmp) then
        os.remove(j.out)
        ok = os.rename(tmp, j.out) ~= nil
      end
      running = running - 1
      if j.done then j.done(ok) end
      pump()
    end)
    if id and not finished then inflight[id] = true end
  end
  go(args, true)
end

pump = function()
  while running < WORKERS and #queue > 0 do
    local j = table.remove(queue, 1)
    if j.gen == gen then start_job(j) end
  end
end

-- New file / cleared cache: drop queued frames and stop the running ffmpegs.
local function stop_all()
  gen = gen + 1
  queue = {}
  if mp.abort_async_command then
    for id in pairs(inflight) do mp.abort_async_command(id) end
  end
  inflight = {}
end

-- ---------- per file ----------
-- cur: { path, dir, duration, n, codec } of the video being played (nil otherwise).
-- seek_state: nil (not started), "running", "done"; chap_running / chap_again likewise.
local cur, seek_state, chap_running, chap_again, played, tick_timer
local codec_warned = {}

local function local_video()
  local path = mp.get_property("path")
  if not path or path:find("://") or not utils.file_info(path) then return nil end
  for _, t in ipairs(mp.get_property_native("track-list") or {}) do
    if t.type == "video" and not t.albumart and not t.image then return path, t.codec end
  end
  return nil
end

-- Remove the least recently used cache folders beyond max-cache files / max-cache-mb.
local function prune()
  local list = {}
  for _, d in ipairs(utils.readdir(ROOT, "dirs") or {}) do
    local p = ROOT .. SEP .. d
    local fi = utils.file_info(p)
    list[#list + 1] = { d, fi and fi.mtime or 0, dir_size(p) }
  end
  local keepname = cur and cur.dir and cur.dir:match("[^/\\]+$")
  local mb = tonumber(o["max-cache-mb"]) or 500
  for _, d in ipairs(select_prune(list, tonumber(o["max-cache"]) or 200, mb * 1048576, keepname)) do
    rm(ROOT .. SEP .. d)
  end
end

-- ffmpeg that can decode this file: cb(ff), or cb(nil) after telling why (when `loud`, or
-- once per codec). Nothing when the file changed meanwhile.
local function ffmpeg_for(file, loud, cb)
  get_ffmpeg(o.download, function(ff, err)
    if cur ~= file then return end
    if not ff then
      if loud or o.download then toast("Thumbnails need ffmpeg: " .. tostring(err), 6) end
      return cb(nil)
    end
    if ff.kind == "managed" and not managed_decodes(file.codec) then
      if loud or not codec_warned[file.codec] then
        codec_warned[file.codec] = true
        toast("Thumbnails: " .. file.codec:upper() .. " video needs ffmpeg installed on the system", 6)
      end
      return cb(nil)
    end
    cb(ff)
  end)
end

local function publish_seek(file) mp.commandv("script-message", "vivi-preview-frames", file.dir) end

-- Seek-bar frames of the current file (coarse to fine). `low`: lowest priority (On open).
local function start_seek(manual, low)
  local file = cur
  if not file or not o.seekbar then
    if manual and not file then toast("Thumbnails: play a local video first") end
    return
  end
  if seek_state == "done" then if manual then toast("Thumbnails are up to date") end return end
  if seek_state == "running" then return end
  seek_state = "running"
  ffmpeg_for(file, manual, function(ff)
    if not ff then seek_state = nil return end
    mkdir(file.dir, function()
      if cur ~= file then return end
      clear_seek(file.dir)
      local n, my, t0 = file.n, gen, mp.get_time()
      local times = seek_times(file.duration, n)
      local done, good = 0, 0
      local marks = { [4] = true, [math.ceil(n / 4)] = true, [math.ceil(n / 2)] = true }
      for _, k in ipairs(order(n)) do
        local out = seek_name(file.dir, k)
        local args = frame_args(ff.ffmpeg, file.path, times[k + 1], out, SEEK_W, SEEK_H)
        queue[#queue + 1] = { gen = my, out = out, args = low and low_priority(args, NICE, IONICE) or args,
          done = function(ok)
            done = done + 1
            if ok then good = good + 1 end
            if done < n then
              if marks[done] and good > 0 then fill_gaps(file.dir, n) publish_seek(file) end
              return
            end
            if good == 0 then
              seek_state = nil
              if manual then toast("Thumbnails: ffmpeg could not read this video", 5) end
              return
            end
            fill_gaps(file.dir, n)
            write_file(file.dir .. SEP .. "seek.meta", "frames=" .. n .. "\n")
            seek_state = "done"
            publish_seek(file)
            mp.msg.info(string.format("%d seek-bar thumbnails in %.1f s (%s ffmpeg)", n, mp.get_time() - t0, ff.kind))
            if manual then toast(string.format("%d seek-bar thumbnails generated", n)) end
            prune()
          end }
      end
      pump()
    end)
  end)
end

-- Chapter pictures: those missing or made for another start time (chapters.meta has one
-- start per line), e.g. after Scene Chapters or SponsorBlock added chapters.
local function start_chapters(manual)
  local file = cur
  if not file or not o.chapters then return end
  if chap_running then chap_again = true return end
  local list = mp.get_property_native("chapter-list") or {}
  local meta_path = file.dir .. SEP .. "chapters.meta"
  local old = {}
  for l in (read_file(meta_path) or ""):gmatch("[^\n]+") do old[#old + 1] = l end
  local lines, todo = {}, {}
  for i, c in ipairs(list) do
    local t = math.min(c.time + 1, math.max(0, file.duration - 1))
    lines[i] = chap_line(c.time)
    if old[i] ~= lines[i] or not utils.file_info(chap_name(file.dir, i)) then todo[#todo + 1] = { i = i, t = t } end
  end
  if #todo == 0 then
    if #list > 0 then mp.commandv("script-message", "vivi-chapter-thumbs", file.dir) end
    return
  end
  chap_running, chap_again = true, false
  local function finish()
    chap_running = false
    if cur == file and chap_again then chap_again = false start_chapters(false) end
  end
  ffmpeg_for(file, manual, function(ff)
    if not ff then return finish() end
    mkdir(file.dir, function()
      if cur ~= file then return end
      local left, my = #todo, gen
      local jobs = {}
      for _, c in ipairs(todo) do
        local out = chap_name(file.dir, c.i)
        jobs[#jobs + 1] = { gen = my, out = out, args = frame_args(ff.ffmpeg, file.path, c.t, out, 320),
          done = function(ok)
            if not ok then lines[c.i] = "-" end
            left = left - 1
            if left > 0 then return end
            write_file(meta_path, table.concat(lines, "\n") .. "\n")
            mp.commandv("script-message", "vivi-chapter-thumbs", file.dir)
            if manual then toast(string.format("%d chapter thumbnails generated", #todo)) end
            finish()
          end }
      end
      -- Chapters first: few, and shown in the side panel right away.
      for k = #jobs, 1, -1 do table.insert(queue, 1, jobs[k]) end
      pump()
    end)
  end)
end

local function on_tick()
  if not tick_timer then return end
  if not cur or seek_state then tick_timer:kill() tick_timer = nil return end
  if mp.get_property_bool("pause", false) or mp.get_property_bool("seeking", false) then return end
  played = (played or 0) + 1
  if played >= ON_OPEN_DELAY then
    tick_timer:kill()
    tick_timer = nil
    start_seek(false, true)
  end
end

local function on_open_mode() return tostring(o.when):lower():find("open", 1, true) ~= nil end

-- A file was loaded (or the settings changed): cached frames are shown at once; missing
-- chapter pictures are made now; seek frames on the first seek-bar hover, or with
-- "On open" after 10 s of playback of a video longer than 3 minutes.
local function on_file_loaded()
  stop_all()
  if tick_timer then tick_timer:kill() tick_timer = nil end
  cur, seek_state, chap_running, chap_again, played = nil, nil, false, false, 0
  local path, codec = local_video()
  if not path then return end
  local duration = mp.get_property_number("duration", 0)
  if duration <= 1 then return end
  cur = { path = path, dir = ROOT .. SEP .. key(path), duration = duration,
    n = frame_count(duration, o.frames), codec = codec }
  if o.seekbar then
    if seek_done(cur.dir) == cur.n and utils.file_info(seek_name(cur.dir, cur.n - 1)) then
      seek_state = "done"
      write_file(cur.dir .. SEP .. "seek.meta", "frames=" .. cur.n .. "\n") -- marks the folder as used
      publish_seek(cur)
    else
      clear_seek(cur.dir)
      if on_open_mode() and duration > ON_OPEN_MIN then tick_timer = mp.add_periodic_timer(1, on_tick) end
    end
  end
  start_chapters(false)
end

local function fmt_time(t)
  t = math.floor(t or 0)
  local h, m, s = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

local function chapter_list()
  local list = mp.get_property_native("chapter-list") or {}
  if #list == 0 then toast("This file has no chapters (Scene Chapters can detect scenes)") return end
  local now = mp.get_property_number("chapter", -1) + 1
  local lines = {}
  for i, c in ipairs(list) do
    lines[#lines + 1] = string.format("%s%s  %s", i == now and "▶ " or "   ", fmt_time(c.time),
      (c.title and c.title ~= "") and c.title or ("Chapter " .. i))
  end
  mp.osd_message(table.concat(lines, "\n"), 6)
end

local function generate()
  if not cur then toast("Thumbnails: play a local video first") return end
  start_chapters(true)
  start_seek(true, false)
end

local function clear()
  local file = cur
  if not file then toast("Thumbnails: play a local video first") return end
  stop_all()
  seek_state, chap_running, chap_again = nil, false, false
  rm(file.dir, function() toast("Thumbnails of this file deleted") end)
end

local function clear_all()
  stop_all()
  seek_state, chap_running, chap_again = nil, false, false
  local dirs = utils.readdir(ROOT, "dirs") or {}
  local bytes = 0
  for _, d in ipairs(dirs) do bytes = bytes + dir_size(ROOT .. SEP .. d) end
  local left = #dirs
  if left == 0 then toast("The thumbnail cache is empty") return end
  for _, d in ipairs(dirs) do
    rm(ROOT .. SEP .. d, function()
      left = left - 1
      if left == 0 then toast(string.format("Deleted the thumbnails of %d file%s (%s)", #dirs, #dirs == 1 and "" or "s", human(bytes))) end
    end)
  end
end

-- ---------- scene chapters ----------
-- Threshold and minimum length from the settings, kept in a sane range.
local function scene_threshold()
  return math.max(0.05, math.min(0.95, tonumber(o["scenes-threshold"]) or 0.4))
end
local function scene_gap() return math.max(1, tonumber(o["scenes-min-length"]) or 30) end
local function scene_mode() return tostring(o["scenes-scan"]):lower():find("key", 1, true) and "keyframes" or "full" end

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
local function pick_scenes(times, gap, duration)
  local out, last = {}, 0
  for _, t in ipairs(times or {}) do
    if t - last >= gap and not (duration and duration > 0 and duration - t < gap) then
      out[#out + 1] = t
      last = t
    end
  end
  return out
end

local function scene_args(ff, path, th, mode)
  local a = { ff, "-nostdin", "-hide_banner" }
  if mode == "keyframes" then a[#a + 1] = "-skip_frame" a[#a + 1] = "nokey" end
  for _, x in ipairs({ "-i", path, "-an", "-sn", "-dn",
    "-vf", string.format("scale=160:-2,select='gt(scene,%.2f)',showinfo", th), "-f", "null", "-" }) do
    a[#a + 1] = x
  end
  return low_priority(a, NICE, IONICE)
end

-- scenes.json of a folder: v2 table, a Scene Chapters 1.0.x list ({ legacy = true }) or nil.
local function read_scenes(dir)
  local d = read_file(dir .. SEP .. "scenes.json")
  local v = d and utils.parse_json(d)
  if type(v) ~= "table" then return nil end
  if v.version == 2 and type(v.times) == "table" then return v end
  if #v > 0 or next(v) == nil then return { legacy = true, times = v } end
  return nil
end
-- Own cache first, then the deprecated Scene Chapters plugin's (same key).
local function scene_cache(file)
  return read_scenes(file.dir)
    or read_scenes(PLUGIN_DATA .. SEP .. "scene-chapters" .. SEP .. file.dir:match("[^/\\]+$"))
end

-- Is the cache good for a scan with threshold `th` and `mode`? A full scan also serves
-- "Keyframes only". Scene Chapters 1.0.x lists (no threshold recorded) only for automatic runs.
local function scene_cache_fits(c, th, mode, manual)
  if not c then return false end
  if c.legacy then return not manual end
  return math.abs((tonumber(c.threshold) or -1) - th) < 0.001 and (c.scan == mode or c.scan == "full")
end

-- State of the current file: chapters the file itself has (counted when it loaded), the
-- scene chapters we added, the running scan.
local file_chapters, ours, scan_job, scene_gen, scene_ff_warned = 0, {}, nil, 0, false

local function is_ours(c)
  for _, x in ipairs(ours) do
    if c.title == x.title and math.abs((c.time or -1) - x.time) < 0.001 then return true end
  end
  return false
end

-- Put `starts` in as "Scene 1" (at 0), "Scene 2", …, replacing the scenes added before and
-- keeping every other chapter (SponsorBlock's), sorted by time.
local function apply_scenes(starts)
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

local function remove_scenes()
  if #ours == 0 then return false end
  local list = {}
  for _, c in ipairs(mp.get_property_native("chapter-list") or {}) do
    if not is_ours(c) then list[#list + 1] = c end
  end
  ours = {}
  mp.set_property_native("chapter-list", list)
  return true
end

-- Chapters from cut times; returns how many scene chapters there are (0: none found).
local function use_scenes(times)
  local starts = pick_scenes(times, scene_gap(), mp.get_property_number("duration"))
  if #starts == 0 then remove_scenes() return 0 end
  apply_scenes(starts)
  return #starts + 1
end

local function cancel_scan(quiet)
  if not scan_job then return false end
  scan_job.cancelled = true
  if scan_job.id and mp.abort_async_command then mp.abort_async_command(scan_job.id) end
  scan_job = nil
  if not quiet then toast("Scene detection cancelled") end
  return true
end

local function detect_scenes(manual)
  local file = cur
  if not file then
    if manual then
      local path = mp.get_property("path")
      toast((path and path:find("://")) and "Scene detection: local files only" or "Scene detection: play a local video first")
    end
    return
  end
  if scan_job then
    if manual then cancel_scan(false) end
    return
  end
  if file_chapters > 0 then
    if manual then toast("This video has its own chapters") end
    return
  end
  local th, mode = scene_threshold(), scene_mode()
  local cached = scene_cache(file)
  if scene_cache_fits(cached, th, mode, manual) then
    local n = use_scenes(cached.times)
    if manual then toast(n > 0 and string.format("%d scene chapters (cached)", n) or "No scene changes found (cached)") end
    return
  end
  local me, my, t0 = { path = file.path }, scene_gen, mp.get_time()
  scan_job = me
  if manual then toast(mode == "keyframes" and "Detecting scenes (keyframes)…" or "Detecting scenes…") end
  -- Not ffmpeg_for: a settings change replaces `cur` (same path) while this runs.
  get_ffmpeg(o.download, function(ff, err)
    if scan_job ~= me or me.cancelled then return end
    if not ff then
      scan_job = nil
      -- Automatic runs say it once per session, not for every video.
      if manual or not scene_ff_warned then toast("Scene detection needs ffmpeg: " .. tostring(err), 6) end
      scene_ff_warned = true
      return
    end
    if ff.kind == "managed" and not managed_decodes(file.codec) then
      scan_job = nil
      if manual then toast("Scene detection: " .. tostring(file.codec):upper() .. " video needs ffmpeg installed on the system", 6) end
      return
    end
    me.id = mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
      capture_stderr = true, args = scene_args(ff.ffmpeg, file.path, th, mode) },
      function(ok, r)
        if scan_job ~= me or me.cancelled then return end
        scan_job = nil
        r = r or {}
        if not ok or r.status ~= 0 then
          local why = ok and ("exit " .. tostring(r.status)) or tostring(r.error_string)
          mp.msg.warn("scene scan failed: " .. why .. " " .. tostring(r.stderr):sub(-300))
          if manual then toast("Scene detection failed (ffmpeg " .. why .. ")") end
          return
        end
        local times = parse_scenes(r.stderr)
        mkdir(file.dir, function()
          write_file(file.dir .. SEP .. "scenes.json",
            utils.format_json({ version = 2, threshold = th, scan = mode, times = times }))
        end)
        mp.msg.info(string.format("%d cuts in %.1f s (%s, threshold %.2f, %s ffmpeg)", #times,
          mp.get_time() - t0, mode, th, ff.kind))
        if my ~= scene_gen or not cur or cur.path ~= file.path or file_chapters > 0 then return end
        local n = use_scenes(times)
        if n > 0 then toast(string.format("%d scene chapters", n))
        elseif manual then toast("No scene changes found (try a lower threshold)") end
      end)
  end)
end

-- Remove the scene chapters and forget this file's scan (thumbnails stay).
local function forget_scenes()
  if not cur then toast("Scene detection: play a local video first") return end
  cancel_scan(true)
  os.remove(cur.dir .. SEP .. "scenes.json")
  os.remove(PLUGIN_DATA .. SEP .. "scene-chapters" .. SEP .. cur.dir:match("[^/\\]+$") .. SEP .. "scenes.json")
  toast(remove_scenes() and "Scene chapters removed" or "Cached scenes removed")
end

-- After on_file_loaded (file-loaded only, not on settings changes): count the file's own
-- chapters, maybe start the automatic scan.
local function scenes_file_loaded()
  cancel_scan(true)
  scene_gen = scene_gen + 1
  ours = {}
  file_chapters = #(mp.get_property_native("chapter-list") or {})
  if o.scenes and cur then
    local my = scene_gen
    mp.add_timeout(1, function() if my == scene_gen then detect_scenes(false) end end)
  end
end

-- Settings changed: a new minimum length (or a threshold with a cached scan) applies to
-- the scenes on screen right away.
local function scenes_settings()
  if #ours == 0 or scan_job or not cur then return end
  local c = scene_cache(cur)
  if scene_cache_fits(c, scene_threshold(), scene_mode(), false) then use_scenes(c.times) end
end

-- Settings changed: start over for the current file; frames that were wanted (hovered or
-- being made) are made again with the new settings.
options.read_options(o, "chapter-thumbnails", function()
  if not mp.get_property("path") then return end
  local wanted = seek_state ~= nil
  on_file_loaded()
  if wanted and cur and not seek_state then start_seek(false, false) end
  scenes_settings()
end)
mp.register_event("file-loaded", function() on_file_loaded() scenes_file_loaded() end)
mp.register_event("start-file", function()
  stop_all()
  cancel_scan(true)
  scene_gen = scene_gen + 1
  if tick_timer then tick_timer:kill() tick_timer = nil end
  cur, seek_state = nil, nil
end)
-- Chapters can arrive later (Scene Chapters, SponsorBlock): make their images too.
mp.observe_property("chapter-list", "native", function()
  if cur and cur.path == mp.get_property("path") then start_chapters(false) end
end)
-- Vivi asks when the pointer first goes over the seek bar of a file.
local function hover() if cur and not seek_state then start_seek(false, false) end end
mp.register_script_message("preview-wanted", hover)
mp.register_script_message("vivi-preview-wanted", hover)
mp.add_forced_key_binding("Alt+h", "list", chapter_list)
mp.register_script_message("generate", generate)
mp.register_script_message("list", chapter_list)
mp.register_script_message("clear", clear)
mp.register_script_message("clear-all", clear_all)
mp.add_forced_key_binding("Alt+j", "scenes-detect", function() detect_scenes(true) end)
mp.register_script_message("scenes-detect", function() detect_scenes(true) end)
mp.register_script_message("scenes-forget", forget_scenes)
-- The deprecated Scene Chapters plugin steps aside (no second Alt+J, no second automatic
-- scan) when it hears this; it asks with scene-chapters-hello if it loaded after us.
mp.commandv("script-message", "scene-chapters-superseded")
mp.register_script_message("scene-chapters-hello", function() mp.commandv("script-message", "scene-chapters-superseded") end)

if VIVI_TEST then
  return { key = key, seek_times = seek_times, frame_args = frame_args, fmt_time = fmt_time,
    frame_count = frame_count, order = order, low_priority = low_priority, managed_decodes = managed_decodes,
    select_prune = select_prune, on_file_loaded = on_file_loaded, on_tick = on_tick, hover = hover,
    queue = function() return queue end, state = function() return cur, seek_state end,
    set_ffmpeg = function(f) ff_cache = f end,
    parse_scenes = parse_scenes, pick_scenes = pick_scenes, scene_args = scene_args,
    scene_cache_fits = scene_cache_fits, read_scenes = read_scenes, scene_threshold = scene_threshold,
    scene_mode = scene_mode, apply_scenes = apply_scenes, detect_scenes = detect_scenes,
    forget_scenes = forget_scenes, scenes_file_loaded = scenes_file_loaded, scenes_settings = scenes_settings,
    opts = o, scanning = function() return scan_job end, ours = function() return ours end }
end
