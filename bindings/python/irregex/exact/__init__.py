"""Exact search — where is this pattern, byte for byte.

The rg-shaped half of the binding: `SearchRequest` is the whole query surface
(one dataclass, validated against the contract's option set rather than against
a hand-kept list), `Match` is one hit with its submatch spans, `Cursor` streams
them under a cancel token, and `aggregate` folds them into ranked tallies.

Nothing here interprets a pattern — the same certified matcher the CLI uses
decides everything, so a Python answer and a shell answer are the same answer.
"""

from __future__ import annotations
