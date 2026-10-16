-- @name Remote Control
-- @version 1.1.0
-- @author Vivi
-- @description Phone remote control page on the local network (Vivi plugin package).
--
-- The web server is the native helper bin/vivi-remote (installed with the package for
-- this platform). This script turns on mpv's JSON IPC server (input-ipc-server), creates
-- a PIN when none is set (saved with `script-message vivi-setting`), starts the helper and
-- restarts it when the port, PIN or network setting changes. The helper drives the player
-- over IPC and publishes user-data/remote/url (address and PIN) and user-data/remote/pair
-- (address with the PIN in the URL fragment), which "Show QR code" hands to Vivi's QR
-- dialog (`script-message vivi-qr`, Vivi 0.10.1+; older versions show a toast only).
local mp = require "mp"
local options = require "mp.options"

local o = { port = "8765", pin = "", lan_only = "true", pkgdir = "" }
local windows = package.config:sub(1, 1) == "\\"
local job

local function toast(msg, secs)
  mp.commandv("script-message", "vivi-toast", msg, tostring(secs or 6))
end

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

-- 6 random digits (from /dev/urandom when there is one).
local function random_pin()
  local f = io.open("/dev/urandom", "rb")
  if f then
    local b = f:read(4)
    f:close()
    local n = 0
    for i = 1, #b do n = n * 256 + b:byte(i) end
    return string.format("%06d", n % 1000000)
  end
  math.randomseed(os.time() + math.floor(mp.get_time() * 1e6) + tonumber(mp.get_property("pid", "0")))
  return string.format("%06d", math.random(0, 999999))
end

-- Port 1024–65535, else nil.
local function valid_port(p)
  local n = tonumber((tostring(p or "")):match("^%s*(%d+)%s*$"))
  if n and n >= 1024 and n <= 65535 then return n end
  return nil
end

-- PIN without spaces; nil when too short to protect anything (under 4 characters).
local function clean_pin(p)
  p = (p or ""):gsub("%s", "")
  if #p < 4 then return nil end
  return p
end

local function truthy(v)
  v = tostring(v or ""):lower()
  return v ~= "false" and v ~= "no" and v ~= "0" and v ~= "off"
end

local function helper_args(exe, ipc, port, pin, lan_only)
  return { exe, "--ipc", ipc, "--port", tostring(port), "--pin", pin, "--lan-only", lan_only and "yes" or "no" }
end

local function stop()
  if job then
    mp.abort_async_command(job)
    job = nil
  end
  mp.set_property("user-data/remote/pair", "")
end

local last = {}

local function save_pin(pin)
  o.pin = pin
  last.pin = pin
  mp.commandv("script-message", "vivi-setting", "remote-control", "pin", pin)
end

local function start()
  stop()
  last = { port = o.port, pin = o.pin, lan_only = o.lan_only }
  local exe = helper("vivi-remote")
  if not exe then
    toast("Remote Control: helper not found, reinstall the plugin")
    return
  end
  local port = valid_port(o.port)
  if not port then
    toast("Remote Control: the port must be a number from 1024 to 65535")
    mp.set_property("user-data/remote/url", "Invalid port " .. tostring(o.port))
    return
  end
  local pin = clean_pin(o.pin)
  if not pin then
    local first = (o.pin or ""):gsub("%s", "") == ""
    pin = random_pin()
    save_pin(pin)
    if first then
      toast("Remote Control is on: Settings → Extensions → Remote Control → Show QR code, then scan it with your phone", 8)
    else
      toast("Remote Control: the PIN needs at least 4 characters, a new one was made")
    end
  end
  local args = helper_args(exe, ipc_path(), port, pin, truthy(o.lan_only))
  mp.set_property("user-data/remote/url", "starting…")
  local me
  me = mp.command_native_async({ name = "subprocess", args = args, playback_only = false }, function(_, r)
    if job == me then job = nil end
    if r and r.status and r.status ~= 0 and not r.killed_by_us then
      mp.msg.warn("vivi-remote exited with " .. tostring(r.status) .. " " .. tostring(r.error_string or ""))
    end
  end)
  job = me
end

-- "Show QR code": Vivi's QR dialog with the pairing link, plus a toast for Vivi versions
-- without the dialog.
local function show_address()
  local url = mp.get_property_native("user-data/remote/url") or ""
  local pair = mp.get_property_native("user-data/remote/pair") or ""
  if not job or pair == "" then
    toast("Remote Control: " .. (url ~= "" and url or "not running"))
    return
  end
  local caption = "Scan with your phone's camera, or open " .. url:gsub(" · PIN ", " and enter PIN ")
  if not truthy(o.lan_only) then
    caption = caption .. ". Reachable from any network: keep the PIN secret"
  end
  mp.commandv("script-message", "vivi-qr", "Remote Control", pair, caption)
  toast("Remote control: " .. url, 10)
end

options.read_options(o, "remote-control", function()
  -- Our own vivi-setting for a generated PIN comes back here: no restart needed.
  if o.port ~= last.port or o.pin ~= last.pin or o.lan_only ~= last.lan_only then
    start()
  end
end)
mp.register_script_message("address", show_address)
-- "New PIN": phones paired with the old one have to scan the new QR code.
mp.register_script_message("new_pin", function()
  save_pin(random_pin())
  start()
  toast("Remote Control: new PIN " .. o.pin .. "; other phones are signed out")
end)
mp.register_event("shutdown", stop)

if VIVI_TEST then
  return { valid_port = valid_port, clean_pin = clean_pin, truthy = truthy, helper_args = helper_args,
           random_pin = random_pin, start = start, show_address = show_address, o = o }
end
start()
