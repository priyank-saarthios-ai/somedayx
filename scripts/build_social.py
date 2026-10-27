"""Build the website's social and search assets: Open Graph images, the demo
video, icons, one share page per Wrapped persona, and the sitemap.

    uv run python scripts/build_social.py            # everything
    uv run python scripts/build_social.py --no-video # skip recording the demo

Personas here must match `Wrapped.personaSlug` in macapp/SomedayX.swift: the
app's share caption links to somedayx.com/p/<slug>, and that page's preview
image is the persona's card.
"""

import html
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from playwright.sync_api import sync_playwright

SITE = Path(__file__).resolve().parent.parent / "site"
BASE = "https://somedayx.com"
OG_W, OG_H = 1200, 630

# slug, emoji, name, roast, theme colours
PERSONAS = [
    ("ai-agent-maximalist", "🤖", "AI agent maximalist", "Bookmarks every new agent framework. Uses none of them.", "#1d9bf0", "#7856ff"),
    ("founder-brain", "🚀", "founder brain, unemployed thumbs", "Saves every fundraising thread. Replies to zero investors.", "#ff7a00", "#f91880"),
    ("design-snob", "🎨", "certified design snob", "400 landing pages saved for inspiration. Ships in Times New Roman.", "#f91880", "#7856ff"),
    ("repo-hoarder", "🧑‍💻", "professional repo hoarder", "Stars it. Bookmarks it. Never clones it.", "#00ba7c", "#1d9bf0"),
    ("pm-in-denial", "🧩", "PM in denial", "Saves every prioritisation framework. Prioritises nothing.", "#7856ff", "#1d9bf0"),
    ("growth-goblin", "📈", "growth goblin", "Knows 37 viral hooks by heart. Posts twice a year.", "#00ba7c", "#ffd400"),
    ("meme-archivist", "🤡", "meme archivist", "The group chat's unofficial museum curator.", "#ffd400", "#f91880"),
    ("armchair-selector", "🏏", "armchair selector", "Would have picked a better XI. Has the receipts saved.", "#00ba7c", "#ff7a00"),
    ("chief-curator", "🗂️", "chief curator of the timeline", "Saves a little of everything. A renaissance hoarder.", "#1d9bf0", "#f91880"),
]

LOGO_SVG = ("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' rx='22' "
            "fill='{bg}'/><path d='M30 18h40v66L50 70 30 84z' fill='{fg}'/></svg>")

FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', sans-serif"
CARD_CSS = f"""
* {{ margin: 0; box-sizing: border-box; }}
body {{ width: {OG_W}px; height: {OG_H}px; overflow: hidden; background: #000; color: #e7e9ea;
       font-family: {FONT}; -webkit-font-smoothing: antialiased; }}
.frame {{ position: relative; width: 100%; height: 100%; padding: 64px 72px; }}
.logo {{ display: flex; align-items: center; gap: 14px; font-weight: 800; font-size: 30px; }}
.logo svg {{ width: 44px; height: 44px; }}
.url {{ position: absolute; right: 72px; bottom: 56px; font-size: 26px; color: #8b9096; font-weight: 600; }}
"""


def glow(c1: str, c2: str) -> str:
    return (f"background: radial-gradient(700px 420px at 85% 10%, {c1}66, transparent 70%),"
            f"radial-gradient(600px 400px at 5% 100%, {c2}40, transparent 70%), #000;")


def home_card() -> str:
    rows = [("#1d9bf0", "A founder you follow", "How to <b>price</b> your SaaS: 9 lessons from raising <b>prices</b>"),
            ("#f91880", "A newsletter writer", "The <b>pricing</b> page teardown I wish I'd read"),
            ("#00ba7c", "An indie hacker", "We doubled our <b>price</b>. Churn went down.")]
    row_html = "".join(
        f"<div class='row{' sel' if i == 0 else ''}'><span class='av' style='background:{c}'></span>"
        f"<div><div class='n'>{n}</div><div class='t'>{t}</div></div></div>" for i, (c, n, t) in enumerate(rows))
    return f"""<style>{CARD_CSS}
      .frame {{ {glow('#1d9bf0', '#f91880')} display: grid; grid-template-columns: 1.05fr 1fr; gap: 40px; align-items: center; }}
      h1 {{ font-size: 64px; line-height: 1.02; letter-spacing: -2px; font-weight: 900; margin-top: 34px; }}
      h1 span {{ color: #71767b; }}
      .sub {{ font-size: 25px; color: #c4c8cc; margin-top: 22px; line-height: 1.35; }}
      .panel {{ background: #0b0b0c; border: 1px solid #2f3336; border-radius: 22px; overflow: hidden;
               box-shadow: 0 30px 80px rgba(29,155,240,.25); }}
      .bar {{ margin: 16px; padding: 0 18px; height: 52px; border: 2px solid #1d9bf0; border-radius: 999px;
             display: flex; align-items: center; font-size: 20px; gap: 10px; }}
      .row {{ display: flex; gap: 14px; padding: 15px 20px; border-top: 1px solid #2f3336; }}
      .row.sel {{ background: rgba(29,155,240,.13); box-shadow: inset 4px 0 0 #1d9bf0; }}
      .av {{ width: 40px; height: 40px; border-radius: 50%; flex: none; }}
      .n {{ font-size: 16px; font-weight: 700; }} .t {{ font-size: 17px; color: #d6d9db; margin-top: 3px; }}
    </style>
    <div class='frame'>
      <div>
        <div class='logo'>{LOGO_SVG.format(bg='#fff', fg='#000')}SomedayX</div>
        <h1>For the X posts you'll read <span>someday.</span></h1>
        <div class='sub'>Search your X bookmarks &amp; likes by meaning, even inside images. 100% on your Mac.</div>
      </div>
      <div class='panel'><div class='bar'>🔍 that thread about pricing</div>{row_html}</div>
      <div class='url'>somedayx.com · free &amp; open source</div>
    </div>"""


def persona_card(emoji: str, name: str, roast: str, c1: str, c2: str) -> str:
    a = "an" if name[0].lower() in "aeiou" else "a"
    return f"""<style>{CARD_CSS}
      .frame {{ {glow(c1, c2)} }}
      .kicker {{ margin-top: 56px; font-size: 28px; color: #c4c8cc; font-weight: 600; }}
      .who {{ display: flex; align-items: center; gap: 30px; margin-top: 14px; }}
      .emoji {{ font-size: 130px; line-height: 1; }}
      .name {{ font-size: 76px; font-weight: 900; letter-spacing: -2.5px; line-height: 1.0; max-width: 880px;
              background: linear-gradient(90deg, #fff 40%, {c1}); -webkit-background-clip: text; color: transparent; }}
      .roast {{ margin-top: 30px; font-size: 30px; color: #e7e9ea; max-width: 900px; }}
      .cta {{ position: absolute; left: 72px; bottom: 54px; font-size: 26px; font-weight: 700;
             padding: 12px 22px; border-radius: 999px; background: linear-gradient(90deg, {c1}, {c2}); color: #fff; }}
    </style>
    <div class='frame'>
      <div class='logo'>{LOGO_SVG.format(bg='#fff', fg='#000')}SomedayX Wrapped</div>
      <div class='kicker'>my X bookmarks say I'm {a}</div>
      <div class='who'><div class='emoji'>{emoji}</div><div class='name'>{html.escape(name)}</div></div>
      <div class='roast'>{html.escape(roast)}</div>
      <div class='cta'>what's yours? find out free</div>
      <div class='url'>somedayx.com</div>
    </div>"""


def share_page(slug, emoji, name, roast, c1, c2) -> str:
    a = "an" if name[0].lower() in "aeiou" else "a"
    title = f"{emoji} {a.capitalize()} {name}: a SomedayX Wrapped"
    desc = f"{roast} SomedayX reads your X bookmarks and likes on your Mac and tells you what kind of saver you are. Free, open source, 100% local."
    url = f"{BASE}/p/{slug}/"
    others = "".join(f"<a href='/p/{s}/'>{e} {html.escape(n)}</a>" for s, e, n, *_ in PERSONAS if s != slug)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(desc)}">
<link rel="canonical" href="{url}">
<script defer src="https://cloud.umami.is/script.js" data-website-id="664a070a-3b3c-4188-a8e2-406e4eaaa0fb"></script>
<meta name="theme-color" content="#000000">
<link rel="icon" href="/icon-32.png" sizes="32x32"><link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta property="og:type" content="website">
<meta property="og:site_name" content="SomedayX">
<meta property="og:title" content="{html.escape(title)}">
<meta property="og:description" content="{html.escape(roast)} What's your X persona?">
<meta property="og:url" content="{url}">
<meta property="og:image" content="{BASE}/img/og/{slug}.png">
<meta property="og:image:width" content="{OG_W}"><meta property="og:image:height" content="{OG_H}">
<meta property="og:image:alt" content="SomedayX Wrapped persona card: {html.escape(name)}">
<meta property="og:video" content="{BASE}/media/demo.mp4">
<meta property="og:video:secure_url" content="{BASE}/media/demo.mp4">
<meta property="og:video:type" content="video/mp4">
<meta property="og:video:width" content="1280"><meta property="og:video:height" content="720">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{html.escape(title)}">
<meta name="twitter:description" content="{html.escape(roast)} What's your X persona?">
<meta name="twitter:image" content="{BASE}/img/og/{slug}.png">
<meta name="twitter:creator" content="@priyankmmehta">
<style>
  * {{ box-sizing: border-box; margin: 0; }}
  body {{ background: #000; color: #e7e9ea; font: 17px/1.55 {FONT}; -webkit-font-smoothing: antialiased; }}
  .wrap {{ max-width: 760px; margin: 0 auto; padding: 32px 20px 60px; }}
  a {{ color: inherit; }}
  .logo {{ display: inline-flex; gap: 10px; align-items: center; font-weight: 800; text-decoration: none; }}
  .logo img {{ width: 28px; height: 28px; }}
  img.card {{ width: 100%; border-radius: 18px; margin-top: 28px; box-shadow: 0 20px 70px {c1}40; }}
  h1 {{ font-size: clamp(30px, 6vw, 46px); letter-spacing: -.03em; line-height: 1.08; margin-top: 32px; }}
  p {{ color: #c4c8cc; margin-top: 12px; font-size: 18px; }}
  .btn {{ display: inline-block; margin-top: 24px; padding: 13px 22px; border-radius: 999px; font-weight: 700;
         background: #e7e9ea; color: #000; text-decoration: none; }}
  .more {{ margin-top: 44px; color: #71767b; font-size: 14px; }}
  .more div {{ display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px; }}
  .more a {{ padding: 6px 12px; border-radius: 999px; border: 1px solid #2f3336; text-decoration: none; color: #c4c8cc; font-size: 14px; }}
</style>
</head>
<body>
<div class="wrap">
  <a class="logo" href="/"><img src="/icon-192.png" alt="">SomedayX</a>
  <img class="card" src="/img/og/{slug}.png" alt="Wrapped persona card: {html.escape(name)}" width="{OG_W}" height="{OG_H}">
  <h1>Someone's X bookmarks say they're {a} {html.escape(name)} {emoji}</h1>
  <p>{html.escape(roast)}</p>
  <p>SomedayX searches everything you've bookmarked or liked on X by meaning, even inside images, from your Mac's menu bar. Then it roasts you. Free, open source, and it never leaves your Mac.</p>
  <a class="btn" href="/" data-umami-event="persona-cta">Find out what yours say →</a>
  <div class="more">Other personas<div>{others}</div></div>
</div>
</body>
</html>
"""


def article_card(kicker: str, title: str) -> str:
    return f"""<style>{CARD_CSS}
      .frame {{ {glow('#1d9bf0', '#7856ff')} }}
      .kicker {{ margin-top: 70px; font-size: 26px; font-weight: 700; color: #1d9bf0; text-transform: uppercase; letter-spacing: 2px; }}
      h1 {{ margin-top: 18px; font-size: 68px; line-height: 1.05; letter-spacing: -2px; font-weight: 900; max-width: 1000px; }}
    </style>
    <div class='frame'>
      <div class='logo'>{LOGO_SVG.format(bg='#fff', fg='#000')}SomedayX</div>
      <div class='kicker'>{html.escape(kicker)}</div>
      <h1>{html.escape(title)}</h1>
      <div class='url'>somedayx.com · free &amp; open source</div>
    </div>"""


# Long-form pages (guides, comparisons) live in scripts/pages/*.html: a header
# comment of `key: value` lines, then the article body. The build wraps each
# in the site's look, metadata, JSON-LD (Article + its FAQ) and a preview card.
PAGES_SRC = Path(__file__).resolve().parent / "pages"


def load_pages() -> list[dict]:
    pages = []
    for f in sorted(PAGES_SRC.glob("*.html")):
        head, body = re.match(r"\s*<!--(.*?)-->(.*)", f.read_text(), re.S).groups()
        meta = dict(l.split(":", 1) for l in head.strip().splitlines())
        meta = {k.strip(): v.strip() for k, v in meta.items()}
        pages.append({**meta, "name": f.stem, "body": body.strip(), "url": f"{BASE}/{meta['path']}/"})
    return pages


def article_page(pg: dict) -> str:
    strip = lambda t: html.unescape(re.sub(r"<[^>]+>", "", t)).strip()
    faq = re.findall(r"<details><summary>(.*?)</summary>(.*?)</details>", pg["body"], re.S)
    img = f"{BASE}/img/og/{pg['name']}.png"
    graph = [
        {"@type": "Article", "headline": pg["title"], "description": pg["description"], "image": img,
         "datePublished": pg["published"], "dateModified": pg["updated"], "mainEntityOfPage": pg["url"],
         "author": {"@type": "Person", "name": "Priyank Mehta", "url": "https://x.com/priyankmmehta"},
         "publisher": {"@id": f"{BASE}/#site"}, "about": {"@id": f"{BASE}/#app"}},
        {"@type": "BreadcrumbList", "itemListElement": [
            {"@type": "ListItem", "position": 1, "name": "SomedayX", "item": f"{BASE}/"},
            {"@type": "ListItem", "position": 2, "name": pg["crumb"], "item": pg["url"]}]},
    ]
    if faq:
        graph.append({"@type": "FAQPage", "mainEntity": [
            {"@type": "Question", "name": strip(q), "acceptedAnswer": {"@type": "Answer", "text": strip(a)}}
            for q, a in faq]})
    jsonld = json.dumps({"@context": "https://schema.org", "@graph": graph}, ensure_ascii=False)
    updated = f"{int(pg['updated'][8:])} {['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][int(pg['updated'][5:7]) - 1]} {pg['updated'][:4]}"
    others = "".join(f"<a href='/{o['path']}/'>{html.escape(o['card'])}</a>" for o in load_pages() if o["name"] != pg["name"])
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(pg['title'])}</title>
<meta name="description" content="{html.escape(pg['description'])}">
<link rel="canonical" href="{pg['url']}">
<meta name="robots" content="index, follow, max-image-preview:large">
<script defer src="https://cloud.umami.is/script.js" data-website-id="664a070a-3b3c-4188-a8e2-406e4eaaa0fb"></script>
<meta name="theme-color" content="#000000">
<link rel="icon" href="/icon-32.png" sizes="32x32"><link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta property="og:type" content="article">
<meta property="og:site_name" content="SomedayX">
<meta property="og:title" content="{html.escape(pg['title'])}">
<meta property="og:description" content="{html.escape(pg['description'])}">
<meta property="og:url" content="{pg['url']}">
<meta property="og:image" content="{img}">
<meta property="og:image:width" content="{OG_W}"><meta property="og:image:height" content="{OG_H}">
<meta property="article:modified_time" content="{pg['updated']}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="{html.escape(pg['title'])}">
<meta name="twitter:description" content="{html.escape(pg['description'])}">
<meta name="twitter:image" content="{img}">
<meta name="twitter:creator" content="@priyankmmehta">
<script type="application/ld+json">{jsonld}</script>
<style>
  * {{ box-sizing: border-box; margin: 0; }}
  body {{ background: #000; color: #e7e9ea; font: 17px/1.65 {FONT}; -webkit-font-smoothing: antialiased; }}
  .wrap {{ max-width: 760px; margin: 0 auto; padding: 32px 20px 70px; }}
  a {{ color: #1d9bf0; }}
  .logo {{ display: inline-flex; gap: 10px; align-items: center; font-weight: 800; text-decoration: none; color: #e7e9ea; }}
  .logo img {{ width: 28px; height: 28px; }}
  .meta {{ margin-top: 34px; color: #71767b; font-size: 14px; }}
  h1 {{ font-size: clamp(30px, 6vw, 44px); letter-spacing: -.03em; line-height: 1.1; margin-top: 8px; }}
  h2 {{ font-size: 25px; letter-spacing: -.02em; line-height: 1.25; margin-top: 44px; }}
  h3 {{ font-size: 19px; margin-top: 28px; }}
  p, li {{ color: #c4c8cc; }} p {{ margin-top: 14px; }}
  ul, ol {{ margin-top: 12px; padding-left: 22px; }} li {{ margin-top: 6px; }}
  strong {{ color: #e7e9ea; }}
  code {{ font: 14px ui-monospace, SFMono-Regular, Menlo, monospace; background: #16181c; padding: 2px 6px; border-radius: 6px; }}
  .answer {{ margin-top: 20px; padding: 16px 18px; border-left: 3px solid #1d9bf0; background: #0b0b0c; border-radius: 0 12px 12px 0; }}
  .answer p:first-child {{ margin-top: 0; }}
  .scroll {{ overflow-x: auto; margin-top: 18px; border: 1px solid #2f3336; border-radius: 12px; }}
  table {{ border-collapse: collapse; width: 100%; min-width: 640px; font-size: 15px; }}
  th, td {{ text-align: left; padding: 10px 12px; border-bottom: 1px solid #2f3336; vertical-align: top; color: #c4c8cc; }}
  th {{ color: #e7e9ea; background: #0b0b0c; }} tr:last-child td {{ border-bottom: 0; }}
  details {{ margin-top: 10px; border: 1px solid #2f3336; border-radius: 12px; padding: 12px 16px; }}
  summary {{ cursor: pointer; font-weight: 700; color: #e7e9ea; }}
  .btn {{ display: inline-block; margin-top: 22px; padding: 13px 22px; border-radius: 999px; font-weight: 700;
         background: #e7e9ea; color: #000; text-decoration: none; }}
  .note {{ font-size: 14px; color: #71767b; }}
  .more {{ margin-top: 50px; padding-top: 20px; border-top: 1px solid #2f3336; color: #71767b; font-size: 14px; }}
  .more a {{ margin-right: 16px; }}
</style>
</head>
<body>
<div class="wrap">
  <a class="logo" href="/"><img src="/icon-192.png" alt="">SomedayX</a>
  <div class="meta">{html.escape(pg['crumb'])} · Updated <time datetime="{pg['updated']}">{updated}</time> · by <a href="https://x.com/priyankmmehta">Priyank Mehta</a></div>
{pg['body']}
  <div class="more">More: <a href="/">SomedayX home</a>{others}<a href="https://github.com/priyank-saarthios-ai/somedayx">Source on GitHub</a></div>
</div>
</body>
</html>
"""


DEMO_HTML = """<!doctype html><html><head><meta charset="utf-8"><style>
* { margin: 0; box-sizing: border-box; }
body { width: 1280px; height: 720px; overflow: hidden; color: #e7e9ea; font-family: FONT;
       background: radial-gradient(700px 420px at 80% 10%, #1d9bf044, transparent 70%),
                   radial-gradient(600px 400px at 10% 100%, #f9188026, transparent 70%), #000;
       display: grid; place-items: center; -webkit-font-smoothing: antialiased; }
.stage { width: 760px; }
.keys { display: flex; gap: 12px; justify-content: center; margin-bottom: 20px; }
.key { width: 60px; height: 60px; border-radius: 14px; display: grid; place-items: center; font-size: 27px; font-weight: 600;
       background: #16181c; border: 1px solid #2f3336; box-shadow: 0 3px 0 #000; transition: all .12s; }
.key.lit { background: #1d9bf0; color: #fff; transform: translateY(2px) scale(.94); box-shadow: none; }
.panel { background: #0b0b0c; border: 1px solid #2f3336; border-radius: 20px; overflow: hidden; box-shadow: 0 30px 90px rgba(29,155,240,.22); }
.bar { display: flex; align-items: center; gap: 12px; margin: 16px; padding: 0 18px; height: 54px; border: 2px solid #1d9bf0; border-radius: 999px; font-size: 20px; }
.caret { width: 2px; height: 22px; background: #1d9bf0; }
.rows { border-top: 1px solid #2f3336; min-height: 285px; }
.row { display: flex; gap: 14px; padding: 15px 20px; border-bottom: 1px solid #2f3336; opacity: 0; transform: translateY(10px); transition: all .35s cubic-bezier(.2,.8,.2,1); }
.row.in { opacity: 1; transform: none; } .row.sel { background: rgba(29,155,240,.12); box-shadow: inset 4px 0 0 #1d9bf0; }
.av { width: 40px; height: 40px; border-radius: 50%; flex: none; }
.tag { font-size: 14px; font-weight: 700; color: #1d9bf0; } .n { font-size: 15px; font-weight: 700; }
.t { font-size: 17px; color: #d6d9db; margin-top: 2px; } .t b { color: #fff; }
.foot { display: flex; justify-content: space-between; padding: 11px 20px; font-size: 14px; color: #71767b; background: #16181c; }
.title { text-align: center; margin-top: 24px; font-size: 22px; color: #8b9096; font-weight: 600; }
</style></head><body><div class="stage">
<div class="keys"><div class="key" id="k1">⌥</div><div class="key" id="k2">⌥</div></div>
<div class="panel"><div class="bar">🔍 <span id="q"></span><span class="caret"></span></div><div class="rows" id="rows"></div>
<div class="foot"><span>SomedayX · double-tap ⌥ from anywhere</span><span>found by meaning ✨</span></div></div>
<div class="title">search your X bookmarks by meaning · 100% on your Mac · somedayx.com</div>
</div><script>
const demos = [
 {q: "that thread about pricing", hits: [["🧵 thread · bookmarked 2024","A founder you follow","How to <b>price</b> your SaaS: 9 lessons from raising <b>prices</b> 3 times","#1d9bf0"],["","A newsletter writer","The <b>pricing</b> page teardown I wish I'd read before launch","#f91880"],["","An indie hacker","We doubled our <b>price</b>. Churn went down. Here's why","#00ba7c"]]},
 {q: "screenshot of a dashboard", hits: [["🖼️ found in an image · liked 2023","A designer you like","Shipped the new analytics view this week","#7856ff"],["","A data person","My favourite <b>dashboard</b> layouts, collected over 2 years","#ffd400"],["","A startup","Our metrics, publicly, every month","#1d9bf0"]]},
];
const q = document.getElementById("q"), rows = document.getElementById("rows");
const wait = ms => new Promise(r => setTimeout(r, ms));
async function run() {
  for (const d of demos) {
    for (const k of ["k1", "k2"]) { const e = document.getElementById(k); e.classList.add("lit"); await wait(170); e.classList.remove("lit"); await wait(120); }
    rows.innerHTML = ""; q.textContent = "";
    for (const ch of d.q) { q.textContent += ch; await wait(60); }
    await wait(250);
    rows.innerHTML = d.hits.map((h, i) => `<div class="row${i ? "" : " sel"}"><span class="av" style="background:${h[3]}"></span><div>${h[0] ? `<div class="tag">${h[0]}</div>` : ""}<div class="n">${h[1]}</div><div class="t">${h[2]}</div></div></div>`).join("");
    for (const r of rows.children) { r.classList.add("in"); await wait(120); }
    await wait(2300);
  }
  document.title = "done";
}
setTimeout(run, 400);
</script></body></html>""".replace("FONT", FONT)


def render(page, html_body: str, out: Path) -> None:
    page.set_content(f"<!doctype html><html><head><meta charset='utf-8'></head><body>{html_body}</body></html>")
    page.wait_for_timeout(300)
    out.parent.mkdir(parents=True, exist_ok=True)
    page.screenshot(path=str(out), clip={"x": 0, "y": 0, "width": OG_W, "height": OG_H})


def icons(page) -> None:
    for name, size in (("apple-touch-icon.png", 180), ("icon-192.png", 192), ("icon-512.png", 512), ("icon-32.png", 32)):
        page.set_viewport_size({"width": size, "height": size})
        page.set_content(f"<body style='margin:0;background:transparent'>{LOGO_SVG.format(bg='#000', fg='#fff')}</body>"
                         .replace("<svg ", f"<svg width='{size}' height='{size}' "))
        page.screenshot(path=str(SITE / name), omit_background=True)


def record_demo(browser) -> None:
    tmp = Path(tempfile.mkdtemp())
    ctx = browser.new_context(viewport={"width": 1280, "height": 720}, record_video_dir=str(tmp),
                              record_video_size={"width": 1280, "height": 720})
    page = ctx.new_page()
    page.set_content(DEMO_HTML)
    page.wait_for_function("document.title === 'done'", timeout=60_000)
    page.wait_for_timeout(500)
    page.screenshot(path=str(SITE / "media" / "demo.jpg"), type="jpeg", quality=88)
    video = page.video.path()
    ctx.close()
    # H.264 + faststart so link previews (and iOS) can play it; skip the blank first moments.
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-ss", "0.4", "-i", video, "-c:v", "libx264",
                    "-pix_fmt", "yuv420p", "-crf", "24", "-preset", "slow", "-movflags", "+faststart", "-an",
                    str(SITE / "media" / "demo.mp4")], check=True)
    shutil.rmtree(tmp, ignore_errors=True)


def sitemap() -> None:
    urls = [(f"{BASE}/", "")] + [(pg["url"], pg["updated"]) for pg in load_pages()]
    urls += [(f"{BASE}/p/{slug}/", "") for slug, *_ in PERSONAS]
    body = "".join(f"<url><loc>{u}</loc>{f'<lastmod>{d}</lastmod>' if d else ''}</url>" for u, d in urls)
    (SITE / "sitemap.xml").write_text(
        f'<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">{body}</urlset>\n')


def structured_data() -> None:
    """JSON-LD for search engines and AI answer engines: the app, its demo
    video, and the page's FAQ (read from the FAQ itself, so they can't drift)."""
    page = (SITE / "index.html").read_text()
    faq = re.findall(r"<details><summary>(.*?)</summary><p>(.*?)</p></details>", page)
    strip = lambda t: html.unescape(re.sub(r"<[^>]+>", "", t))
    graph = [
        {"@type": "SoftwareApplication", "@id": f"{BASE}/#app", "name": "SomedayX",
         "description": "Search everything you've bookmarked or liked on X (Twitter) by meaning, even inside images, "
                        "from your Mac's menu bar. Runs 100% on-device with EmbeddingGemma.",
         "url": f"{BASE}/", "image": f"{BASE}/img/og.png", "screenshot": f"{BASE}/img/card-11.jpg",
         "applicationCategory": "UtilitiesApplication", "operatingSystem": "macOS 14 or later",
         "softwareVersion": "1.1.1", "isAccessibleForFree": True, "license": "https://opensource.org/licenses/MIT",
         "downloadUrl": "https://github.com/priyank-saarthios-ai/somedayx",
         "sameAs": ["https://github.com/priyank-saarthios-ai/somedayx"],
         "offers": {"@type": "Offer", "price": "0", "priceCurrency": "USD"},
         "author": {"@type": "Person", "name": "Priyank Mehta", "url": "https://x.com/priyankmmehta",
                    "sameAs": ["https://x.com/priyankmmehta", "https://github.com/priyank-saarthios-ai"]},
         "video": {"@type": "VideoObject", "name": "SomedayX demo: search your X bookmarks by meaning",
                   "description": "Double-tap Option, type what you remember, and SomedayX finds the post.",
                   "thumbnailUrl": f"{BASE}/media/demo.jpg", "contentUrl": f"{BASE}/media/demo.mp4",
                   "uploadDate": "2026-10-26", "duration": "PT11S"}},
        {"@type": "WebSite", "@id": f"{BASE}/#site", "name": "SomedayX", "url": f"{BASE}/"},
        {"@type": "FAQPage", "mainEntity": [
            {"@type": "Question", "name": strip(q), "acceptedAnswer": {"@type": "Answer", "text": strip(a)}}
            for q, a in faq]},
    ]
    block = ('<!-- jsonld:start (generated by scripts/build_social.py from the FAQ below) -->\n'
             '<script type="application/ld+json">' + json.dumps({"@context": "https://schema.org", "@graph": graph},
                                                                  ensure_ascii=False) + '</script>\n<!-- jsonld:end -->')
    page = re.sub(r"<!-- jsonld:start.*?<!-- jsonld:end -->", lambda _: block, page, flags=re.S)
    (SITE / "index.html").write_text(page)


def text_files() -> None:
    (SITE / "robots.txt").write_text(f"User-agent: *\nAllow: /\n\nSitemap: {BASE}/sitemap.xml\n")
    guides = "".join(f"- [{pg['title']}]({pg['url']}): {pg['description']}\n" for pg in load_pages())
    personas = "\n".join(f"- [{e} {n}]({BASE}/p/{s}/): {roast}" for s, e, n, roast, *_ in PERSONAS)
    # llms.txt: a plain summary for AI assistants and answer engines (llmstxt.org).
    (SITE / "llms.txt").write_text(f"""# SomedayX

> SomedayX is a free, open-source Mac app that searches everything you've bookmarked or liked on X (Twitter) by meaning, from the menu bar. It runs 100% on your Mac: Google's EmbeddingGemma model (via llama.cpp) for search over text and images, and Apple Vision to read text in screenshots. No account, no server, no tracking.

## Key facts
- Platform: macOS 14 or newer; Apple silicon recommended; 8 GB RAM; about 1.5 GB of disk.
- Price: free; MIT licensed; source at https://github.com/priyank-saarthios-ai/somedayx
- Open it from anywhere by double-tapping the Option key (or ⌥⌘X).
- Finds posts by meaning ("that thread about pricing"), inside images ("screenshot of a dashboard") and in full X Articles.
- Filters: from:handle, is:bookmark, is:like, has:image, has:video, has:link, has:article, year:2025, since:, until:.
- How it gets your saves: it opens its own browser window where you log in to X once, then reads your Bookmarks and Likes read-only, the way the X website loads them. Unofficial; not affiliated with X Corp.
- SomedayX Wrapped: a shareable card that roasts your saving habits and gives you a persona.
- MCP server for AI apps (Claude Desktop, Claude Code, the ChatGPT desktop app for Mac, Codex CLI/IDE, Cursor; not chatgpt.com in a browser or the ChatGPT phone apps): read-only tools search_saves, recent_saves, get_post, library_overview. Off by default; turn on in the menu bar under AI Apps (MCP). Guide: {BASE}/guides/mcp/
- Made by Priyank Mehta (https://x.com/priyankmmehta).

## Pages
- [Home]({BASE}/): what it is, install, FAQ
{guides}- [Source code and install guide](https://github.com/priyank-saarthios-ai/somedayx)

## Wrapped personas
{personas}
""")


def main() -> None:
    (SITE / "media").mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        page = browser.new_page(viewport={"width": OG_W, "height": OG_H})
        render(page, home_card(), SITE / "img" / "og.png")
        for slug, emoji, name, roast, c1, c2 in PERSONAS:
            render(page, persona_card(emoji, name, roast, c1, c2), SITE / "img" / "og" / f"{slug}.png")
            out = SITE / "p" / slug / "index.html"
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(share_page(slug, emoji, name, roast, c1, c2))
        for pg in load_pages():
            render(page, article_card(pg["kicker"], pg["card"]), SITE / "img" / "og" / f"{pg['name']}.png")
            out = SITE / pg["path"] / "index.html"
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(article_page(pg))
        icons(page)
        if "--no-video" not in sys.argv:
            record_demo(browser)
        browser.close()
    sitemap()
    structured_data()
    text_files()
    print("Built: og images, persona pages, guides, icons, sitemap" + ("" if "--no-video" in sys.argv else ", demo video"))


if __name__ == "__main__":
    main()
