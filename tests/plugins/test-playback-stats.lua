local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/playback-stats/playback-stats.lua", { days = 7 })

-- Fixed clock: 2026-10-19 12:00 local time, and a controllable monotonic time.
local NOW = os.time({ year = 2026, month = 10, day = 19, hour = 12 })
local now, t = NOW, 100
P.set_clock(function() return now end)
P.set_now(function() return t end)
local function secs(kind, who, title)
  return P.rows()[table.concat({ os.date("%Y-%m-%d", now), kind, who, title }, "\t")] or 0
end

-- show names from episode file names
T.eq(P.show_name("The Expanse S02E05 Home"), "The Expanse", "S01E02")
T.eq(P.show_name("The.Expanse.S02.E05.1080p"), "The Expanse", "dotted, S02.E05")
T.eq(P.show_name("Dark_1x03_Past"), "Dark", "1x03")
T.eq(P.show_name("Big Buck Bunny"), nil, "not an episode")
T.eq(P.show_name("S01E01"), nil, "no show before it")
T.eq(P.hms(59.6), "1m 00s", "rounds")
T.eq(P.hms(3725), "1h 02m", "hours")

-- pause accounting: 7 s play, 8 s pause, 3 s play -> exactly 10 s
T.props["core-idle"] = false
T.props["idle-active"] = false
P.set_current({ "video", "My Show", "Pilot" })
P.tick() -- file loaded: starts counting
t = t + 5 P.tick() -- periodic tick
t = t + 2 T.props["core-idle"] = true P.tick() -- pause (observer)
t = t + 5 P.tick() -- periodic tick while paused
t = t + 3 T.props["core-idle"] = false P.tick() -- unpause
t = t + 3 P.tick()
T.eq(secs("video", "My Show", "Pilot"), 10, "pause neither loses nor adds time")

-- buffering/seeking (core-idle while not paused) is not counted either
T.props["core-idle"] = true P.tick()
t = t + 4 T.props["core-idle"] = false P.tick()
T.eq(secs("video", "My Show", "Pilot"), 10, "buffering not counted")

-- gaps (suspend, stalled timer) are capped at 10 s
t = t + 600 P.tick()
T.eq(secs("video", "My Show", "Pilot"), 20, "gap capped")

-- Record statistics off: nothing counted, and the seconds before switching still count
t = t + 2 P.set_record(false)
T.eq(secs("video", "My Show", "Pilot"), 22, "time before pausing recording counts")
T.eq(T.osd[#T.osd], "Playback statistics: paused (not recording)", "record off toast")
t = t + 5 P.tick()
T.eq(secs("video", "My Show", "Pilot"), 22, "not recording")
P.set_record(true)
t = t + 5 P.tick()
T.eq(secs("video", "My Show", "Pilot"), 27, "recording again")
-- palette "pause / resume recording": switches and saves the setting in Vivi
T.calls = {}
P.toggle_record()
T.ok(not P.recording(), "toggled off")
local saved
for _, c in ipairs(T.calls) do if c[2] == "vivi-setting" then saved = table.concat(c, " ", 3) end end
T.eq(saved, "playback-stats record false", "saved as the setting")
t = t + 5 P.tick()
T.eq(secs("video", "My Show", "Pilot"), 27, "toggled off: not counted")
P.toggle_record()
T.ok(P.recording(), "toggled on")
T.eq(P.opts.record, true, "option follows")

-- audio, older days
P.set_current({ "audio", "Artist A", "Song" })
P.tick()
t = t + 9 P.tick()
local rows = P.rows()
local function put(daysago, kind, who, title, s)
  P.rows()[table.concat({ os.date("%Y-%m-%d", NOW - daysago * 86400), kind, who, title }, "\t")] = s
end
put(1, "audio", "Artist B", "x", 3600)
put(2, "audio", "Artist A", "y", 120)
put(3, "video", "", "Movie", 600)  -- no show: not in the top list
put(5, "audio", "Artist B", "z", 30) -- under a minute: breaks the streak
put(20, "audio", "Artist C", "old", 7200)
put(200, "video", "Old Show", "e", 100)

local S = P.summary()
T.eq(S.days, 7, "days")
T.eq(math.floor(S.total + 0.5), 27 + 9 + 3600 + 120 + 600 + 30, "7-day total")
T.eq(math.floor(S.periods[1][2] + 0.5), 36, "today")
T.eq(math.floor(S.periods[3][2] + 0.5), 27 + 9 + 3600 + 120 + 600 + 30 + 7200, "30 days")
T.eq(math.floor(S.periods[4][2] + 0.5), 27 + 9 + 3600 + 120 + 600 + 30 + 7200 + 100, "365 days")
T.eq(S.top[1][1], "Artist B", "top artist")
T.eq(S.top[2][1], "Artist A", "second")
T.eq(S.top[3][1], "My Show", "show counted")
T.eq(#S.top, 3, "only named artists / shows")
T.eq(#S.bars, 7, "7 bars")
T.eq(S.bars[7][1], "2026-10-19", "last bar is today")
T.eq(S.max, 3600, "bars scaled to the shown days")
T.eq(S.streak, 3, "today under a minute: streak from yesterday back to 3 days ago")
local L = P.summary_lines(S)
T.ok(L[1]:find("^Last 7 days: 1h 13m"), "header line")
T.ok(L[2]:find("Today 0m 36s · 7 days 1h 13m · 30 days 3h 13m · 365 days 3h 14m · 3-day streak", 1, true), "periods line")
T.eq(P.toast_line(S), "Today 0m 36s · last 7 days 1h 13m · top: Artist B", "one-line toast")

-- streak survives a morning with nothing played yet
local pd = { [os.date("%Y-%m-%d", NOW - 86400)] = 100, [os.date("%Y-%m-%d", NOW - 2 * 86400)] = 100 }
T.eq(P.streak(pd, NOW), 2, "streak up to yesterday")
T.eq(P.streak({}, NOW), 0, "no streak")

-- 30 days: bars still the last 7, scaled to them; 20 days ago counted in the total
P.opts.days = 30
S = P.summary()
T.eq(#S.bars, 7, "still 7 bars")
T.eq(S.max, 3600, "the 20-days-ago day does not shrink the bars")
T.ok(P.summary_lines(S)[1]:find("^Last 30 days: 3h 13m"), "30-day header")
P.opts.days = 7

-- show: one-line toast (not the whole panel) and the panel
T.calls = {}
P.show()
local toasts = {}
for _, c in ipairs(T.calls) do if c[2] == "vivi-toast" then toasts[#toasts + 1] = c[3] end end
T.eq(#toasts, 1, "one toast")
T.ok(toasts[1] and not toasts[1]:find("\n"), "toast is one line")

-- native view (Vivi with the plugin host API): Alt+S opens the plugin dialog
local function last(name)
  for i = #T.calls, 1, -1 do local c = T.calls[i] if c[2] == name then return c end end
end
local function dialog() local c = last("vivi-dialog") return c and T.json_decode(c[4]) end
T.props["user-data/vivi/playlists"] = 1
T.calls = {}
P.show()
local D = dialog()
T.ok(D and D.open, "dialog opened")
T.eq(last("vivi-dialog")[3], "playback-stats", "dialog owner")
T.eq(D.title, "Playback statistics", "title")
T.eq(D.chip, "7 days", "period chip follows the setting")
T.eq(#D.chips, 4, "four periods")
T.eq(D.rows[1].title, "Artist B", "top row")
T.eq(D.rows[1].badge, "#1", "rank badge")
T.eq(D.rows[1].dur, "1h 00m", "row time")
T.eq(D.rows[2].dur, "2m", "short row time")
T.eq(D.rows[1].sub, "artist · 2 titles", "row sub")
T.eq(D.rows[3].title, "My Show", "show row")
T.eq(D.rows[3].sub, "show · 1 title", "show sub")
T.ok(D.detail:find("Last 7 days: 1h 13m", 1, true), "detail total")
T.ok(D.detail:find("Streak: 3 days", 1, true), "detail streak")
T.ok(D.detail:find("365 days: 3h 14m", 1, true), "detail 365")
T.eq(D.primary, "Refresh", "primary")
T.eq(D.actions[1], "Export CSV", "export action")
T.eq(D.secondary, "Pause recording", "secondary")
T.ok(last("vivi-toast"), "toast too")
-- chips, grouping, search, selection
P.on_ui('{"event":"chip","args":["Today"]}')
D = dialog()
T.eq(D.open, nil, "updates do not reopen")
T.eq(D.chip, "Today", "today chip")
T.eq(#D.rows, 2, "today: My Show and Artist A")
P.on_ui('{"event":"chip","args":["30 days"]}')
T.eq(dialog().rows[1].title, "Artist C", "30 days: the 20-days-ago artist leads")
P.on_ui('{"event":"filter","args":["Group by\31Days"]}')
D = dialog()
T.eq(D.rows[1].title, os.date("%a %d %b", NOW), "days: newest first")
T.ok(D.rows[1].sub:find("▬"), "day bar")
P.on_ui('{"event":"filter","args":["Group by","Titles"]}')
D = dialog()
T.eq(D.rows[1].title, "old", "titles grouping")
T.eq(D.rows[1].sub, "Artist C", "title sub is the artist")
P.on_ui('{"event":"search","query":"artist b"}')
D = dialog()
T.eq(#D.rows, 2, "filtered by artist")
P.on_ui('{"event":"search","query":"zzz"}')
T.ok(dialog().status:find("Nothing matches", 1, true), "no match status")
P.on_ui('{"event":"search","query":""}')
P.on_ui('{"event":"filter","args":["Group by","Artists & shows"]}')
P.on_ui('{"event":"select","args":["0"]}')
D = dialog()
T.ok(D.detail:find("^Artist C\n2h 00m", 1), "selected row detail")
T.ok(D.rows[1].selected, "row selected")
T.eq(dialog().primary, "Overview", "primary goes back to the overview")
P.on_ui('{"event":"primary","args":["0"]}')
T.eq(P.view.sel, nil, "overview")
P.on_ui('{"event":"primary","args":["1"]}')
T.eq(P.view.sel, 2, "row play button selects the row")
P.on_ui('{"event":"act:Queue","args":["1"]}')
T.eq(P.view.sel, 2, "queue button ignored")
P.on_ui('{"event":"primary","args":["1"]}')
T.eq(P.view.sel, nil, "again: overview")
local csv = P.file:gsub("stats%.tsv$", "test-export.csv")
os.execute("mkdir -p '" .. P.file:match("^(.*)/") .. "'")
P.set_export_path(csv)
P.on_ui('{"event":"act:Export CSV","args":["-1"]}')
local cf = io.open(csv)
T.ok(cf and cf:read("*l") == "date,seconds,kind,artist_or_show,title", "csv header")
if cf then cf:close() os.remove(csv) end
T.ok(T.osd[#T.osd]:find("^Statistics exported to "), "export from the dialog")
P.on_ui('{"event":"secondary","args":["0"]}')
T.ok(not P.recording(), "secondary pauses recording")
T.eq(dialog().secondary, "Resume recording", "button follows")
P.on_ui('{"event":"secondary","args":["-1"]}')
T.ok(P.recording(), "resumed")
P.on_ui('{"event":"chip","args":["7 days"]}')
-- Clear from the dialog asks with Vivi's confirm dialog
T.calls = {}
P.on_ui('{"event":"act:Clear…","args":["-1"]}')
local c = last("vivi-confirm")
T.ok(c and c[4] == "clear", "confirm asked")
T.ok(c and T.json_decode(c[5]).heading == "Clear playback statistics?", "confirm heading")
P.on_ui('{"event":"confirm","args":["clear","no"]}')
T.ok(next(P.rows()) ~= nil, "no: kept")
-- drawer tab opened: a one-line toast
T.calls = {}
P.drawer()
T.ok(last("vivi-toast") and last("vivi-toast")[3]:find("^Today "), "drawer toast")
-- Alt+S again closes the dialog
P.show()
T.ok(last("vivi-dialog-close"), "Alt+S closes")
P.on_ui('{"event":"close"}')
T.ok(not P.view.open, "closed")
T.props["user-data/vivi/playlists"] = nil

-- save / load round trip (mkdir runs through the stubbed subprocess)
os.execute("mkdir -p '" .. P.file:match("^(.*)/") .. "'")
P.save()
local f = assert(io.open(P.file))
local n = 0
for _ in f:lines() do n = n + 1 end
f:close()
T.ok(n >= 8, "rows saved")

-- clear needs a second press within 10 s
P.clear()
T.ok(T.osd[#T.osd]:find("^Press Clear statistics again"), "asks first")
T.ok(next(P.rows()) ~= nil, "nothing deleted yet")
t = t + 20
P.clear()
T.ok(T.osd[#T.osd]:find("^Press Clear statistics again"), "too late: asks again")
t = t + 3
P.clear()
T.eq(T.osd[#T.osd], "Playback statistics cleared", "cleared")
T.eq(next(P.rows()), nil, "rows gone")
T.eq(io.open(P.file), nil, "file gone")
P.set_current(nil)
P.clear()
T.eq(T.osd[#T.osd], "No playback statistics to clear", "nothing to clear")

-- confirmed clear through Vivi's confirm dialog
T.props["user-data/vivi/playlists"] = 1
put(0, "audio", "Artist A", "Song", 60)
P.clear()
T.ok(next(P.rows()) ~= nil, "native clear waits for the answer")
P.on_ui('{"event":"confirm","args":["clear","yes"]}')
T.eq(next(P.rows()), nil, "yes: cleared")
T.eq(T.osd[#T.osd], "Playback statistics cleared", "cleared toast")
P.on_ui("not json")
T.ok(true, "bad vivi-ui json is ignored")

T.done("playback-stats")
