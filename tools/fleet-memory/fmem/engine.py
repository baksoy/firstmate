"""Query pipeline (pipeline-fix config C1): expansion -> hybrid RRF top-20 -> rerank original query -> blend -> tiers.

Pure decision functions (fuse, blend, tier) are separate from model and index access so they test without either.
"""
from __future__ import annotations

import collections
import os
import re
import time

from . import config, registry as registry_mod, sources as sources_mod, thesaurus as thesaurus_mod

CONF, LOW, NONE = "confident", "low_confidence", "none"


# ------------------------------------------------------------------ pure pieces

def rrf_fuse(vec_keys, fts_keys, weights, boosted, k=60, boost=0.004):
    """Reciprocal-rank fusion of two ranked chunk-key lists.

    weights: key -> group weight multiplier. boosted: set of keys sharing a query customer (+boost).
    Returns keys, best first.
    """
    sc = collections.defaultdict(float)
    for leg in (vec_keys, fts_keys):
        for i, key in enumerate(leg):
            sc[key] += 1.0 / (k + i)
    for key in list(sc):
        if key in boosted:
            sc[key] += boost
        sc[key] *= weights.get(key, 1.0)
    return sorted(sc, key=lambda x: (-sc[x], x))


def group_pool(keys, pool=20, per_doc=3):
    """Top `pool` chunk keys grouped by doc in first-appearance order, at most per_doc chunks each (config C1)."""
    docs = collections.OrderedDict()
    for key in keys[:pool]:
        docs.setdefault(key[0], []).append(key)
    return collections.OrderedDict((p, ks[:per_doc]) for p, ks in docs.items())


def blend_order(docs_order, doc_scores):
    """Order docs by 1/(60+ce_rank) + 1/(60+rrf_rank); doc_scores = best reranker score per doc."""
    ce_rank = {p: i for i, p in enumerate(sorted(doc_scores, key=lambda p: -doc_scores[p]))}
    rrf_rank = {p: i for i, p in enumerate(docs_order)}
    blend = {p: 1 / (60 + ce_rank[p]) + 1 / (60 + rrf_rank[p]) for p in docs_order}
    return sorted(docs_order, key=lambda p: (-blend[p], rrf_rank[p]))


def hit_confidence(score, settings):
    if score >= settings["confident_gate"]:
        return CONF
    if score >= settings["low_gate"]:
        return "low"
    return NONE


def tier_for(lead_score, settings):
    """Answer tier from the reranker score of the pointer that would be shown first.

    Using the first pointer, not the pool maximum, refuses a query whose only strong chunk sits in a
    document the blend itself ranked below something the reranker rates as junk.
    """
    if lead_score >= settings["confident_gate"]:
        return CONF
    if lead_score >= settings["low_gate"]:
        return LOW
    return NONE


def one_line(text, n=140):
    return " ".join(text.split())[:n]


# ------------------------------------------------------------------ engine

class Engine:
    def __init__(self, p: config.Paths | None = None):
        import lancedb
        from . import models
        self.p = p or config.paths()
        self.settings = config.load_settings(self.p)
        self.reg = registry_mod.load()
        self.rules = thesaurus_mod.load(config.live_or_default(self.p.thesaurus, "thesaurus.tsv"))
        self.group_weight = self._group_weights()
        self._lancedb = lancedb
        self.embedder = models.load_embedder(self.p, self.settings["max_seq_length"])
        self.reranker = models.load_reranker(self.p)
        self._stamp = None
        self.tbl = None
        self.reopen()

    def _manifest_stamp(self):
        try:
            return self.p.manifest.stat().st_mtime_ns
        except OSError:
            return None

    def reopen(self):
        db = self._lancedb.connect(str(self.p.db))
        if "chunks" not in db.table_names():
            raise SystemExit(f"no index at {self.p.db}; run `fm-memory.sh build` first")
        self.tbl = db.open_table("chunks")
        self._stamp = self._manifest_stamp()

    def reload_config(self):
        """Pick up edits to the thesaurus and registry without restarting."""
        self.settings = config.load_settings(self.p)
        self.reg = registry_mod.load()
        self.rules = thesaurus_mod.load(config.live_or_default(self.p.thesaurus, "thesaurus.tsv"))
        self.group_weight = self._group_weights()

    @staticmethod
    def _group_weights():
        """Group weights are read at query time from sources.toml, so tuning one needs no re-index."""
        return {r.group: r.weight for r in sources_mod.load_rules()}

    def _fts(self, qx, limit):
        try:
            return self.tbl.search(qx, query_type="fts").limit(limit).to_list()
        except Exception:
            safe = re.sub(r"[^\w\s]", " ", qx)
            try:
                return self.tbl.search(safe, query_type="fts").limit(limit).to_list()
            except Exception:
                return []

    def query(self, q: str, k: int | None = None, raw: bool = False) -> dict:
        """raw=True keeps below-gate hits (eval harness only); the public contract never shows them."""
        t0 = time.time()
        if self._manifest_stamp() != self._stamp:        # a refresh landed: see it immediately
            self.reopen()
        s = self.settings
        k = k or s["k"]
        ids, alias_extra = self.reg.analyze_query(q)
        th_extra = thesaurus_mod.expand(q, self.rules)
        qx = " ".join([q, *alias_extra, *th_extra]).strip()

        qv = self.embedder.encode([qx], normalize_embeddings=True)[0]
        vec = self.tbl.search(qv, vector_column_name="vector").metric("cosine").limit(s["per_leg"]).to_list()
        fts = self._fts(qx, s["per_leg"])
        info, weights, boosted = {}, {}, set()
        for r in (*vec, *fts):
            key = (r["path"], r["chunk_no"])
            info.setdefault(key, r)
            weights[key] = self.group_weight.get(r["group"], 1.0)
            if ids and r.get("entities") and set(ids) & set(r["entities"].split(",")):
                boosted.add(key)
        order = rrf_fuse([(r["path"], r["chunk_no"]) for r in vec], [(r["path"], r["chunk_no"]) for r in fts],
                         weights, boosted, s["rrf_k"], s["customer_boost"])
        docs = group_pool(order, s["pool"], s["chunks_per_doc"])
        if not docs:
            return self._result(q, qx, ids, NONE, [], float("-inf"), float("-inf"), t0)

        pairs = [(p, key) for p, ks in docs.items() for key in ks]
        scores = self.reranker.predict([(q, info[key]["ctx"][:1500]) for _, key in pairs])   # ORIGINAL query
        best = {}
        for (p, key), sc in zip(pairs, scores):
            if p not in best or sc > best[p][0]:
                best[p] = (float(sc), key)
        ordered = blend_order(list(docs), {p: v[0] for p, v in best.items()})
        top = max(v[0] for v in best.values())
        lead = best[ordered[0]][0]

        hits, seen_titles = [], set()
        for p in ordered:
            sc, key = best[p]
            r = info[key]
            if r["title"] in seen_titles:
                continue
            seen_titles.add(r["title"])
            conf = hit_confidence(sc, s)
            if conf == NONE and not raw:
                continue
            hits.append(dict(
                rank=len(hits) + 1, title=r["title"], path=p, date=r["mtime"], confidence=conf,
                why=f"§ {r['heading'][:80] or '-'} :: {one_line(r['text'])}",
                heading=r["heading"], snippet=one_line(r["text"]), score=round(sc, 2), group=r["group"],
                customers=[c for c in (r.get("entities") or "").split(",") if c],
            ))
            if len(hits) == k:
                break
        tier = tier_for(lead, s)
        if tier == NONE and not raw:
            hits = []
        return self._result(q, qx, ids, tier, hits, top, lead, t0)

    def _result(self, q, qx, ids, tier, hits, top, lead, t0):
        return dict(query=q, tier=tier, hits=hits, customers=ids, expanded=qx,
                    top_score=None if top == float("-inf") else round(top, 2),
                    lead_score=None if lead == float("-inf") else round(lead, 2),
                    gates=dict(confident=self.settings["confident_gate"], low=self.settings["low_gate"]),
                    ms=round((time.time() - t0) * 1000))


def format_text(res: dict) -> str:
    """Human rendering of a query result (the `--json` form is the machine contract)."""
    out = [f'Q: "{res["query"]}"  [customers: {",".join(res["customers"]) or "-"} | {res["ms"]} ms | '
           f'score {res.get("lead_score", res["top_score"])}]']
    if res["tier"] == NONE:
        out.append("No confident match.")
        return "\n".join(out)
    if res["tier"] == LOW:
        out.append("LOW CONFIDENCE - closest matches, not a confident hit:")
    for h in res["hits"]:
        tag = "" if h["confidence"] == CONF or res["tier"] == LOW else "  (low confidence)"
        out.append(f'{h["rank"]}. {h["title"]}  - {h["date"]}{tag}')
        out.append(f'   {h["path"]}')
        out.append(f'   why: {h["why"]}')
    return "\n".join(out)
