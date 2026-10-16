local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/remote-control/remote-control.lua", { pkgdir = "/pkg" })
T.eq(P.valid_port("8765"), 8765, "port")
T.eq(P.valid_port(" 9000 "), 9000, "port with spaces")
T.eq(P.valid_port("80"), nil, "privileged port")
T.eq(P.valid_port("70000"), nil, "port too big")
T.eq(P.valid_port("87a"), nil, "port not a number")
T.eq(P.clean_pin(" 12 34 "), "1234", "pin spaces")
T.eq(P.clean_pin("123"), nil, "pin too short")
T.ok(P.random_pin():match("^%d%d%d%d%d%d$"), "random pin")
T.eq(P.truthy("true"), true, "lan only on")
T.eq(P.truthy("false"), false, "lan only off")
local a = P.helper_args("/pkg/bin/vivi-remote", "/tmp/s", 8765, "1234", false)
T.eq(table.concat(a, " "), "/pkg/bin/vivi-remote --ipc /tmp/s --port 8765 --pin 1234 --lan-only no", "helper args")

-- First start without a PIN: one is made, saved with vivi-setting, the helper started.
P.start()
local saved, spawned
for _, c in ipairs(T.calls) do
  if c[1] == "script-message" and c[2] == "vivi-setting" then saved = c end
  if c.name == "subprocess" then spawned = c end
end
T.ok(saved and saved[3] == "remote-control" and saved[4] == "pin" and saved[5]:match("^%d+$"), "pin saved")
T.ok(spawned, "helper started")
T.eq(spawned.args[1], "/pkg/bin/vivi-remote", "helper path")
T.eq(spawned.args[#spawned.args], "yes", "LAN only by default")

-- Show QR code: vivi-qr with the pairing link from the helper (helper still running).
local mp = package.loaded["mp"]
mp.command_native_async = function(t) T.calls[#T.calls + 1] = t return { job = 1 } end
mp.abort_async_command = function() end
P.start()
T.calls = {}
T.props["user-data/remote/url"] = "http://192.168.1.5:8765 · PIN 123456"
T.props["user-data/remote/pair"] = "http://192.168.1.5:8765/#pin=123456"
P.show_address()
local qr
for _, c in ipairs(T.calls) do
  if c[1] == "script-message" and c[2] == "vivi-qr" then qr = c end
end
T.ok(qr, "vivi-qr sent")
T.eq(qr[4], "http://192.168.1.5:8765/#pin=123456", "QR carries the pairing link")
T.ok(qr[5]:find("enter PIN 123456", 1, true), "caption has the PIN")

-- A too short PIN is replaced.
P.o.pin = "12"
T.calls = {}
P.start()
local np
for _, c in ipairs(T.calls) do
  if c[2] == "vivi-setting" then np = c[5] end
end
T.ok(np and #np == 6, "short pin replaced")
T.done("remote-control")
