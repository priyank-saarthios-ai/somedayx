"""End-to-end sync: collect -> import -> fetch -> tl;drs (optional) -> index.

Everything after collecting runs on this Mac: Gemma writes tl;drs when
turned on, Apple Vision reads text in images, EmbeddingGemma indexes.

Writes logs/last_sync.json (in the data folder) and, while running, sync_progress.json
(both read by the menu bar app), and holds a lock so a scheduled run and a
manual "Sync now" never overlap.
"""

import fcntl
import json
import os
import time
import subprocess
import traceback
from datetime import datetime

from . import enrich, llm, models, write
from .db import DATA

LOG_DIR = DATA / "logs"
STATUS = LOG_DIR / "last_sync.json"
LOCK = LOG_DIR / "sync.lock"
PROGRESS = LOG_DIR / "sync_progress.json"
BUSY = 3  # exit code: another sync is running (the app follows that one instead)


class Progress:
    """Live state for the app: phase (login | bookmark | like | fetch |
    write | index), counts and the latest avatars, merged across calls."""

    def __init__(self):
        # pid: so a reader can tell a live sync from one that was killed.
        self.state: dict = {"phase": "starting", "pid": os.getpid(), "started": time.time()}
        self.write()

    def __call__(self, **fields) -> None:
        self.state.update(fields)
        self.write()

    def write(self) -> None:
        tmp = PROGRESS.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state))
        tmp.replace(PROGRESS)

    def clear(self) -> None:
        PROGRESS.unlink(missing_ok=True)


def _status(**fields) -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    STATUS.write_text(json.dumps({"at": datetime.now().isoformat(timespec="seconds"), **fields}))


def _notify(title: str, message: str) -> None:
    script = f"display notification {json.dumps(message)} with title {json.dumps(title)}"
    subprocess.run(["osascript", "-e", script], capture_output=True)


def run_sync(conn, headless: bool = False, notify: bool = False) -> int:
    from .collect import LoginRequired, collect
    from .embed import index_lock, index_missing
    from .importer import import_new, import_older

    LOG_DIR.mkdir(parents=True, exist_ok=True)
    lock = open(LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Another sync is already running.")
        return BUSY

    _status(state="running")
    progress = Progress()
    added = {"bookmark": 0, "like": 0}

    def save_older(kind: str, records: list[dict]) -> None:
        import_older(conn, kind, records)
        added[kind] += len(records)

    try:
        print(f"== {datetime.now():%Y-%m-%d %H:%M} collecting new saves from X", flush=True)
        new = collect(conn, headless=headless, save_older=save_older, progress=progress)
        for kind, records in new.items():
            import_new(conn, kind, records)
            added[kind] += len(records)
        print(f"Added {added['bookmark']} bookmarks, {added['like']} likes", flush=True)

        if any(added.values()):
            print("\n== fetching links, quoted posts and images", flush=True)
            progress(phase="fetch")
            enrich.fetch_all(conn)
        # Both steps also pick up anything an earlier run didn't finish.
        if write.enabled():
            print("\n== writing tl;drs", flush=True)
            progress(phase="write", done=0, total=0)
            write.write_missing(conn, lambda **kw: progress(phase="write", **kw))
        if models.ready("embed"):
            print("\n== indexing", flush=True)
            progress(phase="index", done=0, total=0)
            # The search server's model if it's running, else our own for now.
            started = llm._embed.start()
            try:
                with index_lock(wait=True):
                    counts = index_missing(conn, lambda **kw: progress(phase="index", **kw))
                print(f"Indexed {counts}", flush=True)
            finally:
                if started:
                    llm._embed.stop()
        else:
            print("\nSearch model not installed yet; new posts are searchable by words only.", flush=True)

        msg = f"{added.get('bookmark', 0)} new bookmarks, {added.get('like', 0)} new likes"
        _status(state="ok", message=msg, **added)
        if notify:
            _notify("Your saves are up to date", msg)
        return 0
    except LoginRequired as e:
        _status(state="login", message=str(e))
        if notify:
            _notify("Log in to X", "Your X session expired. Right-click SomedayX and choose Sync Now to log in.")
        print(e)
        return 2
    except Exception as e:
        traceback.print_exc()
        if "has been closed" in str(e):  # the login window was closed
            _status(state="stopped", message="The X login window was closed before the sync finished. "
                                             "Everything collected so far is kept; sync again to continue.")
            return 1
        _status(state="error", message=f"{type(e).__name__}: {e}"[:300])
        if notify:
            _notify("Sync didn't finish", f"{type(e).__name__}: {e}"[:200])
        return 1
    finally:
        progress.clear()
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()
