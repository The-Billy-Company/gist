<!--
doc_radar:
  sentinels:
    - file: kinship.go
      contains:
        - "func Over(roots ...string) *Corpus"
        - "func (c *Corpus) Similar(ctx context.Context, k irregex.Kinship) ([]Neighbor, error)"
        - "func (c *Corpus) Dups(ctx context.Context, k irregex.Kinship) ([]Pair, error)"
        - "func (c *Corpus) Clusters(ctx context.Context, k irregex.Kinship) ([]Cluster, error)"
        - "func (c *Corpus) Echoes(ctx context.Context, k irregex.Kinship) ([]Echo, error)"
        - "func (c *Corpus) Concepts(ctx context.Context, k irregex.Kinship) ([]Concept, error)"
        - "func (c *Corpus) Fragments(ctx context.Context, k irregex.Kinship) ([]Family, error)"
        - "func (c *Corpus) Distinct(ctx context.Context, k irregex.Kinship) ([]Lone, error)"
    - file: retrieval.go
      contains:
        - "func (c *Corpus) Recall(ctx context.Context, r irregex.Retrieval) ([]Recalled, error)"
        - "func (c *Corpus) Pack(ctx context.Context, r irregex.Retrieval) ([]Pick, error)"
        - "func (c *Corpus) Quote(ctx context.Context, r irregex.Retrieval) (Quotation, error)"
        - "func (c *Corpus) Patterns(ctx context.Context, s irregex.Sweep) ([]Hit, error)"
        - "func (c *Corpus) Counts(ctx context.Context, s irregex.Sweep) ([]Count, error)"
-->

# `relate` — kinship and retrieval

The questions regex cannot ask. Everything here prices bytes against bytes:
what resembles what, and which files explain a text most cheaply.

```go
c := relate.Over("pkg/kernels").In(repoRoot)

near, _ := c.Similar(ctx, irregex.Kinship{Target: "runtime/row.go", Top: 5})
dups, _ := c.Dups(ctx, irregex.Kinship{MaxDistance: new(0.15)})
set,  _ := c.Pack(ctx, irregex.Retrieval{Query: "how does the ladder decline", Top: 6})
```

## Kinship — what resembles what

| Verb        | Question                                                                     |
| ----------- | ---------------------------------------------------------------------------- |
| `Similar`   | nearest units to one probe, ranked, each carrying a calibrated grade         |
| `Dups`      | near-duplicate pairs at distance ≤ threshold                                 |
| `Clusters`  | fork **families** — the connected components a pair list makes you re-derive |
| `Echoes`    | same skeleton, different vocabulary: the DRY candidates `Dups` cannot see    |
| `Concepts`  | the vocabulary a family shares, and which members carry it                   |
| `Fragments` | families at sub-file granularity — functions, not whole units                |
| `Distinct`  | the units nothing else in the corpus resembles                               |

Every row carries its **grade** (`identical` · `strong` · `moderate` · `weak` ·
`none`), so an answer made only of background says so instead of looking like a
hit. `MinGrade` withholds the weaker rows outright.

## Retrieval — what explains this text

`Recall` ranks the corpus by which files would describe a query most cheaply.
`Pack` picks the **set** that jointly explains it, each pick priced by the bits it
adds _beyond_ the picks before it, so a near-duplicate of an earlier pick never
makes the cut. `Quote` rewrites the query as corpus quotations with per-phrase
attribution. `Patterns` and `Counts` sweep N patterns in **one** walk with exact
per-pattern attribution — the cheap way to ask several exact questions at once.

`Rows` is the escape hatch: any op, any params, the undecoded cursor plus its
`Stats`. Reach for it when you want `Foreign` (the query text simply isn't in this
repo) or a verb's raw shape.
