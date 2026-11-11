"""Query-expansion thesaurus: lay words -> the nouns the documents actually use.

File format (thesaurus.tsv, one rule per line, `#` starts a comment):

    cheat, scam*, shady  =>  fraud waste abuse FWA improper payments

Left of `=>` are comma-separated lay terms; right are the terms appended to the SEARCH query
(never shown to the reranker). A term matches whole words, plural allowed (`bot` matches `bots`).
A trailing `*` makes it a prefix match (`scam*` matches scam, scams, scammer). A space inside a
term matches a space or hyphen (`rip off` matches `rip-off`).
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Rule:
    pattern: re.Pattern
    terms: tuple[str, ...]
    source: str


def _term_regex(term: str) -> str:
    term = term.strip().lower()
    prefix = term.endswith("*")
    term = term.rstrip("*").strip()
    body = r"[\s-]+".join(re.escape(w) for w in term.split())
    return rf"(?<![a-z0-9]){body}\w*" if prefix else rf"(?<![a-z0-9]){body}(?:e?s)?(?![a-z0-9])"


def parse(text: str) -> list[Rule]:
    rules = []
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "=>" not in line:
            raise ValueError(f"thesaurus line {n}: expected 'terms => expansion': {raw!r}")
        left, right = line.split("=>", 1)
        lay = [t for t in (x.strip() for x in left.split(",")) if t]
        exp = tuple(right.split())
        if not lay or not exp:
            raise ValueError(f"thesaurus line {n}: empty side: {raw!r}")
        pat = re.compile("|".join(_term_regex(t) for t in lay))
        rules.append(Rule(pat, exp, line))
    return rules


def load(path: Path) -> list[Rule]:
    return parse(Path(path).read_text())


def expand(query: str, rules: list[Rule]) -> list[str]:
    """Expansion words for the query, deduplicated, in rule order."""
    ql = query.lower()
    out: list[str] = []
    for r in rules:
        if r.pattern.search(ql):
            out.extend(r.terms)
    return list(dict.fromkeys(out))
