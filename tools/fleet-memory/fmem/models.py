"""Offline model loading. Policy: only the two approved MiniLM models, never downloaded.

Resolution order for each model: <memory home>/models/<name> (a directory or symlink), then the local
Hugging Face cache. HF_HUB_OFFLINE=1 is forced so a missing model fails loudly instead of fetching.
"""
from __future__ import annotations

import os
from pathlib import Path

from . import config

APPROVED = {
    "embed": ("minilm", "sentence-transformers/all-MiniLM-L6-v2"),
    "rerank": ("ce-minilm", "cross-encoder/ms-marco-MiniLM-L-6-v2"),
}


def _offline() -> None:
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


def hf_cache_snapshot(repo_id: str) -> Path | None:
    """Newest cached snapshot that actually holds weights."""
    hub = Path(os.environ.get("HF_HOME") or Path.home() / ".cache" / "huggingface") / "hub"
    snaps = hub / f"models--{repo_id.replace('/', '--')}" / "snapshots"
    if not snaps.is_dir():
        return None
    good = [s for s in snaps.iterdir()
            if (s / "config.json").exists() and any((s / w).exists() for w in ("model.safetensors", "pytorch_model.bin"))]
    return max(good, key=lambda s: s.stat().st_mtime) if good else None


def link_models(p: config.Paths | None = None) -> dict[str, str]:
    """Symlink the cached snapshots into <home>/models so the tool never depends on cache layout again."""
    p = p or config.paths()
    out = {}
    for _, (name, repo) in APPROVED.items():
        snap = hf_cache_snapshot(repo)
        if snap is None:
            raise SystemExit(f"{repo} is not in the local Hugging Face cache; fetch it once with the approved "
                             f"tooling, this tool never downloads models")
        dest = p.models(name)
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.is_symlink() or dest.exists():
            if dest.is_symlink():
                dest.unlink()
            else:
                out[name] = f"{dest} (exists, left alone)"
                continue
        dest.symlink_to(snap)
        out[name] = f"{dest} -> {snap}"
    return out


def _resolve(kind: str, p: config.Paths) -> str:
    name, repo = APPROVED[kind]
    local = p.models(name)
    if local.exists():
        return str(local)
    return repo


def load_embedder(p: config.Paths | None = None, max_seq_length: int = 384):
    _offline()
    from sentence_transformers import SentenceTransformer
    p = p or config.paths()
    m = SentenceTransformer(_resolve("embed", p), device="cpu")
    m.max_seq_length = max_seq_length
    return m


def load_reranker(p: config.Paths | None = None):
    _offline()
    from sentence_transformers import CrossEncoder
    p = p or config.paths()
    return CrossEncoder(_resolve("rerank", p), device="cpu")
