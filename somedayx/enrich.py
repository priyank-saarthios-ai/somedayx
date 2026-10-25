"""Fetching what a saved post points to: resolve t.co links, fetch page
titles, fetch missing quoted posts and download images. No models involved.

Every step only processes what's missing, so each can be re-run safely.
"""

import html
import json
import re
import sqlite3
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .db import DATA, rebuild_fts

MEDIA_DIR = DATA / "media"

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0 Safari/537.36"
TIMEOUT = 15
WORKERS = 16


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


_no_redirect = urllib.request.build_opener(_NoRedirect)


def _request(url: str) -> urllib.request.Request:
    return urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en"})


# ---------- links ----------

def _resolve_tco(tco: str) -> str | None:
    # t.co answers browser user-agents with a JS/meta-refresh page; anything
    # else gets a plain 301 with the target in Location.
    try:
        resp = _no_redirect.open(urllib.request.Request(tco, headers={"User-Agent": "somedayx/1.0"}), timeout=TIMEOUT)
        return resp.headers.get("Location")
    except urllib.error.HTTPError as e:
        return e.headers.get("Location")
    except Exception:
        return None


def _meta(page: str, *names: str) -> str | None:
    for name in names:
        for pattern in (
            rf'<meta[^>]+(?:property|name)=["\']{name}["\'][^>]+content=["\']([^"\']*)["\']',
            rf'<meta[^>]+content=["\']([^"\']*)["\'][^>]+(?:property|name)=["\']{name}["\']',
        ):
            m = re.search(pattern, page, re.I)
            if m and m.group(1).strip():
                return html.unescape(m.group(1).strip())
    return None


def _page_meta(url: str) -> dict:
    out = {"url": url, "final_url": None, "title": None, "description": None, "error": None}
    if re.match(r"https?://(www\.)?(x|twitter)\.com/", url):
        out["error"] = "skipped: x.com link"
        return out
    try:
        with urllib.request.urlopen(_request(url), timeout=TIMEOUT) as resp:
            out["final_url"] = resp.geturl()
            if "html" not in (resp.headers.get("Content-Type") or ""):
                out["error"] = f"non-html: {resp.headers.get('Content-Type')}"
                return out
            page = resp.read(400_000).decode(resp.headers.get_content_charset() or "utf-8", "replace")
    except Exception as e:
        out["error"] = f"{type(e).__name__}: {e}"[:300]
        return out
    title = _meta(page, "og:title", "twitter:title")
    if not title:
        m = re.search(r"<title[^>]*>(.*?)</title>", page, re.I | re.S)
        title = html.unescape(m.group(1)).strip() if m else None
    out["title"] = re.sub(r"\s+", " ", title)[:300] if title else None
    desc = _meta(page, "og:description", "description", "twitter:description")
    out["description"] = re.sub(r"\s+", " ", desc)[:600] if desc else None
    return out


def fetch_links(conn: sqlite3.Connection) -> None:
    pending = [r[0] for r in conn.execute("SELECT DISTINCT tco_url FROM links WHERE expanded_url IS NULL")]
    print(f"Resolving {len(pending)} t.co links…")
    with ThreadPoolExecutor(WORKERS) as pool:
        for tco, target in zip(pending, pool.map(_resolve_tco, pending)):
            if target:
                conn.execute("UPDATE links SET expanded_url = ? WHERE tco_url = ?", (target, tco))
    conn.commit()

    urls = [r[0] for r in conn.execute(
        "SELECT DISTINCT expanded_url FROM links WHERE expanded_url IS NOT NULL "
        "AND expanded_url NOT IN (SELECT url FROM link_meta)")]
    print(f"Fetching page titles for {len(urls)} links…")
    with ThreadPoolExecutor(WORKERS) as pool:
        for meta in pool.map(_page_meta, urls):
            conn.execute(
                "INSERT OR REPLACE INTO link_meta (url, final_url, title, description, error) "
                "VALUES (:url, :final_url, :title, :description, :error)", meta)
    conn.commit()


# ---------- quoted posts ----------

def _syndication(post_id: str) -> dict | None:
    url = f"https://cdn.syndication.twimg.com/post-result?id={post_id}&token=a"
    try:
        with urllib.request.urlopen(_request(url), timeout=TIMEOUT) as resp:
            data = json.load(resp)
    except Exception:
        return None
    if data.get("__typename") == "TweetTombstone" or "text" not in data:
        return None
    note = (data.get("note_tweet") or {}).get("note_tweet_results", {}).get("result") or {}
    user = data.get("user") or {}
    return {
        "id": post_id,
        "screen_name": user.get("screen_name"),
        "name": user.get("name"),
        "created_at": data.get("created_at"),
        "full_text": note.get("text") or data.get("text"),
    }


def fetch_quotes(conn: sqlite3.Connection) -> None:
    ids = [r[0] for r in conn.execute(
        "SELECT DISTINCT quoted_id FROM posts WHERE quoted_id IS NOT NULL "
        "AND quoted_id NOT IN (SELECT id FROM quoted_posts)")]
    print(f"Fetching {len(ids)} quoted posts…")
    found = 0
    with ThreadPoolExecutor(8) as pool:
        for q in pool.map(_syndication, ids):
            if q:
                found += 1
                conn.execute(
                    "INSERT OR REPLACE INTO quoted_posts (id, screen_name, name, created_at, full_text) "
                    "VALUES (:id, :screen_name, :name, :created_at, :full_text)", q)
    conn.commit()
    print(f"  got {found}; the rest are deleted or protected")


# ---------- images ----------

def _small_image_url(row: sqlite3.Row) -> str | None:
    # Photos: the full image. Videos/GIFs: their poster frame. 680px is
    # enough to read screenshot text and keeps vision tokens down.
    src = row["original"] if row["type"] == "photo" else row["thumbnail"]
    if not src:
        return None
    src = re.sub(r"([?&]name=)\w+", r"\1small", src)
    return src if "name=" in src else src + ("&" if "?" in src else "?") + "name=small"


def _download(job: tuple[str, Path]) -> Path | None:
    url, dest = job
    try:
        with urllib.request.urlopen(_request(url), timeout=TIMEOUT) as resp:
            ext = {"image/png": ".png", "image/webp": ".webp"}.get(resp.headers.get_content_type(), ".jpg")
            path = dest.with_suffix(ext)
            path.write_bytes(resp.read())
            return path
    except Exception:
        return None


def fetch_images(conn: sqlite3.Connection) -> None:
    MEDIA_DIR.mkdir(parents=True, exist_ok=True)
    rows = conn.execute(
        "SELECT m.* FROM media m JOIN posts t ON t.id = m.post_id "
        "WHERE m.local_path IS NULL OR m.local_path = ''").fetchall()
    jobs = [(row, (_small_image_url(row), MEDIA_DIR / f"{row['post_id']}_{row['idx']}")) for row in rows]
    jobs = [(row, job) for row, job in jobs if job[0]]
    print(f"Downloading {len(jobs)} images…")
    ok = 0
    with ThreadPoolExecutor(WORKERS) as pool:
        for (row, _), path in zip(jobs, pool.map(_download, [j for _, j in jobs])):
            if path:
                ok += 1
                conn.execute("UPDATE media SET local_path = ? WHERE post_id = ? AND idx = ?",
                             (str(path.relative_to(DATA)), row["post_id"], row["idx"]))
    conn.commit()
    print(f"  downloaded {ok}, failed {len(jobs) - ok}")


def fetch_all(conn: sqlite3.Connection) -> None:
    from .importer import backfill_articles

    fetch_links(conn)
    backfill_articles(conn)  # needs resolved links
    fetch_quotes(conn)
    fetch_images(conn)
    with conn:
        rebuild_fts(conn)
