-- @name AcoustID Tagger
-- @version 1.1.1
-- @author Vivi
-- @description Identify songs by their sound (Chromaprint fpcalc + AcoustID) and review tags and a new file name in the Auto-tagger (Vivi plugin package).
--
-- Keys: Alt+i  identify the playing file
-- Script messages: identify, detect, forget (clear the result cache).
--
-- 1. fpcalc (Chromaprint) fingerprints the first two minutes: a system fpcalc first
--    (package chromaprint / libchromaprint-tools, brew chromaprint), otherwise the
--    official static build of Chromaprint 1.6.2 is downloaded once from
--    https://github.com/acoustid/chromaprint/releases (1.3-2.6 MB, sha256 pinned below)
--    into plugin-data/acoustid/.
-- 2. POST https://api.acoustid.org/v2/lookup (client = your application API key,
--    meta = recordings + release groups) with curl. The request body goes to curl as a
--    private file (mpv logs subprocess arguments and stdin), never on its command line.
-- 3. The answer goes to Vivi's Auto-tagger (`script-message vivi-tagger-acoustid <path>
--    <json>`), which looks the recordings up on MusicBrainz and opens its candidates list
--    and before/after review, including the file name built from `pattern`.
--
-- Answers are cached per file (path, size, mtime) in plugin-data/acoustid/cache.json, so
-- identifying a file again (or playing it again with "auto" on) asks AcoustID only once.
--
-- "auto" (Vivi 0.13+, shared now playing): when a local song without title / artist tags
-- starts, it is identified in the background and the best match (score >= 70%) is handed to
-- Vivi as the track's metadata (`vivi-media-meta`): the now-playing card, MPRIS and
-- extensions that read now playing (Scrobbler) then show the real artist and title. The file is not changed; Alt+I opens
-- the review that writes the tags.
--
-- The API key (a `secret` setting): Vivi 0.13+ hands it in a private file
-- (manifest `secrets_file = true`, plugin-data/acoustid/vivi-secrets.json, 0600) named by the
-- script-opt `acoustid-secrets=<revision>:<path>`, because mpv writes every script-opt with
-- its value to its log. Older Vivi passes it as the script-opt `acoustid-api-key`, which is
-- also used when the file has no key (a value from mpv's own script-opts/acoustid.conf).
--
-- AcoustID requires an application key and Vivi does not ship one: register a free
-- application at https://acoustid.org/new-application and paste its key in the settings.
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

local VERSION = "1.1.1"
local ID = "acoustid"
local o = {
  ["api-key"] = "", pattern = "{artist} - {title}", download = true, auto = false,
  secrets = "", -- Vivi 0.13+: "<revision>:<path>" of the private file with the API key
  pkgdir = "", -- set by Vivi
}
options.read_options(o, ID)

-- Inside Vivi (it always sets pkgdir) messages are Vivi toasts; mpv's OSD is only drawn
-- into the video, so it is used only when the script runs in a plain mpv.
local function toast(msg, secs)
  mp.msg.info(msg)
  if (o.pkgdir or "") == "" then return mp.osd_message(msg, secs or 4) end
  mp.commandv("script-message", "vivi-toast", msg, tostring(secs or 4))
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
-- ---------- end of managed helpers ----------

local DIR = PLUGIN_DATA .. SEP .. "acoustid"
local CACHE = DIR .. SEP .. "cache.json"
local CACHE_MAX = 300
local V = "1.6.2"
local FPCALC = {
  ["linux-x86_64"] = { "linux-x86_64", "tar.gz", "c968ad4a0821592a79b158fb2e1f46cbe0a22a0a1dbc0743c67d68e75d15d2bb" },
  ["linux-aarch64"] = { "linux-arm64", "tar.gz", "3aa1498126ed272d805bc9d081c77965c9e1e1a0891bb112c13b56ef2ad47bad" },
  ["macos-aarch64"] = { "macos-universal", "tar.gz", "53d9368f96017fb288d74f6ed4d928f7bbbfb2ff81e69b4ef67b6ceeb217d9b2" },
  ["macos-x86_64"] = { "macos-universal", "tar.gz", "53d9368f96017fb288d74f6ed4d928f7bbbfb2ff81e69b4ef67b6ceeb217d9b2" },
  ["windows-x86_64"] = { "windows-x86_64", "zip", "b74369726676670af3ab0eadff45f960cf969fdf4a87a971ba37eaf8d530e874" },
}

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

-- ---------- API key (secrets file on Vivi 0.13+, script-opts before) ----------
local secret_key = nil -- key from vivi-secrets.json ("" = the file has none)

-- Reads the private file named by the `secrets` option ("<revision>:<path>"). Returns
-- whether there was one. Only Vivi's file for this package is read
-- (<data>/plugin-data/acoustid/vivi-secrets.json).
local function read_secrets()
  local f = trim(o.secrets):match("^%d+:(.+)$")
  if not f then secret_key = nil return false end
  if not f:match("[/\\]plugin%-data[/\\]acoustid[/\\]vivi%-secrets%.json$") then
    mp.msg.warn("unexpected secrets file ignored: " .. f)
    secret_key = nil
    return false
  end
  local h = io.open(f, "r")
  if not h then
    mp.msg.warn("secret settings file missing")
    secret_key = nil
    return false
  end
  local j = utils.parse_json(h:read("*a") or "")
  h:close()
  secret_key = type(j) == "table" and type(j["api-key"]) == "string" and j["api-key"] or ""
  return true
end

-- The key in use, without white space: the secrets file first, else (older Vivi, or a
-- value from mpv's script-opts/acoustid.conf) the script-opt.
local function api_key()
  local k = (secret_key or ""):gsub("%s", "")
  if k ~= "" then return k end
  return (o["api-key"] or ""):gsub("%s", "")
end

-- ---------- fpcalc ----------
local function managed_path(plat)
  local f = FPCALC[plat]
  if not f then return nil end
  return DIR .. SEP .. "chromaprint-fpcalc-" .. V .. "-" .. f[1] .. SEP .. "fpcalc" .. EXE
end

local fp_cache
-- cb(path | nil, err, kind)
local function get_fpcalc(cb)
  if fp_cache then return cb(fp_cache.path, nil, fp_cache.kind) end
  find_program({ "fpcalc" }, { "-version" }, function(p)
    if p then fp_cache = { path = p, kind = "system" } return cb(p, nil, "system") end
    platform(function(plat)
      local m = managed_path(plat)
      if m and utils.file_info(m) then fp_cache = { path = m, kind = "downloaded" } return cb(m, nil, "downloaded") end
      local f = FPCALC[plat]
      if not f then return cb(nil, "no fpcalc build for " .. plat .. "; install chromaprint") end
      if not o.download then return cb(nil, "fpcalc is not installed (install chromaprint, or allow the download)") end
      local name = "chromaprint-fpcalc-" .. V .. "-" .. f[1] .. "." .. f[2]
      fetch_verified("fpcalc", "https://github.com/acoustid/chromaprint/releases/download/v" .. V .. "/" .. name,
        f[3], DIR, name, true, function(ok, err)
          if not ok then return cb(nil, err) end
          if not utils.file_info(m) then return cb(nil, "fpcalc missing from the download") end
          fp_cache = { path = m, kind = "downloaded" }
          cb(m, nil, "downloaded")
        end)
    end)
  end)
end

-- { duration, fingerprint } from `fpcalc -json` output, or nil.
local function parse_fpcalc(out)
  local v = utils.parse_json(out or "")
  if type(v) ~= "table" or type(v.fingerprint) ~= "string" or v.fingerprint == "" or not tonumber(v.duration) then
    return nil
  end
  return { duration = math.floor(tonumber(v.duration) + 0.5), fingerprint = v.fingerprint }
end

-- A path fpcalc cannot take for an option: absolute (mpv's working directory for a
-- relative one), or "./-name".
local function safe_path(path, cwd)
  local abs = path:match("^/") or path:match("^%a:[/\\]") or path:match("^\\\\")
  if abs then return path end
  if cwd and cwd ~= "" then return cwd .. SEP .. path end
  return "." .. SEP .. path
end

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function lookup_body(key, fp)
  return "client=" .. urlencode(key) .. "&meta=recordings+releasegroups&duration=" .. fp.duration ..
    "&fingerprint=" .. urlencode(fp.fingerprint)
end

-- "A feat. B" from the recording's artist credits (AcoustID gives the join phrases on all
-- but the last; without them: commas).
local function artists(rec)
  local out, list = {}, rec.artists or {}
  for i, x in ipairs(list) do
    if type(x.name) == "string" then
      out[#out + 1] = x.name
      if i < #list then out[#out + 1] = type(x.joinphrase) == "string" and x.joinphrase or ", " end
    end
  end
  return trim(table.concat(out))
end

-- Best match of an AcoustID answer: { title, artist, album, mbid, score (0..1), duration },
-- plus the number of recordings and the "Artist - Title (97%)" label.
local function best(v)
  local top, n = nil, 0
  for _, r in ipairs(v.results or {}) do
    for _, rec in ipairs(r.recordings or {}) do
      n = n + 1
      if rec.title and (not top or (r.score or 0) > top.score) then
        local album
        for _, g in ipairs(rec.releasegroups or {}) do
          if type(g.title) == "string" and (g.type == "Album" or not album) then album = g.title end
          if album and g.type == "Album" then break end
        end
        top = { title = rec.title, artist = artists(rec), album = album or "", mbid = rec.id or "",
          score = r.score or 0, duration = tonumber(rec.duration) or 0 }
      end
    end
  end
  local label = top and string.format("%s - %s (%d%%)", top.artist, top.title, math.floor(top.score * 100 + 0.5))
  return label, n, top
end

-- The AcoustID answer without what neither the Auto-tagger nor `best` reads (cache size).
local function slim(v)
  local out = { status = v.status, results = {} }
  for _, r in ipairs(v.results or {}) do
    local recs = {}
    for _, rec in ipairs(r.recordings or {}) do
      local a, g = {}, {}
      for _, x in ipairs(rec.artists or {}) do a[#a + 1] = { id = x.id, name = x.name, joinphrase = x.joinphrase } end
      for _, x in ipairs(rec.releasegroups or {}) do
        if #g < 5 then g[#g + 1] = { id = x.id, title = x.title, type = x.type } end
      end
      recs[#recs + 1] = { id = rec.id, title = rec.title, duration = rec.duration, artists = a, releasegroups = g }
    end
    if #out.results < 10 then out.results[#out.results + 1] = { id = r.id, score = r.score, recordings = recs } end
  end
  return out
end

-- ---------- result cache ----------
local cache = nil

local function load_cache()
  if cache then return cache end
  cache = {}
  local f = io.open(CACHE, "r")
  if f then
    local j = utils.parse_json(f:read("*a") or "")
    f:close()
    if type(j) == "table" and type(j.files) == "table" then cache = j.files end
  end
  return cache
end

local function save_cache()
  local list = {}
  for k, v in pairs(cache or {}) do list[#list + 1] = { k, v } end
  table.sort(list, function(a, b) return (a[2].t or 0) > (b[2].t or 0) end)
  local keep = {}
  for i = 1, math.min(#list, CACHE_MAX) do keep[list[i][1]] = list[i][2] end
  cache = keep
  mkdir(DIR, function()
    local tmp = CACHE .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(utils.format_json({ version = 1, files = keep }))
    f:close()
    os.remove(CACHE)
    os.rename(tmp, CACHE)
  end)
end

-- "path|size|mtime": a changed (retagged, re-encoded) file is looked up again.
local function file_key(path)
  local fi = utils.file_info(path)
  if not fi then return nil end
  return path .. "|" .. tostring(fi.size or 0) .. "|" .. tostring(math.floor(fi.mtime or 0))
end

-- ---------- lookup ----------
-- The request body holds the API key. mpv logs every subprocess command with its
-- arguments and stdin_data (debug level, always in a --log-file), so the body goes to curl
-- as a file: plugin-data/acoustid/req-*.form, in a 0700 folder, removed right after.
-- cb(path | nil, done)
local req_n = 0
local function with_request_file(body, cb)
  local function write()
    req_n = req_n + 1
    local p = DIR .. SEP .. string.format("req-%d-%d.form", os.time(), req_n)
    local f = io.open(p, "w")
    if not f then return cb(nil) end
    f:write(body)
    f:close()
    local function done() os.remove(p) end
    if windows then return cb(p, done) end
    run({ "chmod", "600", p }, function() cb(p, done) end)
  end
  if windows then return mkdir(DIR, write) end
  run({ "mkdir", "-p", DIR }, function() run({ "chmod", "700", DIR }, write) end)
end

-- Request files left by a crash.
local function clean_requests()
  for _, f in ipairs(utils.readdir(DIR, "files") or {}) do
    if f:match("^req%-.*%.form$") then os.remove(DIR .. SEP .. f) end
  end
end

local busy = false

-- AcoustID answer for a local file: cb(answer | nil, err). Uses the cache.
local function lookup(path, key, cb, quiet)
  local ck = file_key(path)
  local hit = ck and load_cache()[ck]
  if hit and type(hit.answer) == "table" then return cb(hit.answer) end
  get_fpcalc(function(fpcalc, err)
    if not fpcalc then return cb(nil, err) end
    if not quiet then toast("Fingerprinting…", 3) end
    run({ fpcalc, "-json", safe_path(path, mp.get_property("working-directory", "")) }, function(r)
      local fp = r.status == 0 and parse_fpcalc(r.stdout) or nil
      if not fp then return cb(nil, "fpcalc could not read this file: " .. ((r.stderr or ""):match("[^\n]+") or "")) end
      with_request_file(lookup_body(key, fp), function(req, done)
        if not req then return cb(nil, "could not write the request in " .. DIR) end
        run({ "curl", "-sS", "-m", "20", "-A", "Vivi-acoustid/" .. VERSION, "--data-binary", "@" .. req,
              "-H", "Content-Type: application/x-www-form-urlencoded", "https://api.acoustid.org/v2/lookup" },
          function(res)
            done()
            local v = res.status == 0 and utils.parse_json(res.stdout or "") or nil
            if type(v) ~= "table" then return cb(nil, "no answer (" .. ((res.stderr or ""):match("[^\n]+") or "offline?") .. ")") end
            if v.status ~= "ok" then
              local m = tostring(v.error and v.error.message or "lookup failed")
              if m:lower():find("invalid api key", 1, true) or m:lower():find("application", 1, true) then
                m = m .. " — check the key in Extensions → AcoustID (acoustid.org/new-application)"
              end
              return cb(nil, m)
            end
            v = slim(v)
            if ck then
              load_cache()[ck] = { t = os.time(), answer = v }
              save_cache()
            end
            cb(v)
          end)
      end)
    end)
  end)
end

local function local_file(path)
  return path and path ~= "" and not path:find("://", 1, true) and utils.file_info(path) ~= nil
end

local function identify()
  if busy then return toast("AcoustID: already identifying") end
  local path = mp.get_property("path")
  if not local_file(path) then return toast("AcoustID: play a local audio file first") end
  local key = api_key()
  if key == "" then
    return toast("AcoustID needs your free application key: acoustid.org/new-application → Extensions → AcoustID", 8)
  end
  busy = true
  lookup(path, key, function(v, err)
    busy = false
    if not v then return toast("AcoustID: " .. tostring(err), 8) end
    local label, n = best(v)
    if n == 0 then return toast("AcoustID: this recording is not in the database yet") end
    toast("AcoustID: " .. (label or (n .. " matches")) .. " — opening the review", 4)
    mp.commandv("script-message", "vivi-tagger-acoustid", path,
      utils.format_json({ acoustid = v, pattern = o.pattern or "" }))
  end)
end

-- ---------- automatic identification of untagged songs (Vivi 0.13+) ----------
local AUTO_MIN_SCORE = 0.7
local tried = {}      -- path -> true: identified (or tried) this run
local warned_key = false

local function np_api()
  return tostring(mp.get_property_native("user-data/vivi/now-playing-api", "")) == "1"
end

-- Whether the shared now-playing track `np` (for mpv path `path`) is a local song Vivi
-- knows nothing about: no tags, not in the library, no package metadata.
local function untagged_song(np, path)
  if type(np) ~= "table" or np.path ~= path or not local_file(path) then return false end
  if np.kind ~= "music" then return false end
  return np.source == "file"
end

-- `vivi-media-meta` for the file, from the best match.
local function meta_for(path, top)
  local m = { url = path, title = top.title, artist = top.artist, album = top.album, mbid = top.mbid, kind = "music" }
  if top.duration and top.duration > 0 then m.duration = top.duration end
  return m
end

local function auto_identify(path)
  if tried[path] or busy then return end
  local key = api_key()
  if key == "" then
    if not warned_key then
      warned_key = true
      toast("AcoustID: automatic identification needs your application key (Extensions → AcoustID)", 6)
    end
    return
  end
  tried[path] = true
  lookup(path, key, function(v, err)
    if not v then return mp.msg.warn("auto-identify " .. path .. ": " .. tostring(err)) end
    if mp.get_property("path") ~= path then return end
    local label, _, top = best(v)
    if not top or top.score < AUTO_MIN_SCORE then
      return mp.msg.info("auto-identify: no confident match for " .. path)
    end
    mp.commandv("script-message", "vivi-media-meta", ID, utils.format_json(meta_for(path, top)))
    toast("Identified: " .. label .. " · Alt+I to review and write the tags", 6)
  end, true)
end

local function on_now_playing(_, np)
  if not o.auto then return end
  local path = mp.get_property("path", "")
  if untagged_song(np, path) then auto_identify(path) end
end

local function detect()
  fp_cache = nil
  get_fpcalc(function(p, err, kind)
    local k = api_key() ~= "" and "key set" or "no API key"
    toast((p and ("fpcalc (" .. kind .. "): " .. p) or ("fpcalc: " .. err)) .. " · " .. k, 6)
  end)
end

options.read_options(o, ID, function(changed)
  if changed.secrets then read_secrets() end
  if changed["api-key"] or changed.secrets then warned_key = false end
end)
read_secrets()
clean_requests()

mp.add_forced_key_binding("Alt+i", "identify", identify)
mp.register_script_message("identify", identify)
mp.register_script_message("detect", detect)
mp.register_script_message("forget", function()
  cache = {}
  tried = {}
  os.remove(CACHE)
  toast("AcoustID: cached results cleared")
end)
if np_api() then mp.observe_property("user-data/vivi/now-playing", "native", on_now_playing) end

if VIVI_TEST then
  return { parse_fpcalc = parse_fpcalc, lookup_body = lookup_body, best = best, managed_path = managed_path,
    read_secrets = read_secrets, api_key = api_key, o = o, slim = slim, safe_path = safe_path,
    untagged_song = untagged_song, meta_for = meta_for, file_key = file_key, on_now_playing = on_now_playing,
    lookup = lookup, DIR = DIR, CACHE = CACHE, load_cache = load_cache, identify = identify }
end
