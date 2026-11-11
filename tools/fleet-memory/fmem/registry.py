"""Customer registry: canonical customers with aliases, speech-recognition mishearings, geography, products, repos.

customers.toml (editable) holds `[[customer]]` tables:

    id          stable slug, used as the facet value
    name        canonical display name
    aliases     names that identify the customer in documents AND queries (strong)
    mishearings speech-recognition slips, query side only (FGIC -> FDIC)
    keywords    loose query-side hints (agency nicknames, topics); never tag documents
    geography   places; query side only ("university in Georgia")
    products    products/themes worked with this customer (informational, shown by `registry show`)
    repos       repo directory names; a path containing one tags the document
    vault_note  relative path of the customer note in the Work vault (informational)

Document tagging uses name + aliases + repos. Query analysis additionally uses mishearings,
keywords and geography.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from . import config

LIST_FIELDS = ("aliases", "mishearings", "keywords", "geography", "products", "repos")
GENERIC_TAGS = {
    "customer", "federal", "education", "internal", "reference", "agent-fabric", "mcp", "idp", "api-led",
    "agent-governance", "mulesoft", "world-cup", "higher-ed", "state-local", "healthcare", "transportation",
}


def norm(s: str) -> str:
    """Lowercase, punctuation to spaces, collapsed. Used for both terms and haystacks."""
    return " " + re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", s.lower())).strip() + " "


def slug(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


@dataclass
class Customer:
    id: str
    name: str
    aliases: list[str] = field(default_factory=list)
    mishearings: list[str] = field(default_factory=list)
    keywords: list[str] = field(default_factory=list)
    geography: list[str] = field(default_factory=list)
    products: list[str] = field(default_factory=list)
    repos: list[str] = field(default_factory=list)
    vault_note: str = ""

    def doc_terms(self) -> list[str]:
        return [self.name, *self.aliases, *self.repos]

    def query_terms(self) -> list[str]:
        return [*self.doc_terms(), *self.mishearings, *self.keywords, *self.geography]


def _compile(pairs: list[tuple[str, str]]) -> tuple[re.Pattern | None, dict[str, set[str]]]:
    by_term: dict[str, set[str]] = {}
    for cid, term in pairs:
        t = norm(term).strip()
        if len(t) >= 2:
            by_term.setdefault(t, set()).add(cid)
    if not by_term:
        return None, {}
    alt = "|".join(re.escape(t) for t in sorted(by_term, key=len, reverse=True))
    return re.compile(rf"(?<![a-z0-9])(?:{alt})(?![a-z0-9])"), by_term


class Registry:
    def __init__(self, customers: list[Customer]):
        self.customers = customers
        self.by_id = {c.id: c for c in customers}
        self._doc = _compile([(c.id, t) for c in customers for t in c.doc_terms()])
        self._qry = _compile([(c.id, t) for c in customers for t in c.query_terms()])

    @staticmethod
    def _find(compiled, haystack: str) -> list[str]:
        pat, by_term = compiled
        if pat is None:
            return []
        found: list[str] = []
        for m in pat.finditer(norm(haystack)):
            for cid in sorted(by_term[m.group(0).strip()]):
                if cid not in found:
                    found.append(cid)
        return found

    def tag_document(self, path: str, title: str, text: str) -> list[str]:
        """Customer facet at index time: path + title + first 3000 chars."""
        return self._find(self._doc, f"{path} {title} {text[:3000]}")

    def analyze_query(self, query: str) -> tuple[list[str], list[str]]:
        """(customer ids detected, words to append to the search query)."""
        ids = self._find(self._qry, query)
        qn = norm(query)
        extra: list[str] = []
        for cid in ids:
            c = self.by_id[cid]
            for term in [c.name, *c.aliases[:5]]:
                tn = norm(term)
                if len(tn.strip()) > 3 and tn not in qn and term not in extra:
                    extra.append(term)
        return ids, extra


def _coerce(d: dict) -> Customer:
    if "id" not in d or "name" not in d:
        raise ValueError(f"customer entry needs id and name: {d!r}")
    kw = {f: [str(x) for x in d.get(f, [])] for f in LIST_FIELDS}
    return Customer(id=str(d["id"]), name=str(d["name"]), vault_note=str(d.get("vault_note", "")), **kw)


def load(path: Path | None = None) -> Registry:
    p = path or config.live_or_default(config.paths().customers, "customers.example.toml")
    data = config.load_toml(p)
    return Registry([_coerce(d) for d in data.get("customer", [])])


# ---------------------------------------------------------------- seeding from the vault

def _frontmatter(path: Path) -> dict:
    import yaml
    raw = path.read_text(errors="ignore")
    m = re.match(r"^---\n(.*?)\n---\n", raw, re.S)
    if not m:
        return {}
    try:
        d = yaml.safe_load(m.group(1))
    except yaml.YAMLError:
        return {}
    return d if isinstance(d, dict) else {}


def seed_from_vault(vault_customers: Path) -> list[Customer]:
    """One Customer per Work/Customers/*.md note. Read-only on the vault."""
    out = []
    for f in sorted(Path(vault_customers).glob("*.md")):
        fm = _frontmatter(f)
        if "customer" not in (fm.get("tags") or []):
            continue
        title = str(fm.get("title") or f.stem)
        names = [title, f.stem]
        for part in re.split(r"\s*/\s*|\s+-\s+", title):
            names.append(part)
        tn = norm(title)
        for t in fm.get("tags") or []:
            t = str(t)
            if t in GENERIC_TAGS:
                continue
            if norm(t) in tn and len(norm(t).strip()) >= 3:
                names.append(t.replace("-", " "))
        names = [n for n in dict.fromkeys(x.strip() for x in names if x and x.strip())]
        out.append(Customer(id=slug(f.stem), name=title, aliases=[n for n in names if n != title],
                            vault_note=f"Customers/{f.name}"))
    return out


def _toml_list(xs: list[str]) -> str:
    return "[" + ", ".join('"' + x.replace("\\", "\\\\").replace('"', '\\"') + '"' for x in xs) + "]"


def render_entry(c: Customer) -> str:
    lines = ["[[customer]]", f'id = "{c.id}"', f'name = {_toml_list([c.name])[1:-1]}']
    for f in LIST_FIELDS:
        v = getattr(c, f)
        if v:
            lines.append(f"{f} = {_toml_list(v)}")
    if c.vault_note:
        lines.append(f'vault_note = {_toml_list([c.vault_note])[1:-1]}')
    return "\n".join(lines) + "\n"


def merge_seed(path: Path, seeded: list[Customer]) -> list[str]:
    """Append seeded customers not already present (matched by id or name). Never edits existing entries."""
    existing = load(path) if path.exists() else Registry([])
    have_ids = set(existing.by_id)
    have_names = {norm(c.name) for c in existing.customers}
    new = [c for c in seeded if c.id not in have_ids and norm(c.name) not in have_names]
    if new:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a") as f:
            if path.exists() and path.stat().st_size:
                f.write("\n")
            f.write("\n".join(render_entry(c) for c in new))
    return [c.id for c in new]
