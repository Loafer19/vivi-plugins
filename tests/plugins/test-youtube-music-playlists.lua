-- YouTube Music: playlist downloads. Pure helpers (playlist text, source line, file
-- name choice, sync plan), then the flow on the fixtures: tracks already downloaded are
-- reused, the playlist is written in YouTube Music order (by the plugin on older Vivi,
-- through vivi-playlist on newer), a user's playlist of the same name is left alone,
-- and Sync rewrites the same file.
local real_getenv = os.getenv
os.getenv = function(k)
  if k == "VIVI_YTM_FIXTURES" then return "tests/plugins/fixtures/youtube-music" end
  return real_getenv(k)
end
local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/youtube-music/youtube-music.lua", {})
os.getenv = real_getenv
local mp, utils = package.loaded["mp"], package.loaded["mp.utils"]
-- Timers fire at once; directories are listed for real.
mp.add_timeout = function(_, f) f() return { kill = function() end } end
utils.readdir = function(dir)
  local out, h = {}, io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
  for l in h:lines() do out[#out + 1] = l end
  h:close()
  return out
end
local function read(p) local f = io.open(p, "rb") if not f then return nil end local s = f:read("*a") f:close() return s end
local function write(p, s) local f = assert(io.open(p, "wb")) f:write(s) f:close() end

-- pure helpers
T.eq(P.source_of({ kind = "playlist", browse_id = "VLPL1", playlist_id = "PL1" }), "VLPL1", "playlist source")
T.eq(P.source_of({ kind = "album", browse_id = "MPREb_1", playlist_id = "OLAK" }), "MPREb_1", "album source")
T.eq(P.source_of({ kind = "playlist", browse_id = "", playlist_id = "PL2" }), "VLPL2", "playlist id only")
T.eq(P.source_of({ kind = "song", video_id = "v" }), nil, "a song is not a list")
T.eq(P.source_of({ kind = "artist", browse_id = "UC1" }), nil, "nor an artist")
T.eq(P.source_url("VLLM"), "https://music.youtube.com/playlist?list=LM", "liked url")
T.eq(P.source_url("MPREb_1"), "https://music.youtube.com/browse/MPREb_1", "album url")
T.eq(P.safe_name(" a/b\\c\t "), "a_b_c", "safe name")
T.eq(P.safe_name(".."), "Playlist", "blank name")
T.eq(#P.safe_name(string.rep("é", 200)), 240, "120 characters, not bytes")
local text = P.m3u("Mix\nTape", "VLPL1", {
  { path = "/m/A/B/01 One.m4a", title = "A - One", duration = 200.4 },
  { path = "/m/A/B/Two.m4a" }, { path = "" } })
T.eq(text, "#EXTM3U\n#PLAYLIST:Mix Tape\n#VIVI-SOURCE:youtube-music VLPL1\n#VIVI-URL:https://music.youtube.com/playlist?list=PL1\n" ..
  "#EXTINF:200,A - One\n/m/A/B/01 One.m4a\n/m/A/B/Two.m4a\n", "playlist text (same as Vivi's)")
local pid, src = P.parse_source(text)
T.eq(pid .. " " .. src, "youtube-music VLPL1", "source line")
T.eq(P.parse_source("#EXTM3U\n/a.mp3\n#VIVI-SOURCE:youtube-music VL1\n"), nil, "only in the header")
T.eq(P.parse_source("#EXTM3U\n/a.mp3\n"), nil, "user playlist")
local files = { ["/d/Mix.m3u"] = "#EXTM3U\n/a.mp3\n" }
local rd = function(p) return files[p] end
T.eq(P.pick_path("/d", "Fresh", "VL1", { "Mix.m3u" }, rd), "/d/Fresh.m3u", "free name")
T.eq(P.pick_path("/d", "Mix", "VL1", { "Mix.m3u" }, rd), "/d/Mix (YouTube Music).m3u", "user playlist kept")
files["/d/Gym.m3u"] = P.m3u("Mix", "VL1", {})
T.eq(P.pick_path("/d", "Mix", "VL1", { "Mix.m3u", "Gym.m3u" }, rd), "/d/Gym.m3u", "own file, also renamed")
files["/d/Mix (YouTube Music).m3u"] = P.m3u("Mix", "VL9", {})
T.eq(P.pick_path("/d", "Mix", "VL2", { "Mix.m3u", "Gym.m3u", "Mix (YouTube Music).m3u" }, rd),
  "/d/Mix (YouTube Music 2).m3u", "another list of the same name")
local tr = function(id, extra) local t = { kind = "song", video_id = id, title = "T" .. id, artist = "A", duration = 60 } for k, v in pairs(extra or {}) do t[k] = v end return t end
local plan = P.plan({ tr("a"), tr("b"), { kind = "album", video_id = "" }, tr("a"), tr("c") },
  function(it) return it.video_id == "b" and "/m/b.m4a" or nil end)
T.eq(#plan.order, 3, "tracks once each, lists left out")
T.eq(plan.have.b, "/m/b.m4a", "on disk")
T.eq(#plan.todo, 2, "to download")
T.eq(plan.todo[1].video_id .. plan.todo[2].video_id, "ac", "in order")
T.eq(P.list_name({ tr("a", { album = "EP" }), tr("b", { album = "EP" }) }), "EP", "headerless list: its album")
T.eq(P.list_name({ tr("a", { album = "EP" }), tr("b", { album = "LP" }) }), "YouTube Music playlist", "mixed: default")
T.eq(P.list_name({}), "YouTube Music playlist", "empty")
local en = P.entries(plan.order, { a = "/m/a.m4a", b = "/m/b.m4a" })
T.eq(#en, 2, "missing tracks left out")
T.eq(en[1].path .. "|" .. en[1].title .. "|" .. en[1].duration, "/m/a.m4a|A - Ta|60", "entry")

-- flow: every track of the fixture playlist is on disk already
local DATA_HOME = real_getenv("XDG_DATA_HOME")
local DATA = DATA_HOME .. "/vivi/plugin-data/youtube-music"
local MUSIC = DATA_HOME .. "/Music"
local PLS = DATA_HOME .. "/vivi/playlists"
os.execute('mkdir -p "' .. DATA .. '" "' .. MUSIC .. '" "' .. PLS .. '"')
P.o.downloads, P.o.folder = true, MUSIC
local pl = P.parse_page(T.json_decode(read("tests/plugins/fixtures/youtube-music/browse_VLPLfakePlaylist0001.json")), "VLPLfakePlaylist0001")
local ids, index = {}, {}
for _, it in ipairs(pl.items) do
  if it.video_id ~= "" then
    ids[#ids + 1] = it.video_id
    local f = MUSIC .. "/" .. it.video_id .. ".m4a"
    write(f, "x")
    index[#index + 1] = it.video_id .. "\t" .. f
  end
end
T.ok(#ids >= 2, "fixture has tracks")
write(DATA .. "/downloads.tsv", table.concat(index, "\n") .. "\n")
-- The user already has a playlist called like it.
write(PLS .. "/" .. pl.title .. ".m3u", "#EXTM3U\n/mine.mp3\n")
mp.command_native = function(t) T.calls[#T.calls + 1] = t
  if t.args and t.args[1] == "yt-dlp" then return { status = 0, stdout = "2026.01.01" } end
  return { status = 1, stdout = "", stderr = "" } end
T.props["user-data/vivi/downloads"] = 1
P.sync_playlist("VLPLfakePlaylist0001", { title = "ignored when the page has one" })
local own = PLS .. "/" .. pl.title .. " (YouTube Music).m3u"
local got = read(own)
T.ok(got, "playlist written next to the user's")
T.eq(read(PLS .. "/" .. pl.title .. ".m3u"), "#EXTM3U\n/mine.mp3\n", "user's playlist untouched")
local paths = {}
for l in (got or ""):gmatch("[^\n]+") do if l:sub(1, 1) ~= "#" then paths[#paths + 1] = l end end
T.eq(#paths, #ids, "every track listed")
T.eq(paths[1], MUSIC .. "/" .. ids[1] .. ".m4a", "YouTube Music order")
T.ok(got:find("#VIVI-SOURCE:youtube-music VLPLfakePlaylist0001", 1, true), "source line written")
local rec = T.json_decode(read(DATA .. "/playlists.json"))
T.eq(rec.VLPLfakePlaylist0001.path, own, "recorded")
local last
for _, c in ipairs(T.calls) do if c[2] == "vivi-download" and c[4] == "playlist:VLPLfakePlaylist0001" then last = T.json_decode(c[5]) end end
T.eq(last and last.state, "done", "playlist row done")
T.eq(last and last.items_done, #ids, "12 / 40 counts")
T.eq(last and last.items_total, #ids, "total")

-- Sync on a newer Vivi: the host writes it (vivi-playlist), the file it reports is kept.
T.props["user-data/vivi/playlists"] = 1
os.remove(MUSIC .. "/" .. ids[2] .. ".m4a") -- this one is downloaded again
P.S.dl_job = {} -- a download is running: the new track waits in the queue
T.calls = {}
P.sync_playlist("VLPLfakePlaylist0001")
T.eq(#P.S.dl_queue, 1, "only the missing track queued")
T.eq(P.S.dl_queue[1].video_id, ids[2], "the missing one")
local child
for _, c in ipairs(T.calls) do if c[2] == "vivi-download" and c[4] == ids[2] then child = T.json_decode(c[5]) end end
T.eq(child and child.parent, "playlist:VLPLfakePlaylist0001", "track drawn under the playlist")
-- Cancel from the playlist row: the rest is written without it.
P.cancel_job("playlist:VLPLfakePlaylist0001")
local msg
for _, c in ipairs(T.calls) do if c[2] == "vivi-playlist" then msg = c end end
T.ok(msg, "vivi-playlist sent")
local body = T.json_decode(msg[4])
T.eq(msg[3], "youtube-music", "plugin id")
T.eq(body.source, "VLPLfakePlaylist0001", "source")
T.eq(body.name, pl.title, "keeps its name")
T.eq(#body.entries, #ids - 1, "cancelled track left out")
T.eq(body.url, "https://music.youtube.com/playlist?list=PLfakePlaylist0001", "url")
T.messages["playlist-saved"]("VLPLfakePlaylist0001", PLS .. "/Renamed.m3u")
rec = T.json_decode(read(DATA .. "/playlists.json"))
T.eq(rec.VLPLfakePlaylist0001.path, PLS .. "/Renamed.m3u", "path from Vivi")
for _, c in ipairs(T.calls) do if c[2] == "vivi-download" and c[4] == "playlist:VLPLfakePlaylist0001" then last = T.json_decode(c[5]) end end
T.eq(last.state, "failed", "one track missing: Retry")
T.eq(last.items_done, #ids - 1, "done count")
T.eq(P.S.pls.VLPLfakePlaylist0001, nil, "finished")
P.S.dl_job = nil

-- dialog: the playlist page offers Sync once it was downloaded
P.S.view, P.S.items, P.S.sel, P.S.title = { kind = "page", id = "VLPLfakePlaylist0001" }, pl.items, nil, pl.title
write(PLS .. "/Renamed.m3u", "#EXTM3U\n")
P.on_ui('{"event":"select","args":["0"]}')
P.S.sel = nil
local dlg
P.on_ui('{"event":"view","args":["list"]}')
T.calls = {}
P.on_ui('{"event":"close"}')
P.S.open = true
P.on_ui('{"event":"select","args":["99"]}')
for _, c in ipairs(T.calls) do if c[2] == "vivi-dialog" then dlg = T.json_decode(c[4]) end end
local acts = table.concat(dlg and dlg.actions or {}, ",")
T.ok(acts:find("Sync playlist", 1, true), "Sync on a downloaded playlist page: " .. acts)
T.done("youtube-music playlists")
