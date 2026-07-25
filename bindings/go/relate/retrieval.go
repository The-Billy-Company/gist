package relate

import (
	"context"

	irregex "irregex/bindings/go"
	"irregex/bindings/go/runtime"
)

// Recalled is one file priced against a query: Gain is how much of the query this
// file explains, in [0,1], and the two bit columns are the accounting behind it.
type Recalled struct {
	Path      string
	Gain      float64
	CostBits  float64
	BitsSaved float64
	Factors   int64
	Literals  int64
}

// Recall ranks the corpus by which files would describe query most cheaply — the
// recall verb for when the exact spelling is unknown, since it scores content
// rather than matching a pattern.
func (c *Corpus) Recall(ctx context.Context, r irregex.Retrieval) ([]Recalled, error) {
	return collect(ctx, c, irregex.OpRecall, r, func(row runtime.Row) Recalled {
		return Recalled{
			Path:      row.Text("path"),
			Gain:      row.Float("gain"),
			CostBits:  row.Float("cost_bits"),
			BitsSaved: row.Float("bits_saved"),
			Factors:   row.Int("factors"),
			Literals:  row.Int("literals"),
		}
	})
}

// Pick is one member of a reading set. MarginalBits is the novelty this file adds
// BEYOND every pick before it — which is why a near-duplicate of an earlier pick
// never makes the list — and Coverage is how much of the query the picks so far
// jointly explain.
type Pick struct {
	Rank         int64
	Path         string
	MarginalBits float64
	Coverage     float64
	Patterns     []string
}

// ScanPick decodes one pick row, shared with the composed `context` verb, which
// answers in the same shape over a pattern-narrowed candidate set.
func ScanPick(r runtime.Row) Pick {
	return Pick{
		Rank:         r.Int("rank"),
		Path:         r.Text("path"),
		MarginalBits: r.Float("marginal_bits"),
		Coverage:     r.Float("coverage"),
		Patterns:     r.Strings("patterns"),
	}
}

// Pack assembles the anti-redundant set of files that jointly explain the query
// most cheaply — the reading list, not the ranking.
func (c *Corpus) Pack(ctx context.Context, r irregex.Retrieval) ([]Pick, error) {
	return collect(ctx, c, irregex.OpPack, r, ScanPick)
}

// Phrase is one span of a quotation, priced in bits and attributed to the file it
// came from. Source is absent when the phrase is not in the corpus at all.
type Phrase struct {
	Text        string
	Occurrences int64
	Bits        float64
	Source      string
	Quoted      bool
}

// Quotation is a query rewritten as corpus quotations. BitsPerByte is the
// compression the corpus achieved over the text, so a high value means the text is
// largely foreign to this repo; Escapes counts the phrases it could not quote.
type Quotation struct {
	Bits        float64
	BitsPerByte float64
	QuotedBytes int64
	QueryBytes  int64
	Escapes     int64
	Phrases     []Phrase
}

// Quote rewrites the query as corpus quotations, each phrase attributed to a
// source file — the provenance question, answered statistically. It needs the
// persisted codex shelf (`relate index --shelf`) and says so when it is missing.
func (c *Corpus) Quote(ctx context.Context, r irregex.Retrieval) (Quotation, error) {
	rows, err := c.Rows(ctx, irregex.OpQuote, r)
	if err != nil {
		return Quotation{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		return Quotation{}, rows.Err()
	}
	row := rows.Row()
	q := Quotation{
		Bits:        row.Float("bits"),
		BitsPerByte: row.Float("bits_per_byte"),
		QuotedBytes: row.Int("quoted_bytes"),
		QueryBytes:  row.Int("query_bytes"),
		Escapes:     row.Int("escapes"),
	}
	for _, p := range row.Rows("phrases") {
		source, quoted := p.OptText("source")
		q.Phrases = append(q.Phrases, Phrase{
			Text:        p.Text("text"),
			Occurrences: p.Int("occurrences"),
			Bits:        p.Float("bits"),
			Source:      source,
			Quoted:      quoted,
		})
	}
	return q, rows.Err()
}

// Hit is one line matching one pattern of a sweep, attributed to which.
type Hit struct {
	Path      string
	Line      int64
	PatternID int64
}

// Patterns sweeps N patterns in ONE walk with exact per-pattern attribution —
// materially cheaper than N searches, which is the whole reason the verb exists.
func (c *Corpus) Patterns(ctx context.Context, s irregex.Sweep) ([]Hit, error) {
	return collect(ctx, c, irregex.OpPatterns, s, func(r runtime.Row) Hit {
		return Hit{Path: r.Text("path"), Line: r.Int("line"), PatternID: r.Int("pattern_id")}
	})
}

// Count is one tally of a sweep. Label is the pattern or the path, depending on
// which grouping the sweep asked for.
type Count struct {
	Label string
	Count int64
}

// Counts tallies a sweep engine-side, grouped by pattern (Sweep.ByPattern) or by
// file (Sweep.ByFile) — the counts without the rows, so a caller sizing a problem
// never pays to stream every hit.
func (c *Corpus) Counts(ctx context.Context, s irregex.Sweep) ([]Count, error) {
	return collect(ctx, c, irregex.OpPatternCounts, s, func(r runtime.Row) Count {
		return Count{Label: r.Text("label"), Count: r.Int("count")}
	})
}
