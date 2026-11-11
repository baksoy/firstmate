"""fmem command line. Query path: resident server if running, else a one-shot in-process engine."""
from __future__ import annotations

import argparse
import json
import sys

from . import config


def _query(a) -> int:
    from . import server
    q = " ".join(a.q)
    res = None
    if not a.one_shot:
        res = server.request({"op": "query", "q": q, "k": a.k}, timeout=120)
        if res is not None and "error" in res:
            print(f"server error: {res['error']}", file=sys.stderr)
            res = None
    if res is None:
        from .engine import Engine
        res = Engine().query(q, a.k)
        res["via"] = "one-shot"
    else:
        res["via"] = "server"
    if a.json:
        print(json.dumps(res, ensure_ascii=False))
    else:
        from .engine import format_text
        print(format_text(res))
    return 0


def _build(a) -> int:
    from . import indexer
    indexer.run("rebuild" if a.cmd == "rebuild" else "refresh", dry_run=getattr(a, "dry_run", False))
    from . import server
    if server.is_running():
        server.request({"op": "reload"})
    return 0


def _stats(a) -> int:
    from . import indexer
    s = indexer.stats()
    if a.json:
        print(json.dumps(s, indent=1))
        return 0
    m = s["meta"]
    print(f"built {m.get('built', '?')} ({m.get('mode', '?')}), {m.get('rows', 0)} chunks, model {m.get('embed_model', '?')}")
    print(f"{'group':28} {'files':>6} {'indexed':>8} {'dupes':>6} {'empty':>6} {'chunks':>7}")
    for g, v in sorted(s["groups"].items()):
        print(f"{g:28} {v['files']:>6} {v['indexed']:>8} {v['duplicates']:>6} {v['empty']:>6} {v['chunks']:>7}")
    return 0


def _server(a) -> int:
    from . import server
    if a.cmd == "serve":
        server.serve()
    elif a.cmd == "start":
        print(server.start())
    elif a.cmd == "stop":
        print(server.stop())
    elif a.cmd == "status":
        r = server.request({"op": "ping"}, timeout=2)
        print(f"running pid={r['pid']}" if r and r.get("ok") else "not running")
        return 0 if r and r.get("ok") else 1
    return 0


def _registry(a) -> int:
    from . import registry
    p = config.paths()
    if a.sub == "seed":
        vault = a.vault or "~/Vaults/Work/Customers"
        import os
        seeded = registry.seed_from_vault(os.path.expanduser(vault))
        target = p.customers
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text((config.DEFAULTS_DIR / "customers.example.toml").read_text())
            print(f"created {target} from the shipped defaults")
        added = registry.merge_seed(target, seeded)
        print(f"{len(added)} new customers appended to {target}: {', '.join(added) or '-'}")
    elif a.sub == "show":
        reg = registry.load()
        for c in reg.customers:
            print(f"{c.id}: {c.name} | aliases={c.aliases} | mishearings={c.mishearings} | repos={c.repos}")
    elif a.sub == "query":
        reg = registry.load()
        print(reg.analyze_query(" ".join(a.words)))
    return 0


def _init(a) -> int:
    import shutil
    from . import models
    p = config.paths()
    p.home.mkdir(parents=True, exist_ok=True)
    for name, live in (("sources.toml", p.sources), ("thesaurus.tsv", p.thesaurus), ("eval.toml", p.eval_set)):
        if not live.exists():
            shutil.copy(config.DEFAULTS_DIR / name, live)
            print(f"wrote {live}")
    if not p.customers.exists():
        shutil.copy(config.DEFAULTS_DIR / "customers.example.toml", p.customers)
        print(f"wrote {p.customers}")
    for k, v in models.link_models(p).items():
        print(f"model {k}: {v}")
    return 0


def _eval(a) -> int:
    from . import evalrun
    res = evalrun.run()
    if a.json:
        print(json.dumps(res, indent=1))
    ok = (res["headline"] and all(0 < h["rank"] <= 3 and h["tier"] != "none" for h in res["headline"])
          and res["neg_refused"] == res["neg_n"] and res["hard_refused"] == res["hard_n"]
          and res["gold_hit3"] >= res["gold_n"] - 1)
    print("EVAL PASS" if ok else "EVAL FAIL")
    return 0 if ok else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="fmem", description="Fleet Memory librarian: semantic pointers to the captain's own work.")
    sub = ap.add_subparsers(dest="cmd", required=True)
    q = sub.add_parser("query", help="ask in plain language; returns at most 3 pointers")
    q.add_argument("q", nargs="+")
    q.add_argument("-k", type=int, default=None)
    q.add_argument("--json", action="store_true")
    q.add_argument("--one-shot", action="store_true", help="skip the resident server")
    q.set_defaults(fn=_query)
    for name, h in (("refresh", "incremental: re-embed changed files, tombstone deleted ones"),
                    ("rebuild", "cold rebuild of the whole index")):
        s = sub.add_parser(name, help=h)
        s.add_argument("--dry-run", action="store_true")
        s.set_defaults(fn=_build)
    s = sub.add_parser("stats", help="what is indexed, by group")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=_stats)
    for name in ("serve", "start", "stop", "status"):
        sub.add_parser(name, help=f"resident server: {name}").set_defaults(fn=_server)
    r = sub.add_parser("registry", help="customer registry helpers")
    rs = r.add_subparsers(dest="sub", required=True)
    sd = rs.add_parser("seed", help="append customers from the Work vault notes' frontmatter (read-only on the vault)")
    sd.add_argument("--vault", default=None)
    rs.add_parser("show")
    rq = rs.add_parser("query")
    rq.add_argument("words", nargs="+")
    r.set_defaults(fn=_registry)
    sub.add_parser("init", help="create the memory home, copy editable defaults, link cached models").set_defaults(fn=_init)
    e = sub.add_parser("eval", help="run the eval set; exit 1 if the headline or a negative regresses")
    e.add_argument("--json", action="store_true")
    e.set_defaults(fn=_eval)
    a = ap.parse_args(argv)
    return a.fn(a)
