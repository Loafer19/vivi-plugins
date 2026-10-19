-- Live check (not part of run.sh, needs the network and curl): a public, signed-out
-- search on music.youtube.com through the plugin's own request code.
--   XDG_DATA_HOME=$(mktemp -d) luajit tests/plugins/live-youtube-music.lua [query]
local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/youtube-music/youtube-music.lua", {})
local mp = package.loaded["mp"]
local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function run(t)
  if t.name ~= "subprocess" then return { status = 1 } end
  local args = {}
  for i, a in ipairs(t.args) do args[i] = q(a) end
  local cmd = table.concat(args, " ")
  local tmp
  if t.stdin_data then
    tmp = os.tmpname()
    local f = assert(io.open(tmp, "w")) f:write(t.stdin_data) f:close()
    cmd = cmd .. " < " .. tmp
  else
    cmd = cmd .. " < /dev/null"
  end
  local p = io.popen(cmd .. " 2>/dev/null")
  local out = p:read("*a")
  local ok, _, code = p:close()
  if tmp then os.remove(tmp) end
  return { status = (ok == true or ok == 0) and 0 or (code or 1), stdout = out, stderr = "" }
end
mp.command_native = run
mp.command_native_async = function(t, cb) local r = run(t) if cb then cb(true, r) end return {} end

local query = arg[1] or "daft punk"
P.on_ui(T.json_encode({ event = "search", query = query, args = {}, chip = "", source = "" }))
local last
for _, c in ipairs(T.calls) do if c[2] == "vivi-dialog" then last = c end end
T.ok(last, "dialog updated")
local d = T.json_decode(last[4])
T.ok(d.rows and #d.rows >= 3, "live search returned rows (status: " .. tostring(d.status) .. ")")
for i = 1, math.min(5, d.rows and #d.rows or 0) do
  local r = d.rows[i]
  print(string.format("%d. %s — %s [%s] %s", i, r.title or "", r.sub or "", r.badge or "", r.cover and "cover" or "no cover"))
  T.ok(r.cover and r.cover:find("^https://"), "row " .. i .. " has an https cover")
end
T.done("youtube-music live")
