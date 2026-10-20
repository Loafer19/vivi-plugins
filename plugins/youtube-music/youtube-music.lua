-- YouTube Music for Vivi: your own YouTube Music account (search, library, up next,
-- mixes, likes, adding to playlists, opt-in downloads) through YouTube Music's web API
-- (InnerTube, music.youtube.com/youtubei/v1, client WEB_REMIX), as the web app and
-- ytmusicapi use it. Unofficial: Google can change it at any time and may restrict
-- accounts that use it.
--
-- Sign-in: the youtube.com cookies of your browser (yt-dlp --cookies-from-browser), a
-- cookies.txt or request-headers file, or a Cookie header / "Copy as cURL" from the
-- clipboard. Only youtube.com cookies are kept, in <data>/vivi/plugin-data/youtube-music/
-- cookies.txt (folder 0700, file 0600 through Vivi's vivi-protect); Sign out wipes it.
-- Requests go through curl with the headers in a config file in that folder, never on
-- the command line; cookie values are never logged or shown.
--
-- UI: Vivi's shared music dialog through the host API (vivi-dialog / vivi-ui, see
-- docs/plugins-architecture.md in Loafer19/vivi). Playback: mpv loadfile with
-- per-file options (cookies for yt-dlp, audio-only format, title). Downloads: yt-dlp
-- with tags and a square cover, progress from a log file, cancel; jobs show in Vivi's
-- shared Downloads panel (vivi-download) when it has one.
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

local ID = "youtube-music"
local NAME = "YouTube Music"
local o = {
  browser = "Firefox",
  ["cookie-file"] = "",
  ["up-next"] = true,
  ["audio-only"] = true,
  view = "List",
  downloads = false,
  folder = "",
  ["audio-format"] = "Original (m4a/opus, no re-encode)",
  pkgdir = "",
}

local windows = package.config:sub(1, 1) == "\\"
local SEP = windows and "\\" or "/"
local HOME = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
local DATA_HOME = os.getenv("XDG_DATA_HOME")
if not DATA_HOME or DATA_HOME == "" then DATA_HOME = HOME .. SEP .. ".local" .. SEP .. "share" end
local DATA = DATA_HOME .. SEP .. "vivi" .. SEP .. "plugin-data" .. SEP .. ID
local JAR = DATA .. SEP .. "cookies.txt"
local ACCOUNT = DATA .. SEP .. "account.txt"      -- display name only
local RUN_JAR = DATA .. SEP .. "cookies-yt-dlp.txt" -- copy handed to yt-dlp / mpv (see ytdlp_jar)
local INDEX = DATA .. SEP .. "downloads.tsv" -- <video id> TAB <file>, one line per download
local ACCEPTED = DATA .. SEP .. "downloads-accepted" -- the download warning was accepted
local unpack = table.unpack or unpack
local ORIGIN = "https://music.youtube.com"
local API = ORIGIN .. "/youtubei/v1/"
local UA = "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0"
local FIXTURES = os.getenv("VIVI_YTM_FIXTURES") -- screenshots / tests: canned answers
if FIXTURES == "" then FIXTURES = nil end

local FILTERS = {
  { "Songs", "EgWKAQIIAWoMEA4QChADEAQQCRAF", "song" },
  { "Albums", "EgWKAQIYAWoMEA4QChADEAQQCRAF", "album" },
  { "Artists", "EgWKAQIgAWoMEA4QChADEAQQCRAF", "artist" },
  { "Playlists", "Eg-KAQwIABAAGAAgACgBMABqChAEEAMQCRAFEAo=", "playlist" },
  { "Videos", "EgWKAQIQAWoMEA4QChADEAQQCRAF", "video" },
  { "All results", "", nil },
}
local LIBRARY = {
  { "Liked songs", "VLLM" },
  { "Playlists", "FEmusic_liked_playlists" },
  { "Albums", "FEmusic_liked_albums" },
  { "History", "FEmusic_history" },
}
local KIND_LABEL = { song = "Song", video = "Video", album = "Album", artist = "Artist", playlist = "Playlist" }
local FORMATS = { "Original (m4a/opus, no re-encode)", "m4a", "mp3", "opus" }
local BROWSERS = { "Firefox", "Chrome", "Chromium", "Brave", "Edge", "Opera", "Vivaldi", "Safari", "Whale" }
local RADIO, PLAY_MAX = 25, 200

local function is_track(it) return it.kind == "song" or it.kind == "video" end

-- ---------------------------------------------------------------- small helpers
local function toast(msg, secs)
  mp.msg.info(msg)
  mp.commandv("script-message", "vivi-toast", msg, tostring(secs or 3))
end

-- Sign-in results: also a desktop notification (Vivi shows it as a toast when they are
-- off), so they are seen when nothing plays; failures go to the terminal log as warnings.
local function signin_result(ok, msg)
  if ok then mp.msg.info(msg) else mp.msg.warn(msg) end
  mp.commandv("script-message", "vivi-toast", msg, ok and "5" or "8")
  mp.commandv("script-message", "vivi-notify", "youtube-music", ok and "YouTube Music: signed in" or "YouTube Music: sign-in failed", msg)
end

local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function keys_sorted(t)
  local k = {}
  for x in pairs(t) do k[#k + 1] = x end
  table.sort(k, function(a, b) return tostring(a) < tostring(b) end)
  return k
end

local function is_array(t) return type(t) == "table" and (t[1] ~= nil or next(t) == nil) end

-- `v["a"]["b"]…` without errors on missing keys.
local function get(v, ...)
  for _, k in ipairs({ ... }) do
    if type(v) ~= "table" then return nil end
    v = v[k]
  end
  return v
end

local function str(v) return type(v) == "string" and v or "" end

local function text(v)
  if type(v) ~= "table" then return "" end
  if type(v.simpleText) == "string" then return v.simpleText end
  local out = {}
  for _, r in ipairs(v.runs or {}) do out[#out + 1] = str(r.text) end
  return table.concat(out)
end

-- "3:28" / "1:02:05" → seconds; nil for anything else.
local function parse_len(s)
  s = trim(s)
  if s == "" or not s:find(":") then return nil end
  local total = 0
  for p in (s .. ":"):gmatch("([^:]*):") do
    if not p:match("^%d%d?$") then return nil end
    total = total * 60 + tonumber(p)
  end
  return total
end

local function clock(n)
  if not n or n <= 0 then return "" end
  local h, m, s = math.floor(n / 3600), math.floor(n % 3600 / 60), n % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
  return string.format("%d:%02d", m, s)
end

-- googleusercontent `=w60-h60-l90-rj` → `=w<px>-h<px>-l90-rj`.
local function resize(u, px)
  if not u:find("googleusercontent.com", 1, true) then return u end
  local i = u:match("^.*()=w")
  if not i then return u end
  local tail = u:sub(i + 2)
  local rest = tail:match("^[^-]*(%-.*)$") or ""
  rest = rest:gsub("^%-h[^-]*", "")
  return u:sub(1, i - 1) .. "=w" .. px .. "-h" .. px .. rest
end

local function thumbs(a)
  if type(a) ~= "table" or #a == 0 then return "", "" end
  local function url(t)
    local u = str(t.url)
    if u:sub(1, 2) == "//" then u = "https:" .. u end
    return u
  end
  local big, list, bw, lw = nil, nil, -1, math.huge
  for _, t in ipairs(a) do
    local w = tonumber(t.width) or 0
    if w > bw then big, bw = t, w end
    if w >= 200 and w < lw then list, lw = t, w end
  end
  local b = url(big)
  return resize(list and url(list) or b, 226), resize(b, 544)
end

local function page_type(ep)
  return str(get(ep, "browseEndpoint", "browseEndpointContextSupportedConfigs",
    "browseEndpointContextMusicConfig", "pageType"))
end

local function video_kind(w)
  local t = get(w, "watchEndpointMusicSupportedConfigs", "watchEndpointMusicConfig", "musicVideoType")
  if t == nil or t == "MUSIC_VIDEO_TYPE_ATV" then return "song" end
  return "video"
end

local function kind_from(ep, video)
  local p = page_type(ep)
  if p == "MUSIC_PAGE_TYPE_ALBUM" or p == "MUSIC_PAGE_TYPE_AUDIOBOOK" then return "album" end
  if p == "MUSIC_PAGE_TYPE_ARTIST" or p == "MUSIC_PAGE_TYPE_USER_CHANNEL" or p == "MUSIC_PAGE_TYPE_LIBRARY_ARTIST" then return "artist" end
  if p == "MUSIC_PAGE_TYPE_PLAYLIST" or p == "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE" then return "playlist" end
  if video ~= "" then return "song" end
  return nil
end

-- ---------------------------------------------------------------- InnerTube parsing
local M = {} -- exported for tests

local NOT_EXTRA = { Song = 1, Video = 1, Episode = 1, Album = 1, Playlist = 1, Artist = 1, Profile = 1 }

local function subtitle_runs(it, runs, artists, extras)
  for _, r in ipairs(runs or {}) do
    local t = trim(str(r.text))
    if t ~= "" and t ~= "•" and t ~= "&" and t ~= "," then
      local ep = r.navigationEndpoint
      local p = page_type(ep)
      if p == "MUSIC_PAGE_TYPE_ARTIST" or p == "MUSIC_PAGE_TYPE_USER_CHANNEL" then
        if it.artist_id == "" then it.artist_id = str(get(ep, "browseEndpoint", "browseId")) end
        artists[#artists + 1] = t
      elseif p == "MUSIC_PAGE_TYPE_ALBUM" then
        it.album, it.album_id = t, str(get(ep, "browseEndpoint", "browseId"))
      else
        local d = parse_len(t)
        if d then
          it.duration = d
        elseif not NOT_EXTRA[t] or it.kind == "album" then
          extras[#extras + 1] = t
        end
      end
    end
  end
end

-- "1.1M plays", "12M views", "2019": counts and years, never an artist name.
local function is_stat(t)
  local l = t:lower()
  for _, w in ipairs({ "plays", "play", "views", "view", "watching" }) do
    if l:sub(-(#w + 1)) == " " .. w then return true end
  end
  return t:match("^%d%d%d%d$") ~= nil
end

local function new_item(title)
  return { kind = "song", title = title or "", artist = "", artist_id = "", album = "", album_id = "",
    video_id = "", playlist_id = "", browse_id = "", duration = 0, thumb = "", thumb_full = "", extra = "" }
end

local function finish(it, artists, extras)
  if it.title == "" then return nil end
  local plain
  for i, e in ipairs(extras) do if not is_stat(e) then plain = i break end end
  if #artists == 0 and is_track(it) and plain then
    it.artist = table.remove(extras, plain)
  else
    it.artist = table.concat(artists, ", ")
  end
  if it.kind == "album" and extras[1] == "Album" then table.remove(extras, 1) end
  it.extra = table.concat(extras, " · ")
  return it
end

function M.parse_responsive(r)
  local cols = r.flexColumns
  if type(cols) ~= "table" or not cols[1] then return nil end
  local title_v = get(cols[1], "musicResponsiveListItemFlexColumnRenderer", "text")
  local it = new_item(text(title_v))
  local title_watch = get(title_v, "runs", 1, "navigationEndpoint", "watchEndpoint")
  local play = get(r, "overlay", "musicItemThumbnailOverlayRenderer", "content",
    "musicPlayButtonRenderer", "playNavigationEndpoint")
  it.video_id = str(get(r, "playlistItemData", "videoId"))
  if it.video_id == "" then it.video_id = str(get(play, "watchEndpoint", "videoId")) end
  if it.video_id == "" then it.video_id = str(get(title_watch, "videoId")) end
  local nav = r.navigationEndpoint
  it.browse_id = str(get(nav, "browseEndpoint", "browseId"))
  it.playlist_id = str(get(play, "watchPlaylistEndpoint", "playlistId"))
  it.kind = kind_from(nav, it.video_id)
  if not it.kind then return nil end
  if it.kind == "song" then
    it.kind = video_kind(get(play, "watchEndpoint") or title_watch)
  else
    it.video_id = "" -- pages are opened, not played
  end
  it.thumb, it.thumb_full = thumbs(get(r, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails"))
  it.index = tonumber(text(r.index)) -- position on an album / playlist page
  local artists, extras = {}, {}
  for i = 2, #cols do
    subtitle_runs(it, get(cols[i], "musicResponsiveListItemFlexColumnRenderer", "text", "runs"), artists, extras)
  end
  for _, c in ipairs(r.fixedColumns or {}) do
    local d = parse_len(text(get(c, "musicResponsiveListItemFixedColumnRenderer", "text")))
    if d then it.duration = d end
  end
  if it.kind == "artist" then artists = {} end
  return finish(it, artists, extras)
end

function M.parse_two_row(r)
  local nav = r.navigationEndpoint
  local play = get(r, "thumbnailOverlay", "musicItemThumbnailOverlayRenderer", "content",
    "musicPlayButtonRenderer", "playNavigationEndpoint")
  local it = new_item(text(r.title))
  it.video_id = str(get(nav, "watchEndpoint", "videoId"))
  it.browse_id = str(get(nav, "browseEndpoint", "browseId"))
  it.playlist_id = str(get(play, "watchPlaylistEndpoint", "playlistId"))
  if it.playlist_id == "" then it.playlist_id = str(get(nav, "watchPlaylistEndpoint", "playlistId")) end
  it.kind = kind_from(nav, it.video_id)
  if not it.kind then return nil end
  if it.kind == "song" then it.kind = video_kind(get(nav, "watchEndpoint")) end
  it.thumb, it.thumb_full = thumbs(get(r, "thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails"))
  local artists, extras = {}, {}
  subtitle_runs(it, get(r, "subtitle", "runs"), artists, extras)
  if it.kind == "artist" then artists = {} end
  return finish(it, artists, extras)
end

function M.parse_panel(r)
  if type(r.videoId) ~= "string" then return nil end
  local it = new_item(text(r.title))
  it.kind = video_kind(get(r, "navigationEndpoint", "watchEndpoint"))
  it.video_id = r.videoId
  it.duration = parse_len(text(r.lengthText)) or 0
  it.thumb, it.thumb_full = thumbs(get(r, "thumbnail", "thumbnails"))
  local artists, extras = {}, {}
  subtitle_runs(it, get(r, "longBylineText", "runs"), artists, extras)
  local keep = {}
  for _, e in ipairs(extras) do if not e:match("^%d%d%d%d$") then keep[#keep + 1] = e end end
  return finish(it, artists, keep)
end

local CHROME = { header = 1, microformat = 1, frameworkUpdates = 1, responseContext = 1, background = 1, menu = 1 }

function M.key(it)
  if it.video_id ~= "" then return it.video_id end
  if it.browse_id ~= "" then return it.browse_id end
  return it.playlist_id
end

-- Every list item in an answer, whatever the layout around it (de-duplicated).
function M.collect(v)
  local out = {}
  local function walk(x)
    if type(x) ~= "table" then return end
    if is_array(x) then
      for _, y in ipairs(x) do walk(y) end
      return
    end
    for _, k in ipairs(keys_sorted(x)) do
      local y = x[k]
      local it
      if k == "musicResponsiveListItemRenderer" then it = M.parse_responsive(y)
      elseif k == "musicTwoRowItemRenderer" then it = M.parse_two_row(y)
      elseif k == "playlistPanelVideoRenderer" then it = M.parse_panel(y)
      elseif not CHROME[k] then walk(y) end
      if it then out[#out + 1] = it end
    end
  end
  walk(v)
  local seen, res = {}, {}
  for _, it in ipairs(out) do
    local k = M.key(it)
    if not seen[k] then seen[k] = true res[#res + 1] = it end
  end
  return res
end

local SHELF = { musicShelfRenderer = 1, musicPlaylistShelfRenderer = 1, gridRenderer = 1,
  musicShelfContinuation = 1, musicPlaylistShelfContinuation = 1, gridContinuation = 1 }

-- The next page: { body = token } (continuationItemRenderer) or { query = token }
-- (nextContinuationData of a shelf, not of the page's suggestions).
function M.continuation(v)
  local function walk(x, shelf)
    if type(x) ~= "table" then return nil end
    if is_array(x) then
      for _, y in ipairs(x) do
        local r = walk(y, shelf)
        if r then return r end
      end
      return nil
    end
    local t = get(x, "continuationItemRenderer", "continuationEndpoint", "continuationCommand", "token")
    if type(t) == "string" then return { body = t } end
    if shelf then
      t = get(x, "nextContinuationData", "continuation")
      if type(t) == "string" then return { query = t } end
    end
    for _, k in ipairs(keys_sorted(x)) do
      if k ~= "header" and k ~= "frameworkUpdates" and k ~= "responseContext" then
        local r = walk(x[k], shelf or SHELF[k] ~= nil)
        if r then return r end
      end
    end
    return nil
  end
  return walk(v, false)
end

function M.find(v, key)
  if type(v) ~= "table" then return nil end
  if not is_array(v) and v[key] ~= nil then return v[key] end
  for _, k in ipairs(keys_sorted(v)) do
    local r = M.find(v[k], key)
    if r ~= nil then return r end
  end
  return nil
end

function M.parse_page(v, browse_id)
  local h = M.find(v, "musicResponsiveHeaderRenderer") or M.find(v, "musicDetailHeaderRenderer")
    or M.find(v, "musicImmersiveHeaderRenderer") or M.find(v, "musicVisualHeaderRenderer")
  local p = { title = "", sub = "", thumb = "", items = M.collect(v), cont = M.continuation(v), playlist_id = "" }
  if h then
    p.title = text(h.title)
    p.year = text(h.subtitle):match("%f[%d](%d%d%d%d)%f[%D]")
    local artist = text(h.straplineTextOne)
    local parts = {}
    for _, s in ipairs({ artist, text(h.subtitle), text(h.secondSubtitle) }) do
      s = s:gsub(" • ", " · "):gsub("^[%s·•]+", ""):gsub("[%s·•]+$", "")
      if s ~= "" then parts[#parts + 1] = s end
    end
    p.sub = table.concat(parts, " · ")
    local th = get(h, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")
      or get(h, "thumbnail", "croppedSquareThumbnailRenderer", "thumbnail", "thumbnails")
    local _, big = thumbs(th)
    p.thumb = big
    if browse_id:sub(1, 4) == "MPRE" then
      for _, it in ipairs(p.items) do
        if it.album == "" then it.album, it.album_id = p.title, browse_id end
        if it.artist == "" then it.artist = artist end
        if it.thumb == "" then it.thumb, it.thumb_full = resize(p.thumb, 226), p.thumb end
        -- Album tracks: the row number is the track number (tags and file names).
        if it.album_id == browse_id then it.track_no, it.year = it.index, p.year end
      end
    end
  end
  if browse_id:sub(1, 2) == "VL" then p.playlist_id = browse_id:sub(3) end
  if p.playlist_id == "" then p.playlist_id = str(get(M.find(v, "watchPlaylistEndpoint"), "playlistId")) end
  return p
end

function M.account_name(v)
  local n = text(M.find(v, "accountName"))
  return n ~= "" and n or nil
end

function M.needs_sign_in(v)
  return M.find(v, "musicNotifierShelfRenderer") ~= nil
    or (M.find(v, "signInEndpoint") ~= nil and #M.collect(v) == 0)
end

function M.sub(it)
  local parts, n = {}, is_track(it) and 2 or 3
  for _, s in ipairs({ it.artist, it.album, it.extra }) do
    if s ~= "" and #parts < n then parts[#parts + 1] = s end
  end
  return table.concat(parts, " · ")
end

function M.url(it) return "https://music.youtube.com/watch?v=" .. it.video_id end

function M.page_url(it)
  if is_track(it) then return M.url(it) end
  if it.browse_id ~= "" then return "https://music.youtube.com/browse/" .. it.browse_id end
  return "https://music.youtube.com/playlist?list=" .. it.playlist_id
end

-- ---------------------------------------------------------------- cookies
local function cookie_matches(c, host)
  local d = c.domain:gsub("^%.", "")
  return host == d or host:sub(-(#d + 1)) == "." .. d
end

function M.parse_netscape(s)
  local out = {}
  for line in (s .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local http_only = false
    if line:sub(1, 10) == "#HttpOnly_" then line, http_only = line:sub(11), true end
    if line:sub(1, 1) ~= "#" then
      local f = {}
      for x in (line .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = x end
      if #f >= 7 and f[6] ~= "" then
        out[#out + 1] = { domain = f[1], path = f[3], secure = f[4]:upper() == "TRUE",
          expires = tonumber(f[5]) or 0, name = f[6], value = table.concat(f, "\t", 7), http_only = http_only }
      end
    end
  end
  return out
end

-- Expiry as whole Unix seconds. yt-dlp's Chrome reader stores Chrome's own expires_utc
-- (microseconds since 1601, ~1.3e16), and LuaJIT's tostring() prints such numbers as
-- "1.3471032042792e+16": yt-dlp then skipped every sign-in cookie of the jar (and saved
-- the jar back without them). 0 = session cookie.
function M.unix_expiry(e)
  e = tonumber(e) or 0
  if e > 1e11 then e = e / 1e6 - 11644473600 end -- Chrome / WebKit time
  if e > 1e11 or e < 0 or e ~= e then return 0 end
  return math.floor(e)
end

function M.to_netscape(v)
  local s = { "# Netscape HTTP Cookie File", "# Written by Vivi (YouTube Music plugin). Keep it private.", "" }
  for _, c in ipairs(v) do
    s[#s + 1] = table.concat({ (c.http_only and "#HttpOnly_" or "") .. c.domain,
      c.domain:sub(1, 1) == "." and "TRUE" or "FALSE", c.path ~= "" and c.path or "/",
      c.secure and "TRUE" or "FALSE", string.format("%d", M.unix_expiry(c.expires)), c.name, c.value }, "\t")
  end
  return table.concat(s, "\n") .. "\n"
end

local function header_cookies(h)
  local out = {}
  for part in (h .. ";"):gmatch("([^;]*);") do
    local k, v = part:match("^%s*([^=]-)%s*=%s*(.-)%s*$")
    if k and k ~= "" and not k:find(" ") then
      out[#out + 1] = { domain = ".youtube.com", path = "/", secure = true, expires = 0, name = k, value = v, http_only = false }
    end
  end
  return out
end

-- The Cookie header inside copied request headers, a cURL command or browser.json.
local function find_cookie_header(s)
  local lower = s:lower()
  for _, key in ipairs({ "cookie: ", "cookie:", "\"cookie\": \"", "\"cookie\":\"", "-b '", "-b \"", "-b $'",
    "--cookie '", "--cookie \"", "--cookie $'" }) do
    local from = 1
    while true do
      local i, j = lower:find(key, from, true)
      if not i then break end
      from = j + 1
      local before = i > 1 and lower:sub(i - 1, i - 1) or ""
      if not (key:sub(1, 1) == "c" and before:match("[%w%-]")) then
        local rest = s:sub(j + 1)
        local v = trim(rest:match("^([^\n'\"]*)") or "")
        if v:find("=") then return v end
      end
    end
  end
  return nil
end

function M.youtube_only(v)
  local out = {}
  for _, c in ipairs(v) do
    if cookie_matches(c, "music.youtube.com") or c.domain:gsub("^%.", "") == "youtube.com" then out[#out + 1] = c end
  end
  return out
end

function M.sapisid(v)
  for _, n in ipairs({ "__Secure-3PAPISID", "SAPISID" }) do
    for _, c in ipairs(v) do if c.name == n and c.value ~= "" then return c.value end end
  end
  return nil
end

function M.cookie_header(v, host)
  local out = {}
  for _, c in ipairs(v) do if cookie_matches(c, host) then out[#out + 1] = c.name .. "=" .. c.value end end
  return table.concat(out, "; ")
end

-- Cookies from a cookies.txt, request headers, a cURL command, browser.json or a bare
-- header value. nil + why when there is no signed-in youtube.com cookie.
function M.parse_any(s)
  s = trim(s)
  if s == "" then return nil, "Nothing to import: the text is empty" end
  local v = M.parse_netscape(s)
  if #v == 0 then
    local h = find_cookie_header(s)
    if not h and not s:find("\n") and s:find("=") then h = trim(s:gsub("^[Cc]ookie:", "")) end
    v = h and header_cookies(h) or {}
  end
  v = M.youtube_only(v)
  if #v == 0 then return nil, "No youtube.com cookies found: copy the Cookie header of a music.youtube.com request or export cookies.txt" end
  if not M.sapisid(v) then return nil, "These cookies are not signed in (no SAPISID): sign in at music.youtube.com in that browser first" end
  return v
end

-- SHA-1 for the SAPISIDHASH header (pure Lua; uses LuaJIT's bit / Lua 5.2's bit32).
local bitlib = (function()
  local ok, b = pcall(require, "bit")
  if ok and b then
    return { band = function(a, c) return b.band(a, c) % 4294967296 end, bor = function(a, c) return b.bor(a, c) % 4294967296 end,
      bxor = function(a, c) return b.bxor(a, c) % 4294967296 end, bnot = function(a) return b.bnot(a) % 4294967296 end,
      lrot = function(a, n) return b.rol(a, n) % 4294967296 end }
  end
  if bit32 then
    return { band = bit32.band, bor = bit32.bor, bxor = bit32.bxor, bnot = bit32.bnot, lrot = bit32.lrotate }
  end
  -- Plain arithmetic (Lua 5.1 without bit).
  local function op(a, c, f)
    local r, p = 0, 1
    for _ = 1, 32 do
      local x, y = a % 2, c % 2
      if f(x, y) then r = r + p end
      a, c, p = (a - x) / 2, (c - y) / 2, p * 2
    end
    return r
  end
  return {
    band = function(a, c) return op(a, c, function(x, y) return x == 1 and y == 1 end) end,
    bor = function(a, c) return op(a, c, function(x, y) return x == 1 or y == 1 end) end,
    bxor = function(a, c) return op(a, c, function(x, y) return x ~= y end) end,
    bnot = function(a) return 4294967295 - a end,
    lrot = function(a, n) local p = 2 ^ n return (a * p) % 4294967296 + math.floor(a / 2 ^ (32 - n)) end,
  }
end)()

function M.sha1_hex(msg)
  local band, bor, bxor, bnot, lrot = bitlib.band, bitlib.bor, bitlib.bxor, bitlib.bnot, bitlib.lrot
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local ml = #msg * 8
  msg = msg .. "\128" .. string.rep("\0", (55 - #msg) % 64)
  for i = 7, 0, -1 do msg = msg .. string.char(math.floor(ml / 2 ^ (8 * i)) % 256) end
  for chunk = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for i = 16, 79 do w[i] = lrot(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1) end
    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then f, k = bxor(bxor(b, c), d), 0x6ED9EBA1
      elseif i < 60 then f, k = bor(bor(band(b, c), band(b, d)), band(c, d)), 0x8F1BBCDC
      else f, k = bxor(bxor(b, c), d), 0xCA62C1D6 end
      local t = (lrot(a, 5) + f + e + k + w[i]) % 4294967296
      a, b, c, d, e = t, a, lrot(b, 30), c, d
    end
    h0, h1, h2, h3, h4 = (h0 + a) % 4294967296, (h1 + b) % 4294967296, (h2 + c) % 4294967296,
      (h3 + d) % 4294967296, (h4 + e) % 4294967296
  end
  return string.format("%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
end

function M.sapisid_hash(sapisid, unix)
  return string.format("SAPISIDHASH %d_%s", unix, M.sha1_hex(string.format("%d %s %s", unix, sapisid, ORIGIN)))
end

-- `%len%`-quoted mpv option value (survives commas and `=`).
local function q(s) return "%" .. #s .. "%" .. s end

-- Per-file mpv options for a track: title, audio-only format, cookies for yt-dlp.
function M.file_options(title, audio_only, jar)
  local v = {}
  if title and title ~= "" then v[#v + 1] = "force-media-title=" .. q(title) end
  if audio_only then v[#v + 1] = "ytdl-format=" .. q("bestaudio/best") end
  if jar then v[#v + 1] = "ytdl-raw-options=" .. q("cookies=" .. q(jar)) end
  return table.concat(v, ",")
end

-- "mpv v0.40.0" → true when 0.<minor> or newer.
function M.mpv_at_least(version, minor)
  local v = (version or ""):match("(%d+%.%d+)")
  if not v then return true end
  local maj, mi = v:match("(%d+)%.(%d+)")
  return tonumber(maj) > 0 or tonumber(mi) >= minor
end

-- ---------------------------------------------------------------- download arguments
-- Files: <folder>/<artist>/<album>/[NN ]<title>.<ext>, e.g. "Artist/Album/03 Song.m4a"
-- (NN only for tracks of an album page; "Singles" without an album). " [<video id>]" is
-- added only when another video already has that name. yt-dlp makes the names safe
-- (--windows-filenames). vivi_no is the zero-padded track number (--parse-metadata).
local AUDIO_FORMAT = "141/bestaudio[ext=m4a]/bestaudio/best"
-- YouTube thumbnails are 16:9 with bars around the square cover: crop the middle square.
local CROP = "ThumbnailsConvertor+ffmpeg_o:-c:v mjpeg -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\""

local function tmpl_lit(s) return (s:gsub("%%", "%%%%")) end

function M.out_template(dir, with_id)
  return tmpl_lit(dir) .. SEP .. "%(artists.0,artist,creator,uploader|Unknown artist)s" .. SEP .. "%(album,vivi_album|Singles)s"
    .. SEP .. "%(vivi_no&{} |)s%(track,vivi_title,title)s" .. (with_id and " [%(id)s]" or "") .. ".%(ext)s"
end

-- --parse-metadata for the tags: track number (album pages), year (release year, else
-- the album page's, else the upload year), album artist (first artist); YouTube's long
-- description / synopsis are left out. YouTube Music's album and track title are the
-- fallback (vivi_album / vivi_title): yt-dlp has no album for the "video" tracks of an
-- album and some songs, which then landed in Singles under the video's title.
-- A --parse-metadata FROM is a template: literal % doubled, ":" escaped, and an empty
-- field first so a one-word literal ("Action") is not read as a field name.
function M.meta_lit(v) return "%(vivi_none|)s" .. (tostring(v):gsub("%%", "%%%%"):gsub(":", "\\:")) end
function M.meta_args(it)
  local a = {}
  local function pm(v) a[#a + 1] = "--parse-metadata" a[#a + 1] = v end
  local album = trim(tostring(it and it.album or ""))
  if album ~= "" then
    pm(M.meta_lit(album) .. ":(?P<vivi_album>.+)")
    pm("%(album,vivi_album)s:%(meta_album)s")
  end
  local title = trim(tostring(it and it.title or ""))
  if title ~= "" and it.kind == "video" then
    pm(M.meta_lit(title) .. ":(?P<vivi_title>.+)")
    pm("%(track,vivi_title,title)s:%(meta_title)s")
  end
  local n = tonumber(it and it.track_no)
  if n and n > 0 and n < 1000 then
    n = math.floor(n)
    pm(string.format("%02d:%%(vivi_no)s", n))
    pm(string.format("%d:%%(meta_track)s", n))
  end
  local y = tostring(it and it.year or ""):match("^%d%d%d%d$")
  pm("%(release_year,release_date>%Y" .. (y and ("|" .. y) or ",upload_date>%Y") .. ")s:%(meta_date)s")
  pm("%(artists.0,artist,creator,uploader)s:%(meta_album_artist)s")
  pm(":(?P<meta_synopsis>)")
  pm(":(?P<meta_description>)")
  return a
end

-- Step 1: metadata only. Prints the file name the download would get and a few fields,
-- writes the info JSON for step 2 (no second extraction); -v lists yt-dlp's optional
-- libraries (mutagen embeds covers in opus).
function M.probe_args(url, dir, jar, info_base, meta)
  local a = { "-v", "--ignore-config", "--no-playlist", "--windows-filenames", "--skip-download", "--no-simulate",
    "--write-info-json", "--no-write-playlist-metafiles", "-f", AUDIO_FORMAT, "-o", M.out_template(dir, false),
    "-o", "infojson:" .. tmpl_lit(info_base), "--print", "%(filename)s",
    "--print", "%(track,vivi_title,title|)s\t%(artist,creator,uploader|)s\t%(album,vivi_album|)s\t%(thumbnail|)s" }
  for _, v in ipairs(meta or {}) do a[#a + 1] = v end
  if jar then a[#a + 1] = "--cookies" a[#a + 1] = jar end
  a[#a + 1] = "--"
  a[#a + 1] = url
  return a
end

-- Step 1's output -> { filename, title, artist, album, thumb, mutagen }.
function M.parse_probe(out, err)
  local lines = {}
  for l in (out or ""):gmatch("[^\r\n]+") do lines[#lines + 1] = l end
  local f = {}
  for v in ((lines[2] or "") .. "\t"):gmatch("([^\t]*)\t") do f[#f + 1] = trim(v) end
  local p = { filename = lines[1], title = f[1] or "", artist = f[2] or "", album = f[3] or "", thumb = f[4] or "" }
  p.mutagen = (err or ""):match("Optional libraries:[^\n]*mutagen") ~= nil
  return p
end

local AUDIO_EXTS = { "m4a", "mp3", "opus", "ogg", "webm", "aac", "flac", "mka", "wav" }

-- An audio file with the name of `filename` (any extension), via exists(path).
function M.existing(filename, exists)
  local stem = filename:gsub("%.[%w]+$", "")
  for _, e in ipairs(AUDIO_EXTS) do
    if exists(stem .. "." .. e) then return stem .. "." .. e end
  end
  return nil
end

-- A file downloaded before is reused when it is in the download folder and has the
-- chosen format (any for Original); otherwise the song is downloaded again.
function M.reuse(path, folder, format)
  if not path or path:sub(1, #folder + 1) ~= folder .. SEP then return false end
  local ext = (path:match("%.(%w+)$") or ""):lower()
  if format == "m4a" or format == "mp3" or format == "opus" then return ext == format end
  return true
end

-- The name with " [<id>]" before the extension (step 1 prints it without).
function M.with_id(filename, id)
  local stem, ext = filename:match("^(.*)(%.[%w]+)$")
  if not stem then stem, ext = filename, "" end
  return stem .. " [" .. id .. "]" .. ext
end

-- yt-dlp download arguments (ffmpeg: "ffmpeg" in PATH, a folder with ffmpeg, or nil =
-- keep the original file, tags only). x: { meta = M.meta_args(), with_id, info = step 1's
-- info JSON (used instead of the URL), covers = folder for the cropped cover
-- (<id>.jpg, kept for the Downloads panel), embed = false when yt-dlp cannot embed the
-- cover (opus without mutagen: M.cover_args does it) }.
function M.download_args(url, dir, format, jar, ffmpeg, pathfile, x)
  x = x or {}
  local a = { "--ignore-config", "--no-playlist", "--newline", "--progress", "--progress-template",
    "download:[vivi] %(progress._percent_str)s|%(info.title)s", "--windows-filenames", "--no-overwrites",
    "-f", AUDIO_FORMAT, "-o", M.out_template(dir, x.with_id) }
  for _, v in ipairs(x.meta or {}) do a[#a + 1] = v end
  if ffmpeg then
    -- "ffmpeg" = the one in PATH: yt-dlp finds it itself (--ffmpeg-location wants a path).
    if ffmpeg ~= "ffmpeg" then a[#a + 1] = "--ffmpeg-location" a[#a + 1] = ffmpeg end
    a[#a + 1] = "-x"
    if format == "m4a" or format == "mp3" or format == "opus" then
      a[#a + 1] = "--audio-format" a[#a + 1] = format
      if format == "mp3" then a[#a + 1] = "--audio-quality" a[#a + 1] = "0" end
    end
    for _, v in ipairs({ "--embed-metadata", "--convert-thumbnails", "jpg", "--ppa", CROP }) do a[#a + 1] = v end
    if x.covers then
      for _, v in ipairs({ "--write-thumbnail", "-o", "thumbnail:" .. tmpl_lit(x.covers) .. SEP .. "%(id)s.%(ext)s" }) do a[#a + 1] = v end
    end
    if x.embed ~= false then a[#a + 1] = "--embed-thumbnail" end
  else
    a[#a + 1] = "--embed-metadata"
  end
  if jar then a[#a + 1] = "--cookies" a[#a + 1] = jar end
  if pathfile then
    for _, v in ipairs({ "--print-to-file", "after_move:filepath", pathfile }) do a[#a + 1] = v end
  end
  if x.info then
    a[#a + 1] = "--load-info-json"
    a[#a + 1] = x.info
  else
    a[#a + 1] = "--"
    a[#a + 1] = url
  end
  return a
end

-- ---------------------------------------------------------------- covers without mutagen
-- yt-dlp embeds covers in opus / ogg only with mutagen; ffmpeg cannot attach a picture
-- to Ogg, but it writes the METADATA_BLOCK_PICTURE comment (a base64 FLAC picture
-- block) from an ffmetadata file. m4a / mp3 get an attached picture stream.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local d1, d2 = math.floor(n / 262144), math.floor(n / 4096) % 64
    local d3, d4 = math.floor(n / 64) % 64, n % 64
    out[#out + 1] = B64:sub(d1 + 1, d1 + 1) .. B64:sub(d2 + 1, d2 + 1)
      .. (b and B64:sub(d3 + 1, d3 + 1) or "=") .. (c and B64:sub(d4 + 1, d4 + 1) or "=")
  end
  return table.concat(out)
end

local function be32(n)
  return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

-- Width and height of a JPEG (its SOF segment), or 0, 0.
function M.jpeg_size(d)
  local i = 3
  while i + 8 <= #d do
    if d:byte(i) ~= 0xFF then return 0, 0 end
    local m = d:byte(i + 1)
    local len = d:byte(i + 2) * 256 + d:byte(i + 3)
    if m >= 0xC0 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
      return d:byte(i + 7) * 256 + d:byte(i + 8), d:byte(i + 5) * 256 + d:byte(i + 6)
    end
    i = i + 2 + len
  end
  return 0, 0
end

-- ffmetadata file text with the cover as METADATA_BLOCK_PICTURE (front cover, JPEG).
function M.picture_meta(jpeg)
  local w, h = M.jpeg_size(jpeg)
  local mime = "image/jpeg"
  local block = be32(3) .. be32(#mime) .. mime .. be32(0) .. be32(w) .. be32(h) .. be32(24) .. be32(0) .. be32(#jpeg) .. jpeg
  return ";FFMETADATA1\nMETADATA_BLOCK_PICTURE=" .. M.base64(block):gsub("=", "\\=") .. "\n"
end

-- ffmpeg arguments that write `path` with the cover to `out` (nil for other formats).
function M.cover_args(ff, path, cover, out, metafile)
  local ext = (path:match("%.(%w+)$") or ""):lower()
  local a = { ff, "-v", "error", "-y", "-i", path }
  if ext == "opus" or ext == "ogg" then
    for _, v in ipairs({ "-f", "ffmetadata", "-i", metafile, "-map", "0:a", "-map_metadata:s:a:0", "0:s:a:0",
      "-map_metadata", "1", "-c", "copy", out }) do a[#a + 1] = v end
  elseif ext == "m4a" or ext == "mp4" or ext == "mp3" then
    for _, v in ipairs({ "-i", cover, "-map", "0:a", "-map", "1", "-c", "copy", "-disposition:v:0", "attached_pic" }) do a[#a + 1] = v end
    if ext == "mp3" then
      for _, v in ipairs({ "-id3v2_version", "3", "-metadata:s:v", "title=Album cover", "-metadata:s:v", "comment=Cover (front)" }) do a[#a + 1] = v end
    end
    a[#a + 1] = out
  else
    return nil
  end
  return a
end

-- Run args with stdout (progress) in a log file. stderr stays a pipe to mpv: mpv stops
-- watching for an abort once every pipe is closed, so with both redirected Cancel left
-- yt-dlp running until the song was done (and quitting waited for Vivi to stop it).
function M.log_wrap(log, args)
  return { "sh", "-c", 'log=$1; shift; exec "$@" >"$log"', "sh", log, unpack(args) }
end

function M.parse_progress(log)
  local line
  for l in log:gmatch("%[vivi%][^\r\n]*") do line = l end
  if not line then return nil end
  local pct, title = line:match("^%[vivi%]%s*([%d%.]+)%%?|(.*)$")
  return tonumber(pct), title
end

-- ---------------------------------------------------------------- playlists
-- "Download playlist": every track of a playlist / album / Liked songs goes into the shared
-- Artist/Album tree (files downloaded before are reused), and a Vivi playlist lists them
-- in YouTube Music's order. Sync downloads new tracks and rewrites the list; tracks
-- removed online drop out of the list, their files stay. The playlist carries
-- `#VIVI-SOURCE:youtube-music <browse id>`: Vivi 0.13+ writes it (vivi-playlist), shows a
-- badge and Sync / Open Source and calls back playlist-sync / playlist-open; on older
-- builds the plugin writes the same file itself. A playlist without that line is the
-- user's and is never overwritten.
local PL_MAX = 5000  -- tracks fetched per playlist (Liked songs can be long)
local PL_PAGES = 100 -- continuation pages

-- The browse id of a playlist / album item, or nil.
function M.source_of(it)
  if not it or is_track(it) or it.kind == "artist" then return nil end
  if (it.browse_id or "") ~= "" and (it.browse_id:sub(1, 2) == "VL" or it.browse_id:sub(1, 4) == "MPRE") then return it.browse_id end
  if (it.playlist_id or "") ~= "" then return "VL" .. it.playlist_id end
  return nil
end

function M.source_url(src)
  if src:sub(1, 2) == "VL" then return ORIGIN .. "/playlist?list=" .. src:sub(3) end
  return ORIGIN .. "/browse/" .. src
end

-- A name safe as a file name (as Vivi's store::playlist_file_name).
function M.safe_name(name)
  local s = trim(name):gsub("[/\\%z%c]", "_")
  s = trim(s):gsub("^%.+", "")
  s = trim(s)
  if s == "" then return "Playlist" end
  -- At most 120 characters (UTF-8 aware).
  local n, cut = 0, #s
  for pos in s:gmatch("()[^\128-\191]") do
    n = n + 1
    if n == 121 then cut = pos - 1 break end
  end
  return s:sub(1, cut)
end

local function one_line(s) return (tostring(s or ""):gsub("[\r\n]", " ")) end

-- The playlist text: entries = { { path, title, duration }, ... } in order.
function M.m3u(name, src, entries)
  local t = { "#EXTM3U", "#PLAYLIST:" .. one_line(name), "#VIVI-SOURCE:" .. ID .. " " .. one_line(src),
    "#VIVI-URL:" .. M.source_url(src) }
  for _, e in ipairs(entries) do
    if (e.path or "") ~= "" then
      if (e.title or "") ~= "" then
        local d = (e.duration or 0) > 0 and math.floor(e.duration + 0.5) or -1
        t[#t + 1] = "#EXTINF:" .. d .. "," .. one_line(e.title)
      end
      t[#t + 1] = one_line(e.path)
    end
  end
  return table.concat(t, "\n") .. "\n"
end

-- plugin id, source id of a playlist's header (nil, nil for the user's own).
function M.parse_source(text)
  for l in (text or ""):gmatch("[^\r\n]*") do
    if l ~= "" and l:sub(1, 1) ~= "#" then break end
    local p, src = l:match("^#VIVI%-SOURCE:%s*(%S+)%s+(%S+)")
    if p then return p, src end
  end
  return nil, nil
end

-- Where playlist `src` goes in dir (as Vivi's store::owned_playlist_path): the file that
-- already has its source line (also renamed), else <name>.m3u, else <name> (YouTube
-- Music).m3u, <name> (YouTube Music 2).m3u, ... files = the .m3u names in dir, read(path).
function M.pick_path(dir, name, src, files, read)
  local have = {}
  table.sort(files)
  for _, f in ipairs(files) do
    have[f] = true
    local p, s = M.parse_source(read(dir .. SEP .. f) or "")
    if p == ID and s == src then return dir .. SEP .. f end
  end
  local base = M.safe_name(name)
  for i = 0, 999 do
    local n = i == 0 and base or (i == 1 and (base .. " (" .. NAME .. ")") or (base .. " (" .. NAME .. " " .. i .. ")"))
    if not have[n .. ".m3u"] then return dir .. SEP .. n .. ".m3u" end
  end
  return dir .. SEP .. base .. " (" .. NAME .. " " .. src .. ").m3u"
end

-- A name for a list whose page has no header (an album's OLAK playlist opened as a
-- playlist): the album all its tracks share, else "YouTube Music playlist".
function M.list_name(tracks)
  local album
  for _, it in ipairs(tracks) do
    if (it.album or "") == "" or (album and it.album ~= album) then album = nil break end
    album = it.album
  end
  return album or (NAME .. " playlist")
end

-- Split a playlist's tracks (YouTube Music order) into the ones on disk and the ones to
-- download: { order = tracks without repeats, have = { id = path }, todo = { it, ... } }.
-- local_file(it) = the downloaded file or nil.
function M.plan(tracks, local_file)
  local r, seen = { order = {}, have = {}, todo = {} }, {}
  for _, it in ipairs(tracks) do
    if is_track(it) and (it.video_id or "") ~= "" and not seen[it.video_id] then
      seen[it.video_id] = true
      r.order[#r.order + 1] = it
      local f = local_file(it)
      if f then r.have[it.video_id] = f else r.todo[#r.todo + 1] = it end
    end
  end
  return r
end

-- The playlist entries: tracks in order that have a file (paths = { id = path }).
function M.entries(order, paths)
  local out = {}
  for _, it in ipairs(order) do
    local p = paths[it.video_id]
    if p then
      local title = (it.artist or "") ~= "" and (it.artist .. " - " .. it.title) or it.title
      out[#out + 1] = { path = p, title = title or "", duration = it.duration or 0 }
    end
  end
  return out
end

-- ---------------------------------------------------------------- state
local S = {
  cookies = nil, loaded = false, account = "", signing_in = false,
  view = { kind = "search", q = "", filter = 1 }, back = {},
  items = {}, cont = nil, cont_ep = "browse", sel = nil, busy = false, gen = 0,
  title = "", sub = "", page_playlist = "", my_playlists = nil, liked = {},
  dl_queue = {}, dl_job = nil, dl_pct = nil, dl_title = "", dl_timer = nil, dl_log = nil,
  open = false,
}

local function mkdir_p(dir)
  if utils.file_info(dir) then return end
  if windows then
    mp.command_native({ name = "subprocess", args = { "cmd", "/c", "mkdir", dir }, playback_only = false })
  else
    mp.command_native({ name = "subprocess", args = { "mkdir", "-p", "-m", "700", dir }, playback_only = false })
  end
end

local function private_dir()
  mkdir_p(DATA)
  mp.commandv("script-message", "vivi-protect", ID, DATA)
end

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_private(p, s)
  private_dir()
  local f = io.open(p, "wb")
  if not f then return false end
  f:write(s)
  f:close()
  mp.commandv("script-message", "vivi-protect", ID, p)
  return true
end

local function load_cookies()
  if S.loaded then return end
  S.loaded = true
  local s = read_file(JAR)
  if s then
    local v = M.youtube_only(M.parse_netscape(s))
    if #v > 0 and M.sapisid(v) then
      S.cookies = v
      -- Jars written before unix_expiry had "1.3e+16" expiries: rewrite them once.
      if s:find("%de%+%d") then write_private(JAR, M.to_netscape(v)) end
    end
  end
  S.account = trim(read_file(ACCOUNT) or "")
end

-- yt-dlp saves its --cookies file back when it exits: YouTube's Set-Cookie (or two runs at
-- once) left cookies.txt without the sign-in cookies, and the next start was signed out.
-- yt-dlp and mpv get a copy, rewritten from memory for every call; cookies.txt stays ours.
local function ytdlp_jar()
  load_cookies()
  if not S.cookies then return nil end
  if write_private(RUN_JAR, M.to_netscape(S.cookies)) then return RUN_JAR end
  return nil
end

local function signed_in()
  load_cookies()
  return S.cookies ~= nil or FIXTURES ~= nil
end

-- Google rotates the session cookies the browser holds: a copy imported from the browser
-- stops working after a while (here ~30 min) and YouTube Music answers as signed out.
-- refresh_session reads the browser again, silently, and keeps the old jar on failure.
local refresh_session -- defined with sign_in_browser
local STALE_AFTER = 20 * 60
function M.jar_stale(mtime, now, browser)
  return browser ~= nil and browser ~= "" and mtime ~= nil and now - mtime > STALE_AFTER
end

-- ---------------------------------------------------------------- HTTP (curl)
local function today()
  return os.date("!%Y%m%d")
end

local function fixture(name)
  if not FIXTURES then return nil end
  local s = read_file(FIXTURES .. SEP .. name:gsub("[/?&=]", "_") .. ".json")
  if not s then return { err = "no fixture " .. name } end
  return { json = utils.parse_json(s) }
end

local function curl_quote(s) return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"' end

-- POST an InnerTube endpoint; cb(json) or cb(nil, why).
local function post(ep, body, query, cb, fixture_name)
  local fx = fixture(fixture_name or ep)
  if fx then
    mp.add_timeout(0.05, function() cb(fx.json, fx.err) end)
    return
  end
  body.context = { client = { clientName = "WEB_REMIX", clientVersion = "1." .. today() .. ".01.00", hl = "en" } }
  local url = API .. ep .. "?alt=json&prettyPrint=false"
  for _, kv in ipairs(query or {}) do url = url .. "&" .. kv[1] .. "=" .. kv[2] end
  local headers = { "Content-Type: application/json", "Origin: " .. ORIGIN, "X-Origin: " .. ORIGIN,
    "Referer: " .. ORIGIN .. "/", "User-Agent: " .. UA }
  load_cookies()
  if S.cookies then
    local sid = M.sapisid(S.cookies)
    if sid then headers[#headers + 1] = "Authorization: " .. M.sapisid_hash(sid, os.time()) end
    headers[#headers + 1] = "Cookie: " .. M.cookie_header(S.cookies, "music.youtube.com")
    headers[#headers + 1] = "X-Goog-AuthUser: 0"
  end
  -- Headers in a private config file: never on the command line (ps shows it).
  local cfg = {}
  for _, h in ipairs(headers) do cfg[#cfg + 1] = "header = " .. curl_quote(h) end
  local cf = DATA .. SEP .. "request-" .. tostring(math.random(1e9)) .. ".curl"
  if not write_private(cf, table.concat(cfg, "\n") .. "\n") then return cb(nil, "Cannot write to " .. DATA) end
  mp.command_native_async({
    name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
    stdin_data = utils.format_json(body),
    args = { "curl", "-sS", "--compressed", "-m", "30", "-K", cf, "--data-binary", "@-", "-w", "\n%{http_code}", url },
  }, function(_, r)
    os.remove(cf)
    r = r or {}
    local out = r.stdout or ""
    local bodytext, code = out:match("^(.*)\n(%d%d%d)$")
    code = tonumber(code)
    if r.status ~= 0 or not code then
      return cb(nil, "YouTube Music: network error (" .. trim((r.stderr or ""):sub(1, 120)) .. ")")
    end
    if code == 401 or code == 403 then
      return cb(nil, "YouTube Music refused the sign-in (expired cookies?). Sign in again in the plugin settings")
    end
    if code == 429 then return cb(nil, "YouTube Music: too many requests, try again in a minute") end
    local j = utils.parse_json(bodytext or "")
    if code < 200 or code > 299 then
      return cb(nil, trim("YouTube Music error " .. code .. " " .. str(get(j, "error", "message"))))
    end
    if not j then return cb(nil, "YouTube Music: unreadable answer") end
    cb(j)
  end)
end

local function search_req(qtext, f, cb)
  local fl = FILTERS[f] or FILTERS[1]
  local body = { query = qtext }
  if fl[2] ~= "" then body.params = fl[2] end
  post("search", body, nil, function(v, err)
    if not v then return cb(nil, err) end
    local items = M.collect(v)
    if fl[3] then
      local keep = {}
      for _, it in ipairs(items) do if it.kind == fl[3] then keep[#keep + 1] = it end end
      items = keep
    end
    cb({ items = items, cont = M.continuation(v) })
  end, "search_" .. fl[1]:lower())
end

local function browse_req(id, cb, retried)
  post("browse", { browseId = id }, nil, function(v, err)
    if not v then return cb(nil, err) end
    if (id:sub(1, 2) == "FE" or id == "VLLM") and M.needs_sign_in(v) then
      if not retried and S.cookies and refresh_session then
        return refresh_session(function(ok)
          if ok then return browse_req(id, cb, true) end
          cb(nil, "YouTube Music signed you out: sign in again in Settings → Extensions → YouTube Music")
        end)
      end
      return cb(nil, "Sign in first: Settings → Extensions → YouTube Music")
    end
    cb(M.parse_page(v, id))
  end, "browse_" .. id)
end

local function more_req(ep, c, cb)
  local body, query = {}, nil
  if c.body then body.continuation = c.body else query = { { "ctoken", c.query }, { "continuation", c.query }, { "type", "next" } } end
  post(ep, body, query, function(v, err)
    if not v then return cb(nil, err) end
    cb({ items = M.collect(v), cont = M.continuation(v) })
  end, ep .. "_more")
end

local function watch_req(video_id, cb)
  post("next", { enablePersistentPlaylistPanel = true, isAudioOnly = true, tunerSettingValue = "AUTOMIX_SETTING_NORMAL",
    videoId = video_id, playlistId = "RDAMVM" .. video_id, params = "wAEB" }, nil, function(v, err)
    if not v then return cb(nil, err) end
    cb(M.collect(v))
  end, "next")
end

-- ---------------------------------------------------------------- dialog
local function send_dialog(t)
  mp.commandv("script-message", "vivi-dialog", ID, utils.format_json(t))
end

local function selected()
  return S.sel and S.items[S.sel] or nil
end

local function status_text()
  local parts = {}
  if S.busy then parts[#parts + 1] = "Loading…" end
  if S.dl_job then
    parts[#parts + 1] = string.format("Downloading %s%s%s", S.dl_title,
      S.dl_pct and string.format(" · %.0f%%", S.dl_pct) or "", #S.dl_queue > 0 and (" (+" .. #S.dl_queue .. " queued)") or "")
  end
  if not S.busy then
    if S.empty then parts[#parts + 1] = S.empty end
    if signed_in() then
      parts[#parts + 1] = FIXTURES and "Mock data (fixtures), not a real account" or
        ("Signed in" .. (S.account ~= "" and (" as " .. S.account) or ""))
    else
      parts[#parts + 1] = "Not signed in: search works; sign in for your library (Settings → Extensions → YouTube Music)"
    end
  end
  return table.concat(parts, " · ")
end

local function detail_text(it)
  if not it then
    if S.view.kind == "page" and S.title ~= "" then return S.title .. "\n" .. S.sub end
    return ""
  end
  local d = { it.title, "" }
  local function add(k, v) if v and v ~= "" then d[#d + 1] = k .. ": " .. v end end
  add("Type", KIND_LABEL[it.kind])
  add(it.kind == "artist" and "Audience" or "Artist", it.kind == "artist" and it.extra or it.artist)
  add("Album", it.album)
  add("Length", clock(it.duration))
  if it.kind ~= "artist" then add("Info", it.extra) end
  d[#d + 1] = ""
  d[#d + 1] = M.page_url(it)
  return table.concat(d, "\n")
end

local pl_action -- "Download playlist" / "Sync playlist" / nil for the page or chosen item

local function actions()
  local a = {}
  if #S.back > 0 then a[#a + 1] = "‹ Back" end
  local it = selected()
  if S.view.kind == "page" or (S.view.kind == "lib" and S.view.i == 1) then
    a[#a + 1] = "Play all" a[#a + 1] = "Shuffle"
  end
  if it and is_track(it) then
    a[#a + 1] = "Start mix"
    if it.album_id ~= "" then a[#a + 1] = "Album" end
    if it.artist_id ~= "" then a[#a + 1] = "Artist" end
    if signed_in() then a[#a + 1] = S.liked[it.video_id] and "Unlike" or "Like" end
  elseif it then
    a[#a + 1] = "Play all" a[#a + 1] = "Queue"
  end
  local pa = o.downloads and pl_action()
  if pa then a[#a + 1] = pa end
  if S.dl_job then a[#a + 1] = "Cancel download" end
  return a
end

local function filters()
  local it = selected()
  if not (it and is_track(it) and S.my_playlists and #S.my_playlists > 0) then return {} end
  local names = {}
  for _, p in ipairs(S.my_playlists) do names[#names + 1] = p.title end
  -- The dropdown shows `value`: an empty one looked like a broken bar.
  return { { name = "Add to playlist", options = names, value = "Add to playlist…" } }
end

local function title_text()
  if S.view.kind == "lib" then return NAME .. " · " .. LIBRARY[S.view.i][1] end
  if S.view.kind == "page" then return NAME .. " · " .. (S.title ~= "" and S.title or S.view.title or "") end
  return NAME
end

-- Video ids with a downloaded file that still exists (downloads.tsv), for the check
-- mark on tiles / rows; S.saved = nil after a download recomputes it.
local function saved_ids()
  if S.saved then return S.saved end
  local t = {}
  for line in (read_file(INDEX) or ""):gmatch("[^\n]+") do
    local id, path = line:match("^([^\t]+)\t(.+)$")
    if id and not t[id] and utils.file_info(path) then t[id] = true end
  end
  S.saved = t
  return t
end

-- The big cover of the detail pane: the largest thumbnail, square ones at 544 px.
function M.detail_cover(it)
  if not it then return "" end
  local u = it.thumb_full ~= "" and it.thumb_full or it.thumb or ""
  return resize(u, 544)
end

local function show(extra)
  local rows = {}
  local saved = saved_ids()
  for i, it in ipairs(S.items) do
    rows[i] = { title = it.title, sub = M.sub(it), badge = KIND_LABEL[it.kind] or "", dur = clock(it.duration),
      chip = (is_track(it) and S.liked[it.video_id]) and "♥ Liked" or "", cover = it.thumb,
      dl = o.downloads and is_track(it), saved = (is_track(it) and saved[it.video_id]) or false,
      selected = (i == S.sel) }
  end
  local it = selected()
  local t = { title = title_text(), rows = rows, status = status_text(), busy = S.busy, detail = detail_text(it),
    detail_cover = M.detail_cover(it),
    has_more = (S.cont ~= nil and not S.busy and #S.items > 0), actions = actions(), filters = filters(),
    primary = (it and not is_track(it)) and "Open" or "Play",
    secondary = (it and is_track(it)) and (o.downloads and "Download" or "Add to queue") or "",
    chip = S.view.kind == "lib" and LIBRARY[S.view.i][1] or "" }
  for k, v in pairs(extra or {}) do t[k] = v end
  send_dialog(t)
end

local function fail(err)
  S.busy = false
  show({ status = err })
  toast(err, 6)
end

local function load_view(v)
  S.gen = S.gen + 1
  local gen = S.gen
  S.view, S.items, S.cont, S.sel, S.busy, S.title, S.sub, S.page_playlist = v, {}, nil, nil, true, "", "", ""
  S.empty = nil
  show({ rows = {} })
  local function done(r, err)
    if gen ~= S.gen then return end
    if not r then return fail(err) end
    S.busy = false
    S.items, S.cont = r.items, r.cont
    S.title, S.sub, S.page_playlist = r.title or "", r.sub or "", r.playlist_id or ""
    -- An empty grid alone looks like a failed load (e.g. no saved albums).
    if #r.items == 0 then
      S.empty = v.kind == "lib" and ("Nothing in " .. LIBRARY[v.i][1] .. " yet") or
        (v.kind == "search" and "No results" or "Nothing here")
    end
    if v.kind == "lib" and v.i == 1 then
      for _, it in ipairs(r.items) do S.liked[it.video_id] = true end
    end
    show()
  end
  if v.kind == "search" then
    if trim(v.q) == "" then S.busy = false return show({ status = "Type a search, or pick a library chip" }) end
    S.cont_ep = "search"
    search_req(v.q, v.filter, done)
  else
    S.cont_ep = "browse"
    browse_req(v.kind == "lib" and LIBRARY[v.i][2] or v.id, done)
  end
end

local function go(v)
  S.back[#S.back + 1] = S.view
  load_view(v)
end

local function more()
  if not S.cont or S.busy then return end
  local gen, c = S.gen, S.cont
  S.busy = true
  show()
  more_req(S.cont_ep, c, function(r, err)
    if gen ~= S.gen then return end
    S.busy = false
    if not r then return fail(err) end
    local seen = {}
    for _, it in ipairs(S.items) do seen[M.key(it)] = true end
    for _, it in ipairs(r.items) do
      if not seen[M.key(it)] then S.items[#S.items + 1] = it end
    end
    S.cont = r.cont
    show()
  end)
end

local function fetch_my_playlists()
  if S.my_playlists or not signed_in() then return end
  S.my_playlists = {}
  browse_req("FEmusic_liked_playlists", function(p)
    if not p then return end
    local mine = {}
    for _, it in ipairs(p.items) do
      if it.playlist_id ~= "LM" and it.browse_id ~= "VLLM" and (it.browse_id:sub(1, 2) == "VL" or it.playlist_id ~= "") then
        mine[#mine + 1] = it
      end
    end
    S.my_playlists = mine
    if S.open then show() end
  end)
end

-- Vivi builds with the package host API (vivi-dialog, vivi-confirm, vivi-media-meta) also
-- set user-data/vivi/downloads (and, later ones, /playlists). Vivi 0.12.0 and older set
-- neither and ignore vivi-dialog, so the dialog would silently never show.
function M.host_api(downloads, playlists) return downloads ~= nil or playlists ~= nil end
local function host_api()
  return M.host_api(mp.get_property_native("user-data/vivi/downloads"), mp.get_property_native("user-data/vivi/playlists"))
end
M.OLD_HOST = "YouTube Music needs a newer Vivi: 0.13, or a 0.12 build from master of 18 Oct 2026 or later (its music dialog for plugins)."

-- want: the view to show (the "liked" command); else the last one.
local function open(want)
  if type(want) ~= "table" then want = nil end -- "open" script-message arguments
  if not host_api() then
    mp.msg.warn(M.OLD_HOST)
    return mp.commandv("script-message", "vivi-toast", M.OLD_HOST, "6")
  end
  S.open = true
  S.saved = nil -- files may have been deleted since
  load_cookies()
  local v = want or S.view
  if v.kind == "page" then v = { kind = "lib", i = 1 } end
  if v.kind == "search" and trim(v.q) == "" and signed_in() then v = { kind = "lib", i = 1 } end
  local srcs = {}
  for i, f in ipairs(FILTERS) do srcs[i] = f[1] end
  local chips = {}
  for i, l in ipairs(LIBRARY) do chips[i] = l[1] end
  send_dialog({ open = true, title = NAME, placeholder = "Search YouTube Music: songs, albums, artists, playlists…",
    search_label = "Search", sources = srcs, source = FILTERS[v.filter or 1][1], chips = chips,
    grid_toggle = true, grid = (o.view == "Grid"), query = v.q or "", rows = {}, status = status_text() })
  S.back = {}
  local fi = S.cookies and not S.refresh_failed and utils.file_info(JAR)
  if fi and M.jar_stale(fi.mtime, os.time(), o.browser) then
    S.busy, S.view = true, v
    send_dialog({ status = "Refreshing the YouTube Music sign-in from " .. o.browser .. "…" })
    return refresh_session(function()
      S.busy = false
      if not S.open then return end
      fetch_my_playlists()
      load_view(S.view) -- or the chip picked meanwhile
    end)
  end
  fetch_my_playlists()
  load_view(v)
end

-- ---------------------------------------------------------------- playback
local function loadfile(url, mode, opts)
  if M.mpv_at_least(mp.get_property("mpv-version", ""), 38) then
    mp.command_native({ "loadfile", url, mode, -1, opts })
  else
    mp.command_native({ "loadfile", url, mode, opts })
  end
end

local function describe(list)
  local items = {}
  for _, it in ipairs(list) do
    items[#items + 1] = { url = M.url(it), title = it.title, artist = it.artist, album = it.album,
      cover = it.thumb_full ~= "" and it.thumb_full or it.thumb, info = NAME }
  end
  if #items > 0 then mp.commandv("script-message", "vivi-media-meta", ID, utils.format_json({ items = items })) end
end

local function ytdlp_ok()
  for _, d in ipairs({ "yt-dlp", "yt-dlp.exe" }) do
    local r = mp.command_native({ name = "subprocess", args = { d, "--version" }, playback_only = false, capture_stdout = true, capture_stderr = true })
    if r and r.status == 0 then return d end
  end
  return nil
end

local NO_YTDLP = "Playing YouTube Music needs yt-dlp: install it, or the YouTube & yt-dlp plugin (it downloads a managed copy)"

-- Queue tracks: replace = start with the first one.
local function queue(list, replace, note)
  if #list == 0 then return end
  if not ytdlp_ok() then return toast(NO_YTDLP, 8) end
  load_cookies()
  local jar = ytdlp_jar()
  describe(list)
  for i, it in ipairs(list) do
    if i > PLAY_MAX then break end
    local mode = (replace and i == 1) and "replace" or "append-play"
    local title = it.artist ~= "" and (it.artist .. " — " .. it.title) or it.title
    loadfile(M.url(it), mode, M.file_options(title, o["audio-only"], jar))
  end
  if note then toast(note) end
end

local function radio(it, play)
  watch_req(it.video_id, function(list, err)
    if not list then return toast(err, 6) end
    local out = {}
    if play then out[1] = it end
    for _, x in ipairs(list) do
      if x.video_id ~= it.video_id and is_track(x) and #out < RADIO + 1 then out[#out + 1] = x end
    end
    queue(out, play, string.format("Mix of “%s”: %d tracks queued", it.title, #out - (play and 1 or 0)))
  end)
end

local function tracks_of_view()
  local t = {}
  for _, it in ipairs(S.items) do if is_track(it) then t[#t + 1] = it end end
  return t
end

-- Every track of an album / playlist page (all continuations), then cb(list).
local function container_tracks(it, cb)
  local id = it.browse_id ~= "" and it.browse_id or ("VL" .. it.playlist_id)
  browse_req(id, function(p, err)
    if not p then return toast(err, 6) end
    local list = {}
    for _, x in ipairs(p.items) do if is_track(x) then list[#list + 1] = x end end
    local function step(c, n)
      if not c or #list >= PLAY_MAX or n > 20 then return cb(list) end
      more_req("browse", c, function(r)
        if not r then return cb(list) end
        for _, x in ipairs(r.items) do if is_track(x) then list[#list + 1] = x end end
        step(r.cont, n + 1)
      end)
    end
    step(p.cont, 1)
  end)
end

local function shuffle(t)
  for i = #t, 2, -1 do
    local j = math.random(i)
    t[i], t[j] = t[j], t[i]
  end
  return t
end

local function play(it)
  if not is_track(it) then
    local v = { kind = "page", id = it.browse_id ~= "" and it.browse_id or ("VL" .. it.playlist_id), title = it.title }
    if it.kind == "artist" then v.id = it.browse_id end
    return go(v)
  end
  if S.view.kind == "search" then
    queue({ it }, true)
    if o["up-next"] then radio(it, false) end
    return
  end
  -- From a list: this track, then the rest of the list.
  local list, after = {}, false
  for _, x in ipairs(tracks_of_view()) do
    if x == it then after = true end
    if after then list[#list + 1] = x end
  end
  queue(list, true, #list > 1 and string.format("%d more queued from this list", #list - 1) or nil)
end

local function play_all(shuffled)
  local it = selected()
  if it and not is_track(it) and S.view.kind ~= "page" then
    return container_tracks(it, function(list)
      if shuffled then shuffle(list) end
      queue(list, true, string.format("%d tracks of “%s”", #list, it.title))
    end)
  end
  local list = tracks_of_view()
  if shuffled then shuffle(list) end
  queue(list, true, string.format("%d tracks queued", #list))
end

-- ---------------------------------------------------------------- account actions
local function rate(it, like)
  if FIXTURES then S.liked[it.video_id] = like or nil return show() end
  post(like and "like/like" or "like/removelike", { target = { videoId = it.video_id } }, nil, function(v, err)
    if not v then return toast(err, 6) end
    S.liked[it.video_id] = like or nil
    toast((like and "Liked “" or "Removed the like from “") .. it.title .. "”")
    if S.open then show() end
  end)
end

local function add_to(name)
  local it = selected()
  if not (it and is_track(it) and S.my_playlists) then return end
  for _, p in ipairs(S.my_playlists) do
    if p.title == name then
      local pid = p.playlist_id ~= "" and p.playlist_id or p.browse_id:gsub("^VL", "")
      if FIXTURES then return toast("Added “" .. it.title .. "” to " .. name .. " (mock)") end
      return post("browse/edit_playlist", { playlistId = pid, actions = { { action = "ACTION_ADD_VIDEO",
        addedVideoId = it.video_id, dedupeOption = "DEDUPE_OPTION_SKIP" } } }, nil, function(v, err)
        if not v then return toast(err, 6) end
        local st = str(v.status)
        if st ~= "" and st ~= "STATUS_SUCCEEDED" then return toast("YouTube Music: " .. st, 6) end
        toast("Added “" .. it.title .. "” to " .. name)
      end)
    end
  end
end

-- ---------------------------------------------------------------- sign-in
-- yt-dlp only loads the browser's cookies and writes the jar: the input is not a URL it
-- can fetch (no network; it fails right after the cookies are loaded, which is expected),
-- so the jar is checked for a signed-in SAPISID instead of the exit code.
-- keyring: yt-dlp's BROWSER+KEYRING (gnomekeyring, kwallet6, ...) or nil = its own guess.
function M.browser_args(y, browser, jar, keyring)
  local spec = (browser or ""):lower()
  if keyring and keyring ~= "" then spec = spec .. "+" .. keyring end
  return { y, "--ignore-config", "--simulate", "--no-progress", "--cookies-from-browser", spec,
    "--cookies", jar, "ytsearch0:vivi" }
end

-- Chromium-based browsers encrypt cookies (v11) with a password in the desktop keyring.
-- yt-dlp picks the keyring from the desktop: on Hyprland, Sway, i3, ... it guesses "basic
-- text" and finds no key ("cannot decrypt v11 cookies: no key found"), although Chrome
-- keeps it in the Secret Service (gnome-keyring, KeePassXC) or KWallet. So name the
-- keyring that is running. desktop = XDG_CURRENT_DESKTOP; names = D-Bus session names.
local KEYRING_DESKTOPS = { kde = 1, gnome = 1, unity = 1, xfce = 1, cinnamon = 1, pantheon = 1, lxqt = 1, deepin = 1 }
function M.keyring_hint(browser, desktop, names)
  local b = (browser or ""):lower()
  if b == "firefox" or b == "safari" or b == "" then return nil end
  for d in (desktop or ""):lower():gmatch("[^:]+") do
    if KEYRING_DESKTOPS[d] then return nil end -- yt-dlp knows these
  end
  names = names or {}
  if names["org.kde.kwalletd6"] then return "kwallet6" end
  if names["org.kde.kwalletd5"] then return "kwallet5" end
  if names["org.freedesktop.secrets"] then return "gnomekeyring" end
  return nil
end

-- Reads the cookies with yt-dlp's own code, but takes the browser's "<Name> Safe
-- Storage" password from the Secret Service with secret-tool (libsecret) instead of
-- Python's secretstorage, which distributions often leave out ("secretstorage not
-- available": then only the cookies Chrome wrote before the keyring was up decrypt, and
-- the sign-in ones do not). The password and cookies never reach stdout / stderr; the jar
-- is written with mode 0600. argv: browser, jar path.
M.KEYRING_HELPER = [==[
import os, subprocess, sys
import yt_dlp.cookies as c
browser, out = sys.argv[1], sys.argv[2]

def secret(name):
    label = name + " Safe Storage"
    for schema in ("chrome_libsecret_os_crypt_password_v2", "chrome_libsecret_os_crypt_password_v1"):
        try:
            r = subprocess.run(["secret-tool", "search", "--all", "--unlock", "xdg:schema", schema],
                               capture_output=True, text=True, timeout=120)
        except Exception:
            continue
        blocks, cur = [], {}
        for line in r.stdout.splitlines():
            if line.startswith("["):
                cur = {}
                blocks.append(cur)
            elif " = " in line:
                k, v = line.split(" = ", 1)
                cur[k] = v
        for b in blocks:
            if b.get("label") == label and "secret" in b:
                return b["secret"].encode()
    print("ERROR: no '%s' password in the keyring (open %s once, then try again)" % (label, name), file=sys.stderr)
    return b""

class Log(c.YDLLogger):
    def __init__(self):
        super().__init__(None)
    def debug(self, message, *a, **k):
        pass
    def info(self, message, *a, **k):
        print(message, file=sys.stderr)
    def warning(self, message, *a, **k):
        print("WARNING: " + message, file=sys.stderr)
    def error(self, message, *a, **k):
        print("ERROR: " + message, file=sys.stderr)

c._get_gnome_keyring_password = lambda name, logger: secret(name)
jar = c.extract_cookies_from_browser(browser, logger=Log(), keyring="GNOMEKEYRING")
os.umask(0o077)
jar.save(out, ignore_discard=True, ignore_expires=True)
]==]

-- Why reading the browser's cookies did not give a signed-in jar (stderr of yt-dlp;
-- it never contains cookie values).
function M.browser_error(browser, stderr, err)
  local lines = {}
  for l in (stderr or ""):gmatch("[^\r\n]+") do
    if (l:find("^ERROR:") or l:find("^WARNING:")) and not l:find("Unsupported url scheme", 1, true)
      and not l:find("ytsearch0", 1, true) then
      lines[#lines + 1] = trim(l:gsub("^%u+:%s*", ""))
    end
  end
  local n = (stderr or ""):match("Extracted (%d+) cookies")
  local why
  if #lines > 0 then why = lines[1]
    if why:find("no key found", 1, true) or why:find("secretstorage not available", 1, true) then
      why = why .. ". The browser keeps the key in the desktop keyring: install libsecret (secret-tool) and python-secretstorage, or use Paste / Import with a cookies.txt"
    end
  elseif n then why = "found " .. n .. " cookies but none signed in to youtube.com: sign in at music.youtube.com in " .. browser .. " first"
  else why = err and err ~= "" and err or "yt-dlp read no cookies" end
  return "Could not read the " .. browser .. " cookies: " .. why
end
local function verify(cookies, how, quiet)
  local old = S.cookies
  S.cookies, S.loaded = cookies, true
  S.signing_in = true
  post("account/account_menu", {}, nil, function(v, err)
    S.signing_in = false
    local name = v and M.account_name(v)
    if quiet then
      -- Same account only; on any failure keep the stored jar (the user signs in again).
      if not name or (S.account ~= "" and name ~= S.account) then S.cookies = old return quiet(false) end
      write_private(JAR, M.to_netscape(cookies))
      S.account = name
      mp.msg.info("YouTube Music: sign-in refreshed from " .. how)
      return quiet(true)
    end
    if not name then
      S.cookies = nil
      mp.commandv("script-message", "vivi-wipe", ID, JAR)
      return signin_result(false, err or "YouTube Music did not accept these cookies (not signed in). Sign in at music.youtube.com and try again")
    end
    if not write_private(JAR, M.to_netscape(cookies)) then return signin_result(false, "Cannot write " .. JAR) end
    S.account, S.my_playlists, S.liked = name, nil, {}
    write_private(ACCOUNT, name)
    signin_result(true, "Signed in to YouTube Music as " .. name .. " (" .. how .. ")")
    if S.open then open() end
  end, "account")
end

local function import_text(s, how)
  local v, err = M.parse_any(s or "")
  if not v then return signin_result(false, err .. " (" .. how .. ")") end
  toast("Checking the cookies with YouTube Music…")
  verify(v, how)
end

-- D-Bus session bus names (to see which keyring runs); {} when busctl is missing.
local function bus_names()
  local r = mp.command_native({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
    args = { "busctl", "--user", "--no-pager", "--no-legend", "list" } })
  local t = {}
  for n in ((r and r.status == 0 and r.stdout) or ""):gmatch("([%w%._%-]+)[^\n]*") do t[n] = true end
  return t
end

-- The helper needs python3 with the yt_dlp module (a distribution / pip yt-dlp, not the
-- single-file binary) and secret-tool.
local function helper_ok()
  if windows then return false end
  local r = mp.command_native({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
    args = { "sh", "-c", "command -v secret-tool >/dev/null && python3 -c 'import yt_dlp.cookies'" } })
  return r and r.status == 0
end

local function sign_in_browser(quiet)
  if type(quiet) ~= "function" then quiet = nil end
  local function fail(msg) if quiet then mp.msg.warn(msg) return quiet(false) end signin_result(false, msg) end
  local function say(msg) if not quiet then toast(msg) end end
  local y = ytdlp_ok()
  if not y then return fail("Reading browser cookies needs yt-dlp (install it or the YouTube & yt-dlp plugin)") end
  private_dir()
  local tmp = DATA .. SEP .. "import.txt"
  say("Reading the " .. o.browser .. " cookies…")
  os.remove(tmp)
  local keyring = (not windows) and M.keyring_hint(o.browser, os.getenv("XDG_CURRENT_DESKTOP"), bus_names()) or nil
  local function take(r)
    local s = read_file(tmp)
    if s then mp.commandv("script-message", "vivi-wipe", ID, tmp) os.remove(tmp) end
    local v = s and M.parse_any(s)
    return v, (r and r.stderr) or "", r and r.error_string
  end
  local function cli(first_err)
    os.remove(tmp)
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
      args = M.browser_args(y, o.browser, tmp, keyring) }, function(_, r)
      local v, err, es = take(r)
      if not v then
        return fail(M.browser_error(o.browser, (first_err and (first_err .. "\n") or "") .. err, es))
      end
      say("Checking the cookies with YouTube Music…")
      verify(v, o.browser, quiet)
    end)
  end
  -- Secret Service on a desktop yt-dlp does not know: read the key with secret-tool.
  if keyring == "gnomekeyring" and helper_ok() then
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
      args = { "python3", "-c", M.KEYRING_HELPER, o.browser:lower(), tmp } }, function(_, r)
      local v, err = take(r)
      if v then
        say("Checking the cookies with YouTube Music…")
        return verify(v, o.browser .. ", keyring", quiet)
      end
      -- Not there (another keyring, no password yet): yt-dlp on its own.
      cli(err:match("ERROR: [^\n]+"))
    end)
    return
  end
  cli()
end

-- One browser read at a time; callers that arrive meanwhile wait for it.
local refresh_waiters
refresh_session = function(done)
  if FIXTURES or not S.cookies or (o.browser or "") == "" then return done(false) end
  if refresh_waiters then refresh_waiters[#refresh_waiters + 1] = done return end
  refresh_waiters = { done }
  sign_in_browser(function(ok)
    local w = refresh_waiters
    refresh_waiters = nil
    S.refresh_failed = not ok or nil
    for _, f in ipairs(w) do f(ok) end
  end)
end

local function sign_out()
  mp.commandv("script-message", "vivi-wipe", ID, JAR)
  mp.commandv("script-message", "vivi-wipe", ID, RUN_JAR)
  os.remove(JAR)
  os.remove(RUN_JAR)
  S.cookies, S.loaded, S.account, S.my_playlists, S.liked = nil, true, "", nil, {}
  os.remove(ACCOUNT)
  toast("Signed out of YouTube Music: the stored cookies are deleted (your browser stays signed in)", 6)
  if S.open then open() end
end

-- Clipboard text: mpv's clipboard property (0.39+, not on every platform / compositor),
-- else wl-paste, xclip, xsel, pbpaste or PowerShell.
function M.clipboard()
  local s = mp.get_property("clipboard/text", "")
  if s and trim(s) ~= "" then return s end
  local tries = { { "powershell", "-NoProfile", "-Command", "Get-Clipboard -Raw" } }
  if not windows then
    tries = { { "xclip", "-o", "-selection", "clipboard" }, { "xsel", "-ob" }, { "pbpaste" } }
    if os.getenv("WAYLAND_DISPLAY") then table.insert(tries, 1, { "wl-paste", "--no-newline" }) end
  end
  for _, a in ipairs(tries) do
    local r = mp.command_native({ name = "subprocess", args = a, playback_only = false, capture_stdout = true, capture_stderr = true })
    if r and r.status == 0 and trim(r.stdout or "") ~= "" then return r.stdout end
  end
  return nil
end

-- ---------------------------------------------------------------- downloads
local function ffmpeg_dir()
  local r = mp.command_native({ name = "subprocess", args = { "ffmpeg", "-version" }, playback_only = false, capture_stdout = true })
  if r and r.status == 0 then return "ffmpeg" end
  local own = DATA_HOME .. SEP .. "vivi" .. SEP .. "plugin-data" .. SEP .. "youtube" .. SEP .. "ffmpeg"
  if utils.file_info(own) then return own end
  return nil
end

local function ffmpeg_bin(dir)
  if dir == "ffmpeg" then return "ffmpeg" end
  return dir .. SEP .. "ffmpeg" .. (windows and ".exe" or "")
end

local COVERS = DATA .. SEP .. "covers"     -- <video id>.jpg: the cropped cover of each download

local next_download

-- Vivi 0.13+ has a shared Downloads panel and sets user-data/vivi/downloads: every job is
-- reported there (job id = video id) and its Cancel / Retry buttons call back
-- download-cancel / download-retry <job>. Older Vivi: progress shows in the dialog only.
-- 2 = this host shows `subtitle` and fetches `artwork` URLs (it sets the integer 1);
-- 1 = an earlier host (a string "1", which mp.get_property returns quoted).
function M.panel_level(v)
  if v == 1 then return 2 end
  if tostring(v or "") == "1" then return 1 end
  return 0
end
local function panel() return M.panel_level(mp.get_property_native("user-data/vivi/downloads")) end
S.dl_known = {}

-- The panel row of `it` with `fields` on top.
function M.panel_row(it, fields, level)
  local sub = {}
  for _, v in ipairs({ it.artist, it.album }) do if (v or "") ~= "" then sub[#sub + 1] = v end end
  -- No title yet (Retry after a restart): the row keeps the one it has.
  local title = (it.title or "") ~= "" and it.title or nil
  local r = { title = title, state = "queued", done = 0, total = 0, progress = 0, error = "", path = "",
    can_pause = false, detail = "" }
  local cover = it.cover or ""
  if level >= 2 then
    r.subtitle = table.concat(sub, " · ")
    if cover == "" then cover = (it.thumb_full or "") ~= "" and it.thumb_full or (it.thumb or "") end
  elseif title and (it.artist or "") ~= "" then
    r.title = title .. " · " .. it.artist
  end
  r.artwork = cover
  -- A track of a playlist download: drawn under the playlist's row.
  if it.pl and level >= 2 then r.parent = "playlist:" .. it.pl end
  for k, v in pairs(fields or {}) do r[k] = v end
  return r
end

local function report(it, fields)
  local level = panel()
  if level == 0 then return end
  mp.commandv("script-message", "vivi-download", ID, it.video_id, utils.format_json(M.panel_row(it, fields, level)))
end

-- downloads.tsv: which video each downloaded file is (re-downloads and name clashes).
local function load_index()
  local by_id, by_path = {}, {}
  for line in (read_file(INDEX) or ""):gmatch("[^\n]+") do
    local id, path = line:match("^([^\t]+)\t(.+)$")
    if id then by_id[id], by_path[path] = path, id end
  end
  return by_id, by_path
end

local function add_index(id, path)
  S.saved = nil
  mkdir_p(DATA)
  local f = io.open(INDEX, "ab")
  if f then f:write(id .. "\t" .. path .. "\n") f:close() end
end

local function file_exists(p) return utils.file_info(p) ~= nil end

local pl_finished -- (video id, ok, path, error): playlist downloads waiting for it

local function finish_download(ok, msg, path)
  if S.dl_timer then S.dl_timer:kill() S.dl_timer = nil end
  if S.dl_log then os.remove(S.dl_log) S.dl_log = nil end
  local it = S.dl_item
  S.dl_job, S.dl_pct, S.dl_item = nil, nil, nil
  if it then
    if ok then
      local c = COVERS .. SEP .. it.video_id .. ".jpg"
      if file_exists(c) then it.cover = c end
      local fi = path and path ~= "" and utils.file_info(path)
      local size = fi and fi.size or 0
      report(it, { state = "done", progress = 1, path = path or "", done = size, total = size })
    else
      report(it, { state = "failed", error = (msg or ""):gsub("^Download failed: ", "") })
    end
  end
  -- Desktop notification (or a player toast when notifications are off); a playlist's
  -- tracks finish quietly and the playlist notifies once.
  if not (it and it.pl) then
    mp.commandv("script-message", "vivi-notify", ID, ok and "Download finished" or "Download failed", msg)
  end
  if it then pl_finished(it.video_id, ok, path, msg) end
  if S.open then show() end
  next_download()
end

-- One subprocess step of the running download; a newer step or job makes it stale.
local function step(args, cb)
  local me
  me = mp.command_native_async({ name = "subprocess", args = args, playback_only = false,
    capture_stdout = true, capture_stderr = true }, function(_, r)
    if S.dl_job ~= me then return end
    r = r or {}
    if r.killed_by_us then return finish_download(false, "Download cancelled") end
    cb(r)
  end)
  S.dl_job = me
end

-- Step 3 (no mutagen): put the cropped cover into the file with ffmpeg.
local function add_cover(it, path, ff, done)
  local cover = COVERS .. SEP .. it.video_id .. ".jpg"
  local data = ff and read_file(cover)
  local ext = path:match("(%.%w+)$") or ""
  local tmp = path:sub(1, #path - #ext) .. ".vivi-cover" .. ext
  local meta = DATA .. SEP .. "cover.ffmeta"
  local args = data and M.cover_args(ffmpeg_bin(ff), path, cover, tmp, meta)
  if not args then return done() end
  if ext:lower() == ".opus" or ext:lower() == ".ogg" then
    local f = io.open(meta, "wb")
    if not f then return done() end
    f:write(M.picture_meta(data))
    f:close()
  end
  report(it, { state = "active", progress = 1, detail = "Adding the cover…" })
  step(args, function(r)
    os.remove(meta)
    if r.status == 0 and file_exists(tmp) then
      os.remove(path)
      os.rename(tmp, path)
    else
      os.remove(tmp)
      mp.msg.warn("cover not embedded: " .. trim(r.stderr or ""))
    end
    done()
  end)
end

local function download_folder()
  local folder = trim(o.folder)
  if folder == "" then folder = HOME .. SEP .. "Music" .. SEP .. "vivi" end
  folder = folder:gsub("^~", HOME)
  if #folder > 1 then folder = folder:gsub("[/\\]+$", "") end
  return folder
end

local PL_PAUSE = 2 -- seconds between the tracks of a playlist download (rate limits)

next_download = function()
  if S.dl_job or S.dl_wait or #S.dl_queue == 0 then return end
  if S.dl_queue[1].pl and S.dl_last_pl and os.time() - S.dl_last_pl < PL_PAUSE then
    S.dl_wait = mp.add_timeout(PL_PAUSE, function() S.dl_wait = nil next_download() end)
    return
  end
  local it = table.remove(S.dl_queue, 1)
  if it.pl then S.dl_last_pl = os.time() end
  local y = ytdlp_ok()
  if not y then
    for _, x in ipairs(S.dl_queue) do report(x, { state = "failed", error = "yt-dlp is missing" }) end
    report(it, { state = "failed", error = "yt-dlp is missing" })
    local all = { it }
    for _, x in ipairs(S.dl_queue) do all[#all + 1] = x end
    S.dl_queue = {}
    for _, x in ipairs(all) do pl_finished(x.video_id, false, nil, "yt-dlp is missing") end
    return toast(NO_YTDLP, 8)
  end
  local folder = download_folder()
  mkdir_p(folder)
  mkdir_p(COVERS)
  load_cookies()
  local jar = ytdlp_jar()
  S.dl_title, S.dl_pct, S.dl_item = it.title, 0, it
  local by_id, by_path = load_index()
  -- Downloaded before (and still there): nothing to do.
  local before = by_id[it.video_id]
  if before and file_exists(before) and M.reuse(before, folder, it.pl and "Original" or o["audio-format"]) then
    return finish_download(true, "Already downloaded: " .. before, before)
  end
  local ff = ffmpeg_dir()
  local meta = M.meta_args(it)
  local info = DATA .. SEP .. "download"
  os.remove(info .. ".info.json")
  report(it, { state = "active", progress = -1, detail = "Preparing…" })
  if S.open then show() end
  -- Step 1: metadata and the file name.
  local probe = M.probe_args(M.url(it), folder, jar, info, meta)
  table.insert(probe, 1, y)
  step(probe, function(r)
    local p = M.parse_probe(r.stdout, r.stderr)
    if r.status ~= 0 or not p.filename or not file_exists(info .. ".info.json") then
      os.remove(info .. ".info.json")
      return finish_download(false, "Download failed: " .. ((r.stderr or ""):match("ERROR: ([^\n]+)") or r.error_string or "yt-dlp error"))
    end
    if it.title == "" or it.title == it.video_id or it.from_player then it.title = p.title ~= "" and p.title or it.title end
    if (it.artist or "") == "" then it.artist = p.artist end
    if (it.album or "") == "" then it.album = p.album end
    if (it.thumb or "") == "" and (it.thumb_full or "") == "" then it.thumb_full = p.thumb end
    S.dl_title = it.title
    -- The name is taken by another video: add the id; with the id it is this one.
    local with_id = false
    local same = M.existing(p.filename, file_exists)
    if same and by_path[same] ~= it.video_id then
      with_id = true
      same = M.existing(M.with_id(p.filename, it.video_id), file_exists)
    end
    if same and not M.reuse(same, folder, o["audio-format"]) then same = nil end
    if same then
      os.remove(info .. ".info.json")
      add_index(it.video_id, same)
      return finish_download(true, "Already downloaded: “" .. it.title .. "”", same)
    end
    local embed = p.mutagen
    -- yt-dlp would not replace an older cover (--no-overwrites) and leave the new one
    -- next to the song instead.
    os.remove(COVERS .. SEP .. it.video_id .. ".jpg")
    local pathfile = DATA .. SEP .. "download.path"
    os.remove(pathfile)
    local args = M.download_args(M.url(it), folder, o["audio-format"], jar, ff, pathfile,
      { meta = meta, with_id = with_id, info = info .. ".info.json", covers = COVERS, embed = embed })
    table.insert(args, 1, y)
    report(it, { state = "active", progress = 0, detail = "" })
    if not windows then
      S.dl_log = DATA .. SEP .. "download.log"
      os.remove(S.dl_log)
      args = M.log_wrap(S.dl_log, args)
      S.dl_timer = mp.add_periodic_timer(1, function()
        local pc = M.parse_progress(read_file(S.dl_log) or "")
        if pc and pc ~= S.dl_pct then
          S.dl_pct = pc
          report(it, { state = "active", progress = pc / 100 })
          if S.open then show() end
        end
      end)
    end
    -- Step 2: the download (tags, cover).
    step(args, function(r2)
      if S.dl_timer then S.dl_timer:kill() S.dl_timer = nil end
      local log = (S.dl_log and read_file(S.dl_log) or "") .. (r2.stdout or "") .. (r2.stderr or "")
      os.remove(info .. ".info.json")
      if r2.status ~= 0 then
        return finish_download(false, "Download failed: " .. (log:match("ERROR: ([^\n]+)") or r2.error_string or "yt-dlp error"))
      end
      local path = trim((read_file(pathfile) or ""):match("[^\r\n]+") or "")
      os.remove(pathfile)
      if path ~= "" then add_index(it.video_id, path) end
      local function done() finish_download(true, "Downloaded “" .. it.title .. "” to " .. folder, path) end
      -- Step 3: the cover, when yt-dlp could not embed it.
      if not embed and ff and path ~= "" then return add_cover(it, path, ff, done) end
      done()
    end)
  end)
  if S.open then show() end
end

local function download(it)
  if not o.downloads then return toast("Turn on Allow downloads in the YouTube Music settings first", 5) end
  if not is_track(it) then return toast("Downloads are per track: open the album or playlist and download its tracks", 5) end
  for _, x in ipairs(S.dl_queue) do if x.video_id == it.video_id then return end end
  if S.dl_item and S.dl_item.video_id == it.video_id then return end
  S.dl_queue[#S.dl_queue + 1] = it
  S.dl_known[it.video_id] = it
  report(it, { state = "queued" })
  if S.dl_job then toast("Queued for download: " .. it.title) end
  next_download()
end

local function cancel_downloads()
  local q = S.dl_queue
  S.dl_queue = {}
  for _, x in ipairs(q) do
    report(x, { state = "failed", error = "Cancelled" })
    pl_finished(x.video_id, false, nil, "Cancelled")
  end
  if S.dl_job then mp.abort_async_command(S.dl_job) else toast("No download is running") end
end

-- Downloads panel buttons.
local cancel_playlist, sync_playlist

local function cancel_job(job)
  local src = (job or ""):match("^playlist:(.+)$")
  if src then return cancel_playlist(src) end
  if S.dl_item and S.dl_item.video_id == job then return mp.abort_async_command(S.dl_job) end
  for i, x in ipairs(S.dl_queue) do
    if x.video_id == job then
      table.remove(S.dl_queue, i)
      report(x, { state = "failed", error = "Cancelled" })
      return pl_finished(x.video_id, false, nil, "Cancelled")
    end
  end
end

-- Retry also works after a restart: the job id is the video id (step 1 finds the rest).
local function retry_job(job)
  local src = (job or ""):match("^playlist:(.+)$")
  if src then return sync_playlist(src) end
  local it = S.dl_known[job]
  if not it then
    if not (job or ""):match("^[%w_%-]+$") then return end
    it = new_item("")
    it.video_id, it.from_player = job, true
  end
  download(it)
end


-- ---------------------------------------------------------------- playlist downloads
local PLAYLISTS = DATA .. SEP .. "playlists.json"    -- { <browse id> = { name, path, synced, tracks } }
local PL_COVERS = DATA .. SEP .. "playlist-covers"   -- <browse id>.jpg: the square header cover
S.pls = {}                                            -- running playlist downloads by browse id

local function pl_dir() return DATA_HOME .. SEP .. "vivi" .. SEP .. "playlists" end

local function load_pls()
  local t = utils.parse_json(read_file(PLAYLISTS) or "")
  return type(t) == "table" and not is_array(t) and t or {}
end

local function save_pls(t)
  mkdir_p(DATA)
  local f = io.open(PLAYLISTS, "wb")
  if f then f:write(utils.format_json(t)) f:close() end
end

-- Vivi 0.13+ writes plugin playlists (vivi-playlist) and sets this.
local function host_playlists() return mp.get_property_native("user-data/vivi/playlists") == 1 end

local function pl_report(st, fields)
  if panel() == 0 then return end
  local r = { title = st.name, subtitle = st.album and "Album" or "Playlist",
    artwork = st.thumb or "", items_done = st.done, items_total = st.total, can_pause = false }
  for k, v in pairs(fields or {}) do r[k] = v end
  mp.commandv("script-message", "vivi-download", ID, "playlist:" .. st.src, utils.format_json(r))
end

-- Every track of a playlist / album (all pages), then cb(page, tracks) or cb(nil, err).
local function fetch_all(src, cb)
  browse_req(src, function(p, err)
    if not p then return cb(nil, err) end
    local list = {}
    local function add(items)
      for _, x in ipairs(items) do if is_track(x) and #list < PL_MAX then list[#list + 1] = x end end
    end
    add(p.items)
    local function page(c, n)
      if not c or #list >= PL_MAX or n > PL_PAGES then return cb(p, list) end
      more_req("browse", c, function(r, e)
        -- A failed page: stop rather than write a playlist missing its end.
        if not r then return cb(nil, e) end
        add(r.items)
        page(r.cont, n + 1)
      end)
    end
    page(p.cont, 1)
  end)
end

-- The header cover, square-cropped with ffmpeg, then cb(path or nil).
local function pl_cover(st, cb)
  local url = st.thumb or ""
  if url == "" then return cb(nil) end
  mkdir_p(PL_COVERS)
  local base = PL_COVERS .. SEP .. st.src:gsub("[^%w_%-]", "_")
  local raw, out = base .. ".download", base .. ".jpg"
  mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
    args = { "curl", "-sSfL", "-m", "30", "-o", raw, url } }, function(_, r)
    if not (r and r.status == 0 and file_exists(raw)) then os.remove(raw) return cb(file_exists(out) and out or nil) end
    local ff = ffmpeg_dir()
    if not ff then
      os.remove(out)
      os.rename(raw, out) -- YouTube Music covers are JPEG
      return cb(out)
    end
    mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true, capture_stderr = true,
      args = { ffmpeg_bin(ff), "-v", "error", "-y", "-i", raw, "-vf", "crop='min(iw,ih)':'min(iw,ih)'",
        "-frames:v", "1", "-q:v", "2", out } }, function(_, r2)
      os.remove(raw)
      cb((r2 and r2.status == 0 and file_exists(out)) and out or nil)
    end)
  end)
end

local function list_m3u(dir)
  local t = utils.readdir(dir, "files") or {}
  local out = {}
  for _, f in ipairs(t) do if f:match("%.m3u$") then out[#out + 1] = f end end
  return out
end

-- Older Vivi: write the playlist and its cover ourselves (same format as the host).
local function write_own(st, entries, cover)
  local dir = pl_dir()
  mkdir_p(dir)
  local path = M.pick_path(dir, st.name, st.src, list_m3u(dir), read_file)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return nil, "Cannot write to " .. dir end
  f:write(M.m3u(st.name, st.src, entries))
  f:close()
  local ok, err = os.rename(tmp, path)
  if not ok then os.remove(tmp) return nil, err end
  if cover then
    local stem = path:gsub("%.m3u$", "")
    for _, e in ipairs({ ".jpg", ".jpeg", ".png", ".webp" }) do os.remove(stem .. e) end
    local data = read_file(cover)
    local c = data and io.open(stem .. ".jpg", "wb")
    if c then c:write(data) c:close() end
  end
  return path
end

local function pl_record(src, fields)
  local t = load_pls()
  local r = t[src] or {}
  for k, v in pairs(fields) do r[k] = v end
  t[src] = r
  save_pls(t)
end

-- The last step: write the playlist, report the row, notify.
local function pl_done(st, path, err)
  S.pls[st.src] = nil
  if not path then
    pl_report(st, { state = "failed", error = err or "Could not write the playlist" })
    mp.commandv("script-message", "vivi-notify", ID, "Playlist not downloaded", "“" .. st.name .. "”: " .. tostring(err))
    return toast("Could not save the playlist “" .. st.name .. "”: " .. tostring(err), 6)
  end
  pl_record(st.src, { name = st.name, path = path, synced = os.time(), tracks = st.done })
  local msg = string.format("“%s”: %d of %d tracks", st.name, st.done, st.total)
  if st.failed > 0 then
    pl_report(st, { state = "failed", path = path,
      error = st.limited and "YouTube is limiting downloads: Sync again later" or "Retry downloads the rest" })
    mp.commandv("script-message", "vivi-notify", ID, "Playlist partly downloaded", msg)
  else
    pl_report(st, { state = "done", path = path, error = "", detail = "" })
    if st.had and st.done == st.had then
      -- A sync that found nothing new: not "downloaded" again.
      mp.commandv("script-message", "vivi-notify", ID, "Playlist up to date",
        string.format("“%s”: all %d tracks are here", st.name, st.done))
    else
      mp.commandv("script-message", "vivi-notify", ID, "Playlist downloaded", msg)
    end
  end
  if S.open then show() end
end

local function pl_write(st)
  if st.writing then return end
  st.writing = true
  pl_report(st, { state = "active", detail = "Writing the playlist…" })
  local entries = M.entries(st.order, st.paths)
  if #entries == 0 then return pl_done(st, nil, "No track could be downloaded") end
  pl_cover(st, function(cover)
    if host_playlists() then
      -- Vivi answers playlist-saved / playlist-failed.
      st.waiting = true
      mp.commandv("script-message", "vivi-playlist", ID, utils.format_json({ name = st.name, source = st.src,
        url = M.source_url(st.src), entries = entries, cover = cover or st.thumb or "" }))
    else
      pl_done(st, write_own(st, entries, cover))
    end
  end)
end

pl_finished = function(id, ok, path, err)
  for _, st in pairs(S.pls) do
    if st.want[id] then
      st.want[id] = nil
      st.pending = st.pending - 1
      if ok and path and path ~= "" then
        st.paths[id] = path
        st.done = st.done + 1
      else
        st.failed = st.failed + 1
        -- Rate-limited or blocked: stop this playlist instead of failing every track.
        local e = (err or ""):lower()
        if e:find("429", 1, true) or e:find("too many requests", 1, true) or e:find("not a bot", 1, true) then
          st.limited = true
        end
      end
      if st.limited and not st.stopping then
        st.stopping = true
        mp.add_timeout(0, function() cancel_playlist(st.src, "YouTube is limiting downloads: Sync again later") end)
      end
      if st.pending <= 0 then pl_write(st) else pl_report(st, { state = "active", detail = "" }) end
    end
  end
end

cancel_playlist = function(src, why)
  local st = S.pls[src]
  if not st then return end
  local keep = {}
  local dropped = {}
  for _, x in ipairs(S.dl_queue) do
    if x.pl == src and st.want[x.video_id] then dropped[#dropped + 1] = x else keep[#keep + 1] = x end
  end
  S.dl_queue = keep
  for _, x in ipairs(dropped) do
    report(x, { state = "failed", error = why or "Cancelled" })
    pl_finished(x.video_id, false, nil, why or "Cancelled")
  end
  if S.dl_item and S.dl_item.pl == src and S.dl_job then mp.abort_async_command(S.dl_job) end
  if st.fetching then
    S.pls[src] = nil
    pl_report(st, { state = "failed", error = why or "Cancelled" })
  end
end

-- Download (or sync) playlist / album `src`; hint = { title, thumb } from the list it was
-- picked in.
sync_playlist = function(src, hint)
  if not o.downloads then return toast("Turn on Allow downloads in the YouTube Music settings first", 5) end
  if not ytdlp_ok() then return toast(NO_YTDLP, 8) end
  if S.pls[src] then return toast("This playlist is already downloading") end
  hint = hint or {}
  local rec = load_pls()[src] or {}
  local st = { src = src, name = rec.name or hint.title or "", thumb = hint.thumb, album = src:sub(1, 4) == "MPRE",
    total = 0, done = 0, failed = 0, pending = 0, want = {}, paths = {}, order = {}, fetching = true }
  S.pls[src] = st
  pl_report(st, { state = "active", title = st.name ~= "" and st.name or NAME .. " playlist",
    detail = "Getting the track list…", error = "", path = "" })
  toast(st.name ~= "" and ("Getting the tracks of “" .. st.name .. "”…") or "Getting the tracks…")
  fetch_all(src, function(p, list)
    if S.pls[src] ~= st then return end
    st.fetching = false
    if not p then
      S.pls[src] = nil
      pl_report(st, { state = "failed", error = list or "Could not load the playlist" })
      return toast(tostring(list), 6)
    end
    -- A synced playlist keeps the name it got first (its file is found by its source).
    if (rec.name or "") == "" and p.title ~= "" then st.name = p.title end
    if st.name == "" then st.name = M.list_name(list) end
    if p.thumb ~= "" then st.thumb = p.thumb end
    if (st.thumb or "") == "" and list[1] then st.thumb = list[1].thumb_full ~= "" and list[1].thumb_full or list[1].thumb end
    local folder = download_folder()
    local by_id = load_index()
    local plan = M.plan(list, function(it)
      local f = by_id[it.video_id]
      -- Any format already in the download folder (no re-download after a format change).
      if f and file_exists(f) and M.reuse(f, folder, "Original") then return f end
      return nil
    end)
    st.order, st.paths = plan.order, plan.have
    st.total = #plan.order
    for _ in pairs(plan.have) do st.done = st.done + 1 end
    st.had = st.done
    if st.total == 0 then
      S.pls[src] = nil
      return pl_report(st, { state = "failed", error = "No playable tracks" })
    end
    for _, it in ipairs(plan.todo) do
      it.pl = src
      st.want[it.video_id] = true
      st.pending = st.pending + 1
    end
    pl_report(st, { state = "active", detail = "" })
    if st.pending == 0 then return pl_write(st) end
    toast(string.format("“%s”: %d tracks to download, %d already here", st.name, st.pending, st.done))
    for _, it in ipairs(plan.todo) do
      -- Already queued on its own: that download counts for the playlist too.
      local queued = (S.dl_item and S.dl_item.video_id == it.video_id)
      for _, x in ipairs(S.dl_queue) do if x.video_id == it.video_id then queued = true end end
      if not queued then
        S.dl_queue[#S.dl_queue + 1] = it
        S.dl_known[it.video_id] = it
        report(it, { state = "queued" })
      end
    end
    next_download()
    if S.open then show() end
  end)
end

-- Sync every downloaded playlist whose file is still there (one after another).
local function sync_all()
  local srcs = {}
  for src, r in pairs(load_pls()) do
    if r.path and file_exists(r.path) then srcs[#srcs + 1] = src end
  end
  table.sort(srcs)
  if #srcs == 0 then return toast("No downloaded YouTube Music playlists yet") end
  local i = 0
  local function nxt()
    i = i + 1
    if not srcs[i] then return end
    sync_playlist(srcs[i])
    -- The next one starts when this one has its track list.
    local t
    t = mp.add_periodic_timer(1, function()
      local st = S.pls[srcs[i]]
      if not (st and st.fetching) then t:kill() nxt() end
    end)
  end
  nxt()
end

-- Is `src` a downloaded playlist (its file still there)?
local function is_synced(src)
  local r = src and load_pls()[src]
  return r and r.path and file_exists(r.path) or false
end

-- The playlist / album of the open page or chosen item: src, { title, thumb }.
local function pl_target()
  local it = selected()
  local src = M.source_of(it)
  if src then return src, { title = it.title, thumb = it.thumb_full ~= "" and it.thumb_full or it.thumb } end
  if S.view.kind == "lib" and S.view.i == 1 then return LIBRARY[1][2], { title = S.title ~= "" and S.title or "Liked Music" } end
  if S.view.kind == "page" then
    local id = S.view.id or ""
    if id:sub(1, 2) == "VL" or id:sub(1, 4) == "MPRE" then return id, { title = S.title ~= "" and S.title or S.view.title } end
    if S.page_playlist ~= "" and id:sub(1, 2) ~= "UC" then return "VL" .. S.page_playlist, { title = S.title } end
  end
  return nil
end

pl_action = function()
  local src = pl_target()
  if not src then return nil end
  if S.pls[src] then return nil end
  if is_synced(src) then return "Sync playlist" end
  return src:sub(1, 4) == "MPRE" and "Download album" or "Download playlist"
end

local WARNING = "Downloading from YouTube Music may violate YouTube's Terms of Service and the rights of the artists and labels. " ..
  "Only download for your own personal use, where the law allows it, and at your own risk: Google may restrict accounts that do it.\n\n" ..
  "Downloads need yt-dlp (and ffmpeg for tags and the cover). Files go to the download folder you choose (default ~/Music/vivi)."

local function ask_downloads()
  mp.commandv("script-message", "vivi-confirm", ID, "downloads", utils.format_json({ title = "Allow downloads?",
    heading = "Downloads are for personal use only", text = WARNING, ok = "Allow downloads" }))
end

-- ---------------------------------------------------------------- events
local function index(args)
  local i = tonumber(args and args[1] or "")
  if i then return i + 1 end -- the dialog counts from 0
  return nil
end

local function on_ui(json)
  local e = utils.parse_json(json or "")
  if type(e) ~= "table" then return end
  local ev, args = str(e.event), e.args or {}
  if ev == "search" then
    local f = 1
    for i, fl in ipairs(FILTERS) do if fl[1] == e.source then f = i end end
    S.back = {}
    load_view({ kind = "search", q = str(e.query), filter = f })
  elseif ev == "chip" then
    for i, l in ipairs(LIBRARY) do
      if l[1] == args[1] then S.back = {} load_view({ kind = "lib", i = i }) end
    end
  elseif ev == "select" then
    S.sel = index(args)
    show()
  elseif ev == "primary" then
    local i = index(args) or S.sel
    if S.items[i] then S.sel = i play(S.items[i]) end
  elseif ev == "secondary" then
    local i = index(args) or S.sel
    local it = S.items[i]
    if not it then return end
    if o.downloads then download(it) else queue({ it }, false, "Added “" .. it.title .. "” to the queue") end
  elseif ev:sub(1, 4) == "act:" then
    local a = ev:sub(5)
    local i = index(args)
    if i and S.items[i] then S.sel = i end
    local it = selected()
    if a == "‹ Back" then
      local v = table.remove(S.back)
      if v then load_view(v) end
    elseif a == "Play all" then play_all(false)
    elseif a == "Shuffle" then play_all(true)
    elseif a == "Queue" and it then
      if is_track(it) then queue({ it }, false, "Added “" .. it.title .. "” to the queue")
      else container_tracks(it, function(l) queue(l, false, string.format("%d tracks of “%s” queued", #l, it.title)) end) end
    elseif a == "Start mix" and it then radio(it, true)
    elseif a == "Album" and it then go({ kind = "page", id = it.album_id, title = it.album })
    elseif a == "Artist" and it then go({ kind = "page", id = it.artist_id, title = it.artist })
    elseif (a == "Like" or a == "Unlike") and it then rate(it, a == "Like")
    elseif a == "Cancel download" then cancel_downloads()
    elseif a == "Download playlist" or a == "Download album" or a == "Sync playlist" then
      local src, hint = pl_target()
      if src then sync_playlist(src, hint) end
    end
  elseif ev == "more" then more()
  elseif ev == "view" then
    o.view = args[1] == "grid" and "Grid" or "List"
    mp.commandv("script-message", "vivi-setting", ID, "view", o.view)
  elseif ev == "filter" then
    if args[1] == "Add to playlist" then add_to(args[2]) end
  elseif ev == "close" then
    S.open = false
  elseif ev == "confirm" then
    if args[1] == "downloads" and args[2] == "yes" then
      o.downloads = true
      write_private(ACCEPTED, os.date("!%Y-%m-%dT%H:%M:%SZ") .. "\n")
      mp.commandv("script-message", "vivi-setting", ID, "downloads", "true")
      toast("Downloads are on. Use the Download button in YouTube Music")
      if S.open then show() end
    end
  end
end

local function current()
  local path = mp.get_property("path", "")
  local id = path:match("^https://music%.youtube%.com/watch%?v=([%w_%-]+)")
  -- A song downloaded by this plugin (downloads.tsv knows its video id).
  if not id and path ~= "" then
    local _, by_path = load_index()
    id = by_path[path]
  end
  if not id then return nil end
  local it = new_item(mp.get_property("media-title", id))
  it.video_id, it.from_player = id, true
  return it
end

local function accepted() return utils.file_info(ACCEPTED) ~= nil end
local last_downloads = nil
-- Newer Vivi sets the options under the underscore id (youtube_music-*), and leaves out
-- the youtube-music-* keys the YouTube & yt-dlp plugin would read as its own; older builds
-- only set youtube-music-*. Vivi always sets <prefix>-pkgdir for a package, so that tells
-- which prefix this host uses.
function M.opts_prefix(script_opts)
  local safe = ID:gsub("-", "_")
  if type(script_opts) == "table" and script_opts[safe .. "-pkgdir"] ~= nil then return safe end
  return ID
end
options.read_options(o, M.opts_prefix(mp.get_property_native("options/script-opts", {})), function(changed)
  if changed.downloads and o.downloads and last_downloads == false and not accepted() then
    -- Turned on in Settings: ask first, keep it off until the user agrees.
    o.downloads = false
    mp.commandv("script-message", "vivi-setting", ID, "downloads", "false")
    ask_downloads()
  end
  last_downloads = o.downloads
  if S.open then show() end
end)
last_downloads = o.downloads
if o.downloads and not accepted() then
  o.downloads = false
  mp.commandv("script-message", "vivi-setting", ID, "downloads", "false")
end

mp.register_script_message("vivi-ui", on_ui)
mp.register_script_message("open", open)
mp.register_script_message("liked", function() open({ kind = "lib", i = 1 }) end)
mp.register_script_message("sign-in", sign_in_browser)
mp.register_script_message("import", function()
  local p = trim(o["cookie-file"]):gsub("^~", HOME)
  if p == "" then return toast("Enter the path of a cookies.txt or request-headers file first", 6) end
  local s = read_file(p)
  if not s then return toast("Cannot read " .. p, 6) end
  import_text(s, "file")
end)
mp.register_script_message("paste", function()
  local s = M.clipboard()
  if not s or s == "" then
    return signin_result(false, "The clipboard is empty, or it could not be read (on Wayland install wl-clipboard): use Import with a file instead")
  end
  import_text(s, "clipboard")
end)
mp.register_script_message("sign-out", sign_out)
mp.register_script_message("cancel", cancel_downloads)
mp.register_script_message("allow-downloads", ask_downloads)
mp.register_script_message("download-cancel", cancel_job)
mp.register_script_message("download-retry", retry_job)
-- Playlists (Vivi's Playlists tab: Sync / Open Source; vivi-playlist answers).
mp.register_script_message("playlist-sync", function(src) if src and src ~= "" then sync_playlist(src) end end)
mp.register_script_message("sync-playlists", sync_all)
mp.register_script_message("playlist-open", function(src)
  if not src or src == "" then return end
  open()
  go({ kind = "page", id = src, title = (load_pls()[src] or {}).name })
end)
mp.register_script_message("playlist-saved", function(src, path)
  local st = S.pls[src or ""]
  if st and st.waiting then pl_done(st, path) end
end)
mp.register_script_message("playlist-failed", function(src, err)
  local st = S.pls[src or ""]
  if st and st.waiting then pl_done(st, nil, err) end
end)
mp.register_script_message("radio-current", function()
  local it = current()
  if not it then return toast("Play a YouTube Music song first") end
  radio(it, false)
end)
mp.register_script_message("like-current", function()
  local it = current()
  if not it then return toast("Play a YouTube Music song first") end
  if not signed_in() then return toast("Sign in to YouTube Music to like songs (Settings → Extensions → YouTube Music)", 6) end
  -- "Like", never a toggle: a tray click must not remove a like (unlike in the dialog).
  if S.liked[it.video_id] then return toast("“" .. it.title .. "” is in your liked songs already") end
  rate(it, true)
end)
mp.register_script_message("download-current", function()
  local it = current()
  if not it then return toast("Play a YouTube Music song first") end
  download(it)
end)
mp.register_event("shutdown", function() if S.dl_job then mp.abort_async_command(S.dl_job) end end)

math.randomseed(os.time())

if rawget(_G, "VIVI_TEST") or os.getenv("VIVI_TEST") then
  M.bus_names, M.helper_ok = bus_names, helper_ok
  M.download, M.cancel_job, M.retry_job, M.sync_playlist, M.sync_all = download, cancel_job, retry_job, sync_playlist, sync_all
  M.S, M.on_ui, M.FILTERS, M.LIBRARY, M.BROWSERS, M.FORMATS, M.o = S, on_ui, FILTERS, LIBRARY, BROWSERS, FORMATS, o
  return M
end
