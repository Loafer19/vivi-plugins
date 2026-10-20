local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/equalizer/equalizer.lua")
local g = P.parse_gains("3, -2 20 x 1.5")
T.eq(g[1], 3, "gain 1")
T.eq(g[3], 12, "clamped")
T.eq(g[4], 1.5, "decimal")
T.eq(g[10], 0, "missing bands are 0")
T.eq(P.graph(P.PRESETS.Flat, "equalizer (10 bands)", true), nil, "flat = no filter")
T.eq(P.graph(P.PRESETS.Bass, "equalizer (10 bands)", true),
  "equalizer=f=31:t=o:w=1:g=6,equalizer=f=62:t=o:w=1:g=5,equalizer=f=125:t=o:w=1:g=4,equalizer=f=250:t=o:w=1:g=2,volume=-6dB",
  "bass graph")
T.eq(P.graph(P.PRESETS.Night, "equalizer (10 bands)", false):find("volume"), nil, "no preamp")
local s = P.graph(P.PRESETS.Rock, "superequalizer (18 bands)", false)
T.ok(s:find("^superequalizer=1b=1.39:"), "super band 1-2 interpolated")
T.ok(s:find(":18b=1.78$"), "super band 18 (+5 dB)")
T.eq(P.gain_at(P.PRESETS.Rock, 1000), -1, "interp at a band")
T.eq(math.floor(P.gain_at({ 0, 0, 0, 0, 0, 0, 6, 0, 0, 0 }, 2828) * 100 + 0.5), 300, "interp between bands")
-- applying adds a labelled filter; cycling saves the preset
P.next_preset()
local last = T.calls[#T.calls]
local added
for _, c in ipairs(T.calls) do if c[1] == "af" and c[2] == "add" then added = c[3] end end
T.ok(added and added:find("^@vivi%-eqplug:lavfi=%[equalizer=f=31"), "af add with label")
T.eq(P.o.preset, "Bass", "next preset")
T.eq(#T.osd, 0, "no mpv OSD text, Vivi toasts only")

local function msgs(name)
  local out = {}
  for _, c in ipairs(T.calls) do
    if c[1] == "script-message" and c[2] == name then out[#out + 1] = c end
  end
  return out
end
local function afs()
  local out = {}
  for _, c in ipairs(T.calls) do if c[1] == "af" then out[#out + 1] = c[2] end end
  return out
end

-- U+2212 minus and the en dash (the setting's title writes "−12…12") are minus signs.
local m = P.parse_gains("−3 –2.5 4")
T.eq(m[1], -3, "unicode minus")
T.eq(m[2], -2.5, "en dash minus")
T.eq(m[3], 4, "plain value after unicode minus")

-- A stale or hand-edited preset name plays and shows as Flat.
P.o.preset = "Jazz"
T.eq(P.preset_name(), "Flat", "unknown preset = Flat")
P.next_preset()
T.eq(P.o.preset, "Bass", "cycling from an unknown preset")

-- Resampling for the built-in equalizer's bands (60 … 16000 Hz).
local j = T.json_decode(P.handover_json(P.PRESETS.Rock, "X"))
T.eq(j.format, "vivi-eq-presets", "export format")
T.eq(j.presets[1].preamp, 12, "unity preamp")
T.eq(#j.presets[1].bands, 10, "ten core bands")
T.eq(j.presets[1].bands[5], -1, "1 kHz band copied")
T.eq(j.presets[1].bands[10], 5, "16 kHz band copied")
T.ok(j.presets[1].bands[1] > 3 and j.presets[1].bands[1] < 5, "60 Hz between the 31 / 62 Hz gains")

-- Older Vivi (no user-data/vivi/equalizer): the filter stays, Move explains why not.
local O = T.load("plugins/equalizer/equalizer.lua", { preset = "Rock" })
T.eq(afs()[1], "add", "old Vivi: filter applied at load")
T.eq(O.handover(true), "old-vivi", "old Vivi: nothing to move")
T.eq(#msgs("vivi-eq-preset") + #msgs("vivi-eq-import"), 0, "old Vivi: no handover messages")
O.on_file_loaded()
T.ok(O.applied(), "old Vivi: still equalizing after file-loaded")

-- Vivi 0.13+: no own filter, and the preset goes to the built-in equalizer once.
local B = T.load("plugins/equalizer/equalizer.lua", { preset = "Rock" },
  { ["user-data/vivi/equalizer"] = 1, af = {} })
T.eq(#afs(), 0, "built-in: no filter at load")
T.eq(#msgs("vivi-eq-preset"), 0, "built-in: no handover before a file is loaded")
B.on_file_loaded()
local sel = msgs("vivi-eq-preset")
T.eq(sel[1] and sel[1][3], "Rock", "built-in: Rock selected in the core")
local saved
for _, c in ipairs(msgs("vivi-setting")) do if c[4] == "move-to-builtin" then saved = c[5] end end
T.eq(saved, "no", "handover setting turns itself off")
B.on_file_loaded()
T.eq(#msgs("vivi-eq-preset"), 1, "handover only once")
B.next_preset()
T.eq(B.o.preset, "Rock", "built-in: Alt+e does not change the plugin preset")
T.eq(#afs(), 0, "built-in: Alt+e adds no filter")

-- A plugin filter added before Vivi set the flag is removed at the first file.
local L = T.load("plugins/equalizer/equalizer.lua", { preset = "Bass" })
T.ok(L.applied(), "late flag: filter applied at load")
T.props["user-data/vivi/equalizer"] = 1
T.props.af = {}
L.on_file_loaded()
T.eq(afs()[#afs()], "remove", "late flag: own filter removed")
T.eq(L.applied(), nil, "late flag: nothing applied")
T.eq(#msgs("vivi-eq-preset"), 1, "late flag: Bass handed over")

-- Custom curve: imported as a preset, resampled.
local C = T.load("plugins/equalizer/equalizer.lua", { preset = "Custom", custom = "1 2 3 4 5 6 7 8 9 10" },
  { ["user-data/vivi/equalizer"] = 1, af = {} })
C.on_file_loaded()
local imp = msgs("vivi-eq-import")
T.eq(#imp, 1, "custom: one import")
local pj = imp[1] and T.json_decode(imp[1][3])
T.eq(pj and pj.presets[1].name, "Custom (Equalizer plugin)", "custom: preset name")
T.eq(pj and pj.presets[1].bands[5], 6, "custom: 1 kHz gain")

-- Never over an equalizer the user already turned on in Vivi; Flat / off hands nothing.
local K = T.load("plugins/equalizer/equalizer.lua", { preset = "Vocal" },
  { ["user-data/vivi/equalizer"] = 1, af = { { name = "lavfi", label = "vivi-eq" } } })
K.on_file_loaded()
T.eq(#msgs("vivi-eq-preset"), 0, "core EQ on: not overridden")
T.eq(K.handover(true), "moved", "Move button: the user asked, so it moves")
local F = T.load("plugins/equalizer/equalizer.lua", { preset = "Night", enabled = false },
  { ["user-data/vivi/equalizer"] = 1, af = {} })
F.on_file_loaded()
T.eq(#msgs("vivi-eq-preset") + #msgs("vivi-eq-import"), 0, "plugin off: nothing handed over")
T.done("equalizer")
