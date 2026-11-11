# Fleet Memory librarian

A local, private, read-only semantic index over the captain's own work, with a query CLI.
It answers "where did we put that thing" with at most 3 pointers to real artifacts and never a synthesized answer.
The use case is an SE or AE who half-remembers a customer artifact in the middle of a call.

## Quick start

All commands go through `bin/fm-memory.sh`.

```
bin/fm-memory.sh init        # create the memory home, copy the editable defaults, link the cached models
bin/fm-memory.sh registry seed   # append customers from ~/Vaults/Work/Customers frontmatter (read-only on the vault)
bin/fm-memory.sh build       # cold rebuild (about 2 minutes for roughly 1,000 artifacts)
bin/fm-memory.sh refresh     # incremental: re-embed changed files, tombstone deleted ones (about 1 second when nothing changed)
bin/fm-memory.sh start       # optional resident server: models stay loaded, queries answer in about 100-200 ms
bin/fm-memory.sh query "that walkthrough where the bot can't leak patient info"
bin/fm-memory.sh stats       # exactly what is indexed, by group
bin/fm-memory.sh eval        # re-run the eval set; exit 1 on a regression
bin/fm-memory.sh stop
```

`refresh` is a command you run, not a daemon.
`refresh` and `build` accept `--dry-run` to print the plan without touching the index.
A running server reloads automatically after a build or refresh.

## Where things live

The memory home is `$FM_MEMORY_HOME`, else `$FM_HOME/data/fleet-memory`, else `<code root>/data/fleet-memory`.
`data/` is gitignored, so the index, weights links, and every editable file below stay private and uncommitted.

| File in the memory home | Purpose |
| --- | --- |
| `sources.toml` | what is crawled; falls back to `defaults/sources.toml` |
| `thesaurus.tsv` | lay word to document noun expansion; falls back to `defaults/thesaurus.tsv` |
| `customers.toml` | customer and alias registry; falls back to `defaults/customers.example.toml` |
| `settings.toml` | optional overrides of the gates and pool sizes (keys in `fmem/config.py`) |
| `eval.toml` | eval queries; falls back to `defaults/eval.toml` |
| `manifest.json`, `lancedb/` | generated index state; safe to delete, then `build` |
| `models/` | symlinks to the two cached models, written by `init` |
| `run/` | server socket (mode 0600), pid file, log |

Edit `sources.toml`, `thesaurus.tsv`, and `customers.toml` in place.
Thesaurus and group-weight edits apply on the next query, or after `bin/fm-memory.sh start` is restarted for a running server.
A `customers.toml` edit re-tags every document on the next `refresh`, reusing unchanged vectors.
A `sources.toml` edit takes effect on the next `refresh`.

## Interpreter and models

`bin/fm-memory.sh` picks the first of `$FM_MEMORY_PYTHON`, `<memory home>/venv/bin/python`, and `~/fleet-memory-poc/venv/bin/python`.
The interpreter needs the packages in `requirements.txt` (lancedb, sentence-transformers, pyarrow, numpy, beautifulsoup4, lxml, pyyaml).
Embedding is `all-MiniLM-L6-v2` and reranking is `cross-encoder/ms-marco-MiniLM-L-6-v2`, both loaded offline from the local Hugging Face cache.
The tool never downloads a model and refuses to start if one is missing.

## What is indexed

Crawling is strictly read-only on every source.
`stats` prints the live per-group counts, and `sources.toml` is the authority; the shipped defaults cover:

- Both firstmate homes (live and buildmate's treehouse copy): `data/` records (`done-archive.md`, `learnings.md`, `backlog.md`), per-task report folders up to three levels deep, and `.lavish/*.html`.
- Loose files at the `data/` root are deliberately not indexed, because research dumps there flood the candidate pool.
- `WALKTHROUGH` and `DECK` files (html or md) anywhere under `~/Development` and buildmate's `projects/`.
- `README.md`, `AGENTS.md`, `CLAUDE.md` at project roots, and any `docs/` folder.
- The `~/Vaults/MuleSoftKB` vault, with `raw/` vendor scrapes down-weighted to 0.5.
- The Work vault slices `Customers`, `Deliverables`, `Meeting Prep`, `Reference`, and `MuleSoft Agent Fabric`.

Never indexed under any rule: `node_modules`, dot directories, `target`, `_archive`, `attachments`, `venv`, `site-packages`, `dist`, `build`, `vendor`, `__pycache__`.
Copies of one artifact (the live `~/Development/firstmate/projects/...` tree and buildmate's treehouse copy) collapse to one pointer, and the live path wins.
On the reference build, 1,192 files collapsed to 999 distinct artifacts and 21,151 chunks.

## How a query is answered

1. The registry detects customers in the question (names, aliases, speech-recognition mishearings such as FGIC for FDIC, geography) and the thesaurus maps lay words to document nouns; both only extend the search text.
2. Vector and BM25 searches over MiniLM chunks are fused by reciprocal rank (top 20 chunks), with a small boost for chunks tagged with a detected customer.
3. The cross-encoder scores the ORIGINAL question, never the expanded one, against every chunk of the pool.
4. Documents are ordered by the blend `1/(60+reranker rank) + 1/(60+fusion rank)` and deduplicated by title.
5. The reranker score of the first pointer (the top of the blended order, not the best score anywhere in the pool) picks the tier.

| Tier | First pointer's reranker score | Output |
| --- | --- | --- |
| `confident` | at least -6.0 | up to 3 pointers |
| `low_confidence` | from -8.6 up to -6.0 | up to 3 pointers under a "LOW CONFIDENCE - closest matches" banner |
| `none` | below -8.6 | no pointers, "No confident match." |

Gates live in `fmem/config.py` and can be overridden in `settings.toml`.

## Invocation for the librarian mate

```
FM_MEMORY_HOME=<memory home> /path/to/firstmate/bin/fm-memory.sh query --json "<the question as spoken>"
```

The command prints one JSON object on stdout and exits 0 whether or not anything matched.
It uses the resident server when one is running and otherwise loads the models in-process (about 5-10 seconds), so run `start` once per session for call-time speed.
Pass `-k N` to change the pointer count; the contract default is 3.

```json
{
  "query": "the question as given",
  "tier": "confident | low_confidence | none",
  "hits": [
    {
      "rank": 1,
      "title": "document title",
      "path": "/absolute/path/to/the/artifact",
      "date": "YYYY-MM-DD (file modified)",
      "why": "§ heading :: one-line snippet",
      "heading": "section heading",
      "snippet": "one-line snippet",
      "confidence": "confident | low",
      "score": -4.2,
      "group": "source group",
      "customers": ["customer-id"]
    }
  ],
  "customers": ["customer ids detected in the question"],
  "expanded": "the search text actually used",
  "top_score": -4.2,
  "lead_score": -4.2,
  "gates": {"confident": -6.0, "low": -8.6},
  "ms": 120,
  "via": "server | one-shot"
}
```

Rules for the mate:

- `hits` is empty exactly when `tier` is `none`.
- When `tier` is `low_confidence`, say plainly that these are the closest matches and not a confident hit.
- Always show `path` and never state facts from a document that the mate has not opened.
- Never present a hit as an answer; it is a pointer.
- `bin/fm-memory.sh refresh` before an important session picks up new work cheaply.

## Eval numbers

The eval set (`defaults/eval.toml`) has 18 gold queries, 10 held-out queries, and 14 negatives (6 original, 8 hard).
`bin/fm-memory.sh eval` passes when the headline query is at rank 1, every original negative is refused, and gold hit@3 is within one of perfect.
Reference run on the full real corpus with the shipped configuration:

| Measure | Result |
| --- | --- |
| Gold hit@1 / hit@3 | 17/18 / 18/18 |
| Held-out hit@1 / hit@3 | 6/10 / 8/10 |
| Headline "bot can't leak patient info" walkthrough | rank 1, score -8.0, low-confidence tier |
| Weakest true hit | -8.0 (gate -8.6) |
| Original negatives refused | 6/6 (strongest -9.2) |
| Hard negatives refused | 8/8 (strongest -9.57) |
| Latency, resident server | median about 165 ms, p90 about 200 ms |

## Known limits

- The off-topic query "how to detect cheating in online chess" has a stray strong chunk (-7.54) in a customer note, below a -10.22 first pointer.
  The tier is judged on the first pointer, so that query is refused, while the headline walkthrough query (first pointer -8.0) stays recovered.
  The separation is thin: it works because the blend put the junk document first, so a different corpus can still produce a false closest-match in the low-confidence tier.
  `top_score` (pool maximum) stays in the JSON for diagnosis; `lead_score` is the value the tier uses.
- The margin between the weakest true hit (-8.0) and the strongest original negative (-9.2) is 1.2.
  Gate values are corpus-dependent, so re-run `eval` after a large corpus change.
- Held-out misses cluster on abstract paraphrases (monolith decomposition slides, identity propagation, government cloud, zero trust).
  Add a thesaurus rule or a registry alias when a real question misses; the editable files exist for this.
- Lay words absent from the thesaurus and registry are not bridged; the embedding is a small English model.
- The index is a snapshot until `refresh` runs.

## Tests

`python -m unittest` over `tests/` covers the thesaurus, registry, fusion, blending, tiers, de-duplication, crawl rules, and the refresh and tombstone path with a stand-in embedder.
`tests/fm-memory.test.sh` at the repo root drives the executable and runs these unit tests when an interpreter with the dependencies exists.
