# SomedayX

**For the X posts you'll read someday.** Search everything you've bookmarked or liked on X by meaning, from your Mac's menu bar. It runs 100% on your Mac: no cloud, no account, no tracking.

<!-- demo GIF goes here: double-tap ⌥ → type → found -->

- **Double-tap ⌥ anywhere** to open search. Type what you remember ("that thread about pricing") and SomedayX finds it, even when the words don't match.
- **Search inside images.** "screenshot of a dashboard" finds posts by what's *in* the picture, and text in screenshots and memes is searchable too.
- **X Articles included.** The full text of saved X Articles is searchable, not just their titles.
- **SomedayX Wrapped.** A shareable card that roasts your saving habits ("🤖 AI agent maximalist · 549 videos in watch later").
- **Your saves, your Mac.** Google's Gemma models run locally through llama.cpp. Nothing you save is ever sent anywhere.

## Requirements

- macOS 14 or newer, Apple silicon recommended (Intel works, slowly)
- 8 GB of RAM or more, about 1.5 GB of free disk space
- [Homebrew](https://brew.sh) (the installer uses it for `uv` and `llama.cpp`)
- Xcode Command Line Tools (`xcode-select --install`)
- Google Chrome, or the installer downloads Chromium

## Install

```sh
git clone https://github.com/priyank-saarthios-ai/somedayx.git
cd somedayx
macapp/install.sh
```

The first launch walks you through it: log in to X once in SomedayX's own browser window, pick your search brain (optionally with tl;drs), and learn the shortcut. The first sync reads your whole history, and indexing about 3,000 saves takes roughly 35 minutes on an M2. Search works long before it finishes.

To uninstall: `macapp/install.sh --uninstall` (your data stays until you delete `~/Library/Application Support/SomedayX`).

## Using it

| | |
|---|---|
| Double-tap ⌥, or ⌥⌘X | open or close SomedayX from any app |
| ↵ · ⌘L · ⇧⌘C | open on X · open the link · copy the post's link |
| ⌘1 ⌘2 ⌘3 | Both · Bookmarks · Likes |
| ⌘R | surprise me |
| ⌘Y | your Wrapped (⌘R in there shuffles the card) |
| Esc | back to home, then close |

Search understands X-style operators: `from:handle`, `is:bookmark`, `is:like`, `has:image`, `has:video`, `has:link`, `has:article`, `year:2025`, `since:2025-03`, `until:2025-06`.

SomedayX syncs every night at 3 AM (and whenever you press sync). Right-click the menu bar icon for sync, settings and logs.

## Use it from AI apps (MCP)

SomedayX includes an [MCP](https://modelcontextprotocol.io) server, so Claude Desktop, Claude Code, the ChatGPT desktop app, Codex, Cursor and other MCP apps can search your saves: *"find the posts I saved about pricing and summarise the advice"*.

1. Click the SomedayX menu bar icon → **AI Apps (MCP)** → **Let AI Apps Search My Saves**. It's off until you turn it on.
2. In the same menu, choose **Connect Claude Desktop**, **Connect ChatGPT Desktop & Codex** or **Connect Cursor** (then reopen that app), or **Copy Claude Code Command**, which copies:
   ```
   claude mcp add --scope user somedayx -- ~/Applications/SomedayX.app/Contents/Resources/somedayx-mcp
   ```
   For other apps, **Copy Setup for Other Apps** copies the JSON config. It's a local stdio server. Apps that aren't installed show as "(not installed)"; SomedayX checks without running them.

**ChatGPT:** works in the **ChatGPT desktop app for Mac** and **Codex** (CLI and IDE extension), which share `~/.codex/config.toml`. It does **not** work in chatgpt.com in a browser or the ChatGPT phone apps: those can only reach MCP servers on the internet, and SomedayX keeps your saves on your Mac.

| Tool | What it does |
|---|---|
| `search_saves` | Search by meaning and keywords, including text in images and X Articles. Takes the same operators as the app (`from:`, `is:like`, `has:image`, `year:`…) |
| `recent_saves` | What you saved lately, with the same filters |
| `get_post` | One post in full: text, image text, quoted post, X Article, links |
| `library_overview` | Counts, date range, top authors and topics |

It's read-only: it opens the database read-only and never syncs, posts, or touches your X session. It works whether or not the SomedayX app is open, and shares the app's search model instead of loading a second copy. Turn sharing off in the same menu and every request is refused.

**Privacy note:** an AI app you connect reads your saved posts to answer you, and cloud-based apps send that text to their servers. Your saves stay on your Mac unless you connect one.

## How it works

1. **Collect.** Playwright drives a Chrome window logged in to *your* X account and reads your Bookmarks and Likes timelines, the same data the X website loads for you. It's read-only: it never posts, likes, follows or clicks anything on a post.
2. **Fetch.** Link titles, quoted posts, images and the full text of X Articles.
3. **Understand.** Apple Vision reads text in images. [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) (via [llama.cpp](https://github.com/ggml-org/llama.cpp)) turns every post *and* image into a search vector. Gemma 4 E2B can optionally write a one-line tl;dr per post.
4. **Search.** Keyword search (SQLite FTS5) and meaning search ([sqlite-vec](https://github.com/asg017/sqlite-vec)) are combined, so both exact words and vague memories work.

The menu bar app is Swift/SwiftUI; the engine is Python (run with `uv`). Everything is in this repo.

## Privacy

- Your saves, images, models and search index live in `~/Library/Application Support/SomedayX`, readable only by your macOS user.
- The only network traffic is to X (to read your saves), to the pages your saved links point to (for their titles), and a one-time model download from Hugging Face. If an identical copy of the model is already on your Mac, SomedayX clones it instead of downloading.
- No analytics, no telemetry, no accounts, no servers.
- AI apps can read your saves only if you turn on **AI Apps (MCP)** and connect one; cloud-based AI apps then send what they read to their servers. Off by default.
- The local search server only answers SomedayX itself: it checks a private access token and refuses requests from web pages.
- That data folder contains a logged-in X browser session. Treat it like a password and don't share it.

## FAQ

**Is this allowed by X?** SomedayX is an unofficial tool, not affiliated with or endorsed by X Corp. It reads your own bookmarks and likes with your own logged-in session, at a human-like pace, much as you would by scrolling. Automated access may still conflict with X's terms; you decide whether to use it, at your own risk.

**Could my account get flagged?** Syncs scroll slowly and back off when X asks them to. The first sync of a big history is the heaviest; after that, a sync stops as soon as it reaches posts it already has. No problems have been seen so far, but no guarantees.

**Why not the official X API?** Reading posts through it is billed per post, and the bookmarks endpoint has historically returned only your latest ~800 bookmarks.

**It broke after an X update.** X changes its website from time to time; please open an issue with `logs/sync.log` from the data folder.

**Windows or Linux?** Not yet. Open a discussion if you'd use it.

## For developers

```sh
uv run python -m somedayx                     # list commands
uv run python -m somedayx search "from:rauchg agents"
uv run python -m somedayx sync --headless     # what the nightly sync runs
uv run python -m somedayx models              # local model status
```

Set `SOMEDAYX_HOME` to keep data somewhere else (handy for testing with an empty library).

## License

MIT. See [LICENSE](LICENSE).
