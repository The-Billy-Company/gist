<!--
doc_radar:
  sentinels:
    - file: compose.go
      contains:
        - "func Over(roots ...string) *Corpus"
        - "func (c *Corpus) All() *Corpus"
        - "func (c *Corpus) Context(ctx context.Context, p irregex.Compose) ([]relate.Pick, error)"
        - "func (c *Corpus) Family(ctx context.Context, p irregex.Compose) ([]relate.Family, error)"
        - "func (c *Corpus) Provenance(ctx context.Context, p irregex.Compose) ([]Attribution, error)"
        - "func (c *Corpus) Blast(ctx context.Context, p irregex.Compose) (Blast, error)"
        - "var ErrUnscoped"
-->

# `compose` — both engines at once

The questions that need exact match _and_ compression in one pass (ADR-367). The
pattern set narrows the corpus to a typed candidate set; the compression kernel
then reasons **only inside that subset**, so the statistical scores are priced
against the matching files rather than against whole-corpus noise. The two scores
stay in separate fields — never fused into one number.

```go
c := compose.Over("pkg/kernels/irregex").In(repoRoot)

picks, _ := c.Context(ctx, irregex.Compose{Text: "how does the resident session reconcile freshness",
                                           Patterns: []string{"resident"}, Top: 6})
kin,    _ := c.Family(ctx, irregex.Compose{Patterns: []string{"Assemble"}, MaxDistance: new(0.25)})
radius, _ := c.Blast(ctx, irregex.Compose{Text: "Assemble"})
```

| Verb         | Question                                                                               |
| ------------ | -------------------------------------------------------------------------------------- |
| `Context`    | the reading set among the files that _actually_ match some intents                     |
| `Family`     | which matching files are forks or renamed twins of each other                          |
| `Provenance` | where a pasted text is really from, re-verified against **current** bytes              |
| `Blast`      | what moves if I change this symbol — dependents, dependencies, twins, ripple, mentions |

`Blast` reads live bytes, not a precomputed graph, so it is answering about the
tree as it is right now — the point of asking before an edit. Its `Budget` trims
the low-priority tail, and the trim is reported rather than silent.

**Scope is mandatory.** `Context` and `Family` refuse an unscoped query with
`ErrUnscoped`; a whole-corpus sweep is the deliberate `Over().All()`, so a composed
query never silently walks `vendor/` on a caller's behalf. Test-family discovery
wants `MinEcho`, not `MaxDistance`: tests sharing a skeleton across different API
surfaces are structural twins, and byte kinship finds no edge between them.
