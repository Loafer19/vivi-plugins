-- @name YouTube & yt-dlp
-- @version 1.4.0
-- @author Vivi
-- @description List, size and download YouTube (and other yt-dlp) videos and playlists.
--
-- Keys: Alt+u  paste a URL from the clipboard and add its entries to the playlist
--
-- Needs Vivi 0.13+ (host API): the YouTube source opens Vivi's music dialog to search YouTube
-- or list a pasted video / playlist / channel link (rows with thumbnails; Play, Queue,
-- Download, Download audio; the detail pane shows the selected video's estimated size per
-- quality, the Quality dropdown sets the download quality), queued videos get their title,
-- channel and thumbnail on the
-- now-playing card (vivi-media-meta), and downloads are rows in Vivi's Downloads panel
-- (vivi-download: progress, Cancel, Retry, Play / Show in folder). In a plain mpv progress
-- is shown on the OSD.
--
-- Every URL handed to yt-dlp comes after "--", so a URL setting such as "--exec=…" can
-- never be read as an option, and only http(s) URLs are accepted.
--
-- yt-dlp: a system copy is preferred when it is recent (released in the last 90 days):
-- PATH and common install folders. Otherwise the plugin downloads its own copy from the official GitHub releases
-- (https://github.com/yt-dlp/yt-dlp/releases/latest), checks it against SHA2-256SUMS and
-- keeps it in $XDG_DATA_HOME/vivi/plugin-data/youtube/bin, where Vivi also looks for it
-- (it appends that folder to PATH, so mpv's ytdl_hook finds it in the Flatpak). Only that
-- managed copy is updated (`yt-dlp -U`, daily when "auto-update" is on). The chosen yt-dlp
-- is also handed to mpv's ytdl_hook (script-opt ytdl_hook-ytdl_path) for streaming.
--
-- ffmpeg (merging separate video + audio, audio conversion): a system ffmpeg is used when
-- there is one (not inside the Flatpak, whose runtime has no ffmpeg program). A managed
-- static build is downloaded only when needed: video at 1080p or more / "Best", a video
-- with no single file of video and audio at the chosen quality (YouTube often has none),
-- or audio converted to mp3/m4a/opus. It is Vivi's own minimal build (release
-- helper-ffmpeg-v<build>, Linux x86_64/aarch64, Windows x64, macOS arm64; about 6-12 MB),
-- checked against the sha256 pinned in this file (FF_BUILD). Kept in
-- plugin-data/youtube/ffmpeg (ffmpeg + ffprobe), passed to yt-dlp with
-- --ffmpeg-location; only this copy is updated: when a plugin update pins a new build
-- (*Update ffmpeg*, or checked every 30 days with auto-update). Lower qualities without ffmpeg use
-- single-file formats.
--
-- Sizes: from yt-dlp's filesize / filesize_approx (or bitrate × duration) of the formats
-- the chosen quality would pick; shown before every download and with "Show sizes".
-- Progress: yt-dlp writes a progress template line to a log file that is read every
-- 2 s (Linux/macOS; on Windows only start and end are reported).
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

local ID = "youtube"
local o = {
  url = "",
  view = "List",
  quality = "1080p",
  mode = "Video",
  ["audio-format"] = "Original",
  folder = "",
  source = "Auto (system if recent, else managed)",
  ["auto-update"] = true,
  pkgdir = "", -- set by Vivi
}

local windows = package.config:sub(1, 1) == "\\"
local SEP = windows and "\\" or "/"
local EXE = windows and ".exe" or ""
local HOME = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
local DATA_HOME = os.getenv("XDG_DATA_HOME")
if not DATA_HOME or DATA_HOME == "" then DATA_HOME = HOME .. SEP .. ".local" .. SEP .. "share" end
local DATA = DATA_HOME .. SEP .. "vivi" .. SEP .. "plugin-data" .. SEP .. "youtube"
local BIN_DIR = DATA .. SEP .. "bin"
local MANAGED = BIN_DIR .. SEP .. "yt-dlp" .. EXE
local RELEASES = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
local MAX_AGE = 90 * 86400
local FLATPAK = utils.file_info("/.flatpak-info") ~= nil

local ytdlp = nil      -- { cmd = {...}, kind = "system"|"managed", version, path }
local resolving = nil  -- callbacks waiting for detection
local job = nil        -- running download
local info_cache = {}  -- url -> yt-dlp JSON (single video)

-- Inside Vivi (it always sets pkgdir) messages are Vivi toasts; mpv's OSD is only drawn
-- into the video, so it is used only when the script runs in a plain mpv.
local function toast(msg, secs)
  mp.msg.info(msg)
  if (o.pkgdir or "") == "" then return mp.osd_message(msg, secs or 3) end
  mp.commandv("script-message", "vivi-toast", msg, tostring(secs or 3))
end

local function run(args, cb, capture)
  return mp.command_native_async({
    name = "subprocess", args = args, playback_only = false,
    capture_stdout = capture ~= false, capture_stderr = true,
  }, function(_, r) cb(r or {}) end)
end

local function concat(a, b)
  local t = {}
  for _, v in ipairs(a) do t[#t + 1] = v end
  for _, v in ipairs(b) do t[#t + 1] = v end
  return t
end

local function mkdir(dir, cb)
  if windows then
    run({ "cmd", "/c", "if not exist \"" .. dir .. "\" mkdir \"" .. dir .. "\"" }, cb)
  else
    run({ "mkdir", "-p", dir }, cb)
  end
end

local function human(n)
  if not n then return "?" end
  if n >= 1073741824 then return string.format("%.1f GB", n / 1073741824) end
  if n >= 1048576 then return string.format("%.0f MB", n / 1048576) end
  return string.format("%.0f KB", n / 1024)
end

-- ---------- finding yt-dlp ----------

-- "2026.08.19" -> unix time (nil when not a yt-dlp date version).
local function version_time(v)
  local y, m, d = (v or ""):match("(%d%d%d%d)%.(%d%d?)%.(%d%d?)")
  if not y then return nil end
  return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
end

local function recent(v)
  local t = version_time(v)
  return t ~= nil and os.time() - t <= MAX_AGE
end

-- Executables named yt-dlp outside our own folder: PATH first, then common places.
local function system_candidates()
  local seen, out = {}, {}
  local function add(dir)
    if not dir or dir == "" or dir == BIN_DIR then return end
    local p = dir .. SEP .. "yt-dlp" .. EXE
    if not seen[p] and utils.file_info(p) then
      seen[p] = true
      out[#out + 1] = p
    end
  end
  for dir in (os.getenv("PATH") or ""):gmatch(windows and "[^;]+" or "[^:]+") do add(dir) end
  if windows then
    local la = os.getenv("LOCALAPPDATA") or ""
    add(la .. "\\Microsoft\\WinGet\\Links")
    add(HOME .. "\\scoop\\shims")
    add("C:\\ProgramData\\chocolatey\\bin")
  else
    for _, d in ipairs({ HOME .. "/.local/bin", HOME .. "/bin", "/usr/local/bin", "/usr/bin",
                         "/opt/homebrew/bin", "/opt/local/bin", "/snap/bin" }) do add(d) end
  end
  return out
end

local function probe(cmd, cb)
  run(concat(cmd, { "--version" }), function(r)
    local v = r.status == 0 and (r.stdout or ""):match("^%s*(%S+)") or nil
    cb(v)
  end)
end

-- First working system yt-dlp: { cmd, version, path, kind }.
local function find_system(cb)
  local list = system_candidates()
  local i = 0
  local function nxt()
    i = i + 1
    if list[i] then
      probe({ list[i] }, function(v)
        if v then cb({ cmd = { list[i] }, version = v, path = list[i], kind = "system" }) else nxt() end
      end)
    else
      cb(nil)
    end
  end
  nxt()
end

-- Release asset for this computer.
local function asset_name(cb)
  if windows then
    local a = (os.getenv("PROCESSOR_ARCHITEW6432") or os.getenv("PROCESSOR_ARCHITECTURE") or ""):upper()
    cb(a == "ARM64" and "yt-dlp_arm64.exe" or a == "X86" and "yt-dlp_x86.exe" or "yt-dlp.exe")
    return
  end
  run({ "uname", "-sm" }, function(r)
    local s = r.stdout or ""
    if s:match("Darwin") then cb("yt-dlp_macos")
    elseif s:match("x86_64") then cb("yt-dlp_linux")
    elseif s:match("aarch64") or s:match("arm64") then cb("yt-dlp_linux_aarch64")
    else cb(nil, "no yt-dlp build for " .. s:gsub("%s+$", "")) end
  end)
end

local function sha256(file, cb)
  local function first_hex(s)
    for line in (s or ""):gmatch("[^\r\n]+") do
      local h = line:gsub("%s", ""):lower():match("^(%x+)")
      if h and #h >= 64 then return h:sub(1, 64) end
    end
  end
  if windows then
    run({ "certutil", "-hashfile", file, "SHA256" }, function(r)
      local out = (r.stdout or ""):gsub("^[^\n]*\n", "") -- skip the "SHA256 hash of" line
      cb(first_hex(out))
    end)
    return
  end
  run({ "sha256sum", file }, function(r)
    if r.status == 0 then return cb(first_hex(r.stdout)) end
    run({ "shasum", "-a", "256", file }, function(r2) cb(r2.status == 0 and first_hex(r2.stdout) or nil) end)
  end)
end

-- Bytes of a URL (HEAD, following redirects), or nil.
local function remote_size(url, cb)
  run({ "curl", "-sIL", url }, function(r)
    local n
    for v in (r.stdout or ""):gmatch("[Cc]ontent%-[Ll]ength:%s*(%d+)") do n = tonumber(v) end
    cb(n)
  end)
end

-- Download the managed copy (verified against the release's SHA2-256SUMS).
local function install_managed(cb)
  asset_name(function(asset, err)
    if not asset then return cb(nil, err) end
    mkdir(BIN_DIR, function() remote_size(RELEASES .. asset, function(n)
      local tmp = MANAGED .. ".part"
      toast("Downloading yt-dlp" .. (n and (" (" .. human(n) .. ")") or "") .. " from its GitHub releases…", 6)
      run({ "curl", "-fsSL", "--retry", "2", "-o", tmp, RELEASES .. asset }, function(r)
        if r.status ~= 0 then
          os.remove(tmp)
          return cb(nil, "yt-dlp download failed: " .. (r.stderr or r.error_string or ""))
        end
        run({ "curl", "-fsSL", RELEASES .. "SHA2-256SUMS" }, function(s)
          local want
          for h, n in (s.stdout or ""):gmatch("(%x+)%s+%*?([^\r\n]+)") do
            if n == asset then want = h:lower() end
          end
          sha256(tmp, function(got)
            if not want or not got or got ~= want then
              os.remove(tmp)
              return cb(nil, not got and "no sha256 tool (sha256sum/shasum/certutil) to verify yt-dlp"
                or "yt-dlp checksum mismatch, not installed")
            end
            os.remove(MANAGED)
            local ok, e = os.rename(tmp, MANAGED)
            if not ok then return cb(nil, e) end
            local function done()
              probe({ MANAGED }, function(v)
                if not v then return cb(nil, "the downloaded yt-dlp does not run") end
                local f = io.open(DATA .. SEP .. "last-update", "w")
                if f then f:write(tostring(os.time())) f:close() end
                cb({ cmd = { MANAGED }, version = v, path = MANAGED, kind = "managed" })
              end)
            end
            if windows then done() else run({ "chmod", "755", MANAGED }, done) end
          end)
        end)
      end)
    end) end)
  end)
end

local function self_update(quiet, cb)
  if not utils.file_info(MANAGED) then
    if not quiet then toast("The managed yt-dlp is not installed (a system yt-dlp is used)") end
    return cb and cb()
  end
  run({ MANAGED, "-U" }, function(r)
    local f = io.open(DATA .. SEP .. "last-update", "w")
    if f then f:write(tostring(os.time())) f:close() end
    local out = ((r.stdout or "") .. (r.stderr or "")):gsub("%s+$", "")
    local last = out:match("([^\n]+)$") or "done"
    if ytdlp and ytdlp.kind == "managed" then
      probe({ MANAGED }, function(v) ytdlp.version = v or ytdlp.version end)
    end
    if not quiet or out:match("Updated yt%-dlp") then toast("yt-dlp: " .. last, 5) end
    if cb then cb() end
  end)
end

local function maybe_auto_update()
  if not o["auto-update"] then return end
  local f = io.open(DATA .. SEP .. "last-update", "r")
  local t = f and tonumber(f:read("*a")) or 0
  if f then f:close() end
  if os.time() - t > 86400 then self_update(true) end
end

-- Hand the chosen yt-dlp to mpv's ytdl_hook.
local function tell_ytdl_hook(y)
  mp.commandv("change-list", "script-opts", "append", "ytdl_hook-ytdl_path=" .. y.path)
end

local function chose(y, cb_err)
  ytdlp = y
  if y then
    mp.msg.info(string.format("using %s yt-dlp %s (%s)", y.kind, y.version, y.path))
    tell_ytdl_hook(y)
    if y.kind == "managed" then maybe_auto_update() end
  end
  local waiting = resolving or {}
  resolving = nil
  for _, cb in ipairs(waiting) do cb(y, cb_err) end
end

-- Resolve the yt-dlp to use per the "source" setting, then cb(ytdlp | nil, err).
local function ensure(cb)
  if ytdlp then return cb(ytdlp) end
  if resolving then resolving[#resolving + 1] = cb return end
  resolving = { cb }
  local src = o.source
  local function managed(fallback)
    if utils.file_info(MANAGED) then
      probe({ MANAGED }, function(v)
        if v then return chose({ cmd = { MANAGED }, version = v, path = MANAGED, kind = "managed" }) end
        install_managed(function(y, e) chose(y or fallback, not (y or fallback) and e or nil) end)
      end)
    else
      install_managed(function(y, e)
        if not y and e then toast(e, 6) end
        chose(y or fallback, not (y or fallback) and e or nil)
      end)
    end
  end
  if src == "Managed copy" then return managed(nil) end
  find_system(function(sys)
    if src == "System" then
      if not sys then return chose(nil, "no system yt-dlp found; choose \"Managed copy\" in the plugin settings") end
      if not recent(sys.version) then toast("System yt-dlp " .. sys.version .. " is old; YouTube may fail", 5) end
      return chose(sys)
    end
    if sys and recent(sys.version) then return chose(sys) end
    managed(sys) -- old system copy only as a fallback
  end)
end

local function with_ytdlp(cb)
  ensure(function(y, err)
    if not y then return toast(err or "yt-dlp is not available", 6) end
    cb(y)
  end)
end

-- An http(s) URL without white space or control characters, else nil.
local function valid_url(u)
  u = tostring(u or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if u:match("^[Hh][Tt][Tt][Pp][Ss]?://[^%s%c]+$") then return u end
  return nil
end

-- yt-dlp -J for `target` (a URL or "ytsearchN:query"), always after "--".
local function ytdlp_json(y, args, target, cb)
  run(concat(y.cmd, concat(concat({ "-J", "--no-warnings" }, args), { "--", target })), function(r)
    if r.status ~= 0 then
      local e = (r.stderr or ""):match("ERROR: ([^\n]+)") or r.error_string or "yt-dlp failed"
      return cb(nil, e)
    end
    local j = utils.parse_json(r.stdout or "")
    if not j then return cb(nil, "yt-dlp returned no data") end
    cb(j)
  end)
end

-- ---------- quality, sizes, formats ----------

local function height_limit(q)
  return tonumber((q or ""):match("^(%d+)p")) or math.huge
end

local function fsize(f, dur)
  local s = f.filesize or f.filesize_approx
  if not s and f.tbr and dur then s = f.tbr * 125 * dur end
  return s
end

local function has_v(f) return f.vcodec and f.vcodec ~= "none" end
local function has_a(f) return f.acodec and f.acodec ~= "none" end

local function vcodec_rank(c)
  c = tostring(c or ""):lower()
  if c:match("^av01") then return 4 end
  if c:match("^vp0?9") then return 3 end
  if c:match("^hev") or c:match("^hvc") or c:match("^h265") then return 2 end
  if c:match("^avc") or c:match("^h264") then return 1 end
  return 0
end

local function acodec_rank(c)
  c = tostring(c or ""):lower()
  if c:match("^opus") then return 4 end
  if c:match("^vorbis") then return 3 end
  if c:match("^mp4a") or c:match("^aac") then return 2 end
  if c:match("^mp3") then return 1 end
  return 0
end

-- Sort key of a format, after yt-dlp's default order (lang, quality, res, fps, vcodec,
-- acodec, size, bitrate, protocol): `bv*` / `ba` / `b` pick the highest one. Estimating with
-- the highest bitrate instead picked YouTube's HLS copies (no size, high tbr) and showed
-- about 3× the real size.
local function fkey(f, audio)
  local p = tostring(f.protocol or "https")
  return { tonumber(f.language_preference) or -1, tonumber(f.quality) or -1,
    audio and 0 or (f.height or 0), audio and 0 or (tonumber(f.fps) or 0),
    audio and acodec_rank(f.acodec) or vcodec_rank(f.vcodec), has_a(f) and acodec_rank(f.acodec) or 0,
    (f.filesize or f.filesize_approx) and 1 or 0, f.tbr or f.abr or 0,
    (p == "https" or p == "http") and 1 or 0 }
end

-- Whether format b sorts above a (a may be nil).
local function better(a, b, audio)
  if not a then return true end
  local ka, kb = fkey(a, audio), fkey(b, audio)
  for i = 1, #ka do
    if kb[i] ~= ka[i] then return kb[i] > ka[i] end
  end
  return false
end

-- "1080p" for a 1920×804 format (yt-dlp's format_note), else its height.
local function label(f)
  return tostring(f.format_note or ""):match("^(%d+p)") or (f.height and (f.height .. "p")) or "?"
end

-- Estimated bytes, picked height and its label of what the format selector below would
-- download.
local function estimate(info, q, audio_only, ff)
  local dur = info.duration
  local fm = info.formats or {}
  local ba, bv, bp
  local h = height_limit(q)
  for _, f in ipairs(fm) do
    if has_a(f) and not has_v(f) and better(ba, f, true) then ba = f end
    if has_v(f) and (f.height or 0) <= h then
      if better(bv, f) then bv = f end
      if has_a(f) and better(bp, f) then bp = f end
    end
  end
  if audio_only then
    local f = ba or bp
    return f and fsize(f, dur), nil
  end
  if ff and bv then
    local s = fsize(bv, dur)
    if not has_a(bv) and ba then
      local sa = fsize(ba, dur)
      s = s and sa and s + sa or nil
    end
    return s, bv.height, label(bv)
  end
  if bp then return fsize(bp, dur), bp.height, label(bp) end
  if info.filesize or info.filesize_approx then
    return info.filesize or info.filesize_approx, info.height, info.height and label(info)
  end
  return nil, nil
end

-- mode: "Video" | "Audio only" (default: the setting).
local function format_args(ff, mode)
  mode = mode or o.mode
  if mode == "Audio only" then
    local a = { "-f", "ba/b" }
    local af = o["audio-format"]
    if af ~= "Original" then
      if ff then
        a = concat(a, { "-x", "--audio-format", af })
      else
        toast("Converting to " .. af .. " needs ffmpeg; keeping the original audio", 5)
      end
    end
    return a
  end
  local h = height_limit(o.quality)
  local lim = h == math.huge and "" or "[height<=" .. h .. "]"
  if ff then return { "-f", "bv*" .. lim .. "+ba/b" .. lim .. "/b" } end
  -- Without ffmpeg yt-dlp cannot merge: single files with video and audio only.
  return { "-f", "b" .. lim .. "/b" }
end

-- ---------- ffmpeg ----------

local FF_DIR = DATA .. SEP .. "ffmpeg"
local FF_MANAGED = FF_DIR .. SEP .. "ffmpeg" .. EXE
local FF_UPDATE_EVERY = 30 * 86400

local function rmtree(dir, cb)
  if windows then run({ "cmd", "/c", "rmdir", "/s", "/q", dir }, cb or function() end)
  else run({ "rm", "-rf", dir }, cb or function() end) end
end

local function read_file(p)
  local f = io.open(p, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(p, s)
  local f = io.open(p, "w")
  if f then f:write(s) f:close() end
end

local function ff_probe(exe, cb)
  run({ exe, "-version" }, function(r)
    cb(r.status == 0 and ((r.stdout or ""):match("ffmpeg version (%S+)") or "?") or nil)
  end)
end

-- System ffmpeg (never inside the Flatpak: the runtime has none and PATH holds no host tools).
local function find_system_ffmpeg(cb)
  if FLATPAK or os.getenv("VIVI_TEST_NO_SYSTEM_FFMPEG") then return cb(nil) end
  local list, seen = {}, {}
  local function add(dir)
    if not dir or dir == "" or dir == FF_DIR or dir == BIN_DIR then return end
    local p = dir .. SEP .. "ffmpeg" .. EXE
    if not seen[p] and utils.file_info(p) then seen[p] = true list[#list + 1] = p end
  end
  for dir in (os.getenv("PATH") or ""):gmatch(windows and "[^;]+" or "[^:]+") do add(dir) end
  if not windows then
    for _, d in ipairs({ "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin", "/opt/local/bin", "/snap/bin" }) do add(d) end
  end
  local i = 0
  local function nxt()
    i = i + 1
    if not list[i] then return cb(nil) end
    ff_probe(list[i], function(v)
      if v then
        local dir = list[i]:match("^(.*)[/\\][^/\\]+$")
        cb({ kind = "system", path = list[i], dir = dir, version = v })
      else nxt() end
    end)
  end
  nxt()
end

-- Vivi's own minimal static ffmpeg + ffprobe (helpers/ffmpeg/build.sh, release
-- helper-ffmpeg-v<build>): only the muxers/demuxers and audio codecs yt-dlp needs, about
-- 6-12 MB for both. The checksums are pinned here, so a new build comes with a plugin update.
local FF_BUILD = {
  tag = "helper-ffmpeg-v8.0-1",
  base = "https://github.com/Loafer19/vivi-plugins/releases/download/",
  sha = {
    ["ffmpeg-linux-aarch64"] = "307ffd8e2394ec06e35cc59a1a01c5fd812af78a02987c6204822297e567e7af",
    ["ffmpeg-linux-x86_64"] = "33eb6cf11c72c1f41ee62e0b31d458b4184daf4bfa89a474bf5c79a36f6e6527",
    ["ffmpeg-macos-aarch64"] = "47e80364f7ec81d3572d53b12ded16c7131711708709a7560279f3b21567c9ec",
    ["ffmpeg-windows-x86_64.exe"] = "65ddf95601d990b03aa006ca6ab1d3db2eabf8155373f5a41f67eae36f560f3e",
    ["ffprobe-linux-aarch64"] = "a88b8bd5b5b2408155bde6565e72a8b8bda7816759fef52cfce8e1dcca3d7a85",
    ["ffprobe-linux-x86_64"] = "c486ed98eb69d3e1f7164dec8e7bc88676455dbd953727a567518c9682310830",
    ["ffprobe-macos-aarch64"] = "c2079f617fd3c30686445a12598f4d0c8928e92ed8101158aa429cfd7d75d345",
    ["ffprobe-windows-x86_64.exe"] = "8f883f23334ba858411f14e2337e2801b97b147b1d05cc0e9aa04b87b2e947aa",
  },
}

-- What to download for this computer: cb({ files = { {url, sha, members} }, id }) or cb(nil, err).
local function ff_source(cb)
  local function pick(plat)
    local files = {}
    for _, prog in ipairs({ "ffmpeg", "ffprobe" }) do
      local asset = prog .. "-" .. plat .. EXE
      local sha = FF_BUILD.sha[asset]
      if not sha then return cb(nil, "no managed ffmpeg for " .. plat .. "; install ffmpeg to merge or convert") end
      files[#files + 1] = { url = FF_BUILD.base .. FF_BUILD.tag .. "/" .. asset, sha = sha, members = { prog .. EXE } }
    end
    cb({ id = FF_BUILD.tag .. ":" .. plat, files = files })
  end
  if windows then
    local a = (os.getenv("PROCESSOR_ARCHITEW6432") or os.getenv("PROCESSOR_ARCHITECTURE") or ""):upper()
    return pick(a == "ARM64" and "windows-aarch64" or "windows-x86_64")
  end
  run({ "uname", "-sm" }, function(u)
    local s = u.stdout or ""
    local arch = (s:match("x86_64") and "x86_64") or ((s:match("aarch64") or s:match("arm64")) and "aarch64") or "?"
    if s:match("Linux") then return pick("linux-" .. arch) end
    if s:match("Darwin") then return pick("macos-" .. arch) end
    cb(nil, "no managed ffmpeg for " .. s:gsub("%s+$", ""))
  end)
end

-- Download, verify and install the managed ffmpeg + ffprobe. cb(ff | nil, err)
local function install_ffmpeg(src, cb)
  local tmp = FF_DIR .. SEP .. ".x"
  local function fail(msg) rmtree(tmp) cb(nil, msg) end
  local function finish()
    for _, prog in ipairs({ "ffmpeg", "ffprobe" }) do
      local found
      for _, f in ipairs(src.files) do
        for _, m in ipairs(f.members) do
          local pth = tmp .. SEP .. m:gsub("/", SEP)
          if m:sub(-#(prog .. EXE) - 1) == "/" .. prog .. EXE or m == prog .. EXE then
            if utils.file_info(pth) then found = pth end
          end
        end
      end
      if not found then return fail(prog .. " missing from the download") end
      local dst = FF_DIR .. SEP .. prog .. EXE
      os.remove(dst)
      local ok, e = os.rename(found, dst)
      if not ok then return fail(e) end
    end
    rmtree(tmp)
    write_file(FF_DIR .. SEP .. "source", src.id)
    write_file(FF_DIR .. SEP .. "last-update", tostring(os.time()))
    local function probe_new()
      ff_probe(FF_MANAGED, function(v)
        if not v then return cb(nil, "the downloaded ffmpeg does not run") end
        cb({ kind = "managed", path = FF_MANAGED, dir = FF_DIR, version = v })
      end)
    end
    if windows then return probe_new() end
    run({ "chmod", "755", FF_MANAGED, FF_DIR .. "/ffprobe" }, probe_new)
  end
  local function verify(file, want, nxt)
    sha256(file, function(got)
      if not got then return fail("no sha256 tool (sha256sum/shasum/certutil) to verify ffmpeg") end
      if got ~= want then return fail("ffmpeg checksum mismatch, not installed") end
      nxt()
    end)
  end
  local function fetch(i)
    local f = src.files[i]
    if not f then return finish() end
    local dl = tmp .. SEP .. f.members[1]
    run({ "curl", "-fsSL", "--retry", "2", "-o", dl, f.url }, function(r)
      if r.status ~= 0 then return fail("ffmpeg download failed: " .. (r.stderr or "")) end
      verify(dl, f.sha, function() fetch(i + 1) end)
    end)
  end
  rmtree(tmp, function()
    mkdir(tmp, function()
      -- Announce the download size first (HEAD requests).
      local n, total = 0, 0
      for _, f in ipairs(src.files) do
        remote_size(f.url, function(sz)
          total = total + (sz or 0)
          n = n + 1
          if n == #src.files then
            toast("Downloading ffmpeg (" .. human(total) .. ") for merging / converting…", 6)
            fetch(1)
          end
        end)
      end
    end)
  end)
end

local ffm = nil        -- { kind = "system"|"managed", path, dir, version }
local ff_waiting = nil

-- ffmpeg if available; with `need`, download the managed copy when there is none.
local function get_ffmpeg(need, cb)
  if ffm then return cb(ffm) end
  if ff_waiting then ff_waiting[#ff_waiting + 1] = { need, cb } return end
  ff_waiting = { { need, cb } }
  local function finish(f, err)
    ffm = f
    local w = ff_waiting
    ff_waiting = nil
    local needers_failed = false
    for _, x in ipairs(w) do
      if not f and x[1] and err then needers_failed = true end
      x[2](f)
    end
    if needers_failed then toast(err, 8) end
  end
  find_system_ffmpeg(function(sys)
    if sys then return finish(sys) end
    if utils.file_info(FF_MANAGED) then
      return ff_probe(FF_MANAGED, function(v)
        if v then return finish({ kind = "managed", path = FF_MANAGED, dir = FF_DIR, version = v }) end
        finish(nil)
      end)
    end
    local any_need = false
    for _, x in ipairs(ff_waiting) do any_need = any_need or x[1] end
    if not any_need then return finish(nil) end
    ff_source(function(src, e)
      if not src then return finish(nil, e) end
      mkdir(FF_DIR, function() install_ffmpeg(src, function(f, e2) finish(f, e2) end) end)
    end)
  end)
end

-- Re-download the managed ffmpeg when the published build changed.
local function update_ffmpeg(quiet)
  if not utils.file_info(FF_MANAGED) then
    if not quiet then toast("No managed ffmpeg installed (it is downloaded when needed)") end
    return
  end
  ff_source(function(src, e)
    write_file(FF_DIR .. SEP .. "last-update", tostring(os.time()))
    if not src then if not quiet then toast("ffmpeg update: " .. e, 6) end return end
    if (read_file(FF_DIR .. SEP .. "source") or "") == src.id then
      if not quiet then toast("ffmpeg is up to date (" .. (ffm and ffm.version or "managed") .. ")") end
      return
    end
    install_ffmpeg(src, function(f, e2)
      if f then
        if not ffm or ffm.kind == "managed" then ffm = f end
        toast("ffmpeg updated to " .. f.version, 5)
      else
        toast("ffmpeg update failed: " .. e2, 6)
      end
    end)
  end)
end

local function maybe_update_ffmpeg()
  if not o["auto-update"] or not utils.file_info(FF_MANAGED) then return end
  local t = tonumber(read_file(FF_DIR .. SEP .. "last-update") or "") or 0
  if os.time() - t > FF_UPDATE_EVERY then update_ffmpeg(true) end
end

-- Whether the current settings need ffmpeg (and may download it).
local function needs_ffmpeg(mode)
  if (mode or o.mode) == "Audio only" then return o["audio-format"] ~= "Original" end
  return height_limit(o.quality) >= 1080
end

-- Whether `info` has one file with video and audio up to quality q (what `b[height<=H]`
-- downloads without ffmpeg). Sites without a format list count as single files.
local function has_single(info, q)
  if type(info.formats) ~= "table" or #info.formats == 0 then return true end
  local h = height_limit(q)
  for _, f in ipairs(info.formats) do
    if has_v(f) and has_a(f) and (f.height or 0) <= h then return true end
  end
  return false
end

local QUALITIES = { "Best available", "2160p", "1440p", "1080p", "720p", "480p", "360p" }

-- Estimated size per quality, highest first (qualities that pick the same file once):
-- { { text = "1080p ≈ 86 MB", mine = <what the Download quality setting picks> }, …, audio }.
local function size_parts(info, ff)
  local function ffq(q) return ff or height_limit(q) >= 1080 or not has_single(info, q) end
  local ms, mh = estimate(info, o.quality, false, ffq(o.quality))
  local parts, seen = {}, {}
  for _, q in ipairs(QUALITIES) do
    local s, h, lbl = estimate(info, q, false, ffq(q))
    local key = tostring(h) .. tostring(s)
    if h and not seen[key] then
      seen[key] = true
      parts[#parts + 1] = { text = (q == "Best available" and "best " or "") .. lbl .. " ≈ " .. human(s),
        mine = mh == h and ms == s }
    end
  end
  parts[#parts + 1] = { text = "audio ≈ " .. human((estimate(info, nil, true, ff))), mine = false }
  return parts
end

local function size_list(info, ff)
  local t = {}
  for _, x in ipairs(size_parts(info, ff)) do t[#t + 1] = x.text end
  return table.concat(t, " · ")
end

-- The playing http(s) URL, or nil.
local function playing_url()
  return valid_url(mp.get_property("path", ""))
end

-- The URL setting, else the playing URL: url, from_setting. A URL setting that is not an
-- http(s) URL is refused (it would reach yt-dlp's command line).
local function current_url()
  local u = (o.url or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if u ~= "" then
    local v = valid_url(u)
    if not v then return nil, "not an http(s) URL: " .. u:sub(1, 60) end
    return v, true
  end
  return playing_url(), false
end

-- One video's info (first entry for a playlist URL), cached per URL. Only the first entry
-- of a playlist is extracted (--playlist-items 1), not the whole list.
local cached = 0
local function video_info(y, url, cb)
  if info_cache[url] then return cb(info_cache[url]) end
  ytdlp_json(y, { "--playlist-items", "1" }, url, function(j, e)
    if not j then return cb(nil, e) end
    cached = cached + 1
    if cached > 60 then info_cache, cached = {}, 1 end -- about 150 KB of JSON per video
    if j._type == "playlist" then
      local first = j.entries and j.entries[1]
      if type(first) ~= "table" then return cb(nil, "empty playlist") end
      first._playlist = j.title
      first._count = j.playlist_count
      info_cache[url] = first
      return cb(first)
    end
    info_cache[url] = j
    cb(j)
  end)
end

-- ---------- actions ----------

local NAME = "YouTube"

-- Vivi (0.13+, min_vivi) sets user-data/vivi/downloads: downloads are rows in its panel.
-- Unset only in a plain mpv, where progress goes to the OSD instead.
local function panel()
  return tostring(mp.get_property_native("user-data/vivi/downloads", "")) == "1"
end

-- "mpv v0.38.0", "mpv 0.40.0-dev" -> whether the minor version is at least `minor`.
local function mpv_at_least(v, minor)
  local maj, mi = tostring(v or ""):match("(%d+)%.(%d+)")
  if not maj then return true end
  return tonumber(maj) > 0 or tonumber(mi) >= minor
end

local function fmt_dur(s)
  s = tonumber(s)
  if not s or s <= 0 then return "" end
  s = math.floor(s + 0.5)
  local h, m, sec = math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
  return string.format("%d:%02d", m, sec)
end

local function short_count(n)
  n = tonumber(n)
  if not n then return nil end
  if n >= 1e9 then return string.format("%.1fB", n / 1e9) end
  if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
  if n >= 1e3 then return string.format("%.0fK", n / 1e3) end
  return tostring(math.floor(n))
end

local function is_youtube(e)
  return e.ie_key == "Youtube" or (e.extractor_key or "") == "Youtube"
end

-- Playlists and channels (listed, not played) in flat yt-dlp output.
local function is_container(e)
  return e._type == "playlist" or e.ie_key == "YoutubeTab" or (e.extractor_key or "") == "YoutubeTab"
end

-- The entry's http(s) URL (flat entries of YouTube may only carry the video id), or nil.
local function entry_url(e)
  local u = e.webpage_url or e.url
  local v = valid_url(u)
  if v then return v end
  if is_youtube(e) and tostring(e.id or u or ""):match("^[%w_-]+$") then
    return "https://www.youtube.com/watch?v=" .. (e.id or u)
  end
  return nil
end

-- Vivi decodes JPEG and PNG covers only. YouTube serves its sized thumbnails
-- (`…/hqdefault.jpg?sqp=…`, `vi_webp/…`) as WebP, which showed no cover at all; without the
-- query (and from `vi/` instead of `vi_webp/`) the same image comes as JPEG.
local function jpeg_thumb(u)
  local host, path = tostring(u or ""):match("^https?://([%w.-]*ytimg%.com)(/[^?#]*)")
  if not host then return u end
  path = path:gsub("^/vi_webp/", "/vi/"):gsub("%.webp$", ".jpg")
  return "https://" .. host .. path
end

-- A small thumbnail URL of an entry (YouTube videos: i.ytimg.com by id), or "".
local function thumb(e)
  if is_youtube(e) and not is_container(e) and tostring(e.id or ""):match("^[%w_-]+$") then
    return "https://i.ytimg.com/vi/" .. e.id .. "/mqdefault.jpg" -- 320×180 JPEG, always there
  end
  local best, bw
  for _, t in ipairs(e.thumbnails or {}) do
    local w = tonumber(t.width) or 0
    if valid_url(t.url) and (not best or (w <= 480 and w > bw) or (bw > 480 and w < bw)) then best, bw = t.url, w end
  end
  if best then return jpeg_thumb(best) end
  if valid_url(e.thumbnail) then return jpeg_thumb(e.thumbnail) end
  return ""
end

local function channel(e)
  return e.channel or e.uploader or e.playlist_uploader or ""
end

-- Title, channel and thumbnail of queued URLs for Vivi's now-playing card and the shared
-- now playing.
local function describe(list)
  local items = {}
  for _, e in ipairs(list) do
    local u = entry_url(e)
    if u and e.title then
      items[#items + 1] = { url = u, title = e.title, artist = channel(e), cover = thumb(e), info = NAME,
        kind = "video", duration = tonumber(e.duration) }
    end
  end
  if #items > 0 then mp.commandv("script-message", "vivi-media-meta", ID, utils.format_json({ items = items })) end
end

-- mode: "append-play" (queue) or "replace" (play now).
local function loadfile(url, title, mode)
  mode = mode or "append-play"
  if title and title ~= "" then
    local opts = "force-media-title=%" .. #title .. "%" .. title
    if mpv_at_least(mp.get_property("mpv-version", ""), 38) then
      mp.command_native({ "loadfile", url, mode, -1, opts })
    else
      mp.command_native({ "loadfile", url, mode, opts })
    end
  else
    mp.commandv("loadfile", url, mode)
  end
end

local function queue(list, mode)
  local n, first = 0, true
  local queued = {}
  for _, e in ipairs(list) do
    local u = entry_url(e)
    if u and not is_container(e) then
      loadfile(u, e.title, (mode == "replace" and first) and "replace" or "append-play")
      first = false
      n = n + 1
      queued[#queued + 1] = e
    end
  end
  describe(queued)
  return n
end

local function add_to_playlist(url)
  local err
  if not url then url, err = current_url() end
  if not url then
    return toast(err and ("YouTube: " .. err) or "Enter a video or playlist URL in the YouTube plugin settings (or press Alt+U)", 5)
  end
  with_ytdlp(function(y)
    toast("Reading " .. url .. "…", 2)
    ytdlp_json(y, { "--flat-playlist" }, url, function(j, e)
      if not j then return toast("YouTube: " .. e, 6) end
      if j._type == "playlist" then
        local n = queue(j.entries or {})
        toast(string.format("Added %d entries from %s", n, j.title or "the playlist"), 4)
      else
        if j.formats then info_cache[url] = j end
        j.webpage_url = j.webpage_url or url
        queue({ j })
        toast("Added " .. (j.title or url), 3)
      end
    end)
  end)
end

local function show_sizes()
  local url, err = current_url()
  if not url then return toast(err and ("YouTube: " .. err) or "Enter a video URL first") end
  with_ytdlp(function(y)
    toast("Checking sizes…", 2)
    get_ffmpeg(false, function(ff)
      video_info(y, url, function(info, e)
        if not info then return toast("YouTube: " .. e, 6) end
        local head = info._playlist and ("First video of " .. info._playlist .. ": ") or ""
        local note = (not ff and has_single(info, "720p")) and " (below 1080p without ffmpeg: single-file formats)" or ""
        toast(head .. size_list(info, ff ~= nil) .. note, 10)
      end)
    end)
  end)
end

local function default_folder()
  return HOME .. SEP .. "Downloads" .. SEP .. "Vivi"
end

-- ---------- downloads (one at a time, queued; Vivi's Downloads panel when it has one) ----------

local LOG_DIR = DATA .. SEP .. "logs"
local PROGRESS = "download:[vivi] %(progress.downloaded_bytes)s|%(progress.total_bytes,progress.total_bytes_estimate)s|%(progress.eta)s|%(progress.speed)s|%(info.playlist_index)s|%(info.n_entries)s|%(info.title)s"

local jobs, order = {}, {} -- job id -> job; ids in the order they were added
local active = nil         -- the running job
local seq = 0

-- Vivi reads done / total / speed as whole bytes: one fractional value (yt-dlp's speed is
-- one) made it drop the whole report, so the row stayed at "Starting…" with no progress.
local function report(j, t)
  if not panel() then return end
  for _, k in ipairs({ "done", "total", "speed" }) do
    if type(t[k]) == "number" then t[k] = math.max(0, math.floor(t[k])) end
  end
  mp.commandv("script-message", "vivi-download", ID, j.id, utils.format_json(t))
end

-- The last "[vivi] …" progress line of a log: { done, total, eta, speed, idx, n, title } or nil.
local function parse_progress(s)
  local line
  for l in (s or ""):gmatch("%[vivi%][^\r\n]*") do line = l end
  if not line then return nil end
  local d, t, eta, sp, idx, n, title = line:match("^%[vivi%] *([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)|(.*)$")
  if not d then return nil end
  return { line = line, done = tonumber(d), total = tonumber(t), eta = tonumber(eta), speed = tonumber(sp),
    idx = tonumber(idx), n = tonumber(n), title = title ~= "NA" and title or nil }
end

-- Final paths yt-dlp printed (`--print after_move:[vivi-file] %(filepath)s`).
local function printed_files(s)
  local out = {}
  for f in (s or ""):gmatch("%[vivi%-file%] ([^\r\n]+)") do out[#out + 1] = f end
  return out
end

local function progress_text(p)
  local msg = "Downloading"
  if p.done and p.total and p.total > 0 then
    msg = string.format("%s %.0f%% of %s", msg, p.done * 100 / p.total, human(p.total))
  end
  if p.eta then msg = msg .. ", ETA " .. fmt_dur(p.eta) end
  if p.idx and p.n then msg = msg .. string.format(" (%d/%d)", p.idx, p.n) end
  if p.title then msg = msg .. " · " .. p.title end
  return msg
end

-- yt-dlp arguments of a download (without the yt-dlp command itself).
local function download_args(j, folder, ff, ffi)
  local audio = j.audio
  local a = { "--newline", "--progress", "--no-colors", j.no_playlist and "--no-playlist" or "--yes-playlist",
    "--progress-template", PROGRESS,
    "--print", "after_move:[vivi-file] %(filepath)s",
    -- Audio gets its own name: -x deletes its source file, which could be a video
    -- downloaded earlier under the same name.
    "-P", folder, "-o", "%(playlist_index&{} - |)s%(title)s [%(id)s]" .. (audio and " (audio)" or "") .. ".%(ext)s" }
  a = concat(a, format_args(ff, audio and "Audio only" or "Video"))
  if ffi then a = concat(a, { "--ffmpeg-location", ffi.dir }) end
  return concat(a, { "--", j.url })
end

local pump

local function finish(j, state, t, msg, secs)
  j.state = state
  if active == j then active = nil end
  report(j, t)
  if msg then toast(msg, secs) end
  pump()
end

local function start(j)
  active = j
  j.state = "active"
  j.cancelled = false
  report(j, { state = "active", detail = "Starting…" })
  with_ytdlp(function(y)
    local mode = j.audio and "Audio only" or "Video"
    -- The video's formats first: YouTube often has no single file with video and audio
    -- below 1080p either, and then even 720p needs ffmpeg to merge.
    video_info(y, j.url, function(info)
      if j.cancelled then return finish(j, "failed", { state = "cancelled", error = "Cancelled", detail = "" }) end
      local need = needs_ffmpeg(mode) or (not j.audio and info ~= nil and not has_single(info, o.quality))
      get_ffmpeg(need, function(ffi)
        if j.cancelled then return finish(j, "failed", { state = "cancelled", error = "Cancelled", detail = "" }) end
        local ff = ffi ~= nil
        if not ff and need then
          return finish(j, "failed", { state = "failed", error = "needs ffmpeg, which could not be installed", detail = "" },
            needs_ffmpeg(mode) and "Download needs ffmpeg, which could not be installed; pick a lower quality or Original audio"
              or "This video needs ffmpeg to merge video and audio, and it could not be installed", 8)
        end
        local folder = (o.folder or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if folder == "" then folder = default_folder() end
        folder = folder:gsub("^~", HOME)
        local function go()
          mkdir(folder, function() mkdir(LOG_DIR, function()
            if j.cancelled then return finish(j, "failed", { state = "cancelled", error = "Cancelled", detail = "" }) end
            local log = LOG_DIR .. SEP .. j.id .. ".log"
            os.remove(log)
            local args = concat(y.cmd, download_args(j, folder, ff, ffi))
            local timer, last
            if not windows then
              -- Only stdout (progress, printed file names) goes to the log: stderr must stay
              -- a pipe to mpv, which stops watching for an abort once every pipe is closed,
              -- so with both redirected Cancel (and quitting Vivi) left yt-dlp running.
              args = concat({ "sh", "-c", 'log=$1; shift; exec "$@" >"$log"', "sh", log }, args)
              timer = mp.add_periodic_timer(2, function()
                local f = io.open(log, "r")
                if not f then return end
                local size = f:seek("end") or 0
                f:seek("set", math.max(0, size - 4096)) -- the last lines: yt-dlp writes one per update
                local p = parse_progress(f:read("*a"))
                f:close()
                if not p or p.line == last then return end
                last = p.line
                local share = p.done and p.total and p.total > 0 and p.done / p.total or nil
                report(j, { state = "active", done = p.done or 0, total = p.total or 0, speed = p.speed,
                  progress = share, detail = p.idx and p.n and string.format("%d / %d · %s", p.idx, p.n, p.title or "") or "" })
                if not panel() then toast(progress_text(p), 3) end
              end)
            end
            j.cmd = run(args, function(r)
              j.cmd = nil
              if timer then timer:kill() end
              local out = (r.stdout or "") .. (r.stderr or "")
              local f = io.open(log, "r")
              if f then out = out .. f:read("*a") f:close() end
              os.remove(log)
              local files = printed_files(out)
              if r.killed_by_us or j.cancelled then
                return finish(j, "failed", { state = "cancelled", error = "Cancelled", detail = "" }, "Download cancelled")
              elseif r.status == 0 then
                local path = files[#files]
                local fi = path and utils.file_info(path)
                local what = #files > 1 and string.format("%d files", #files) or (path and path:match("([^/\\]+)$")) or "done"
                return finish(j, "done", { state = "done", path = path, done = fi and fi.size, total = fi and fi.size,
                  progress = 1, detail = #files > 1 and string.format("%d files in %s", #files, folder) or "" },
                  "Downloaded " .. what .. " to " .. folder, 6)
              end
              local e = out:match("ERROR: ([^\n]+)") or r.error_string or "yt-dlp error"
              finish(j, "failed", { state = "failed", error = e, detail = "" }, "Download failed: " .. e, 8)
            end, windows) -- Windows has no sh: capture stdout for the printed file names
          end) end)
        end
        -- Estimated size first (single videos; playlists say how many entries).
        if info then
          local s, _, lbl = estimate(info, o.quality, j.audio, ff)
          local what = j.audio and "audio" or (lbl or o.quality)
          j.title = j.title or info._playlist or info.title
          j.art = (j.art and j.art ~= "") and j.art or thumb(info)
          report(j, { title = j.title, artwork = j.art ~= "" and j.art or nil, subtitle = channel(info), state = "active",
            total = (not info._playlist and s) and math.floor(s) or 0 })
          local pl = info._playlist and (" each, playlist " .. info._playlist) or ""
          toast(string.format("Downloading %s (%s ≈ %s%s) to %s", info.title or j.url, what, human(s), pl, folder), 5)
        else
          toast("Downloading " .. j.url .. " to " .. folder, 4)
        end
        go()
      end)
    end)
  end)
end

pump = function()
  if active then return end
  for _, id in ipairs(order) do
    local j = jobs[id]
    if j and j.state == "queued" then return start(j) end
  end
end

-- Queue a download: url (http(s)), opts { audio, title, art, no_playlist }.
local function enqueue(url, opts)
  opts = opts or {}
  local u = valid_url(url)
  if not u then return toast("YouTube: not an http(s) URL") end
  seq = seq + 1
  local j = { id = string.format("yt-%d-%d", os.time(), seq), url = u, audio = opts.audio or false,
    title = opts.title, art = opts.art, no_playlist = opts.no_playlist, state = "queued" }
  jobs[j.id] = j
  order[#order + 1] = j.id
  report(j, { title = j.title or u, artwork = (j.art and j.art ~= "") and j.art or nil, state = "queued",
    subtitle = j.audio and "Audio" or o.quality })
  if active then toast("Queued: " .. (j.title or u) .. " (after the running download)", 3) end
  pump()
  return j
end

-- The URL setting (playlists allowed), else the playing video (only that video, even
-- when its URL names a playlist).
local function download(audio)
  local url, from_setting = current_url()
  if not url then
    return toast(type(from_setting) == "string" and ("YouTube: " .. from_setting)
      or "Enter a video or playlist URL first, or play a video", 5)
  end
  enqueue(url, { audio = audio == nil and o.mode == "Audio only" or audio, no_playlist = not from_setting })
end

local function download_current(audio)
  local url = playing_url()
  if not url then return toast("Play a YouTube (or other yt-dlp) video first") end
  enqueue(url, { audio = audio == nil and o.mode == "Audio only" or audio, no_playlist = true,
    title = mp.get_property("media-title") })
end

local function cancel_job(id)
  local j = jobs[id or ""]
  if not j then return end
  j.cancelled = true
  if j.cmd then return mp.abort_async_command(j.cmd) end
  if j.state == "queued" then
    j.state = "failed"
    report(j, { state = "cancelled", error = "Cancelled", detail = "" })
  end
end

local function retry_job(id)
  local j = jobs[id or ""]
  if not j then return toast("This download is from an earlier session: start it again") end
  if j.state == "active" or j.state == "queued" then return end
  j.state = "queued"
  j.cancelled = false
  report(j, { state = "queued", error = "" })
  pump()
end

-- Settings "Cancel": the running download and everything queued.
local function cancel()
  local any = false
  for _, id in ipairs(order) do
    local j = jobs[id]
    if j and (j.state == "queued" or j.state == "active") then any = true cancel_job(id) end
  end
  if not any then toast("No download is running") end
end

-- ---------- search / browse dialog ----------

local S = { open = false, items = {}, sel = nil, q = "", n = 30, back = {}, title = nil, req = 0, more = false,
  fetching = nil }
local SEARCH_STEP, SEARCH_MAX = 30, 150

local function send_dialog(t)
  mp.commandv("script-message", "vivi-dialog", ID, utils.format_json(t))
end

local function rows()
  local out = {}
  for i, e in ipairs(S.items) do
    local sub = {}
    if channel(e) ~= "" then sub[#sub + 1] = channel(e) end
    local v = short_count(e.view_count)
    if v then sub[#sub + 1] = v .. " views" end
    if is_container(e) and e.playlist_count then sub[#sub + 1] = e.playlist_count .. " videos" end
    out[#out + 1] = { title = e.title or entry_url(e) or "?", sub = table.concat(sub, " · "),
      dur = (e.live_status == "is_live" and "LIVE") or fmt_dur(e.duration), cover = thumb(e),
      badge = is_container(e) and "Playlist" or (e.live_status == "is_live" and "Live" or ""),
      dl = entry_url(e) ~= nil, selected = i == S.sel }
  end
  return out
end

local function actions()
  local a = {}
  if #S.back > 0 then a[#a + 1] = "‹ Back" end
  for _, x in ipairs({ "Queue", "Queue all", "Download audio" }) do a[#a + 1] = x end
  return a
end

-- The download quality, chosen in the dialog too (the same setting).
local function filters()
  return { { name = "Quality", options = QUALITIES, value = "Download quality: " .. o.quality } }
end

local function secondary_label()
  return "Download " .. (o.quality == "Best available" and "best" or o.quality)
end

-- Detail pane of the selected row: what it is, and for a video the estimated size of
-- each quality (read in the background with yt-dlp -J, then cached).
local function detail(it)
  if not it then return { detail = "", detail_cover = "" } end
  local d = { it.title or "?", "" }
  local function add(k, v) if v and v ~= "" then d[#d + 1] = k .. ": " .. v end end
  local u = entry_url(it)
  local info = u and info_cache[u]
  add(is_container(it) and "By" or "Channel", channel(it))
  if is_container(it) then
    add("Videos", it.playlist_count and tostring(it.playlist_count))
  else
    add("Length", it.live_status == "is_live" and "live now" or fmt_dur(it.duration))
    add("Views", short_count(it.view_count))
    if info then
      local y, m, dd = tostring(info.upload_date or ""):match("^(%d%d%d%d)(%d%d)(%d%d)$")
      if y then add("Uploaded", y .. "-" .. m .. "-" .. dd) end
      add("License", info.license)
    end
  end
  if not is_container(it) and u then
    d[#d + 1] = ""
    if info and info.formats then
      d[#d + 1] = "Estimated download size:"
      for _, x in ipairs(size_parts(info, ffm ~= nil)) do
        d[#d + 1] = "  " .. x.text .. (x.mine and "   ← Download" or "")
      end
    elseif S.fetching == u then
      d[#d + 1] = "Checking the sizes…"
    elseif S.size_err and S.size_err[u] then
      d[#d + 1] = "Sizes: " .. S.size_err[u]
    end
  end
  if u then d[#d + 1] = "" d[#d + 1] = u end
  local cover = thumb(it)
  if is_youtube(it) and not is_container(it) and tostring(it.id or ""):match("^[%w_-]+$") then
    cover = "https://i.ytimg.com/vi/" .. it.id .. "/mqdefault.jpg"
  end
  return { detail = table.concat(d, "\n"), detail_cover = cover }
end

local function selected() return S.sel and S.items[S.sel] end

local function show_detail()
  if not S.open then return end
  local t = detail(selected())
  t.copy = selected() and entry_url(selected()) or ""
  send_dialog(t)
end

-- Read the selected video's formats (one at a time; the newest selection wins).
local function fetch_sizes()
  local it = selected()
  local u = it and not is_container(it) and it.live_status ~= "is_live" and entry_url(it)
  if not u or S.fetching or (info_cache[u] and info_cache[u].formats) then return end
  S.fetching = u
  show_detail()
  with_ytdlp(function(y)
    get_ffmpeg(false, function()
      video_info(y, u, function(_, e)
        S.fetching = nil
        if e then S.size_err = S.size_err or {} S.size_err[u] = e end
        show_detail()
        fetch_sizes() -- the selection may have moved on meanwhile
      end)
    end)
  end)
end

local function show(status)
  local n = #S.items
  local t = detail(selected())
  t.rows, t.busy, t.actions, t.has_more, t.filters = rows(), false, actions(), S.more, filters()
  t.status = status or (S.title and (S.title .. " · ") or "") .. (n == 1 and "1 result" or (n .. " results"))
  send_dialog(t)
end

-- q: a link (listed as it is: video, playlist, channel) or a search.
local function load(q, keep)
  q = tostring(q or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if q == "" then return show("Type something to search YouTube, or paste a link") end
  S.q = q
  if not keep then S.n = SEARCH_STEP end
  S.req = S.req + 1
  local req = S.req
  send_dialog({ busy = true, query = q, status = valid_url(q) and "Reading the link…" or "Searching YouTube…" })
  with_ytdlp(function(y)
    local target = valid_url(q) or string.format("ytsearch%d:%s", S.n, q)
    ytdlp_json(y, { "--flat-playlist" }, target, function(j, e)
      if req ~= S.req or not S.open then return end -- a newer search, or closed meanwhile
      if not j then
        S.items = {}
        return show("YouTube: " .. tostring(e))
      end
      local keep_sel = keep and S.sel
      if j._type == "playlist" then
        S.items = {}
        for _, it in ipairs(j.entries or {}) do if type(it) == "table" then S.items[#S.items + 1] = it end end
        S.title = valid_url(q) and j.title or nil
        S.more = not valid_url(q) and #S.items >= S.n and S.n < SEARCH_MAX
      else
        j.webpage_url = j.webpage_url or valid_url(q)
        if j.formats and j.webpage_url then info_cache[j.webpage_url] = j end
        S.items, S.title, S.more = { j }, nil, false
      end
      S.sel = keep_sel or (#S.items == 1 and 1 or nil)
      show()
      fetch_sizes()
    end)
  end)
end

-- Open the dialog; with `q` (a pasted link), list it right away.
local function open(q)
  S.open = true
  send_dialog({ open = true, title = NAME, placeholder = "Search YouTube, or paste a video, playlist or channel link",
    search_label = "Search", query = q or S.q, primary = "Play", secondary = secondary_label(), grid_toggle = true,
    grid = o.view == "Grid", rows = rows(), actions = actions(), filters = filters(),
    status = #S.items == 0 and "Search YouTube, or paste a link" or nil })
  if q then
    S.back = {}
    load(q)
  end
end

local function index(args)
  local i = tonumber((args or {})[1])
  if i and i >= 0 then return math.floor(i) + 1 end -- the dialog counts from 0; -1: none
end

local function on_ui(json)
  local e = utils.parse_json(json or "")
  if type(e) ~= "table" then return end
  local ev, args = tostring(e.event or ""), e.args or {}
  local function item() local i = index(args) or S.sel if i then S.sel = i end return S.sel and S.items[S.sel] end
  if ev == "search" then
    S.back = {}
    load(e.query)
  elseif ev == "select" then
    local i = index(args)
    S.sel = i and S.items[i] and i or nil
    show_detail()
    fetch_sizes()
  elseif ev == "primary" then
    local it = item()
    if not it then return end
    if is_container(it) then
      local u = entry_url(it)
      if not u then return end
      S.back[#S.back + 1] = { q = S.q, items = S.items, title = S.title, more = S.more, n = S.n, sel = S.sel }
      S.sel = nil
      load(u)
    else
      queue({ it }, "replace")
    end
  elseif ev == "secondary" then
    local it = item()
    if it and entry_url(it) then enqueue(entry_url(it), { title = it.title, art = thumb(it), no_playlist = not is_container(it) }) end
  elseif ev == "filter" then
    if args[1] == "Quality" and args[2] then
      for _, q in ipairs(QUALITIES) do
        if q == args[2] then
          o.quality = q
          mp.commandv("script-message", "vivi-setting", ID, "quality", q)
          local t = detail(selected())
          t.secondary, t.filters = secondary_label(), filters()
          send_dialog(t)
        end
      end
    end
  elseif ev:sub(1, 4) == "act:" then
    local a = ev:sub(5)
    if a == "‹ Back" then
      local b = table.remove(S.back)
      if b then
        S.q, S.items, S.title, S.more, S.n, S.sel = b.q, b.items, b.title, b.more, b.n, b.sel
        S.req = S.req + 1 -- a listing still running would replace the restored rows
        send_dialog({ query = S.q })
        show()
      end
    elseif a == "Queue" then
      local it = item()
      if not it then return toast("Select a video first") end
      if is_container(it) then return add_to_playlist(entry_url(it)) end
      if queue({ it }) > 0 then toast("Queued “" .. (it.title or "") .. "”", 2) end
    elseif a == "Queue all" then
      local n = queue(S.items)
      toast(string.format("Queued %d videos", n), 3)
    elseif a == "Download audio" then
      local it = item()
      if it and entry_url(it) then
        enqueue(entry_url(it), { audio = true, title = it.title, art = thumb(it), no_playlist = not is_container(it) })
      else
        toast("Select a video first")
      end
    end
  elseif ev == "more" then
    if S.more then
      S.n = math.min(SEARCH_MAX, S.n + SEARCH_STEP)
      load(S.q, true)
    end
  elseif ev == "view" then
    o.view = tostring(args[1] or ""):lower() == "grid" and "Grid" or "List"
    mp.commandv("script-message", "vivi-setting", ID, "view", o.view)
  elseif ev == "close" then
    S.open = false
    S.req = S.req + 1
  end
end

-- "managed copy", or a system program's path with ~ for the home folder.
local function where(x)
  if x.kind == "managed" then return "managed copy" end
  local p = tostring(x.path or "")
  if HOME ~= "" and p:sub(1, #HOME + 1) == HOME .. SEP then p = "~" .. p:sub(#HOME + 1) end
  return p
end

local function show_info()
  ensure(function(y, err)
    if not y then return toast(err or "No yt-dlp available", 6) end
    get_ffmpeg(false, function(f)
      local fs = f and string.format("ffmpeg %s (%s)", f.version, where(f))
        or "no ffmpeg yet (downloaded for merging or audio conversion)"
      mp.msg.info(string.format("yt-dlp %s; ffmpeg %s", y.path, f and f.path or "none"))
      toast(string.format("yt-dlp %s (%s)%s · %s", y.version, where(y),
        recent(y.version) and "" or ", old: YouTube may fail", fs), 10)
    end)
  end)
end

local function paste()
  local t = valid_url(mp.get_property("clipboard/text", "") or "")
  if not t then
    return toast("No URL in the clipboard (paste it into the YouTube plugin settings instead)")
  end
  o.url = t
  mp.commandv("script-message", "vivi-setting", ID, "url", t)
  add_to_playlist(t)
end

local last_source = o.source
options.read_options(o, ID, function()
  if o.source ~= last_source then
    last_source = o.source
    ytdlp = nil
  end
end)
last_source = o.source

mp.register_script_message("add", function() add_to_playlist() end)
mp.register_script_message("sizes", show_sizes)
mp.register_script_message("download", function() download() end)
mp.register_script_message("download-current", function() download_current() end)
mp.register_script_message("download-audio-current", function() download_current(true) end)
mp.register_script_message("cancel", cancel)
mp.register_script_message("download-cancel", cancel_job)
mp.register_script_message("download-retry", retry_job)
mp.register_script_message("open", open)
mp.register_script_message("vivi-ui", on_ui)
mp.register_script_message("update", function()
  toast("Updating yt-dlp…", 2)
  self_update(false)
end)
mp.register_script_message("info", show_info)
mp.register_script_message("update-ffmpeg", function()
  toast("Checking for a newer ffmpeg…", 2)
  update_ffmpeg(false)
end)
mp.register_script_message("pick-folder", function()
  mp.commandv("script-message", "vivi-pick-folder", ID, "folder")
end)
mp.register_script_message("folder-picked", function(p)
  o.folder = p
  toast("Downloads go to " .. p)
end)
mp.add_forced_key_binding("Alt+u", "youtube-paste", paste)
mp.register_event("shutdown", function()
  for _, j in pairs(jobs) do if j.cmd then mp.abort_async_command(j.cmd) end end
end)

-- An existing managed copy is handed to ytdl_hook right away (streaming works before any
-- plugin action), and checked for updates.
if o.source ~= "System" and utils.file_info(MANAGED) then
  ensure(function() end)
end
mp.add_timeout(30, maybe_update_ffmpeg)

-- For tests: `script-message-to youtube selftest <json file>` prints size estimates.
mp.register_script_message("selftest", function(file)
  local f = io.open(file, "r")
  local j = utils.parse_json(f:read("*a"))
  f:close()
  print("sizes(ffmpeg): " .. size_list(j, true))
  print("sizes(no ffmpeg): " .. size_list(j, false))
  print("fmt(1080p,ff): " .. table.concat(format_args(true), " "))
  print("needs_ffmpeg(1080p video)=" .. tostring(needs_ffmpeg()))
  if file:match("ffmpeg") then
    get_ffmpeg(true, function(x) print("ffmpeg: " .. (x and (x.kind .. " " .. x.version .. " " .. x.path) or "none")) mp.command("quit") end)
    return
  end
  print("recent(2000.01.01)=" .. tostring(recent("2000.01.01")) .. " recent(today)=" .. tostring(recent(os.date("%Y.%m.%d"))))
  mp.command("quit")
end)

if VIVI_TEST then
  return { valid_url = valid_url, current_url = current_url, entry_url = entry_url, thumb = thumb,
    is_container = is_container, fmt_dur = fmt_dur, parse_progress = parse_progress, printed_files = printed_files,
    download_args = download_args, format_args = format_args, needs_ffmpeg = needs_ffmpeg, enqueue = enqueue,
    jobs = jobs, on_ui = on_ui, S = S, o = o, queue = queue, mpv_at_least = mpv_at_least, open = open,
    estimate = estimate, height_limit = height_limit, download = download, cancel_job = cancel_job,
    progress_text = progress_text, size_list = size_list, has_single = has_single, jpeg_thumb = jpeg_thumb,
    info_cache = info_cache, report = report, paste = paste }
end
