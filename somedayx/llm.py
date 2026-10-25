"""Local models through llama.cpp's llama-server, each on its own port:

    8766  EmbeddingGemma 2 (+ vision encoder): search vectors for text and images
    8767  Gemma 4 E2B: tl;drs and tags, loaded only while a sync writes them

The search server keeps the embedder running; a sync reuses it, or starts
its own for the duration when run from a terminal.
"""

import base64
import json
import math
import os
import shutil
import subprocess
import time
import urllib.error
import urllib.request
from functools import lru_cache
from pathlib import Path

from . import models
from .db import DATA

LOG_DIR = DATA / "logs"
EMBED_PORT = 8766
WRITER_PORT = 8767
IDLE_SLEEP = 300
TOOL_PATH = os.pathsep.join([os.environ.get("PATH", ""), "/opt/homebrew/bin", "/usr/local/bin"])

# EmbeddingGemma's retrieval prompts (from its model card).
QUERY_PREFIX = "task: search result | query: "
DOC_PREFIX = "title: none | text: "


class ModelUnavailable(RuntimeError):
    pass


def llama_server() -> str | None:
    return shutil.which("llama-server", path=TOOL_PATH)


class Server:
    def __init__(self, name: str, port: int, args: list[str]):
        self.name, self.port, self.args = name, port, args
        self.proc: subprocess.Popen | None = None
        self.adopted: list[int] = []

    @property
    def base(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def alive(self) -> bool:
        try:
            with urllib.request.urlopen(self.base + "/health", timeout=2) as r:
                return r.status == 200
        except Exception:
            return False

    def start(self, timeout: float = 240) -> bool:
        """Start the server unless one is already answering on the port.
        Returns True if this call started it (and so should stop it)."""
        if self.alive():
            return False
        binary = llama_server()
        if not binary:
            raise ModelUnavailable("llama.cpp isn't installed (brew install llama.cpp)")
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        log = open(LOG_DIR / f"llama-{self.name}.log", "ab")
        self.proc = subprocess.Popen(
            [binary, "--host", "127.0.0.1", "--port", str(self.port), *self.args],
            stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.proc.poll() is not None:
                raise ModelUnavailable(f"{self.name} model failed to start; see {LOG_DIR}/llama-{self.name}.log")
            if self.alive():
                return True
            time.sleep(0.5)
        self.stop()
        raise ModelUnavailable(f"{self.name} model didn't start in time")

    def adopt(self) -> None:
        """Take over a server left running (say, by a crashed run) so stop() ends it."""
        out = subprocess.run(["pgrep", "-f", f"llama-server .*--port {self.port} "], capture_output=True, text=True)
        self.adopted = [int(p) for p in out.stdout.split()]

    def stop(self) -> None:
        for pid in self.adopted:
            try:
                os.kill(pid, 15)
            except OSError:
                pass
        self.adopted = []
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.proc = None

    def post(self, route: str, body: dict, timeout: float = 300) -> dict:
        req = urllib.request.Request(self.base + route, json.dumps(body).encode(), {"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"{self.name}: {e.read().decode(errors='replace')[:300]}") from None


def embedder() -> Server:
    return Server("embed", EMBED_PORT, [
        "-m", str(models.path("embeddinggemma-2-Q8_0.gguf")),
        "--mmproj", str(models.path("mmproj-embeddinggemma-2-Q8_0.gguf")),
        "--embeddings", "-c", "4096", "-np", "2", "-b", "2048", "-ub", "2048",
        # A modest vision budget keeps images fast; plenty for search.
        "--image-max-tokens", "256",
        # Give the memory back when nobody's searching; the next search
        # reloads it in a second or two.
        "--sleep-idle-seconds", str(IDLE_SLEEP),
    ])


def writer() -> Server:
    return Server("writer", WRITER_PORT, [
        "-m", str(models.path("gemma-4-E2B-it-Q4_0.gguf")), "-c", "8192", "-np", "2",
    ])


_embed = embedder()


def _normalize(v: list[float]) -> list[float]:
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def embed_texts(texts: list[str], query: bool = False) -> list[list[float]]:
    prefix = QUERY_PREFIX if query else DOC_PREFIX
    out = _embed.post("/v1/embeddings", {"input": [prefix + t for t in texts]})
    return [_normalize(d["embedding"]) for d in sorted(out["data"], key=lambda d: d["index"])]


@lru_cache(maxsize=1)
def _media_marker() -> str:
    # llama-server picks a random marker for where media goes in a prompt.
    with urllib.request.urlopen(_embed.base + "/props", timeout=5) as r:
        return json.load(r)["media_marker"]


def embed_image(p: Path) -> list[float]:
    data = base64.b64encode(p.read_bytes()).decode()
    try:
        marker = _media_marker()
    except Exception:
        _media_marker.cache_clear()
        raise
    out = _embed.post("/v1/embeddings", {"input": [{"prompt_string": marker, "multimodal_data": [data]}]})
    return _normalize(out["data"][0]["embedding"])


def embedder_alive() -> bool:
    return _embed.alive()


def chat_json(server: Server, system: str, user: str, schema: dict, max_tokens: int = 220) -> dict:
    out = server.post("/v1/chat/completions", {
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
        "temperature": 0.2, "max_tokens": max_tokens,
        "response_format": {"type": "json_schema", "json_schema": {"schema": schema}},
        "chat_template_kwargs": {"enable_thinking": False},
    }, timeout=180)
    return json.loads(out["choices"][0]["message"]["content"])
