"""Index builder: cold rebuild and incremental refresh over an mtime/hash manifest.

Read-only on every source file. Writes only inside the memory home (lancedb/, manifest.json).

Manifest (manifest.json) per crawled path: size, mtime_ns, sha1, group, state, isha, canon.
  state  indexed - rows exist for this path (it is the canonical copy of its artifact)
         alias   - another path is the canonical copy; `canon` names it; nothing indexed here
         empty   - extracted text too short to be useful
         error   - unreadable; retried on the next refresh
Deleted paths are tombstoned by deleting their rows and dropping the manifest entry.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
from pathlib import Path

from . import config, extract, registry as registry_mod, sources, models

TABLE = "chunks"
SCHEMA_VERSION = 2            # bump when chunking/extraction/columns change: forces a rebuild
MIN_TEXT = 40
DIM = 384


def _schema():
    import pyarrow as pa
    return pa.schema([
        ("path", pa.string()), ("group", pa.string()), ("title", pa.string()), ("heading", pa.string()),
        ("text", pa.string()), ("ctx", pa.string()), ("mtime", pa.string()), ("entities", pa.string()),
        ("weight", pa.float32()), ("chunk_no", pa.int32()), ("vector", pa.list_(pa.float32(), DIM)),
    ])


def _h(s: str) -> str:
    return hashlib.sha1(s.encode("utf-8", "ignore")).hexdigest()


def registry_fingerprint(reg: registry_mod.Registry) -> str:
    parts = [f"{c.id}|{c.name}|{','.join(c.doc_terms())}" for c in sorted(reg.customers, key=lambda c: c.id)]
    return _h("\n".join(parts))


def load_manifest(p: config.Paths) -> dict:
    if not p.manifest.exists():
        return {}
    return json.loads(p.manifest.read_text())


def save_manifest(p: config.Paths, m: dict) -> None:
    p.home.mkdir(parents=True, exist_ok=True)
    tmp = p.manifest.with_suffix(".tmp")
    tmp.write_text(json.dumps(m, indent=1, sort_keys=True))
    os.replace(tmp, p.manifest)


def _sql_in(paths) -> str:
    return ", ".join("'" + x.replace("'", "''") + "'" for x in paths)


def _rows_for(path: str, group: str, weight: float, reg: registry_mod.Registry, mtime: float):
    text, _fm = extract.read_text(path)
    if len(text.strip()) < MIN_TEXT:
        return None
    title = extract.doc_title(path, text)
    ents = ",".join(reg.tag_document(path, title, text))
    date = time.strftime("%Y-%m-%d", time.localtime(mtime))
    rows = []
    for i, (head, body) in enumerate(extract.chunk_markdown(text)):
        rows.append(dict(path=path, group=group, title=title, heading=head, text=body,
                         ctx=extract.contextualise(title, path, head, body), mtime=date, entities=ents,
                         weight=float(weight), chunk_no=i))
    return rows


def run(mode: str = "refresh", log=print, p: config.Paths | None = None, dry_run: bool = False) -> dict:
    """mode 'refresh' (incremental) or 'rebuild' (cold). Returns a summary dict."""
    p = p or config.paths()
    t0 = time.time()
    settings = config.load_settings(p)
    rules = sources.load_rules()
    reg = registry_mod.load()
    reg_fp = registry_fingerprint(reg)
    old = {} if mode == "rebuild" else load_manifest(p)
    meta = old.get("_meta", {})
    files_old = old.get("files", {})
    force_all = mode == "rebuild" or not files_old
    if not force_all and (meta.get("schema") != SCHEMA_VERSION or meta.get("embed_model") != settings["embed_model"]):
        log("schema or model changed since the last build: doing a full re-embed")
        force_all = True
    retag = force_all or meta.get("registry") != reg_fp
    if retag and not force_all:
        log("customer registry changed: re-tagging every document (unchanged text keeps its vectors)")

    # ---- crawl + stat + hash (hash only when stat changed)
    crawled = sources.crawl(rules)
    weights = {i: r.weight for i, r in enumerate(rules)}
    entries: dict[str, dict] = {}
    for group, path, idx in crawled:
        try:
            st = os.stat(path)
        except OSError:
            continue
        o = files_old.get(path)
        if o and o.get("mtime_ns") == st.st_mtime_ns and o.get("size") == st.st_size and not force_all:
            sha = o["sha1"]
        else:
            try:
                sha = sources.sha1_file(path)
            except OSError:
                continue
        entries[path] = dict(sha1=sha, rkey=sources.repo_key(path), prio=idx, mtime=st.st_mtime, group=group,
                             size=st.st_size, mtime_ns=st.st_mtime_ns, weight=weights[idx])
    canon = sources.elect(entries)
    desired = {q for q, c in canon.items() if c == q}

    # ---- plan
    to_remove, to_add = set(), []
    for q, o in files_old.items():
        if o.get("state") == "indexed" and (q not in desired or force_all or retag
                                            or (q in entries and entries[q]["sha1"] != o.get("isha"))):
            to_remove.add(q)
    for q in sorted(desired):
        o = files_old.get(q)
        if (force_all or retag or o is None or o.get("state") in ("alias", "error")
                or o.get("isha") != entries[q]["sha1"]):
            to_add.append(q)
    plan = dict(crawled=len(entries), canonical=len(desired), duplicates=len(entries) - len(desired),
                add=len(to_add), remove=len(to_remove - set(to_add)), mode=mode)
    log(f"crawl: {plan['crawled']} files, {plan['canonical']} distinct artifacts "
        f"({plan['duplicates']} duplicates collapsed); to (re)index {plan['add']}, tombstone {plan['remove']}")
    if dry_run:
        return plan

    # ---- vector cache from rows about to be dropped
    import lancedb
    import numpy as np
    cache: dict[str, list[float]] = {}
    db_exists = p.db.exists() and not mode == "rebuild"
    db = None
    if db_exists:
        db = lancedb.connect(str(p.db))
        if TABLE not in db.table_names():
            db_exists = False
    if db_exists:
        tbl = db.open_table(TABLE)
        arrow = tbl.to_arrow() if (retag or force_all) else None
        if arrow is not None:
            for c, v in zip(arrow["ctx"].to_pylist(), arrow["vector"].to_pylist()):
                cache[_h(c)] = v
        elif to_remove:
            sel = tbl.search().where(f"path IN ({_sql_in(sorted(to_remove))})").select(["ctx", "vector"]).limit(10**7).to_arrow()
            for c, v in zip(sel["ctx"].to_pylist(), sel["vector"].to_pylist()):
                cache[_h(c)] = v

    # ---- extract + chunk
    new_rows, new_state = [], {}
    for q in to_add:
        e = entries[q]
        try:
            rows = _rows_for(q, e["group"], e["weight"], reg, e["mtime"])
        except Exception as ex:                                  # unreadable file must not sink the run
            log(f"  skip {q}: {ex}")
            new_state[q] = "error"
            continue
        if rows is None:
            new_state[q] = "empty"
        else:
            new_rows.extend(rows)
            new_state[q] = "indexed"

    # ---- embed only what has no cached vector
    need = [r for r in new_rows if _h(r["ctx"]) not in cache]
    if need:
        log(f"embedding {len(need)} chunks ({len(new_rows) - len(need)} reused)")
        model = models.load_embedder(p, settings["max_seq_length"])
        vecs = model.encode([r["ctx"] for r in need], batch_size=32, normalize_embeddings=True,
                            show_progress_bar=False)
        for r, v in zip(need, vecs):
            cache[_h(r["ctx"])] = v.astype(np.float32).tolist()
    for r in new_rows:
        r["vector"] = cache[_h(r["ctx"])]

    # ---- write index
    changed = bool(new_rows or to_remove)
    if mode == "rebuild" or not db_exists:
        if p.db.exists():
            assert p.db.name == "lancedb" and p.db.parent == p.home
            shutil.rmtree(p.db)
        p.home.mkdir(parents=True, exist_ok=True)
        db = lancedb.connect(str(p.db))
        tbl = db.create_table(TABLE, data=new_rows, schema=_schema())
        changed = True
    else:
        tbl = db.open_table(TABLE)
        gone = sorted(to_remove)
        for i in range(0, len(gone), 200):
            tbl.delete(f"path IN ({_sql_in(gone[i:i + 200])})")
        if new_rows:
            tbl.add(new_rows)
    if changed:
        tbl.create_fts_index("ctx", replace=True, use_tantivy=False)

    # ---- manifest
    chunks_per: dict[str, int] = {}
    for r in new_rows:
        chunks_per[r["path"]] = chunks_per.get(r["path"], 0) + 1
    files_new = {}
    for q, e in entries.items():
        o = files_old.get(q, {})
        if q in new_state:
            st = new_state[q]
            isha = e["sha1"]
            n = chunks_per.get(q, 0)
        elif q in desired:                    # unchanged canonical copy
            st, isha, n = o.get("state", "indexed"), o.get("isha", e["sha1"]), o.get("chunks", 0)
        else:
            st, isha, n = "alias", o.get("isha", ""), 0
        files_new[q] = dict(size=e["size"], mtime_ns=e["mtime_ns"], sha1=e["sha1"], group=e["group"], state=st,
                            isha=isha, chunks=n, canon=canon[q])
    save_manifest(p, dict(files=files_new, _meta=dict(
        schema=SCHEMA_VERSION, embed_model=settings["embed_model"], registry=reg_fp,
        built=time.strftime("%Y-%m-%dT%H:%M:%S"), mode=mode, rows=tbl.count_rows())))
    plan.update(chunks=tbl.count_rows(), embedded=len(need), seconds=round(time.time() - t0, 1))
    log(f"done: {plan['chunks']} chunks in index, {plan['embedded']} embedded, {plan['seconds']}s")
    return plan


def stats(p: config.Paths | None = None) -> dict:
    """What is indexed, by group - the answer to 'exactly what is in there?'."""
    p = p or config.paths()
    m = load_manifest(p)
    groups: dict[str, dict] = {}
    for q, e in m.get("files", {}).items():
        g = groups.setdefault(e["group"], dict(files=0, indexed=0, duplicates=0, empty=0, error=0, chunks=0))
        g["files"] += 1
        if e["state"] == "indexed":
            g["indexed"] += 1
            g["chunks"] += e.get("chunks", 0)
        elif e["state"] == "alias":
            g["duplicates"] += 1
        elif e["state"] in ("empty", "error"):
            g[e["state"]] += 1
    return dict(meta=m.get("_meta", {}), groups=groups)
