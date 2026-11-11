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


def matched(query: str, rules: list[Rule]) -> list[Rule]:
    """The rules whose lay terms occur in the query: each one is a distinct concept the query names in lay words."""
    ql = query.lower()
    return [r for r in rules if r.pattern.search(ql)]


def _stem(word: str) -> str:
    word = word.lower()
    return word[:-1] if len(word) > 3 and word.endswith("s") else word


def corroborated(rules: list[Rule], doc_words: set[str], cover: float) -> int:
    """How many matched rules the document corroborates: at least `cover` of the rule's document nouns appear in it.

    A document that holds the nouns for several different lay concepts of the question is a real neighbour of the
    question even when the question shares no keyword with it; off-topic junk names at most one concept.
    """
    words = {_stem(w) for w in doc_words}
    n = 0
    for r in rules:
        terms = {_stem(t) for t in r.terms}
        if terms and len(terms & words) / len(terms) >= cover:
            n += 1
    return n
