-- Test driver loaded next to scrobbler.lua in a headless mpv: records the messages the
-- plugin sends to Vivi (vivi-toast, vivi-setting) and runs a scripted session.
local mp = require "mp"
local utils = require "mp.utils"
local OUT = os.getenv("ITEST_OUT")
local MEDIA = os.getenv("ITEST_MEDIA")
local PHASE = os.getenv("ITEST_PHASE")
local function rec(kind, ...)
  local f = io.open(OUT .. "/events.jsonl", "a")
  f:write(utils.format_json({ t = mp.get_time(), kind = kind, args = { ... } }), "\n")
  f:close()
end
local function ctl(what) mp.command_native({ name = "subprocess", args = { "curl", "-s", os.getenv("ITEST_MOCK") .. "/ctl/" .. what }, playback_only = false, capture_stdout = true }) end
mp.register_script_message("vivi-toast", function(...) rec("toast", ...) end)
mp.register_script_message("vivi-setting", function(...) rec("setting", ...) end)
local function to(name) mp.commandv("script-message-to", "scrobbler", name) end
local steps
local function run(i)
  local s = steps[i]
  if not s then return end
  mp.add_timeout(s[1], function() rec("step", s[2]) s[3]() run(i + 1) end)
end
local loaded = 0
mp.register_event("file-loaded", function() loaded = loaded + 1 rec("file", mp.get_property("filename")) end)
if PHASE == "online" then
  steps = {
    { 0.5, "connect", function() to("lastfm_connect") end },
    { 8, "play tone x2 (loop-file=1)", function()
      mp.set_property("loop-file", "1")
      mp.commandv("loadfile", MEDIA .. "/tone.flac")
    end },
    { 2, "love", function() to("love") end },
    { 8, "play podcast", function() mp.set_property("loop-file", "no") mp.commandv("loadfile", MEDIA .. "/talk.mp3") end },
    { 4, "status", function() to("status") end },
    { 2, "play mp3 with TXXX mbid", function() mp.commandv("loadfile", MEDIA .. "/tone550.mp3") end },
    { 4, "quit", function() mp.command("quit") end },
  }
elseif PHASE == "offline" then
  steps = {
    { 0.2, "server down", function() ctl("down") end },
    { 0.3, "play tone offline", function() mp.commandv("loadfile", MEDIA .. "/tone.flac") end },
    { 4, "play mp3 offline", function() mp.commandv("loadfile", MEDIA .. "/tone550.mp3") end },
    { 4, "server up + flush", function() ctl("up") to("flush") end },
    { 3, "status", function() to("status") end },
    { 2, "disconnect", function() to("lastfm_disconnect") end },
    { 1, "quit", function() mp.command("quit") end },
  }
end
run(1)
