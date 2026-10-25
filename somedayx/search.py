"""Hybrid search over saved X posts: BM25 keyword + embedding similarity,
merged with reciprocal rank fusion (RRF). Supports X-style operators
(from:, is:, has:, since:, until:, year:)."""

import calendar
import re
import sqlite3
from dataclasses import dataclass

from . import embed

RRF_K = 60
CANDIDATES = 150
# Meaning-only matches further than this from the best hit are noise
# ("design inspiration" -> a tennis quote); keyword matches always stay.
# Tuned for EmbeddingGemma 2: good matches sit around 0.20–0.30.
SEMANTIC_SLACK = 0.08
SEMANTIC_MAX = 0.33
# Image matches land on the same scale; a nudge lets text win ties.
IMAGE_PENALTY = 0.01

STOPWORDS = set("""
a about an and any are as at be by can did do does find for from had has have how i in into is it its
me my of on or post posts saved show some something that the their them there these this those to post
posts was were what when where which who why with about anything everything like liked bookmarked
""".split())


@dataclass
class Filters:
    source: str | None = None   # "bookmark" | "like" | None
    author: str | None = None   # screen name, with or without @
    since: str | None = None    # YYYY-MM-DD, when the post was published
    until: str | None = None
    media: str | None = None    # "image" | "video" | "link" | None


OPERATOR_RE = re.compile(r"(?<!\S)(from|is|has|since|until|year):(\S+)", re.I)


def _date_bound(v: str, start: bool) -> str:
    """'2025' / '2025-03' / '2025-03-14' -> first or last day of that span."""
    parts = [int(x) for x in v.split("-")]
    if len(parts) == 3:
        return v
    year, month = parts[0], (parts[1] if len(parts) == 2 else (1 if start else 12))
    day = 1 if start else calendar.monthrange(year, month)[1]
    return f"{year:04d}-{month:02d}-{day:02d}"


def parse_operators(text: str, f: Filters | None = None) -> tuple[str, Filters]:
    """Pull X-style operators out of a query. Operators already set on `f`
    (e.g. from UI tabs) are kept unless the query names them explicitly."""
    f = f or Filters()
    for key, value in OPERATOR_RE.findall(text):
        key, v = key.lower(), value.lower()
        if key == "from":
            f.author = value.lstrip("@")
        elif key == "is" and v in ("bookmark", "bookmarks", "bookmarked"):
            f.source = "bookmark"
        elif key == "is" and v in ("like", "likes", "liked"):
            f.source = "like"
        elif key == "has" and v in ("image", "images", "photo", "photos", "media"):
            f.media = "image"
        elif key == "has" and v in ("video", "videos", "gif"):
            f.media = "video"
        elif key == "has" and v in ("link", "links"):
            f.media = "link"
        elif key in ("has", "is") and v in ("article", "articles"):
            f.media = "article"
        elif key in ("since", "until") and re.fullmatch(r"\d{4}(-\d{2}){0,2}", v):
            setattr(f, key, _date_bound(v, start=key == "since"))
        elif key == "year" and re.fullmatch(r"\d{4}", v):
            f.since, f.until = f"{v}-01-01", f"{v}-12-31"
    return OPERATOR_RE.sub(" ", text).strip(), f


def _where(f: Filters) -> tuple[str, list]:
    clauses, params = [], []
    if f.source == "bookmark":
        clauses.append("t.is_bookmark")
    elif f.source == "like":
        clauses.append("t.is_like")
    if f.author:
        # Exact handle, or a partial match on handle / display name.
        a = f.author.lstrip("@").lower()
        clauses.append("(lower(t.screen_name) = ? OR lower(t.screen_name) LIKE ? OR lower(t.name) LIKE ?)")
        params += [a, f"%{a}%", f"%{a}%"]
    if f.media == "image":
        clauses.append("EXISTS (SELECT 1 FROM media m WHERE m.post_id = t.id AND m.type = 'photo')")
    elif f.media == "video":
        clauses.append("EXISTS (SELECT 1 FROM media m WHERE m.post_id = t.id AND m.type IN ('video', 'animated_gif'))")
    elif f.media == "article":
        clauses.append("EXISTS (SELECT 1 FROM articles a WHERE a.post_id = t.id)")
    elif f.media == "link":
        clauses.append("EXISTS (SELECT 1 FROM links l WHERE l.post_id = t.id "
                       "AND coalesce(l.expanded_url, '') NOT LIKE 'https://x.com/%' "
                       "AND coalesce(l.expanded_url, '') NOT LIKE 'https://twitter.com/%')")
    if f.since:
        clauses.append("t.created_at >= ?")
        params.append(f.since)
    if f.until:
        clauses.append("t.created_at < date(?, '+1 day')")
        params.append(f.until)
    return (" AND " + " AND ".join(clauses)) if clauses else "", params


def query_terms(text: str) -> list[str]:
    """The words a query actually searches for (what the UI highlights)."""
    return [w for w in re.findall(r"[\w@#.+-]+", text.lower()) if w not in STOPWORDS and len(w) > 1]


def _fts_query(text: str) -> str | None:
    words = query_terms(text)
    if not words:
        return None
    # OR so natural-language queries still match partially; BM25 ranks
    # posts matching more (and rarer) words higher.
    return " OR ".join('"' + w.replace('"', '""') + '"' for w in words)


def keyword_ids(conn: sqlite3.Connection, text: str, f: Filters) -> list[str]:
    q = _fts_query(text)
    if not q:
        return []
    where, params = _where(f)
    rows = conn.execute(
        f"""SELECT t.id FROM posts_fts JOIN posts t ON t.id = posts_fts.id
             WHERE posts_fts MATCH ? {where}
             ORDER BY bm25(posts_fts, 0, 1.0, 2.0, 0.5, 0.5, 1.0, 1.0, 0.7, 1.0)
             LIMIT {CANDIDATES}""",
        [q, *params],
    ).fetchall()
    return [r[0] for r in rows]


def query_vector(text: str) -> bytes | None:
    """The query's search vector, or None when the model isn't running.
    Computed before taking any database lock: the model may be busy."""
    if not text.strip():
        return None
    try:
        return embed.query_vector(text)
    except Exception:
        return None  # not running (yet): words only


def semantic_ids(conn: sqlite3.Connection, vec: bytes, f: Filters) -> list[tuple[str, float, bool]]:
    """(id, cosine distance, matched by an image) of the closest posts,
    nearest first, comparing the query with post text and with images."""
    where, params = _where(f)
    # Over-fetch from the vector indexes, then apply filters.
    rows = conn.execute(
        f"""WITH hits AS (
                SELECT post_id, distance, 0 AS image FROM posts_vec
                 WHERE embedding MATCH ? AND k = {CANDIDATES * 4}
                UNION ALL
                SELECT substr(media_key, 1, instr(media_key, ':') - 1), distance + {IMAGE_PENALTY}, 1 FROM media_vec
                 WHERE embedding MATCH ? AND k = {CANDIDATES * 2}),
            best AS (SELECT post_id, min(distance) AS distance, image FROM hits GROUP BY post_id)
            SELECT t.id, best.distance, best.image FROM best JOIN posts t ON t.id = best.post_id
             WHERE 1 {where}
             ORDER BY best.distance LIMIT {CANDIDATES}""",
        [vec, vec, *params],
    ).fetchall()
    return [(r[0], r[1], bool(r[2])) for r in rows]


def hydrate(conn: sqlite3.Connection, ids: list[str]) -> list[dict]:
    """Full post records for display, in the order of `ids`."""
    if not ids:
        return []
    rows = {
        r["id"]: dict(r)
        for r in conn.execute(
            f"""SELECT t.id, t.url, t.screen_name, t.name, t.profile_image, t.created_at, t.full_text,
                       t.is_bookmark, t.is_like, t.favorite_count, t.repost_count, t.reply_count,
                       t.views_count, e.summary, e.tags, e.image_text,
                       q.screen_name AS q_author, q.name AS q_name, q.full_text AS q_text,
                       a.title AS article_title, a.preview AS article_preview,
                       length(a.body) - length(replace(a.body, ' ', '')) + 1 AS article_words
                  FROM posts t
                  LEFT JOIN enrichment e ON e.post_id = t.id
                  LEFT JOIN articles a ON a.post_id = t.id
                  LEFT JOIN quoted_posts q ON q.id = t.quoted_id
                 WHERE t.id IN ({",".join("?" * len(ids))})""",
            ids,
        )
    }
    out = []
    for pid in ids:
        r = rows[pid]
        r["media"] = [
            dict(m) for m in conn.execute(
                "SELECT type, local_path, original, thumbnail FROM media WHERE post_id = ? ORDER BY idx", (pid,))
        ]
        out.append(r)
    return out


def random_post(conn: sqlite3.Connection, f: Filters | None = None, older_than_days: int = 0) -> dict | None:
    where, params = _where(f or Filters())
    row = conn.execute(
        f"""SELECT t.id FROM posts t WHERE (t.is_bookmark OR t.is_like) {where}
               AND t.created_at <= date('now', ?) ORDER BY random() LIMIT 1""",
        [*params, f"-{older_than_days} days"]).fetchone()
    return hydrate(conn, [row[0]])[0] if row else None


def browse(conn: sqlite3.Connection, f: Filters | None = None, limit: int = 50) -> list[dict]:
    """Most recently saved posts matching the filters (no search text)."""
    f = f or Filters()
    where, params = _where(f)
    order = "t.like_rank" if f.source == "like" else "coalesce(t.bookmark_rank, 1e9), t.like_rank"
    ids = [r[0] for r in conn.execute(
        f"SELECT t.id FROM posts t WHERE (t.is_bookmark OR t.is_like) {where} ORDER BY {order} LIMIT ?",
        [*params, limit])]
    return hydrate(conn, ids)


def search(conn: sqlite3.Connection, text: str, f: Filters | None = None, limit: int = 20,
           vec: bytes | None = None) -> list[dict]:
    """`vec` is the query_vector(text); without it the search is words only."""
    f = f or Filters()
    if not text.strip():
        return browse(conn, f, limit)
    kw = keyword_ids(conn, text, f)
    near = semantic_ids(conn, vec, f) if vec else []
    sem = [pid for pid, _, _ in near]
    by_image = {pid for pid, _, image in near if image}
    kw_all = set(kw)
    cutoff = min(near[0][1] + SEMANTIC_SLACK, SEMANTIC_MAX) if near else 0
    weak = {pid for pid, d, _ in near if d > cutoff and pid not in kw_all}
    scores: dict[str, float] = {}
    for ranking in (kw, sem):
        for rank, pid in enumerate(ranking):
            scores[pid] = scores.get(pid, 0.0) + 1.0 / (RRF_K + rank + 1)
    top = sorted((p for p in scores if p not in weak), key=scores.get, reverse=True)[:limit]
    kw_set, sem_set = set(kw[:50]), set(sem[:50])
    results = hydrate(conn, top)
    for r in results:
        r["matched_by"] = [name for name, s in (("keyword", kw_set), ("meaning", sem_set)) if r["id"] in s]
        if r["id"] in by_image and r["id"] not in kw_set:
            r["matched_by"] = ["image"]
    return results
