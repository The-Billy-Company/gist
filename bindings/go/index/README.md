<!--
doc_radar:
  sentinels:
    - file: index.go
      contains:
        - "func Over(roots ...string) *Corpus"
        - "func (c *Corpus) Status(ctx context.Context) (Trigrams, error)"
        - "func (c *Corpus) Atlas(ctx context.Context) (Atlas, error)"
        - "func (c *Corpus) Refresh(ctx context.Context) (Trigrams, error)"
        - "func (c *Corpus) RefreshAtlas(ctx context.Context, shelf bool) (Atlas, error)"
-->

# `index` — artifact lifecycle and readiness

Warmth is an optimization tier, never a dependency: every verb answers correctly
with no artifact at all, just slower. This package is how a caller _sees_ that
tier and rebuilds it deliberately.

```go
c := index.Over(".").In(repoRoot)

if t, _ := c.Status(ctx); !t.Ready() {
    t, _ = c.Refresh(ctx)           // ~3 s over the Billy tree
}
if a, _ := c.Atlas(ctx); !a.Shelf.Ready() {
    a, _ = c.RefreshAtlas(ctx, true) // the shelf is the expensive one, so it is opt-in
}
```

`Trigrams` is the exact engine's persisted index — its size, its freshness anchor,
and `BoundHere`, which is the one that matters: an artifact home built over
_another_ checkout accelerates nothing here, and `Ready()` folds that in rather
than letting a caller mistake "present" for "usable". Staleness is informational,
not disqualifying; a wall-clock anchor folds every file changed since the build
back into the answer, so a days-old index is still correct.

`Atlas` reports the three compression artifacts **separately** — kinship,
fragments, shelf — because `Quote` and `Provenance` need the shelf specifically
and "the atlas is ready" must not stand in for that.

Both refresh verbs run the certified binary: the C ABI exposes no index lifecycle,
by design, so a rebuild is one process doing one thing rather than a library
mutating a caller's tree from inside their address space. `$GIST_DIR` relocates
the artifact home, which is what makes a hermetic test possible.
