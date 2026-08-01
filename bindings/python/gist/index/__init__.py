"""The persisted trigram index, and whether it can be trusted yet.

`lifecycle` builds and inspects gist's search index and reports what this binary
can do (`capabilities`). The warm tier is an optimization, never a dependency.
Relate owns atlas / fragment / shelf lifecycle in its own package.
"""

from __future__ import annotations
