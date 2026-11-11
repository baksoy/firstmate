"""Corpus definition, crawl, and duplicate canonicalization. Strictly read-only on every source."""
from __future__ import annotations

import hashlib
import os
from dataclasses import dataclass, field
from pathlib import Path

from . import config

# Directories never descended into, whatever the rule.
SKIP_DIRS = {
    "node_modules", "target", "_archive", "attachments", "venv", "site-packages", "dist", "build",
    "__pycache__", "Pods", "vendor", "coverage",
}


@dataclass
class Rule:
    group: str
    roots: list[str]
    names: list[str] = field(default_factory=list)        # exact file names (empty = any name)
    exts: list[str] = field(default_factory=list)         # lowercase suffixes incl. dot (empty = any)
    maxdepth: int | None = None                           # dir levels below the root (0 = root only)
    mindepth: int = 0                                     # skip files fewer dir levels below the root (1 = not loose root files)
    require_part: str = ""                                # a path component that must equal this (e.g. docs)
    exclude_names: list[str] = field(default_factory=list)
    exclude_parts: list[str] = field(default_factory=list)  # substring match on the full path
    weight: float = 1.0                                   # multiplies the RRF score of this group's chunks


def expand_root(s: str) -> str:
    home = str(Path.home())
    fm = str(config.fm_home())
    bm = os.environ.get("FM_MEMORY_BUILDHOME") or str(Path(home) / ".treehouse/firstmate-7bab20/2/firstmate")
    return (s.replace("{FM}", fm).replace("{BUILDMATE}", bm).replace("~", home, 1)
            if s.startswith(("~", "{")) else s)


def load_rules(path: Path | None = None) -> list[Rule]:
    p = path or config.live_or_default(config.paths().sources, "sources.toml")
    out = []
    for d in config.load_toml(p).get("source", []):
        out.append(Rule(
            group=d["group"], roots=list(d["roots"]), names=list(d.get("names", [])),
            exts=[e.lower() for e in d.get("exts", [])], maxdepth=d.get("maxdepth"), mindepth=int(d.get("mindepth", 0)),
            require_part=d.get("require_part", ""), exclude_names=list(d.get("exclude_names", [])),
            exclude_parts=list(d.get("exclude_parts", [])), weight=float(d.get("weight", 1.0)),
        ))
    return out


def _match(rule: Rule, path: str, name: str) -> bool:
    if rule.names and name not in rule.names:
        return False
    if rule.exts and Path(name).suffix.lower() not in rule.exts:
        return False
    if name in rule.exclude_names:
        return False
    if any(x in path for x in rule.exclude_parts):
        return False
    if rule.require_part and rule.require_part not in Path(path).parts[:-1]:
        return False
    return True


def crawl(rules: list[Rule]) -> list[tuple[str, str, int]]:
    """[(group, path, rule_index)] in rule order. Symlinked dirs are not followed; realpath dupes dropped."""
    out, seen = [], set()
    for idx, rule in enumerate(rules):
        for root in rule.roots:
            root = expand_root(root)
            if not os.path.isdir(root):
                continue
            base_depth = root.rstrip(os.sep).count(os.sep)
            for dp, dn, fn in os.walk(root):
                depth = dp.rstrip(os.sep).count(os.sep) - base_depth
                dn[:] = sorted(d for d in dn if d not in SKIP_DIRS and not d.startswith("."))
                if rule.maxdepth is not None and depth >= rule.maxdepth:
                    dn[:] = []
                if depth < rule.mindepth:
                    continue
                for f in sorted(fn):
                    p = os.path.join(dp, f)
                    if not _match(rule, p, f):
                        continue
                    rp = os.path.realpath(p)
                    if rp in seen or not os.path.isfile(rp):
                        continue
                    seen.add(rp)
                    out.append((rule.group, p, idx))
    return out


# --------------------------------------------------------------------- canonicalization

def sha1_file(path: str) -> str:
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


_repo_cache: dict[str, str | None] = {}


def repo_key(path: str, stop: str = "/") -> str | None:
    """`<repo-dir-name>/<relpath>` for files inside a git repo that is not itself a firstmate home.

    The same repo checked out in two places (live ~/Development/... and a treehouse copy) yields the same key,
    which is how copies that have drifted by a few bytes still collapse into one pointer.
    """
    d = os.path.dirname(path)
    while d and d != stop and d != os.path.dirname(d):
        if d in _repo_cache:
            root = _repo_cache[d]
        else:
            root = d if os.path.lexists(os.path.join(d, ".git")) else None
            _repo_cache[d] = root
        if root:
            if os.path.exists(os.path.join(root, "bin", "fm-session-start.sh")):
                return None                        # a firstmate home: data/ differs per home, never merge
            return f"{os.path.basename(root)}/{os.path.relpath(path, root)}"
        d = os.path.dirname(d)
    return None


def elect(entries: dict[str, dict]) -> dict[str, str]:
    """Map every path to its canonical path.

    entries[path] = {sha1, rkey, prio, mtime}. Two paths are the same artifact when they share a content hash or a
    repo key. Winner: best (lowest) rule priority, then live Development paths over treehouse copies, then newest.
    """
    parent = {p: p for p in entries}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    for field_name in ("sha1", "rkey"):
        first: dict[str, str] = {}
        for p, e in entries.items():
            k = e.get(field_name)
            if not k:
                continue
            if k in first:
                parent[find(p)] = find(first[k])
            else:
                first[k] = p
    groups: dict[str, list[str]] = {}
    for p in entries:
        groups.setdefault(find(p), []).append(p)

    def rank(p):
        e = entries[p]
        treehouse = "/.treehouse/" in p
        return (treehouse, e["prio"], -e["mtime"], len(p), p)

    canon = {}
    for members in groups.values():
        win = min(members, key=rank)
        for m in members:
            canon[m] = win
    return canon
