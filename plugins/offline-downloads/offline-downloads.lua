-- @name Offline Downloads
-- @version 1.1.4
-- @author Vivi
-- @description Download queue for YouTube/yt-dlp sites, direct music files (Jamendo, Internet Archive, …) and radio streams (Vivi plugin package).
--
-- Keys: Alt+d   add the URL in the clipboard (or the playing URL) to the queue
--       Alt+D   show the queue (Alt+Shift+d)
-- Script messages: add, add-current, add-clipboard, enqueue <url>, record [url] (a radio /
--                  live recording of the URL, else the playing stream, else the clipboard
--                  URL), show, pause, cancel, retry,
--                  clear-done, open-folder, pick-folder, info; from Vivi's Downloads
--                  panel: download-pause / download-resume / download-cancel /
--                  download-retry <job id>; stop (end the active recording and keep
--                  it), discard (end it and delete what was recorded).
--
-- One item downloads at a time; the queue (pending / active / paused / done / failed)
-- is kept in plugin-data/offline-downloads/queue.json and survives restarts.
--
-- Vivi 0.13+ has a shared Downloads panel (Library -> Downloads) and sets the property
-- user-data/vivi/downloads to 1. Every queue change is then reported to it with
-- `script-message vivi-download offline-downloads <job id> <json>`, its row buttons call
-- back with the download-* messages above, and Show / Alt+Shift+D open the panel
-- instead of the OSD list. Older Vivi ignores the reports and keeps the OSD queue.
--
-- How an URL is fetched:
--   * direct media files (.mp3 .ogg .flac .opus .m4a .mp4 .mkv …, Jamendo/Internet
--     Archive download links, or any URL whose Content-Type is audio/video with a known
--     length): curl, resumable (curl -C -). Progress = bytes on disk / Content-Length.
--   * live radio (Icecast/Shoutcast, audio without Content-Length, .pls/.m3u lists, or
--     the playing item when mpv shows it is a live stream): recorded for the "Radio
--     recording length" setting with curl --max-time.
--     HLS (.m3u8) needs ffmpeg (system, or one another Vivi plugin already downloaded).
--   * anything else (YouTube, Jamendo/IA pages, SoundCloud, Bandcamp, …): yt-dlp. When
--     yt-dlp turns out to be recording a live stream (it says so, or an unknown site
--     sends no size), it is a recording too.
-- Streams are probed with a short GET (a 1-byte range, at most 4 KB read): many
-- Icecast servers refuse HEAD requests. Every recording is capped at the set length, also
-- under yt-dlp. Stopping one (the length is reached, Cancel in the panel, "stop") ends
-- the tool with SIGTERM by its exact pid so it closes the file, and keeps the recording
-- as a finished download with its length; only "discard" deletes it.
--
-- yt-dlp: a system yt-dlp is used, else the copy the YouTube & yt-dlp plugin manages
-- (plugin-data/youtube/bin). This plugin never downloads its own yt-dlp or ffmpeg; it
-- only reuses ffmpeg found on the system or already installed by the YouTube plugin
-- (plugin-data/youtube/ffmpeg) or the shared media build (plugin-data/shared/ffmpeg-media).
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

local o = { url = "", folder = "", ["radio-minutes"] = "30", ["video-quality"] = "Best single file" }
options.read_options(o, "offline-downloads")

local windows = package.config:sub(1, 1) == "\\"
local SEP = windows and "\\" or "/"
local EXE = windows and ".exe" or ""
local HOME = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
local DATA_HOME = os.getenv("XDG_DATA_HOME")
if not DATA_HOME or DATA_HOME == "" then
  DATA_HOME = windows and (os.getenv("APPDATA") or HOME) or (HOME .. "/.local/share")
end
local PLUGIN_DATA = DATA_HOME .. SEP .. "vivi" .. SEP .. "plugin-data"
local DIR = PLUGIN_DATA .. SEP .. "offline-downloads"
local QUEUE = DIR .. SEP .. "queue.json"
local FLATPAK = utils.file_info("/.flatpak-info") ~= nil
local TMP = os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp"

local function run(args, cb)
  return mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
    capture_stdout = true, capture_stderr = true }, function(_, r) cb(r or {}) end)
end

-- Long downloads (curl, yt-dlp, ffmpeg) run under a small sh watchdog, so they stop when
-- Vivi goes away without telling its scripts (quitting on Vivi before 0.13, a crash, a
-- kill) and when mpv kills the wrapper on pause / cancel / quit: the tool and its own
-- children (yt-dlp's ffmpeg) get SIGTERM. $1 = Vivi's pid, $2 = file for the tool's
-- stdout + stderr ("" = keep mpv's capture pipes), $3 = file that gets the tool's pid
-- ("" = none; used to stop a recording gracefully). Not on Windows (no sh).
local GUARD = [[vp=$1; log=$2; pf=$3; shift 3
if [ -n "$log" ]; then "$@" >"$log" 2>&1 & else "$@" & fi
c=$!
if [ -n "$pf" ]; then echo "$c" >"$pf"; fi
( while kill -0 "$c" 2>/dev/null; do
    if ! kill -0 "$vp" 2>/dev/null || ! kill -0 "$PPID_SH" 2>/dev/null; then
      pkill -TERM -P "$c" 2>/dev/null; kill -TERM "$c" 2>/dev/null; exit 0
    fi
    sleep 1
  done ) >/dev/null 2>&1 &
w=$!
wait "$c"; r=$?
kill "$w" 2>/dev/null
exit $r]]

local function guarded(args, log, pidfile)
  if windows then return args end
  local pid = mp.get_property("pid", "")
  if not pid or not pid:match("^%d+$") or pid == "0" then pid = "1" end
  local w = { "sh", "-c", "PPID_SH=$$; " .. GUARD, "sh", pid, log or "", pidfile or "" }
  for _, x in ipairs(args) do w[#w + 1] = x end
  return w
end

-- Graceful stop of a guarded tool by the exact pid in $1 (a file): its children first
-- (yt-dlp's ffmpeg finishes the file on SIGTERM), up to 5 s for them, then the tool.
local STOP = [[p=$(cat "$1" 2>/dev/null)
case "$p" in ''|*[!0-9]*) exit 1;; esac
pkill -TERM -P "$p" 2>/dev/null
i=0
while pgrep -P "$p" >/dev/null 2>&1 && [ $i -lt 20 ]; do sleep 0.25; i=$((i+1)); done
kill -TERM "$p" 2>/dev/null
exit 0]]

local function toast(msg, secs)
  mp.osd_message(msg, secs or 4)
  mp.commandv("script-message", "vivi-toast", msg)
end

local function mkdir(dir, cb)
  if windows then run({ "cmd", "/c", "if not exist \"" .. dir .. "\" mkdir \"" .. dir .. "\"" }, cb)
  else run({ "mkdir", "-p", dir }, cb) end
end

local function human(n)
  if not n then return "?" end
  if n >= 1073741824 then return string.format("%.2f GB", n / 1073741824) end
  if n >= 1048576 then return string.format("%.1f MB", n / 1048576) end
  return string.format("%.0f KB", n / 1024)
end

local function trim(s) return ((s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function folder()
  local f = trim(o.folder)
  if f == "" then f = HOME .. SEP .. "Downloads" .. SEP .. "Vivi" end
  return (f:gsub("^~", HOME))
end

-- ---------- classification (pure) ----------

local MEDIA_EXT = { mp3 = 1, ogg = 1, oga = 1, opus = 1, flac = 1, m4a = 1, aac = 1, wav = 1, wma = 1,
  mp4 = 1, m4v = 1, mkv = 1, webm = 1, mov = 1, avi = 1, ts = 1, mka = 1 }
local LIST_EXT = { pls = 1, m3u = 1 }

local function url_ext(url)
  local path = url:gsub("[?#].*$", "")
  return (path:match("%.([%w]+)$") or ""):lower()
end

-- "file" | "stream" | "hls" | "list" | "ytdlp" from the URL alone (headers may refine it).
local function classify(url)
  local ext = url_ext(url)
  if ext == "m3u8" then return "hls" end
  if LIST_EXT[ext] then return "list" end
  if MEDIA_EXT[ext] then return "file" end
  -- Jamendo's storage and archive.org /download/ URLs are files even without extension.
  if url:match("^https?://[%w%.%-]*storage%.jamendo%.com/") or url:match("^https?://[%w%.%-]*mp3l%.jamendo%.com/")
    or url:match("^https?://archive%.org/download/") then return "file" end
  return "ytdlp"
end

-- Refine with response headers (the GET probe's, or curl -sIL's): live audio has no
-- length, or ICY headers / an "ICY 200 OK" status (Shoutcast). A ranged reply's size is
-- the total in Content-Range, not its 1-byte Content-Length. Returns kind, size, type.
local function classify_headers(kind, head)
  -- Only the last response counts (curl -L dumps every redirect's headers too).
  local lines = {}
  for l in (head or ""):gmatch("[^\r\n]+") do
    if l:match("^[Hh][Tt][Tt][Pp]/") or l:match("^ICY ") then lines = {} end
    lines[#lines + 1] = l
  end
  head = table.concat(lines, "\n")
  local ctype, len, total
  for v in head:gmatch("[Cc]ontent%-[Tt]ype:%s*([^\r\n;]+)") do ctype = trim(v):lower() end
  for v in head:gmatch("[Cc]ontent%-[Ll]ength:%s*(%d+)") do len = tonumber(v) end
  for v in head:gmatch("[Cc]ontent%-[Rr]ange:%s*bytes%s+[%d%-]+/(%d+)") do total = tonumber(v) end
  if total then len = total end
  local low = "\n" .. head:lower()
  local icy = low:find("\nicy%-") ~= nil or low:find("\nicy %d") ~= nil
  if ctype and ctype:match("apple%.mpegurl") then return "hls", nil, ctype end
  if ctype and (ctype:match("mpegurl") or ctype:match("x%-scpls")) then return "list", nil, ctype end
  if icy then return "stream", nil, ctype end
  if ctype and (ctype:match("^audio/") or ctype:match("^video/") or ctype == "application/ogg") then
    if not len or len == 0 then return "stream", nil, ctype end
    return "file", len, ctype
  end
  return kind, len, ctype
end

-- File extension for a recorded stream's Content-Type.
local STREAM_EXT = { ["audio/mpeg"] = "mp3", ["audio/mp3"] = "mp3", ["audio/aac"] = "aac",
  ["audio/aacp"] = "aac", ["audio/x-aac"] = "aac", ["audio/ogg"] = "ogg", ["application/ogg"] = "ogg",
  ["audio/opus"] = "opus", ["audio/flac"] = "flac", ["video/mp2t"] = "ts", ["video/webm"] = "webm" }

-- First http(s) URL in a .pls/.m3u body.
local function first_list_url(body)
  for line in (body or ""):gmatch("[^\r\n]+") do
    local u = line:match("^File%d+=(https?://%S+)") or line:match("^%s*(https?://%S+)")
    if u then return u end
  end
end

local function safe_name(s)
  s = (s or ""):gsub("[%c<>:\"/\\|%?%*]", "_"):gsub("^%s+", ""):gsub("[%s%.]+$", "")
  if s == "" then s = "download" end
  return s:sub(1, 150)
end

local function unescape(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local function file_name(url, kind, ctype)
  local path = url:gsub("[?#].*$", "")
  local base = unescape(path:match("^%a+://[^/]+/(.*)$") or ""):match("([^/]+)/*$") or ""
  local host = url:match("^%a+://([^/:]+)") or "stream"
  if kind == "stream" then
    local ext = url_ext(url)
    local stem = safe_name(base ~= "" and (base:gsub("%.[%w]+$", "")) or host)
    ext = MEDIA_EXT[ext] and ext or STREAM_EXT[ctype or ""] or "mp3"
    return stem .. " " .. os.date("%Y-%m-%d %H%M") .. "." .. ext
  end
  if kind == "hls" then return safe_name(host) .. " " .. os.date("%Y-%m-%d %H%M") .. ".ts" end
  if base == "" then base = host end
  base = safe_name(base)
  if not MEDIA_EXT[(base:match("%.([%w]+)$") or ""):lower()] then base = base .. ".mp3" end
  return base
end

-- yt-dlp --progress-template lines -> percent, total text, title (last line wins).
local function parse_progress(s)
  local line
  for l in (s or ""):gmatch("%[vivi%][^\r\n]*") do line = l end
  if not line then return nil end
  local pct, total, title = line:match("^%[vivi%] *([^|]*)|([^|]*)|(.*)$")
  if not pct then return nil end
  total = trim(total)
  if total == "NA" or total == "N/A" then total = "" end
  return tonumber((pct:gsub("[%s%%]", ""))), total, trim(title)
end

-- ---------- queue ----------

local queue = {}      -- { id, url, kind, state, file, size, done, total, pct, total_text, title, error, added }
local active          -- { item, job, timer, t0, aborted = "pause"|"cancel" }
local next_id = 1

-- ---------- Vivi's shared Downloads panel ----------

local PLUGIN = "offline-downloads"
local PANEL_STATE = { pending = "queued", active = "active", paused = "paused", done = "done", failed = "failed" }

-- Read natively: Vivi up to 0.13's first builds set a string node, which
-- mp.get_property returns quoted ("1"); newer ones set the integer 1.
local function panel() return tostring(mp.get_property_native("user-data/vivi/downloads", "")) == "1" end

-- Stable across restarts and unique even when ids are reused after the list was cleared.
local function job_id(it) return tostring(it.added or 0) .. "-" .. tostring(it.id) end

local function recording(it) return it.record == true or it.live == true or it.kind == "stream" or it.kind == "hls" end

local function clock(secs)
  secs = math.max(0, math.floor(secs or 0))
  if secs >= 3600 then return string.format("%d:%02d:%02d", secs / 3600, secs % 3600 / 60, secs % 60) end
  return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

local function title_of(it) return it.title or (it.file and it.file:match("([^/\\]+)$")) or it.url end

-- The panel row (fields of Vivi's downloads report; all are sent so a row never keeps
-- stale values from an earlier state).
local function panel_row(it, now)
  local r = { title = title_of(it), state = PANEL_STATE[it.state] or "queued",
    done = it.done or 0, total = it.total or 0, progress = (it.pct or 0) / 100,
    error = it.error or "", path = it.file or "", can_pause = not recording(it), detail = "" }
  if it.state == "done" then
    r.done = it.size or r.done
    r.total = it.size or r.total
    r.progress = 1
    if it.recorded then
      r.detail = "Recorded " .. clock(it.recorded) .. (it.size and (" · " .. human(it.size)) or "")
      r.done_title = "Recording finished"
    end
  end
  if it.state == "active" and recording(it) then
    local el = math.max(0, (now or os.time()) - (it.started or now or os.time()))
    r.detail = string.format("Recording · %s of %s min", clock(el), tostring(it.minutes or "?"))
  elseif it.state == "active" and r.total == 0 and it.total_text and it.total_text ~= "" then
    r.detail = string.format("%.0f%% of %s", it.pct or 0, it.total_text)
  end
  return r
end

local function report(it)
  if not panel() then return end
  mp.commandv("script-message", "vivi-download", PLUGIN, job_id(it), utils.format_json(panel_row(it)))
end

local function unreport(it)
  if panel() then mp.commandv("script-message", "vivi-download-remove", PLUGIN, job_id(it)) end
end

local function find_job(job)
  for _, it in ipairs(queue) do if job_id(it) == job then return it end end
end

local function save()
  mkdir(DIR, function()
    local f = io.open(QUEUE .. ".tmp", "w")
    if not f then return end
    f:write(utils.format_json({ items = queue }))
    f:close()
    os.remove(QUEUE)
    os.rename(QUEUE .. ".tmp", QUEUE)
  end)
end

local function load()
  local f = io.open(QUEUE, "r")
  if not f then return end
  local v = utils.parse_json(f:read("*a") or "")
  f:close()
  queue = type(v) == "table" and type(v.items) == "table" and v.items or {}
  for _, it in ipairs(queue) do
    if it.state == "active" then
      -- Interrupted by quitting. A recording is kept as it is (restarting it would
      -- overwrite the file); anything else continues.
      local fi = recording(it) and it.file and utils.file_info(it.file)
      if fi and fi.size > 0 then it.state, it.size, it.pct = "done", fi.size, 100
      else it.state = "pending" end
    end
    if (it.id or 0) >= next_id then next_id = it.id + 1 end
  end
end

local function counts()
  local c = { pending = 0, active = 0, paused = 0, done = 0, failed = 0 }
  for _, it in ipairs(queue) do c[it.state] = (c[it.state] or 0) + 1 end
  return c
end

local function describe(it)
  local name = it.title or (it.file and it.file:match("([^/\\]+)$")) or it.url
  local s = "[" .. it.state .. "] " .. name
  if it.state == "active" and recording(it) and it.started then
    s = s .. string.format(" recording %s of %s min", clock(os.time() - it.started), tostring(it.minutes or "?"))
  elseif it.state == "active" or it.state == "paused" then
    if it.pct then s = s .. string.format(" %.0f%%", it.pct) end
    if it.total and it.total > 0 then s = s .. " of " .. human(it.total)
    elseif it.total_text and it.total_text ~= "" then s = s .. " of " .. it.total_text
    elseif it.done and it.done > 0 then s = s .. " " .. human(it.done) end
  elseif it.state == "done" and it.recorded then
    s = s .. " (recorded " .. clock(it.recorded) .. ", " .. human(it.size) .. ")"
  elseif it.state == "done" and it.size then s = s .. " (" .. human(it.size) .. ")"
  elseif it.state == "failed" and it.error then s = s .. ": " .. it.error:sub(1, 80) end
  return s
end

local function show()
  if panel() then return mp.commandv("script-message", "vivi-downloads-show") end
  if #queue == 0 then return toast("The download queue is empty") end
  local c, lines = counts(), {}
  lines[1] = string.format("Downloads: %d pending, %d active, %d paused, %d done, %d failed → %s",
    c.pending, c.active, c.paused, c.done, c.failed, folder())
  for i = math.max(1, #queue - 11), #queue do lines[#lines + 1] = describe(queue[i]) end
  toast(table.concat(lines, "\n"), 10)
end

-- ---------- tools (found, never downloaded) ----------

local function find(names, extra_dirs)
  local dirs = {}
  if not FLATPAK and not os.getenv("VIVI_TEST_NO_SYSTEM_TOOLS") then
    for d in (os.getenv("PATH") or ""):gmatch(windows and "[^;]+" or "[^:]+") do dirs[#dirs + 1] = d end
    if not windows then
      for _, d in ipairs({ HOME .. "/.local/bin", "/usr/local/bin", "/usr/bin", "/opt/homebrew/bin", "/snap/bin" }) do dirs[#dirs + 1] = d end
    end
  end
  for _, d in ipairs(extra_dirs or {}) do dirs[#dirs + 1] = d end
  for _, d in ipairs(dirs) do
    for _, n in ipairs(names) do
      local p = d .. SEP .. n .. EXE
      if utils.file_info(p) then return p, d end
    end
  end
end

local YT_BIN = PLUGIN_DATA .. SEP .. "youtube" .. SEP .. "bin"
local FF_DIRS = { PLUGIN_DATA .. SEP .. "youtube" .. SEP .. "ffmpeg", PLUGIN_DATA .. SEP .. "shared" .. SEP .. "ffmpeg-media" }

local function ytdlp() return (find({ "yt-dlp" }, { YT_BIN })) end
local function ffmpeg() return find({ "ffmpeg" }, FF_DIRS) end
local function ffprobe() return (find({ "ffprobe" }, FF_DIRS)) end

local function radio_secs() return math.max(1, math.floor((tonumber(o["radio-minutes"]) or 30) * 60)) end

-- ---------- running ----------

local start_next
local stop_active

-- A stopped yt-dlp leaves its file as name.part: that is the recording so far.
local function adopt_part(it)
  if it.file and utils.file_info(it.file) then return end
  local final = it.part and it.part:gsub("%.part$", "")
  if final and utils.file_info(it.part) and os.rename(it.part, final) then it.file = final end
end

local function remove_recording(it)
  if it.file then os.remove(it.file) end
  if it.part then os.remove(it.part) end
end

-- The real length of a finished recording, when ffprobe is around.
local function probe_length(it)
  local fp = ffprobe()
  if not fp or not it.file then return end
  run({ fp, "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", it.file }, function(r)
    local d = tonumber(trim(r.stdout))
    if d and d > 0 and it.state == "done" then
      it.recorded = math.floor(d + 0.5)
      report(it)
      save()
    end
  end)
end

local function finish(it, ok, err)
  local a = active
  if a and a.timer then a.timer:kill() end
  if a and a.cap then a.cap:kill() end
  active = nil
  local rec = recording(it)
  if rec and a and a.aborted == "discard" then
    remove_recording(it)
    it.state, it.error, it.done, it.pct, it.file, it.part = "failed", "Discarded", 0, 0, nil, nil
    toast("Recording discarded")
  elseif rec and a and a.aborted ~= "pause" and a.aborted ~= "cancel" then
    -- Ended by its length (the tool's own limit or ours), Stop or Cancel: keep it.
    adopt_part(it)
    local fi = it.file and utils.file_info(it.file)
    if fi and fi.size > 0 then
      local secs = (it.minutes or 0) * 60
      local el = os.time() - (it.started or os.time())
      it.state, it.error, it.pct, it.size = "done", nil, 100, fi.size
      it.recorded = secs > 0 and math.min(el, secs) or el
      toast("Recorded " .. clock(it.recorded) .. ": " .. title_of(it), 5)
      probe_length(it)
    else
      it.state, it.error = "failed", "Nothing was recorded: " .. (trim(err or "") ~= "" and trim(err):match("([^\n]*)$") or "the stream sent no data")
      toast("Recording failed: " .. it.error, 8)
    end
  elseif a and a.aborted == "pause" then
    it.state = "paused"
  elseif a and a.aborted == "cancel" then
    if it.file and it.kind ~= "ytdlp" then os.remove(it.file) end
    if panel() then
      -- Keep the row (failed, "Cancelled") so the panel's Retry works.
      it.state, it.error, it.done, it.pct = "failed", "Cancelled", 0, 0
      if it.kind ~= "ytdlp" then it.file = nil end
    else
      for i, x in ipairs(queue) do if x == it then table.remove(queue, i) break end end
    end
    toast("Download cancelled")
  elseif ok then
    it.state, it.error, it.pct = "done", nil, 100
    local fi = it.file and utils.file_info(it.file)
    it.size = fi and fi.size or it.size
    toast("Downloaded: " .. describe(it), 5)
  else
    it.state, it.error = "failed", trim(err or "error"):match("([^\n]*)$")
    toast("Download failed: " .. it.error, 8)
  end
  report(it)
  save()
  start_next()
end

local function curl_job(it, max_time)
  local args = { "curl", "-fL", "-s", "-A", "Vivi", "-o", it.file }
  if max_time then
    -- A recording: no --retry (curl retries after --max-time and the new transfer
    -- overwrote the recording), unbuffered so a stop loses nothing.
    args[#args + 1] = "-N"
    args[#args + 1] = "--max-time"
    args[#args + 1] = tostring(max_time)
  else
    args[#args + 1] = "--retry"
    args[#args + 1] = "2"
    args[#args + 1] = "-C"
    args[#args + 1] = "-"
  end
  args[#args + 1] = it.url
  local t0 = active.t0
  active.timer = mp.add_periodic_timer(1, function()
    local fi = utils.file_info(it.file)
    it.done = fi and fi.size or 0
    if it.total and it.total > 0 then it.pct = math.min(99, it.done / it.total * 100)
    elseif max_time then it.pct = math.min(99, (os.time() - t0) / max_time * 100) end
    report(it)
  end)
  active.job = run(guarded(args, nil, active.pidfile), function(r)
    -- curl exits 28 when --max-time ends a recording: that is the normal end.
    local ok = r.status == 0 or (max_time ~= nil and r.status == 28 and utils.file_info(it.file) ~= nil)
    finish(it, ok, (r.stderr or "") ~= "" and r.stderr or ("curl exit " .. tostring(r.status)))
  end)
end

local SITES = { "youtube%.com", "youtu%.be", "vimeo%.com", "soundcloud%.com", "bandcamp%.com",
  "twitch%.tv", "dailymotion%.com", "mixcloud%.com" }
local function known_site(url)
  local host = (url:match("^%a+://([^/:]+)") or ""):lower()
  for _, s in ipairs(SITES) do
    if host:match("^" .. s .. "$") or host:match("%." .. s .. "$") then return true end
  end
  return false
end

-- yt-dlp -f for the quality setting. Every choice ends in fallbacks: YouTube often has no
-- single file with video and audio (format 18) any more, and plain "b" then failed with
-- "Requested format is not available". YouTube Music links are songs: best audio.
local function format_for(url, q, have_ffmpeg)
  local host = (url:match("^%a+://([^/:]+)") or ""):lower()
  if host == "music.youtube.com" or q == "Audio only" then return "ba[ext=m4a]/ba/b" end
  local merge = have_ffmpeg and "/bv*+ba" or ""
  local h = q:match("(%d+)p")
  if have_ffmpeg and h then return "bv*[height<=" .. h .. "]+ba/b[height<=" .. h .. "]/bv*+ba/b/ba" end
  if have_ffmpeg and q == "Best" then return "bv*+ba/b/ba" end
  return "b" .. merge .. "/ba"
end

local function ytdlp_job(it)
  local y = ytdlp()
  if not y then
    return finish(it, false, "no yt-dlp: install yt-dlp or the YouTube & yt-dlp plugin (its managed copy is reused here)")
  end
  local ff, ffdir = ffmpeg()
  local fmt = format_for(it.url, o["video-quality"], ff ~= nil)
  local log = TMP .. SEP .. "vivi-offline-" .. mp.get_property("pid", "0") .. ".log"
  os.remove(log)
  os.remove(log .. ".path")
  os.remove(log .. ".info")
  local args = { y, "--newline", "--no-colors", "--no-playlist", "-f", fmt, "-P", folder(),
    "-o", "%(title).150B [%(id)s].%(ext)s", "--print-to-file", "after_move:filepath", log .. ".path",
    "--print-to-file", "video:%(is_live)s\t%(filename)s", log .. ".info",
    "--progress-template", "download:[vivi] %(progress._percent_str)s|%(progress._total_bytes_str,progress._total_bytes_estimate_str)s|%(info.title)s" }
  if ffdir then args[#args + 1] = "--ffmpeg-location" args[#args + 1] = ffdir end
  if not known_site(it.url) then
    -- May turn out to be a stream: small fixed blocks, so stopping it keeps all but the
    -- last few seconds (yt-dlp holds a whole block in memory, up to megabytes).
    for _, x in ipairs({ "--buffer-size", "16K", "--no-resize-buffer" }) do args[#args + 1] = x end
  end
  args[#args + 1] = it.url
  if not windows then args = guarded(args, log, active.pidfile) end
  local a = active
  active.timer = mp.add_periodic_timer(1, function()
    local fi = io.open(log .. ".info", "r")
    if fi then
      local live, name = (fi:read("*a") or ""):match("([^\t\r\n]*)\t([^\r\n]+)")
      fi:close()
      if name then it.part = name .. ".part" end
      if live == "True" then it.live = true end
    end
    local f = io.open(log, "r")
    if not f then return end
    local pct, total, title = parse_progress(f:read("*a"))
    f:close()
    if pct then it.pct, it.total_text = pct, total end
    if title and title ~= "" then it.title = title end
    -- An unknown site sending no size is a stream too (yt-dlp's generic extractor on
    -- a radio URL the probe could not read): record it for the set length.
    if not it.live and pct and (total or "") == "" and not known_site(it.url) then it.live = true end
    if it.live and not a.cap then
      local secs = radio_secs()
      it.minutes = math.floor(secs / 60)
      toast(string.format("Recording %d min: %s (Cancel in Downloads stops and keeps it)", it.minutes, title_of(it)), 5)
      save()
      a.cap = mp.add_timeout(math.max(0, secs - (os.time() - (it.started or os.time()))), function()
        if active == a and not a.aborted then stop_active("auto") end
      end)
    end
    report(it)
  end)
  active.job = run(args, function(r)
    local out = (r.stdout or "") .. (r.stderr or "")
    local f = io.open(log, "r")
    if f then out = out .. f:read("*a") f:close() end
    local pf = io.open(log .. ".path", "r")
    local path = pf and trim(pf:read("*a")):match("([^\r\n]+)$")
    if pf then pf:close() end
    os.remove(log)
    os.remove(log .. ".path")
    if path and utils.file_info(path) then it.file = path end
    finish(it, r.status == 0, out:match("ERROR: ([^\n]+)") or r.error_string or "yt-dlp error")
  end)
end

-- Short GET probe: headers of the first ≤4 KB (a 1-byte range for files). Icecast
-- servers that refuse HEAD answer it; a live stream is cut off right after its headers.
local PROBE = [[h=$(mktemp) || exit 1
curl -sL -A Vivi -H 'Icy-MetaData: 1' -r 0-0 --max-time 10 -D "$h" -o - "$1" 2>/dev/null | head -c 4096 >/dev/null
cat "$h"; rm -f "$h"]]

local function probe_args(url)
  if windows then
    return { "curl", "-sL", "-A", "Vivi", "-H", "Icy-MetaData: 1", "-r", "0-0", "--max-time", "6", "-D", "-", "-o", "NUL", url }
  end
  return { "sh", "-c", PROBE, "sh", url }
end

-- Whether mpv is playing `url` as a live stream: ICY metadata (Icecast / Shoutcast), or
-- not seekable with no duration.
local function playing_live(url)
  if (mp.get_property("path", "") or "") ~= url then return false end
  local md = mp.get_property_native("metadata") or {}
  for k in pairs(md) do
    if tostring(k):lower():match("^icy%-") then return true end
  end
  return mp.get_property_native("seekable") == false and mp.get_property_native("duration") == nil
end

stop_active = function(how)
  if not active then return end
  active.aborted = how
  if not windows and active.pidfile and utils.file_info(active.pidfile) then
    run({ "sh", "-c", STOP, "sh", active.pidfile }, function(r)
      -- No pid to stop (already gone): fall back to ending the wrapper.
      if r.status ~= 0 and active and active.job then mp.abort_async_command(active.job) end
    end)
  elseif active.job then
    mp.abort_async_command(active.job)
  end
end

local function begin(it)
  active = { item = it, t0 = os.time(),
    pidfile = not windows and (TMP .. SEP .. "vivi-offline-" .. mp.get_property("pid", "0") .. ".pid") or nil }
  if active.pidfile then os.remove(active.pidfile) end
  it.state, it.error, it.started = "active", nil, active.t0
  report(it)
  save()
  mkdir(folder(), function()
    -- Well-known video/music sites skip the header probe; other URLs may be radio or files.
    if it.kind == "ytdlp" and known_site(it.url) then return ytdlp_job(it) end
    run(probe_args(it.url), function(h)
      if active and active.aborted then return finish(it, false) end
      local kind, len, ctype = classify_headers(it.kind, h.stdout)
      -- "record": a timed recording even when the server sends a length.
      if it.record and kind ~= "list" then kind, len = (kind == "hls") and "hls" or "stream", nil end
      if kind == "list" then
        return run({ "curl", "-sL", "--max-time", "15", it.url }, function(b)
          local u = first_list_url(b.stdout)
          if not u then return finish(it, false, "no stream URL in the playlist file") end
          it.url = u
          it.kind = classify(u) == "hls" and "hls" or "stream"
          active = nil
          begin(it)
        end)
      end
      it.kind = kind
      if kind == "ytdlp" then return ytdlp_job(it) end
      it.file = it.file or (folder() .. SEP .. file_name(it.url, kind, ctype))
      local secs = radio_secs()
      if kind == "stream" or kind == "hls" then
        it.minutes = math.floor(secs / 60)
        toast(string.format("Recording %d min: %s (Cancel in Downloads stops and keeps it)", it.minutes, title_of(it)), 5)
        -- The tools stop themselves at the length; this is the backstop.
        local a = active
        a.cap = mp.add_timeout(secs + 15, function()
          if active == a and not a.aborted then stop_active("auto") end
        end)
      end
      report(it)
      if kind == "hls" then
        local ff = ffmpeg()
        if not ff then return finish(it, false, "HLS streams need ffmpeg (install ffmpeg)") end
        local t0 = active.t0
        active.timer = mp.add_periodic_timer(1, function()
          it.pct = math.min(99, (os.time() - t0) / secs * 100)
          report(it)
        end)
        active.job = run(guarded({ ff, "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", it.url, "-t", tostring(secs), "-c", "copy", it.file }, nil, active.pidfile),
          function(r) finish(it, r.status == 0, r.stderr) end)
        return
      end
      it.total = len
      curl_job(it, kind == "stream" and secs or nil)
    end)
  end)
end

start_next = function()
  if active then return end
  for _, it in ipairs(queue) do
    if it.state == "pending" then return begin(it) end
  end
end

local function enqueue(url, record)
  url = trim(url)
  if not url:match("^https?://%S+$") then return toast("Not an http(s) URL: " .. url:sub(1, 80)) end
  -- mpv knows the playing item is live (radio): record it rather than download forever.
  if not record and playing_live(url) then record = true end
  for _, it in ipairs(queue) do
    if it.url == url and it.state ~= "done" and it.state ~= "failed" then return toast("Already in the queue") end
  end
  local it = { id = next_id, url = url, kind = classify(url), state = "pending", added = os.time(),
    record = record or nil }
  next_id = next_id + 1
  queue[#queue + 1] = it
  report(it)
  save()
  toast(string.format("Queued (%s): %s — %d waiting",
    record and (o["radio-minutes"] .. " min recording") or (it.kind == "ytdlp" and "yt-dlp" or it.kind),
    url:sub(1, 80), counts().pending), 4)
  start_next()
  return it
end

local function abort(how)
  -- A recording is never thrown away by Cancel: it stops and keeps what was recorded.
  if recording(active.item) then
    if how == "cancel" then how = "stop" end
    if how == "pause" and active.item.state == "active" then how = "stop" end
    return stop_active(how)
  end
  active.aborted = how
  if active.job then mp.abort_async_command(active.job) end
end

local function stop_recording(discard)
  if not active or not recording(active.item) then return toast("Nothing is being recorded") end
  stop_active(discard and "discard" or "stop")
end

local function pause()
  if active then
    abort("pause")
    return toast("Paused (Pause / Resume again continues)")
  end
  local any = false
  for _, it in ipairs(queue) do
    if it.state == "paused" then it.state = "pending" any = true report(it) end
  end
  if not any then return toast("Nothing to pause or resume") end
  save()
  toast("Resumed")
  start_next()
end

local function cancel()
  if active then
    if recording(active.item) then toast("Stopping the recording (it is kept)") end
    return abort("cancel")
  end
  local n = 0
  for i = #queue, 1, -1 do
    if queue[i].state == "pending" or queue[i].state == "paused" then
      unreport(queue[i])
      table.remove(queue, i)
      n = n + 1
    end
  end
  save()
  toast(n > 0 and ("Removed " .. n .. " waiting download(s)") or "Nothing to cancel")
end

local function retry()
  local n = 0
  for _, it in ipairs(queue) do
    if it.state == "failed" then
      it.state, it.error, it.kind = "pending", nil, classify(it.url)
      it.live, it.part, it.recorded = nil, nil, nil
      n = n + 1
      report(it)
    end
  end
  save()
  toast(n > 0 and ("Retrying " .. n .. " download(s)") or "No failed downloads")
  start_next()
end

local function clear_done()
  for i = #queue, 1, -1 do
    if queue[i].state == "done" then unreport(queue[i]) table.remove(queue, i) end
  end
  save()
  toast("Finished downloads removed from the list (files are kept)")
end

local function open_folder()
  local f = folder()
  mkdir(f, function()
    local cmd = windows and { "explorer", f } or (utils.file_info("/System/Library") and { "open", f } or { "xdg-open", f })
    run(cmd, function() end)
  end)
end

local function add_clipboard_or_current()
  local t = trim(mp.get_property("clipboard/text", "") or "")
  if t:match("^https?://%S+$") then return enqueue(t) end
  local p = mp.get_property("path", "") or ""
  if p:match("^https?://") then return enqueue(p) end
  toast("Copy a URL first (or paste it into the Offline Downloads settings)")
end

-- ---------- Downloads panel buttons (one job each) ----------

local function job_pause(job)
  local it = find_job(job)
  if not it then return end
  if active and active.item == it then return abort("pause") end
  if it.state == "pending" then it.state = "paused" report(it) save() end
end

local function job_resume(job)
  local it = find_job(job)
  if not it or it.state ~= "paused" then return end
  it.state = "pending"
  report(it)
  save()
  start_next()
end

local function job_cancel(job)
  local it = find_job(job)
  if not it then return end
  if active and active.item == it then return abort("cancel") end
  if it.state == "pending" or it.state == "paused" then
    it.state, it.error = "failed", "Cancelled"
    report(it)
    save()
  end
end

local function job_retry(job)
  local it = find_job(job)
  if not it or it.state ~= "failed" then return end
  it.state, it.error, it.kind, it.pct, it.done = "pending", nil, classify(it.url), 0, 0
  it.live, it.part, it.recorded = nil, nil, nil
  report(it)
  save()
  start_next()
end

-- Vivi keeps finished rows itself (and Remove / Clear finished are its own), so only
-- the unfinished ones are announced again at startup.
local function report_unfinished()
  for _, it in ipairs(queue) do
    if it.state ~= "done" and it.state ~= "failed" then report(it) end
  end
end

-- Record the given URL, else the playing online stream, else the URL in the clipboard.
local function record(url)
  url = trim(url)
  if url == "" then
    local p = mp.get_property("path", "") or ""
    local c = trim(mp.get_property("clipboard/text", "") or "")
    if p:match("^https?://") then url = p
    elseif c:match("^https?://%S+$") then url = c
    else return toast("Play a radio / live stream (or copy its URL) to record it") end
  end
  return enqueue(url, true)
end

local function info()
  toast(string.format("yt-dlp: %s\nffmpeg: %s\nFolder: %s",
    ytdlp() or "none (install yt-dlp or the YouTube & yt-dlp plugin)",
    ffmpeg() or "none (single-file formats only; HLS recording unavailable)", folder()), 8)
end

load()
options.read_options(o, "offline-downloads", function() end)
mp.register_script_message("add", function() enqueue(o.url) end)
mp.register_script_message("add-current", function()
  local p = mp.get_property("path", "") or ""
  if p:match("^https?://") then enqueue(p) else toast("The playing item is not an online URL") end
end)
mp.register_script_message("enqueue", function(url) enqueue(url) end)
mp.register_script_message("record", record)
mp.register_script_message("add-clipboard", add_clipboard_or_current)
mp.register_script_message("show", show)
mp.register_script_message("pause", pause)
mp.register_script_message("cancel", cancel)
mp.register_script_message("stop", function() stop_recording(false) end)
mp.register_script_message("discard", function() stop_recording(true) end)
mp.register_script_message("retry", retry)
mp.register_script_message("clear-done", clear_done)
mp.register_script_message("open-folder", open_folder)
mp.register_script_message("info", info)
mp.register_script_message("download-pause", job_pause)
mp.register_script_message("download-resume", job_resume)
mp.register_script_message("download-cancel", job_cancel)
mp.register_script_message("download-retry", job_retry)
mp.register_script_message("pick-folder", function()
  mp.commandv("script-message", "vivi-pick-folder", "offline-downloads", "folder")
end)
mp.register_script_message("folder-picked", function(p) o.folder = p toast("Downloads go to " .. p) end)
mp.add_forced_key_binding("Alt+d", "offline-add", add_clipboard_or_current)
mp.add_forced_key_binding("Alt+D", "offline-show", show)
mp.register_event("shutdown", function()
  if not active then return end
  -- Quitting ends a recording the same way as Stop (the watchdog stops the tool too).
  if recording(active.item) then return stop_active("stop") end
  abort("pause")
end)
mp.add_timeout(3, function()
  report_unfinished()
  start_next()
end)

if VIVI_TEST then
  return { classify = classify, classify_headers = classify_headers, first_list_url = first_list_url,
    file_name = file_name, parse_progress = parse_progress, enqueue = enqueue, retry = retry,
    clear_done = clear_done, known_site = known_site, format_for = format_for, queue = function() return queue end, describe = describe, human = human,
    set_active = function(a) active = a end, job_id = job_id, panel_row = panel_row,
    job_pause = job_pause, job_resume = job_resume, job_cancel = job_cancel, job_retry = job_retry,
    show = show, report_unfinished = report_unfinished, record = record, guarded = guarded, GUARD = GUARD,
    STOP = STOP, PROBE = PROBE, probe_args = probe_args, playing_live = playing_live, finish = finish,
    get_active = function() return active end, cancel = cancel, stop_recording = stop_recording, clock = clock }
end
