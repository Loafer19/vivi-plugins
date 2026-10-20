#!/usr/bin/env python3
"""Build the plugin marketplace (https://plugins.viviplayer.app) into _market/ (or argv[1]).

Input: plugins/index.json (the catalog the app reads; also copied to /index.json),
plugins/<id>/store.toml (changelog; categories/tags/screenshots are already in the index)
and screenshots from docs/screenshots/. Output: a static site with a filterable grid
(index.html, a few lines of JavaScript for search/filter/sort; without JavaScript every
card is still listed), one page per plugin (/p/<id>/), sitemap.xml, robots.txt and an
Atom feed of plugin updates (feed.xml). Standard library only.
"""
import hashlib
import html
import io
import json
import re
import shutil
import subprocess
import sys
import tomllib
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "_market"
BASE = "https://plugins.viviplayer.app"
SITE = "https://viviplayer.app"
ICONS = ROOT / "docs/site/icons"
CATEGORIES = ["Music", "Video", "Subtitles", "Streaming", "Integrations", "Tools"]
CAT_ICON = {"Music": "music", "Video": "film", "Subtitles": "captions", "Streaming": "radio",
            "Integrations": "plug", "Tools": "wrench"}
PERM = {"network": ("globe", "Internet access"), "filesystem": ("folder-open", "Reads and writes files outside its folder"),
        "subprocess": ("terminal", "Runs other programs")}
PLAT = {"linux-x86_64": "Linux x86_64", "linux-aarch64": "Linux ARM64", "windows-x86_64": "Windows",
        "macos-x86_64": "macOS Intel", "macos-aarch64": "macOS Apple silicon"}
e = lambda s: html.escape(str(s), quote=True)
# Marker over a deprecated plugin's main image: "a" diagonal banner, "b" corner ribbon,
# "c" greyed image + badge + "Replaced by", "d" striped stamp. ?depstyle=a|b|c|d previews another one.
DEP_STYLE = "a"
NAMES: dict[str, str] = {}  # plugin id -> name, filled in main() (for "Replaced by ...")


def icon(name: str) -> str:
    f = ICONS / f"{name}.svg"
    if not f.exists():
        f = ICONS / "puzzle.svg"
    svg = re.sub(r"<!--.*?-->\s*", "", f.read_text(), flags=re.S).strip()
    return svg.replace('class="lucide', 'aria-hidden="true" class="lucide', 1)


def kb(n: int) -> str:
    return f"{n / 1024:.0f} KB" if n < 1 << 20 else f"{n / (1 << 20):.1f} MB"


def download_sizes(p: dict) -> list[int]:
    """Bytes downloaded on each platform: the zip plus that platform's helpers."""
    if not p.get("size"):
        return []
    per: dict[str, int] = {}
    for b in p.get("binaries", []):
        per[b["platform"]] = per.get(b["platform"], 0) + b.get("size", 0)
    return sorted(p["size"] + n for n in per.values()) or [p["size"]]


def size_label(p: dict) -> str:
    """"12 KB", "305–628 KB" across platforms for packages with helpers, plus size_note."""
    n = download_sizes(p)
    if not n:
        return "built in"
    lo, hi = kb(n[0]), kb(n[-1])
    out = lo if lo == hi else (f"{lo[:-3]}–{hi}" if lo[-2:] == hi[-2:] else f"{lo}–{hi}")
    return f"{out} {p['size_note']}" if p.get("size_note") else out


def platforms(p: dict) -> list[str]:
    if p.get("kind") == "builtin":
        return ["Built in"]
    if p.get("binaries"):
        return sorted({PLAT.get(b["platform"], b["platform"]) for b in p["binaries"]})
    return ["Linux", "Windows", "macOS"]


def changelog(p: dict) -> list[dict]:
    if p.get("changelog"):
        return p["changelog"]
    f = ROOT / "plugins" / p["id"] / "store.toml"
    return tomllib.loads(f.read_text()).get("changelog", []) if f.exists() else []


def _git_times() -> list[tuple[str, str, set[str]]]:
    """(ISO commit time, lower-cased subject, touched paths) for every commit, newest first; [] without git."""
    try:
        git = lambda *a: subprocess.run(["git", "-C", str(ROOT), *a], capture_output=True, text=True, timeout=60, check=True).stdout
        if git("rev-parse", "--is-shallow-repository").strip() == "true":
            subprocess.run(["git", "-C", str(ROOT), "fetch", "-q", "--unshallow"], capture_output=True, timeout=120)
            if git("rev-parse", "--is-shallow-repository").strip() == "true":
                return []  # a shallow history would date every plugin to the one fetched commit
        out = subprocess.run(["git", "-C", str(ROOT), "log", "--format=%x00%cI%x01%s", "--name-only"],
                             capture_output=True, text=True, timeout=30, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    res = []
    for chunk in out.split("\0")[1:]:
        head, _, files = chunk.partition("\n")
        when, _, subj = head.partition("\x01")
        res.append((when.strip(), subj.lower(), {l for l in files.splitlines() if l}))
    return res


GIT = _git_times()


def updated(p: dict) -> str:
    """Sortable UTC timestamp of the latest update: the newest changelog/release date, refined
    to the time of the commit that shipped it (subject starts with the plugin name, or touches
    plugins/<id>/) when git history is available. Falls back to that commit alone if there is no
    changelog, then to ""."""
    dates = [c["date"] for c in changelog(p) if c.get("date")]
    day = max(dates) if dates else ""
    name, d = p["name"].lower(), f"plugins/{p['id']}/"
    for when, subj, files in GIT:
        if subj.startswith(name + " ") or subj.startswith(name + ":") or any(x.startswith(d) for x in files):
            ts = datetime.fromisoformat(when).astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            if not day or ts[:10] == day:
                return ts
            if ts[:10] < day:
                break
    return f"{day}T00:00:00Z" if day else ""


def shot_path(name: str) -> Path | None:
    for f in (ROOT / f"docs/screenshots/plugins/{name}.png", ROOT / f"docs/screenshots/{name}.png"):
        if f.exists():
            return f
    return None


SHOT_V: dict[str, str] = {}  # screenshot name -> short content hash, appended as ?v= to bust caches


def shot(s: str, ext: str, up: str = "") -> str:
    return f"{up}img/shots/{e(s)}.{ext}?v={SHOT_V.get(s, '0')}"


def write_shot(s: str, src: Path) -> None:
    """Copy the PNG and derive the WebP from that same PNG, so the thumbnail can never lag behind
    the full-size image (a prebuilt WebP is only used if Pillow is missing and it sits next to the PNG)."""
    data = src.read_bytes()
    (OUT / f"img/shots/{s}.png").write_bytes(data)
    webp = None
    try:
        from PIL import Image
        buf = io.BytesIO()
        Image.open(io.BytesIO(data)).save(buf, "WEBP", quality=82, method=6)
        webp = buf.getvalue()
    except ImportError:
        pre = src.parent / "webp" / f"{s}.webp"
        webp = pre.read_bytes() if pre.exists() else data  # browsers sniff the PNG
    (OUT / f"img/shots/{s}.webp").write_bytes(webp)
    SHOT_V[s] = hashlib.sha256(data + webp).hexdigest()[:10]


def short_platforms(p: dict) -> str:
    """Card line: OS families only ("Linux · Windows · macOS"); built-ins say nothing (the badge does)."""
    if p.get("kind") == "builtin":
        return ""
    fam = []
    for x in platforms(p):
        f = x.split()[0]
        if f not in fam:
            fam.append(f)
    order = {"Linux": 0, "Windows": 1, "macOS": 2}
    return " · ".join(sorted(fam, key=lambda f: order.get(f, 9)))


def zip_link(c: dict) -> str:
    return f' · <a href="{e(c["url"])}">download zip</a>' if c.get("url") else ""


def head(title: str, desc: str, url: str, image: str, extra: str = "", depth: int = 0) -> str:
    up = "../" * depth
    return f"""<!doctype html>
<html lang="en" data-dep-style="{DEP_STYLE}">
<head>
<meta charset="utf-8">
<script>(function(){{var s=new URLSearchParams(location.search).get("depstyle");if(/^[abcd]$/.test(s||""))document.documentElement.dataset.depStyle=s}})()</script>
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{e(title)}</title>
<meta name="description" content="{e(desc)}">
<link rel="canonical" href="{url}">
<meta name="theme-color" content="#0e0e0e">
<meta property="og:type" content="website"><meta property="og:site_name" content="Vivi plugins">
<meta property="og:title" content="{e(title)}"><meta property="og:description" content="{e(desc)}">
<meta property="og:url" content="{url}"><meta property="og:image" content="{image}">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="{e(title)}">
<meta name="twitter:description" content="{e(desc)}"><meta name="twitter:image" content="{image}">
<link rel="alternate" type="application/atom+xml" title="Vivi plugin updates" href="{BASE}/feed.xml">
<link rel="icon" href="{up}img/vivi.svg">
<link rel="stylesheet" href="{up}market.css">
{extra}
</head>
<body>
<header class="nav"><div class="in">
  <a class="brand" href="{up}./"><img src="{up}img/vivi.svg" alt="" width="26" height="26">Vivi plugins</a>
  <nav>
    <a href="{SITE}/">{icon('house')}<span class="wide">Vivi</span></a>
    <a href="{up}dev/">{icon("code-xml")}<span class="wide">Developers</span><span class="narrow">Dev</span></a>
    <a href="{up}feed.xml">{icon('rss')}<span class="wide">Updates</span></a>
    <a href="https://github.com/Loafer19/vivi-plugins">{icon('git-fork')}<span class="wide">GitHub</span></a>
  </nav>
</div></header>
<main>
"""


FOOT = f"""</main>
<footer>Vivi plugin marketplace · <a href="{SITE}/">viviplayer.app</a> · catalog as <a href="/index.json">index.json</a> ·
<a href="/dev/">Developer docs</a> ·
icons from <a href="https://lucide.dev">Lucide</a> (ISC) · screenshots show <a href="https://durian.blender.org">Sintel</a>, <a href="https://peach.blender.org">Big Buck Bunny</a> and <a href="https://mango.blender.org">Tears of Steel</a> (© Blender Foundation, CC BY 3.0)</footer>
</body>
</html>
"""


def deprecated_badge(p: dict) -> str:
    """'Deprecated — built into Vivi since 0.13.0' (catalog `deprecated`), or ''."""
    d = p.get("deprecated")
    if not d:
        return ""
    since = f" — built into Vivi since {d['since']}" if d.get("since") and d.get("replacement", "").startswith("builtin:") else ""
    return f'<span class="chip dep">Deprecated{e(since)}</span>'


def replaced_by(p: dict) -> str:
    """'Auto-tagger (built into Vivi)' / 'Chapters & Previews' from deprecated.replacement, or ''."""
    r = (p.get("deprecated") or {}).get("replacement", "")
    kind, _, rid = r.partition(":")
    if not rid:
        return ""
    name = NAMES.get(rid, rid.replace("-", " ").capitalize())
    return f"{name} (built into Vivi)" if kind == "builtin" else name


def dep_mark(p: dict) -> str:
    """Overlay on the main image of a deprecated plugin; every variant uses the same markup."""
    if not p.get("deprecated"):
        return ""
    rb = replaced_by(p)
    return (f'<span class="dep-mark" aria-hidden="true"><b>Deprecated</b>'
            f'{f"<small>Replaced by {e(rb)}</small>" if rb else ""}</span>')


def card(p: dict) -> str:
    cats = p.get("categories", [])
    shots = [s for s in p.get("screenshots", []) if shot_path(s)]
    thumb = (f'<img class="thumb" src="{shot(shots[0], 'webp')}" alt="{e(p["name"])} screenshot" loading="lazy" width="640" height="360">'
             if shots else f'<div class="thumb ph">{icon(p.get("lucide", "puzzle"))}</div>')
    if p.get("deprecated"):
        thumb = f'<div class="dep-shot">{thumb}{dep_mark(p)}</div>'
    size = size_label(p)
    kind = "Built-in" if p.get("kind") == "builtin" else ("Example script" if p.get("kind") == "script" else "Download")
    date = updated(p)
    dep = ' dep" data-dep="1' if p.get("deprecated") else ""
    return f"""<a class="card{dep}" href="p/{e(p['id'])}/" data-cats="{e('|'.join(cats))}" data-tags="{e(' '.join(p.get('tags', [])))}"
 data-name="{e(p['name'].lower())}" data-text="{e((p['name'] + ' ' + p['description'] + ' ' + ' '.join(p.get('tags', []))).lower())}"
 data-size="{(download_sizes(p) or [0])[-1]}" data-date="{e(date)}">
  {thumb}
  <div class="body">
    <div class="title"><span class="ic">{icon(p.get('lucide', 'puzzle'))}</span><h2>{e(p['name'])}</h2></div>
    <p>{e(p['description'])}</p>
    <div class="meta"><span>v{e(p.get('version', ''))}</span>{f'<span>{e(size)}</span>' if p.get('kind') != 'builtin' else ''}{f'<span>{e(short_platforms(p))}</span>' if short_platforms(p) else ''}</div>
    <div class="chips">{'<span class="chip dep">Deprecated</span>' if p.get('deprecated') else ''}<span class="chip k">{e(kind)}</span>{''.join(f'<span class="chip">{e(c)}</span>' for c in cats)}</div>
  </div>
</a>"""


def page(p: dict) -> str:
    pid = p["id"]
    url = f"{BASE}/p/{pid}/"
    shots = [s for s in p.get("screenshots", []) if shot_path(s)]
    image = f"{BASE}/{shot(shots[0], 'png')}" if shots else f"{SITE}/img/og.png"
    desc = p["description"]
    ld = {"@context": "https://schema.org", "@type": "SoftwareApplication", "name": p["name"],
          "applicationCategory": "MultimediaApplication", "applicationSubCategory": ", ".join(p.get("categories", [])),
          "operatingSystem": ", ".join(platforms(p)), "softwareVersion": p.get("version", ""), "description": desc,
          "url": url, "image": image, "author": {"@type": "Organization", "name": p.get("author", "Vivi")},
          "isPartOf": {"@type": "SoftwareApplication", "name": "Vivi", "url": SITE + "/"},
          "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"}}
    if p.get("url"):
        ld["downloadUrl"] = p["url"]
    out = head(f"{p['name']} – Vivi plugin", desc, url, image,
               f'<script type="application/ld+json">{json.dumps(ld)}</script>', depth=2)
    gallery = "".join(
        f'<figure{" class=dep-shot" if i == 0 and p.get("deprecated") else ""}><a href="{shot(s, 'png', '../../')}"><img src="{shot(s, 'webp', '../../')}" alt="{e(p["name"])} in Vivi ({i + 1})" '
        f'loading="{"eager" if i == 0 else "lazy"}" width="1280" height="720"></a>{dep_mark(p) if i == 0 else ""}</figure>' for i, s in enumerate(shots))
    # A deprecated plugin without screenshots still gets a marked main image (its icon, as on its card).
    dep_hero = (f'<div class="gallery"><figure class="dep-shot"><div class="thumb ph">{icon(p.get("lucide", "puzzle"))}</div>'
                f'{dep_mark(p)}</figure></div>') if p.get("deprecated") else ""
    perms = p.get("permissions", [])
    perm_html = "".join(f"<li>{icon(PERM.get(x, ('shield', x))[0])}{e(PERM.get(x, ('', x))[1])}</li>" for x in perms) \
        or f"<li>{icon('shield-check')}No special permissions: runs inside Vivi's mpv only</li>"
    if p.get("kind") == "builtin":
        perm_html = f"<li>{icon('shield-check')}Part of Vivi itself; turn it on or off in Settings → Extensions</li>"
    cl = changelog(p)
    cl_html = "".join(
        f"<li><div class=v><b>v{e(c['version'])}</b> <time datetime=\"{e(c.get('date', ''))}\">{e(c.get('date', ''))}</time>"
        f"{zip_link(c)}{' · <em>latest</em>' if c['version'] == p.get('version') else ''}</div>"
        f"<p>{e(c.get('notes', ''))}</p></li>" for c in cl) or "<li><p>Ships with Vivi; changes are listed in the <a href=\"https://github.com/Loafer19/vivi/blob/master/CHANGELOG.md\">Vivi changelog</a>.</p></li>"
    settings = "".join(f"<li><b>{e(s['title'])}</b> <span class=muted>({e(s['type'])})</span></li>" for s in p.get("settings", []) if s["type"] != "action")
    install = ""
    dep = p.get("deprecated")
    if dep:
        # Kept for older Vivi versions: download only, no "Open in Vivi" (Browse hides it).
        install = f"""<a class="btn ghost" href="{e(p['url'])}">{icon('download')}Download zip ({e(kb(p['size']))})</a>
<p class="muted small">For Vivi older than {e(dep.get('since', 'the current version'))} only. <a href="{SITE}/#install">Get the latest Vivi</a></p>"""
    elif p.get("kind") == "package":
        install = f"""<a class="btn primary" href="vivi://plugin/{e(pid)}">{icon('external-link')}Open in Vivi</a>
<a class="btn ghost" href="{e(p['url'])}">{icon('download')}Download zip ({e(kb(p['size']))})</a>
<p class="muted small">"Open in Vivi" shows the plugin in Settings → Extensions → Browse, where you confirm its permissions and install it.
Needs Vivi {e(p.get('min_vivi', ''))} or newer. No Vivi yet? <code>curl -fsSL {SITE}/install.sh | sh</code></p>"""
    elif p.get("kind") == "builtin":
        install = f"""<a class="btn primary" href="vivi://plugin/{e(pid)}">{icon('external-link')}Open in Vivi</a>
<p class="muted small">Built into Vivi: enable it in Settings → Extensions. <a href="{SITE}/#install">Install Vivi</a></p>"""
    else:
        install = f"""<a class="btn ghost" href="https://github.com/Loafer19/vivi-plugins/tree/master/{e(p.get('source', ''))}">{icon('code-xml')}View the script</a>"""
    src = f' · <a href="https://github.com/Loafer19/vivi-plugins/tree/master/{e(p["source"])}">source</a>' if p.get("source") else ""
    out += f"""<nav class="crumbs"><a href="../../">All plugins</a> / {e(p['name'])}</nav>
<section class="phead">
  <div class="bigic">{icon(p.get('lucide', 'puzzle'))}</div>
  <div><h1>{e(p['name'])}</h1>
  {f'<div class="deprecated">{deprecated_badge(p)}<p>{e(dep.get("message", ""))}</p></div>' if dep else ''}
  <p class="lead">{e(desc)}</p>
  <div class="meta"><span>v{e(p.get('version', ''))}</span>{f'<span>{e(size_label(p))}</span>' if p.get('kind') != 'builtin' else '<span>Built into Vivi</span>'}
  {f'<span>{e(", ".join(platforms(p)))}</span>' if p.get('kind') != 'builtin' else ''}<span>by {e(p.get('author', ''))}{src}</span></div>
  <div class="chips">{''.join(f'<a class="chip" href="../../?cat={e(c)}">{e(c)}</a>' for c in p.get('categories', []))}
  {''.join(f'<span class="chip t">#{e(t)}</span>' for t in p.get('tags', []))}</div>
  <div class="actions">{install}</div></div>
</section>
{f'<h2>Screenshots</h2><div class="gallery">{gallery}</div>' if gallery else dep_hero}
<div class="cols">
<section><h2>Changelog</h2><ol class="changelog">{cl_html}</ol></section>
<section><h2>Permissions</h2><ul class="perms">{perm_html}</ul>
{f'<h2>Settings</h2><ul class="settings">{settings}</ul>' if settings else ''}</section>
</div>
"""
    return out + FOOT.replace('href="/index.json"', 'href="../../index.json"')


# Developer docs: one page per docs/dev/<slug>.md (single source of truth), rendered with a sidebar.
DEV_PAGES = ["index", "manifest", "lua-api", "permissions", "settings", "ui-hooks", "binaries",
             "packaging", "catalog", "architecture"]


def build_dev() -> list[str]:
    import markdown
    docs = []
    for slug in DEV_PAGES:
        src = (ROOT / f"docs/dev/{slug}.md").read_text()
        title = src.splitlines()[0].lstrip("# ").strip()
        m = re.search(r"<!-- desc: (.*?) -->", src)
        docs.append((slug, title, m.group(1) if m else title, src))
    urls = []
    for slug, title, desc, src in docs:
        depth = 1 if slug == "index" else 2
        up = "../" * (depth - 1)
        side = "".join(
            f'<a href="{up}{"" if s == "index" else s + "/"}"{" class=on aria-current=page" if s == slug else ""}>{e(t)}</a>'
            for s, t, _, _ in docs)
        body = markdown.markdown(src, extensions=["tables", "fenced_code", "toc"])
        i = DEV_PAGES.index(slug)
        nxt = docs[i + 1] if i + 1 < len(docs) else None
        pager = (f'<p class="pager"><a href="{up}{nxt[0]}/">Next: {e(nxt[1])} →</a></p>' if nxt else "")
        url = BASE + "/dev/" + ("" if slug == "index" else slug + "/")
        page_title = "Vivi plugin developer docs" if slug == "index" else f"{title} – Vivi plugin developer docs"
        d = OUT / "dev" / ("" if slug == "index" else slug)
        d.mkdir(parents=True, exist_ok=True)
        (d / "index.html").write_text(
            head(page_title, desc, url, f"{SITE}/img/og.png", depth=depth)
            + f'<div class="devdocs"><nav class="side" aria-label="Developer docs"><b>Developer docs</b>{side}</nav>'
            + f'<article class="doc">{body}{pager}</article></div>\n'
            + FOOT.replace('href="/', f'href="{"../" * depth}'))
        urls.append(url)
    return urls


def main() -> None:
    idx = json.loads((ROOT / "plugins/index.json").read_text())
    plugins = [p for p in idx["plugins"]]
    NAMES.update({p["id"]: p["name"] for p in plugins})
    # Deprecated plugins are in the grid but only under the "Deprecated" filter (?cat=deprecated);
    # the default listing, search, counts and ItemList leave them out.
    listed = [p for p in plugins if not p.get("deprecated")]
    deprecated = sorted((p for p in plugins if p.get("deprecated")), key=lambda p: p["name"].lower())
    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "img/shots").mkdir(parents=True)
    shutil.copy(ROOT / "plugins/index.json", OUT / "index.json")
    shutil.copy(ROOT / "docs/marketplace/market.css", OUT / "market.css")
    shutil.copy(ROOT / "packaging/vivi.svg", OUT / "img/vivi.svg")
    for p in plugins:
        for s in p.get("screenshots", []):
            f = shot_path(s)
            if f and s not in SHOT_V:
                write_shot(s, f)
    order = sorted(listed, key=lambda p: (p.get("kind") == "script", p["name"].lower()))
    cats = "".join(f'<button type="button" data-cat="{c}">{icon(CAT_ICON[c])}{c}</button>' for c in CATEGORIES)
    dep_btn = (f'<span class="sep" aria-hidden="true"></span><button type="button" data-cat="deprecated" class="depf" '
               f'title="Plugins replaced by Vivi features or other plugins; kept for older Vivi">{icon("archive")}Deprecated'
               f'<span class="n">{len(deprecated)}</span></button>') if deprecated else ""
    desc = (f"{len(listed)} plugins for the Vivi media player: music, video, subtitles, streaming, integrations and tools. "
            "Install them in one click from Vivi.")
    ld = {"@context": "https://schema.org", "@type": "ItemList", "name": "Vivi plugins",
          "itemListElement": [{"@type": "ListItem", "position": i + 1, "url": f"{BASE}/p/{p['id']}/", "name": p["name"]}
                              for i, p in enumerate(order)]}
    out = head("Vivi plugins – extensions for the Vivi media player", desc, BASE + "/", f"{SITE}/img/og.png",
               f'<script type="application/ld+json">{json.dumps(ld)}</script>')
    out += f"""<section class="hero"><h1>Plugins for <span>Vivi</span></h1>
<p>{len(listed)} extensions. Built-in ones ship with Vivi; downloadable ones install from Settings → Extensions → Browse
with checksums verified and permissions shown before install.</p></section>
<div class="toolbar">
  <label class="search">{icon('search')}<input id="q" type="search" placeholder="Search plugins" aria-label="Search plugins"></label>
  <div class="cats" role="group" aria-label="Category"><button type="button" data-cat="" class="on">All</button>{cats}{dep_btn}</div>
  <label class="sort">Sort <select id="sort" aria-label="Sort"><option value="name">Name</option><option value="date">Recently updated</option></select></label>
</div>
<p id="empty" class="muted" hidden>No plugins match.</p>
<p id="deptip" class="muted small" hidden></p>
<div class="grid" id="grid">
{''.join(card(p) for p in order)}
{''.join(card(p) for p in deprecated)}
</div>
<script src="market.js" defer></script>
""" + FOOT
    (OUT / "index.html").write_text(out)
    shutil.copy(ROOT / "docs/marketplace/market.js", OUT / "market.js")
    for p in plugins:
        d = OUT / "p" / p["id"]
        d.mkdir(parents=True)
        (d / "index.html").write_text(page(p))
    dev_urls = build_dev()
    urls = [BASE + "/"] + dev_urls + [f"{BASE}/p/{p['id']}/" for p in order + [p for p in plugins if p.get("deprecated")]]
    (OUT / "sitemap.xml").write_text('<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
                                     + "".join(f"<url><loc>{u}</loc></url>" for u in urls) + "</urlset>\n")
    (OUT / "robots.txt").write_text(f"User-agent: *\nAllow: /\nSitemap: {BASE}/sitemap.xml\n")
    # Atom feed: one entry per plugin version, newest first.
    items = sorted(((c.get("date", ""), p, c) for p in plugins for c in changelog(p)), key=lambda t: (t[0], t[2]["version"]), reverse=True)
    stamp = lambda d: f"{d}T00:00:00Z" if d else datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    x = lambda s: html.escape(str(s), quote=False)
    entries = "".join(f"""<entry><title>{x(p['name'])} {x(c['version'])}</title>
<id>{BASE}/p/{p['id']}/#v{x(c['version'])}</id><link href="{BASE}/p/{p['id']}/"/>
<updated>{stamp(d)}</updated><summary>{x(c.get('notes', ''))}</summary></entry>
""" for d, p, c in items[:50])
    (OUT / "feed.xml").write_text(f"""<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>Vivi plugin updates</title>
<id>{BASE}/feed.xml</id><link rel="self" href="{BASE}/feed.xml"/><link href="{BASE}/"/>
<updated>{stamp(items[0][0] if items else '')}</updated><author><name>Vivi</name></author>
{entries}</feed>
""")
    print(f"marketplace built in {OUT} ({len(plugins)} plugins, {len(items)} feed entries)")


if __name__ == "__main__":
    main()
