-- @name Playback Statistics
-- @version 1.2.0
-- @author Vivi
-- @description Local watch/listen time statistics (Vivi plugin package).
--
-- Data: $XDG_DATA_HOME/vivi/plugin-data/playback-stats/stats.tsv
-- (one line per day + item: date, seconds, kind, artist/show, title). Nothing leaves the machine.
-- Alt+S (script-binding playback_stats/show) opens the statistics in Vivi's plugin dialog (an OSD
-- panel on older Vivi) and a one-line toast. Home widget and side-drawer tab in Vivi 0.13+;
-- with live plugin content (Vivi announcing "content" in user-data/vivi/host-features) the
-- widget and the drawer tab show the numbers and bars themselves and Alt+S toggles the
-- drawer while something plays.
-- Script messages: show, open, drawer, export, clear, toggle-record, vivi-ui (dialog events).

local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

-- mpv's OSD is not always visible in Vivi (no video, UI on top), so messages also go
-- to Vivi's toast through `script-message vivi-toast <text>`. Toasts are one line high.
local function toast(msg)
  mp.osd_message(msg, 3)
  mp.commandv("script-message", "vivi-toast", msg)
end

-- pkgdir is passed by Vivi (reserved key); declared so mp.options does not warn about it.
local o = { days = 7, record = true, pkgdir = "" }

local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
local data = os.getenv("XDG_DATA_HOME")
if not data or data == "" then data = home .. "/.local/share" end
local dir = data .. "/vivi/plugin-data/playback-stats"
local file = dir .. "/stats.tsv"
local export_path = home .. "/vivi-stats.csv"

local rows = {} -- key "date\tkind\tartist\ttitle" -> seconds
local dirty = false
local current = nil -- { kind, artist, title } of the loaded file
local last_t = nil
local counting = false -- whether the time since last_t is playback time
local recording = true -- "Record statistics" (o.record), switched through set_record
local clock = os.time -- injectable for tests
local now_fn = mp.get_time

local function clean(s) return (tostring(s or ""):gsub("[\t\r\n]", " ")) end
local function day(t) return os.date("%Y-%m-%d", t) end

local function load()
  local f = io.open(file, "r")
  if not f then return end
  for line in f:lines() do
    local d, s, k, a, t = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if d and tonumber(s) then
      local key = table.concat({ d, k, a, t }, "\t")
      rows[key] = (rows[key] or 0) + tonumber(s)
    end
  end
  f:close()
end

local function save()
  if not dirty then return end
  utils.subprocess({ args = { "mkdir", "-p", dir }, playback_only = false })
  local tmp = file .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  for key, s in pairs(rows) do
    local d, k, a, t = key:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    f:write(string.format("%s\t%d\t%s\t%s\t%s\n", d, math.floor(s + 0.5), k, a, t))
  end
  f:close()
  os.rename(tmp, file)
  dirty = false
end

-- "Show S01E02 ...", "Show.Name.1x02" -> "Show" / "Show Name"; nil when not an episode.
local function show_name(name)
  name = name or ""
  local s = name:match("^(.-)[ ._-]+[Ss]%d+[ ._-]?[Ee]%d+") or name:match("^(.-)[ ._-]+%d+x%d%d")
  if not s or s == "" then return nil end
  return (s:gsub("[._]", " "):gsub("%s+$", ""))
end

local function describe()
  local md = mp.get_property_native("metadata") or {}
  local function m(k) return md[k] or md[string.upper(k)] or md[k:sub(1, 1):upper() .. k:sub(2)] end
  local video = false
  for _, tr in ipairs(mp.get_property_native("track-list") or {}) do
    if tr.type == "video" and not tr.albumart and not tr.image then video = true end
  end
  local title = m("title") or mp.get_property("media-title") or mp.get_property("filename") or "?"
  local artist = m("artist") or m("album_artist") or ""
  if video then
    return { "video", clean(m("show") or show_name(mp.get_property("filename/no-ext")) or ""), clean(title) }
  end
  return { "audio", clean(artist), clean(title) }
end

-- True while a file plays: not paused, not buffering or seeking (core-idle), recording on.
local function playing()
  return current ~= nil and recording and not mp.get_property_native("core-idle", true)
    and not mp.get_property_native("idle-active", false)
end

-- Adds the time since the last call if it was playback time, then samples the state
-- again. Called every 5 s and on every change (pause, buffering, file, setting), so a
-- pause neither loses the seconds before it nor counts the seconds it lasted.
local function tick()
  local now = now_fn()
  if counting and current and last_t then
    local dt = math.min(math.max(now - last_t, 0), 10)
    local key = table.concat({ day(clock()), current[1], current[2], current[3] }, "\t")
    rows[key] = (rows[key] or 0) + dt
    dirty = true
  end
  last_t = now
  counting = playing()
end

local function hms(s)
  s = math.floor(s + 0.5)
  if s >= 3600 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor((s % 3600) / 60)) end
  return string.format("%dm %02ds", math.floor(s / 60), s % 60)
end

-- Seconds per day ("YYYY-MM-DD" -> s) over all rows.
local function per_day()
  local t = {}
  for key, s in pairs(rows) do
    local d = key:match("^([^\t]*)\t")
    if d then t[d] = (t[d] or 0) + s end
  end
  return t
end

local function total_since(pd, days, now)
  local since = day(now - (days - 1) * 86400)
  local s = 0
  for d, v in pairs(pd) do if d >= since then s = s + v end end
  return s
end

-- Days in a row with at least a minute played, up to today (or yesterday, when nothing
-- has played yet today, so the streak does not drop to 0 in the morning).
local function streak(pd, now)
  local n, i = 0, 0
  if (pd[day(now)] or 0) < 60 then i = 1 end
  while (pd[day(now - (i + n) * 86400)] or 0) >= 60 do n = n + 1 end
  return n
end

local function period_name(days)
  if days == 1 then return "Today" end
  return string.format("Last %d days", days)
end

-- The summary as data: totals, top artists/shows and the last 7 days. `days` defaults to
-- the "Summary covers" setting; 1 is today only.
local function summary(days)
  local now = clock()
  days = days or tonumber(o.days) or 7
  local pd = per_day()
  local since = day(now - (days - 1) * 86400)
  local total, kinds, who = 0, { audio = 0, video = 0 }, {}
  for key, s in pairs(rows) do
    local d, k, a = key:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t")
    if d and d >= since then
      total = total + s
      kinds[k] = (kinds[k] or 0) + s
      if a ~= "" then who[a] = (who[a] or 0) + s end
    end
  end
  local top = {}
  for a, s in pairs(who) do top[#top + 1] = { a, s } end
  table.sort(top, function(x, y) if x[2] ~= y[2] then return x[2] > y[2] end return x[1] < y[1] end)
  while #top > 5 do top[#top] = nil end
  local bars, maxd = {}, 0
  for i = math.min(days, 7) - 1, 0, -1 do
    local d = day(now - i * 86400)
    bars[#bars + 1] = { d, pd[d] or 0 }
    maxd = math.max(maxd, pd[d] or 0)
  end
  local st = streak(pd, now)
  return {
    days = days, total = total, video = kinds.video or 0, audio = kinds.audio or 0, top = top,
    bars = bars, max = maxd, streak = st,
    periods = { { "Today", pd[day(now)] or 0 }, { "7 days", total_since(pd, 7, now) },
      { "30 days", total_since(pd, 30, now) }, { "365 days", total_since(pd, 365, now) } },
  }
end

local function summary_lines(S)
  S = S or summary()
  local p = {}
  for _, x in ipairs(S.periods) do p[#p + 1] = x[1] .. " " .. hms(x[2]) end
  local lines = {
    string.format("%s: %s (video %s, audio %s)", period_name(S.days), hms(S.total), hms(S.video), hms(S.audio)),
    table.concat(p, " · ") .. (S.streak > 1 and string.format(" · %d-day streak", S.streak) or ""),
  }
  for i, t in ipairs(S.top) do lines[#lines + 1] = string.format("%d. %s  %s", i, t[1], hms(t[2])) end
  for _, b in ipairs(S.bars) do
    lines[#lines + 1] = string.format("%s %s %s", b[1]:sub(6), string.rep("█", math.floor(20 * b[2] / math.max(S.max, 1) + 0.5)), hms(b[2]))
  end
  return lines
end

-- One line for Vivi's toast.
local function toast_line(S)
  S = S or summary()
  local s = string.format("Today %s · %s %s", hms(S.periods[1][2]), period_name(S.days):lower(), hms(S.total))
  if S.days == 1 then s = "Today " .. hms(S.total) end
  if S.top[1] then s = s .. " · top: " .. S.top[1][1] end
  return s
end

-- Panel on mpv's OSD, below Vivi's title bar (which covers the top of the video).
local overlay = mp.create_osd_overlay("ass-events")
local hide_timer
local function ass(s) return (tostring(s):gsub("\\", "\\\226\129\160"):gsub("{", "\\{"):gsub("}", "\\}")) end

local function panel(S)
  local w, h = mp.get_osd_size()
  if not w or not h or w <= 0 or h <= 0 then w, h = 1280, 720 end
  local H = 720
  local W = math.floor(H * w / h)
  overlay.res_x, overlay.res_y = W, H
  local x, y, lh, pw = 28, 64, 26, 470
  local rows_n = 2 + #S.top + #S.bars
  local ev = {}
  local function rect(x0, y0, x1, y1, col, alpha)
    ev[#ev + 1] = string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}m %d %d l %d %d %d %d %d %d{\\p0}",
      col, alpha, x0, y0, x1, y0, x1, y1, x0, y1)
  end
  local function text(tx, ty, s, size, col)
    ev[#ev + 1] = string.format("{\\an7\\pos(%d,%d)\\fs%d\\bord0\\shad0\\1c&H%s&}%s", tx, ty, size, col or "FFFFFF", s)
  end
  rect(x, y, x + pw, y + 20 + rows_n * lh + 8, "101010", "40")
  local cy = y + 12
  text(x + 16, cy, ass(string.format("%s: %s", period_name(S.days), hms(S.total))), 22)
  text(x + 260, cy + 3, ass(string.format("video %s · audio %s", hms(S.video), hms(S.audio))), 15, "B0B0B0")
  cy = cy + lh
  local p = {}
  for _, q in ipairs(S.periods) do p[#p + 1] = q[1] .. " " .. hms(q[2]) end
  if S.streak > 1 then p[#p + 1] = string.format("%d-day streak", S.streak) end
  text(x + 16, cy + 2, ass(table.concat(p, " · ")), 15, "B0B0B0")
  cy = cy + lh
  for i, t in ipairs(S.top) do
    local name = t[1]
    if #name > 40 then name = name:sub(1, 38):gsub("[\192-\255][\128-\191]*$", "") .. "…" end
    text(x + 16, cy, ass(string.format("%d. %s", i, name)), 18)
    text(x + pw - 96, cy, ass(hms(t[2])), 18, "B0B0B0")
    cy = cy + lh
  end
  for _, b in ipairs(S.bars) do
    text(x + 16, cy + 1, ass(b[1]:sub(6)), 16, "B0B0B0")
    local len = math.floor(250 * b[2] / math.max(S.max, 1) + 0.5)
    rect(x + 76, cy + 5, x + 76 + math.max(len, 2), cy + 19, b[2] > 0 and "1E90F0" or "505050", "10")
    text(x + 76 + math.max(len, 2) + 10, cy + 1, ass(hms(b[2])), 16)
    cy = cy + lh
  end
  overlay.data = table.concat(ev, "\n")
  overlay:update()
  if hide_timer then hide_timer:kill() end
  hide_timer = mp.add_timeout(8, function() overlay:remove(); hide_timer = nil end)
end

-- Native view (Vivi with the plugin host API): the shared plugin dialog through
-- `vivi-dialog`, opened by Alt+S, the Home widget and the drawer's "Show summary".
-- Periods are chips, the list groups by artist / show, title or day, the search field
-- filters it and the side pane has the totals, streak and 7-day bars. Older Vivi ignores
-- vivi-* messages, so there the OSD panel above is used instead.
local ID = "playback-stats"
local PERIODS = { { "Today", 1 }, { "7 days", 7 }, { "30 days", 30 }, { "365 days", 365 } }
local GROUPS = { "Artists & shows", "Titles", "Days" }
local view = { days = nil, group = GROUPS[1], query = "", sel = nil, open = false, list = {} }

local function native()
  -- Set by the same Vivi builds that have vivi-dialog / vivi-confirm.
  return mp.get_property_native("user-data/vivi/playlists") ~= nil
    or mp.get_property_native("user-data/vivi/downloads") ~= nil
end

-- Host API words Vivi announces (`user-data/vivi/host-features`, e.g. "content drawer
-- bars info-dialog"); unset on older Vivi, which keeps the dialog / toast behaviour.
local function host_has(word)
  local f = mp.get_property_native("user-data/vivi/host-features")
  if f == nil then return false end
  return (" " .. tostring(f) .. " "):find(" " .. word .. " ", 1, true) ~= nil
end

-- Short time for the list's narrow duration column: "1h 53m", "35m", "40s".
local function short(s)
  s = math.floor(s + 0.5)
  if s >= 3600 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor((s % 3600) / 60)) end
  if s >= 60 then return string.format("%dm", math.floor(s / 60)) end
  return string.format("%ds", s)
end

local function bar(s, max, width)
  local n = math.floor(width * s / math.max(max, 1) + 0.5)
  if s > 0 and n == 0 then n = 1 end
  return string.rep("▬", n) -- draws as one solid bar in Vivi's UI font ("█" shows seams)
end

local function weekday(d)
  local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
  return os.date("%a %d %b", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 }))
end

-- Rows of the list for `days` and a group, filtered by `query` (case-insensitive).
local function list_items(days, group, query)
  local now = clock()
  local since = day(now - (days - 1) * 86400)
  local agg, order = {}, {}
  for key, s in pairs(rows) do
    local d, k, a, t = key:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    if d and d >= since then
      local name, sub
      if group == "Days" then name, sub = d, ""
      elseif group == "Titles" then name, sub = t, a ~= "" and a or k
      else name, sub = a, k end
      if name ~= "" then
        local id = name .. "\t" .. sub
        local e = agg[id]
        if not e then
          e = { name = name, sub = sub, s = 0, titles = {}, kinds = {} }
          agg[id] = e
          order[#order + 1] = e
        end
        e.s = e.s + s
        e.titles[t] = (e.titles[t] or 0) + s
        e.kinds[k] = true
      end
    end
  end
  local q = (query or ""):lower()
  local out = {}
  for _, e in ipairs(order) do
    if q == "" or e.name:lower():find(q, 1, true) or e.sub:lower():find(q, 1, true) then out[#out + 1] = e end
  end
  if group == "Days" then
    table.sort(out, function(x, y) return x.name > y.name end)
  else
    table.sort(out, function(x, y) if x.s ~= y.s then return x.s > y.s end return x.name < y.name end)
  end
  return out
end

local function detail_text(S, e)
  if e then
    local t = { e.name, string.format("%s · %d%% of %s", hms(e.s), math.floor(100 * e.s / math.max(S.total, 1) + 0.5), period_name(S.days):lower()) }
    local titles = {}
    for name, s in pairs(e.titles) do titles[#titles + 1] = { name, s } end
    table.sort(titles, function(x, y) if x[2] ~= y[2] then return x[2] > y[2] end return x[1] < y[1] end)
    if #titles > 1 or view.group ~= "Titles" then
      t[#t + 1] = ""
      for i = 1, math.min(10, #titles) do t[#t + 1] = string.format("%s  %s", titles[i][1], hms(titles[i][2])) end
    end
    return table.concat(t, "\n")
  end
  local t = {
    string.format("%s: %s", period_name(S.days), hms(S.total)),
    string.format("Video %s · audio %s", hms(S.video), hms(S.audio)),
    "",
  }
  for _, q in ipairs(S.periods) do t[#t + 1] = string.format("%s: %s", q[1], hms(q[2])) end
  t[#t + 1] = S.streak == 1 and "Streak: 1 day" or string.format("Streak: %d days", S.streak)
  t[#t + 1] = ""
  t[#t + 1] = "Last 7 days"
  local native_bars = host_has("bars") -- the Days view draws real bars: plain lines here
  for _, b in ipairs(S.bars) do
    if native_bars then
      t[#t + 1] = string.format("%s · %s", weekday(b[1]), hms(b[2]))
    else
      -- bar first, so the bars line up (proportional font)
      t[#t + 1] = string.format("%s %s · %s", b[2] > 0 and bar(b[2], S.max, 10) or "·", weekday(b[1]), hms(b[2]))
    end
  end
  return table.concat(t, "\n")
end

-- The vivi-dialog JSON for the current view (`open`: show it if it is not up).
local function dialog_payload(open)
  local days = view.days or tonumber(o.days) or 7
  local S = summary(days)
  view.list = list_items(days, view.group, view.query)
  local max = 0
  for _, e in ipairs(view.list) do max = math.max(max, e.s) end
  local out = {}
  for i, e in ipairs(view.list) do
    local r = { title = e.name, dur = short(e.s), selected = view.sel == i }
    if view.group == "Days" then
      r.title = weekday(e.name)
      if host_has("bars") then r.bar = e.s / math.max(max, 1) else r.sub = bar(e.s, max, 24) end
    elseif view.group == "Titles" then
      r.sub = e.sub
    else
      r.sub = string.format("%s · %d %s", e.kinds.video and (e.kinds.audio and "video, audio" or "show") or "artist",
        (function() local n = 0 for _ in pairs(e.titles) do n = n + 1 end return n end)(),
        (function() local n = 0 for _ in pairs(e.titles) do n = n + 1 end return n == 1 and "title" or "titles" end)())
      r.badge = "#" .. i
    end
    out[#out + 1] = r
  end
  local chip = PERIODS[2][1]
  for _, p in ipairs(PERIODS) do if p[2] == days then chip = p[1] end end
  local st = recording and "Recording" or "Recording paused: nothing is counted"
  st = st .. " · " .. #view.list .. (#view.list == 1 and " entry" or " entries")
  if #view.list == 0 then
    st = (view.query ~= "" and "Nothing matches \"" .. view.query .. "\"" or "Nothing played in this period yet") .. (recording and "" or " · recording paused")
  end
  local info = host_has("info-dialog")
  return {
    open = open or nil,
    -- Read-only statistics: no search row and no per-row play / queue buttons.
    info_only = info or nil,
    title = "Playback statistics",
    placeholder = "Filter artists, shows, titles",
    search_label = "Filter",
    query = view.query,
    chips = (function() local c = {} for _, p in ipairs(PERIODS) do c[#c + 1] = p[1] end return c end)(),
    chip = chip,
    filters = { { name = "Group by", options = GROUPS, value = view.group } },
    rows = out,
    detail = detail_text(S, view.sel and view.list[view.sel] or nil),
    status = st,
    -- The row's play button / double click also send "primary" (with the row), so the
    -- accent button is the harmless Overview / Refresh and Export is an action.
    actions = { "Export CSV", "Clear…" },
    secondary = recording and "Pause recording" or "Resume recording",
    primary = view.sel and "Overview" or "Refresh",
  }
end

local function send_dialog(open)
  mp.commandv("script-message", "vivi-dialog", ID, utils.format_json(dialog_payload(open)))
  if open then view.open = true end
end

local function refresh_dialog() if view.open then send_dialog(false) end end

local function open_dialog()
  tick()
  view.sel = nil
  send_dialog(true)
end

local function close_dialog()
  view.open = false
  mp.commandv("script-message", "vivi-dialog-close", ID)
end

-- Live content of the Home widget and the drawer tab (`vivi-content`, Vivi with the
-- "content" host feature): sent when it changes (the 5 s timer, recording, clear) and when
-- the drawer tab opens. Times are whole minutes, so playing updates it once a minute.
local sent = {}
local function day_label(d)
  local y, m, dd = d:match("^(%d+)-(%d+)-(%d+)$")
  return os.date("%a", os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 }))
end

local function live_content()
  local S = summary(7)
  local today = S.periods[1][2]
  local days = {}
  for _, b in ipairs(S.bars) do
    days[#days + 1] = { label = day_label(b[1]), bar = b[2] / math.max(S.max, 1), value = short(b[2]) }
  end
  local streak_txt = S.streak == 1 and "1-day streak" or string.format("%d-day streak", S.streak)
  local home = {
    replace = true,
    value = "Today " .. short(today),
    sub = "7 days " .. short(S.periods[2][2]) .. (S.streak > 0 and " · " .. streak_txt or "")
      .. (recording and "" or " · paused"),
    rows = days,
  }
  local rows = { { heading = true, label = "Totals" } }
  for _, q in ipairs(S.periods) do rows[#rows + 1] = { label = q[1], value = short(q[2]) } end
  rows[#rows + 1] = { label = "Streak", value = S.streak == 1 and "1 day" or string.format("%d days", S.streak) }
  rows[#rows + 1] = { label = "Video · audio", value = short(S.video) .. " · " .. short(S.audio) }
  if #S.top > 0 then
    rows[#rows + 1] = { heading = true, label = "Top artists & shows (7 days)" }
    for _, t in ipairs(S.top) do
      rows[#rows + 1] = { label = t[1], bar = t[2] / math.max(S.top[1][2], 1), value = short(t[2]) }
    end
  end
  rows[#rows + 1] = { heading = true, label = "Last 7 days" }
  for _, r in ipairs(days) do rows[#rows + 1] = r end
  local drawer_c = {
    replace = true,
    value = "Today " .. short(today),
    sub = (recording and "Recording" or "Recording paused: nothing is counted")
      .. " · 7 days " .. short(S.periods[2][2]),
    rows = rows,
  }
  return home, drawer_c
end

local function push_live(force)
  if not host_has("content") then return end
  local home, drawer_c = live_content()
  for _, x in ipairs({ { "home", home }, { "drawer", drawer_c } }) do
    local j = utils.format_json(x[2])
    if force or sent[x[1]] ~= j then
      sent[x[1]] = j
      mp.commandv("script-message", "vivi-content", ID, x[1], j)
    end
  end
end

local shown = false
local function show()
  tick()
  local S = summary()
  if native() then
    if view.open then close_dialog() return end -- Alt+S again closes it
    open_dialog()
    mp.commandv("script-message", "vivi-toast", toast_line(S))
    return
  end
  if shown and hide_timer then -- Alt+S again hides the panel
    hide_timer:kill(); hide_timer = nil; overlay:remove(); shown = false
    return
  end
  panel(S)
  shown = true
  mp.commandv("script-message", "vivi-toast", toast_line(S))
end

local function export()
  tick()
  save()
  local out = export_path
  local f = io.open(out, "w")
  if not f then toast("Could not write " .. out); return end
  local function q(s) return '"' .. tostring(s):gsub('"', '""') .. '"' end
  f:write("date,seconds,kind,artist_or_show,title\n")
  local keys = {}
  for key in pairs(rows) do keys[#keys + 1] = key end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local d, k, a, t = key:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
    f:write(string.format("%s,%d,%s,%s,%s\n", d, math.floor(rows[key] + 0.5), k, q(a), q(t)))
  end
  f:close()
  toast(string.format("Statistics exported to %s (%d rows)", out, #keys))
end

local function recorded()
  local total = 0
  for _, s in pairs(rows) do total = total + s end
  local f = io.open(file, "r")
  if f then f:close() end
  return total, f ~= nil
end

local function clear_now()
  rows = {}
  dirty = false
  os.remove(file)
  view.sel = nil
  toast("Playback statistics cleared")
  refresh_dialog()
  push_live()
end

-- Clear deletes everything recorded, so it asks first: Vivi's confirm dialog where the
-- host has it, else a second press within 10 s.
local clear_armed = nil
local function clear()
  tick()
  local total, has_file = recorded()
  if total < 1 and not has_file then toast("No playback statistics to clear"); return end
  if native() then
    mp.commandv("script-message", "vivi-confirm", ID, "clear", utils.format_json({
      title = "Playback Statistics", heading = "Clear playback statistics?",
      text = "This deletes " .. hms(total) .. " of recorded watch and listen time. It cannot be undone; export a CSV first to keep a copy.",
      ok = "Clear",
    }))
    return
  end
  local now = now_fn()
  if not clear_armed or now - clear_armed > 10 then
    clear_armed = now
    toast("Press Clear statistics again to delete " .. hms(total) .. " of statistics")
    return
  end
  clear_armed = nil
  clear_now()
end

local function set_record(on, quiet)
  tick() -- the time up to now counts with the old state
  recording = on
  o.record = on
  tick()
  if not quiet then toast(on and "Playback statistics: recording" or "Playback statistics: paused (not recording)") end
  refresh_dialog()
  push_live()
end

-- Palette / dialog / drawer: switch and save it as the setting, so it survives a restart.
local function toggle_record()
  set_record(not recording)
  mp.commandv("script-message", "vivi-setting", ID, "record", recording and "true" or "false")
end

-- Answers from the dialog / confirm: script-message-to playback_stats vivi-ui <json>.
local function on_ui(json)
  local ev = utils.parse_json(json or "")
  if type(ev) ~= "table" then return end
  local name, args = ev.event or "", ev.args or {}
  if name == "close" then
    view.open = false
  elseif name == "chip" then
    for _, p in ipairs(PERIODS) do if p[1] == (args[1] or ev.chip) then view.days = p[2] end end
    view.sel = nil
    refresh_dialog()
  elseif name == "search" or name == "edited" then
    view.query = ev.query or ""
    view.sel = nil
    refresh_dialog()
  elseif name == "filter" then
    local n, v = args[1], args[2]
    if v == nil and n then n, v = n:match("^(.-)\31(.*)$") end
    if n == "Group by" and v then view.group = v; view.sel = nil; refresh_dialog() end
  elseif name == "select" then
    local i = tonumber(args[1])
    i = i and i + 1 -- row index is 0-based
    view.sel = (i and view.list[i] and view.sel ~= i) and i or nil
    refresh_dialog()
  elseif name == "primary" then
    local i = tonumber(args[1])
    i = i and i + 1
    if i and i > 0 and view.list[i] and view.sel ~= i then view.sel = i else view.sel = nil end
    tick()
    refresh_dialog()
  elseif name == "act:Export CSV" then
    export()
  elseif name == "secondary" then
    toggle_record()
  elseif name == "act:Clear…" then
    clear()
  elseif name == "confirm" then
    if args[1] == "clear" and args[2] == "yes" then clear_now() end
  end
end

-- The drawer tab was opened: with live content it shows the numbers itself (sent again
-- now); on older Vivi its body is the static description, so they go to a toast.
local function drawer()
  tick()
  if host_has("content") then push_live(true) return end
  mp.commandv("script-message", "vivi-toast", toast_line(summary()))
end

-- Alt+S: with live content and something playing, toggle the drawer tab (the stats are
-- there); otherwise the dialog / OSD panel as before. The `show` message (palette, the
-- drawer's "Show summary" button) always opens the dialog.
local function show_key()
  if host_has("drawer") and host_has("content") and current ~= nil then
    tick()
    push_live()
    mp.commandv("script-message", "vivi-drawer", ID, "toggle")
    return
  end
  show()
end

options.read_options(o, "playback-stats", function(changed)
  -- Vivi changed a setting while playing.
  if changed.record and o.record ~= recording then set_record(o.record) end
  if changed.days then
    if shown and hide_timer then panel(summary()) end
    view.days = nil
    refresh_dialog()
  end
end)

recording = o.record
load()
mp.register_event("file-loaded", function() tick(); current = describe(); tick() end)
mp.register_event("end-file", function() tick(); current = nil; counting = false; save() end)
mp.observe_property("core-idle", "bool", function() tick() end)
mp.register_event("shutdown", function() tick(); save() end)
mp.add_periodic_timer(5, function() tick(); refresh_dialog(); push_live() end)
mp.add_periodic_timer(60, save)
push_live()
mp.add_forced_key_binding("Alt+s", "show", show_key)
mp.register_script_message("show", show)
mp.register_script_message("open", function() if native() then open_dialog() else show() end end)
mp.register_script_message("drawer", drawer)
mp.register_script_message("export", export)
mp.register_script_message("clear", clear)
mp.register_script_message("toggle-record", toggle_record)
mp.register_script_message("vivi-ui", on_ui)

if VIVI_TEST then
  return { tick = tick, show = show, export = export, clear = clear, summary = summary,
    summary_lines = summary_lines, toast_line = toast_line, show_name = show_name, hms = hms,
    streak = streak, set_record = set_record, toggle_record = toggle_record,
    recording = function() return recording end, opts = o, rows = function() return rows end,
    set_current = function(c) current = c end, save = save, load = load, file = file,
    set_clock = function(f) clock = f end, set_now = function(f) now_fn = f end,
    list_items = list_items, dialog_payload = dialog_payload, on_ui = on_ui, view = view,
    drawer = drawer, open_dialog = open_dialog, native = native, host_has = host_has,
    push_live = push_live, live_content = live_content, show_key = show_key,
    set_export_path = function(p) export_path = p end }
end
