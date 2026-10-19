#!/usr/bin/env python3
"""Local mock of the ListenBrainz and Last.fm 2.0 APIs for the Scrobbler plugin.

Never talks to the real services. Every request is appended to requests.jsonl with
`auth_ok` / `sig_ok` checks done here (Authorization header, Last.fm api_sig recomputed
with the fake shared secret, session key).
"""
import hashlib, json, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LB_TOKEN, KEY, SECRET, SK = "FAKE-LB-TOKEN-7f3a", "fakeapikey0001", "FAKE-SHARED-SECRET-91c2", "FAKE-SESSION-KEY-55d0"
OUT = sys.argv[2]
state = {"down": False, "session_polls": 0}
lock = threading.Lock()


def sig(params):
    s = "".join(k + params[k] for k in sorted(params) if k not in ("format", "callback", "api_sig"))
    return hashlib.md5((s + SECRET).encode()).hexdigest()


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def record(self, rec):
        with lock, open(OUT, "a") as f:
            f.write(json.dumps(rec) + "\n")

    def do_GET(self):
        p = self.path
        if p.startswith("/ctl/"):
            state["down"] = p == "/ctl/down"
            return self.reply(200, {"down": state["down"]})
        auth = self.headers.get("Authorization", "")
        self.record({"path": p, "method": "GET", "auth_ok": auth == "Token " + LB_TOKEN, "ua": self.headers.get("User-Agent")})
        if state["down"]:
            return self.reply(503, {"error": "down"})
        if p == "/lb/1/validate-token":
            ok = auth == "Token " + LB_TOKEN
            return self.reply(200, {"valid": ok, "user_name": "demo-listener" if ok else None, "code": 200})
        self.reply(404, {"error": "not found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n).decode()
        p = self.path
        if p.startswith("/lb/"):
            auth = self.headers.get("Authorization", "")
            j = json.loads(body)
            self.record({"path": p, "method": "POST", "auth_ok": auth == "Token " + LB_TOKEN,
                         "ctype": self.headers.get("Content-Type"), "json": j})
            if state["down"]:
                return self.reply(503, {"error": "down"})
            if auth != "Token " + LB_TOKEN:
                return self.reply(401, {"code": 401, "error": "Invalid authorization token."})
            if p == "/lb/1/submit-listens":
                lt = j.get("listen_type")
                ok = lt in ("single", "import", "playing_now") and all(
                    l["track_metadata"].get("artist_name") and l["track_metadata"].get("track_name")
                    and (("listened_at" in l) == (lt != "playing_now")) for l in j["payload"])
                return self.reply(200 if ok else 400, {"status": "ok"} if ok else {"code": 400, "error": "Invalid listen"})
            if p == "/lb/1/feedback/recording-feedback":
                return self.reply(200, {"status": "ok"})
            return self.reply(404, {"error": "not found"})
        if p == "/lastfm/2.0/":
            form = {k: v[0] for k, v in urllib.parse.parse_qs(body, keep_blank_values=True).items()}
            m = form.get("method")
            sig_ok = form.get("api_sig") == sig(form) and form.get("api_key") == KEY
            sk_ok = form.get("sk") == SK
            self.record({"path": p, "method": "POST", "lastfm": m, "sig_ok": sig_ok, "sk_ok": sk_ok,
                         "ctype": self.headers.get("Content-Type"),
                         "form": {k: v for k, v in form.items() if k not in ("sk", "api_sig")}})
            if state["down"]:
                return self.reply(503, {"error": 16, "message": "down"})
            if not sig_ok:
                return self.reply(403, {"error": 13, "message": "Invalid method signature supplied"})
            if m == "auth.getToken":
                return self.reply(200, {"token": "fake-auth-token-1"})
            if m == "auth.getSession":
                state["session_polls"] += 1
                if state["session_polls"] < 2:
                    return self.reply(403, {"error": 14, "message": "Unauthorized Token - This token has not been authorized"})
                return self.reply(200, {"session": {"name": "demo-user", "key": SK, "subscriber": 0}})
            if not sk_ok:
                return self.reply(403, {"error": 9, "message": "Invalid session key - Please re-authenticate"})
            if m == "track.updateNowPlaying":
                return self.reply(200, {"nowplaying": {"track": {"#text": form.get("track")}}})
            if m == "track.scrobble":
                n_items = sum(1 for k in form if k.startswith("artist["))
                return self.reply(200, {"scrobbles": {"@attr": {"accepted": n_items, "ignored": 0}, "scrobble": []}})
            if m == "track.love":
                return self.reply(200, {})
            return self.reply(400, {"error": 3, "message": "Invalid Method"})
        self.reply(404, {"error": "not found"})


srv = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
srv.serve_forever()
