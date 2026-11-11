"""Refresh behavior on a tiny fixture corpus with a stand-in embedder (no model files needed)."""
import hashlib
import os
import tempfile
import unittest
from pathlib import Path

import numpy as np

from fmem import config, indexer


class FakeEmbedder:
    def encode(self, texts, **_kw):
        out = []
        for t in texts:
            seed = int(hashlib.sha1(t.encode()).hexdigest()[:8], 16)
            v = np.random.default_rng(seed).normal(size=384).astype("float32")
            out.append(v / np.linalg.norm(v))
        return np.array(out)


class RefreshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.corpus, self.home = t / "corpus", t / "home"
        self.corpus.mkdir()
        self.home.mkdir()
        (self.home / "sources.toml").write_text(
            f'[[source]]\ngroup = "docs"\nroots = ["{self.corpus}"]\nexts = [".md"]\n')
        (self.home / "customers.toml").write_text("")
        self.prev = os.environ.get("FM_MEMORY_HOME")
        os.environ["FM_MEMORY_HOME"] = str(self.home)
        self.orig = indexer.models.load_embedder
        indexer.models.load_embedder = lambda *a, **k: FakeEmbedder()
        self.p = config.paths()
        self.logs = []

    def tearDown(self):
        indexer.models.load_embedder = self.orig
        if self.prev is None:
            os.environ.pop("FM_MEMORY_HOME", None)
        else:
            os.environ["FM_MEMORY_HOME"] = self.prev
        self.tmp.cleanup()

    def doc(self, name, body):
        (self.corpus / name).write_text(f"# {name}\n\n{body}\n" * 3)

    def run_idx(self, mode="refresh"):
        return indexer.run(mode, log=self.logs.append, p=self.p)

    def test_build_refresh_edit_and_tombstone(self):
        self.doc("a.md", "alpha text about gardens and soil conditions for spring planting")
        self.doc("b.md", "beta text about databases and indexing strategies for large tables")
        first = self.run_idx("rebuild")
        self.assertEqual(first["canonical"], 2)
        self.assertGreater(first["chunks"], 1)

        noop = self.run_idx()
        self.assertEqual((noop["add"], noop["remove"], noop["embedded"]), (0, 0, 0))

        self.doc("a.md", "alpha text rewritten entirely to talk about oceans and tides over time")
        edited = self.run_idx()
        self.assertEqual(edited["add"], 1)

        (self.corpus / "b.md").unlink()
        gone = self.run_idx()
        self.assertEqual(gone["remove"], 1)
        import lancedb
        paths = set(lancedb.connect(str(self.p.db)).open_table("chunks").to_arrow()["path"].to_pylist())
        self.assertEqual(paths, {str(self.corpus / "a.md")})
        self.assertNotIn(str(self.corpus / "b.md"), indexer.load_manifest(self.p)["files"])

    def test_duplicate_content_is_indexed_once(self):
        self.doc("a.md", "identical text about quarterly planning and budget review meetings")
        self.doc("copy.md", "identical text about quarterly planning and budget review meetings")
        (self.corpus / "copy.md").write_text((self.corpus / "a.md").read_text())
        plan = self.run_idx("rebuild")
        self.assertEqual((plan["crawled"], plan["canonical"], plan["duplicates"]), (2, 1, 1))
        self.assertEqual(indexer.stats(self.p)["groups"]["docs"]["duplicates"], 1)

    def test_dry_run_changes_nothing(self):
        self.doc("a.md", "some searchable text about planting and soil for the spring season")
        self.run_idx("rebuild")
        self.doc("c.md", "new text about something else entirely, including kayaks and rivers")
        before = self.p.manifest.read_text()
        plan = indexer.run("refresh", log=self.logs.append, p=self.p, dry_run=True)
        self.assertEqual(plan["add"], 1)
        self.assertEqual(self.p.manifest.read_text(), before)


if __name__ == "__main__":
    unittest.main()
