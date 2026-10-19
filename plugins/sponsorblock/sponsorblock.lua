-- @name SponsorBlock
-- @version 1.2.0
-- @author Vivi
-- @description Skip SponsorBlock segments in YouTube streams (Vivi plugin package).
--
-- Keys: Alt+k        skip   skip the current (or announced) segment
--       Alt+Shift+k  undo   go back to the start of the last skipped segment (it is
--                           then played, not skipped again); inside a muted segment:
--                           unmute it. No time limit: it undoes the most recent skip.
-- Per category: "intro=ask outro=skip filler=off" overrides the global mode.
-- Mute segments (actionType "mute") are muted instead of skipped.
-- Works for YouTube URLs (also the entries the YouTube plugin adds to the playlist) and
-- for files downloaded by it / yt-dlp, whose names end in "[<video id>]".
-- Network: GET <api>/api/skipSegments/<sha256 prefix>?categories=[...]&actionTypes=[...] via curl.
local mp = require "mp"
local options = require "mp.options"
local utils = require "mp.utils"

local o = {
  categories = "sponsor selfpromo interaction",
  mode = "Skip automatically",
  chapters = true,
  api = "https://sponsor.ajay.app",
  ["local"] = true,
  notice = true,
  mute = true,
  per_category = "",
  pkgdir = "", -- set by Vivi; declared so mp.options does not warn about it
}

local segments = {}   -- { {a, b, category, action}, ... }; action "skip" or "mute"
local skipped = {}    -- index -> true (auto mode: skip each once per file)
local announced = nil -- index of the segment offered for Alt+K
local video_id = nil
local last_skip = nil -- { index, from } of the last automatic/manual skip (undo)
local allowed = {}    -- index -> true: undone, play it through
local muted = nil     -- index of the mute segment we muted (we restore `mute` after it)

local function toast(msg, secs)
  mp.osd_message(msg, secs or 3)
  mp.commandv("script-message", "vivi-toast", msg)
end

local NAMES = {
  sponsor = "Sponsor", selfpromo = "Self-promotion", interaction = "Interaction reminder",
  intro = "Intro", outro = "Outro", preview = "Preview", music_offtopic = "Non-music part",
  filler = "Filler",
}

-- YouTube video id from a URL, or nil.
local function youtube_id(url)
  if not url then return nil end
  local patterns = {
    "youtube%.com/watch%?.-v=([%w_-]+)", "youtube%.com/shorts/([%w_-]+)",
    "youtube%.com/live/([%w_-]+)", "youtube%.com/embed/([%w_-]+)",
    "youtube%-nocookie%.com/embed/([%w_-]+)", "youtu%.be/([%w_-]+)",
    "music%.youtube%.com/watch%?.-v=([%w_-]+)",
  }
  for _, p in ipairs(patterns) do
    local id = url:match(p)
    if id and #id == 11 then return id end
  end
  local ytdl = url:match("^ytdl://([%w_-]+)$")
  if ytdl and #ytdl == 11 then return ytdl end
  return nil
end

-- Video id of a local file named by yt-dlp's default template: "Title [dQw4w9WgXcQ].mp4".
local function file_id(path)
  if not path or path:find("://") then return nil end
  local name = path:match("([^/\\]+)$") or path
  local id = name:match("%[([%w_-]+)%][^%[%]]*%.[%w]+$")
  if id and #id == 11 then return id end
  return nil
end

-- Per-category overrides from "intro=ask outro=skip filler=off" -> { intro = "ask", ... }.
local function overrides()
  local out = {}
  for c, a in (o.per_category or ""):gmatch("([%w_]+)%s*[=:]%s*(%a+)") do
    a = a:lower()
    if a == "skip" or a == "ask" or a == "off" then out[c] = a end
  end
  return out
end

-- What to do when a skip segment of category `cat` starts: "skip" or "ask".
local function action_for(cat)
  local a = overrides()[cat]
  if a == "skip" or a == "ask" then return a end
  return (o.mode or ""):find("^Ask") and "ask" or "skip"
end

local function categories()
  local list, off = {}, overrides()
  for c in (o.categories or ""):gmatch("[%w_]+") do
    if off[c] ~= "off" then list[#list + 1] = '"' .. c .. '"' end
  end
  for c, a in pairs(off) do
    -- A category named only in the overrides (e.g. "intro=ask") is fetched too.
    if a ~= "off" and not (" " .. (o.categories or "") .. " "):find("[%s]" .. c .. "[%s]") then
      list[#list + 1] = '"' .. c .. '"'
    end
  end
  if #list == 0 then list = { '"sponsor"' } end
  table.sort(list)
  return "[" .. table.concat(list, ",") .. "]"
end

local function action_types()
  return o.mute and '["skip","mute"]' or '["skip"]'
end

local function sha_prefix(id)
  for _, cmd in ipairs({ { "sha256sum" }, { "shasum", "-a", "256" } }) do
    local r = mp.command_native({ name = "subprocess", args = cmd, stdin_data = id,
      capture_stdout = true, capture_stderr = true, playback_only = false })
    if r and r.status == 0 and r.stdout then
      local h = r.stdout:match("^(%x+)")
      if h and #h == 64 then return h:sub(1, 4) end
    end
  end
  return nil
end

local function urlencode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Segment list for `id` from a skipSegments answer (hash-prefix form or plain array).
local function parse(body, id)
  local v = utils.parse_json(body or "")
  if type(v) ~= "table" then return {} end
  local list = v
  if v[1] and v[1].videoID then
    list = {}
    for _, e in ipairs(v) do if e.videoID == id then list = e.segments or {} end end
  end
  local out = {}
  for _, s in ipairs(list) do
    local act = s.actionType or "skip"
    if type(s.segment) == "table" and (act == "skip" or (act == "mute" and o.mute)) then
      local a, b = tonumber(s.segment[1]), tonumber(s.segment[2])
      if a and b and b > a then out[#out + 1] = { a, b, s.category or "sponsor", act } end
    end
  end
  table.sort(out, function(x, y) return x[1] < y[1] end)
  return out
end

local function add_chapters()
  if not o.chapters or #segments == 0 then return end
  local list = mp.get_property_native("chapter-list") or {}
  for _, s in ipairs(segments) do
    local n = NAMES[s[3]] or s[3]
    if s[4] == "mute" then
      list[#list + 1] = { time = s[1], title = n .. " (muted)" }
      list[#list + 1] = { time = s[2], title = "End of muted " .. n:lower() }
    else
      list[#list + 1] = { time = s[1], title = n }
      list[#list + 1] = { time = s[2], title = "End of " .. n:lower() }
    end
  end
  table.sort(list, function(x, y) return x.time < y.time end)
  mp.set_property_native("chapter-list", list)
end

local function fetch(id)
  local base = (o.api or "https://sponsor.ajay.app"):gsub("/+$", "")
  local prefix = sha_prefix(id)
  local q = "categories=" .. urlencode(categories()) .. "&actionTypes=" .. urlencode(action_types())
  local url
  if prefix then
    url = base .. "/api/skipSegments/" .. prefix .. "?" .. q
  else
    url = base .. "/api/skipSegments?videoID=" .. id .. "&" .. q
  end
  mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
    capture_stderr = true, args = { "curl", "-sS", "-m", "15", "-A", "Vivi SponsorBlock", url } },
    function(ok, r)
      if id ~= video_id then return end
      if not ok or not r or r.status ~= 0 then
        mp.msg.warn("SponsorBlock request failed: " .. tostring(r and r.stderr))
        return
      end
      segments = parse(r.stdout, id)
      mp.msg.info(string.format("%d segment(s) for %s", #segments, id))
      if #segments > 0 then
        toast(string.format("SponsorBlock: %d segment%s", #segments, #segments == 1 and "" or "s"))
        add_chapters()
      end
    end)
end

local function skip_to(i)
  local s = segments[i]
  if not s then return end
  skipped[i] = true
  announced = nil
  local from = mp.get_property_number("time-pos") or s[1]
  last_skip = { i, from }
  mp.set_property_number("time-pos", s[2])
  local what = (NAMES[s[3]] or s[3]):lower()
  if o.notice then
    toast(string.format("Skipped %s (%.0f s) — Alt+Shift+K to undo", what, s[2] - s[1]), 5)
  else
    mp.msg.info("skipped " .. what)
  end
end

local function unmute()
  if muted then
    muted = nil
    mp.set_property_native("mute", false)
  end
end

-- Undo the last skip: back to where it happened; that segment is then played through.
-- Inside a segment we muted, Undo unmutes it instead.
local function undo()
  if muted then
    allowed[muted] = true
    unmute()
    toast("Unmuted — playing the segment with sound")
    return
  end
  if not last_skip then toast("Nothing to undo") return end
  local i, from = last_skip[1], last_skip[2]
  last_skip = nil
  allowed[i] = true
  announced = i
  mp.set_property_number("time-pos", math.max(0, math.min(from, segments[i] and segments[i][1] or from)))
  toast("Skip undone — playing the segment")
end

-- Mute segments: mute while inside one, restore the sound after it (only if we muted).
local function check_mute(t)
  if muted then
    local s = segments[muted]
    if not s or t < s[1] or t >= s[2] then unmute() end
  end
  if muted then return end
  for i, s in ipairs(segments) do
    if s[4] == "mute" and not allowed[i] and t >= s[1] and t < s[2] - 0.5 then
      if mp.get_property_native("mute") then return end -- already muted by the user
      muted = i
      mp.set_property_native("mute", true)
      if o.notice then
        toast(string.format("Muted %s (%.0f s) — Alt+Shift+K to unmute", (NAMES[s[3]] or s[3]):lower(), s[2] - s[1]), 5)
      end
      return
    end
  end
end

local function on_time(_, t)
  if not t or #segments == 0 then return end
  check_mute(t)
  for i, s in ipairs(segments) do
    if s[4] ~= "mute" and t >= s[1] and t < s[2] - 0.5 then
      if allowed[i] then
        -- undone: play through
      elseif action_for(s[3]) == "skip" then
        if not skipped[i] then skip_to(i) end
      elseif announced ~= i then
        announced = i
        toast((NAMES[s[3]] or s[3]) .. " — press Alt+K to skip", 5)
      end
      return
    end
  end
  announced = nil
end

local function skip_key()
  local t = mp.get_property_number("time-pos")
  if announced then skip_to(announced); return end
  for i, s in ipairs(segments) do
    if t and t >= s[1] and t < s[2] then skip_to(i); return end
  end
  toast("No SponsorBlock segment here")
end

options.read_options(o, "sponsorblock", function() if video_id then fetch(video_id) end end)

mp.register_event("file-loaded", function()
  unmute()
  segments, skipped, announced, last_skip, allowed = {}, {}, nil, nil, {}
  local path = mp.get_property("path")
  video_id = youtube_id(path) or youtube_id(mp.get_property("stream-open-filename"))
    or (o["local"] and file_id(path)) or nil
  if video_id then fetch(video_id) end
end)
mp.observe_property("time-pos", "number", on_time)
mp.add_forced_key_binding("Alt+k", "skip", skip_key)
mp.add_forced_key_binding("Alt+K", "undo", undo)
mp.register_script_message("undo", undo)
mp.register_event("end-file", unmute)

-- For tests: `script-message-to sponsorblock selftest` prints parser results and quits.
mp.register_script_message("selftest", function()
  local function show(x) return x and tostring(x) or "nil" end
  print("SELFTEST id " .. show(youtube_id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1")) ..
    " " .. show(youtube_id("https://youtu.be/aqz-KE-bpKQ")) .. " " .. show(youtube_id("https://x.org/a")))
  local p = parse('[{"videoID":"aqz-KE-bpKQ","segments":[{"category":"outro","actionType":"skip","segment":[494.6,618.7]}]}]', "aqz-KE-bpKQ")
  print("SELFTEST parse " .. #p .. " " .. show(p[1] and p[1][3]))
  print("SELFTEST prefix " .. show(sha_prefix("aqz-KE-bpKQ")))
  mp.command("quit")
end)

if VIVI_TEST then
  return { youtube_id = youtube_id, file_id = file_id, parse = parse, categories = categories,
    action_for = action_for, action_types = action_types, add_chapters = add_chapters,
    set_segments = function(v) segments, skipped, allowed, muted, last_skip, announced = v, {}, {}, nil, nil, nil end,
    on_time = on_time, undo = undo, skip_key = skip_key, opts = o,
    skipped = function() return skipped end }
end
