"""SomedayX as an MCP server (stdio), so AI apps like Claude Desktop, Claude
Code and Cursor can search your saves.

    python -m somedayx mcp

Read-only by design: it opens the database read-only, never syncs, never
touches X, the browser session or the access token. It answers only while
"Let AI apps search my saves" is on (settings.json "mcp": true), because the
app you connect may send what it reads to its own cloud.
"""

import re
import sqlite3
from dataclasses import asdict
from typing import Literal

from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations

from . import llm, models
from .db import DB_PATH
from .search import Filters, browse, hydrate, parse_operators, query_vector, search

OFF = ("SomedayX isn't sharing saves with AI apps. To allow it, click the SomedayX icon in the menu bar → "
       "AI Apps (MCP) → Let AI Apps Search My Saves, then try again.")
TEXT_MAX = 700        # characters of post text per search result
IMAGE_TEXT_MAX = 300  # characters of text read from images per search result
ARTICLE_MAX = 20_000  # characters of an X Article in get_post
META_TAGS = {"thread", "reply", "link only", "video", "image", "meme", "humor", "tweet", "announcement", "quote"}

server = MCPServer(
    "SomedayX",
    instructions=(
        "Search the user's own saved X (Twitter) posts: everything they bookmarked or liked, stored on their Mac. "
        "Use search_saves for anything they half-remember (it matches by meaning, keywords and text inside "
        "images), recent_saves for what they saved lately, get_post for one post in full (including X Article "
        "text), and library_overview to understand the library. Always cite posts by their url."),
    website_url="https://somedayx.com",
    version="1.1.0",
)
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)

_conn: sqlite3.Connection | None = None


class Refused(Exception):
    pass


def _db() -> sqlite3.Connection:
    """Checked on every call, so turning the switch off takes effect at once."""
    global _conn
    if not models.settings().get("mcp"):
        raise Refused(OFF)
    if _conn is None:
        if not DB_PATH.exists():
            raise Refused("SomedayX has no saves yet. Open SomedayX and finish setup first.")
        _conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True, check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        import sqlite_vec

        _conn.enable_load_extension(True)
        sqlite_vec.load(_conn)
        _conn.enable_load_extension(False)
    return _conn


def _vector(text: str) -> bytes | None:
    """The query's meaning, starting the search model if nothing else has.
    It's left running for the app to share; it frees its memory when idle."""
    if not text.strip() or not models.ready("embed"):
        return None
    if not llm.embedder_alive():
        try:
            llm._embed.start()
        except llm.ModelUnavailable:
            return None
    return query_vector(text)


def _filters(query: str, source: str, author: str | None, since: str | None, until: str | None,
             has: str | None) -> tuple[str, Filters]:
    f = Filters(source=None if source == "both" else source, author=(author or "").lstrip("@") or None)
    ops = " ".join(f"{k}:{v}" for k, v in (("since", since), ("until", until), ("has", has)) if v)
    return parse_operators(f"{query} {ops}", f)


def _ocr(conn: sqlite3.Connection, pid: str) -> str:
    return "\n".join(r[0] for r in conn.execute(
        "SELECT ocr_text FROM media WHERE post_id = ? AND ocr_text != '' ORDER BY idx", (pid,)))


def _cut(text: str | None, n: int) -> str | None:
    if not text:
        return None
    return text if len(text) <= n else text[:n].rstrip() + "…"


def _brief(conn: sqlite3.Connection, r: dict, full: bool = False) -> dict:
    """A post as an AI app needs it: who, when, what, and where to open it."""
    out = {
        "id": r["id"], "url": r["url"],
        "author": f"{r['name']} (@{r['screen_name']})" if r.get("name") else f"@{r['screen_name']}",
        "posted": (r.get("created_at") or "")[:10] or None,
        "saved_as": " and ".join(k for k, on in (("bookmark", r["is_bookmark"]), ("like", r["is_like"])) if on),
        "text": r["full_text"] if full else _cut(r["full_text"], TEXT_MAX),
        "tldr": r.get("summary"),
        "text_in_images": (lambda t: t if full else _cut(t, IMAGE_TEXT_MAX))(_ocr(conn, r["id"])) or None,
        "quoted_post": f"@{r['q_author']}: {r['q_text']}" if r.get("q_text") else None,
        "article_title": r.get("article_title"),
        "likes": r.get("favorite_count"),
        "matched_by": r.get("matched_by"),
    }
    return {k: v for k, v in out.items() if v not in (None, "", [])}


def _call(fn):
    try:
        return fn()
    except Refused as e:
        return {"error": str(e)}


Source = Literal["both", "bookmark", "like"]
Has = Literal["image", "video", "link", "article"]


@server.tool(annotations=READ_ONLY)
def search_saves(query: str, source: Source = "both", author: str | None = None, since: str | None = None,
                 until: str | None = None, has: Has | None = None, limit: int = 10) -> dict:
    """Search the user's saved X posts (bookmarks and likes) by meaning and keywords, including text inside
    images and full X Articles. Describe what they remember in plain words ("that thread about pricing").
    X-style operators also work inside the query: from:handle, is:bookmark, is:like, has:image, has:video,
    has:link, has:article, year:2025, since:2025-03, until:2025-06. Dates are when the post was published.
    Returns up to `limit` posts (max 25), best first."""
    def run():
        conn = _db()
        text, f = _filters(query, source, author, since, until, has)
        vec = _vector(text)
        results = search(conn, text, f, limit=max(1, min(limit, 25)), vec=vec)
        return {
            "query": text, "filters": {k: v for k, v in asdict(f).items() if v},
            "search": "meaning + keywords" if vec or not text else "keywords only (search model not running)",
            "results": [_brief(conn, r) for r in results],
        }
    return _call(run)


@server.tool(annotations=READ_ONLY)
def recent_saves(source: Source = "both", author: str | None = None, since: str | None = None,
                 until: str | None = None, has: Has | None = None, limit: int = 15) -> dict:
    """The user's most recently saved X posts, newest first, optionally filtered (source, author,
    has:image/video/link/article, publish dates since/until as YYYY, YYYY-MM or YYYY-MM-DD). Max 50."""
    def run():
        conn = _db()
        _, f = _filters("", source, author, since, until, has)
        return {"results": [_brief(conn, r) for r in browse(conn, f, limit=max(1, min(limit, 50)))]}
    return _call(run)


@server.tool(annotations=READ_ONLY)
def get_post(post: str) -> dict:
    """One saved post in full, by its id or x.com/twitter.com URL: complete text, text read from its
    images, the post it quotes, the full text of an X Article, and the links it contains."""
    def run():
        conn = _db()
        m = re.search(r"status(?:es)?/(\d+)", post)
        pid = m.group(1) if m else post.strip()
        rows = hydrate(conn, [pid]) if conn.execute("SELECT 1 FROM posts WHERE id = ?", (pid,)).fetchone() else []
        if not rows:
            return {"error": f"No saved post with id {pid}. Only posts the user bookmarked or liked are here."}
        out = _brief(conn, rows[0], full=True)
        body = conn.execute("SELECT body FROM articles WHERE post_id = ?", (pid,)).fetchone()
        if body and body[0]:
            out["article_text"] = _cut(body[0], ARTICLE_MAX)
        links = [{k: v for k, v in dict(r).items() if v} for r in conn.execute(
            """SELECT coalesce(m.final_url, l.expanded_url, l.tco_url) AS url, m.title, m.description
                 FROM links l LEFT JOIN link_meta m ON m.url = l.expanded_url WHERE l.post_id = ?""", (pid,))]
        if links:
            out["links"] = links
        return out
    return _call(run)


@server.tool(annotations=READ_ONLY)
def library_overview() -> dict:
    """A summary of the user's saved X library: how many bookmarks and likes, the date range, the people
    they save most, and their most common topics. Useful before answering broad questions."""
    def run():
        conn = _db()
        one = lambda sql: conn.execute(sql).fetchone()[0]
        saved = "(is_bookmark OR is_like)"
        authors = conn.execute(
            f"""SELECT screen_name, max(name), count(*) FROM posts WHERE {saved}
                GROUP BY lower(screen_name) ORDER BY 3 DESC LIMIT 10""").fetchall()
        tags = conn.execute(
            f"""SELECT lower(j.value), count(*) FROM enrichment e JOIN posts p ON p.id = e.post_id, json_each(e.tags) j
                 WHERE (p.is_bookmark OR p.is_like) GROUP BY 1 ORDER BY 2 DESC LIMIT 25""").fetchall()
        return {
            "saved_posts": one(f"SELECT count(*) FROM posts WHERE {saved}"),
            "bookmarks": one("SELECT count(*) FROM posts WHERE is_bookmark"),
            "likes": one("SELECT count(*) FROM posts WHERE is_like"),
            "x_articles": one("SELECT count(*) FROM articles"),
            "oldest_post": (one(f"SELECT min(created_at) FROM posts WHERE {saved}") or "")[:10] or None,
            "newest_post": (one(f"SELECT max(created_at) FROM posts WHERE {saved}") or "")[:10] or None,
            "top_authors": [{"author": f"{n} (@{s})", "saved": c} for s, n, c in authors],
            "top_topics": [{"topic": t, "saved": c} for t, c in tags if t not in META_TAGS][:15],
        }
    return _call(run)


def main() -> None:
    server.run("stdio")
