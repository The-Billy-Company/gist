"""The persisted artifacts, and whether they can be trusted yet.

`lifecycle` builds and inspects the trigram index and the kinship atlas, and
reports what this binary can actually do (`capabilities`). The warm tier is an
*optimization*, never a dependency: a missing or stale artifact degrades to a
live answer with identical bytes, which is why status is worth asking for — a
long-running process can decide once whether to build instead of paying a cold
walk per call.

The facade deliberately keeps `irregex.index` bound to the *build* function
rather than to this package; import the module as `irregex.index.lifecycle`.
"""

from __future__ import annotations
