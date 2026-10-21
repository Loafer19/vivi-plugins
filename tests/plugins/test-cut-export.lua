local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/cut-export/cut-export.lua", { pkgdir = "/pkg" })
T.eq(P.parse_time("1:02:03.5"), 3723.5, "h:m:s")
T.eq(P.parse_time("62:03"), 3723, "m:s")
T.eq(P.parse_time("12.25"), 12.25, "seconds")
T.eq(P.parse_time(""), nil, "empty")
T.eq(P.parse_time("x:1"), nil, "invalid")
T.eq(P.fmt_time(62.5), "1:02.500", "fmt")
T.eq(P.fmt_time(3723.5), "1:02:03.500", "fmt hours")
-- Range: In/Out, then A-B loop, then the whole file; swapped points are ordered.
T.props.duration = 100
T.props["ab-loop-a"], T.props["ab-loop-b"] = 10, 20
local a, b, src = P.range()
T.eq(a, 10, "ab a") T.eq(b, 20, "ab b") T.eq(src, "A-B loop", "ab source")
P.o["in"], P.o.out = "0:50", "0:40"
a, b, src = P.range()
T.eq(a, 40, "swapped a") T.eq(b, 50, "swapped b") T.eq(src, "In/Out", "explicit")
P.o["in"], P.o.out = "5", ""
a, b = P.range()
T.eq(b, 100, "out defaults to duration")
T.eq(P.out_path("/v/movie.mkv", 62.5, 70, "", false, false), "/v/movie [1m02.5s-1m10.0s].mkv", "copy name")
T.eq(P.out_path("/v/song.flac", 0, 30, "/out", true, true), "/out/song [0m00.0s-0m30.0s].m4a", "re-encode audio")
local args = table.concat(P.ffmpeg_args("ffmpeg", "in.mkv", 1, 3.5, "o.mkv", false), " ")
T.ok(args:find("-ss 1.000 -i in.mkv -t 2.500 -map 0 -dn -ignore_unknown -c copy", 1, true), "copy args")
T.ok(args:find(" -n ", 1, true) and not args:find(" -y ", 1, true), "never overwrites")
args = table.concat(P.ffmpeg_args("ffmpeg", "in.mkv", 1, 3.5, "o.mp4", true, false), " ")
T.ok(args:find("-c:v libx264", 1, true), "x264 args")
args = table.concat(P.ffmpeg_args("ffmpeg", "in.flac", 1, 3.5, "o.m4a", true, true), " ")
T.ok(args:find("-vn -c:a aac", 1, true), "audio args")
-- Same pinned media ffmpeg build as Subtitle Auto-Sync (no other ffmpeg flavor).
local f = io.open("plugins/subtitle-sync/subtitle-sync.lua")
local ss = f:read("*a")
f:close()
T.ok(ss:find(P.FF_MEDIA.tag, 1, true), "same ffmpeg tag")
for k, v in pairs(P.FF_MEDIA.sha) do T.ok(ss:find(k .. "\"] = \"" .. v, 1, true), "same sha " .. k) end
-- Audio track copy: the playing track by its ff-index, an extension of its own type.
args = table.concat(P.ffmpeg_args("ffmpeg", "in.mkv", 1, 3.5, "o.opus", "audio", false, nil, 2, "/p.txt"), " ")
T.ok(args:find("-progress /p.txt -nostats", 1, true), "progress file")
T.ok(args:find("-map 0:2 -vn -sn -dn -c copy", 1, true), "audio track copy")
T.ok(args:find("-ss 0.000 -i in.mkv -ss 1.000 -t 2.500", 1, true), "audio: exact output seek")
args = table.concat(P.ffmpeg_args("ffmpeg", "in.mkv", 100, 110, "o.m4a", "audio", false, nil, 1), " ")
T.ok(args:find("-ss 85.000 -i in.mkv -ss 15.000 -t 10.000", 1, true), "audio: coarse input seek")
T.eq(P.audio_ext("aac"), "m4a", "aac ext") T.eq(P.audio_ext("opus"), "opus", "opus ext")
T.eq(P.audio_ext("pcm_s16le"), "wav", "pcm ext") T.eq(P.audio_ext("weird"), "mka", "fallback ext")
T.eq(P.out_path("/v/concert.mkv", 0, 30, "", false, false, "opus"), "/v/concert [0m00.0s-0m30.0s].opus", "audio name")
-- Never replaces a file.
local taken = { ["/v/a [x].mkv"] = true, ["/v/a [x] (2).mkv"] = true }
T.eq(P.unique("/v/a [x].mkv", function(p) return taken[p] end), "/v/a [x] (3).mkv", "unique name")
T.eq(P.unique("/v/b.mkv", function(p) return taken[p] end), "/v/b.mkv", "free name kept")
-- Encoder fallback.
T.eq(P.pick_encoder(" V....D libx264              libx264 H.264\n V.S... mpeg4   MPEG-4")[1], "libx264", "x264 first")
T.eq(P.pick_encoder(" V....D libx264rgb   libx264 RGB\n V.S... mpeg4                MPEG-4 part 2")[1], "mpeg4", "x264rgb is not x264")
T.eq(P.pick_encoder(" A....D aac  AAC"), nil, "no video encoder")
args = table.concat(P.ffmpeg_args("ffmpeg", "in.mkv", 0, 2, "o.mp4", "reencode", false, P.pick_encoder(" V.S... mpeg4  MPEG-4")), " ")
T.ok(args:find("-c:v mpeg4 -q:v 2", 1, true), "mpeg4 args")
T.eq(P.progress_seconds("out_time_us=1500000\nprogress=continue\nout_time_us=2500000\n"), 2.5, "progress seconds")
T.eq(P.progress_seconds("progress=continue"), nil, "no progress yet")
-- Video tracks decide, not the selected one.
T.props["track-list"] = { { type = "video", id = 1 }, { type = "audio", id = 1 } }
T.ok(not P.is_audio_only(), "video with the video track off is video")
T.props["track-list"] = { { type = "video", id = 1, albumart = true }, { type = "audio", id = 1 } }
T.ok(P.is_audio_only(), "cover art is audio")
-- Inside Vivi: toasts only, no mpv OSD.
T.osd = {}
T.props.path = "https://example.com/x"
P.export(false)
T.eq(#T.osd, 0, "no OSD inside Vivi")
local toast
for _, c in ipairs(T.calls) do if c[2] == "vivi-toast" then toast = c[3] end end
T.eq(toast, "Cut & Export works on local files only", "toast")
-- Downloads panel rows ask Vivi to say "Export finished" (older Vivi ignores the field).
T.calls = {}
P.report("7", { state = "done" })
T.eq(#T.calls, 0, "no panel: no report")
T.props["user-data/vivi/downloads"] = 1
P.report("7", { state = "done", title = "a [x].mp4" })
local c = T.calls[1]
T.eq(c[2], "vivi-download", "panel report")
T.eq(c[4], "7", "job id")
local r = require("mp.utils").parse_json(c[5])
T.eq(r.done_title, "Export finished", "done_title")
T.eq(r.state, "done", "state kept")
T.done("cut-export")
