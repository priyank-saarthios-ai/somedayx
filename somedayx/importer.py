"""Import twitter-web-exporter JSON files from raw/ (in the data folder) into SQLite.

Re-running is safe: posts are upserted by id, and a post that appears in
both a bookmarks and a likes export keeps both flags.
"""

import json
import re
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from .db import DATA, rebuild_fts

RAW_DIR = DATA / "raw"
TCO_RE = re.compile(r"https://t\.co/\w+")


def _iso_utc(value: str | None, fmt: str) -> str | None:
    if not value:
        return None
    return datetime.strptime(value, fmt).astimezone(timezone.utc).isoformat()


def _kind_of(path: Path) -> str:
    name = path.name.lower()
    if "bookmark" in name:
        return "bookmark"
    if "like" in name:
        return "like"
    raise ValueError(f"Can't tell if {path.name} holds bookmarks or likes; rename it to include one of those words")


def _unwrap(result: dict | None) -> dict | None:
    # Some GraphQL results are wrapped in TweetWithVisibilityResults.
    if result and result.get("__typename") == "TweetWithVisibilityResults":
        return result.get("post")
    return result


def _metadata_links(meta: dict) -> list[dict]:
    urls = list((meta.get("legacy") or {}).get("entities", {}).get("urls") or [])
    note = (meta.get("note_tweet") or {}).get("note_tweet_results", {}).get("result") or {}
    urls += note.get("entity_set", {}).get("urls") or []
    return urls


def _quoted_from_metadata(meta: dict) -> dict | None:
    q = _unwrap((meta.get("quoted_status_result") or {}).get("result"))
    if not q or "legacy" not in q:
        return None
    legacy = q["legacy"]
    user = (q.get("core") or {}).get("user_results", {}).get("result") or {}
    ucore = user.get("core") or user.get("legacy") or {}
    note = (q.get("note_tweet") or {}).get("note_tweet_results", {}).get("result") or {}
    return {
        "id": q.get("rest_id") or legacy.get("id_str"),
        "screen_name": ucore.get("screen_name"),
        "name": ucore.get("name"),
        "created_at": _iso_utc(legacy.get("created_at"), "%a %b %d %H:%M:%S %z %Y"),
        "full_text": note.get("text") or legacy.get("full_text"),
    }


ARTICLE_RE = re.compile(r"x\.com/(?:i|\w+)/article/(\d+)")


def _article_from_metadata(meta: dict) -> dict | None:
    """Title and opening of an X Article the post is, or quotes (the
    timeline doesn't include the body)."""
    url = None
    art = ((meta.get("article") or {}).get("article_results") or {}).get("result")
    if not art:
        quoted = _unwrap((meta.get("quoted_status_result") or {}).get("result")) or {}
        art = ((quoted.get("article") or {}).get("article_results") or {}).get("result")
        url = f"https://x.com/i/status/{quoted.get('rest_id')}" if art else None
    if not art:
        return None
    return {"article_id": art.get("rest_id"), "title": art.get("title"), "preview": art.get("preview_text"), "url": url}


def save_article(conn: sqlite3.Connection, post_id: str, article_id: str | None,
                 title: str | None = None, preview: str | None = None, url: str | None = None) -> None:
    conn.execute(
        """INSERT INTO articles (post_id, article_id, title, preview, url) VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(post_id) DO UPDATE SET
               article_id = coalesce(excluded.article_id, articles.article_id),
               title = coalesce(excluded.title, articles.title),
               preview = coalesce(excluded.preview, articles.preview),
               url = coalesce(excluded.url, articles.url)""",
        (post_id, article_id, title, preview, url))


def backfill_articles(conn: sqlite3.Connection) -> int:
    """Find X Articles among saved posts: from stored timeline data, or a
    link to one. Cheap; safe to run every sync."""
    before = conn.execute("SELECT count(*) FROM articles").fetchone()[0]
    with conn:
        for pid, raw in conn.execute(
                "SELECT id, raw FROM posts WHERE raw LIKE '%article_results%' "
                "AND id NOT IN (SELECT post_id FROM articles WHERE title IS NOT NULL)").fetchall():
            art = _article_from_metadata(json.loads(raw).get("metadata") or {})
            if art:
                save_article(conn, pid, **art)
        for pid, url in conn.execute(
                "SELECT post_id, expanded_url FROM links WHERE expanded_url LIKE '%/article/%' "
                "AND post_id NOT IN (SELECT post_id FROM articles)").fetchall():
            m = ARTICLE_RE.search(url)
            if m:
                save_article(conn, pid, m.group(1))
    return conn.execute("SELECT count(*) FROM articles").fetchone()[0] - before


def _upsert_post(conn: sqlite3.Connection, rec: dict, kind: str, rank: int) -> None:
    meta = rec.get("metadata") or {}
    row = {
        "id": rec["id"],
        "url": f"https://x.com/{rec['screen_name']}/status/{rec['id']}",
        "screen_name": rec.get("screen_name"),
        "name": rec.get("name"),
        "user_id": rec.get("user_id"),
        "profile_image": rec.get("profile_image_url"),
        "created_at": _iso_utc(rec.get("created_at"), "%Y-%m-%d %H:%M:%S %z"),
        "full_text": rec.get("full_text"),
        "lang": (meta.get("legacy") or {}).get("lang"),
        "in_reply_to": rec.get("in_reply_to"),
        "quoted_id": rec.get("quoted_status"),
        "favorite_count": rec.get("favorite_count"),
        "repost_count": rec.get("retweet_count"),
        "reply_count": rec.get("reply_count"),
        "quote_count": rec.get("quote_count"),
        "bookmark_count": rec.get("bookmark_count"),
        "views_count": rec.get("views_count"),
        "is_bookmark": int(kind == "bookmark"),
        "is_like": int(kind == "like"),
        "bookmark_rank": rank if kind == "bookmark" else None,
        "like_rank": rank if kind == "like" else None,
        "raw": json.dumps(rec, ensure_ascii=False),
    }
    cols = ", ".join(row)
    params = ", ".join(f":{k}" for k in row)
    # Refresh content and counts; OR the source flags so a post can be both.
    # Keep the richer raw record if a later export lacks metadata.
    conn.execute(
        f"""
        INSERT INTO posts ({cols}) VALUES ({params})
        ON CONFLICT(id) DO UPDATE SET
            screen_name = excluded.screen_name,
            name = excluded.name,
            profile_image = excluded.profile_image,
            full_text = excluded.full_text,
            lang = coalesce(excluded.lang, posts.lang),
            favorite_count = excluded.favorite_count,
            repost_count = excluded.repost_count,
            reply_count = excluded.reply_count,
            quote_count = excluded.quote_count,
            bookmark_count = excluded.bookmark_count,
            views_count = excluded.views_count,
            is_bookmark = max(posts.is_bookmark, excluded.is_bookmark),
            is_like = max(posts.is_like, excluded.is_like),
            bookmark_rank = coalesce(excluded.bookmark_rank, posts.bookmark_rank),
            like_rank = coalesce(excluded.like_rank, posts.like_rank),
            raw = CASE WHEN json_extract(excluded.raw, '$.metadata') IS NOT NULL
                       OR json_extract(posts.raw, '$.metadata') IS NULL
                       THEN excluded.raw ELSE posts.raw END
        """,
        row,
    )

    media_tcos = set()
    for idx, m in enumerate(rec.get("media") or []):
        media_tcos.add(m.get("url"))
        conn.execute(
            "INSERT OR REPLACE INTO media (post_id, idx, type, tco_url, thumbnail, original) VALUES (?, ?, ?, ?, ?, ?)",
            (rec["id"], idx, m.get("type"), m.get("url"), m.get("thumbnail"), m.get("original")),
        )

    # Links: expanded versions from metadata when present, otherwise the bare
    # t.co URLs from the text (resolved later during enrichment).
    for u in _metadata_links(meta):
        conn.execute(
            """INSERT INTO links (post_id, tco_url, expanded_url, display_url) VALUES (?, ?, ?, ?)
               ON CONFLICT(post_id, tco_url) DO UPDATE SET
                   expanded_url = excluded.expanded_url, display_url = excluded.display_url""",
            (rec["id"], u["url"], u.get("expanded_url"), u.get("display_url")),
        )
    for tco in set(TCO_RE.findall(rec.get("full_text") or "")) - media_tcos:
        conn.execute("INSERT OR IGNORE INTO links (post_id, tco_url) VALUES (?, ?)", (rec["id"], tco))

    art = _article_from_metadata(meta)
    if art:
        save_article(conn, rec["id"], **art)

    quoted = _quoted_from_metadata(meta)
    if quoted and quoted["id"]:
        conn.execute(
            """INSERT OR REPLACE INTO quoted_posts (id, screen_name, name, created_at, full_text)
               VALUES (:id, :screen_name, :name, :created_at, :full_text)""",
            quoted,
        )


def import_new(conn: sqlite3.Connection, kind: str, records: list[dict]) -> None:
    """Add newly collected saves (newest first) on top of the existing order."""
    if not records:
        return
    col = f"{kind}_rank"
    ids = [r["id"] for r in records]
    with conn:
        conn.execute(
            f"UPDATE posts SET {col} = {col} + ? WHERE {col} IS NOT NULL "
            f"AND id NOT IN ({','.join('?' * len(ids))})",
            [len(records), *ids],
        )
        for rank, rec in enumerate(records):
            _upsert_post(conn, rec, kind, rank)
        rebuild_fts(conn)


def import_older(conn: sqlite3.Connection, kind: str, records: list[dict]) -> None:
    """Add saves found below the already-saved ones (a backfill) at the end."""
    if not records:
        return
    col = f"{kind}_rank"
    start = conn.execute(f"SELECT coalesce(max({col}) + 1, 0) FROM posts").fetchone()[0]
    with conn:
        for rank, rec in enumerate(records, start):
            _upsert_post(conn, rec, kind, rank)
        rebuild_fts(conn)


def import_all(conn: sqlite3.Connection, raw_dir: Path = RAW_DIR) -> dict[str, int]:
    files = sorted(raw_dir.glob("*.json"))
    if not files:
        raise SystemExit(f"No JSON exports found in {raw_dir}")
    counts: dict[str, int] = {}
    with conn:
        for path in files:
            kind = _kind_of(path)
            records = json.loads(path.read_text())
            for rank, rec in enumerate(records):
                _upsert_post(conn, rec, kind, rank)
            counts[path.name] = len(records)
        rebuild_fts(conn)
    return counts
