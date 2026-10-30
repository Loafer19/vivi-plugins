local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/offline-downloads/offline-downloads.lua")
T.eq(P.classify("https://www.youtube.com/watch?v=abc"), "ytdlp", "youtube")
T.eq(P.known_site("https://m.youtube.com/watch?v=abc"), true, "known site")
T.eq(P.known_site("http://radio.example:8000/live"), false, "unknown site")
T.eq(P.classify("https://example.org/song.MP3?x=1"), "file", "mp3 file")
T.eq(P.classify("https://archive.org/download/item/track"), "file", "archive.org download")
T.eq(P.classify("https://prod-1.storage.jamendo.com/?trackid=1&format=mp31"), "file", "jamendo storage")
T.eq(P.classify("https://radio.example/live.pls"), "list", "pls")
T.eq(P.classify("https://cdn.example/x/index.m3u8"), "hls", "hls")
local k, n = P.classify_headers("ytdlp", "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\nicy-name: X\r\n")
T.eq(k, "stream", "icy is a stream")
k, n = P.classify_headers("ytdlp", "HTTP/1.1 200 OK\r\nContent-Type: audio/ogg\r\nContent-Length: 1234\r\n")
T.eq(k, "file", "audio with length is a file")
T.eq(n, 1234, "length")
T.eq(P.classify_headers("ytdlp", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"), "ytdlp", "html stays yt-dlp")
T.eq(P.classify_headers("ytdlp", "HTTP/1.1 200 OK\r\nContent-Type: audio/mpeg\r\n"), "stream", "audio without length is live")
T.eq(P.classify_headers("file", "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\n"), "hls", "hls by type")
T.eq(P.first_list_url("[playlist]\nFile1=http://a.example:8000/stream\nTitle1=x"), "http://a.example:8000/stream", "pls url")
T.eq(P.first_list_url("#EXTM3U\n#EXTINF:-1,x\nhttps://b.example/live\n"), "https://b.example/live", "m3u url")
T.eq(P.file_name("https://example.org/a%20b.flac?dl=1", "file"), "a b.flac", "file name")
T.eq(P.file_name("https://example.org/", "file"), "example.org.mp3", "host fallback")
T.ok(P.file_name("http://radio.example:8000/live", "stream"):match("^live %d+%-%d+%-%d+ %d+%.mp3$"), "stream name")
local pct, total, title = P.parse_progress("[vivi]  12.5%|  3.40MiB|Song\n[vivi]  50.0%|  3.40MiB|Song\n")
T.eq(pct, 50, "progress pct")
T.eq(total, "3.40MiB", "progress total")
T.eq(title, "Song", "progress title")
T.eq(P.human(1572864), "1.5 MB", "human")
-- Queue transitions (the runner is kept busy so nothing starts).
P.set_active({ item = {}, t0 = 0 })
P.enqueue("https://example.org/one.mp3")
P.enqueue("https://example.org/one.mp3")
P.enqueue("not a url")
T.eq(#P.queue(), 1, "dedup and reject")
T.eq(P.queue()[1].state, "pending", "waits while busy")
P.queue()[1].state = "failed"
P.retry()
T.eq(P.queue()[1].state, "pending", "retry")
P.queue()[1].state = "done"
P.clear_done()
T.eq(#P.queue(), 0, "clear done")
-- Shared Downloads panel (Vivi sets user-data/vivi/downloads = 1).
local function reports(job)
  local out = {}
  for _, c in ipairs(T.calls) do
    if c[1] == "script-message" and c[2] == "vivi-download" and c[3] == "offline-downloads" and (not job or c[4] == job) then
      out[#out + 1] = T.json_decode(c[5])
    end
  end
  return out
end
T.calls = {}
P.enqueue("https://example.org/two.mp3")
T.eq(#reports(), 0, "no reports without the panel")
P.clear_done()
P.queue()[1] = nil
T.props["user-data/vivi/downloads"] = "1"
T.calls = {}
local it = P.enqueue("https://example.org/three.ogg")
local job = P.job_id(it)
T.ok(job:match("^%d+%-%d+$"), "job id")
local r = reports(job)
T.eq(#r, 1, "reported on enqueue")
T.eq(r[1].state, "queued", "queued state")
T.eq(r[1].title, "https://example.org/three.ogg", "title falls back to the URL")
T.eq(r[1].can_pause, true, "files can pause")
P.job_pause(job)
T.eq(it.state, "paused", "panel pause on a waiting job")
P.job_resume(job)
T.eq(it.state, "pending", "panel resume")
P.job_cancel(job)
T.eq(it.state, "failed", "panel cancel keeps the row")
T.eq(it.error, "Cancelled", "cancel reason")
local last = reports(job)
T.eq(last[#last].state, "failed", "cancel reported")
P.job_retry(job)
T.eq(it.state, "pending", "panel retry")
T.eq(P.panel_row({ id = 9, url = "http://r.example/live", kind = "stream", state = "active", started = 100, minutes = 30 }, 175).detail,
  "Recording · 1:15 of 30 min", "recording detail")
T.eq(P.panel_row({ id = 9, url = "http://r.example/live", kind = "stream", state = "active" }).can_pause, false, "recordings cannot pause")
T.eq(P.panel_row({ id = 9, url = "u", kind = "ytdlp", state = "active", pct = 40, total_text = "3.40MiB" }).detail,
  "40% of 3.40MiB", "yt-dlp detail")
local d = P.panel_row({ id = 9, url = "u", kind = "file", state = "done", size = 2048, file = "/m/a.mp3" })
T.eq(d.progress, 1, "done progress")
T.eq(d.total, 2048, "done size")
T.eq(d.title, "a.mp3", "title from the file")
T.calls = {}
P.show()
T.eq(T.calls[1] and T.calls[1][2], "vivi-downloads-show", "show opens the panel")
it.state = "done"
T.calls = {}
P.clear_done()
T.eq(T.calls[1] and T.calls[1][2], "vivi-download-remove", "clear removes the row")
-- record: the given URL, else the playing stream, else the clipboard.
T.props["path"] = "http://radio.example:8000/live"
local rec = P.record()
T.eq(rec and rec.url, "http://radio.example:8000/live", "record the playing stream")
T.eq(rec and rec.record, true, "record flag")
T.eq(P.panel_row(rec).can_pause, false, "a queued recording cannot pause")
T.props["path"] = "/music/a.flac"
T.props["clipboard/text"] = " https://radio.example/b.pls "
T.eq(P.record().url, "https://radio.example/b.pls", "record the clipboard URL")
T.props["clipboard/text"] = ""
T.eq(P.record(), nil, "nothing to record")
T.eq(P.record("https://x.example/c.mp3").record, true, "record an explicit URL")
-- yt-dlp formats always fall back (no single file with video + audio on YouTube now)
T.eq(P.format_for("https://www.youtube.com/watch?v=x", "Best single file", true), "b/bv*+ba/ba", "best single file falls back to merging")
T.eq(P.format_for("https://www.youtube.com/watch?v=x", "Best single file", false), "b/ba", "no ffmpeg: audio fallback")
T.eq(P.format_for("https://music.youtube.com/watch?v=x", "Best single file", true), "ba[ext=m4a]/ba/b", "YouTube Music: audio")
T.eq(P.format_for("https://www.youtube.com/watch?v=x", "720p", true), "bv*[height<=720]+ba/b[height<=720]/bv*+ba/b/ba", "height")
T.eq(P.format_for("https://www.youtube.com/watch?v=x", "Best", true), "bv*+ba/b/ba", "best")
T.eq(P.format_for("https://www.youtube.com/watch?v=x", "Audio only", false), "ba[ext=m4a]/ba/b", "audio only")
-- Vivi's panel flag: the integer 1 (new) or a string "1" (earlier builds)
T.props["user-data/vivi/downloads"] = 1
T.calls = {}
P.show()
T.eq(T.calls[1] and T.calls[1][2], "vivi-downloads-show", "integer panel flag")
-- Download tools run under the sh watchdog (stops them when Vivi or the wrapper goes away).
T.props["pid"] = 4242
local g = P.guarded({ "curl", "-o", "x", "http://a.example/x.mp3" })
T.eq(g[1], "sh", "guard runs sh")
T.eq(g[5], "4242", "guard watches Vivi's pid")
T.eq(g[6], "", "no log: mpv keeps the capture pipes")
T.eq(g[7], "", "no pid file")
T.eq(g[8], "curl", "tool follows")
T.eq(g[#g], "http://a.example/x.mp3", "args kept")
T.eq(P.guarded({ "yt-dlp", "u" }, "/tmp/l")[6], "/tmp/l", "log file")
T.props["pid"] = nil
T.eq(P.guarded({ "curl" })[5], "1", "no pid: watch init (never stops on its own)")
T.ok(P.GUARD:find("pkill %-TERM %-P", 1) ~= nil, "children of the tool are stopped too")
T.eq(P.guarded({ "curl" }, nil, "/tmp/p")[7], "/tmp/p", "pid file for a graceful stop")
T.ok(P.GUARD:find('echo "$c" >"$pf"', 1, true) ~= nil, "the tool's pid is written")
T.ok(P.STOP:find('kill -INT "$p"', 1, true) ~= nil, "stop: SIGINT to the exact pid first")
T.ok(P.STOP:find('kill -TERM "$p"', 1, true) ~= nil, "stop: then SIGTERM")
T.ok(P.GUARD:find('$SIG{INT} = "DEFAULT"', 1, true) ~= nil, "the tool can be interrupted (not ignored as a background job)")
T.ok(P.STOP:find("[!0-9]", 1, true) ~= nil, "stop: only a numeric pid")
-- #2: radio streams. Many Icecast servers refuse HEAD: a short GET probe instead.
T.ok(P.PROBE:find("-r 0-0", 1, true) and P.PROBE:find("head -c 4096", 1, true), "GET probe reads ≤4 KB")
T.eq(P.probe_args("http://r.example/live")[5], "http://r.example/live", "probe URL")
local k2, n2, ct = P.classify_headers("ytdlp", "ICY 200 OK\r\nicy-name: R\r\nContent-Type: audio/aacp\r\n\r\n")
T.eq(k2, "stream", "Shoutcast ICY status")
T.eq(ct, "audio/aacp", "content type returned")
k2, n2 = P.classify_headers("ytdlp", "HTTP/1.1 206 Partial Content\r\nContent-Type: audio/mpeg\r\nContent-Length: 1\r\nContent-Range: bytes 0-0/5000000\r\n")
T.eq(k2, "file", "ranged file reply")
T.eq(n2, 5000000, "size from Content-Range")
k2 = P.classify_headers("ytdlp", "HTTP/1.1 302 Found\r\nContent-Length: 120\r\nContent-Type: text/html\r\nLocation: /s\r\n\r\nHTTP/1.0 200 OK\r\nContent-Type: audio/mpeg\r\nicy-br: 128\r\n\r\n")
T.eq(k2, "stream", "only the last response after redirects counts")
T.eq(P.classify_headers("ytdlp", "HTTP/1.1 405 Method Not Allowed\r\n"), "ytdlp", "refused probe keeps the guess")
T.ok(P.file_name("http://radio.example:8000/live", "stream", "audio/aacp"):match("%.aac$"), "aac stream name")
T.eq(P.clock(75), "1:15", "clock")
T.eq(P.clock(3725), "1:02:05", "clock hours")
-- mpv knows the playing item is live: ICY metadata, or no duration and not seekable.
T.props["path"] = "http://r.example/live"
T.props["metadata"] = { ["icy-name"] = "R" }
T.eq(P.playing_live("http://r.example/live"), true, "icy metadata is live")
T.eq(P.playing_live("http://other.example/x"), false, "another URL")
T.props["metadata"] = {}
T.props["seekable"] = false
T.eq(P.playing_live("http://r.example/live"), true, "unseekable without duration")
T.props["duration"] = 120
T.eq(P.playing_live("http://r.example/live"), false, "has a duration")
T.props["seekable"], T.props["duration"], T.props["metadata"] = nil, nil, nil
-- Ending a recording keeps it (length reached, Stop, Cancel); Discard deletes it.
local dir = os.getenv("XDG_DATA_HOME") or "/tmp"
local function rec_item(name)
  local f = dir .. "/" .. name
  local h = io.open(f, "w") h:write(string.rep("x", 2048)) h:close()
  return { id = 50, url = "http://r.example/live", kind = "stream", state = "active", file = f,
    started = os.time() - 70, minutes = 1, added = 1 }
end
for _, how in ipairs({ "auto", "stop" }) do
  local ri = rec_item("rec-" .. how .. ".mp3")
  P.set_active({ item = ri, t0 = 0, aborted = how })
  P.finish(ri, false, "curl exit 143")
  T.eq(ri.state, "done", how .. ": kept as done")
  T.eq(ri.recorded, 60, how .. ": length capped at the set minutes")
  T.eq(ri.size, 1, how .. ": size (the stub's file_info)")
  T.ok(io.open(ri.file, "r") ~= nil, how .. ": file kept")
  T.eq(P.panel_row(ri).detail, "Recorded 1:00 · 0 KB", how .. ": panel detail")
end
local ri = rec_item("rec-natural.mp3")
P.set_active({ item = ri, t0 = 0 })
P.finish(ri, true)
T.eq(ri.state, "done", "curl --max-time end is done")
ri = rec_item("rec-discard.mp3")
P.set_active({ item = ri, t0 = 0, aborted = "discard" })
P.finish(ri, false)
T.eq(ri.state, "failed", "discarded")
T.eq(ri.error, "Discarded", "discard reason")
T.eq(io.open(dir .. "/rec-discard.mp3", "r"), nil, "discard deletes the file")
-- yt-dlp stopped mid-recording: its .part becomes the file.
local part = dir .. "/Live [x].mp3.part"
local h = io.open(part, "w") h:write("abc") h:close()
ri = { id = 51, url = "http://r.example/y", kind = "ytdlp", live = true, state = "active", part = part,
  started = os.time() - 5, minutes = 1, added = 1 }
P.set_active({ item = ri, t0 = 0, aborted = "stop" })
P.finish(ri, false, "yt-dlp error")
T.eq(ri.state, "done", "yt-dlp recording kept")
T.eq(ri.file, dir .. "/Live [x].mp3", ".part renamed")
-- Nothing recorded: failed, not an empty "done".
ri = { id = 52, url = "http://r.example/z", kind = "stream", state = "active", file = dir .. "/none.mp3", started = os.time(), minutes = 1, added = 1 }
P.set_active({ item = ri, t0 = 0, aborted = "auto" })
P.finish(ri, false, "curl: (7) Failed to connect")
T.eq(ri.state, "failed", "empty recording fails")
-- Cancel on an active recording stops it gracefully and keeps it (no abort of the wrapper).
T.props["pid"] = 4242
ri = rec_item("rec-cancel.mp3")
local act = { item = ri, t0 = 0, job = {}, pidfile = ri.file }
P.set_active(act)
P.cancel()
T.eq(act.aborted, "stop", "cancel on a recording means stop and keep")
P.set_active(nil)
T.done("offline-downloads")
