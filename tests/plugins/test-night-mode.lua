local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/night-mode/night-mode.lua")

local function filter()
  -- last af add/remove for @vivinight in the recorded commands
  local last
  for _, c in ipairs(T.calls) do
    if c[1] == "af" and c[3] and c[3]:find("^@vivinight") then last = c end
  end
  return last
end

-- startup: on (default), Medium
T.ok(P.is_on(), "on by default")
T.eq(filter()[2], "add", "filter added at startup")
T.ok(filter()[3]:find("dynaudnorm=f=150"), "medium filter")

-- Alt+N toggles
P.toggle()
T.ok(not P.is_on(), "toggled off")
T.eq(filter()[2], "remove", "filter removed")
T.eq(T.osd[#T.osd], "Night mode off", "off toast")
P.toggle()
T.eq(T.osd[#T.osd], "Night mode on (Medium)", "on toast")

-- schedule parsing
local f, t = P.parse_schedule("22:00-07:00")
T.eq(f, 1320, "from") T.eq(t, 420, "to")
f, t = P.parse_schedule(" 21 - 23:30 ")
T.eq(f, 1260, "hour only") T.eq(t, 1410, "to with minutes")
T.eq(P.parse_schedule("22:00–07:00"), 1320, "en dash")
T.eq(P.parse_schedule(""), nil, "empty")
T.eq(P.parse_schedule("late"), nil, "invalid")
T.eq(P.parse_schedule("25:00-07:00"), nil, "bad hour")
T.eq(P.parse_schedule("07:00-07:00"), nil, "empty window")
T.ok(P.within(23 * 60, 1320, 420), "23:00 inside overnight window")
T.ok(P.within(3 * 60, 1320, 420), "03:00 inside overnight window")
T.ok(not P.within(12 * 60, 1320, 420), "noon outside")
T.ok(P.within(14 * 60, 13 * 60, 15 * 60), "daytime window")
T.ok(not P.within(15 * 60, 13 * 60, 15 * 60), "end is exclusive")

-- schedule: switches on at the start, Alt+N sticks until the end
local now = 21 * 60
P.set_clock(function() return now end)
P.opts.schedule = "22:00-07:00"
P.tick() -- first tick: outside the window -> off, quietly
T.ok(not P.is_on(), "off before the window")
now = 22 * 60 + 1
P.tick()
T.ok(P.is_on(), "on when the window starts")
T.ok(T.osd[#T.osd]:find("^Schedule: Night mode on"), "schedule toast")
P.toggle()
P.tick()
T.ok(not P.is_on(), "Alt+N overrides inside the window")
now = 7 * 60
P.tick()
T.ok(not P.is_on(), "off at the end")
P.toggle()
now = 8 * 60
P.tick()
T.ok(P.is_on(), "manual on during the day stays")
P.opts.schedule = ""

-- only for videos: no filter for audio-only / cover art, back for a video
P.opts.only_video = true
T.props["current-tracks/video"] = nil
P.sync()
T.eq(P.applied(), nil, "no filter without video")
T.props["current-tracks/video"] = { id = 1, image = true, albumart = true }
P.sync()
T.eq(P.applied(), nil, "cover art is not video")
T.props["current-tracks/video"] = { id = 1, image = false }
P.sync()
T.ok(P.applied() and P.applied():find("dynaudnorm"), "filter for a video")
P.opts.only_video = false
T.props["current-tracks/video"] = nil
P.sync()
T.ok(P.applied(), "only_video off: filter for audio too")

-- strength
P.opts.strength = "Loudness (EBU R128)"
P.sync()
T.ok(filter()[3]:find("loudnorm"), "loudnorm strength")
T.done("night-mode")
