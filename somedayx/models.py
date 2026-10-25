"""The local models SomedayX runs, and getting them onto this Mac.

Each model is pinned to an exact file (repo revision + SHA-256), because
search vectors from different versions don't mix. Before downloading, we
look for an identical copy already on the Mac and clone it (an APFS clone:
instant and no extra disk space, but still our own file).

    embed   EmbeddingGemma 2 + its vision encoder: search over text and images
    writer  Gemma 4 E2B: optional tl;drs and tags
"""

import hashlib
import json
import shutil
import subprocess
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

from .db import DATA

MODEL_DIR = DATA / "Models"
SETTINGS = DATA / "settings.json"
CHUNK = 4 << 20


@dataclass(frozen=True)
class File:
    name: str
    repo: str
    rev: str
    sha256: str
    size: int

    @property
    def path(self) -> Path:
        return MODEL_DIR / self.name

    @property
    def url(self) -> str:
        return f"https://huggingface.co/{self.repo}/resolve/{self.rev}/{self.name}"


MODELS: dict[str, list[File]] = {
    "embed": [
        File("embeddinggemma-2-Q8_0.gguf", "ggml-org/embeddinggemma-2-GGUF",
             "bfcd298762cc34d0357ece5ebdd31791a3a374d8",
             "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135", 309_855_456),
        File("mmproj-embeddinggemma-2-Q8_0.gguf", "ggml-org/embeddinggemma-2-GGUF",
             "bfcd298762cc34d0357ece5ebdd31791a3a374d8",
             "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f", 554_821_024),
    ],
    "writer": [
        File("gemma-4-E2B-it-Q4_0.gguf", "ggml-org/gemma-4-E2B-it-GGUF",
             "6938c58e698502037401a5f19f6905f2fb2f7dee",
             "8e30dff3ac4c8434c49a7036fa15564bdbb6044e42bf04550bf1a096ad7e6a52", 2_841_481_184),
    ],
}

Progress = Callable[..., None]


# ---------- settings ----------

def settings() -> dict:
    try:
        return {"writer": False, **json.loads(SETTINGS.read_text())}
    except (OSError, ValueError):
        return {"writer": False}


def save_settings(**changes) -> dict:
    s = {**settings(), **changes}
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps(s))
    return s


# ---------- status ----------

def _marker(f: File) -> Path:
    return f.path.with_name(f.name + ".sha256")


def file_ready(f: File) -> bool:
    """Present and verified (the hash is checked once, then remembered)."""
    try:
        return f.path.stat().st_size == f.size and _marker(f).read_text().strip() == f.sha256
    except OSError:
        return False


def ready(kind: str) -> bool:
    return all(file_ready(f) for f in MODELS[kind])


def size(kind: str) -> int:
    return sum(f.size for f in MODELS[kind])


def path(name: str) -> Path:
    return MODEL_DIR / name


# ---------- finding a copy already on this Mac ----------

def _candidates(f: File) -> list[Path]:
    found: set[Path] = set()
    try:
        out = subprocess.run(["mdfind", f"kMDItemFSName == '{f.name}'"], capture_output=True, text=True, timeout=20)
        found |= {Path(p) for p in out.stdout.splitlines() if p}
    except (OSError, subprocess.SubprocessError):
        pass
    # Spotlight skips hidden folders, where model caches usually live.
    home = Path.home()
    repo_dir = "models--" + f.repo.replace("/", "--")
    for pattern in (f".cache/huggingface/hub/{repo_dir}/snapshots/*/{f.name}",
                    f".cache/lm-studio/models/**/{f.name}", f".lmstudio/models/**/{f.name}",
                    f"Library/Application Support/*/Models/{f.name}",
                    f"Library/Application Support/*/models/{f.name}"):
        found |= set(home.glob(pattern))
    return [p.resolve() for p in found
            if p.resolve() != f.path.resolve() and p.is_file() and p.stat().st_size == f.size]


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        while chunk := fh.read(CHUNK):
            h.update(chunk)
    return h.hexdigest()


def found_on_mac(kind: str) -> bool:
    """Cheap check (name and size) for the onboarding screen."""
    return all(file_ready(f) or _candidates(f) for f in MODELS[kind])


def _clone(src: Path, dst: Path) -> None:
    tmp = dst.with_name(dst.name + ".part")
    tmp.unlink(missing_ok=True)
    # cp -c makes an APFS clone; plain copy where cloning isn't possible.
    if subprocess.run(["cp", "-c", str(src), str(tmp)], capture_output=True).returncode != 0:
        shutil.copyfile(src, tmp)
    tmp.replace(dst)


# ---------- downloading ----------

def _download(f: File, progress: Progress) -> None:
    tmp = f.path.with_name(f.name + ".part")
    have = tmp.stat().st_size if tmp.exists() else 0
    if have > f.size:
        tmp.unlink()
        have = 0
    req = urllib.request.Request(f.url, headers={"User-Agent": "SomedayX", **({"Range": f"bytes={have}-"} if have else {})})
    with urllib.request.urlopen(req, timeout=60) as resp:
        if have and resp.status != 206:  # server ignored the range: start over
            have = 0
        with open(tmp, "ab" if have else "wb") as out:
            while chunk := resp.read(CHUNK):
                out.write(chunk)
                have += len(chunk)
                progress(done=have, total=f.size)
    tmp.replace(f.path)


def install(kind: str, progress: Progress = lambda **kw: None) -> str:
    """Make every file of `kind` ready. Returns how: 'ready', 'found' or
    'downloaded'. Raises on failure (no space, network, bad checksum)."""
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    how = "ready"
    files = [f for f in MODELS[kind] if not file_ready(f)]
    total = sum(f.size for f in files)
    done = 0
    for f in files:
        if f.path.exists() and f.path.stat().st_size == f.size:
            # Already here but not yet verified (say, an earlier run stopped).
            progress(state="verifying", done=done, total=total)
            if _sha256(f.path) == f.sha256:
                _marker(f).write_text(f.sha256)
                done += f.size
                continue
        progress(state="finding", done=done, total=total)
        source = None
        for cand in _candidates(f):
            progress(state="verifying", done=done, total=total)
            if _sha256(cand) == f.sha256:
                source = cand
                break
        if source:
            progress(state="copying", done=done, total=total)
            _clone(source, f.path)
            how = "found" if how != "downloaded" else how
        else:
            free = shutil.disk_usage(MODEL_DIR).free
            if free < f.size + (512 << 20):
                raise OSError(f"not enough disk space: {f.size / 1e9:.1f} GB needed, {free / 1e9:.1f} GB free")
            _download(f, lambda done, total, base=done, overall=total:
                      progress(state="downloading", done=base + done, total=overall))
            how = "downloaded"
        progress(state="verifying", done=done + f.size, total=total)
        if _sha256(f.path) != f.sha256:
            f.path.unlink(missing_ok=True)
            raise ValueError(f"{f.name} didn't match its checksum; it was removed, try again")
        _marker(f).write_text(f.sha256)
        done += f.size
    progress(state="ready", done=total, total=total)
    return how


def remove(kind: str) -> None:
    for f in MODELS[kind]:
        f.path.unlink(missing_ok=True)
        _marker(f).unlink(missing_ok=True)
        f.path.with_name(f.name + ".part").unlink(missing_ok=True)
