"""The search index: EmbeddingGemma vectors for every saved post and every
image (sqlite-vec), plus the text Apple Vision reads out of images.

All steps only do what's missing, so the index fills in over time and an
interrupted run picks up where it stopped. One process indexes at a time.
"""

import fcntl
import json
import os
import time
import urllib.error
import sqlite3
import subprocess
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager

import sqlite_vec

from . import llm
from .db import DATA, ROOT, rebuild_fts

MODEL_ID = "embeddinggemma-2-Q8_0"
DIM = 768
MAX_CHARS = 6000
TEXT_BATCH = 16
LOCK = DATA / "logs" / "index.lock"
# Whoever indexes (search server, sync, terminal) reports here, so the app
# can show it.
PROGRESS = DATA / "logs" / "index_progress.json"
OCR_TOOL = ROOT / "macapp" / "build" / "somedayx-ocr"
OCR_BATCH = 24
OCR_PARALLEL = 3

Progress = Callable[..., None]


def ensure_tables(conn: sqlite3.Connection) -> None:
    conn.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute(f"CREATE VIRTUAL TABLE IF NOT EXISTS posts_vec USING vec0("
                 f"post_id TEXT PRIMARY KEY, embedding float[{DIM}] distance_metric=cosine)")
    conn.execute(f"CREATE VIRTUAL TABLE IF NOT EXISTS media_vec USING vec0("
                 f"media_key TEXT PRIMARY KEY, embedding float[{DIM}] distance_metric=cosine)")
    row = conn.execute("SELECT value FROM meta WHERE key = 'embed_model'").fetchone()
    if not row or row[0] != MODEL_ID:
        # Vectors from another model don't compare with these: start over.
        with conn:
            conn.execute("DELETE FROM posts_vec")
            conn.execute("DELETE FROM media_vec")
            conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('embed_model', ?)", (MODEL_ID,))


@contextmanager
def index_lock(wait: bool):
    """Held while indexing so the search server and a sync never both do it.
    Yields False when not waiting and someone else holds it."""
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with open(LOCK, "w") as fh:
        try:
            fcntl.flock(fh, fcntl.LOCK_EX | (0 if wait else fcntl.LOCK_NB))
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


# ---------- text in images (Apple Vision) ----------

def _read_text(batch: list[sqlite3.Row]) -> dict[str, str]:
    paths = [str(DATA / r["local_path"]) for r in batch]
    out = subprocess.run([str(OCR_TOOL), *paths], capture_output=True, text=True, timeout=600)
    texts = {}
    for line in out.stdout.splitlines():
        try:
            rec = json.loads(line)
            texts[rec["path"]] = rec["text"].strip()
        except (ValueError, KeyError):
            continue
    return texts


def ocr_missing(conn: sqlite3.Connection, progress: Progress = lambda **kw: None) -> int:
    if not OCR_TOOL.exists():
        print("Text-in-image reader not built (run macapp/install.sh); skipping.", flush=True)
        return 0
    rows = conn.execute("SELECT post_id, idx, local_path FROM media "
                        "WHERE local_path IS NOT NULL AND ocr_text IS NULL").fetchall()
    # Report against everything, so a resumed run doesn't start the bar over.
    total = conn.execute("SELECT count(*) FROM media WHERE local_path IS NOT NULL").fetchone()[0]
    batches = [rows[i:i + OCR_BATCH] for i in range(0, len(rows), OCR_BATCH)]
    done = total - len(rows)
    with ThreadPoolExecutor(OCR_PARALLEL) as pool:
        for batch, texts in zip(batches, pool.map(_read_text, batches)):
            with conn:
                for r in batch:
                    text = texts.get(str(DATA / r["local_path"]), "")
                    conn.execute("UPDATE media SET ocr_text = ? WHERE post_id = ? AND idx = ?",
                                 (text, r["post_id"], r["idx"]))
                    if text:  # the post's text vector should include it
                        conn.execute("DELETE FROM posts_vec WHERE post_id = ?", (r["post_id"],))
            done += len(batch)
            progress(done=done, total=total)
    if rows:
        with conn:
            rebuild_fts(conn)
    return len(rows)


# ---------- post vectors ----------

def _document(row: sqlite3.Row) -> str:
    parts = [
        f"{row['name']} (@{row['screen_name']})",
        row["full_text"],
        f"Article: {row['article_title'] or ''}\n{row['article']}" if row["article"] else None,
        f"Quoting @{row['q_author']}: {row['q_text']}" if row["q_text"] else None,
        row["link_text"],
        "Text in images: " + row["ocr"] if row["ocr"] else None,
        row["image_text"],
        row["summary"],
        "Topics: " + row["tags"] if row["tags"] else None,
    ]
    return "\n".join(p for p in parts if p)[:MAX_CHARS]


def embed_posts(conn: sqlite3.Connection, progress: Progress = lambda **kw: None, everything: bool = False) -> int:
    """Vectors for posts that lack one, or for all of them (`everything`),
    replacing old ones batch by batch so search keeps working throughout."""
    rows = conn.execute(
        """
        SELECT t.id, t.name, t.screen_name, t.full_text,
               e.summary, e.image_text,
               (SELECT group_concat(value, ', ') FROM json_each(coalesce(e.tags, '[]'))) AS tags,
               q.screen_name AS q_author, q.full_text AS q_text,
               (SELECT group_concat(concat_ws(' — ', m.title, m.description), '\n')
                  FROM links l JOIN link_meta m ON m.url = l.expanded_url
                 WHERE l.post_id = t.id AND m.title IS NOT NULL) AS link_text,
               (SELECT group_concat(ocr_text, '\n') FROM media WHERE post_id = t.id AND ocr_text != '') AS ocr,
               a.title AS article_title, coalesce(nullif(a.body, ''), a.preview) AS article
          FROM posts t
          LEFT JOIN enrichment e ON e.post_id = t.id
          LEFT JOIN articles a ON a.post_id = t.id
          LEFT JOIN quoted_posts q ON q.id = t.quoted_id
         WHERE ? OR t.id NOT IN (SELECT post_id FROM posts_vec)
        """, (everything,)
    ).fetchall()
    total = conn.execute("SELECT count(*) FROM posts").fetchone()[0]
    already = total - len(rows)
    for start in range(0, len(rows), TEXT_BATCH):
        batch = rows[start:start + TEXT_BATCH]
        vecs = llm.embed_texts([_document(r) for r in batch])
        with conn:
            for r, v in zip(batch, vecs):
                conn.execute("DELETE FROM posts_vec WHERE post_id = ?", (r["id"],))
                conn.execute("INSERT INTO posts_vec (post_id, embedding) VALUES (?, ?)",
                             (r["id"], sqlite_vec.serialize_float32(v)))
        progress(done=already + min(start + TEXT_BATCH, len(rows)), total=total)
    return len(rows)


# ---------- image vectors ----------

def embed_media(conn: sqlite3.Connection, progress: Progress = lambda **kw: None, everything: bool = False) -> int:
    rows = conn.execute(
        "SELECT post_id || ':' || idx AS key, local_path FROM media WHERE local_path IS NOT NULL "
        "AND (? OR post_id || ':' || idx NOT IN (SELECT media_key FROM media_vec))", (everything,)).fetchall()
    total = conn.execute("SELECT count(*) FROM media WHERE local_path IS NOT NULL").fetchone()[0]
    already = total - len(rows)
    for done, r in enumerate(rows, already + 1):
        try:
            vec = llm.embed_image(DATA / r["local_path"])
        except urllib.error.URLError:
            raise  # the model stopped: the next run picks up from here
        except (OSError, RuntimeError) as e:
            print(f"  skipped {r['local_path']}: {e}", flush=True)
            vec = None
        if vec:
            with conn:
                conn.execute("DELETE FROM media_vec WHERE media_key = ?", (r["key"],))
                conn.execute("INSERT INTO media_vec (media_key, embedding) VALUES (?, ?)",
                             (r["key"], sqlite_vec.serialize_float32(vec)))
        if done % 8 == 0 or done == total:
            progress(done=done, total=total)
    return len(rows)


def index_missing(conn: sqlite3.Connection, progress: Progress = lambda **kw: None,
                  everything: bool = False) -> dict:
    """Everything search needs, most useful first: post text (search works
    after this), text in images, then the images themselves. `everything`
    rebuilds every vector in place."""
    ensure_tables(conn)

    def report(stage: str) -> Progress:
        def update(**kw):
            state = {"stage": stage, "pid": os.getpid(), "at": time.time(), **kw}
            tmp = PROGRESS.with_suffix(".tmp")
            tmp.write_text(json.dumps(state))
            tmp.replace(PROGRESS)
            progress(stage=stage, **kw)
        return update

    try:
        counts = {"posts": embed_posts(conn, report("posts"), everything)}
        counts["ocr"] = ocr_missing(conn, report("ocr"))
        counts["posts"] += embed_posts(conn, report("posts"))  # ones OCR changed
        counts["images"] = embed_media(conn, report("images"), everything)
    finally:
        PROGRESS.unlink(missing_ok=True)
    if any(counts.values()):
        with conn:
            conn.execute("INSERT OR REPLACE INTO meta (key, value) VALUES ('indexed_at', datetime('now'))")
    return counts


def counts(conn: sqlite3.Connection) -> dict:
    """What's indexed, for the home screen."""
    one = lambda sql: conn.execute(sql).fetchone()[0]
    try:
        return {
            "posts": one("SELECT count(*) FROM posts_vec"),
            "posts_total": one("SELECT count(*) FROM posts"),
            "images": one("SELECT count(*) FROM media_vec"),
            "images_total": one("SELECT count(*) FROM media WHERE local_path IS NOT NULL"),
            "articles": one("SELECT count(*) FROM articles WHERE body != ''"),
            "indexed_at": one("SELECT max(value) FROM meta WHERE key = 'indexed_at'"),
        }
    except sqlite3.OperationalError:
        return {}  # no index yet


def indexing_now() -> dict | None:
    """What's being indexed right now, by any process, or None."""
    try:
        state = json.loads(PROGRESS.read_text())
        os.kill(state["pid"], 0)  # still running?
        return state
    except (OSError, ValueError, KeyError):
        return None


def query_vector(text: str) -> bytes:
    return sqlite_vec.serialize_float32(llm.embed_texts([text], query=True)[0])
