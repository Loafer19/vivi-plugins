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
T.done("offline-downloads")
