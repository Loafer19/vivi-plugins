local T = dofile("tests/plugins/stub.lua")
local TOKEN, KEY, SECRET, SK = "lb-token-SECRET-1", "apikey123", "shared-SECRET-2", "session-SECRET-3"
local P = T.load("plugins/scrobbler/scrobbler.lua", { token = TOKEN, lastfm_key = KEY, lastfm_secret = SECRET })
os.execute("mkdir -p '" .. P.dir .. "'")

-- ---- MD5 (RFC 1321 vectors), native and pure-arithmetic bit operations
local pure = P.pure_bitops()
for _, v in ipairs({
  { "", "d41d8cd98f00b204e9800998ecf8427e" },
  { "abc", "900150983cd24fb0d6963f7d28e17f72" },
  { "message digest", "f96b697d7cb7938d525a2f31aaf161d0" },
  { string.rep("1234567890", 8), "57edf4a22be3c955ac49da2e2107b67a" },
}) do
  T.eq(P.md5(v[1]), v[2], "md5 " .. #v[1])
  T.eq(P.md5(v[1], pure), v[2], "md5 pure Lua 5.1 " .. #v[1])
end
-- Signature: sorted key/value pairs, format excluded, secret appended.
local sig = P.lastfm_sig({ method = "auth.getSession", api_key = "k", token = "t", format = "json" }, "s")
T.eq(sig, P.md5("api_keykmethodauth.getSessiontokents"), "lastfm signature")
local b = P.lastfm_batch({ { artist = "A", track = "T", timestamp = 1, album = "X", track_number = 3 },
  { artist = "B", track = "U", timestamp = 2 } })
T.eq(b["artist[0]"], "A", "batch artist 0")
T.eq(b["trackNumber[0]"], "3", "batch track number")
T.eq(b["timestamp[1]"], "2", "batch timestamp 1")
T.eq(b["album[1]"], nil, "batch no album 1")
T.eq(P.form({ b = "x y", a = "é" }), "a=%C3%A9&b=x%20y", "form encoding")
-- 50% / 4 minutes, nothing under 30 s
T.eq(P.threshold(20), nil, "short track")
T.eq(P.threshold(200), 100, "half")
T.eq(P.threshold(600), 240, "4 minutes")

-- ---- curl config files and URLs
T.eq(P.curl_quote('a"b\\c\nd'), '"a\\"b\\\\c\\nd"', "curl config quoting")
T.eq(P.curl_config({ headers = { "Authorization: Token x" }, body = "{}" }),
  'header = "Authorization: Token x"\ndata-raw = "{}"\n', "curl config")
T.ok(P.safe_url("https://api.listenbrainz.org/1/x"), "https ok")
T.ok(P.safe_url("http://127.0.0.1:8080/1/x"), "loopback http ok")
T.ok(P.safe_url("http://localhost/1/x"), "localhost http ok")
T.ok(not P.safe_url("http://maloja.example/apis/listenbrainz/1/x"), "remote http refused")
T.ok(not P.safe_url("http://127.0.0.1.evil.example/"), "lookalike host refused")

-- ---- tags, filters
T.eq(P.mbid(" 8F3471B5-7E6A-48DA-86A9-C1C07A0F47AE "), "8f3471b5-7e6a-48da-86a9-c1c07a0f47ae", "mbid normalised")
T.eq(P.mbid("not-an-id"), nil, "bad mbid dropped")
T.eq(#P.mbids("8f3471b5-7e6a-48da-86a9-c1c07a0f47ae; 0383dadf-2a4e-4d10-a46a-e9e041da8eb3"), 2, "several artist mbids")
T.eq(P.track_no("3/12"), 3, "track 3/12")
T.eq(P.track_no("x"), nil, "no track number")
T.eq(P.skip_reason({ path = "/m/a.mkv", video = true }), "video (Only music is on)", "video skipped")
T.eq(P.skip_reason({ path = "https://music/x", video = true, from_plugin = true }), nil, "music package stream with video kept")
T.eq(P.skip_reason({ path = "/m/a.mp3", genre = "Comedy Podcast" }), "genre Comedy Podcast", "podcast genre")
T.eq(P.skip_reason({ path = "/m/Book.M4B" }), "audiobook (.m4b)", "m4b")
P.opts.skip_folders = "/home/u/Audio Notes, C:\\Sounds"
T.eq(P.skip_reason({ path = "/home/u/Audio Notes/x.mp3" }), "folder /home/u/Audio Notes", "folder")
T.eq(P.skip_reason({ path = "/home/u/Audio Notes 2/x.mp3" }), nil, "folder prefix needs a separator")
T.eq(P.skip_reason({ path = "/m/a.flac", genre = "Rock" }), nil, "music kept")
P.opts.skip_folders = ""
P.opts.audio_only = false
T.eq(P.skip_reason({ path = "/m/a.mkv", video = true }), nil, "videos allowed when Only music is off")
P.opts.audio_only = true

-- ---- a mock of both APIs: every curl call is answered by `respond`
local reqs = {}
local respond
local function unq(v)
  return (v:gsub('^"', ""):gsub('"$', ""):gsub("\\(.)", { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\" }))
end
local function parse_form(s)
  local t = {}
  for k, v in s:gmatch("([^&=]+)=([^&]*)") do
    local d = function(x) return (x:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
    t[d(k)] = d(v)
  end
  return t
end
T.set_async(function(t, cb)
  local a = t.args or {}
  if a[1] ~= "curl" then return cb and cb(true, { status = 0, stdout = "" }) end
  local cfg, url
  for i, x in ipairs(a) do if x == "-K" then cfg = a[i + 1] end end
  url = a[#a]
  local f = assert(io.open(cfg, "r"), "request config exists while curl runs")
  local text = f:read("*a")
  f:close()
  local r = { url = url, args = a, headers = {}, cfg = cfg, stdin = t.stdin_data }
  for k, v in text:gmatch("([%w%-]+) = (\"[^\n]*\")\n") do
    if k == "header" then r.headers[#r.headers + 1] = unq(v) else r.body = unq(v) end
  end
  if r.body and r.body:sub(1, 1) == "{" then r.json = T.json_decode(r.body) elseif r.body then r.form = parse_form(r.body) end
  reqs[#reqs + 1] = r
  local code, body = respond(r)
  if not code then return cb(true, { status = 7, stdout = "000", stderr = "curl: (7) Failed to connect" }) end
  cb(true, { status = 0, stdout = body .. "\n" .. code, stderr = "" })
end)
local function ok_api(r)
  if r.form then
    local m = r.form.method
    if m == "track.scrobble" then
      return 200, '{"scrobbles":{"@attr":{"accepted":1,"ignored":0},"scrobble":{"ignoredMessage":{"code":"0","#text":""}}}}'
    end
    return 200, "{}"
  end
  return 200, '{"status":"ok"}'
end
respond = ok_api

-- every secret must stay out of command lines, stdin (mpv logs both) and messages to other scripts
local function no_leaks(what)
  for _, c in ipairs(T.calls) do
    local s = T.json_encode(c)
    for _, sec in ipairs({ TOKEN, SECRET, SK }) do
      T.ok(not s:find(sec, 1, true), what .. ": secret not in a command / script-message")
    end
  end
end

local function play(props)
  T.props = props
  P.start_track()
end
local md = {
  path = "/music/Artist/01 Song.flac", duration = 200,
  ["metadata/by-key/artist"] = "Kevin MacLeod", ["metadata/by-key/title"] = "Local Forecast",
  ["metadata/by-key/album"] = "Royalty Free", ["metadata/by-key/track"] = "3/12",
  ["metadata/by-key/musicbrainz_trackid"] = "8f3471b5-7e6a-48da-86a9-c1c07a0f47ae",
  ["track-list"] = { { type = "audio" }, { type = "video", albumart = true } },
}
P.adopt() -- nothing to adopt
T.eq(P.state().session, nil, "not connected")

-- ---- Last.fm desktop auth against the mock: getToken, browser, polling getSession
respond = function(r)
  if r.form.method == "auth.getToken" then return 200, '{"token":"tok1"}' end
  if r.form.method == "auth.getSession" then
    return 200, '{"session":{"name":"demo","key":"' .. SK .. '","subscriber":0}}'
  end
end
P.lastfm_connect()
T.eq(reqs[1].form.method, "auth.getToken", "connect asks for a token")
T.eq(reqs[1].form.sk, nil, "getToken unsigned by session")
T.eq(reqs[1].form.api_sig, P.lastfm_sig({ method = "auth.getToken", api_key = KEY }, SECRET), "getToken signed")
P.lastfm_finish(false)
T.eq(reqs[2].form.method, "auth.getSession", "finish gets the session")
T.eq(reqs[2].form.token, "tok1", "with the approved token")
T.eq(P.state().session.key, SK, "session kept")
local f = io.open(P.SESSION, "r")
T.ok(f and f:read("*a"):find(SK, 1, true), "session in the private file")
if f then f:close() end
local last_toast = T.calls[#T.calls]
T.eq(last_toast[2], "vivi-toast", "connected toast")
T.ok(last_toast[3]:find("demo"), "toast names the account")
no_leaks("auth")
for _, r in ipairs(reqs) do
  T.ok(not table.concat(r.args, " "):find(SK, 1, true), "session key not in curl args")
  T.eq(io.open(r.cfg, "r"), nil, "request file removed after curl")
end

-- ---- now playing + scrobble on both services
reqs, respond = {}, ok_api
play(md)
T.eq(#reqs, 2, "now playing to both")
local lbnp, lfnp = reqs[1], reqs[2]
T.eq(lbnp.url, "https://api.listenbrainz.org/1/submit-listens", "LB endpoint")
T.eq(lbnp.headers[1], "Authorization: Token " .. TOKEN, "LB token in the private header")
T.eq(lbnp.json.listen_type, "playing_now", "LB playing_now")
T.eq(lbnp.json.payload[1].listened_at, nil, "playing_now has no timestamp")
T.eq(lbnp.json.payload[1].track_metadata.additional_info.tracknumber, 3, "LB track number")
T.eq(lfnp.form.method, "track.updateNowPlaying", "Last.fm now playing")
T.eq(lfnp.form.sk, SK, "Last.fm session in the private body")
T.eq(lfnp.form.trackNumber, "3", "Last.fm track number")
local fsig = lfnp.form.api_sig
lfnp.form.api_sig, lfnp.form.format = nil, nil
T.eq(fsig, P.lastfm_sig(lfnp.form, SECRET), "now playing signature matches the sent fields")
for _, x in ipairs(lbnp.args) do T.ok(not x:find(TOKEN, 1, true), "LB token not in curl args") end
reqs = {}
P.on_time(nil, 0)
for t = 1, 99 do P.on_time(nil, t) end
T.eq(#reqs, 0, "not yet at 99 s")
P.on_seek()
P.on_time(nil, 150) -- a seek does not count as listening
P.on_time(nil, 151)
T.eq(#reqs, 2, "scrobbled at 100 s of playback (both services), not at the seek")
-- both services
P.on_time(nil, 152)
reqs = {}
P.on_seek() P.on_time(nil, 0.5) -- repeat one / back to the start
T.eq(#reqs, 2, "replay from the start: now playing again")
T.eq(P.state().cur.sent, false, "a new listen starts")
reqs = {}
for t = 1, 101 do P.on_time(nil, t + 0.5) end
T.eq(#reqs, 2, "replay scrobbled on both")
local lbs, lfs
for _, r in ipairs(reqs) do if r.json then lbs = r else lfs = r end end
T.eq(lbs.json.listen_type, "single", "LB single listen")
T.ok(type(lbs.json.payload[1].listened_at) == "number", "LB listened_at")
T.eq(lbs.json.payload[1].track_metadata.additional_info.recording_mbid, "8f3471b5-7e6a-48da-86a9-c1c07a0f47ae", "LB recording mbid")
T.eq(lfs.form.method, "track.scrobble", "Last.fm scrobble")
T.eq(lfs.form["artist[0]"], "Kevin MacLeod", "Last.fm artist")
T.eq(lfs.form["duration[0]"], "200", "Last.fm duration")
T.eq(lfs.form["mbid[0]"], "8f3471b5-7e6a-48da-86a9-c1c07a0f47ae", "Last.fm mbid")
fsig = lfs.form.api_sig
lfs.form.api_sig, lfs.form.format = nil, nil
T.eq(fsig, P.lastfm_sig(lfs.form, SECRET), "scrobble signature matches the sent fields")

-- ---- offline: both queue; back online: queued items go out as batches
respond = function() return nil end
reqs = {}
play(md)
for t = 0, 101 do P.on_time(nil, t) end
T.eq(#P.read_queue("lb"), 1, "LB offline: queued")
T.eq(#P.read_queue("lastfm"), 1, "Last.fm offline: queued")
T.ok(P.state().err.lb:find("network"), "network error noted")
-- Last.fm wrong secret (13) / invalid key (10): kept, not dropped
respond = function(r) if r.form then return 200, '{"error":13,"message":"Invalid method signature supplied"}' end end
P.flush(true)
T.eq(#P.read_queue("lastfm"), 1, "Last.fm queue kept on a signature error")
-- server rejects a batch with one bad listen: halves until only that one is dropped
P.enqueue("lb", { { listened_at = 2, track_metadata = { artist_name = "A", track_name = "bad" } },
  { listened_at = 3, track_metadata = { artist_name = "A", track_name = "ok2" } } })
reqs = {}
respond = function(r)
  if r.form then return ok_api(r) end
  for _, l in ipairs(r.json.payload) do if l.track_metadata.track_name == "bad" then return 400, '{"error":"invalid"}' end end
  return 200, '{"status":"ok"}'
end
P.flush(true)
T.eq(#P.read_queue("lb"), 0, "LB queue emptied")
T.eq(#P.read_queue("lastfm"), 0, "Last.fm queue sent once fixed")
local import, singles = 0, {}
for _, r in ipairs(reqs) do
  if r.json then
    if r.json.listen_type == "import" then import = import + 1 end
    if r.json.listen_type == "single" and r.json.payload[1].track_metadata.track_name ~= "bad" then
      singles[#singles + 1] = r.json.payload[1].track_metadata.track_name
    end
  end
end
T.ok(import >= 1, "first try as one import")
T.eq(table.concat(singles, ","), "Local Forecast,ok2", "good listens resent in smaller batches after the reject")
-- Last.fm ignores (e.g. too old) are reported
local acc, ign, why = P.lastfm_result(T.json_decode(
  '{"scrobbles":{"@attr":{"accepted":0,"ignored":1},"scrobble":{"ignoredMessage":{"code":"3","#text":"Timestamp too old"}}}}'))
T.eq(acc, 0, "accepted 0")
T.eq(ign, 1, "ignored 1")
T.eq(why, "Timestamp too old", "ignore reason")

-- ---- streams described by a music package (vivi-media-meta)
respond = ok_api
P.on_media_meta("youtube-music", '{"items":[{"url":"https://music.youtube.com/watch?v=abc","title":"Song","artist":"Band","album":"LP","info":"YouTube Music"}]}')
T.props = { path = "https://music.youtube.com/watch?v=other", duration = 180, ["track-list"] = { { type = "video" } } }
local t = P.current_track()
T.eq(t, nil, "unknown stream: no tags")
T.props.path = "https://music.youtube.com/watch?v=abc"
t = P.current_track()
T.eq(t and t.meta.artist_name, "Band", "artist from the package")
T.eq(t and t.meta.additional_info.music_service_name, "YouTube Music", "service name")
T.eq(t and t.meta.additional_info.origin_url, "https://music.youtube.com/watch?v=abc", "origin url")

-- ---- love
reqs = {}
play(md)
reqs = {}
P.love()
local lf_love, lb_love
for _, r in ipairs(reqs) do
  if r.form and r.form.method == "track.love" then lf_love = r end
  if r.url:find("recording%-feedback") then lb_love = r end
end
T.ok(lf_love, "track.love sent")
T.eq(lf_love and lf_love.form.track, "Local Forecast", "loved title")
T.eq(lb_love and lb_love.json.recording_mbid, "8f3471b5-7e6a-48da-86a9-c1c07a0f47ae", "LB feedback by mbid")
T.eq(lb_love and lb_love.json.score, 1, "LB love score")
T.ok(T.calls[#T.calls][3]:find("loved on Last.fm, loved on ListenBrainz"), "love toast")

-- ---- status: validate-token, no secrets
reqs = {}
respond = function(r)
  if r.url:find("validate%-token") then return 200, '{"valid":true,"user_name":"demo"}' end
  return ok_api(r)
end
T.messages.status()
T.ok(reqs[1].url:find("/1/validate%-token$"), "status validates the token")
T.eq(reqs[1].body, nil, "validate is a GET")
local st = T.calls[#T.calls][3]
T.ok(st:find("ListenBrainz: ready %(demo%)"), "status names the LB account")
T.ok(st:find("Last.fm: connected %(demo%)"), "status names the Last.fm account")
no_leaks("everything")
T.eq(#T.osd, 0, "no mpv OSD messages (Vivi toasts only)")

-- ---- disconnect wipes the session file; a pasted session key moves to the file
P.lastfm_disconnect()
T.eq(io.open(P.SESSION, "r"), nil, "session file removed")
T.eq(P.state().session, nil, "disconnected")
T.calls = {}
P.opts.lastfm_session = "pasted-SECRET-4"
P.adopt()
T.eq(P.state().session.key, "pasted-SECRET-4", "pasted session adopted")
local cleared = false
for _, c in ipairs(T.calls) do
  if c[2] == "vivi-setting" and c[4] == "lastfm_session" and c[5] == "" then cleared = true end
end
T.ok(cleared, "the setting is cleared after the move")
P.load_session()
T.eq(P.state().session.key, "pasted-SECRET-4", "session survives a restart")
-- remote plain-http ListenBrainz server: the token is not sent
reqs = {}
P.opts.api = "http://lb.example"
P.flush(true)
P.enqueue("lb", { { listened_at = 9, track_metadata = { artist_name = "A", track_name = "B" } } })
P.flush(true)
T.eq(#reqs, 0, "no request to a plain-http remote server")
T.ok(P.state().err.lb:find("https"), "https error noted")
T.done("scrobbler")
