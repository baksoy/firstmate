"""Paths and settings. No heavy imports: the resident-server client uses this module."""
from __future__ import annotations

import hashlib
import os
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parents[1]          # tools/fleet-memory
REPO_ROOT = TOOL_DIR.parents[1]                         # firstmate code root
DEFAULTS_DIR = TOOL_DIR / "defaults"

DEFAULT_SETTINGS = {
    "embed_model": "sentence-transformers/all-MiniLM-L6-v2",
    "rerank_model": "cross-encoder/ms-marco-MiniLM-L-6-v2",
    "max_seq_length": 384,
    "confident_gate": -6.0,    # reranker score at or above: confident tier
    "low_gate": -8.6,          # between low_gate and confident_gate: closest-matches tier
    "pool": 20,                # RRF candidate pool (chunks)
    "per_leg": 30,             # vector and FTS depth before fusion
    "rrf_k": 60,
    "chunks_per_doc": 20,      # rerank every chunk of the pool (a doc's best chunk is often not its top-3 by RRF)
    "customer_boost": 0.004,   # RRF bonus when query and chunk share a registry customer
    "k": 3,                    # pointers returned
    "rescue_rules": 2,         # distinct thesaurus concepts a query must name, and a document corroborate, to rescue a hit
    "rescue_cover": 0.5,       # share of a concept's document nouns the document must contain to count as corroborating
}


def fm_home() -> Path:
    return Path(os.environ.get("FM_HOME") or REPO_ROOT)


def mem_home() -> Path:
    env = os.environ.get("FM_MEMORY_HOME")
    return Path(env) if env else fm_home() / "data" / "fleet-memory"


@dataclass(frozen=True)
class Paths:
    home: Path

    @property
    def db(self) -> Path: return self.home / "lancedb"
    @property
    def manifest(self) -> Path: return self.home / "manifest.json"
    @property
    def sources(self) -> Path: return self.home / "sources.toml"
    @property
    def thesaurus(self) -> Path: return self.home / "thesaurus.tsv"
    @property
    def customers(self) -> Path: return self.home / "customers.toml"
    @property
    def settings(self) -> Path: return self.home / "settings.toml"
    @property
    def eval_set(self) -> Path: return self.home / "eval.toml"
    @property
    def run(self) -> Path: return self.home / "run"
    @property
    def pidfile(self) -> Path: return self.run / "fmem.pid"
    @property
    def logfile(self) -> Path: return self.run / "fmem.log"

    @property
    def sock(self) -> Path:
        """Unix socket path; AF_UNIX paths are short-limited on macOS, so long homes fall back to a hashed tmp name."""
        p = self.run / "fmem.sock"
        if len(str(p)) <= 100:
            return p
        h = hashlib.sha1(str(self.home).encode()).hexdigest()[:10]
        return Path(tempfile.gettempdir()) / f"fmem-{h}.sock"

    def models(self, name: str) -> Path: return self.home / "models" / name


def paths() -> Paths:
    return Paths(mem_home())


def load_toml(path: Path) -> dict:
    with open(path, "rb") as f:
        return tomllib.load(f)


def live_or_default(live: Path, default_name: str) -> Path:
    """The editable copy in the memory home wins; the tracked default is the fallback."""
    return live if live.exists() else DEFAULTS_DIR / default_name


def load_settings(p: Paths | None = None) -> dict:
    p = p or paths()
    s = dict(DEFAULT_SETTINGS)
    if p.settings.exists():
        s.update(load_toml(p.settings))
    return s
