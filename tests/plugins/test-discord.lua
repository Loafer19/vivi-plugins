local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/discord/discord.lua", { pkgdir = "/pkg", ["app-id"] = "123" })

-- Defaults: everything shown, app name in the member list, YouTube art on, no link button.
local a = table.concat(P.helper_args("/pkg/bin/vivi-discord", "/run/s"), " ")
T.eq(a, "/pkg/bin/vivi-discord --ipc /run/s --app-id 123 --image  --show all --display app --art yes --button no --token 0-0",
  "default helper args")

-- Privacy and display settings map to the helper's flags.
P.o.show = "Music only"
P.o["status-name"] = "Title"
P.o["cover-art"] = false
P.o["link-button"] = true
P.o["hide-names"] = true
P.o.image = "logo"
local args = P.helper_args("/pkg/bin/vivi-discord", "/run/s")
a = table.concat(args, " ")
T.ok(a:find("--show music", 1, true), "music only")
T.ok(a:find("--display title", 1, true), "title in the member list")
T.ok(a:find("--art no", 1, true), "art off")
T.ok(a:find("--button yes", 1, true), "button on")
T.eq(args[#args], "--hide-names", "hide names flag last")
P.o["status-name"] = "Artist"
T.ok(table.concat(P.helper_args("x", "y"), " "):find("--display artist", 1, true), "artist")

-- start(): the helper runs from the package's bin folder; the status is reset first.
T.props["user-data/discord/status"] = "Connected to Discord"
local mp = package.loaded["mp"]
mp.command_native_async = function(t) T.calls[#T.calls + 1] = t return { job = 1 } end
T.calls = {}
P.start()
local spawned
for _, c in ipairs(T.calls) do
  if c.name == "subprocess" then spawned = c end
end
T.ok(spawned, "helper started")
T.eq(spawned.args[1], "/pkg/bin/vivi-discord", "helper path")
T.eq(spawned.playback_only, false, "keeps running between files")
T.eq(T.props["user-data/discord/status"], "Starting…", "stale status cleared")
T.ok(T.props["input-ipc-server"], "IPC server turned on")
local tok = T.props["user-data/discord/helper"]
T.ok(tok and tok ~= "", "helper token published")
T.eq(spawned.args[#spawned.args - 1], tok, "helper gets the token")
-- A second start (two settings changed in a row) hands the token to the new helper only.
P.start()
T.ok(T.props["user-data/discord/helper"] ~= tok, "old helper's token revoked")

-- Connection status: a Vivi toast with the helper's status.
T.props["user-data/discord/status"] = "Discord not reachable: Discord is not running"
T.calls = {}
P.show_status()
local c = T.calls[1]
T.eq(c[2], "vivi-toast", "status is a Vivi toast")
T.eq(c[3], "Discord Rich Presence: Discord not reachable: Discord is not running", "status text")
T.props["user-data/discord/status"] = nil
T.calls = {}
P.show_status()
T.eq(T.calls[1][3], "Discord Rich Presence: Starting…", "no status yet")

-- No package folder (broken install): a toast, no helper.
P.o.pkgdir = ""
T.calls = {}
P.start()
T.eq(T.calls[1][2], "vivi-toast", "missing helper toast")
T.done("discord")
