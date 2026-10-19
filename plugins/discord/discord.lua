-- @name Discord Rich Presence
-- @version 1.1.0
-- @author Vivi
-- @description Discord status from what Vivi plays (Vivi plugin package).
--
-- The work is done by the native helper bin/vivi-discord (installed with the package for
-- this platform): this script makes sure mpv's JSON IPC server (input-ipc-server) is on,
-- starts the helper with the socket path and the settings, restarts it when a setting
-- changes and stops it on shutdown. The helper polls mpv over IPC, talks to Discord's
-- local IPC socket / named pipe and reports its state in user-data/discord/status.
local mp = require "mp"
local options = require "mp.options"

local o = {
  ["app-id"] = "", show = "Music and videos", ["hide-names"] = false,
  ["status-name"] = "Application name", ["cover-art"] = true, ["link-button"] = false,
  image = "", pkgdir = "",
}
local windows = package.config:sub(1, 1) == "\\"
local job
-- Token of the helper that should run: a helper whose token is no longer in
-- user-data/discord/helper exits by itself. abort_async_command alone can lose the race
-- when settings change twice in a row (two helpers kept running).
local gen = 0
local function token() return mp.get_property("pid", "0") .. "-" .. gen end

local function toast(msg)
  mp.commandv("script-message", "vivi-toast", msg)
end

-- mpv's IPC endpoint; turned on here when nobody set one.
local function ipc_path()
  local cur = mp.get_property("input-ipc-server", "")
  if cur ~= "" then return cur end
  local pid = mp.get_property("pid", "0")
  local p
  if windows then
    p = "\\\\.\\pipe\\vivi-mpv-" .. pid
  else
    p = (os.getenv("XDG_RUNTIME_DIR") or os.getenv("TMPDIR") or "/tmp") .. "/vivi-mpv-" .. pid .. ".sock"
  end
  mp.set_property("input-ipc-server", p)
  return p
end

local function helper(name)
  local dir = o.pkgdir
  if not dir or dir == "" then return nil end
  return dir .. (windows and "\\bin\\" or "/bin/") .. name .. (windows and ".exe" or "")
end

local function yn(v) return (v == true or v == "yes" or v == "true") and "yes" or "no" end

-- Command line of the helper for the current settings.
local function helper_args(exe, ipc)
  local display = ({ Title = "title", Artist = "artist" })[o["status-name"]] or "app"
  local args = {
    exe, "--ipc", ipc, "--app-id", o["app-id"], "--image", o.image,
    "--show", o.show == "Music only" and "music" or "all",
    "--display", display,
    "--art", yn(o["cover-art"]),
    "--button", yn(o["link-button"]),
    "--token", token(),
  }
  if yn(o["hide-names"]) == "yes" then args[#args + 1] = "--hide-names" end
  return args
end

local function stop()
  mp.set_property("user-data/discord/helper", "")
  if job then
    mp.abort_async_command(job)
    job = nil
  end
end

local function start()
  stop()
  local exe = helper("vivi-discord")
  if not exe then
    toast("Discord Rich Presence: helper not found, reinstall the plugin")
    return
  end
  gen = gen + 1
  mp.set_property("user-data/discord/helper", token())
  -- A stale "Connected" from the previous helper must not show while this one starts.
  mp.set_property("user-data/discord/status", "Starting…")
  local me
  me = mp.command_native_async({ name = "subprocess", args = helper_args(exe, ipc_path()),
                                 playback_only = false }, function(ok, r)
    if job == me then job = nil end
    if r and r.status and r.status ~= 0 and not r.killed_by_us then
      mp.msg.warn("vivi-discord exited with " .. tostring(r.status) .. " " .. tostring(r.error_string or ""))
      mp.set_property("user-data/discord/status", "The helper stopped (exit " .. tostring(r.status) .. ")")
    end
  end)
  job = me
end

local function show_status()
  -- native: mp.get_property formats a user-data string as JSON (with quotes).
  local s = mp.get_property_native("user-data/discord/status", "")
  if type(s) ~= "string" then s = "" end
  if s == "" then s = job and "Starting…" or "Not running" end
  toast("Discord Rich Presence: " .. s)
end

options.read_options(o, "discord", start)
mp.register_script_message("status", show_status)
mp.register_event("shutdown", stop)

if VIVI_TEST then
  return { o = o, helper_args = helper_args, start = start, show_status = show_status }
end
start()
