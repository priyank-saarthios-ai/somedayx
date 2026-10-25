"""Collect new bookmarks and likes by driving your installed Chrome with
Playwright and capturing the GraphQL responses X's web app loads while
scrolling. Read-only: it never clicks anything on a post.

The browser profile lives in data/browser-profile, so you log in once and
later runs reuse the session.

X Articles in your saves only come with a title and opening paragraph;
each sync also opens a few of them to read the full text.

The first sync of each list is a backfill: it scrolls to the very end and
saves older posts as it goes, so an interrupted run picks up where it left
off. After that, syncs stop once they reach posts already saved.
"""

import html
import json
import os
import random
import re
import sqlite3
import time
from collections.abc import Callable
from datetime import datetime
from pathlib import Path

from .db import DATA

PROFILE = DATA / "browser-profile"
CAPTURE_DIR = DATA / "raw" / "graphql"
BACKFILL = DATA / "logs" / "backfill.json"
ACCOUNT = DATA / "logs" / "account.json"
FLUSH_EVERY = 100
TIMELINE_RE = re.compile(r"/i/api/graphql/[^/]+/(Bookmarks|Likes)\b")
POST_RE = re.compile(r"/i/api/graphql/[^/]+/(TweetResultByRestId|TweetDetail)\b")
ARTICLES_PER_SYNC = 40
# How long a first, full-history sync may scroll (raise for huge histories,
# lower to try things out).
BACKFILL_MINUTES = float(os.environ.get("SOMEDAYX_BACKFILL_MINUTES", 90))
LOGIN_TIMEOUT_MS = 10 * 60 * 1000


class LoginRequired(RuntimeError):
    pass


# ---------- GraphQL -> record (same shape as the twitter-web-exporter JSON) ----------

def _unwrap(result: dict | None) -> dict | None:
    if result and result.get("__typename") == "TweetWithVisibilityResults":
        return result.get("post")
    return result


def tweet_results(obj) -> list[dict]:
    """All timeline posts in a GraphQL response, in display order."""
    found: list[dict] = []

    def walk(o):
        if isinstance(o, dict):
            if "tweet_results" in o:
                r = _unwrap((o["tweet_results"] or {}).get("result"))
                if r:
                    found.append(r)
                return  # don't descend into quoted posts
            for v in o.values():
                walk(v)
        elif isinstance(o, list):
            for v in o:
                walk(v)

    walk(obj)
    return found


def to_record(res: dict) -> dict | None:
    if res.get("__typename") != "Tweet" or "legacy" not in res:
        return None  # deleted / withheld post
    legacy = res["legacy"]
    user = (res.get("core") or {}).get("user_results", {}).get("result") or {}
    ucore, ulegacy = user.get("core") or {}, user.get("legacy") or {}
    screen_name = ucore.get("screen_name") or ulegacy.get("screen_name")
    note = (res.get("note_tweet") or {}).get("note_tweet_results", {}).get("result") or {}

    media = []
    for m in (legacy.get("extended_entities") or {}).get("media") or []:
        base = m.get("media_url_https")
        if m.get("type") == "photo":
            original = f"{base}?name=orig"
        else:
            variants = [v for v in (m.get("video_info") or {}).get("variants") or [] if v.get("content_type") == "video/mp4"]
            original = max(variants, key=lambda v: v.get("bitrate", 0))["url"] if variants else base
        media.append({"type": m.get("type"), "url": m.get("url"), "thumbnail": f"{base}?name=thumb", "original": original})

    created = datetime.strptime(legacy["created_at"], "%a %b %d %H:%M:%S %z %Y")
    return {
        "id": res["rest_id"],
        "created_at": created.strftime("%Y-%m-%d %H:%M:%S %z"),
        "full_text": html.unescape(note.get("text") or legacy.get("full_text") or ""),
        "media": media,
        "screen_name": screen_name,
        "name": ucore.get("name") or ulegacy.get("name"),
        "profile_image_url": (user.get("avatar") or {}).get("image_url") or ulegacy.get("profile_image_url_https"),
        "user_id": legacy.get("user_id_str"),
        "in_reply_to": legacy.get("in_reply_to_status_id_str"),
        "quoted_status": legacy.get("quoted_status_id_str"),
        "favorite_count": legacy.get("favorite_count"),
        "retweet_count": legacy.get("retweet_count"),  # exporter-format key
        "bookmark_count": legacy.get("bookmark_count"),
        "quote_count": legacy.get("quote_count"),
        "reply_count": legacy.get("reply_count"),
        "views_count": int((res.get("views") or {}).get("count") or 0) or None,
        "url": f"https://x.com/{screen_name}/status/{res['rest_id']}",
        "metadata": res,
    }


# ---------- browser ----------

def _logged_in_handle(page, interactive: bool, progress: Callable) -> str:
    page.goto("https://x.com/home", wait_until="domcontentloaded")
    profile_link = '[data-testid="AppTabBar_Profile_Link"]'
    try:
        page.wait_for_selector(profile_link, timeout=15000)
    except Exception:
        if not interactive:
            raise LoginRequired("X session expired; run a sync with the browser visible to log in again")
        progress(phase="login")
        print("\n>>> Log in to X in the Chrome window that just opened. Waiting up to 10 minutes…\n", flush=True)
        page.wait_for_selector(profile_link, timeout=LOGIN_TIMEOUT_MS)
    return page.get_attribute(profile_link, "href").strip("/")


def _scroll_timeline(page, url: str, known: set[str], stop_after: int, max_minutes: float,
                     backfill: bool, save_older: Callable[[list[dict]], None],
                     progress: Callable) -> tuple[list[dict], list[dict], bool]:
    """Scroll one timeline until `stop_after` consecutive known posts (unless
    backfilling), the end of the list, or the time limit.

    Posts newer than everything saved are returned (newest first). Posts
    found below already-saved ones are older and go to `save_older` in
    batches as they arrive. Returns (newer records, raw responses, reached end)."""
    pending, raw = [], []
    older: list[dict] = []
    below_known = not known  # with nothing saved yet, everything is "older"
    avatars: list[str] = []

    def on_response(resp):
        if TIMELINE_RE.search(resp.url):
            pending.append(resp)

    page.on("response", on_response)
    try:
        page.goto(url, wait_until="domcontentloaded")
        seen: set[str] = set()
        new: list[dict] = []
        found = 0
        known_streak = idle = 0
        reached_end = False
        deadline = time.time() + max_minutes * 60
        while time.time() < deadline:
            page.wait_for_timeout(random.randint(1400, 2600))
            got = False
            while pending:
                resp = pending.pop(0)
                if resp.status == 429:
                    print("  rate limited by X; pausing 90s", flush=True)
                    progress(paused=True)
                    page.wait_for_timeout(90_000)
                    progress(paused=False)
                    continue
                try:
                    data = resp.json()
                except Exception:
                    continue
                raw.append(data)
                for res in tweet_results(data):
                    rec = to_record(res)
                    if not rec or rec["id"] in seen:
                        continue
                    got = True
                    seen.add(rec["id"])
                    if rec["id"] in known:
                        known_streak += 1
                        below_known = True
                        continue
                    known_streak = 0
                    found += 1
                    (older if below_known else new).append(rec)
                    if rec.get("profile_image_url"):
                        avatars = (avatars + [rec["profile_image_url"]])[-12:]
            if len(older) >= FLUSH_EVERY:
                batch, older = older, []
                save_older(batch)
            progress(seen=len(seen), new=found, avatars=avatars)
            if known_streak >= stop_after and not backfill:
                print(f"  caught up ({known_streak} already-saved posts in a row)", flush=True)
                break
            idle = 0 if got else idle + 1
            if idle >= 8:
                print("  reached the end of the list", flush=True)
                reached_end = True
                break
            page.mouse.wheel(0, random.randint(1800, 3200))
            print(f"\r  seen {len(seen)}, new {found}", end="", flush=True)
        else:
            print("\n  stopped at the time limit", flush=True)
        print(f"\r  seen {len(seen)}, new {found}      ", flush=True)
        return new, raw, reached_end
    finally:
        if older:  # also when the scroll fails midway: keep what was collected
            save_older(older)
        try:
            page.remove_listener("response", on_response)
        except Exception:
            pass


# ---------- X Articles ----------

def _find_article(obj, article_id: str | None) -> dict | None:
    """The article (with its content_state) inside a post's GraphQL response."""
    if isinstance(obj, dict):
        if "content_state" in obj and (not article_id or obj.get("rest_id") == article_id):
            return obj
        for v in obj.values():
            if (found := _find_article(v, article_id)) is not None:
                return found
    elif isinstance(obj, list):
        for v in obj:
            if (found := _find_article(v, article_id)) is not None:
                return found
    return None


def article_text(article: dict) -> str:
    """Plain text of an article body (Draft.js blocks): paragraphs, headings
    and list items; images and embeds are skipped."""
    lines = []
    for block in (article.get("content_state") or {}).get("blocks") or []:
        text = (block.get("text") or "").strip()
        if not text or block.get("type") == "atomic":
            continue
        lines.append(("- " if "list-item" in (block.get("type") or "") else "") + text)
    return "\n".join(lines)


def fetch_article_bodies(conn: sqlite3.Connection, page, limit: int = ARTICLES_PER_SYNC,
                         progress: Callable = lambda **kw: None) -> int:
    """Open saved posts that are X Articles and keep their full text."""
    from .db import rebuild_fts

    rows = conn.execute(
        """SELECT a.post_id, a.article_id, coalesce(a.url, p.url) FROM articles a JOIN posts p ON p.id = a.post_id
            WHERE a.body IS NULL ORDER BY a.post_id DESC LIMIT ?""", (limit,)).fetchall()
    if not rows:
        return 0
    captured: list = []

    def on_response(resp):
        if POST_RE.search(resp.url):
            captured.append(resp)

    print(f"Reading {len(rows)} X Articles…", flush=True)
    page.on("response", on_response)
    vec = conn.execute("SELECT 1 FROM sqlite_master WHERE name = 'posts_vec'").fetchone()
    done = 0
    try:
        for n, (post_id, article_id, url) in enumerate(rows, 1):
            progress(phase="articles", done=n - 1, total=len(rows))
            captured.clear()
            page.goto(url, wait_until="domcontentloaded")
            article = None
            for _ in range(20):  # up to ~10s for the post's data to load
                page.wait_for_timeout(500)
                for resp in list(captured):
                    if resp.status == 429:
                        print("  X is rate limiting; the rest wait for the next sync", flush=True)
                        return done
                    try:
                        article = _find_article(resp.json(), article_id)
                    except Exception:
                        continue
                    if article:
                        break
                if article:
                    break
            body = article_text(article) if article else ""  # '' = gone or protected; don't retry
            with conn:
                conn.execute(
                    """UPDATE articles SET body = ?, fetched_at = datetime('now'),
                           title = coalesce(?, title), preview = coalesce(?, preview) WHERE post_id = ?""",
                    (body, (article or {}).get("title"), (article or {}).get("preview_text"), post_id))
                if vec and body:  # re-index with the full text
                    conn.execute("DELETE FROM posts_vec WHERE post_id = ?", (post_id,))
            done += bool(body)
            page.wait_for_timeout(random.randint(1200, 2600))
    finally:
        page.remove_listener("response", on_response)
        with conn:
            rebuild_fts(conn)
    print(f"  read {done} of {len(rows)}", flush=True)
    return done


def _launch(p, headless: bool):
    options = dict(
        headless=headless,
        viewport={"width": 1100, "height": 1000},
        args=[
            "--disable-blink-features=AutomationControlled",
            # Keep loading while the window is covered or in the background.
            "--disable-backgrounding-occluded-windows",
            "--disable-renderer-backgrounding",
            "--disable-background-timer-throttling",
        ],
    )
    try:
        return p.chromium.launch_persistent_context(str(PROFILE), channel="chrome", **options)
    except Exception:
        # No Google Chrome installed: use Playwright's own Chromium.
        return p.chromium.launch_persistent_context(str(PROFILE), **options)


def collect_articles(conn: sqlite3.Connection, headless: bool = True, limit: int = 500) -> int:
    """Read X Articles without a full sync (python -m somedayx articles)."""
    from playwright.sync_api import sync_playwright

    from .importer import backfill_articles

    backfill_articles(conn)
    with sync_playwright() as p:
        ctx = _launch(p, headless)
        try:
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            _logged_in_handle(page, interactive=not headless, progress=lambda **kw: None)
            return fetch_article_bodies(conn, page, limit)
        finally:
            ctx.close()


def _backfill_state() -> dict[str, bool]:
    try:
        return json.loads(BACKFILL.read_text())
    except (OSError, ValueError):
        return {}


def collect(conn: sqlite3.Connection, stop_after: int = 50, max_minutes: float = 20,
            headless: bool = False, save_older: Callable[[str, list[dict]], None] = lambda k, r: None,
            progress: Callable = lambda **kw: None) -> dict[str, list[dict]]:
    """headless=True is for unattended runs: no window, and no waiting for a
    login (raises LoginRequired instead). Returns the posts newer than
    anything saved, per kind; older ones (backfill) go to save_older."""
    from playwright.sync_api import sync_playwright

    PROFILE.mkdir(parents=True, exist_ok=True)
    CAPTURE_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out: dict[str, list[dict]] = {}
    with sync_playwright() as p:
        # Collecting always runs without a window. A window opens only when
        # X needs you to log in, and closes by itself once you have.
        ctx = _launch(p, headless=True)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        try:
            handle = _logged_in_handle(page, interactive=False, progress=progress)
        except LoginRequired:
            ctx.close()
            if headless:
                raise
            login = _launch(p, headless=False)
            try:
                _logged_in_handle(login.pages[0] if login.pages else login.new_page(), interactive=True, progress=progress)
            finally:
                login.close()  # saves the session to the profile
            ctx = _launch(p, headless=True)
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            handle = _logged_in_handle(page, interactive=False, progress=progress)
        try:
            print(f"Logged in as @{handle}", flush=True)
            ACCOUNT.write_text(json.dumps({"handle": handle}))
            state = _backfill_state()
            for kind, url in (("bookmark", "https://x.com/i/bookmarks"), ("like", f"https://x.com/{handle}/likes")):
                known = {r[0] for r in conn.execute(f"SELECT id FROM posts WHERE is_{kind}")}
                # Lists imported before this file existed were complete exports.
                backfill = not state.get(kind, bool(known))
                if backfill:  # remember it's unfinished, so an interrupted run resumes
                    state[kind] = False
                    BACKFILL.write_text(json.dumps(state))
                print(f"Collecting {kind}s ({len(known)} already saved{', full history' if backfill else ''})…", flush=True)
                progress(phase=kind, seen=0, new=0, avatars=[], handle=handle)
                new, raw, reached_end = _scroll_timeline(
                    page, url, known, stop_after, BACKFILL_MINUTES if backfill else max_minutes, backfill,
                    lambda recs, kind=kind: save_older(kind, recs), progress)
                if new:  # keep raw responses only when they hold something new
                    (CAPTURE_DIR / f"{kind}s-{stamp}.json").write_text(json.dumps(raw))
                out[kind] = new
                if backfill and reached_end:
                    state[kind] = True
                    BACKFILL.write_text(json.dumps(state))
            # New saves aren't imported yet, so their articles come next sync.
            from .importer import backfill_articles

            backfill_articles(conn)
            fetch_article_bodies(conn, page, progress=progress)
        finally:
            ctx.close()
    return out
