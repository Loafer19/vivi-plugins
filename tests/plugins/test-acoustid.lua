local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/acoustid/acoustid.lua", { pkgdir = "/pkg" })
local fp = P.parse_fpcalc('{"duration": 212.53, "fingerprint": "AQAAT0mUaEkSRZEGAA"}')
T.eq(fp.duration, 213, "rounded duration")
T.eq(fp.fingerprint, "AQAAT0mUaEkSRZEGAA", "fingerprint")
T.eq(P.parse_fpcalc("ERROR: x"), nil, "bad output")
T.eq(P.parse_fpcalc('{"duration": 3, "fingerprint": ""}'), nil, "empty fingerprint")
T.eq(P.lookup_body("k e+y", fp), "client=k%20e%2By&meta=recordings+releasegroups&duration=213&fingerprint=AQAAT0mUaEkSRZEGAA", "form body")
local answer = { status = "ok", results = {
  { score = 0.62, recordings = { { id = "r0", title = "Other", artists = { { name = "X" } } } } },
  { score = 0.97, recordings = {
    { id = "r1", title = "Song", duration = 201, artists = { { name = "A" }, { name = "B" } },
      releasegroups = { { id = "g1", title = "Single", type = "Single" }, { id = "g2", title = "LP", type = "Album" } } },
    { id = "r2" } } } } }
local top, n, best = P.best(answer)
T.eq(top, "A, B - Song (97%)", "best match label (highest score, not first)")
T.eq(n, 3, "recording count")
T.eq(best.album, "LP", "album release group preferred")
T.eq(best.mbid, "r1", "mbid")
local _, _, b2 = P.best({ results = { { score = 0.9, recordings = { { id = "x", title = "T",
  artists = { { name = "A", joinphrase = " feat. " }, { name = "B" } } } } } } })
T.eq(b2.artist, "A feat. B", "join phrases")
T.ok(P.managed_path("linux-x86_64"):find("chromaprint-fpcalc-1.6.2-linux-x86_64", 1, true), "managed path")
T.eq(P.managed_path("plan9-mips"), nil, "unknown platform")

-- slim keeps what the Auto-tagger reads (results[].score, recordings[].id) and drops the rest.
local s = P.slim({ status = "ok", results = { { id = "a", score = 0.9, junk = 1,
  recordings = { { id = "r", title = "T", sources = 5, artists = { { id = "ar", name = "N" } } } } } } })
T.eq(s.results[1].recordings[1].id, "r", "slim recording id")
T.eq(s.results[1].junk, nil, "slim drops extras")
T.eq(s.results[1].recordings[1].sources, nil, "slim drops recording extras")

-- Paths handed to fpcalc never look like options.
T.eq(P.safe_path("/m/a.flac", "/x"), "/m/a.flac", "absolute path kept")
T.eq(P.safe_path("-a.flac", "/home/u"), "/home/u/-a.flac", "relative path made absolute")
T.eq(P.safe_path("-a.flac", ""), "./-a.flac", "relative path without cwd")

-- API key: the secrets file (Vivi 0.13+) wins; the script-opt is the fallback.
T.eq(P.api_key(), "", "no key")
P.o["api-key"] = " opt key "
T.eq(P.api_key(), "optkey", "script-opt key, white space removed")
local dir = os.getenv("XDG_DATA_HOME") .. "/vivi/plugin-data/acoustid"
os.execute("mkdir -p '" .. dir .. "'")
local sf = dir .. "/vivi-secrets.json"
local f = io.open(sf, "w") f:write('{"api-key": "file-key"}') f:close()
P.o.secrets = "3:" .. sf
T.ok(P.read_secrets(), "secrets file read")
T.eq(P.api_key(), "file-key", "secrets file wins")
-- Migration: Vivi writes "" when it has no key; a key from mpv's own acoustid.conf stays usable.
f = io.open(sf, "w") f:write('{"api-key": ""}') f:close()
P.read_secrets()
T.eq(P.api_key(), "optkey", "empty secrets file falls back to the script-opt")
f = io.open("/tmp/vivi-secrets.json", "w") f:write('{"api-key": "evil"}') f:close()
P.o.secrets = "4:/tmp/vivi-secrets.json"
T.eq(P.read_secrets(), false, "a file elsewhere is not read")
P.o.secrets = ""
T.eq(P.read_secrets(), false, "no secrets option (older Vivi)")
os.remove("/tmp/vivi-secrets.json")
local mf = io.open("plugins/acoustid/manifest.toml"):read("*a")
T.ok(mf:find("\nsecrets_file = true", 1, true), "manifest asks for the secrets file")

-- Automatic identification only for local songs Vivi has no metadata for.
local song = "plugins/acoustid/acoustid.lua" -- any existing file
T.ok(P.untagged_song({ path = song, kind = "music", source = "file" }, song), "untagged song")
T.ok(not P.untagged_song({ path = song, kind = "music", source = "tags" }, song), "tagged song")
T.ok(not P.untagged_song({ path = song, kind = "video", source = "file" }, song), "video")
T.ok(not P.untagged_song({ path = "/other", kind = "music", source = "file" }, song), "stale track")
T.ok(not P.untagged_song({ path = "https://x/y.mp3", kind = "music", source = "file" }, "https://x/y.mp3"), "stream")
local m = P.meta_for("/m/a.flac", best)
T.eq(m.url, "/m/a.flac", "meta url") T.eq(m.title, "Song", "meta title") T.eq(m.artist, "A, B", "meta artist")
T.eq(m.mbid, "r1", "meta mbid") T.eq(m.duration, 201, "meta duration") T.eq(m.kind, "music", "meta kind")

-- Cached answers skip fpcalc and the network.
local cache = P.load_cache()
cache[P.file_key(song)] = { t = os.time(), answer = answer }
T.calls = {}
local got
P.lookup(song, "k", function(v) got = v end)
T.eq(got, answer, "cache hit")
T.eq(#T.calls, 0, "no subprocess on a cache hit")

-- Auto mode: a confident match becomes now-playing metadata, once per file.
P.o.auto = true
T.props.path = song
P.on_now_playing(nil, { path = song, kind = "music", source = "file" })
local sent
for _, c in ipairs(T.calls) do if c[2] == "vivi-media-meta" then sent = T.json_decode(c[4]) end end
T.ok(sent and sent.title == "Song" and sent.url == song, "media meta sent")
T.calls = {}
P.on_now_playing(nil, { path = song, kind = "music", source = "file" })
T.eq(#T.calls, 0, "not again for the same file")

-- Toasts are Vivi toasts inside Vivi (no mpv OSD).
T.osd = {}
T.props.path = nil
P.identify()
T.eq(#T.osd, 0, "no OSD inside Vivi")
T.done("acoustid")
