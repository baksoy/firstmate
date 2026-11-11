"""Unit tests for the pure decision pieces: thesaurus, registry, fusion, blend, tiers, dedupe, crawl."""
import os
import tempfile
import unittest
from pathlib import Path

from fmem import config, engine, registry, sources, thesaurus

SETTINGS = dict(config.DEFAULT_SETTINGS)


class ThesaurusTests(unittest.TestCase):
    def setUp(self):
        self.rules = thesaurus.parse(
            "# comment\ncheat, scam*, rip off => fraud waste abuse\nbot => automation agent\n")

    def test_expands_lay_terms(self):
        self.assertEqual(thesaurus.expand("how do people cheat", self.rules), ["fraud", "waste", "abuse"])

    def test_prefix_and_hyphen_match(self):
        self.assertTrue(thesaurus.expand("scammers online", self.rules))
        self.assertTrue(thesaurus.expand("a rip-off", self.rules))

    def test_whole_word_only(self):
        self.assertEqual(thesaurus.expand("robotics", self.rules), [])
        self.assertEqual(thesaurus.expand("bots", self.rules), ["automation", "agent"])

    def test_bad_line_is_an_error(self):
        with self.assertRaises(ValueError):
            thesaurus.parse("no arrow here\n")

    def test_shipped_defaults_parse(self):
        self.assertGreater(len(thesaurus.load(config.DEFAULTS_DIR / "thesaurus.tsv")), 5)


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.reg = registry.Registry([
            registry.Customer(id="fdic", name="FDIC", aliases=["Federal Deposit Insurance"],
                              mishearings=["FGIC"], geography=["Arlington"], repos=["fdic-poc"]),
            registry.Customer(id="umass", name="UMass", aliases=["University of Massachusetts"],
                              keywords=["amherst"]),
        ])

    def test_mishearing_resolves_to_customer(self):
        ids, extra = self.reg.analyze_query("what did we show FGIC last week")
        self.assertEqual(ids, ["fdic"])
        self.assertIn("FDIC", extra)

    def test_alias_in_query_not_repeated(self):
        _, extra = self.reg.analyze_query("University of Massachusetts demo")
        self.assertNotIn("University of Massachusetts", extra)

    def test_no_customer_no_expansion(self):
        self.assertEqual(self.reg.analyze_query("chess cheating"), ([], []))

    def test_document_tag_uses_path_and_text_not_mishearings(self):
        self.assertEqual(self.reg.tag_document("/x/fdic-poc/README.md", "Readme", "body"), ["fdic"])
        self.assertEqual(self.reg.tag_document("/x/a.md", "t", "talked about FGIC"), [])

    def test_whole_word_tagging(self):
        self.assertEqual(self.reg.tag_document("/x/a.md", "t", "the umassive plan"), [])

    def test_shipped_example_loads(self):
        reg = registry.load(config.DEFAULTS_DIR / "customers.example.toml")
        self.assertTrue(reg.customers)


class FusionTests(unittest.TestCase):
    def test_rrf_prefers_chunks_in_both_legs(self):
        a, b, c = ("a", 0), ("b", 0), ("c", 0)
        self.assertEqual(engine.rrf_fuse([a, b], [c, a], {}, set())[0], a)

    def test_customer_boost_breaks_ties(self):
        a, b = ("a", 0), ("b", 0)
        self.assertEqual(engine.rrf_fuse([a], [b], {}, {b})[0], b)

    def test_group_weight_demotes(self):
        a, b = ("a", 0), ("b", 0)
        self.assertEqual(engine.rrf_fuse([a, b], [], {a: 0.1}, set())[0], b)

    def test_group_pool_groups_by_doc_in_first_appearance_order(self):
        keys = [("a", 0), ("b", 0), ("a", 1), ("c", 0)]
        pool = engine.group_pool(keys, pool=3, per_doc=3)
        self.assertEqual(list(pool), ["a", "b"])
        self.assertEqual(pool["a"], [("a", 0), ("a", 1)])

    def test_group_pool_caps_chunks_per_doc(self):
        keys = [("a", i) for i in range(5)]
        self.assertEqual(len(engine.group_pool(keys, pool=5, per_doc=2)["a"]), 2)

    def test_blend_lets_reranker_promote_a_doc(self):
        order = engine.blend_order(["a", "b", "c"], {"a": -9.0, "b": -2.0, "c": -5.0})
        self.assertEqual(order, ["b", "a", "c"])

    def test_blend_swap_ties_resolve_to_rrf_order(self):
        self.assertEqual(engine.blend_order(["a", "b"], {"a": -9.0, "b": -2.0}), ["a", "b"])

    def test_blend_keeps_rrf_order_when_scores_tie_rank(self):
        self.assertEqual(engine.blend_order(["a", "b"], {"a": -1.0, "b": -2.0}), ["a", "b"])

    def test_tiers_at_the_gates(self):
        self.assertEqual(engine.tier_for(-6.0, SETTINGS), engine.CONF)
        self.assertEqual(engine.tier_for(-6.01, SETTINGS), engine.LOW)
        self.assertEqual(engine.tier_for(-8.6, SETTINGS), engine.LOW)
        self.assertEqual(engine.tier_for(-8.61, SETTINGS), engine.NONE)

    def test_tier_follows_the_first_pointer_not_the_pool_maximum(self):
        scores = {"junk-first": -10.2, "strong-second": -7.5}
        order = engine.blend_order(["junk-first", "strong-second"], scores)
        self.assertEqual(order[0], "junk-first")                      # tied blend keeps the fusion order
        self.assertEqual(engine.tier_for(scores[order[0]], SETTINGS), engine.NONE)
        self.assertEqual(engine.tier_for(max(scores.values()), SETTINGS), engine.LOW)

    def test_text_rendering_labels_tiers(self):
        base = dict(query="q", customers=[], ms=1, top_score=-7.0, hits=[
            dict(rank=1, title="T", date="2026-01-01", path="/p", why="w", confidence="low")])
        self.assertIn("LOW CONFIDENCE", engine.format_text(dict(base, tier=engine.LOW)))
        self.assertIn("No confident match.", engine.format_text(dict(base, tier=engine.NONE, hits=[])))


class RescueTests(unittest.TestCase):
    def setUp(self):
        self.rules = thesaurus.parse("cheat => fraud abuse\npatient => phi hipaa\nchess => board\n")

    def test_corroboration_counts_concepts_the_document_holds(self):
        doc = {"fraud", "abuse", "phi", "hipaa", "claims"}
        self.assertEqual(thesaurus.corroborated(self.rules, doc, 0.5), 2)

    def test_corroboration_matches_plurals_and_needs_the_cover_share(self):
        self.assertEqual(thesaurus.corroborated(self.rules[:1], {"frauds"}, 0.5), 1)
        self.assertEqual(thesaurus.corroborated(self.rules[:1], {"unrelated"}, 0.5), 0)

    def test_matched_returns_only_rules_the_query_names(self):
        self.assertEqual(len(thesaurus.matched("do patients cheat", self.rules)), 2)

    def test_rescue_needs_two_concepts_in_query_and_document(self):
        docs = {"real": {"fraud", "abuse", "phi", "hipaa"}, "stray": {"fraud", "abuse"}}
        two = thesaurus.matched("patients who cheat", self.rules)
        self.assertEqual(engine.rescue(["real", "stray"], docs.__getitem__, two, SETTINGS), ["real"])

    def test_one_concept_query_rescues_nothing(self):
        one = thesaurus.matched("online chess cheating", self.rules[:1])
        self.assertEqual(engine.rescue(["real"], lambda p: {"fraud", "abuse"}, one, SETTINGS), [])


class CanonicalTests(unittest.TestCase):
    def entry(self, sha, rkey=None, prio=0, mtime=1.0):
        return dict(sha1=sha, rkey=rkey, prio=prio, mtime=mtime)

    def test_identical_content_prefers_live_over_treehouse(self):
        ents = {"/h/.treehouse/x/a.md": self.entry("s"), "/h/Development/a.md": self.entry("s")}
        self.assertEqual(set(sources.elect(ents).values()), {"/h/Development/a.md"})

    def test_drifted_copy_collapses_on_repo_key(self):
        ents = {"/h/.treehouse/x/r/README.md": self.entry("s1", "r/README.md", mtime=9),
                "/h/Development/r/README.md": self.entry("s2", "r/README.md", mtime=1)}
        self.assertEqual(set(sources.elect(ents).values()), {"/h/Development/r/README.md"})

    def test_distinct_artifacts_stay_distinct(self):
        ents = {"/a.md": self.entry("s1"), "/b.md": self.entry("s2")}
        self.assertEqual(sources.elect(ents), {"/a.md": "/a.md", "/b.md": "/b.md"})


class CrawlTests(unittest.TestCase):
    def test_mindepth_maxdepth_names_and_skips(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "loose.md").write_text("x")
            (root / "task1").mkdir()
            (root / "task1" / "report.md").write_text("x")
            (root / "task1" / "node_modules").mkdir()
            (root / "task1" / "node_modules" / "report.md").write_text("x")
            (root / "task1" / "deep" / "deeper").mkdir(parents=True)
            (root / "task1" / "deep" / "deeper" / "report.md").write_text("x")
            rule = sources.Rule(group="g", roots=[str(root)], names=["report.md"], mindepth=1, maxdepth=1)
            got = [os.path.relpath(p, d) for _, p, _ in sources.crawl([rule])]
            self.assertEqual(got, ["task1/report.md"])


if __name__ == "__main__":
    unittest.main()
