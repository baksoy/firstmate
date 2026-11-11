"""Fleet Memory librarian: local, read-only semantic search over the captain's own work.

Heavy imports (torch, sentence-transformers, lancedb) are deferred so the
resident-server client path stays fast; see fmem.models and fmem.engine.
"""

__version__ = "1.0.0"
