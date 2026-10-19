-- @name Scrobbler (Last.fm & ListenBrainz)
-- @version 1.2.0
-- @author Vivi
-- @description Scrobbles to Last.fm and/or ListenBrainz with an offline queue (Vivi plugin package).
--
-- Rules (Last.fm/ListenBrainz convention): a track is scrobbled once it has been played
-- for half its length or 4 minutes, whichever comes first; tracks shorter than
-- 30 seconds are ignored. Time is counted from actual playback (seeking and pausing do
-- not count); replaying a track from the start (repeat one) is a new listen.
-- Artist / title / album come from the file tags (mpv metadata), or for streams from
-- the metadata a music package announces with `vivi-media-meta` (YouTube Music, …).
--
-- ListenBrainz: POST <api>/1/submit-listens with `Authorization: Token <token>`.
-- Last.fm: signed POSTs to https://ws.audioscrobbler.com/2.0/ (track.updateNowPlaying,
-- track.scrobble, track.love). Last.fm has no per-user tokens without an API account, so
-- the user enters an API key + shared secret (free, https://www.last.fm/api/account/create)
-- and connects once: "Connect Last.fm" opens the browser authorisation page and waits
-- for the approval ("Finish connecting" checks at once). The session key is kept in
-- lastfm-session.json in the plugin's data folder (folder 0700, file 0600), not in
-- Vivi's config file, and is never logged or shown.
--
-- Secrets never appear on a command line or in mpv's log: every request is a private,
-- short-lived curl config file (`curl -K <file>`) in the data folder, removed afterwards.
--
-- Everything that cannot be sent (offline, server error, bad credentials) is appended to
-- $XDG_DATA_HOME/vivi/plugin-data/scrobbler/queue.jsonl (ListenBrainz) and
-- lastfm-queue.jsonl (Last.fm) and sent in batches later (at start, after every
-- successful scrobble, every 10 minutes and on "flush").
-- Script messages: flush, status, love, lastfm_connect, lastfm_finish, lastfm_disconnect.
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

local VERSION = "1.2.0"
local ID = "scrobbler"
local DEFAULT_GENRES = "Podcast, Audiobook, Speech, Spoken Word"
local o = {
  token = "", now_playing = true, audio_only = true, skip_genres = DEFAULT_GENRES, skip_folders = "",
  api = "https://api.listenbrainz.org", lastfm_key = "", lastfm_secret = "", lastfm_session = "",
  pkgdir = "", -- passed by Vivi to every package (unused; declared so mp.options does not warn)
}
-- Overridable for tests against a local mock server only.
local LB_API = os.getenv("VIVI_SCROBBLER_LB_API")
local LASTFM = os.getenv("VIVI_SCROBBLER_LASTFM_API") or "https://ws.audioscrobbler.com/2.0/"
local LASTFM_AUTH = os.getenv("VIVI_SCROBBLER_LASTFM_AUTH") or "https://www.last.fm/api/auth/"
local MAX_QUEUE = 10000
local META_MAX = 5000

local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
local data = os.getenv("XDG_DATA_HOME")
if not data or data == "" then
  data = os.getenv("APPDATA") or (home .. "/.local/share")
end
local dir = data .. "/vivi/plugin-data/" .. ID
local QUEUES = { lb = dir .. "/queue.jsonl", lastfm = dir .. "/lastfm-queue.jsonl" }
local SESSION = dir .. "/lastfm-session.json"
local windows = package.config:sub(1, 1) == "\\"
local NAMES = { lb = "ListenBrainz", lastfm = "Last.fm" }

local cur = nil -- { meta, duration, played, sent, started_at, path, lastfm }
local last_pos, seeked = nil, false
local skipped = nil -- why the current file is not scrobbled
local sending = {}
local last_error = {}
local sent_count = { lb = 0, lastfm = 0 }
local ignored_count = 0
local session = nil -- { key, name, api_key }
local lastfm_token = nil -- pending desktop-auth token
local auth_poll = nil
local stream_meta, stream_meta_n = {}, 0
local M = {} -- test exports

local function log(...) mp.msg.info(...) end
local function trim(s) return ((tostring(s or "")):gsub("^%s+", ""):gsub("%s+$", "")) end
local function token() return trim(o.token) end

-- Vivi's toast (mpv's OSD is drawn under Vivi's UI, so it is not used).
local function toast(msg, secs)
  mp.commandv("script-message", "vivi-toast", msg, tostring(secs or 4))
end

-- ---------- MD5 (Last.fm signatures), pure Lua ----------

-- 32-bit operations on non-negative numbers: arithmetic fallback for Lua 5.1 builds
-- of mpv without the bit library.
local function pure_bitops()
  local function op(a, b, f)
    local r, bit = 0, 1
    for _ = 1, 32 do
      local x, y = a % 2, b % 2
      if f(x, y) then r = r + bit end
      a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
    end
    return r
  end
  local band = function(a, b) return op(a, b, function(x, y) return x == 1 and y == 1 end) end
  local bor = function(a, b) return op(a, b, function(x, y) return x == 1 or y == 1 end) end
  local bxor = function(a, b) return op(a, b, function(x, y) return x ~= y end) end
  local bnot = function(a) return 4294967295 - a % 4294967296 end
  local lshift = function(a, n) return (a % 2 ^ (32 - n)) * 2 ^ n end
  local rshift = function(a, n) return math.floor((a % 4294967296) / 2 ^ n) end
  return { band = band, bor = bor, bxor = bxor, bnot = bnot, lshift = lshift, rshift = rshift }
end

local function native_bitops()
  local ok, b = pcall(require, "bit") -- LuaJIT
  if not ok then ok, b = pcall(require, "bit32") end -- Lua 5.2
  if not ok and rawget(_G, "bit32") then ok, b = true, rawget(_G, "bit32") end
  if ok and b then
    local norm = function(x) return x % 4294967296 end
    return {
      band = function(a, c) return norm(b.band(a, c)) end,
      bor = function(a, c) return norm(b.bor(a, c)) end,
      bxor = function(a, c) return norm(b.bxor(a, c)) end,
      bnot = function(a) return norm(b.bnot(a)) end,
      lshift = function(a, n) return norm(b.lshift(a, n)) end,
      rshift = function(a, n) return norm(b.rshift(norm(a), n)) end,
    }
  end
  -- Lua 5.3+: native integer operators (loaded as text so 5.1 can parse this file).
  local chunk = (loadstring or load)([[
    local m = 0xffffffff
    return { band = function(a, b) return (a & b) & m end, bor = function(a, b) return (a | b) & m end,
      bxor = function(a, b) return (a ~ b) & m end, bnot = function(a) return (~a) & m end,
      lshift = function(a, n) return (a << n) & m end, rshift = function(a, n) return ((a & m) >> n) end }
  ]])
  return chunk and chunk() or pure_bitops()
end

local BIT = native_bitops()

local function md5(msg, ops)
  local B = ops or BIT
  local band, bor, bxor, bnot, lshift, rshift = B.band, B.bor, B.bxor, B.bnot, B.lshift, B.rshift
  local K, S = {}, {
    7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
    5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
    4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
    6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
  }
  for i = 0, 63 do K[i] = math.floor(math.abs(math.sin(i + 1)) * 4294967296) end
  local function add(a, b) return (a + b) % 4294967296 end
  local function rol(x, n) return bor(lshift(x, n), rshift(x, 32 - n)) end
  local len = #msg
  msg = msg .. "\128" .. string.rep("\0", (55 - len) % 64)
  local bits = len * 8
  for _ = 1, 8 do
    msg = msg .. string.char(bits % 256)
    bits = math.floor(bits / 256)
  end
  local a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
  for chunk = 1, #msg, 64 do
    local W = {}
    for i = 0, 15 do
      local p = chunk + i * 4
      local w0, w1, w2, w3 = msg:byte(p, p + 3)
      W[i] = w0 + w1 * 256 + w2 * 65536 + w3 * 16777216
    end
    local A, Bv, C, D = a0, b0, c0, d0
    for i = 0, 63 do
      local F, g
      if i < 16 then F = bor(band(Bv, C), band(bnot(Bv), D)); g = i
      elseif i < 32 then F = bor(band(D, Bv), band(bnot(D), C)); g = (5 * i + 1) % 16
      elseif i < 48 then F = bxor(bxor(Bv, C), D); g = (3 * i + 5) % 16
      else F = bxor(C, bor(Bv, bnot(D))); g = (7 * i) % 16 end
      F = add(add(add(F, A), K[i]), W[g])
      A, D, C = D, C, Bv
      Bv = add(Bv, rol(F, S[i + 1]))
    end
    a0, b0, c0, d0 = add(a0, A), add(b0, Bv), add(c0, C), add(d0, D)
  end
  local out = {}
  for _, v in ipairs({ a0, b0, c0, d0 }) do
    for _ = 1, 4 do
      out[#out + 1] = string.format("%02x", v % 256)
      v = math.floor(v / 256)
    end
  end
  return table.concat(out)
end

-- ---------- private files ----------

local dir_ready = false
local function ensure_dir()
  if dir_ready then return end
  if windows then -- %APPDATA% is per-user already
    utils.subprocess({ args = { "cmd", "/c", "mkdir", (dir:gsub("/", "\\")) }, playback_only = false })
  else
    -- 0700 also for a folder an older version created with the default mode.
    utils.subprocess({ args = { "sh", "-c", 'mkdir -p "$1" && chmod 700 "$1"', "sh", dir }, playback_only = false })
  end
  dir_ready = true
end

-- Create `path` empty and owner-only before any content goes in.
local function private_create(path)
  local f = io.open(path, "w")
  if not f then return false end
  f:close()
  if not windows then utils.subprocess({ args = { "chmod", "600", path }, playback_only = false }) end
  return true
end

-- Write `content` to `path` (0600) through a temporary file.
local function private_write(path, content)
  ensure_dir()
  local tmp = path .. ".tmp"
  if not private_create(tmp) then return false end
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(content)
  f:close()
  os.remove(path)
  return os.rename(tmp, path) and true or false
end

-- Overwrite with zeros, then delete (credentials).
local function wipe(path)
  local f = io.open(path, "r+")
  if f then
    local n = f:seek("end")
    f:seek("set", 0)
    f:write(string.rep("\0", n or 0))
    f:close()
  end
  os.remove(path)
end

-- ---------- queue files ----------

local function read_queue(svc)
  local q = {}
  local f = io.open(QUEUES[svc], "r")
  if not f then return q end
  for line in f:lines() do
    local item = utils.parse_json(line)
    if type(item) == "table" and (item.listened_at or item.timestamp) then q[#q + 1] = item end
  end
  f:close()
  return q
end

local function write_queue(svc, q)
  local lines = {}
  for i = math.max(1, #q - MAX_QUEUE + 1), #q do lines[#lines + 1] = utils.format_json(q[i]) .. "\n" end
  if #q > MAX_QUEUE then mp.msg.warn(string.format("%s: queue full, %d oldest dropped", svc, #q - MAX_QUEUE)) end
  private_write(QUEUES[svc], table.concat(lines))
end

local function enqueue(svc, items)
  local q = read_queue(svc)
  for _, l in ipairs(items) do q[#q + 1] = l end
  write_queue(svc, q)
  log(string.format("%s: queued %d, %d waiting", svc, #items, #q))
end

-- ---------- HTTP ----------

-- A value for a curl config file ("…" with \\, \", \n, \r, \t escaped).
local function curl_quote(s)
  return '"' .. tostring(s):gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

-- The curl config of one request: headers and body, where secrets live.
local function curl_config(req)
  local lines = {}
  for _, h in ipairs(req.headers or {}) do lines[#lines + 1] = "header = " .. curl_quote(h) end
  if req.body then lines[#lines + 1] = "data-raw = " .. curl_quote(req.body) end
  return table.concat(lines, "\n") .. "\n"
end

local req_n = 0
-- req = { url, headers, body }; cb(code | nil, body, err). The command line (which mpv
-- logs and other local users can see) only holds the URL and a private config file,
-- created empty, made 0600 (without blocking the player), then filled.
local function http(req, cb)
  ensure_dir()
  req_n = req_n + 1
  local cfg = string.format("%s/req-%d-%d.curl", dir, os.time(), req_n)
  local f = io.open(cfg, "w")
  if not f then return cb(nil, "", "cannot write to " .. dir) end
  f:close()
  local function run()
    local w = io.open(cfg, "w")
    if not w then return cb(nil, "", "cannot write to " .. dir) end
    w:write(curl_config(req))
    w:close()
    local a = { "curl", "-sS", "-m", "20", "-o", "-", "-w", "\n%{http_code}", "-A", "Vivi-scrobbler/" .. VERSION,
      "-K", cfg, req.url }
    mp.command_native_async({
      name = "subprocess", args = a, capture_stdout = true, capture_stderr = true, playback_only = false,
    }, function(success, res, err)
      wipe(cfg)
      local out = (res and res.stdout) or ""
      local code = tonumber(out:match("(%d%d%d)%s*$") or "")
      if not success or not res or res.status ~= 0 or not code or code == 0 then
        return cb(nil, "", "network error: " .. trim((res and res.stderr ~= "" and res.stderr) or err or "curl failed"))
      end
      cb(code, (out:gsub("\n%d+%s*$", "")), nil)
    end)
  end
  if windows then return run() end
  mp.command_native_async({ name = "subprocess", args = { "chmod", "600", cfg }, playback_only = false },
    function(ok, res)
      if not ok or not res or res.status ~= 0 then
        wipe(cfg)
        return cb(nil, "", "cannot protect the request file")
      end
      run()
    end)
end

-- https, or plain http only to this computer (a token must not cross the network in clear).
local function safe_url(u)
  u = u:lower()
  if u:match("^https://[^/]") then return true end
  local host = u:match("^http://([^/:]+)") or u:match("^http://%[([^%]]+)%]")
  return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function lb_url(path) return (trim(LB_API or o.api):gsub("/+$", "")) .. path end

-- ListenBrainz: cb(ok, retryable, message, json, code)
local function lb_request(path, body, cb)
  if token() == "" then return cb(false, true, "no ListenBrainz token set") end
  local url = lb_url(path)
  if not safe_url(url) then return cb(false, true, "the ListenBrainz API server must use https") end
  local headers = { "Authorization: Token " .. token() }
  if body then headers[2] = "Content-Type: application/json" end
  http({ url = url, headers = headers, body = body and utils.format_json(body) }, function(code, out, err)
    if not code then return cb(false, true, err) end
    local j = utils.parse_json(out) or {}
    if code >= 200 and code < 300 then return cb(true, false, "ok", j, code) end
    -- 4xx other than 429 will not get better by retrying the same payload, except
    -- 401 (token fixed later): keep those queued too.
    local retry = code >= 500 or code == 429 or code == 401
    cb(false, retry, trim(string.format("HTTP %d %s", code, type(j.error) == "string" and j.error or "")), j, code)
  end)
end

local function lb_submit(body, cb) lb_request("/1/submit-listens", body, cb) end

local function urlencode(s)
  return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Last.fm api_sig: md5 of the sorted "<key><value>" pairs (without format) + secret.
local function lastfm_sig(params, secret)
  local keys = {}
  for k in pairs(params) do if k ~= "format" and k ~= "callback" then keys[#keys + 1] = k end end
  table.sort(keys)
  local s = {}
  for _, k in ipairs(keys) do s[#s + 1] = k .. params[k] end
  return md5(table.concat(s) .. secret)
end

local function form(params)
  local keys = {}
  for k in pairs(params) do keys[#keys + 1] = k end
  table.sort(keys)
  local s = {}
  for _, k in ipairs(keys) do s[#s + 1] = urlencode(k) .. "=" .. urlencode(params[k]) end
  return table.concat(s, "&")
end

local function lastfm_ready()
  return trim(o.lastfm_key) ~= "" and trim(o.lastfm_secret) ~= "" and session ~= nil
    and (session.api_key == nil or session.api_key == trim(o.lastfm_key))
end

-- Last.fm error codes worth retrying later: 8 operation failed, 11 offline, 16 temporary,
-- 29 rate limit; and the credential errors (fixed by the user, so queued scrobbles are
-- kept): 4 authentication failed, 9 invalid session, 10 invalid API key, 13 invalid
-- signature (wrong shared secret), 14/15 token, 26 suspended API key.
local LASTFM_RETRY = { [4] = true, [8] = true, [9] = true, [10] = true, [11] = true, [13] = true,
  [14] = true, [15] = true, [16] = true, [26] = true, [29] = true }
local LASTFM_AUTH_ERR = { [4] = true, [9] = true, [10] = true, [13] = true, [26] = true }

-- Signed Last.fm call; cb(ok, retryable, message, json, error code)
local function lastfm_call(params, cb, no_session)
  params.api_key = trim(o.lastfm_key)
  if not no_session and params.sk == nil then params.sk = session and session.key or "" end
  params.api_sig = lastfm_sig(params, trim(o.lastfm_secret))
  params.format = "json"
  if not safe_url(LASTFM) then return cb(false, true, "Last.fm API URL must use https") end
  http({ url = LASTFM, headers = { "Content-Type: application/x-www-form-urlencoded" }, body = form(params) },
    function(code, out, err)
      if not code then return cb(false, true, err) end
      local j = utils.parse_json(out) or {}
      if code >= 200 and code < 300 and not j.error then return cb(true, false, "ok", j) end
      local e = tonumber(j.error)
      local retry = (e and LASTFM_RETRY[e]) or code >= 500 or code == 429 or (not e and code ~= 400)
      cb(false, retry and true or false, trim(string.format("Last.fm %s %s", e and ("error " .. e) or ("HTTP " .. code),
        type(j.message) == "string" and j.message or "")), j, e)
    end)
end

-- track.scrobble form fields for up to 50 queued items (array notation).
local function lastfm_batch(items)
  local p = { method = "track.scrobble" }
  for i, it in ipairs(items) do
    local n = "[" .. (i - 1) .. "]"
    p["artist" .. n] = it.artist
    p["track" .. n] = it.track
    p["timestamp" .. n] = tostring(it.timestamp)
    if it.album then p["album" .. n] = it.album end
    if it.album_artist then p["albumArtist" .. n] = it.album_artist end
    if it.track_number then p["trackNumber" .. n] = tostring(it.track_number) end
    if it.duration then p["duration" .. n] = tostring(it.duration) end
    if it.mbid then p["mbid" .. n] = it.mbid end
  end
  return p
end

-- Accepted / ignored counts of a track.scrobble answer, with the first ignore reason.
local function lastfm_result(j)
  local s = type(j) == "table" and j.scrobbles or nil
  local attr = type(s) == "table" and s["@attr"] or {}
  local accepted, ignored = tonumber(attr.accepted) or 0, tonumber(attr.ignored) or 0
  local why
  local list = type(s) == "table" and s.scrobble or nil
  if type(list) == "table" and list.ignoredMessage then list = { list } end
  for _, it in ipairs(type(list) == "table" and list or {}) do
    local m = type(it) == "table" and it.ignoredMessage
    if type(m) == "table" and tostring(m.code or "0") ~= "0" then
      why = trim(m["#text"]) ~= "" and trim(m["#text"]) or ("code " .. tostring(m.code))
      break
    end
  end
  return accepted, ignored, why
end

-- ---------- what is playing ----------

local function prop(k)
  local v = mp.get_property("metadata/by-key/" .. k)
  if v and trim(v) ~= "" then return trim(v) end
end

local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
local function mbid(s)
  s = s and trim(s:lower()) or ""
  return s:match(UUID) and s or nil
end

-- Several MBIDs in one tag ("a; b", "a/b").
local function mbids(s)
  local out = {}
  for p in tostring(s or ""):gmatch("[^;/,%s]+") do
    local m = mbid(p)
    if m then out[#out + 1] = m end
  end
  return #out > 0 and out or nil
end

local function is_video()
  for _, t in ipairs(mp.get_property_native("track-list") or {}) do
    if t.type == "video" and not t.albumart and not t.image then return true end
  end
  return false
end

local function list(s)
  local out = {}
  for p in tostring(s or ""):gmatch("[^,;]+") do
    p = trim(p)
    if p ~= "" then out[#out + 1] = p end
  end
  return out
end

local function norm_path(p)
  p = tostring(p or ""):gsub("\\", "/"):gsub("/+$", "")
  if windows then p = p:lower() end
  return p
end

-- Why a track should not be scrobbled (nil: scrobble it). t: { path, genre, video, from_plugin }
local function skip_reason(t)
  if o.audio_only and t.video and not t.from_plugin then return "video (Only music is on)" end
  local genre = (t.genre or ""):lower()
  local ext = (t.path or ""):lower():match("%.(%w+)$")
  for _, g in ipairs(list(o.skip_genres)) do
    local gl = g:lower()
    if genre ~= "" and genre:find(gl, 1, true) then return "genre " .. t.genre end
    if gl == "audiobook" and ext == "m4b" then return "audiobook (.m4b)" end
  end
  local p = norm_path(t.path)
  for _, f in ipairs(list(o.skip_folders)) do
    local nf = norm_path(f)
    if nf ~= "" and (p == nf or p:sub(1, #nf + 1) == nf .. "/") then return "folder " .. f end
  end
end

-- Leading number of a "3/12" track tag.
local function track_no(s)
  local n = tonumber(tostring(s or ""):match("^%s*(%d+)"))
  return n and n > 0 and n or nil
end

-- The playing track as ListenBrainz track_metadata (+ extra fields for Last.fm), or nil, reason.
local function current_track()
  local path = mp.get_property("path", "")
  local pm = stream_meta[path]
  local artist, title = prop("artist"), prop("title")
  local album, album_artist = prop("album"), prop("album_artist") or prop("albumartist")
  if pm then
    artist = trim(pm.artist) ~= "" and trim(pm.artist) or artist
    title = trim(pm.title) ~= "" and trim(pm.title) or title
    album = trim(pm.album) ~= "" and trim(pm.album) or album
  end
  if not artist or not title then return nil, "no artist / title tags" end
  local why = skip_reason({ path = path, genre = prop("genre"), video = is_video(), from_plugin = pm ~= nil })
  if why then return nil, why end
  local duration = mp.get_property_number("duration", 0) or 0
  local info = {
    media_player = "Vivi",
    submission_client = "Vivi scrobbler",
    submission_client_version = VERSION,
  }
  local meta = { artist_name = artist, track_name = title, additional_info = info }
  if album then meta.release_name = album end
  if duration > 0 then info.duration_ms = math.floor(duration * 1000) end
  local rec = mbid(prop("musicbrainz_trackid") or prop("MusicBrainz Track Id"))
  if rec then info.recording_mbid = rec end
  local rel = mbid(prop("musicbrainz_albumid") or prop("MusicBrainz Album Id"))
  if rel then info.release_mbid = rel end
  local arts = mbids(prop("musicbrainz_artistid") or prop("MusicBrainz Artist Id"))
  if arts then info.artist_mbids = arts end
  local tn = track_no(prop("track") or prop("tracknumber"))
  if tn then info.tracknumber = tn end
  if pm then
    if path:match("^https?://") then info.origin_url = path end
    if trim(pm.info) ~= "" then info.music_service_name = trim(pm.info) end
  end
  return {
    meta = meta, duration = duration, album_artist = album_artist, track_number = tn, path = path,
  }
end

-- ---------- scrobbling ----------

local flush

local function payload_of(meta, listened_at)
  local l = { track_metadata = meta }
  if listened_at then l.listened_at = listened_at end
  return l
end

local function lastfm_item(c)
  local m = c.meta
  return {
    artist = m.artist_name, track = m.track_name, album = m.release_name,
    album_artist = c.album_artist ~= m.artist_name and c.album_artist or nil,
    track_number = c.track_number,
    timestamp = c.started_at, mbid = m.additional_info.recording_mbid,
    duration = c.duration > 0 and math.floor(c.duration) or nil,
  }
end

local function services()
  local s = {}
  if token() ~= "" then s[#s + 1] = "lb" end
  if lastfm_ready() then s[#s + 1] = "lastfm" end
  return s
end

local function note_lastfm(j)
  local _, ignored, why = lastfm_result(j)
  if ignored > 0 then
    ignored_count = ignored_count + ignored
    mp.msg.warn(string.format("lastfm: %d scrobble(s) ignored by Last.fm: %s", ignored, why or "?"))
    last_error.lastfm = "ignored by Last.fm: " .. (why or "?")
  end
end

local function scrobble(c)
  for _, svc in ipairs(services()) do
    local item, send
    if svc == "lb" then
      item = payload_of(c.meta, c.started_at)
      send = function(cb) lb_submit({ listen_type = "single", payload = { item } }, cb) end
    else
      item = lastfm_item(c)
      send = function(cb) lastfm_call(lastfm_batch({ item }), cb) end
    end
    send(function(ok, retry, msg, j)
      if ok then
        sent_count[svc] = sent_count[svc] + 1
        last_error[svc] = nil
        if svc == "lastfm" then note_lastfm(j) end
        log(svc .. ": scrobbled " .. c.meta.artist_name .. " - " .. c.meta.track_name)
        flush(false, svc)
      else
        last_error[svc] = msg
        mp.msg.warn(svc .. ": scrobble failed: " .. msg)
        if retry then enqueue(svc, { item }) end
      end
    end)
  end
end

-- Send up to `size` queued items; halves the batch when the server rejects it, so one
-- bad item does not take the others with it.
local function flush_one(svc, manual, size)
  if sending[svc] then return 0 end
  local q = read_queue(svc)
  if #q == 0 then return 0 end
  local ready = (svc == "lb" and token() ~= "") or (svc == "lastfm" and lastfm_ready())
  if not ready then return 0 end
  local max = size or (svc == "lb" and 100 or 50)
  local batch = {}
  for i = 1, math.min(#q, max) do batch[i] = q[i] end
  sending[svc] = true
  local function done(ok, retry, msg, j)
    sending[svc] = false
    if not ok and not retry and #batch > 1 then
      return flush_one(svc, manual, math.ceil(#batch / 2)) -- find the bad one
    end
    if ok or not retry then
      -- Keep anything queued while we were sending.
      local now = read_queue(svc)
      local rest = {}
      for i = #batch + 1, #now do rest[#rest + 1] = now[i] end
      write_queue(svc, rest)
      if ok then
        sent_count[svc] = sent_count[svc] + #batch
        last_error[svc] = nil
        if svc == "lastfm" then note_lastfm(j) end
        log(string.format("%s: sent %d queued", svc, #batch))
        if manual then toast(string.format("Scrobbler: sent %d queued to %s", #batch, NAMES[svc])) end
        if #rest > 0 then flush_one(svc, manual, size) end
      else
        last_error[svc] = msg
        mp.msg.warn(string.format("%s: dropped %d queued item(s) the server rejected: %s", svc, #batch, msg))
        if #rest > 0 then flush_one(svc, manual) end
      end
    else
      last_error[svc] = msg
      if manual then toast("Scrobbler: " .. NAMES[svc] .. ": " .. msg, 6) end
    end
  end
  if svc == "lb" then
    lb_submit({ listen_type = #batch == 1 and "single" or "import", payload = batch }, done)
  else
    lastfm_call(lastfm_batch(batch), done)
  end
  return #batch
end

flush = function(manual, only)
  local n = 0
  for _, svc in ipairs({ "lb", "lastfm" }) do
    if not only or only == svc then n = n + (flush_one(svc, manual) or 0) end
  end
  if manual and n == 0 then
    if #services() == 0 then toast("Scrobbler: set a ListenBrainz token or connect Last.fm first")
    else toast("Scrobbler: nothing queued") end
  end
end

-- Seconds of playback after which a track of `duration` seconds is scrobbled (nil: never).
local function threshold(duration)
  if not duration or duration < 30 then return nil end
  return math.min(duration / 2, 240)
end

local function now_playing(c)
  if not o.now_playing or not threshold(c.duration) and c.duration > 0 then return end
  local meta = c.meta
  if token() ~= "" then
    lb_submit({ listen_type = "playing_now", payload = { payload_of(meta) } }, function(ok, _, msg)
      if not ok then mp.msg.verbose("ListenBrainz now playing failed: " .. msg) end
    end)
  end
  if lastfm_ready() then
    local p = { method = "track.updateNowPlaying", artist = meta.artist_name, track = meta.track_name }
    if meta.release_name then p.album = meta.release_name end
    if c.duration > 0 then p.duration = tostring(math.floor(c.duration)) end
    local it = lastfm_item(c)
    if it.album_artist then p.albumArtist = it.album_artist end
    if it.track_number then p.trackNumber = tostring(it.track_number) end
    if it.mbid then p.mbid = it.mbid end
    lastfm_call(p, function(ok, _, msg)
      if not ok then mp.msg.verbose("Last.fm now playing failed: " .. msg) end
    end)
  end
end

local function start_track()
  cur, last_pos, seeked, skipped = nil, nil, false, nil
  local t, why = current_track()
  if not t then
    skipped = why
    mp.msg.verbose("not scrobbled: " .. why)
    return
  end
  t.played, t.sent, t.started_at = 0, false, os.time()
  cur = t
  now_playing(cur)
end

-- Count played media time from position changes (seeks and pauses do not count).
local function on_time(_, pos)
  if cur and pos and seeked and cur.sent and pos < 2 then
    -- Back at the start after a scrobble (repeat one, or seeked to 0): a new listen.
    cur.played, cur.sent, cur.started_at = 0, false, os.time()
    now_playing(cur)
  end
  if pos then seeked = false end
  if not cur or cur.sent or not pos then
    last_pos = pos
    return
  end
  if last_pos and not mp.get_property_bool("pause", false) then
    local d = pos - last_pos
    local speed = mp.get_property_number("speed", 1) or 1
    if d > 0 and d <= 2 * math.max(1, speed) then cur.played = cur.played + d end
  end
  last_pos = pos
  local need = threshold(cur.duration)
  if need and cur.played >= need then
    cur.sent = true
    scrobble(cur)
  end
end

-- Title / artist of streams that music packages describe (same message Vivi reads for
-- its now-playing card): `vivi-media-meta <id> {"url"…} | {"items":[…]}`.
local function on_media_meta(_, json)
  local m = utils.parse_json(json or "")
  if type(m) ~= "table" then return end
  local items = type(m.items) == "table" and m.items or {}
  if m.url then items[#items + 1] = m end
  for _, it in ipairs(items) do
    if type(it) == "table" and type(it.url) == "string" and it.url ~= "" then
      if stream_meta_n >= META_MAX then stream_meta, stream_meta_n = {}, 0 end
      if not stream_meta[it.url] then stream_meta_n = stream_meta_n + 1 end
      stream_meta[it.url] = { title = it.title, artist = it.artist, album = it.album, info = it.info }
    end
  end
end

-- ---------- love ----------

local function love()
  if not cur then
    return toast(skipped and ("Scrobbler: nothing to love (" .. skipped .. ")") or "Scrobbler: nothing playing")
  end
  local m = cur.meta
  local tasks, results = {}, {}
  if lastfm_ready() then
    tasks[#tasks + 1] = function(done)
      lastfm_call({ method = "track.love", artist = m.artist_name, track = m.track_name }, function(ok, _, msg)
        done(ok and "loved on Last.fm" or ("Last.fm: " .. msg))
      end)
    end
  end
  if token() ~= "" then
    local rec = m.additional_info.recording_mbid
    tasks[#tasks + 1] = function(done)
      if not rec then return done("ListenBrainz needs a MusicBrainz recording id in the tags") end
      lb_request("/1/feedback/recording-feedback", { recording_mbid = rec, score = 1 }, function(ok, _, msg)
        done(ok and "loved on ListenBrainz" or ("ListenBrainz: " .. msg))
      end)
    end
  end
  if #tasks == 0 then return toast("Scrobbler: set a ListenBrainz token or connect Last.fm first") end
  for i, t in ipairs(tasks) do
    t(function(r)
      results[i] = r
      for j = 1, #tasks do if not results[j] then return end end
      toast("♥ " .. m.artist_name .. " – " .. m.track_name .. ": " .. table.concat(results, ", "), 5)
    end)
  end
end

-- ---------- Last.fm desktop authorisation ----------

local function load_session()
  session = nil
  local f = io.open(SESSION, "r")
  if not f then return end
  local j = utils.parse_json(f:read("*a") or "")
  f:close()
  if type(j) == "table" and type(j.key) == "string" and j.key ~= "" then session = j end
end

local function save_session(s)
  session = s
  private_write(SESSION, utils.format_json(s))
end

-- A session key pasted into the setting (or left there by Scrobbler 1.1) moves to the
-- private file; the setting is cleared (Vivi 0.9.1+ can clear it).
local function adopt_setting_session()
  local k = trim(o.lastfm_session)
  if k == "" then return end
  if not session or session.key ~= k then
    save_session({ key = k, api_key = trim(o.lastfm_key) ~= "" and trim(o.lastfm_key) or nil })
    log("lastfm: session key moved to the private session file")
  end
  o.lastfm_session = ""
  mp.commandv("script-message", "vivi-setting", ID, "lastfm_session", "")
end

local function open_url(url)
  local args = windows and { "cmd", "/c", "start", "", url }
    or (os.getenv("VIVI_TEST_NO_BROWSER") and { "true" })
    or { "sh", "-c", 'command -v xdg-open >/dev/null && exec xdg-open "$1" || exec open "$1"', "sh", url }
  mp.command_native_async({ name = "subprocess", args = args, playback_only = false }, function() end)
end

local function stop_poll()
  if auth_poll then auth_poll:kill() end
  auth_poll = nil
end

-- auth.getSession for the pending token. quiet: polling (error 14 = not approved yet).
local function lastfm_finish(quiet)
  if not lastfm_token then
    if quiet ~= true then toast("Press \"Connect Last.fm\" first") end
    return
  end
  local tok = lastfm_token
  lastfm_call({ method = "auth.getSession", token = tok }, function(ok, _, msg, j, e)
    if tok ~= lastfm_token then return end -- finished meanwhile
    if not ok or type(j) ~= "table" or type(j.session) ~= "table" or not j.session.key then
      if quiet == true and (e == 14 or e == nil) then return end
      stop_poll()
      if e == 15 then lastfm_token = nil end
      return toast("Last.fm: " .. msg .. (e == 14 and " (allow access in the browser first)" or ""), 6)
    end
    stop_poll()
    lastfm_token = nil
    save_session({ key = j.session.key, name = j.session.name, api_key = trim(o.lastfm_key) })
    toast("Last.fm connected" .. (j.session.name and (" as " .. tostring(j.session.name)) or ""))
    flush(false, "lastfm")
  end, true)
end

local function lastfm_connect()
  if trim(o.lastfm_key) == "" or trim(o.lastfm_secret) == "" then
    toast("Enter your Last.fm API key and shared secret first (free at last.fm/api/account/create)", 8)
    return
  end
  stop_poll()
  lastfm_call({ method = "auth.getToken" }, function(ok, _, msg, j)
    if not ok or type(j) ~= "table" or not j.token then return toast("Last.fm: " .. msg, 6) end
    lastfm_token = j.token
    open_url(LASTFM_AUTH .. "?api_key=" .. urlencode(trim(o.lastfm_key)) .. "&token=" .. urlencode(j.token))
    toast("Allow Vivi on the Last.fm page in your browser; Vivi connects as soon as you do", 10)
    -- Tokens are valid for 60 minutes; check every 3 s for 5 minutes.
    local tries = 0
    auth_poll = mp.add_periodic_timer(3, function()
      tries = tries + 1
      if tries > 100 then return stop_poll() end
      lastfm_finish(true)
    end)
  end, true)
end

local function lastfm_disconnect()
  stop_poll()
  lastfm_token = nil
  local was = session ~= nil or trim(o.lastfm_session) ~= ""
  session = nil
  wipe(SESSION)
  if trim(o.lastfm_session) ~= "" then
    o.lastfm_session = ""
    mp.commandv("script-message", "vivi-setting", ID, "lastfm_session", "")
  end
  toast(was and "Last.fm disconnected (queued scrobbles are kept)" or "Last.fm was not connected")
end

-- ---------- status ----------

local function status_text(lb_user, lb_err)
  local q = { lb = #read_queue("lb"), lastfm = #read_queue("lastfm") }
  local parts = {}
  local lb
  if token() == "" then lb = "no token"
  elseif lb_user then lb = "ready (" .. lb_user .. ")"
  elseif lb_err then lb = lb_err
  else lb = "token set" end
  parts[#parts + 1] = string.format("ListenBrainz: %s, %d sent, %d queued", lb, sent_count.lb, q.lb)
  local lf
  if lastfm_ready() then lf = "connected" .. (session.name and (" (" .. session.name .. ")") or "")
  elseif trim(o.lastfm_key) == "" then lf = "not set up"
  elseif session then lf = "API key changed, connect again"
  else lf = "not connected" end
  parts[#parts + 1] = string.format("Last.fm: %s, %d sent, %d queued", lf, sent_count.lastfm, q.lastfm)
  if cur then
    local need = threshold(cur.duration)
    parts[#parts + 1] = string.format("%s – %s: %s", cur.meta.artist_name, cur.meta.track_name,
      cur.sent and "scrobbled" or need and string.format("%d/%d s", math.floor(cur.played), math.floor(need))
      or "too short")
  elseif skipped then
    parts[#parts + 1] = "Not scrobbled: " .. skipped
  end
  for _, svc in ipairs({ "lb", "lastfm" }) do
    if last_error[svc] then parts[#parts + 1] = "Last error (" .. NAMES[svc] .. "): " .. last_error[svc] end
  end
  return table.concat(parts, " · ")
end

local function status()
  if token() == "" then return toast(status_text(), 8) end
  lb_request("/1/validate-token", nil, function(ok, _, msg, j, code)
    if ok and type(j) == "table" and j.valid then return toast(status_text(tostring(j.user_name or "?")), 8) end
    local err = (ok or code == 401) and "token invalid" or ("unreachable: " .. msg)
    toast(status_text(nil, err), 8)
  end)
end

-- ---------- wiring ----------

-- Leftover request files of a crashed run.
local function clean_requests()
  for _, f in ipairs(utils.readdir(dir, "files") or {}) do
    if f:match("^req%-.*%.curl$") then wipe(dir .. "/" .. f) end
  end
end

mp.register_event("file-loaded", start_track)
mp.observe_property("playback-time", "number", on_time)
mp.register_event("seek", function() last_pos, seeked = nil, true end)

options.read_options(o, ID, function(changed)
  if changed.lastfm_session then adopt_setting_session() end
end)
load_session()
adopt_setting_session()
clean_requests()

mp.register_script_message("flush", function() flush(true) end)
mp.register_script_message("status", status)
mp.register_script_message("love", love)
mp.register_script_message("lastfm_connect", lastfm_connect)
mp.register_script_message("lastfm_finish", function() lastfm_finish(false) end)
mp.register_script_message("lastfm_disconnect", lastfm_disconnect)
mp.register_script_message("vivi-media-meta", on_media_meta)
mp.add_forced_key_binding("Alt+l", "scrobbler-love", love)

mp.add_timeout(5, function() flush(false) end)
mp.add_periodic_timer(600, function() flush(false) end)

if VIVI_TEST then
  M.md5, M.pure_bitops, M.lastfm_sig, M.lastfm_batch, M.threshold = md5, pure_bitops, lastfm_sig, lastfm_batch, threshold
  M.form, M.lastfm_item, M.curl_config, M.curl_quote, M.safe_url = form, lastfm_item, curl_config, curl_quote, safe_url
  M.skip_reason, M.current_track, M.lastfm_result, M.mbid, M.mbids, M.track_no = skip_reason, current_track, lastfm_result, mbid, mbids, track_no
  M.start_track, M.on_time, M.on_seek = start_track, on_time, function() last_pos, seeked = nil, true end
  M.on_media_meta, M.flush, M.status_text, M.read_queue, M.enqueue = on_media_meta, flush, status_text, read_queue, enqueue
  M.love, M.lastfm_connect, M.lastfm_finish, M.lastfm_disconnect = love, lastfm_connect, lastfm_finish, lastfm_disconnect
  M.opts, M.dir, M.SESSION, M.QUEUES = o, dir, SESSION, QUEUES
  M.state = function() return { cur = cur, session = session, sent = sent_count, err = last_error, skipped = skipped } end
  M.load_session, M.adopt = load_session, adopt_setting_session
  return M
end
