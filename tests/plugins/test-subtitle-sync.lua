local T = dofile("tests/plugins/stub.lua")
-- run.sh points XDG_DATA_HOME at a temporary folder (offsets.json is written there).
local P = T.load("plugins/subtitle-sync/subtitle-sync.lua")
T.eq(P.out_path("/m/movie.en.srt"), "/m/movie.en.synced.srt", "synced name")
T.eq(P.out_path("/m/movie.en.synced.srt"), "/m/movie.en.synced.srt", "no double suffix")
T.eq(P.out_path("/m/noext"), "/m/noext.synced.srt", "no extension")
T.eq(P.tmp_path("/m/movie.en.synced.ass"), "/m/movie.en.synced.syncing.ass", "temp output keeps the extension")
T.eq(P.round(0.30000000004), 0.3, "round")
T.eq(P.fmt_offset(0.1), "+0.1 s", "offset label")
T.eq(P.fmt_offset(-1.25), "-1.25 s", "offset label, two decimals")
T.eq(P.fmt_offset(2), "+2.0 s", "offset label, whole seconds")

-- Re-sync starts from the original when it exists next to the synced copy.
local dir = os.getenv("XDG_DATA_HOME")
local orig, synced = dir .. "/m.en.srt", dir .. "/m.en.synced.srt"
local function write(p, s) local f = assert(io.open(p, "w")) f:write(s) f:close() end
write(synced, "1\n00:00:03,500 --> 00:00:05,000\nHi\n")
T.eq(P.source_of(synced), synced, "synced copy without original is its own source")
write(orig, "1\n00:00:01,000 --> 00:00:02,500\nHi\n")
T.eq(P.source_of(synced), orig, "original is the source of its synced copy")
T.eq(P.source_of(orig), orig, "original is its own source")

-- First cue of SRT, WebVTT (with and without hours) and ASS files.
T.eq(P.first_cue(orig), 1, "srt first cue")
T.eq(P.first_cue(synced), 3.5, "srt first cue (synced)")
write(dir .. "/a.vtt", "WEBVTT\n\n01:02.250 --> 01:04.000\nHi\n")
T.eq(P.first_cue(dir .. "/a.vtt"), 62.25, "vtt first cue without hours")
write(dir .. "/b.vtt", "WEBVTT\n\n00:01:02.250 --> 00:01:04.000\nHi\n")
T.eq(P.first_cue(dir .. "/b.vtt"), 62.25, "vtt first cue with hours")
write(dir .. "/c.ass", "[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:12.34,0:00:14.00,Default,,0,0,0,,Hi\n")
T.eq(P.first_cue(dir .. "/c.ass"), 12.34, "ass first cue")
T.eq(P.first_cue(dir .. "/missing.srt"), nil, "missing file")
-- Median shift: one cue moved differently does not decide it.
write(dir .. "/in.srt", "1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:05,000 --> 00:00:06,000\nB\n\n3\n00:00:09,000 --> 00:00:10,000\nC\n")
write(dir .. "/out.srt", "1\n00:00:04,000 --> 00:00:05,000\nA\n\n2\n00:00:02,500 --> 00:00:03,500\nB\n\n3\n00:00:06,500 --> 00:00:07,500\nC\n")
T.eq(P.median_shift(dir .. "/in.srt", dir .. "/out.srt"), -2.5, "median shift")
T.eq(P.median_shift(dir .. "/in.srt", orig), nil, "different cue counts")

-- Reference track: the secondary subtitle first, else embedded text tracks, never the
-- current one, its synced copy or a bitmap track.
local cur = { id = 3, type = "sub", external = true, ["external-filename"] = orig, selected = true }
T.props["track-list"] = {
  { id = 1, type = "sub", codec = "hdmv_pgs_subtitle", lang = "eng" },
  { id = 2, type = "sub", codec = "subrip", lang = "ukr", forced = true },
  cur,
  { id = 4, type = "sub", external = true, ["external-filename"] = synced, codec = "subrip" },
  { id = 5, type = "sub", codec = "ass", lang = "deu" },
  { id = 6, type = "sub", external = true, ["external-filename"] = dir .. "/other.srt", codec = "subrip" },
}
T.eq(P.reference_track(cur).id, 5, "embedded, not forced, not bitmap")
T.props["secondary-sid"] = "6"
T.eq(P.reference_track(cur).id, 6, "secondary subtitle wins")
T.props["secondary-sid"] = "4"
T.eq(P.reference_track(cur).id, 5, "the synced copy of the current one is no reference")
T.props["secondary-sid"] = "no"
T.props["track-list"] = { cur, { id = 1, type = "sub", codec = "dvd_subtitle" } }
T.eq(P.reference_track(cur), nil, "bitmap only: none")

-- Loading the synced copy replaces an already loaded one and keeps name and language.
T.calls = {}
T.props["track-list"] = { { id = 3, type = "sub", external = true, ["external-filename"] = orig, title = "English", lang = "en" },
  { id = 4, type = "sub", external = true, ["external-filename"] = synced } }
P.load_synced(synced, T.props["track-list"][1])
T.eq(T.calls[1][1], "sub-remove", "old copy removed")
T.eq(T.calls[1][2], "4", "old copy id")
T.eq(T.calls[2][1], "sub-add", "copy added")
T.eq(T.calls[2][4], "English (synced)", "title")
T.eq(T.calls[2][5], "en", "language")
T.calls = {}
P.load_synced(synced, { id = 3, ["external-filename"] = orig, title = "en.srt", lang = "en" })
T.eq(T.calls[#T.calls][4], "Synced", "mpv's automatic title is not kept")
P.load_synced(synced, { id = 4, ["external-filename"] = synced, title = "Synced", lang = "en" })
T.eq(T.calls[#T.calls][4], "Synced", "no \"Synced (synced)\"")
P.load_synced(synced, { id = 4, ["external-filename"] = synced, title = "English (synced)" })
T.eq(T.calls[#T.calls][4], "English (synced)", "suffix once")

-- A file opening with the original selected switches to its synced copy, once.
T.calls = {}
T.props.path = "/v/movie.mkv"
T.props["track-list"] = { { id = 1, type = "sub", external = true, selected = true, ["external-filename"] = orig } }
P.prefer_synced()
T.eq(T.calls[1] and T.calls[1][1], "sub-add", "synced copy selected on open")
local n = #T.calls
P.prefer_synced()
T.eq(#T.calls, n, "only once per file")
P.o.prefer = false
T.props.path = "/v/other.mkv"
P.prefer_synced()
T.eq(#T.calls, n, "setting off")
P.o.prefer = true

-- Toasts: Vivi's toast only when Vivi passed pkgdir (0.9.1+), mpv OSD as well otherwise.
T.osd = {}
P.toast("hello")
T.eq(#T.osd, 1, "OSD without Vivi")
P.o.pkgdir = "/pkg"
T.osd, T.calls = {}, {}
P.toast("hello")
T.eq(#T.osd, 0, "no OSD in Vivi")
T.eq(T.calls[1][2], "vivi-toast", "Vivi toast")
P.o.pkgdir = ""

-- Nudges go through sub-delay and are saved per file.
T.props.path = "tests/plugins/stub.lua"
T.props["sub-delay"] = 0
P.nudge(1)()
P.nudge(1)()
T.eq(T.props["sub-delay"], 0.2, "two steps later")
P.nudge(-10)()
T.eq(T.props["sub-delay"], -0.8, "one second earlier")
T.ok(P.OFFSETS:find("subtitle-sync", 1, true), "offsets file path")
-- With Vivi 0.11+ (script-opt vivi-sub-offsets=1) the keys hand the offset to Vivi.
T.opts = { ["vivi-sub-offsets"] = "1" }
T.calls = {}
T.props["sub-delay"] = 0.5
P.nudge(1)()
local last = T.calls[#T.calls]
T.eq(last and last[2], "vivi-sub-offset", "offset message to Vivi")
T.eq(last and last[3], "set:0.6", "absolute offset sent")
T.eq(T.props["sub-delay"], 0.5, "Vivi sets sub-delay itself")
T.opts = nil
T.ok(T.bindings["Alt+Y"], "Alt+Shift+Y bound")
T.ok(T.messages["sync-ref"], "sync-ref message")
T.ok(T.bindings["Alt+z"] and T.bindings["Alt+X"], "older Vivi: offset keys bound")

-- Vivi 0.13+ (user-data/vivi/sub-offset = 1): no offset keys, no offsets.json; the old
-- file is removed once Vivi wrote its import marker, else Vivi is asked to import it.
local pd = P.OFFSETS:match("^(.*)/[^/]*$")
os.execute("mkdir -p '" .. pd .. "'")
write(P.OFFSETS, '{"/v/a.mkv|5": 1.5}')
write(P.IMPORTED, "1 subtitle offset(s) imported\n")
T.next_props = { ["user-data/vivi/sub-offset"] = 1 }
local C = T.load("plugins/subtitle-sync/subtitle-sync.lua")
T.ok(C.core_offset(), "core flag seen")
T.eq(T.bindings["Alt+z"], nil, "Alt+z left to Vivi")
T.eq(T.bindings["Alt+X"], nil, "Alt+Shift+X left to Vivi")
T.ok(T.bindings["Alt+BS"], "Alt+Backspace still resets (through Vivi)")
T.eq(io.open(P.OFFSETS, "r"), nil, "offsets.json removed after the handover")
write(P.OFFSETS, '{"/v/a.mkv|5": 1.5}')
os.remove(P.IMPORTED)
T.calls = {}
C.hand_over()
T.eq(T.calls[1] and T.calls[1][2], "vivi-sub-offset-import", "import asked without marker")
T.ok(io.open(P.OFFSETS, "r"), "kept until Vivi imported it")
T.calls = {}
T.props["sub-delay"] = 0.5
C.nudge(1)()
T.eq(T.calls[#T.calls][3], "set:0.6", "nudge goes to Vivi")
T.eq(T.props["sub-delay"], 0.5, "Vivi sets sub-delay itself")
os.remove(P.OFFSETS)
T.done("subtitle-sync")
