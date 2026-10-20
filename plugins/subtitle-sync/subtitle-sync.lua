-- @name Subtitle Auto-Sync
-- @version 1.3.0
-- @author Vivi
-- @description Align external subtitles to the audio or to another subtitle track with alass or ffsubsync, plus manual per-file offsets on Vivi before 0.13 (Vivi plugin package).
--
-- Keys: Alt+y           sync the selected external subtitle to the audio
--       Alt+Y           sync it to another subtitle track (Alt+Shift+y): the secondary
--                       subtitle, else another text track of the file (embedded or external)
--       Alt+z / Alt+x   subtitle offset one step earlier / later (0.1 s by default);
--                       Vivi 0.13+ handles these keys itself (0.1 s, Alt+Shift 1 s)
--       Alt+Z / Alt+X   ten steps (1 s by default; Alt+Shift+z / x)
--       Alt+BS          reset the offset of this file
-- Script messages: sync, sync-ref, detect, reset.
--
-- Tools: a system alass / alass-cli or ffsubsync (PATH and the usual folders) is used
-- first. Without one, alass 2.0.0 is downloaded on first sync from its official release
-- (https://github.com/kaegi/alass/releases, sha256 pinned below): 3 MB on Linux x86_64,
-- 26 MB on Windows (bundles its ffmpeg). Syncing to the audio needs ffmpeg/ffprobe: a
-- system ffmpeg, else Vivi's shared media ffmpeg build (about 15 MB, also used by
-- Chapter Thumbnails). Syncing to an external subtitle needs no ffmpeg; an embedded
-- reference track is extracted first with a system ffmpeg (the shared build has no
-- subtitle decoders). macOS and Linux ARM have no alass build:
-- install alass-cli (cargo install alass-cli) or ffsubsync (pip install ffsubsync).
--
-- The result is `<name>.synced.<ext>` next to the original. When a file opens again with
-- the original subtitle selected, its synced copy is selected instead (setting *prefer*).
--
-- Offsets: Vivi 0.13+ keeps the per-file offset in the player (z / x, Alt+Z / Alt+X,
-- side panel) and sets user-data/vivi/sub-offset = 1: then this script binds no offset
-- keys and keeps no offsets.json; offsets it saved on older Vivi are imported by Vivi
-- once (marker offsets.imported, written by Vivi) and the file is removed. Vivi 0.11 /
-- 0.12 with Subtitle Search on (script-opt vivi-sub-offsets=1): the keys send
-- `script-message vivi-sub-offset set:<v>` and earlier offsets are handed over per file.
-- Older Vivi: kept in plugin-data/subtitle-sync/offsets.json per file (path, size) and
-- applied as sub-delay whenever that file is opened again.
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

-- pkgdir: set by Vivi 0.9.1+ (declared so mp.options does not warn about it).
local o = { tool = "Auto", download = true, step = "0.1", prefer = true, pkgdir = "" }
options.read_options(o, "subtitle-sync")

-- Vivi shows `vivi-toast` as its own toast. mpv's OSD only where that is missing:
-- plain mpv, or Vivi 0.9.0 (which sets no pkgdir yet), so a message never shows twice.
local function toast(msg, secs)
  if o.pkgdir == "" then mp.osd_message(msg, secs or 4) end
  mp.commandv("script-message", "vivi-toast", msg)
end

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
      toast("Downloading " .. what .. " (" .. human(sz) .. ")…", 5)
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

local DIR = PLUGIN_DATA .. SEP .. "subtitle-sync"
local OFFSETS = DIR .. SEP .. "offsets.json"
local IMPORTED = DIR .. SEP .. "offsets.imported" -- written by Vivi 0.13+ after the import
local ALASS_DIR = DIR .. SEP .. "alass"
local REF = DIR .. SEP .. "reference.srt" -- an embedded reference track, extracted
local ALASS = {
  ["linux-x86_64"] = { url = "https://github.com/kaegi/alass/releases/download/v2.0.0/alass-linux64",
    sha = "7bd0b9ae7e035d3ba940eacffb21243614df36231d47f21f0b4ce42001ab7fcd", file = "alass" },
  ["windows-x86_64"] = { url = "https://github.com/kaegi/alass/releases/download/v2.0.0/alass-windows64.zip",
    sha = "e81a72f97f592910e909a2352d6b8c0de0801c51ac1383bad4ebf3f2ecdd2fd8", file = "alass-windows64.zip", zip = true,
    exe = "alass-windows64\\bin\\alass-cli.exe" },
}

local running = false
local found -- cache: { alass = path, ffsubsync = path, managed = bool }

local function managed_alass(plat)
  local a = ALASS[plat]
  if not a then return nil end
  local p = ALASS_DIR .. SEP .. (a.exe or a.file)
  return utils.file_info(p) and p or nil
end

-- System tools (and an already downloaded alass). cb(found)
local function detect(cb)
  if found then return cb(found) end
  local f = {}
  find_program({ "alass", "alass-cli" }, { "--version" }, function(a)
    f.alass = a
    find_program({ "ffsubsync" }, { "--version" }, function(s)
      f.ffsubsync = s
      platform(function(plat)
        if not f.alass then
          f.alass = managed_alass(plat)
          f.managed = f.alass ~= nil
        end
        f.plat = plat
        found = f
        cb(f)
      end)
    end)
  end)
end

local MISSING = "Subtitle sync needs alass or ffsubsync: cargo install alass-cli, or pip install ffsubsync"

-- Tool to use, downloading alass if allowed. cb(tool, path | nil, err)
local function pick(cb)
  detect(function(f)
    local want = (o.tool or "Auto"):lower()
    if want == "ffsubsync" then
      if f.ffsubsync then return cb("ffsubsync", f.ffsubsync) end
      return cb(nil, nil, "ffsubsync is not installed; set Sync tool to Auto")
    end
    if f.alass then return cb("alass", f.alass) end
    if want == "auto" and f.ffsubsync then return cb("ffsubsync", f.ffsubsync) end
    local a = ALASS[f.plat]
    if not o.download or not a then return cb(nil, nil, MISSING) end
    fetch_verified("alass", a.url, a.sha, ALASS_DIR, a.file, a.zip, function(ok, err)
      if not ok then return cb(nil, nil, err) end
      found = nil
      local p = managed_alass(f.plat)
      if not p then return cb(nil, nil, "alass missing from the download") end
      cb("alass", p)
    end)
  end)
end

-- Output path next to the original: movie.en.srt -> movie.en.synced.srt
local function out_path(sub)
  local base, ext = sub:match("^(.*)%.([^./\\]+)$")
  if not base then return sub .. ".synced.srt" end
  base = base:gsub("%.synced$", "")
  return base .. ".synced." .. ext
end

-- The subtitle to align: the original when its synced copy is selected (a new sync
-- starts from the untouched file instead of shifting the shifted copy again).
local function source_of(sub)
  local base, ext = sub:match("^(.*)%.synced%.([^./\\]+)$")
  if base and utils.file_info(base .. "." .. ext) then return base .. "." .. ext end
  return sub
end

-- Written here first and renamed when the tool succeeds: never a half file, never the
-- input overwritten while it is read. Keeps the extension (alass and ffsubsync pick the
-- format from it).
local function tmp_path(out)
  local base, ext = out:match("^(.*)%.([^./\\]+)$")
  return base .. ".syncing." .. ext
end

local function file_name(p) return p:match("([^/\\]+)$") or p end

local function tracks()
  return mp.get_property_native("track-list") or {}
end

-- The selected subtitle track, if it is an external file.
local function current_track()
  for _, t in ipairs(tracks()) do
    if t.type == "sub" and t.selected and t["main-selection"] ~= 1 and t.external and t["external-filename"] then
      return t
    end
  end
  for _, t in ipairs(tracks()) do
    if t.type == "sub" and t.selected and t.external and t["external-filename"] then return t end
  end
  return nil
end

-- The loaded track of an external file, if any.
local function track_of(path)
  for _, t in ipairs(tracks()) do
    if t.type == "sub" and t["external-filename"] == path then return t end
  end
end

-- Bitmap subtitles (no text to align, ffmpeg cannot turn them into SRT).
local IMAGE_CODECS = { hdmv_pgs_subtitle = true, dvd_subtitle = true, dvb_subtitle = true,
  dvb_teletext = true, xsub = true, pgssub = true, dvdsub = true, dvbsub = true }
local function is_text(t) return t.type == "sub" and not IMAGE_CODECS[(t.codec or ""):lower()] end

-- Reference track for "sync to another subtitle track": the secondary subtitle when
-- one is shown, else another text track of the file, embedded ones first (they come
-- with the video, so their timing is right), forced-only tracks last.
local function reference_track(cur)
  local list = tracks()
  local function usable(t)
    if not is_text(t) or t.id == cur.id then return false end
    local f = t["external-filename"]
    return not (f and (f == cur["external-filename"] or out_path(f) == out_path(cur["external-filename"])))
  end
  local sec = tonumber(mp.get_property("secondary-sid"))
  for _, t in ipairs(list) do
    if t.type == "sub" and t.id == sec and usable(t) then return t end
  end
  local best, score
  for _, t in ipairs(list) do
    if usable(t) then
      local s = (t.external and 0 or 2) + (t.forced and 0 or 1)
      if not score or s > score then best, score = t, s end
    end
  end
  return best
end

-- Start times (seconds) of the cues of a subtitle file, in file order (SRT, WebVTT, ASS).
local function cue_starts(path)
  local f = io.open(path, "rb")
  if not f then return {} end
  local s = f:read("*a") or ""
  f:close()
  local out = {}
  local function add(h, m, sec, frac)
    out[#out + 1] = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(sec) + tonumber(frac) / 10 ^ #frac
  end
  for line in s:gmatch("[^\r\n]+") do
    local h, m, sec, frac = line:match("^%s*(%d+):(%d%d):(%d%d)[,.](%d+)%s*%-%->")
    if h then add(h, m, sec, frac) else
      m, sec, frac = line:match("^%s*(%d%d):(%d%d)%.(%d+)%s*%-%->")
      if m then add(0, m, sec, frac) else
        h, m, sec, frac = line:match("^Dialogue:%s*[^,]*,(%d+):(%d%d):(%d%d)%.(%d+)")
        if h then add(h, m, sec, frac) end
      end
    end
  end
  return out
end

local function first_cue(path) return cue_starts(path)[1] end

-- How far the synced copy moved: the median shift of its cues (both tools keep the cue
-- order), so a few lines moved differently do not decide it. nil without cues.
local function median_shift(before, after)
  local a, b = cue_starts(before), cue_starts(after)
  if #a == 0 or #a ~= #b then return nil end
  local d = {}
  for i = 1, #a do d[i] = b[i] - a[i] end
  table.sort(d)
  return d[math.floor((#d + 1) / 2)]
end

local function round(x) return math.floor(x * 1000 + 0.5) / 1000 end

-- "+0.1 s", "-1.25 s"
local function fmt_offset(v)
  local s = string.format("%+.2f", v):gsub("(%.%d)0$", "%1")
  return s .. " s"
end

-- ---------- manual offset, remembered per file ----------

local function read_offsets()
  local f = io.open(OFFSETS, "r")
  if not f then return {} end
  local v = utils.parse_json(f:read("*a") or "")
  f:close()
  return type(v) == "table" and v or {}
end

local function write_offsets(t)
  mkdir(DIR, function()
    local f = io.open(OFFSETS .. ".tmp", "w")
    if not f then return end
    f:write(utils.format_json(t))
    f:close()
    os.remove(OFFSETS)
    os.rename(OFFSETS .. ".tmp", OFFSETS)
    -- Saved on an older Vivi: a newer one imports the file again.
    os.remove(IMPORTED)
  end)
end

-- Key of a file: path + size (survives renaming the subtitle, not moving the video).
local function file_key(path)
  if not path or path == "" then return nil end
  local fi = utils.file_info(path)
  return path .. "|" .. tostring(fi and fi.size or 0)
end

-- Vivi 0.13+: the per-file offset is the player's own (keys, storage, side panel).
local function core_offset()
  return tostring(mp.get_property_native("user-data/vivi/sub-offset", "")) == "1"
end

-- Vivi saves the offset per file (core in 0.13+; Subtitle Search plugin on in 0.11 / 0.12).
local function vivi_offsets() return core_offset() or mp.get_opt("vivi-sub-offsets") == "1" end

local function file_exists(p) return utils.file_info(p) ~= nil end

-- Vivi 0.13+ imports offsets.json once at startup (and on vivi-sub-offset-import) and
-- writes offsets.imported; then the file is not needed any more.
local function hand_over(cb)
  if not file_exists(OFFSETS) then return cb and cb(false) end
  if file_exists(IMPORTED) then
    os.remove(OFFSETS)
    mp.msg.info("offsets handed over to Vivi, offsets.json removed")
    return cb and cb(true)
  end
  mp.commandv("script-message", "vivi-sub-offset-import")
  mp.add_timeout(1, function()
    local done = file_exists(IMPORTED)
    if done then
      os.remove(OFFSETS)
      mp.msg.info("offsets handed over to Vivi, offsets.json removed")
    end
    if cb then cb(done) end
  end)
end

local function set_offset(v, quiet)
  v = round(v)
  if vivi_offsets() then
    -- Vivi applies it, saves it and shows its own toast.
    mp.commandv("script-message", "vivi-sub-offset", "set:" .. tostring(v))
    return
  end
  mp.set_property_number("sub-delay", v)
  local k = file_key(mp.get_property("path"))
  if k then
    local t = read_offsets()
    t[k] = v ~= 0 and v or nil
    write_offsets(t)
  end
  if not quiet then
    toast(v == 0 and "Subtitle offset reset" or ("Subtitle offset " .. fmt_offset(v) .. " · saved for this file"), 2)
  end
end

local function nudge(d)
  return function() set_offset((mp.get_property_number("sub-delay") or 0) + d * (tonumber(o.step) or 0.1)) end
end

local function reset() set_offset(0) end

-- ---------- sync ----------

-- Load (or reload) the synced copy and select it, named after the original track.
local function load_synced(out, orig)
  for _, t in ipairs(tracks()) do
    if t.type == "sub" and t.external and t["external-filename"] == out then
      mp.commandv("sub-remove", tostring(t.id))
    end
  end
  -- mpv names an auto-loaded file by the end of its name ("en.srt"): no title of its own.
  local src = orig and orig["external-filename"] or out
  local t = (orig and orig.title or ""):gsub("%s*%(synced%)$", "")
  local title = (t == "" or t == "Synced" or src:sub(-#t) == t) and "Synced" or (t .. " (synced)")
  if orig and orig.lang and orig.lang ~= "" then
    mp.commandv("sub-add", out, "select", title, orig.lang)
  else
    mp.commandv("sub-add", out, "select", title)
  end
end

-- job = { tool, exe, ref, ref_label, sub, out, track, env, ffpath }
local function run_sync(job)
  local tmp = tmp_path(job.out)
  local args
  if job.tool == "alass" then
    args = { job.exe, job.ref, job.sub, tmp }
  else
    args = { job.exe, job.ref, "-i", job.sub, "-o", tmp }
    if job.ffpath then args[#args + 1] = "--ffmpeg-path" args[#args + 1] = job.ffpath end
  end
  if job.env and not windows then
    local e = { "env" }
    for k, v in pairs(job.env) do e[#e + 1] = k .. "=" .. v end
    for _, x in ipairs(args) do e[#e + 1] = x end
    args = e
  end
  running = true
  toast("Syncing subtitle to " .. job.ref_label .. " with " .. job.tool .. "…", 3)
  mp.msg.info("running: " .. table.concat(args, " "))
  local t0 = mp.get_time()
  local video = mp.get_property("path")
  run(args, function(r)
    running = false
    if r.status ~= 0 or not utils.file_info(tmp) then
      os.remove(tmp)
      local err = (r.stderr and r.stderr ~= "" and r.stderr) or r.stdout or r.error_string or ""
      mp.msg.warn("sync failed: " .. tostring(err))
      local last = (err or ""):gsub("%s+$", ""):match("([^\n]*)$") or ""
      toast("Subtitle sync failed" .. (last ~= "" and (": " .. last:sub(1, 120)) or ""), 6)
      return
    end
    os.remove(job.out)
    local ok, e = os.rename(tmp, job.out)
    if not ok then return toast("Could not save " .. file_name(job.out) .. ": " .. tostring(e), 6) end
    if mp.get_property("path") ~= video then
      return toast("Synced subtitle saved: " .. file_name(job.out), 4)
    end
    load_synced(job.out, job.track)
    -- The synced copy is aligned already: an offset set for the original would move it off.
    local had = math.abs(mp.get_property_number("sub-delay") or 0) > 0.0005
    if had then set_offset(0, true) end
    local d = median_shift(job.sub, job.out)
    local parts = 0
    for _ in (r.stdout or ""):gmatch("shifted block of") do parts = parts + 1 end
    local moved = d and (" · moved " .. fmt_offset(d) .. (parts > 1 and (" (" .. parts .. " parts)") or "")) or ""
    local secs = mp.get_time() - t0
    toast("Synced subtitle loaded" .. moved .. (had and " · offset reset" or "")
      .. (secs >= 2 and string.format(" · %.0f s", secs) or ""), 5)
  end)
end

-- Common start of both syncs. cb(video, track) when there is something to sync.
local function prepare(cb)
  if running then toast("Subtitle sync is already running"); return end
  local video = mp.get_property("path")
  if not video or video:find("://") then toast("Subtitle sync works on local files only"); return end
  local t = current_track()
  if not t then
    toast("Select an external subtitle first (embedded tracks come timed with the video)"); return
  end
  cb(video, t)
end

local function sync()
  prepare(function(video, t)
    local sub = source_of(t["external-filename"])
    running = true
    pick(function(tool, exe, err)
      running = false
      if not tool then return toast(err or MISSING, 8) end
      local job = { tool = tool, exe = exe, ref = video, ref_label = "the audio", sub = sub, out = out_path(sub),
        track = track_of(sub) or t }
      if tool == "alass" and windows then return run_sync(job) end -- the Windows build bundles ffmpeg
      -- Audio is decoded by ffmpeg + ffprobe: system first, else the shared media build.
      running = true
      get_ffmpeg(true, function(ff, e)
        running = false
        if not ff then return toast(tool .. " needs ffmpeg: " .. tostring(e), 8) end
        if ff.kind == "managed" then
          if tool == "alass" then job.env = { ALASS_FFMPEG_PATH = ff.ffmpeg, ALASS_FFPROBE_PATH = ff.ffprobe }
          else job.ffpath = FF_DIR end
        end
        run_sync(job)
      end)
    end)
  end)
end

-- Embedded reference track -> REF (SRT). cb(path | nil, err)
local function extract(video, t, cb)
  if not t["ff-index"] then return cb(nil, "this subtitle track cannot be extracted") end
  -- Vivi's shared media ffmpeg has no subtitle decoders: a system ffmpeg only.
  get_ffmpeg(false, function(ff)
    if not ff or ff.kind ~= "system" then
      return cb(nil, "Reading an embedded subtitle track needs ffmpeg installed; an external subtitle works as reference without it")
    end
    mkdir(DIR, function()
      os.remove(REF)
      run({ ff.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", video,
            "-map", "0:" .. tostring(t["ff-index"]), "-c:s", "srt", REF }, function(r)
        if r.status ~= 0 or not utils.file_info(REF) then
          local last = (r.stderr or ""):gsub("%s+$", ""):match("([^\n]*)$") or ""
          return cb(nil, "could not extract the reference track" .. (last ~= "" and (": " .. last:sub(1, 100)) or ""))
        end
        cb(REF)
      end)
    end)
  end)
end

local function track_label(t)
  local l = t.title or t.lang or ("#" .. tostring(t.id))
  if t.lang and t.title and not t.title:find(t.lang, 1, true) then l = l .. ", " .. t.lang end
  return "track " .. l
end

-- Align the selected external subtitle to another subtitle track instead of the audio:
-- seconds instead of minutes, and right even when the soundtrack differs (dubs, music).
local function sync_ref()
  prepare(function(video, t)
    local ref = reference_track(t)
    if not ref then
      return toast("No other text subtitle track to sync to: load one, or use Alt+Y to sync to the audio", 6)
    end
    local sub = source_of(t["external-filename"])
    running = true
    pick(function(tool, exe, err)
      if not tool then running = false return toast(err or MISSING, 8) end
      local function go(path)
        running = false
        run_sync({ tool = tool, exe = exe, ref = path, ref_label = track_label(ref), sub = sub,
          out = out_path(sub), track = track_of(sub) or t })
      end
      if ref.external then return go(ref["external-filename"]) end
      toast("Reading the reference subtitle from the video…", 3)
      extract(video, ref, function(path, e)
        if not path then running = false return toast(e, 8) end
        go(path)
      end)
    end)
  end)
end

local function report()
  found, ff_cache = nil, nil
  detect(function(f)
    local list = {}
    if f.alass then list[#list + 1] = (f.managed and "alass (downloaded): " or "alass: ") .. f.alass end
    if f.ffsubsync then list[#list + 1] = "ffsubsync: " .. f.ffsubsync end
    get_ffmpeg(false, function(ff)
      list[#list + 1] = "ffmpeg: " .. (ff and (ff.ffmpeg .. " (" .. ff.kind .. ")") or "none yet (downloaded when needed)")
      if not f.alass and not f.ffsubsync then
        list[#list + 1] = ALASS[f.plat] and (o.download and "alass is downloaded on the first sync" or "downloads are off")
          or MISSING
      end
      -- Vivi's toast is one line; the home folder as ~.
      local line = table.concat(list, " · ")
      if not windows and HOME ~= "" and HOME ~= "/" then line = line:gsub(HOME:gsub("%p", "%%%0"), "~") end
      toast(line, 10)
    end)
  end)
end

-- ---------- the synced copy when a file opens again ----------

local preferred -- path of the file already handled
local function prefer_synced()
  local path = mp.get_property("path")
  if not o.prefer or not path or preferred == path then return end
  local t = current_track()
  if not t then return end
  preferred = path
  local f = t["external-filename"]
  if f:match("%.synced%.[^./\\]+$") then return end
  local s = out_path(f)
  local a, b = utils.file_info(f), utils.file_info(s)
  -- Not when the original was replaced after the sync (the copy belongs to the old one).
  if not b or (a and a.mtime and b.mtime and b.mtime < a.mtime) then return end
  load_synced(s, t)
  toast("Using the synced subtitle " .. file_name(s), 3)
end

mp.register_event("file-loaded", function()
  preferred = nil
  -- After Vivi's per-file pick is loaded (also on file-loaded).
  mp.add_timeout(0.5, prefer_synced)
  mp.add_timeout(2, prefer_synced)
  if core_offset() then return end -- Vivi restores it
  local k = file_key(mp.get_property("path"))
  local t = k and read_offsets() or {}
  local v = k and t[k]
  if v and vivi_offsets() then
    -- Hand an offset saved by older versions over to Vivi once.
    t[k] = nil
    write_offsets(t)
    mp.commandv("script-message", "vivi-sub-offset", "set:" .. tostring(v))
    return
  end
  -- After Vivi's per-show preset (applied on file-loaded too), so the file's own value wins.
  if v then mp.add_timeout(0.2, function()
    mp.set_property_number("sub-delay", v)
    mp.msg.info(string.format("subtitle offset %+.3f s restored", v))
  end) end
end)

mp.add_forced_key_binding("Alt+y", "sync", sync)
mp.add_forced_key_binding("Alt+Y", "sync-ref", sync_ref)
if core_offset() then
  -- Vivi 0.13+ owns Alt+Z / Alt+X (and z / x); Alt+BS still resets through Vivi.
  hand_over()
else
  mp.add_forced_key_binding("Alt+z", "earlier", nudge(-1), { repeatable = true })
  mp.add_forced_key_binding("Alt+x", "later", nudge(1), { repeatable = true })
  mp.add_forced_key_binding("Alt+Z", "earlier-1s", nudge(-10), { repeatable = true })
  mp.add_forced_key_binding("Alt+X", "later-1s", nudge(10), { repeatable = true })
end
mp.add_forced_key_binding("Alt+BS", "reset", reset)
mp.register_script_message("sync", sync)
mp.register_script_message("sync-ref", sync_ref)
mp.register_script_message("detect", report)
mp.register_script_message("reset", reset)

if VIVI_TEST then
  return { out_path = out_path, source_of = source_of, tmp_path = tmp_path, file_key = file_key,
    round = round, fmt_offset = fmt_offset, set_offset = set_offset, read_offsets = read_offsets,
    nudge = nudge, reference_track = reference_track, first_cue = first_cue, median_shift = median_shift, toast = toast,
    load_synced = load_synced, prefer_synced = prefer_synced, OFFSETS = OFFSETS, IMPORTED = IMPORTED,
    core_offset = core_offset, hand_over = hand_over, o = o }
end
