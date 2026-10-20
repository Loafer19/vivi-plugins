local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/discord/discord.lua", { pkgdir = "/pkg", ["app-id"] = "123" })

-- Defaults: video titles hidden, music shown, app name in the member list, YouTube art on, no link button.
local a = table.concat(P.helper_args("/pkg/bin/vivi-discord", "/run/s"), " ")
T.eq(a, "/pkg/bin/vivi-discord --ipc /run/s --app-id 123 --image  --show all --display app --art yes --button no --hide-video-titles yes --token 0-0",
  "default helper args")

-- Custom application ID: the user's image setting as is (no "vivi" asset, their app has none).
local id, img = P.app()
T.eq(id, "123", "custom app id kept")
T.eq(img, "", "custom app: no default image")
P.o.image = "mylogo"
id, img = P.app()
T.eq(img, "mylogo", "custom app: own large image")
P.o.image = ""

-- No application ID (fresh install): Vivi's own application and its "vivi" art asset.
P.o["app-id"] = ""
a = table.concat(P.helper_args("/pkg/bin/vivi-discord", "/run/s"), " ")
T.ok(a:find("--app-id 1562145928717271100 --image vivi ", 1, true), "default Vivi app id and vivi image")
T.eq(P.VIVI_APP_ID, "1562145928717271100", "Vivi's application ID")
P.o.image = "https://img.example/c.png"
id, img = P.app()
T.eq(id, P.VIVI_APP_ID, "default app with own image")
T.eq(img, "https://img.example/c.png", "own image wins over the vivi asset")
P.o.image = ""
-- Whitespace only counts as empty; a padded custom ID is trimmed.
P.o["app-id"] = "  \t"
id, img = P.app()
T.eq(id, P.VIVI_APP_ID, "blank id -> Vivi's")
T.eq(img, "vivi", "blank id -> vivi image")
P.o["app-id"] = " 987654321 "
T.eq(P.app(), "987654321", "custom id trimmed")
-- Not a number: Vivi's application (start() warns), not a helper that refuses to run.
P.o["app-id"] = "my app"
local _, _, bad
id, img, bad = P.app()
T.eq(id, P.VIVI_APP_ID, "invalid custom id falls back to Vivi's")
T.eq(img, "vivi", "invalid custom id: vivi image")
T.ok(bad, "invalid custom id flagged")
P.o["app-id"] = "123"

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
P.o["hide-video-titles"] = false
T.ok(table.concat(P.helper_args("x", "y"), " "):find("--hide-video-titles no", 1, true), "video titles shown when turned off")
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

-- An invalid custom ID: a toast, and the helper still starts with Vivi's application.
P.o["app-id"] = "abc"
T.calls = {}
P.start()
local warned, spawned2
for _, c in ipairs(T.calls) do
  if c[2] == "vivi-toast" and c[3]:find("digits only", 1, true) then warned = true end
  if c.name == "subprocess" then spawned2 = c end
end
T.ok(warned, "invalid id toast")
T.ok(spawned2 and table.concat(spawned2.args, " "):find("--app-id " .. P.VIVI_APP_ID, 1, true), "helper uses Vivi's app")
P.o["app-id"] = "123"

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
