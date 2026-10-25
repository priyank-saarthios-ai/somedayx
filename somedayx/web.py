"""Local API + web UI for SomedayX: python -m somedayx serve [port]

GET /api/search?q=...&source=bookmark|like   search (or browse when q is empty)
GET /api/stats                                counts, last sync and live sync progress
GET /api/home                                 topics, a forgotten gem and search hints
GET /api/surprise?source=...                  one random save
GET /api/wrapped?source=...                   numbers for the home screen and the shareable Wrapped card
GET /api/brain                                local models: install and indexing state
POST /api/brain/install {"writer": bool}      get the models onto this Mac (finds a copy or downloads)
POST /api/brain/writer {"on": bool}           turn Gemma tl;drs on (downloads) or off (deletes the model)
POST /api/brain/reindex                       rebuild every search vector (search keeps working meanwhile)

Only this Mac's SomedayX app can use it: requests must name 127.0.0.1 or
localhost as their Host (so a web page can't reach it through DNS
rebinding) and carry the access token from <data>/token, as the
X-SomedayX-Token header, a t= parameter, or the cookie the browser UI gets.

The server also owns the brain: it keeps the EmbeddingGemma server running
and indexes whatever isn't indexed yet in the background.
"""

import atexit
import hmac
import json
import mimetypes
import secrets
import shutil
import signal
import sys
import threading
import time
from dataclasses import asdict
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from . import embed, llm, models
from .db import DATA, connect
from .search import Filters, hydrate, parse_operators, query_terms, query_vector, random_post, search

STATIC = Path(__file__).parent / "static"
MEDIA = (DATA / "media").resolve()
LOGS = DATA / "logs"
TOKEN_FILE = DATA / "token"
COOKIE = "somedayx"
LAST_SYNC = LOGS / "last_sync.json"
PROGRESS = LOGS / "sync_progress.json"
ACCOUNT = LOGS / "account.json"
# Tags that describe the shape of a post rather than its topic.
META_TAGS = {"thread", "reply", "link only", "video", "image", "meme", "humor", "tweet", "announcement", "quote"}

_conn = connect()
_lock = threading.Lock()  # one sqlite connection shared across request threads


def _links(post_ids: list[str]) -> dict[str, dict[str, dict]]:
    if not post_ids:
        return {}
    out: dict[str, dict[str, dict]] = {}
    rows = _conn.execute(
        f"""SELECT post_id, tco_url, coalesce(l.expanded_url, l.tco_url) AS url, m.title
              FROM links l LEFT JOIN link_meta m ON m.url = l.expanded_url
             WHERE post_id IN ({",".join("?" * len(post_ids))})""",
        post_ids,
    )
    for r in rows:
        out.setdefault(r["post_id"], {})[r["tco_url"]] = {"url": r["url"], "title": r["title"]}
    return out


def _decorate(results: list[dict]) -> list[dict]:
    links = _links([r["id"] for r in results])
    for r in results:
        r["links"] = links.get(r["id"], {})
        r["tags"] = json.loads(r["tags"]) if r.get("tags") else []
        r.setdefault("matched_by", [])
        for m in r["media"]:
            m["src"] = "/" + m["local_path"] if m["local_path"] else m["thumbnail"]
    return results


def _read_json(path: Path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def _saved(source: str | None, alias: str = "") -> str:
    """SQL condition for 'saved as' (Both, Bookmarks or Likes)."""
    a = f"{alias}." if alias else ""
    return {"bookmark": f"{a}is_bookmark", "like": f"{a}is_like"}.get(source or "", f"({a}is_bookmark OR {a}is_like)")


def _top_tags(limit: int, source: str | None = None) -> list[dict]:
    rows = _conn.execute(
        f"""SELECT lower(j.value) AS tag, count(*) AS n FROM enrichment e JOIN posts p ON p.id = e.post_id,
                   json_each(e.tags) j
             WHERE {_saved(source, "p")}
            GROUP BY lower(j.value) ORDER BY n DESC LIMIT ?""", (limit + len(META_TAGS),))
    return [{"tag": r["tag"], "count": r["n"]} for r in rows if r["tag"] not in META_TAGS][:limit]


def _top_authors(limit: int, source: str | None = None) -> list[dict]:
    rows = _conn.execute(
        f"""SELECT screen_name, max(name) AS name, max(profile_image) AS profile_image, count(*) AS n
             FROM posts WHERE {_saved(source)} GROUP BY lower(screen_name)
            ORDER BY n DESC LIMIT ?""", (limit,))
    return [{"screen_name": r["screen_name"], "name": r["name"], "profile_image": r["profile_image"],
             "count": r["n"]} for r in rows]


def _home(source: str | None) -> dict:
    f = Filters(source=source)
    topics = _top_tags(10)
    authors = _top_authors(3)
    gem = random_post(_conn, f, older_than_days=180)
    # Posts from this week in earlier years.
    ids = [r[0] for r in _conn.execute(
        """SELECT id FROM posts WHERE (is_bookmark OR is_like) AND created_at < date('now', '-300 days')
              AND abs(cast(strftime('%j', created_at) AS int) - cast(strftime('%j', 'now') AS int)) <= 3
            ORDER BY favorite_count DESC LIMIT 1""")]
    throwback = hydrate(_conn, ids)[0] if ids else None
    hints = []
    if authors:
        hints.append(f"from:{authors[0]['screen_name']}")
    if topics:
        hints.append(f"has:video {topics[0]['tag']}")
        hints.append(f"{topics[min(2, len(topics) - 1)]['tag']} year:2025")
    hints += ["that thread about pricing", "has:link design inspiration", "is:like funny"]
    return {"topics": topics, "gem": gem and _decorate([gem])[0],
            "throwback": throwback and _decorate([throwback])[0], "hints": hints}


def _underdog(saved: str) -> dict | None:
    """The least-liked post you saved (not a reply): early-fan energy."""
    r = _conn.execute(
        f"""SELECT screen_name, favorite_count, full_text FROM posts
             WHERE {saved} AND favorite_count IS NOT NULL AND in_reply_to IS NULL AND length(full_text) > 20
             ORDER BY favorite_count, created_at LIMIT 1""").fetchone()
    return {"screen_name": r[0], "likes": r[1], "text": r[2][:120]} if r else None


def _median_likes(saved: str) -> int | None:
    n = _conn.execute(f"SELECT count(*) FROM posts WHERE {saved} AND favorite_count IS NOT NULL").fetchone()[0]
    if not n:
        return None
    return _conn.execute(f"""SELECT favorite_count FROM posts WHERE {saved} AND favorite_count IS NOT NULL
                              ORDER BY favorite_count LIMIT 1 OFFSET ?""", (n // 2,)).fetchone()[0]


def _wrapped(source: str | None = None) -> dict:
    one = lambda sql: _conn.execute(sql).fetchone()[0]
    saved = _saved(source)
    by_year = {r[0]: r[1] for r in _conn.execute(
        f"""SELECT substr(created_at, 1, 4), count(*) FROM posts WHERE {saved}
            GROUP BY 1 ORDER BY 1""") if r[0]}
    viral = _conn.execute(
        f"""SELECT id FROM posts WHERE {saved} ORDER BY favorite_count DESC LIMIT 1""").fetchone()
    oldest = _conn.execute(
        f"""SELECT id FROM posts WHERE {saved} AND created_at IS NOT NULL
            ORDER BY created_at LIMIT 1""").fetchone()
    videos = one(f"""SELECT count(DISTINCT m.post_id) FROM media m JOIN posts p ON p.id = m.post_id
                      WHERE m.type IN ('video', 'animated_gif') AND {_saved(source, "p")}""")
    return {
        "handle": (_read_json(ACCOUNT) or {}).get("handle"),
        "source": source,
        "total": one(f"SELECT count(*) FROM posts WHERE {saved}"),
        "bookmarks": one("SELECT count(*) FROM posts WHERE is_bookmark"),
        "likes": one("SELECT count(*) FROM posts WHERE is_like"),
        "people": one(f"SELECT count(DISTINCT lower(screen_name)) FROM posts WHERE {saved}"),
        "videos": videos,
        "articles": one(f"SELECT count(*) FROM articles a JOIN posts p ON p.id = a.post_id WHERE {_saved(source, 'p')}"),
        # Material for the random Wrapped cards.
        "underdog": _underdog(saved),
        "one_hit": one(f"""SELECT count(*) FROM (SELECT 1 FROM posts WHERE {saved}
                             GROUP BY lower(screen_name) HAVING count(*) = 1)"""),
        "threads": one(f"""SELECT count(*) FROM posts WHERE {saved} AND (full_text LIKE '%🧵%'
                            OR lower(full_text) LIKE '%a thread%' OR full_text LIKE '%1/%')"""),
        "reading_hours": round(one(f"""SELECT coalesce(sum(length(a.body) - length(replace(a.body, ' ', '')) + 1), 0)
                                        FROM articles a JOIN posts p ON p.id = a.post_id
                                       WHERE a.body != '' AND {_saved(source, 'p')}""") / 230 / 60, 1),
        "double_tapped": one("SELECT count(*) FROM posts WHERE is_bookmark AND is_like"),
        "median_likes": _median_likes(saved),
        "replies": one(f"SELECT count(*) FROM posts WHERE {saved} AND in_reply_to IS NOT NULL"),
        "topics": _top_tags(5, source),
        "authors": _top_authors(5, source),
        "by_year": by_year,
        "viral": _decorate(hydrate(_conn, [viral[0]]))[0] if viral else None,
        "oldest": _decorate(hydrate(_conn, [oldest[0]]))[0] if oldest else None,
    }


# ---------- the brain: local models and the index ----------

BRAIN: dict = {
    "embed": {"state": "missing"},
    "writer": {"state": "missing"},
    "index": {"state": "idle"},
}
_brain_lock = threading.Lock()
_found = {"at": 0.0, "value": False}


def _found_on_mac() -> bool:
    # Spotlight lookups are slow-ish and the app polls; ask once a minute.
    if BRAIN["embed"]["state"] == "ready":
        return True
    if time.time() - _found["at"] > 60:
        _found.update(at=time.time(), value=models.found_on_mac("embed"))
    return _found["value"]


def _set(part: str, **fields) -> None:
    with _brain_lock:
        BRAIN[part] = {**BRAIN[part], **fields}


def _brain() -> dict:
    with _brain_lock:
        snap = {k: dict(v) for k, v in BRAIN.items()}
    now = embed.indexing_now()
    snap["index"] = {"state": "indexing", **{k: now.get(k) for k in ("stage", "done", "total")}} if now else {"state": "idle"}
    with _lock:
        snap["counts"] = embed.counts(_conn)
    s = models.settings()
    snap.update(
        writer_on=s.get("writer", False),
        found_on_mac=_found_on_mac(),
        embed_size=models.size("embed"), writer_size=models.size("writer"),
        free_space=shutil.disk_usage(models.MODEL_DIR if models.MODEL_DIR.exists() else DATA).free,
        llama=bool(llm.llama_server()),
    )
    return snap


def _run_embedder() -> None:
    """Start EmbeddingGemma (taking over one left running), then index."""
    if not models.ready("embed"):
        return
    try:
        server = llm._embed
        if server.alive():
            server.adopt()
        else:
            _set("embed", state="starting")
            server.start()
        _set("embed", state="ready", running=True)
    except llm.ModelUnavailable as e:
        _set("embed", state="error", error=str(e), running=False)
        return
    _index()


def _index(everything: bool = False) -> None:
    with embed.index_lock(wait=False) as got:
        if not got:
            return  # a sync is indexing
        conn = connect()
        try:
            embed.index_missing(conn, everything=everything)
        except Exception as e:
            print(f"indexing stopped: {type(e).__name__}: {e}", flush=True)
        finally:
            conn.close()


def _install(kind: str) -> None:
    try:
        how = models.install(kind, lambda **kw: _set(kind, **kw))
        _set(kind, state="ready", source=how, error=None)
    except Exception as e:
        _set(kind, state="error", error=str(e))
        return
    if kind == "embed":
        _run_embedder()


def _background(fn, *args) -> None:
    threading.Thread(target=fn, args=args, daemon=True).start()


def _boot_brain() -> None:
    for kind in ("embed", "writer"):
        _set(kind, state="ready" if models.ready(kind) else "missing")
    _background(_run_embedder)
    _background(_keep_indexed)


def _keep_indexed() -> None:
    """Every few minutes, index anything new (say, articles read by a
    terminal command). Cheap when there's nothing to do."""
    while True:
        time.sleep(300)
        if BRAIN["embed"].get("running"):
            _index()


def access_token() -> str:
    """Shared with the app through a file only you can read."""
    try:
        return TOKEN_FILE.read_text().strip()
    except OSError:
        TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
        token = secrets.token_urlsafe(24)
        TOKEN_FILE.write_text(token)
        TOKEN_FILE.chmod(0o600)
        return token


class Handler(BaseHTTPRequestHandler):
    token = ""

    def log_message(self, fmt, *args):
        pass

    def _allowed(self, qs: dict) -> bool:
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0]
        if host not in ("127.0.0.1", "localhost"):
            return False
        cookies = dict(c.strip().split("=", 1) for c in (self.headers.get("Cookie") or "").split(";") if "=" in c)
        given = self.headers.get("X-SomedayX-Token") or qs.get("t") or cookies.get(COOKIE) or ""
        return hmac.compare_digest(given, self.token)

    def _deny(self) -> None:
        self._send(403, b"Open SomedayX from its menu bar icon (Open in Browser).", "text/plain")

    def _send(self, status: int, body: bytes, ctype: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, data) -> None:
        self._send(200, json.dumps(data, ensure_ascii=False).encode(), "application/json; charset=utf-8")

    def do_GET(self) -> None:
        url = urlparse(self.path)
        qs = {k: v[0] for k, v in parse_qs(url.query).items()}
        if not self._allowed(qs):
            return self._deny()

        if url.path == "/":
            # The browser UI gets the token as a cookie, so its own requests work.
            body = (STATIC / "index.html").read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Set-Cookie", f"{COOKIE}={self.token}; Path=/; HttpOnly; SameSite=Strict")
            self.end_headers()
            self.wfile.write(body)
            return

        if url.path == "/api/search":
            source = qs.get("source") if qs.get("source") in ("bookmark", "like") else None
            base = Filters(source=source, author=qs.get("author") or None,
                           since=qs.get("since") or None, until=qs.get("until") or None)
            text, f = parse_operators(qs.get("q") or "", base)
            limit = min(int(qs.get("limit", 40)), 200)
            vec = query_vector(text)
            with _lock:
                results = _decorate(search(_conn, text, f, limit=limit, vec=vec))
            filters = {k: v for k, v in asdict(f).items() if v and k != "source"}
            return self._json({"query": text, "filters": filters, "terms": query_terms(text), "results": results,
                               "semantic": vec is not None or not text})

        if url.path == "/api/home":
            source = qs.get("source") if qs.get("source") in ("bookmark", "like") else None
            with _lock:
                return self._json(_home(source))

        if url.path == "/api/surprise":
            source = qs.get("source") if qs.get("source") in ("bookmark", "like") else None
            with _lock:
                post = random_post(_conn, Filters(source=source))
                return self._json({"post": post and _decorate([post])[0]})

        if url.path == "/api/wrapped":
            source = qs.get("source") if qs.get("source") in ("bookmark", "like") else None
            with _lock:
                return self._json(_wrapped(source))

        if url.path == "/api/brain":
            return self._json(_brain())

        if url.path == "/api/stats":
            with _lock:
                one = lambda sql: _conn.execute(sql).fetchone()[0]
                stats = {
                    "total": one("SELECT count(*) FROM posts"),
                    "bookmarks": one("SELECT count(*) FROM posts WHERE is_bookmark"),
                    "likes": one("SELECT count(*) FROM posts WHERE is_like"),
                }
            stats["last_sync"] = _read_json(LAST_SYNC)
            stats["progress"] = _read_json(PROGRESS)
            stats["handle"] = (_read_json(ACCOUNT) or {}).get("handle")
            stats["brain"] = _brain()
            return self._json(stats)

        if url.path.startswith("/media/"):
            path = (MEDIA / url.path.removeprefix("/media/")).resolve()
            if path.parent == MEDIA and path.is_file():
                ctype = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
                return self._send(200, path.read_bytes(), ctype)

        self._send(404, b"Not found", "text/plain")

    def do_POST(self) -> None:
        url = urlparse(self.path)
        if not self._allowed({k: v[0] for k, v in parse_qs(url.query).items()}):
            return self._deny()
        try:
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
        except ValueError:
            body = {}

        if url.path == "/api/brain/install":
            models.save_settings(writer=bool(body.get("writer")))
            for kind in ("embed", "writer") if body.get("writer") else ("embed",):
                if BRAIN[kind]["state"] not in ("ready", "finding", "verifying", "copying", "downloading"):
                    _set(kind, state="finding", done=0, total=models.size(kind), error=None)
                    _background(_install, kind)
            return self._json(_brain())

        if url.path == "/api/brain/reindex":
            if BRAIN["embed"].get("running") and not embed.indexing_now():
                _background(_index, True)
            return self._json(_brain())

        if url.path == "/api/brain/writer":
            on = bool(body.get("on"))
            models.save_settings(writer=on)
            if on and BRAIN["writer"]["state"] in ("missing", "error"):
                _set("writer", state="finding", done=0, total=models.size("writer"), error=None)
                _background(_install, "writer")
            elif not on:
                models.remove("writer")  # 2.8 GB back; existing tl;drs stay
                _set("writer", state="missing")
            return self._json(_brain())

        self._send(404, b"Not found", "text/plain")


def serve(port: int = 8765) -> None:
    # Stop the model server with us, including when the app sends SIGTERM.
    atexit.register(llm._embed.stop)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    with _lock:
        embed.ensure_tables(_conn)
    Handler.token = access_token()
    _boot_brain()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    print(f"Open http://127.0.0.1:{port}/?t={Handler.token}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
