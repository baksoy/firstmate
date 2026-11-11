"""Text extraction and heading-aware chunking (read-only on sources)."""
from __future__ import annotations

import re
from pathlib import Path

MAX_FILE_BYTES = 400_000          # cap per file after extraction
GENERIC_STEMS = {"README", "AGENTS", "CLAUDE", "WALKTHROUGH", "DECK", "report", "brief"}


def html_to_text(raw: str) -> str:
    from bs4 import BeautifulSoup   # deferred: only HTML needs it
    soup = BeautifulSoup(raw, "lxml")
    for t in soup(["script", "style", "svg", "noscript", "head", "template"]):
        t.decompose()
    for h in soup.find_all(re.compile(r"^h[1-4]$")):
        lvl = int(h.name[1])
        h.insert_before("\n\n" + "#" * lvl + " ")
        h.append("\n")
    for b in soup.find_all(["p", "li", "tr", "div", "section", "br"]):
        b.append("\n")
    txt = soup.get_text(" ")
    txt = re.sub(r"[ \t\r\f\v]+", " ", txt)
    txt = re.sub(r"\n\s*\n+", "\n\n", txt)
    return txt.strip()


def clean_text(raw: str, is_html: bool) -> tuple[str, str]:
    """Return (body, frontmatter). Frontmatter is stripped from the body."""
    if is_html:
        raw = html_to_text(raw)
    fm = ""
    m = re.match(r"^---\n(.*?)\n---\n", raw, re.S)
    if m:
        fm = m.group(1)
        raw = raw[m.end():]
    raw = re.sub(r"!\[\[.*?\]\]", "", raw)                                  # obsidian embeds
    raw = re.sub(r"data:[a-z/+-]+;base64,[A-Za-z0-9+/=]{100,}", "", raw)    # inline blobs
    raw = re.sub(r"\n{3,}", "\n\n", raw)
    return raw[:MAX_FILE_BYTES], fm


def read_text(path: str) -> tuple[str, str]:
    with open(path, "r", errors="ignore") as f:
        raw = f.read()
    return clean_text(raw, path.lower().endswith((".html", ".htm")))


def doc_title(path: str, text: str) -> str:
    """Generic names (README, WALKTHROUGH...) borrow the parent directory so titles identify the artifact."""
    p = Path(path)
    base = p.stem
    if base in GENERIC_STEMS:
        return f"{p.parent.name}/{p.name}"
    if base.lower() == "index":
        m = re.search(r"^#\s+(.+)$", text, re.M)
        return m.group(1).strip()[:90] if m else base
    return base


def chunk_markdown(text: str, target: int = 1100, overlap: int = 120) -> list[tuple[str, str]]:
    """Split on headings, then pack paragraphs to ~target chars. Returns [(heading_path, body)]."""
    sections: list[tuple[str, str]] = []
    cur_head, buf, stack = "", [], []

    def flush():
        body = "\n".join(buf).strip()
        if body:
            sections.append((cur_head, body))

    for ln in text.split("\n"):
        m = re.match(r"^(#{1,4})\s+(.*)", ln)
        if m:
            flush()
            buf.clear()
            lvl = len(m.group(1))
            stack[:] = stack[: lvl - 1] + [m.group(2).strip()]
            cur_head = " > ".join(stack)
        else:
            buf.append(ln)
    flush()

    chunks: list[tuple[str, str]] = []
    for head, body in sections:
        if len(body) <= target * 1.3:
            chunks.append((head, body))
            continue
        cur = ""
        for p in re.split(r"\n\s*\n", body):
            if len(cur) + len(p) > target and cur:
                chunks.append((head, cur.strip()))
                cur = cur[-overlap:] + "\n" + p
            else:
                cur += ("\n\n" if cur else "") + p
            while len(cur) > target * 2:                   # one giant paragraph
                chunks.append((head, cur[:target]))
                cur = cur[target - overlap:]
        if cur.strip():
            chunks.append((head, cur.strip()))

    merged: list[tuple[str, str]] = []
    for h, c in chunks:
        if merged and len(c) < 200 and merged[-1][0] == h:
            merged[-1] = (h, merged[-1][1] + "\n" + c)
        else:
            merged.append((h, c))
    return merged


def contextualise(title: str, path: str, heading: str, body: str) -> str:
    """Chunk text actually embedded and reranked: title + parent dir + heading keep the which-doc signal."""
    return f"{title} | {Path(path).parent.name} | {heading}\n{body}"
