local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/youtube/youtube.lua", { pkgdir = "/pkg" })

-- URLs: only http(s), nothing that yt-dlp could read as an option.
T.eq(P.valid_url(" https://youtu.be/abc "), "https://youtu.be/abc", "trimmed URL")
T.eq(P.valid_url("--exec=rm -rf ~"), nil, "option injection refused")
T.eq(P.valid_url("file:///etc/passwd"), nil, "file URL refused")
T.eq(P.valid_url("https://x/a b"), nil, "white space refused")
P.o.url = "--exec=touch /tmp/pwned"
local u, why = P.current_url()
T.eq(u, nil, "bad URL setting not used")
T.ok(type(why) == "string" and why:find("not an http", 1, true), "bad URL setting explained")
P.o.url = ""
T.props.path = "https://www.youtube.com/watch?v=abc&list=PL1"
local cu, from_setting = P.current_url()
T.eq(cu, "https://www.youtube.com/watch?v=abc&list=PL1", "playing URL") T.eq(from_setting, false, "not from the setting")

-- Download arguments: the URL after "--", the playing video without its playlist.
local args = table.concat(P.download_args({ url = "https://y/v", no_playlist = true, audio = false }, "/dl", true, { dir = "/ff" }), " ")
T.ok(args:find("--no-playlist", 1, true), "playing video: no playlist")
T.ok(args:find(" -- https://y/v$"), "URL after --")
T.ok(args:find("--ffmpeg-location /ff", 1, true), "ffmpeg location")
T.ok(args:find("after_move:[vivi-file] %(filepath)s", 1, true), "prints the final path")
args = table.concat(P.download_args({ url = "https://y/pl", audio = true }, "/dl", false, nil), " ")
T.ok(args:find("--yes-playlist", 1, true), "URL setting: playlist")
T.ok(args:find("(audio).%(ext)s", 1, true), "audio file name")
T.ok(args:find("-f ba/b", 1, true), "audio format")

-- Progress lines and printed files.
local p = P.parse_progress("x\n[vivi] 1048576|4194304|12|65536.5|2|5|Some | Title\n")
T.eq(p.done, 1048576, "done bytes") T.eq(p.total, 4194304, "total bytes") T.eq(p.eta, 12, "eta")
T.eq(p.idx, 2, "playlist index") T.eq(p.n, 5, "entries") T.eq(p.title, "Some | Title", "title with a bar")
T.eq(P.progress_text(p), "Downloading 25% of 4 MB, ETA 0:12 (2/5) · Some | Title", "progress toast")
p = P.parse_progress("[vivi] 10|NA|NA|NA|NA|NA|NA")
T.eq(p.total, nil, "NA total") T.eq(p.title, nil, "NA title")
local files = P.printed_files("[download] x\n[vivi-file] /dl/A [1].mp4\n[vivi-file] /dl/B [2].mp4\n")
T.eq(#files, 2, "printed files") T.eq(files[2], "/dl/B [2].mp4", "last file")

-- Entries of flat yt-dlp output.
T.eq(P.entry_url({ ie_key = "Youtube", id = "dQw4w9WgXcQ", url = "dQw4w9WgXcQ" }), "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "id only")
T.eq(P.entry_url({ url = "javascript:alert(1)" }), nil, "non-http entry dropped")
T.eq(P.entry_url({ ie_key = "Youtube", id = "../../x" }), nil, "odd id dropped")
T.eq(P.thumb({ ie_key = "Youtube", id = "abc" }), "https://i.ytimg.com/vi/abc/mqdefault.jpg", "thumbnail by id")
T.eq(P.thumb({ thumbnails = { { url = "https://t/1.jpg", width = 120 }, { url = "https://t/2.jpg", width = 336 }, { url = "https://t/3.jpg", width = 1280 } } }),
  "https://t/2.jpg", "thumbnail up to 480 px")
T.ok(P.is_container({ ie_key = "YoutubeTab" }), "playlist row")
T.eq(P.fmt_dur(3725), "1:02:05", "hours") T.eq(P.fmt_dur(65), "1:05", "minutes") T.eq(P.fmt_dur(nil), "", "unknown")
T.ok(P.mpv_at_least("mpv v0.38.0", 38) and not P.mpv_at_least("mpv 0.37.1", 38), "mpv version")

-- Queueing sends the loadfile commands and the now-playing metadata.
T.calls = {}
T.props["mpv-version"] = "mpv v0.40.0"
local n = P.queue({ { ie_key = "Youtube", id = "a1", title = "One", channel = "Chan" }, { ie_key = "YoutubeTab", id = "PL", title = "List" },
  { ie_key = "Youtube", id = "b2", title = "Two" } }, "replace")
T.eq(n, 2, "videos queued, playlists skipped")
T.eq(T.calls[1][3], "replace", "first replaces") T.eq(T.calls[2][3], "append-play", "then appends")
local meta
for _, c in ipairs(T.calls) do if c[2] == "vivi-media-meta" then meta = T.json_decode(c[4]) end end
T.ok(meta and meta.items[1].artist == "Chan" and meta.items[1].kind == "video", "media meta")

-- The dialog (Vivi 0.13+, min_vivi): no OSD inside Vivi.
T.props["user-data/vivi/downloads"] = 1
T.calls, T.osd = {}, {}
P.open()
T.eq(#T.osd, 0, "no OSD inside Vivi")
local d = T.json_decode(T.calls[1][4])
T.eq(T.calls[1][2], "vivi-dialog", "dialog") T.ok(d.open and d.primary == "Play" and d.secondary == "Download 1080p", "dialog buttons")
T.eq(d.filters[1].name, "Quality", "quality filter") T.eq(d.filters[1].value, "Download quality: 1080p", "quality value")

-- Search: a query becomes ytsearch, a link is listed; the target always follows "--".
local seen = {}
T.set_async(function(t, cb)
  seen[#seen + 1] = t.args
  return #seen
end)
P.on_ui(T.json_encode({ event = "search", query = "lofi beats", args = {} }))
-- yt-dlp detection runs first (no system tools in tests): answer the managed download path.
T.set_async(nil)
T.ok(#seen >= 1, "search started a subprocess")

-- Sizes: the formats yt-dlp's default order picks (av01 over the HLS copies of the same
-- height), wide videos labelled by format_note (1920×804 is "1080p").
local f = io.open("tests/plugins/fixtures/youtube-spring-formats.json")
local spring = T.json_decode(f:read("*a")) f:close()
local sz, h, lbl = P.estimate(spring, "1080p", false, true)
T.eq(sz, 90648360, "1080p = 400 + 251, as yt-dlp picks") T.eq(h, 858, "height") T.eq(lbl, "1080p", "label of a wide video")
T.eq((P.estimate(spring, "720p", false, true)), 30607552, "720p = 398 + 251")
T.eq((P.estimate(spring, nil, true, true)), 7973641, "audio = 251 (not -drc)")
T.eq(P.has_single(spring, "720p"), false, "no single file with video and audio")
T.eq(P.has_single({ formats = { { vcodec = "avc1", acodec = "mp4a", height = 360 } } }, "720p"), true, "format 18")
T.eq(P.size_list(spring, true), "best 1080p ≈ 86 MB · 720p ≈ 29 MB · 480p ≈ 19 MB · audio ≈ 8 MB", "size list")

-- Thumbnails: Vivi decodes JPEG / PNG, YouTube's sized thumbnails are WebP.
T.eq(P.jpeg_thumb("https://i.ytimg.com/vi/x/hqdefault.jpg?sqp=abc&rs=def"), "https://i.ytimg.com/vi/x/hqdefault.jpg", "no sqp")
T.eq(P.jpeg_thumb("https://i.ytimg.com/vi_webp/x/maxresdefault.webp"), "https://i.ytimg.com/vi/x/maxresdefault.jpg", "vi_webp")
T.eq(P.thumb({ ie_key = "YoutubeTab", _type = "url", id = "PL1", thumbnails = { { url = "https://i.ytimg.com/vi/v/hqdefault.jpg?sqp=1", width = 336 } } }),
  "https://i.ytimg.com/vi/v/hqdefault.jpg", "playlist thumbnail as JPEG")

-- Detail pane and quality filter.
P.S.items = { { ie_key = "Youtube", id = "WhWc3b3KhnY", title = "Spring", channel = "Blender Studio", duration = 464, view_count = 10900000 } }
P.info_cache["https://www.youtube.com/watch?v=WhWc3b3KhnY"] = spring
T.calls = {}
P.on_ui(T.json_encode({ event = "select", args = { "0" } }))
local dd = T.json_decode(T.calls[#T.calls][4])
T.ok(dd.detail:find("1080p ≈ 86 MB   ← Download", 1, true), "sizes in the detail pane, chosen quality marked")
T.eq(dd.detail_cover, "https://i.ytimg.com/vi/WhWc3b3KhnY/mqdefault.jpg", "detail cover")
T.eq(dd.copy, "https://www.youtube.com/watch?v=WhWc3b3KhnY", "copy link")
T.calls = {}
P.on_ui(T.json_encode({ event = "filter", args = { "Quality", "720p" } }))
dd = T.json_decode(T.calls[#T.calls][4])
T.eq(P.o.quality, "720p", "quality from the dialog") T.eq(dd.secondary, "Download 720p", "button follows")
T.ok(dd.detail:find("720p ≈ 29 MB   ← Download", 1, true), "mark follows")
P.on_ui(T.json_encode({ event = "filter", args = { "Quality", "999p" } }))
T.eq(P.o.quality, "720p", "unknown quality ignored")
P.o.quality = "1080p"

-- Downloads panel reports: whole bytes (a fractional speed made Vivi drop the report).
T.calls = {}
P.report({ id = "j1" }, { state = "active", done = 10.5, total = 99.9, speed = 2810928.27, progress = 0.1 })
local rep = T.json_decode(T.calls[#T.calls][5])
T.eq(rep.speed, 2810928, "speed in whole bytes") T.eq(rep.done, 10, "done in whole bytes") T.eq(rep.total, 99, "total")

-- Alt+U: a URL in the clipboard becomes the URL setting; anything else is refused.
T.calls = {}
T.props["clipboard/text"] = "--exec=rm"
P.paste()
T.eq(P.o.url, "", "non-URL clipboard ignored")
T.props["clipboard/text"] = " https://www.youtube.com/watch?v=WhWc3b3KhnY "
P.paste()
T.eq(P.o.url, "https://www.youtube.com/watch?v=WhWc3b3KhnY", "clipboard URL taken")
local saved = false
for _, c in ipairs(T.calls) do if c[2] == "vivi-setting" and c[4] == "url" then saved = true end end
T.ok(saved, "URL saved in the settings")
P.o.url = ""
T.done("youtube")
