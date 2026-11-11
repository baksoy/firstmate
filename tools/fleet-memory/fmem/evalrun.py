"""Eval harness: gold + held-out recall, negative refusal at the gates, and latency. Ported from the PoC scripts."""
from __future__ import annotations

import statistics

from . import config
from .engine import Engine


def rank_of(hits, want):
    for i, h in enumerate(hits, 1):
        if any(t in (h["path"] + h["title"]).lower() for t in want):
            return i
    return 0


def run(p: config.Paths | None = None, eval_path=None, log=print) -> dict:
    p = p or config.paths()
    spec = config.load_toml(eval_path or config.live_or_default(p.eval_set, "eval.toml"))
    eng = Engine(p)
    eng.query("warm up")
    lat = []

    def go(q):
        r = eng.query(q, raw=True)
        lat.append(r["ms"])
        return r

    def block(items):
        out = []
        for it in items:
            r = go(it["q"])
            out.append(dict(q=it["q"], rank=rank_of(r["hits"], it["want"]), top=r["lead_score"],
                            headline=bool(it.get("headline")), tier=r["tier"],
                            hit_score=next((h["score"] for h in r["hits"] if any(t in (h["path"] + h["title"]).lower() for t in it["want"])), None)))
        return out

    gold, held = block(spec["gold"]), block(spec["held"])
    neg = [go(q)["lead_score"] for q in spec["negatives"]["original"]]
    hard = [go(q)["lead_score"] for q in spec["negatives"]["hard"]]
    g = eng.settings
    true_scores = [x["hit_score"] for x in gold + held if x["rank"] and x["hit_score"] is not None]
    low = g["low_gate"]
    res = dict(
        gold_hit1=sum(x["rank"] == 1 for x in gold), gold_hit3=sum(x["rank"] > 0 for x in gold), gold_n=len(gold),
        held_hit1=sum(x["rank"] == 1 for x in held), held_hit3=sum(x["rank"] > 0 for x in held), held_n=len(held),
        headline=[dict(q=x["q"], rank=x["rank"], score=x["hit_score"], tier=x["tier"]) for x in gold if x["headline"]],
        weakest_true_hit=min(true_scores) if true_scores else None,
        neg_max=max(neg), hard_max=max(hard),
        neg_refused=sum(s < low for s in neg), neg_n=len(neg),
        hard_refused=sum(s < low for s in hard), hard_n=len(hard),
        median_ms=round(statistics.median(lat)), p90_ms=sorted(lat)[int(0.9 * len(lat))],
        gates=dict(confident=g["confident_gate"], low=low),
        gold=gold, held=held,
    )
    log(f"gold  hit@1 {res['gold_hit1']}/{res['gold_n']}  hit@3 {res['gold_hit3']}/{res['gold_n']}")
    log(f"held  hit@1 {res['held_hit1']}/{res['held_n']}  hit@3 {res['held_hit3']}/{res['held_n']}")
    for h in res["headline"]:
        log(f"headline rank {h['rank']} score {h['score']} tier {h['tier']}: {h['q'][:70]}")
    log(f"weakest true hit {res['weakest_true_hit']}  gate(low) {low}  gate(confident) {g['confident_gate']}")
    log(f"negatives: original max {res['neg_max']} refused {res['neg_refused']}/{res['neg_n']}; "
        f"hard max {res['hard_max']} refused {res['hard_refused']}/{res['hard_n']}")
    log(f"latency resident: median {res['median_ms']} ms  p90 {res['p90_ms']} ms")
    for x in gold + held:
        if x["rank"] != 1:
            log(f"  not rank 1 (rank {x['rank']}, top {x['top']}): {x['q'][:70]}")
    return res
