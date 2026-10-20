-- @name Equalizer
-- @version 1.1.0
-- @author Vivi
-- @description Equalizer presets and a custom 10-band EQ through mpv audio filters (Vivi plugin package).
--
-- Deprecated: Vivi 0.13.0 has the equalizer built in (Audio panel, Alt+E / Alt+Shift+E) and
-- sets user-data/vivi/equalizer = 1. Then this script applies no filter of its own (both
-- used to add up) and, once, hands its preset over to the built-in equalizer:
-- `vivi-eq-preset <name>` for Bass / Vocal / Rock / Night, `vivi-eq-import <json>` for a
-- Custom curve (resampled to the built-in bands). Older Vivi versions keep the full
-- behaviour below.
--
-- Keys: Alt+e  next preset    Alt+E  equalizer on / off
-- Script messages: next, toggle, show, handover.
--
-- The EQ is one labelled mpv filter, @vivi-eqplug (lavfi), so it never touches Vivi's own
-- Audio-panel EQ (@vivi-eq) or other filters. Engines:
--   * equalizer      ten ffmpeg `equalizer` peaking filters (one octave wide) at
--                    31 Hz … 16 kHz, gains in dB;
--   * superequalizer ffmpeg's 18-band FIR equalizer; the ten gains are interpolated on a
--                    log-frequency scale and passed as linear factors.
-- Both filters are part of libavfilter, which every mpv build links: no ffmpeg binary.
-- A pre-amp of minus the largest boost keeps boosted presets from clipping (optional).
-- The preset, gains and on/off state are plugin settings, so they persist across
-- restarts; Alt+e / Alt+E save them with `script-message vivi-setting` (Vivi 0.9.1+; on
-- 0.9.0 the choice lasts until Vivi closes).
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

local ID = "equalizer"
local LABEL = "@vivi-eqplug"
local FREQS = { 31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 }
local PRESETS = {
  Flat  = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
  Bass  = { 6, 5, 4, 2, 0, 0, 0, 0, 0, 0 },
  Vocal = { -2, -2, -1, 1, 3, 4, 4, 2, 0, -1 },
  Rock  = { 5, 3, 1, -1, -2, -1, 1, 3, 4, 5 },
  Night = { -6, -5, -3, -1, 1, 2, 2, 1, 0, -1 },
}
local ORDER = { "Flat", "Bass", "Vocal", "Rock", "Night", "Custom" }
-- superequalizer band centres (Hz), 1b … 18b.
local SUPER = { 65, 92, 131, 185, 262, 370, 523, 740, 1047, 1480, 2093, 2960, 4186, 5920, 8372, 11840, 16744, 20000 }
-- Band centres of Vivi's built-in equalizer (src/fx.rs BANDS, VLC's).
local CORE_BANDS = { 60, 170, 310, 600, 1000, 3000, 6000, 12000, 14000, 16000 }
-- Presets the built-in equalizer has under the same name (Vivi 0.13.0).
local CORE_PRESETS = { Flat = true, Bass = true, Vocal = true, Rock = true, Night = true }

local o = {
  enabled = true,
  preset = "Flat",
  custom = "0 0 0 0 0 0 0 0 0 0",
  engine = "equalizer (10 bands)",
  preamp = true,
  -- Vivi 0.13.0+: hand the preset to the built-in equalizer at the next file (then this
  -- setting turns itself off).
  ["move-to-builtin"] = true,
}

-- Ten gains (dB, clamped to ±12) from "a b c …" (commas allowed; U+2212 "−" and the
-- en dash count as minus, like the setting's own title); missing bands are 0.
local function parse_gains(s)
  s = (s or ""):gsub("\226\136\146", "-"):gsub("\226\128\147", "-")
  local g = {}
  for v in s:gmatch("[-+]?%d*%.?%d+") do
    if #g < 10 then g[#g + 1] = math.max(-12, math.min(12, tonumber(v) or 0)) end
  end
  for i = #g + 1, 10 do g[i] = 0 end
  return g
end

-- The preset setting as one of ORDER (a hand-edited or stale value counts as Flat, so
-- the name shown always matches what plays).
local function preset_name()
  for _, v in ipairs(ORDER) do if v == o.preset then return v end end
  return "Flat"
end

local function gains()
  local p = preset_name()
  if p == "Custom" then return parse_gains(o.custom) end
  return PRESETS[p]
end

local function fmt(x) return (string.format("%.2f", x):gsub("0+$", ""):gsub("%.$", "")) end

-- Gain (dB) at frequency f by linear interpolation over log2(frequency).
local function gain_at(g, f)
  local lf = math.log(f) / math.log(2)
  if f <= FREQS[1] then return g[1] end
  if f >= FREQS[10] then return g[10] end
  for i = 1, 9 do
    local a, b = FREQS[i], FREQS[i + 1]
    if f >= a and f <= b then
      local la, lb = math.log(a) / math.log(2), math.log(b) / math.log(2)
      return g[i] + (g[i + 1] - g[i]) * (lf - la) / (lb - la)
    end
  end
  return 0
end

local function is_flat(g)
  for _, v in ipairs(g) do if v ~= 0 then return false end end
  return true
end

-- lavfi graph for the gains, or nil when flat.
local function graph(g, engine, preamp)
  if is_flat(g) then return nil end
  local max = 0
  for _, v in ipairs(g) do if v > max then max = v end end
  local parts = {}
  if tostring(engine):find("^superequalizer") then
    local b = {}
    for i, f in ipairs(SUPER) do b[#b + 1] = i .. "b=" .. fmt(10 ^ (gain_at(g, f) / 20)) end
    parts[1] = "superequalizer=" .. table.concat(b, ":")
  else
    for i, f in ipairs(FREQS) do
      if g[i] ~= 0 then parts[#parts + 1] = string.format("equalizer=f=%d:t=o:w=1:g=%s", f, fmt(g[i])) end
    end
  end
  if preamp and max > 0 then parts[#parts + 1] = "volume=" .. fmt(-max) .. "dB" end
  return table.concat(parts, ",")
end

local function describe(g)
  local s = {}
  for i, v in ipairs(g) do s[i] = (v > 0 and "+" or "") .. fmt(v) end
  return table.concat(s, " ")
end

-- Vivi's toast (vivi-toast exists since 0.9.0, the oldest Vivi that runs packages); no
-- mpv OSD, which Vivi's UI covers anyway.
local function toast_now(msg, secs)
  if secs then
    mp.commandv("script-message", "vivi-toast", msg, tostring(secs))
  else
    mp.commandv("script-message", "vivi-toast", msg)
  end
end

local toast = toast_now

local function save(key, value)
  mp.commandv("script-message", "vivi-setting", ID, key, value)
end

-- Vivi 0.13.0+ has the equalizer built in.
local function builtin()
  return tostring(mp.get_property_native("user-data/vivi/equalizer", "")) == "1"
end

-- Whether Vivi's own equalizer filter (@vivi-eq) is in mpv's audio chain right now.
local function core_eq_on()
  local af = mp.get_property_native("af", {})
  if type(af) ~= "table" then return false end
  for _, f in ipairs(af) do
    if type(f) == "table" and f.label == "vivi-eq" then return true end
  end
  return false
end

-- The plugin's curve resampled to the built-in equalizer's bands, as `vivi-eq-import`
-- JSON (the Audio panel's Export format). Preamp 12 = unity; Vivi's auto pre-amp (on
-- by default) does what the plugin's pre-amp option did.
local function handover_json(g, name)
  local bands = {}
  for i, f in ipairs(CORE_BANDS) do
    bands[i] = tonumber(fmt(gain_at(g, f)))
  end
  return utils.format_json({
    format = "vivi-eq-presets", version = 1,
    presets = { { name = name, preamp = 12, bands = bands } },
  })
end

local applied = nil

local function set_filter(gr)
  if gr == applied then return end
  if applied then mp.commandv("af", "remove", LABEL) end
  if gr then mp.commandv("af", "add", LABEL .. ":lavfi=[" .. gr .. "]") end
  applied = gr
  mp.msg.info("af " .. (gr or "off"))
end

-- Hand the active preset to Vivi's built-in equalizer. `manual`: the user asked
-- (Settings action), so it also runs again and says why when there is nothing to move.
-- Returns what happened: "moved", "flat", "core-on" or "old-vivi".
local function handover(manual)
  -- At file-loaded the toast waits a moment: Vivi's resume prompt takes the notice line
  -- right after a file opens and would wipe it.
  local function toast(msg, secs)
    if manual then return toast_now(msg, secs) end
    mp.add_timeout(1.5, function() toast_now(msg, secs) end)
  end
  if not builtin() then
    if manual then toast("This Vivi has no built-in equalizer yet (Vivi 0.13.0+); the plugin keeps working") end
    return "old-vivi"
  end
  local p, g = preset_name(), gains()
  local result
  if not o.enabled or is_flat(g) then
    result = "flat"
    if manual then toast("Equalizer plugin: nothing to move (it is off or Flat). Vivi's Equalizer is in the Audio panel") end
  elseif core_eq_on() and not manual then
    -- Never override an equalizer the user already set up in Vivi.
    result = "core-on"
    toast("Equalizer plugin is now inactive: Vivi's built-in Equalizer is on (Audio panel). You can uninstall the plugin", 8)
  else
    if CORE_PRESETS[p] then
      mp.commandv("script-message", "vivi-eq-preset", p)
      toast("Equalizer: " .. p .. " now plays through Vivi's built-in Equalizer (Audio panel). You can uninstall the plugin", 8)
    else
      local name = "Custom (Equalizer plugin)"
      mp.commandv("script-message", "vivi-eq-import", handover_json(g, name))
      toast("Equalizer: your Custom curve is now the preset \"" .. name .. "\" in Vivi's built-in Equalizer (Audio panel). You can uninstall the plugin", 8)
    end
    result = "moved"
  end
  if o["move-to-builtin"] then
    o["move-to-builtin"] = false
    save("move-to-builtin", "no")
  end
  return result
end

-- Built-in equalizer present: drop our filter (it would add to Vivi's). `file`: called at
-- file-loaded, when Vivi has applied its own filters, so the one-time handover can see
-- whether Vivi's equalizer is on already.
local function check_builtin(file)
  if not builtin() then return false end
  set_filter(nil)
  if file and o["move-to-builtin"] then handover(false) end
  return true
end

local function apply(announce)
  if check_builtin() then
    if announce then toast("Equalizer is built into Vivi now: Audio panel, Alt+E / Alt+Shift+E") end
    return
  end
  set_filter(o.enabled and graph(gains(), o.engine, o.preamp) or nil)
  if announce then
    local p = preset_name()
    toast(not o.enabled and "Equalizer off"
      or ("Equalizer: " .. p .. (p == "Custom" and (" (" .. describe(gains()) .. ")") or "")))
  end
end

local function next_preset()
  if builtin() then return apply(true) end
  local i = 1
  local cur = preset_name()
  for k, v in ipairs(ORDER) do if v == cur then i = k end end
  o.preset = ORDER[i % #ORDER + 1]
  o.enabled = true
  save("preset", o.preset)
  save("enabled", "yes")
  apply(true)
end

local function toggle()
  if builtin() then return apply(true) end
  o.enabled = not o.enabled
  save("enabled", o.enabled and "yes" or "no")
  apply(true)
end

local function on_file_loaded()
  if check_builtin(true) then return end
  -- The filter chain survives file changes, but re-check in case something reset `af`.
  local af = mp.get_property("af") or ""
  if applied and not af:find("vivi%-eqplug") then applied = nil end
  apply(false)
end

options.read_options(o, ID, function() apply(false) end)
-- Vivi sets user-data/vivi/equalizer while it starts; if this script runs first, the
-- filter is dropped again at the first file-loaded, before any audio plays.
apply(false)
mp.register_event("file-loaded", on_file_loaded)

mp.add_forced_key_binding("Alt+e", "next", next_preset)
mp.add_forced_key_binding("Alt+E", "toggle", toggle)
mp.register_script_message("next", next_preset)
mp.register_script_message("toggle", toggle)
mp.register_script_message("show", function() apply(true) end)
mp.register_script_message("handover", function() handover(true) end)

if VIVI_TEST then
  return { parse_gains = parse_gains, graph = graph, gain_at = gain_at, PRESETS = PRESETS,
    o = o, apply = apply, next_preset = next_preset, toggle = toggle, handover = handover,
    handover_json = handover_json, on_file_loaded = on_file_loaded, preset_name = preset_name,
    applied = function() return applied end }
end
