"""Usage:
    python -m somedayx sync [--headless] [--notify]
                                        # collect new saves from X, then fetch, write tl;drs, index
    python -m somedayx collect           # only collect new saves from X (opens Chrome)
    python -m somedayx models [install [--writer] | remove-writer]
                                        # the local Gemma models: status, get them, free space
    python -m somedayx index [--all]     # read text in images and index new (or all) posts and images
    python -m somedayx write             # Gemma tl;drs for posts without one (if turned on)
    python -m somedayx articles          # read the full text of saved X Articles
    python -m somedayx share <png> <text> # open X's composer with the text and image ready
    python -m somedayx import            # load raw/*.json (in the data folder) into the database
    python -m somedayx stats             # what's in the database
    python -m somedayx search <query>    # hybrid search; X-style operators like
                                        # from:handle is:bookmark has:video year:2025
    python -m somedayx fetch             # resolve links, quoted posts, download images
    python -m somedayx serve [port]      # web UI at http://127.0.0.1:8765
"""

import sys
import textwrap

from . import enrich, models
from .db import DB_PATH, connect
from .importer import import_all


def cmd_import(conn) -> None:
    for name, n in import_all(conn).items():
        print(f"  {name}: {n} records")
    cmd_stats(conn)


def cmd_stats(conn) -> None:
    one = lambda sql: conn.execute(sql).fetchone()[0]
    print(f"Database: {DB_PATH}")
    print(f"  saved posts    {one('SELECT count(*) FROM posts')}")
    print(f"    bookmarks    {one('SELECT count(*) FROM posts WHERE is_bookmark')}")
    print(f"    likes        {one('SELECT count(*) FROM posts WHERE is_like')}")
    print(f"    both         {one('SELECT count(*) FROM posts WHERE is_bookmark AND is_like')}")
    print(f"  authors        {one('SELECT count(DISTINCT screen_name) FROM posts')}")
    print(f"  media items    {one('SELECT count(*) FROM media')}"
          f"  ({one('SELECT count(*) FROM media WHERE local_path IS NOT NULL')} downloaded)")
    print(f"  link pages     {one('SELECT count(*) FROM link_meta WHERE title IS NOT NULL')} with titles")
    print(f"  with tl;dr     {one('SELECT count(*) FROM enrichment WHERE summary IS NOT NULL')}")
    for table, label in (("posts_vec", "indexed posts"), ("media_vec", "indexed images")):
        try:
            print(f"  {label:15}{one(f'SELECT count(*) FROM {table}')}")
        except Exception:
            pass
    print(f"  links          {one('SELECT count(*) FROM links')}"
          f"  ({one('SELECT count(*) FROM links WHERE expanded_url IS NULL')} unresolved t.co)")
    print(f"  quoting posts {one('SELECT count(*) FROM posts WHERE quoted_id IS NOT NULL')}"
          f"  ({one('SELECT count(*) FROM posts t JOIN quoted_posts q ON q.id = t.quoted_id')} with quoted text)")


def cmd_search(conn, args: list[str]) -> None:
    from .search import parse_operators, query_vector, search

    # X-style operators work here too: from:, is:bookmark, has:image, year:…
    query, f = parse_operators(" ".join(args))
    results = search(conn, query, f, limit=10, vec=query_vector(query))
    if not results:
        print("No matches.")
    for r in results:
        tag = "/".join(s for s, on in (("bookmark", r["is_bookmark"]), ("like", r["is_like"])) if on)
        matched = f"  ({'+'.join(r['matched_by'])})" if r.get("matched_by") else ""
        print(f"@{r['screen_name']}  {r['created_at'][:10]}  [{tag}]{matched}  {r['url']}")
        print(textwrap.indent(textwrap.fill(r["summary"] or r["full_text"], 100), "    "), "\n")


def cmd_collect(conn) -> None:
    from .collect import collect
    from .importer import import_new

    for kind, records in collect(conn).items():
        import_new(conn, kind, records)
        print(f"Added {len(records)} new {kind}s")


def cmd_models(args: list[str]) -> None:
    def show(**kw):
        if kw.get("total"):
            print(f"\r  {kw.get('state')}: {kw.get('done', 0) / 1e6:,.0f} / {kw['total'] / 1e6:,.0f} MB   ", end="", flush=True)

    if args[:1] == ["install"]:
        for kind in ("embed", "writer") if "--writer" in args else ("embed",):
            print(f"{kind}: {models.install(kind, show)}")
        if "--writer" in args:
            models.save_settings(writer=True)
    elif args[:1] == ["remove-writer"]:
        models.remove("writer")
        models.save_settings(writer=False)
    for kind in models.MODELS:
        print(f"  {kind:7} {'ready' if models.ready(kind) else 'not installed'}  ({models.size(kind) / 1e9:.1f} GB)")
    print(f"  tl;drs  {'on' if models.settings()['writer'] else 'off'}   models in {models.MODEL_DIR}")


def cmd_index(conn, everything: bool) -> None:
    from . import llm
    from .embed import ensure_tables, index_lock, index_missing

    ensure_tables(conn)
    if everything:
        with conn:
            conn.execute("DELETE FROM posts_vec")
            conn.execute("DELETE FROM media_vec")
    started = llm._embed.start()
    try:
        with index_lock(wait=True):
            print(index_missing(conn, lambda **kw: print(f"\r  {kw['stage']}: {kw['done']}/{kw['total']}   ",
                                                          end="", flush=True)))
    finally:
        if started:
            llm._embed.stop()


def main() -> None:
    args = sys.argv[1:]
    if not args or args[0] not in {"import", "stats", "search", "fetch", "models", "index", "write", "articles", "share", "serve", "sync", "collect"}:
        sys.exit(__doc__)
    conn = connect()
    if args[0] == "import":
        cmd_import(conn)
    elif args[0] == "stats":
        cmd_stats(conn)
    elif args[0] == "fetch":
        enrich.fetch_all(conn)
        cmd_stats(conn)
    elif args[0] == "models":
        cmd_models(args[1:])
    elif args[0] == "index":
        cmd_index(conn, everything="--all" in args)
    elif args[0] == "share":
        from pathlib import Path

        from .share import share_post

        sys.exit(share_post(Path(args[1]), args[2]))
    elif args[0] == "articles":
        from .collect import collect_articles

        print(f"Read {collect_articles(conn, headless='--show' not in args)} articles")
    elif args[0] == "write":
        from .write import write_missing

        print(f"Wrote {write_missing(conn)} tl;drs")
    elif args[0] == "sync":
        from .sync import run_sync

        sys.exit(run_sync(conn, headless="--headless" in args, notify="--notify" in args))
    elif args[0] == "collect":
        cmd_collect(conn)
    elif args[0] == "serve":
        from .web import serve

        return serve(int(args[1]) if len(args) > 1 else 8765)
    elif len(args) < 2:
        sys.exit("search needs at least one word")
    else:
        cmd_search(conn, args[1:])


if __name__ == "__main__":
    main()
