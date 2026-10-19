-- @name Night Mode
-- @version 1.1.0
-- @author Vivi
-- @description Dynamic range compression for quiet listening (Vivi plugin package).
--
-- Alt+N (script-binding night_mode/toggle) switches it for this session; the
-- "Night mode on" setting in Vivi decides the state on startup and is applied live.
-- Schedule ("22:00-07:00"): Night Mode turns on when that time starts and off when it
-- ends; Alt+N still overrides it until the next start or end. Only for videos: the
-- filter is left out while music / audio-only files play (covers do not count as video).

local mp = require "mp"
local options = require "mp.options"

-- mpv's OSD is not always visible in Vivi (no video, UI on top), so messages also go
-- to Vivi's toast through `script-message vivi-toast <text>`.
local function osd(msg, secs)
  mp.osd_message(msg, secs)
  mp.commandv("script-message", "vivi-toast", msg)
end

local o = { active = true, strength = "Medium", schedule = "", only_video = false,
  pkgdir = "" } -- pkgdir: set by Vivi; declared so mp.options does not warn about it
local LABEL = "@vivinight"

local FILTERS = {
  ["Light"] = "dynaudnorm=f=250:g=15:p=0.9:m=5",
  ["Medium"] = "dynaudnorm=f=150:g=11:p=0.95:m=10",
  ["Strong"] = "dynaudnorm=f=100:g=7:p=0.97:m=20:r=0.3",
  ["Loudness (EBU R128)"] = "loudnorm=I=-24:LRA=7:TP=-2",
}

local on = false        -- what the user wants (setting, schedule, Alt+N)
local applied = false   -- filter string in the af chain, nil = none, false = unknown (startup)
local in_window = nil   -- last schedule state seen (nil: no schedule)

-- Minutes since midnight for "HH:MM" / "H", or nil.
local function minutes(s)
  local h, m = s:match("^%s*(%d%d?):(%d%d)%s*$")
  if not h then h, m = s:match("^%s*(%d%d?)%s*$"), "0" end
  h, m = tonumber(h), tonumber(m)
  if not h or h > 24 or m > 59 then return nil end
  return (h * 60 + m) % 1440
end

-- Schedule "22:00-07:00" -> from, to (minutes), or nil when empty / invalid.
local function parse_schedule(s)
  local a, b = (s or ""):gsub("\226\128[\147\148]", "-"):match("^%s*([%d:]+)%s*%-%s*([%d:]+)%s*$")
  if not a then return nil end
  local from, to = minutes(a), minutes(b)
  if not from or not to or from == to then return nil end
  return from, to
end

-- Is `now` (minutes since midnight) inside from..to? The window may cross midnight.
local function within(now, from, to)
  if from < to then return now >= from and now < to end
  return now >= from or now < to
end

local clock = function()
  local t = os.date("*t")
  return t.hour * 60 + t.min
end

local function scheduled()
  local from, to = parse_schedule(o.schedule)
  if not from then return nil end
  return within(clock(), from, to)
end

-- Does the current file have a real video track (not cover art)?
local function has_video()
  local v = mp.get_property_native("current-tracks/video")
  return type(v) == "table" and not v.image and not v.albumart
end

local function reason_off()
  if o.only_video and not has_video() then return "only for videos" end
  return nil
end

-- Bring mpv's af chain in line with `on`, the strength and the "only for videos" rule.
local function sync()
  local want = nil
  if on and not reason_off() then want = FILTERS[o.strength] or FILTERS["Medium"] end
  if want == applied then return end
  mp.commandv("af", "remove", LABEL)
  if want then mp.commandv("af", "add", LABEL .. ":lavfi=[" .. want .. "]") end
  applied = want
end

local function say(prefix)
  local r = on and reason_off()
  local msg
  if not on then msg = "Night mode off"
  elseif r then msg = "Night mode on (" .. o.strength .. ") — waits for a video"
  else msg = "Night mode on (" .. o.strength .. ")" end
  osd((prefix or "") .. msg)
end

local function apply(state, quiet, prefix)
  on = state
  sync()
  if not quiet then say(prefix) end
end

-- Schedule tick: switch only when the window starts or ends, so Alt+N in between sticks.
local function tick()
  local w = scheduled()
  if w == nil then in_window = nil return end
  if w ~= in_window then
    local first = in_window == nil
    in_window = w
    if first then apply(w, true) else apply(w, false, "Schedule: ") end
  end
end

options.read_options(o, "night-mode", function(changed)
  -- Vivi changed a setting while playing.
  -- Changing the strength while off leaves it off but says what will be used.
  if changed.schedule then
    in_window = nil
    if scheduled() == nil then apply(o.active) else tick() say("Schedule: ") end
  elseif changed.active then
    apply(o.active)
  elseif changed.strength then
    if on then apply(true) else osd("Night mode strength: " .. o.strength) end
  elseif changed.only_video then
    sync()
    say()
  end
end)

local function toggle() apply(not on) end
mp.add_forced_key_binding("Alt+n", "toggle", toggle)
mp.register_script_message("toggle", toggle)
mp.observe_property("current-tracks/video", "native", function() sync() end)
mp.add_periodic_timer(30, tick)

if scheduled() == nil then apply(o.active, true) else tick() end

if VIVI_TEST then
  return { parse_schedule = parse_schedule, within = within, has_video = has_video,
    set_clock = function(f) clock = f end, tick = tick, toggle = toggle, sync = sync,
    opts = o, is_on = function() return on end, applied = function() return applied end }
end
