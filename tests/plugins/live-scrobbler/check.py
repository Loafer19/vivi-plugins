#!/usr/bin/env python3
"""Assertions on a live-scrobbler run (see run.sh)."""
import json, sys
from collections import Counter
from pathlib import Path

out = Path(sys.argv[1])
SECRETS = ["FAKE-LB-TOKEN-7f3a", "FAKE-SHARED-SECRET-91c2", "FAKE-SESSION-KEY-55d0"]
fails = []


def ok(cond, what):
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        fails.append(what)


reqs = [json.loads(l) for l in (out / "requests.jsonl").read_text().splitlines()]
ev = {p: [json.loads(l) for l in (out / p / "events.jsonl").read_text().splitlines()] for p in ("online", "offline")}
toasts = {p: [e["args"][0] for e in ev[p] if e["kind"] == "toast"] for p in ev}

lf = [r for r in reqs if "lastfm" in r]
lb = [r for r in reqs if r["path"].startswith("/lb/")]
ok(all(r["sig_ok"] for r in lf), "every Last.fm request carries a valid api_sig")
ok(all(r["auth_ok"] for r in lb), "every ListenBrainz request carries the token header")
ok(all(r["sk_ok"] for r in lf if r["lastfm"] not in ("auth.getToken", "auth.getSession")), "session key sent where needed")
ok([r["lastfm"] for r in lf[:3]] == ["auth.getToken", "auth.getSession", "auth.getSession"], "Connect polls getSession until approved")
ok(any("Last.fm connected" in t for t in toasts["online"]), "connected toast")
c = Counter()
for r in reqs:
    j = r.get("json") or {}
    if j.get("listen_type") in ("single", "import"):
        c["lb", j["listen_type"], tuple(p["track_metadata"]["track_name"] for p in j["payload"])] += 1
    if r.get("lastfm") == "track.scrobble":
        c["lf", tuple(v for k, v in sorted(r["form"].items()) if k.startswith("track["))] += 1
ok(c["lb", "single", ("Sine 440",)] >= 2 and c["lf", ("Sine 440",)] >= 2, "repeat one: scrobbled twice")
ok(not any("Talk Show" in json.dumps(r) for r in reqs), "podcast genre not sent")
ok(c["lb", "import", ("Sine 440", "Sine 550")] == 1 and c["lf", ("Sine 440", "Sine 550")] == 1,
   "offline queue sent as one batch per service")
ok(any("loved on Last.fm, loved on ListenBrainz" in t for t in toasts["online"]), "love on both services")
ok(any(r["path"].endswith("recording-feedback") and r["json"]["recording_mbid"] == "8f3471b5-7e6a-48da-86a9-c1c07a0f47ae"
       for r in reqs), "ListenBrainz love by recording mbid")
mp3 = [r for r in reqs if (r.get("json") or {}).get("listen_type") == "playing_now"
       and r["json"]["payload"][0]["track_metadata"]["track_name"] == "Sine 550"]
ok(mp3 and mp3[0]["json"]["payload"][0]["track_metadata"]["additional_info"].get("recording_mbid")
   == "0383dadf-2a4e-4d10-a46a-e9e041da8eb3", "ID3 TXXX MusicBrainz Track Id read")
ok(any("Not scrobbled: genre Podcast" in t for t in toasts["online"]), "status explains the skip")
ok(any("sent 2 queued to ListenBrainz" in t for t in toasts["offline"]), "flush toast")
for p in ("online", "offline"):
    log = (out / p / "mpv.log").read_text(errors="replace")
    ok("Run command: subprocess" in log, f"{p}: mpv debug log has the subprocess commands")
    for s in SECRETS:
        ok(s not in log, f"{p}: {s[:12]}… not in mpv's log")
    ok(not any(s in json.dumps(ev[p]) for s in SECRETS), f"{p}: no secret in messages to Vivi")
perm = (out / "online" / "perms.txt").read_text().split("\n")
ok("700 ." in perm and "600 lastfm-session.json" in perm, "data folder 0700, session file 0600")
perm = (out / "offline" / "perms.txt").read_text().split("\n")
ok("600 queue.jsonl" in perm and "600 lastfm-queue.jsonl" in perm, "queue files 0600")
ok("lastfm-session.json" not in " ".join(perm), "Disconnect removes the session file")
ok(not list((out / "xdg-data/vivi/plugin-data/scrobbler").glob("req-*")), "no request file left behind")
print("live-scrobbler:", "ok" if not fails else f"{len(fails)} failure(s)")
sys.exit(1 if fails else 0)
