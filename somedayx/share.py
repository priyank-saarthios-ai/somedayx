"""Open X's composer with a post ready to go: text typed in, image attached.

Uses the same logged-in browser as syncing, so nothing is posted until you
press Post yourself. The window closes once you've posted (or closed it).

    python -m somedayx share <image.png> <text>
"""

import fcntl
import time
from pathlib import Path

from .collect import _launch

EDITOR = '[data-testid="tweetTextarea_0"]'
FILE_INPUT = 'input[data-testid="fileInput"]'
LOGIN_WAIT_MS = 5 * 60 * 1000
REVIEW_MINUTES = 15
BUSY = 3  # exit code: a sync has the browser


def share_post(image: Path, text: str) -> int:
    from playwright.sync_api import sync_playwright

    from .sync import LOCK

    # The browser profile can only be open once; a running sync has it.
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    lock = open(LOCK, "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("A sync is using the browser; try again when it's done.")
        return BUSY
    try:
        with sync_playwright() as p:
            ctx = _launch(p, headless=False)
            try:
                page = ctx.pages[0] if ctx.pages else ctx.new_page()
                page.goto("https://x.com/compose/post", wait_until="domcontentloaded")
                editor = page.locator(EDITOR).first
                editor.wait_for(timeout=LOGIN_WAIT_MS)  # long enough to log in if needed
                editor.click()
                # Typed line by line: the composer turns Enter into a line break.
                for i, line in enumerate(text.split("\n")):
                    if i:
                        page.keyboard.press("Enter")
                    if line:
                        page.keyboard.insert_text(line)
                page.locator(FILE_INPUT).first.set_input_files(str(image))
                print("Composer ready; waiting for you to post.", flush=True)
                try:
                    deadline = time.time() + REVIEW_MINUTES * 60
                    while time.time() < deadline and not page.is_closed():
                        if "/compose/" not in page.url:  # X leaves the composer once posted
                            print("Posted.", flush=True)
                            break
                        page.wait_for_timeout(1000)
                except Exception:
                    pass  # you closed the window: fine, nothing left to do
            finally:
                try:
                    ctx.close()
                except Exception:
                    pass
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()
    return 0

