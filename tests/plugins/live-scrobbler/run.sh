#!/usr/bin/env bash
# Scrobbler end to end, without any real account: the plugin runs in a headless mpv (real
# Lua runtime, real curl) against mock.py, a local mock of the ListenBrainz and Last.fm
# APIs that checks the Authorization header, the api_sig and the session key of every
# request. check.py then asserts the requests, the private file modes and that no secret
# reached mpv's debug log. Needs mpv, curl, ffmpeg (test tones) and python3.
#   tests/plugins/live-scrobbler/run.sh [plugin script] [out dir]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$(realpath "${1:-$HERE/../../../plugins/scrobbler/scrobbler.lua}")
OUT=$(realpath -m "${2:-$(mktemp -d)}")
rm -rf "$OUT"; mkdir -p "$OUT/xdg-data" "$OUT/mpvconf/script-opts" "$OUT/media"
M=$OUT/media
tone() { ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=$1:duration=40" "${@:3}" "$M/$2"; }
tone 440 tone.flac -metadata artist="Vivi Test Tones" -metadata title="Sine 440" -metadata album="Synthetic Signals" \
  -metadata track=3/12 -metadata MUSICBRAINZ_TRACKID=8f3471b5-7e6a-48da-86a9-c1c07a0f47ae
tone 330 talk.mp3 -metadata artist="Vivi Test Tones" -metadata title="Talk Show" -metadata genre=Podcast
tone 550 tone550.mp3 -metadata artist="Vivi Test Tones" -metadata title="Sine 550" \
  -metadata "MusicBrainz Track Id"=0383dadf-2a4e-4d10-a46a-e9e041da8eb3
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
python3 "$HERE/mock.py" "$PORT" "$OUT/requests.jsonl" & MOCK=$!
trap 'kill $MOCK' EXIT
sleep 0.5
MOCKURL="http://127.0.0.1:$PORT"
# Settings come from script-opts/scrobbler.conf (Vivi passes them as script-opts), so the
# log check below only sees what the plugin itself does with them.
printf 'token=FAKE-LB-TOKEN-7f3a\nlastfm_key=fakeapikey0001\nlastfm_secret=FAKE-SHARED-SECRET-91c2\n' \
  > "$OUT/mpvconf/script-opts/scrobbler.conf"
for phase in online offline; do
  mkdir -p "$OUT/$phase"; ln -sf "$SCRIPT" "$OUT/$phase/scrobbler.lua"
  XDG_DATA_HOME="$OUT/xdg-data" ITEST_OUT="$OUT/$phase" ITEST_MEDIA="$M" ITEST_PHASE="$phase" ITEST_MOCK="$MOCKURL" \
  VIVI_SCROBBLER_LB_API="$MOCKURL/lb" VIVI_SCROBBLER_LASTFM_API="$MOCKURL/lastfm/2.0/" \
  VIVI_SCROBBLER_LASTFM_AUTH="$MOCKURL/auth/" VIVI_TEST_NO_BROWSER=1 \
    timeout 60 mpv --config-dir="$OUT/mpvconf" --idle=yes --ao=null --vo=null --no-terminal --speed=8 \
      --log-file="$OUT/$phase/mpv.log" --msg-level=all=debug \
      --script="$OUT/$phase/scrobbler.lua" --script="$HERE/driver.lua" || echo "mpv exit $?"
  (cd "$OUT/xdg-data/vivi/plugin-data/scrobbler" && stat -c "%a %n" . * > "$OUT/$phase/perms.txt") || true
done
python3 "$HERE/check.py" "$OUT"
