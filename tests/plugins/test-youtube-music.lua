-- YouTube Music: InnerTube parsing on hand-written fixtures (fake names and ids shaped
-- like music.youtube.com answers; no user data), cookies, SAPISIDHASH, options, UI flow.
local T = dofile("tests/plugins/stub.lua")
local P = T.load("plugins/youtube-music/youtube-music.lua", {})
local function fx(name)
  local f = assert(io.open("tests/plugins/fixtures/youtube-music/" .. name .. ".json"))
  local v = assert(T.json_decode(f:read("*a")))
  f:close()
  return v
end

-- search results
local songs = fx("search_songs")
local s = P.collect(songs)
T.eq(#s, 4, "four songs")
T.eq(s[1].kind, "song", "song kind")
T.eq(s[1].title, "Harbour Lights", "title")
T.eq(s[1].artist, "Northern Lights Ensemble", "artist")
T.eq(s[1].artist_id, "UCfakeArtist00000000001", "artist id")
T.eq(s[1].album, "Quiet Harbour", "album")
T.eq(s[1].album_id, "MPREb_fakeAlbum001", "album id")
T.eq(s[1].duration, 208, "duration")
T.eq(P.url(s[1]), "https://music.youtube.com/watch?v=fakeVid0001", "watch url")
T.ok(s[1].thumb:find("=w226%-h226%-l90%-rj"), "list cover size")
T.ok(s[1].thumb_full:find("=w544%-h544"), "big cover size")
T.eq(P.sub(s[1]), "Northern Lights Ensemble · Quiet Harbour", "subtitle")
T.eq(s[2].artist, "Mira Vale, The Paper Boats", "two artists")
T.eq(s[3].kind, "video", "music video")
T.eq(s[3].duration, 3725, "hour-long")
T.eq(s[3].extra, "12M views", "views")
T.eq(s[4].artist, "Various Artists", "unlinked artist")
T.eq(P.continuation(songs).query, "FAKE_SEARCH_CONT", "search continuation")
local more = fx("search_more")
T.eq(P.collect(more)[1].title, "Tide Clock", "page 2")
T.eq(P.continuation(more), nil, "last page")

local al = P.collect(fx("search_albums"))
T.eq(al[1].kind, "album", "album kind")
T.eq(al[1].browse_id, "MPREb_fakeAlbum001", "album browse id")
T.eq(al[1].playlist_id, "OLAK5uy_fakeAlbum001", "album playlist")
T.eq(al[1].extra, "2019", "album year")
T.eq(al[2].extra, "Single · 2024", "single")
T.eq(al[1].video_id, "", "albums are opened, not played")
local ar = P.collect(fx("search_artists"))
T.eq(ar[1].kind, "artist", "artist kind")
T.eq(ar[1].artist, "", "artist has no artist")
T.eq(ar[1].extra, "2.4M monthly audience", "audience")
local pl = P.collect(fx("search_playlists"))
T.eq(pl[1].browse_id, "VLPLfakePlaylist0001", "playlist browse id")
T.eq(P.sub(pl[1]), "Some Curator · 48K views", "playlist subtitle")
T.eq(P.page_url(pl[1]), "https://music.youtube.com/browse/VLPLfakePlaylist0001", "page url")

-- library
local liked = P.parse_page(fx("browse_VLLM"), "VLLM")
T.eq(liked.title, "Liked Music", "liked title")
T.eq(liked.playlist_id, "LM", "liked playlist id")
T.eq(#liked.items, 6, "liked tracks")
T.eq(liked.items[3].album, "Lanterns", "liked album")
T.eq(liked.cont and liked.cont.body, "FAKE_LIKED_CONT", "tracks' continuation, not the suggestions")
T.eq(P.collect(fx("browse_more"))[1].title, "Last Train Home", "liked page 2")
local lp = P.parse_page(fx("browse_FEmusic_liked_playlists"), "FEmusic_liked_playlists")
local names = {}
for i, it in ipairs(lp.items) do names[i] = it.title end
T.eq(table.concat(names, "|"), "Liked Music|Rainy Day Focus|Road Trip 2026|Evening Jazz", "playlists without New playlist")
T.eq(lp.items[2].playlist_id, "PLfakePlaylist0001", "playlist id")
T.eq(P.sub(lp.items[2]), "You · 4 songs", "playlist sub")
local la = P.parse_page(fx("browse_FEmusic_liked_albums"), "FEmusic_liked_albums")
T.eq(#la.items, 4, "albums")
T.eq(la.items[2].extra, "EP · 2022", "album extra")
T.eq(#P.parse_page(fx("browse_FEmusic_history"), "FEmusic_history").items, 3, "history de-duplicated")
T.ok(P.needs_sign_in(fx("browse_signin")), "signed-out library")
T.ok(not P.needs_sign_in(fx("browse_FEmusic_liked_albums")), "signed-in library")
local album = P.parse_page(fx("browse_MPREb_fakeAlbum001"), "MPREb_fakeAlbum001")
T.eq(album.title, "Quiet Harbour", "album page")
T.eq(album.sub, "Northern Lights Ensemble · Album · 2019 · 3 songs · 10 minutes", "album header")
T.eq(album.playlist_id, "OLAK5uy_fakeAlbum001", "album play list")
T.eq(album.items[2].artist, "Northern Lights Ensemble", "album track artist from the header")
T.eq(album.items[2].album, "Quiet Harbour", "album track album")
T.ok(album.items[1].thumb:find("w226"), "album track cover")
T.eq(album.year, "2019", "album year")
T.eq(album.items[2].track_no, 2, "album track number")
T.eq(album.items[2].year, "2019", "album track year")
T.eq(liked.items[1].track_no, nil, "no track numbers in playlists")
local nx = P.collect(fx("next"))
T.eq(#nx, 3, "up next")
T.eq(nx[2].album, "Glass Seasons", "up next album")
T.eq(nx[3].extra, "", "year dropped")
T.eq(P.account_name(fx("account")), "Test Listener", "account")

-- cookies and auth
local jar = "# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t1999999999\tSAPISID\tabc/def\n" ..
  "#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t0\tSID\ts1\n.google.com\tTRUE\t/\tTRUE\t0\tNID\tx\n"
local c = assert(P.parse_any(jar))
T.eq(#c, 2, "only youtube.com cookies")
T.eq(P.sapisid(c), "abc/def", "sapisid")
T.ok(c[2].http_only, "http only flag")
T.eq(#P.parse_netscape(P.to_netscape(c)), 2, "round trip")
T.eq(P.unix_expiry(13471032042792000), 1826558442, "Chrome expires_utc -> Unix seconds")
T.eq(P.unix_expiry(1826558442), 1826558442, "Unix seconds kept")
T.eq(P.unix_expiry("x"), 0, "junk -> session")
T.eq(P.jar_stale(1000, 1000 + 21 * 60, "Chrome"), true, "browser jar older than 20 min is refreshed")
T.eq(P.jar_stale(1000, 1000 + 5 * 60, "Chrome"), false, "fresh jar kept")
T.eq(P.jar_stale(1000, 1000 + 99 * 60, ""), false, "no browser: never refreshed")
T.eq(P.detail_cover({ thumb = "https://lh3.googleusercontent.com/a=w60-h60-l90-rj", thumb_full = "" }),
  "https://lh3.googleusercontent.com/a=w544-h544-l90-rj", "detail cover: 544 px")
T.eq(P.detail_cover(nil), "", "no selection: no cover")
local big = P.to_netscape({ { domain = ".youtube.com", path = "/", secure = true, expires = 13471032042792000, name = "SID", value = "v" } })
T.ok(big:find("\t1826558442\tSID\t", 1, true) and not big:find("e+", 1, true), "no scientific notation in the jar")
local h = assert(P.parse_any("GET / HTTP/2\nHost: music.youtube.com\ncookie: SAPISID=x1; __Secure-3PAPISID=y2; PREF=a=b\n"))
T.eq(P.sapisid(h), "y2", "3PAPISID preferred")
T.eq(P.cookie_header(h, "music.youtube.com"), "SAPISID=x1; __Secure-3PAPISID=y2; PREF=a=b", "cookie header")
T.ok(P.parse_any("curl 'https://music.youtube.com/' -H 'cookie: SAPISID=z' -H 'x: y'"), "copy as curl")
T.eq(select(2, P.parse_any("set-cookie: SAPISID=z")) ~= nil, true, "set-cookie is not a cookie header")
T.ok(not P.parse_any("PREF=1"), "not signed in")
T.eq(P.sha1_hex(""), "da39a3ee5e6b4b0d3255bfef95601890afd80709", "sha1 empty")
T.eq(P.sha1_hex("abc"), "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 abc")
T.eq(P.sha1_hex(string.rep("a", 1000)), "291e9a6c66994949b57ba5e650361e98fc36b1ba", "sha1 long")
T.eq(P.sapisid_hash("x", 1700000000), "SAPISIDHASH 1700000000_" .. P.sha1_hex("1700000000 x https://music.youtube.com"), "sapisidhash")

-- options and helpers
T.eq(P.file_options("A, B", true, "/home/a,b/cookies.txt"),
  "force-media-title=%4%A, B,ytdl-format=%14%bestaudio/best,ytdl-raw-options=%33%cookies=%21%/home/a,b/cookies.txt", "per-file options")
T.ok(P.mpv_at_least("mpv v0.40.0", 38), "new mpv")
T.ok(not P.mpv_at_least("mpv 0.37.0-dirty", 38), "old mpv")
local a = P.download_args("https://music.youtube.com/watch?v=x", "/m", "mp3", "/c.txt", "ffmpeg")
local joined = table.concat(a, " ")
T.ok(joined:find("--audio-format mp3", 1, true), "format")
T.ok(joined:find("--embed-thumbnail", 1, true), "cover")
T.ok(joined:find("--cookies /c.txt", 1, true), "cookies")
T.eq(a[#a - 1], "--", "url after --")
T.eq(P.parse_progress("[download] x\n[vivi]  42.5%|Song\n[vivi]  57.0%|Song\n"), 57, "progress")
T.eq(P.o.downloads, false, "downloads off by default")

-- UI: selecting a row updates the dialog
P.S.items = s
P.on_ui('{"event":"select","args":["1"]}')
T.eq(P.S.sel, 2, "row index from 0")
local last
for _, call in ipairs(T.calls) do if call[2] == "vivi-dialog" then last = call end end
T.ok(last, "dialog update sent")
local d = T.json_decode(last[4])
T.eq(d.rows[2].selected, true, "selected row")
T.eq(d.primary, "Play", "play a song")
T.ok(d.detail:find("Mira Vale"), "details")
-- Downloads panel: queued jobs are reported, Cancel from the panel drops them
T.props["user-data/vivi/downloads"] = "1"
P.o.downloads = true
P.S.dl_job = {} -- pretend one is running so the queue does not start
P.download({ kind = "song", title = "Q", artist = "A", video_id = "vid1" })
local rep
for _, call in ipairs(T.calls) do if call[2] == "vivi-download" and call[4] == "vid1" then rep = call end end
T.ok(rep, "download reported to the panel")
T.eq(T.json_decode(rep[5]).state, "queued", "queued state")
P.cancel_job("vid1")
T.eq(#P.S.dl_queue, 0, "cancelled from the panel")
T.eq(T.json_decode(T.calls[#T.calls][5]).error, "Cancelled", "cancel reported")
P.S.dl_job, P.o.downloads = nil, false
local a2 = P.download_args("u", "/m", "m4a", nil, nil, "/p")
T.ok(table.concat(a2, " "):find("--print-to-file after_move:filepath /p", 1, true), "final path printed")
T.eq(P.opts_prefix({ ["youtube_music-pkgdir"] = "/p" }), "youtube_music", "new host prefix")
T.eq(P.opts_prefix({ ["youtube-music-pkgdir"] = "/p" }), "youtube-music", "old host prefix")
T.eq(P.opts_prefix(nil), "youtube-music", "no script-opts")
-- cURL -b forms and browser sign-in errors
T.ok(P.parse_any("curl 'https://music.youtube.com/youtubei/v1/browse' -b 'SAPISID=z; SID=q' -H 'x: y'"), "curl -b")
T.ok(P.parse_any("curl 'https://music.youtube.com/' -b $'SAPISID=z; SID=q' -H 'x: y'"), "curl -b $'...'")
T.ok(P.parse_any("curl 'https://music.youtube.com/' --cookie \"SAPISID=z\""), "curl --cookie")
local ba = table.concat(P.browser_args("yt-dlp", "Chrome", "/j"), " ")
T.ok(ba:find("--cookies-from-browser chrome --cookies /j", 1, true), "browser args")
T.ok(not ba:find("--no-warnings", 1, true), "warnings kept for the error message")
-- Keyring for Chromium cookies (v11) on desktops yt-dlp does not know (Hyprland ...)
T.ok(table.concat(P.browser_args("yt-dlp", "Chrome", "/j", "gnomekeyring"), " "):find("--cookies-from-browser chrome+gnomekeyring --cookies /j", 1, true), "keyring in the browser spec")
local secrets = { ["org.freedesktop.secrets"] = true }
T.eq(P.keyring_hint("Chrome", "Hyprland", secrets), "gnomekeyring", "Hyprland + Secret Service")
T.eq(P.keyring_hint("Brave", "sway", { ["org.kde.kwalletd6"] = true, ["org.freedesktop.secrets"] = true }), "kwallet6", "KWallet first")
T.eq(P.keyring_hint("Chrome", "Hyprland", {}), nil, "no keyring running: yt-dlp guesses")
T.eq(P.keyring_hint("Chrome", "ubuntu:GNOME", secrets), nil, "GNOME: yt-dlp knows")
T.eq(P.keyring_hint("Chrome", "KDE", secrets), nil, "KDE: yt-dlp knows")
T.eq(P.keyring_hint("Firefox", "Hyprland", secrets), nil, "Firefox has no keyring")
T.ok(P.browser_error("Chrome", "WARNING: cannot decrypt v11 cookies: no key found\n"):find("desktop keyring", 1, true), "no key: says what to do")
-- The secret-tool helper, against a fake yt_dlp.cookies and a fake secret-tool: it finds the
-- browser's password by label, hands it to yt-dlp's decryptor and never prints it.
if os.execute("python3 -c 'import sys' 2>/dev/null") == 0 or os.execute("python3 -c 'import sys' 2>/dev/null") == true then
  local d = os.tmpname()
  os.remove(d)
  os.execute('mkdir -p "' .. d .. '/yt_dlp" "' .. d .. '/bin"')
  local function put(path, text) local f = assert(io.open(path, "w")) f:write(text) f:close() end
  put(d .. "/yt_dlp/__init__.py", "")
  put(d .. "/yt_dlp/cookies.py", [[
class YDLLogger:
    def __init__(self, ydl=None): pass
def _get_gnome_keyring_password(name, logger):
    raise SystemExit("not patched")
class Jar:
    def __init__(self, pw): self.pw = pw
    def save(self, out, ignore_discard=False, ignore_expires=False):
        open(out, "w").write("# Netscape HTTP Cookie File\n.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\t" + ("ok" if self.pw == b"s3cret-pw" else "bad") + "\n")
def extract_cookies_from_browser(browser, logger=None, keyring=None):
    assert keyring == "GNOMEKEYRING"
    logger.info("Extracted 1 cookies from " + browser)
    return Jar(_get_gnome_keyring_password("Chrome", logger))
]])
  put(d .. "/bin/secret-tool", "#!/bin/sh\nprintf '[/2]\\nlabel = Chromium Safe Storage\\nsecret = wrong\\n[/3]\\nlabel = Chrome Safe Storage\\nsecret = s3cret-pw\\nattribute.application = chrome\\n'\n")
  os.execute('chmod +x "' .. d .. '/bin/secret-tool"')
  put(d .. "/helper.py", P.KEYRING_HELPER)
  local h = io.popen('cd "' .. d .. '" && PATH="' .. d .. '/bin:$PATH" PYTHONPATH="' .. d .. '" python3 helper.py chrome "' .. d .. '/jar.txt" 2>&1')
  local out = h:read("*a")
  h:close()
  local jar = read_all and read_all(d .. "/jar.txt") or (function() local f = io.open(d .. "/jar.txt") if not f then return "" end local t = f:read("*a") f:close() return t end)()
  T.ok(jar:find("SAPISID\tok", 1, true), "helper: right password by label (" .. out .. ")")
  T.ok(not out:find("s3cret", 1, true), "helper never prints the password")
  T.ok(out:find("Extracted 1 cookies", 1, true), "helper shows yt-dlp's count")
  os.execute('rm -rf "' .. d .. '"')
end
local se = "[generic] Extracting URL: ytsearch0:vivi\nExtracting cookies from chrome\nWARNING: failed to decrypt cookie (AES-GCM) because the MAC check failed\nERROR: Unable to handle request: Unsupported url scheme: \"ytsearch0\" (urllib)\n"
T.ok(P.browser_error("Chrome", se):find("failed to decrypt cookie", 1, true), "decrypt warning surfaced")
T.ok(P.browser_error("Chrome", "Extracted 12 cookies from chrome\nERROR: Unable to handle request: Unsupported url scheme: \"ytsearch0\"\n"):find("found 12 cookies", 1, true), "no signed-in cookies")
T.ok(P.browser_error("Chrome", "ERROR: could not find chrome cookies database in \"/x\"\n"):find("could not find chrome cookies database", 1, true), "missing browser")
T.props["clipboard/text"] = "SAPISID=z"
T.eq(P.clipboard(), "SAPISID=z", "mpv clipboard")
-- Download names, tags and covers
local tm = P.out_template("/m/100%", false)
T.eq(tm, "/m/100%%/%(artists.0,artist,creator,uploader|Unknown artist)s/%(album,vivi_album|Singles)s/%(vivi_no&{} |)s%(track,vivi_title,title)s.%(ext)s", "clean template")
T.ok(P.out_template("/m", true):find(" [%(id)s].%(ext)s", 1, true), "id only on a clash")
local ma = table.concat(P.meta_args({ track_no = 3, year = "2019" }), " ")
T.ok(ma:find("--parse-metadata 03:%(vivi_no)s", 1, true), "padded track number for the name")
T.ok(ma:find("--parse-metadata 3:%(meta_track)s", 1, true), "track tag")
T.ok(ma:find("%(release_year,release_date>%Y|2019)s:%(meta_date)s", 1, true), "year with the album year as fallback")
T.ok(ma:find("%(artists.0,artist,creator,uploader)s:%(meta_album_artist)s", 1, true), "album artist")
T.ok(not table.concat(P.meta_args({}), " "):find("vivi_no", 1, true), "no track number off album pages")
T.ok(table.concat(P.meta_args({}), " "):find("upload_date>%Y)s:%(meta_date)s", 1, true), "upload year fallback")
local pa = P.probe_args("https://music.youtube.com/watch?v=x", "/m", "/j", "/d/info", {})
T.ok(table.concat(pa, " "):find("--skip-download --no-simulate --write-info-json", 1, true), "probe writes the info JSON")
T.eq(pa[#pa], "https://music.youtube.com/watch?v=x", "probe url")
local pr = P.parse_probe("/m/A/B/03 Song.webm\nSong\tA, C\tB\thttps://i/x.webp\n", "[debug] Optional libraries: certifi, mutagen-1.47.0, requests\n")
T.eq(pr.filename, "/m/A/B/03 Song.webm", "probe file name")
T.eq(pr.artist .. "|" .. pr.album .. "|" .. pr.thumb, "A, C|B|https://i/x.webp", "probe fields")
T.eq(pr.mutagen, true, "mutagen found")
T.eq(P.parse_probe("f\n\t\t\t\n", "[debug] Optional libraries: certifi\n").mutagen, false, "no mutagen")
local have = { ["/m/A/B/03 Song.m4a"] = true }
T.eq(P.existing("/m/A/B/03 Song.webm", function(x) return have[x] end), "/m/A/B/03 Song.m4a", "same name, other extension")
T.eq(P.existing("/m/A/B/04 Other.webm", function(x) return have[x] end), nil, "free name")
T.eq(P.with_id("/m/A/B/03 Song.webm", "abc"), "/m/A/B/03 Song [abc].webm", "id suffix")
local da = P.download_args("u", "/m", "opus", nil, "ffmpeg", "/p", { info = "/d/i.info.json", covers = "/d/covers", embed = false, with_id = true, meta = { "--parse-metadata", "x:y" } })
local dj = table.concat(da, " ")
T.eq(da[#da - 1] .. " " .. da[#da], "--load-info-json /d/i.info.json", "step 2 loads the info JSON")
T.ok(not dj:find("--embed-thumbnail", 1, true), "no yt-dlp embed without mutagen")
T.ok(dj:find("--write-thumbnail -o thumbnail:/d/covers/%(id)s.%(ext)s", 1, true), "cover kept")
T.ok(dj:find("--parse-metadata x:y", 1, true), "metadata args")
T.ok(dj:find("crop=", 1, true) and dj:find("--convert-thumbnails jpg", 1, true), "square jpg cover")
T.ok(table.concat(P.download_args("u", "/m", "m4a", nil, "ffmpeg", nil, { embed = true }), " "):find("--embed-thumbnail", 1, true), "yt-dlp embeds")
T.eq(P.base64(""), "", "b64 empty")
T.eq(P.base64("f"), "Zg==", "b64 1")
T.eq(P.base64("fo"), "Zm8=", "b64 2")
T.eq(P.base64("foobar"), "Zm9vYmFy", "b64 6")
local jpg = "\255\216\255\224\0\16JFIF\0\1\1\0\0\1\0\1\0\0\255\192\0\17\8\2\208\5\0\3\1\34\0"
local w, h = P.jpeg_size(jpg)
T.eq(w .. "x" .. h, "1280x720", "jpeg size")
local pm = P.picture_meta(jpg)
T.ok(pm:find("^;FFMETADATA1\nMETADATA_BLOCK_PICTURE=AAAAAwAAAAppbWFnZS9qcGVn"), "picture block (type 3, image/jpeg)")
T.ok(not pm:sub(40):find("[^\\]="), "= escaped in ffmetadata")
local ca = table.concat(P.cover_args("ffmpeg", "/m/a.opus", "/c.jpg", "/m/a.t.opus", "/d/m.txt"), " ")
T.ok(ca:find("-f ffmetadata -i /d/m.txt", 1, true) and ca:find("-map_metadata:s:a:0 0:s:a:0", 1, true), "opus cover via METADATA_BLOCK_PICTURE")
local cm = table.concat(P.cover_args("ffmpeg", "/m/a.mp3", "/c.jpg", "/m/a.t.mp3", "/d/m.txt"), " ")
T.ok(cm:find("-i /c.jpg", 1, true) and cm:find("attached_pic", 1, true) and cm:find("-id3v2_version 3", 1, true), "mp3 cover")
T.eq(P.cover_args("ffmpeg", "/m/a.wav", "/c.jpg", "/t", "/m"), nil, "no cover for wav")
-- Downloads panel rows: new hosts get subtitle + artwork URL, earlier ones the artist in the title
T.eq(P.reuse("/m/A/x.mp3", "/m", "mp3"), true, "reuse same format")
T.eq(P.reuse("/m/A/x.mp3", "/m", "opus"), false, "other format: download again")
T.eq(P.reuse("/m/A/x.opus", "/m", "Original (m4a/opus, no re-encode)"), true, "original: any")
T.eq(P.reuse("/old/A/x.m4a", "/m", "m4a"), false, "other folder: download again")
T.eq(P.reuse("/mm/A/x.m4a", "/m", "m4a"), false, "folder prefix is a path")
T.eq(P.panel_row({ title = "", video_id = "v" }, {}, 2).title, nil, "unknown title not sent")
T.eq(P.panel_level(1), 2, "integer flag")
T.eq(P.panel_level("1"), 1, "string flag")
T.eq(P.panel_level(nil), 0, "no panel")
local row = P.panel_row({ title = "Song", artist = "A", album = "B", video_id = "v", thumb_full = "https://c/x" }, { state = "active" }, 2)
T.eq(row.title .. "|" .. row.subtitle .. "|" .. row.artwork .. "|" .. row.state, "Song|A · B|https://c/x|active", "row")
row = P.panel_row({ title = "Song", artist = "A", album = "", video_id = "v", thumb_full = "https://c/x", cover = "/d/covers/v.jpg" }, {}, 1)
T.eq(row.title .. "|" .. tostring(row.subtitle) .. "|" .. row.artwork, "Song · A|nil|/d/covers/v.jpg", "row for earlier hosts")
-- Vivi 0.12.0 and older have no host API: Open explains instead of sending vivi-dialog
T.eq(P.host_api(nil, nil), false, "no host API")
T.eq(P.host_api(1, nil), true, "downloads flag (integer)")
T.eq(P.host_api('"1"', nil), true, "downloads flag (string, earlier builds)")
T.eq(P.host_api(nil, 1), true, "playlists flag")
local saved_dl, saved_pl = T.props["user-data/vivi/downloads"], T.props["user-data/vivi/playlists"]
T.props["user-data/vivi/downloads"], T.props["user-data/vivi/playlists"] = nil, nil
T.calls = {}
T.messages.open()
local sent_dialog, toast_msg = false, nil
for _, c in ipairs(T.calls) do
  if c[1] == "script-message" and c[2] == "vivi-dialog" then sent_dialog = true end
  if c[1] == "script-message" and c[2] == "vivi-toast" then toast_msg = c[3] end
end
T.eq(sent_dialog, false, "old host: no dialog")
T.eq(toast_msg, P.OLD_HOST, "old host: toast says why")
T.props["user-data/vivi/downloads"], T.props["user-data/vivi/playlists"] = saved_dl, saved_pl
-- YouTube Music's album / title as fallbacks (yt-dlp has none for an album's video tracks)
local mv = P.meta_args({ kind = "video", title = "Black Vortex", album = "Action: Cuts 100%" })
local mvs = table.concat(mv, "\n")
T.ok(mvs:find("%(vivi_none|)sAction\\: Cuts 100%%:(?P<vivi_album>.+)", 1, true), "album literal escaped")
T.ok(mvs:find("%(vivi_none|)sBlack Vortex:(?P<vivi_title>.+)", 1, true), "video title fallback")
T.ok(mvs:find("%(album,vivi_album)s:%(meta_album)s", 1, true), "album tag")
T.ok(not table.concat(P.meta_args({ kind = "song", title = "S" }), "\n"):find("vivi_title", 1, true), "songs keep yt-dlp's track")
T.done("youtube-music")
