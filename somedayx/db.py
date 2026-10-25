"""The SomedayX database and where everything lives.

Your data stays out of the code folder, in ~/Library/Application Support/
SomedayX (set SOMEDAYX_HOME to use another folder): the database, images,
logs, models and the logged-in browser profile used for syncing.
"""

import os
import shutil
import sqlite3
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent  # the code
DATA = Path(os.environ.get("SOMEDAYX_HOME") or Path.home() / "Library" / "Application Support" / "SomedayX")
DB_PATH = DATA / "somedayx.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS posts (
    id              TEXT PRIMARY KEY,
    url             TEXT NOT NULL,
    screen_name     TEXT,
    name            TEXT,
    user_id         TEXT,
    profile_image   TEXT,
    created_at      TEXT,            -- ISO 8601, UTC
    full_text       TEXT,
    lang            TEXT,
    in_reply_to     TEXT,
    quoted_id       TEXT,
    favorite_count  INTEGER,
    repost_count   INTEGER,
    reply_count     INTEGER,
    quote_count     INTEGER,
    bookmark_count  INTEGER,
    views_count     INTEGER,
    is_bookmark     INTEGER NOT NULL DEFAULT 0,
    is_like         INTEGER NOT NULL DEFAULT 0,
    bookmark_rank   INTEGER,         -- 0 = most recently bookmarked
    like_rank       INTEGER,         -- 0 = most recently liked
    first_seen_at   TEXT NOT NULL DEFAULT (datetime('now')),
    raw             TEXT             -- original export record (JSON)
);

-- Posts we only know about because a saved post quoted them.
-- Kept apart so they never show up as search results on their own.
CREATE TABLE IF NOT EXISTS quoted_posts (
    id              TEXT PRIMARY KEY,
    screen_name     TEXT,
    name            TEXT,
    created_at      TEXT,
    full_text       TEXT
);

CREATE TABLE IF NOT EXISTS media (
    post_id        TEXT NOT NULL,
    idx             INTEGER NOT NULL,
    type            TEXT,            -- photo | video | animated_gif
    tco_url         TEXT,
    thumbnail       TEXT,
    original        TEXT,
    PRIMARY KEY (post_id, idx)
);

CREATE TABLE IF NOT EXISTS links (
    post_id        TEXT NOT NULL,
    tco_url         TEXT NOT NULL,
    expanded_url    TEXT,            -- NULL until resolved
    display_url     TEXT,
    PRIMARY KEY (post_id, tco_url)
);

-- Page metadata for every link target, keyed by the expanded URL.
CREATE TABLE IF NOT EXISTS link_meta (
    url             TEXT PRIMARY KEY,
    final_url       TEXT,
    title           TEXT,
    description     TEXT,
    error           TEXT,
    fetched_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

-- Model-written tl;drs and tags, one row per saved post.
CREATE TABLE IF NOT EXISTS enrichment (
    post_id        TEXT PRIMARY KEY,
    summary         TEXT,
    tags            TEXT,            -- JSON array of strings
    image_text      TEXT,            -- image captions (older enrichment)
    created_at      TEXT NOT NULL DEFAULT (datetime('now'))
);

-- X Articles (long-form posts). Title and opening come with the timeline;
-- the full body is fetched later in the logged-in browser.
CREATE TABLE IF NOT EXISTS articles (
    post_id         TEXT PRIMARY KEY,
    article_id      TEXT,
    url             TEXT,            -- set when the saved post quotes the article
    title           TEXT,
    preview         TEXT,
    body            TEXT,            -- NULL until fetched, '' if it couldn't be
    fetched_at      TEXT
);

CREATE INDEX IF NOT EXISTS idx_posts_screen_name ON posts(screen_name);
CREATE INDEX IF NOT EXISTS idx_posts_created_at ON posts(created_at);
"""

# Columns added after the first release of the schema.
MIGRATIONS = [
    ("media", "local_path", "TEXT"),
    ("media", "ocr_text", "TEXT"),  # read by Apple Vision; '' = no text, NULL = not read yet
    ("articles", "url", "TEXT"),     # the post to open for the body, when it's a quoted article
]

FTS_SCHEMA = """
CREATE VIRTUAL TABLE posts_fts USING fts5(
    id UNINDEXED,
    full_text,
    author,
    quoted_text,
    links,
    summary,
    tags,
    image_text,
    article,
    tokenize = 'porter unicode61 remove_diacritics 2'
);
"""


def migrate_legacy() -> None:
    """One-time move from the early layout: data/ inside the code folder
    (stash.db) and models in Application Support/Stash."""
    legacy = ROOT / "data"
    if DB_PATH.exists() or not (legacy / "stash.db").exists():
        return
    DATA.mkdir(parents=True, exist_ok=True)
    for item in legacy.iterdir():
        name = {"stash.db": "somedayx.db", "stash.db-wal": "somedayx.db-wal", "stash.db-shm": "somedayx.db-shm",
                "enrich": "archive/enrich"}.get(item.name, item.name)  # enrich: old enrichment batches, kept
        (DATA / name).parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(item), DATA / name)
    old_models = Path.home() / "Library" / "Application Support" / "Stash" / "Models"
    if old_models.exists() and not (DATA / "Models").exists():
        shutil.move(str(old_models), DATA / "Models")
    legacy.rmdir()
    conn = sqlite3.connect(DB_PATH)
    with conn:  # image paths were relative to the code folder
        conn.execute("UPDATE media SET local_path = substr(local_path, 6) WHERE local_path LIKE 'data/%'")
    conn.close()


def connect(path: Path = DB_PATH) -> sqlite3.Connection:
    if path == DB_PATH:
        migrate_legacy()
    path.parent.mkdir(parents=True, exist_ok=True)
    DATA.chmod(0o700)  # holds your logged-in X session: yours only
    conn = sqlite3.connect(path, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    try:
        import sqlite_vec

        conn.enable_load_extension(True)
        sqlite_vec.load(conn)
        conn.enable_load_extension(False)
    except (ImportError, AttributeError):
        pass  # vector search unavailable; keyword search still works
    conn.execute("PRAGMA journal_mode = WAL")
    fts_sql = conn.execute("SELECT sql FROM sqlite_master WHERE name = 'posts_fts'").fetchone()
    fresh_fts = not fts_sql or "article" not in fts_sql[0]  # missing, or from before articles
    conn.executescript(SCHEMA)
    for table, column, decl in MIGRATIONS:
        existing = {r["name"] for r in conn.execute(f"PRAGMA table_info({table})")}
        if column not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {column} {decl}")
    if fresh_fts and conn.execute("SELECT 1 FROM posts LIMIT 1").fetchone():
        with conn:
            rebuild_fts(conn)
    return conn


def rebuild_fts(conn: sqlite3.Connection) -> None:
    # Dropped and recreated so column changes to the index take effect.
    conn.execute("DROP TABLE IF EXISTS posts_fts")
    conn.executescript(FTS_SCHEMA)
    conn.execute(
        """
        INSERT INTO posts_fts (id, full_text, author, quoted_text, links, summary, tags, image_text, article)
        SELECT t.id,
               t.full_text,
               coalesce(t.name, '') || ' @' || coalesce(t.screen_name, ''),
               coalesce(q.full_text, '') || ' @' || coalesce(q.screen_name, ''),
               (SELECT group_concat(concat_ws(' ', coalesce(l.expanded_url, l.display_url),
                                                   m.title, m.description), ' ')
                  FROM links l LEFT JOIN link_meta m ON m.url = l.expanded_url
                 WHERE l.post_id = t.id),
               e.summary,
               (SELECT group_concat(value, ' ') FROM json_each(coalesce(e.tags, '[]'))),
               concat_ws(' ', e.image_text,
                         (SELECT group_concat(ocr_text, ' ') FROM media WHERE post_id = t.id AND ocr_text != '')),
               concat_ws(' ', a.title, coalesce(nullif(a.body, ''), a.preview))
          FROM posts t
          LEFT JOIN articles a ON a.post_id = t.id
          LEFT JOIN quoted_posts q ON q.id = t.quoted_id
          LEFT JOIN enrichment e ON e.post_id = t.id
        """
    )
