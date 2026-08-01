// Package exact is the pattern plane: where is this exact pattern, and what does
// the corpus say about where it is?
//
// A host opens a warm [Engine] over some roots and runs many [Engine.Search]
// queries, each materializing a pull [Cursor] it drives at its own pace. The
// engine picks its transport: the in-process pull cursor when this build has cgo
// and the library is there, the certified `gist` binary otherwise, and the child
// again whenever the in-process tier declines a pattern its linear-time engine
// cannot express. Both tiers answer the same question, so which one ran is a fact
// about speed, never about the result.
//
// Records are Go-owned values copied off whichever transport produced them, so a
// [analytic.Match] outlives the cursor and the engine.
package exact

import (
	"context"
	"encoding/json"
	"iter"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/The-Billy-Company/irregex/bindings/go/analytic"
	"github.com/The-Billy-Company/irregex/bindings/go/runtime"
)

// batch is the records-per-pull [Cursor.Next] fills under the hood — enough to
// amortize a cgo crossing without holding a large transient buffer.
const batch = 64

// Engine is a warm corpus queried many times. Searches are serialized (the
// resident engine is single-writer); the cursors they return are independent and
// safe to iterate concurrently. Free it with [Engine.Close].
type Engine struct {
	mu     sync.Mutex
	native *runtime.Native // nil while unopened, and once the tier is unavailable
	opened bool
	roots  []string
	dir    string
}

// Open declares an engine over roots (each absolute or CWD-relative; none = the
// rootless CWD walk a bare `gist <pattern>` scans). It never fails for want of a
// library: with no in-process tier the engine answers through the child, which is
// what makes a CGO_ENABLED=0 host a first-class consumer.
func Open(roots ...string) (*Engine, error) { return &Engine{roots: roots}, nil }

// warm is the in-process corpus, stood up on first search so [Engine.In] has
// already had its say about which tree the relative roots name. nil means this
// process has no in-process tier for these roots and the child answers.
func (e *Engine) warm() *runtime.Native {
	e.mu.Lock()
	defer e.mu.Unlock()
	if !e.opened {
		e.opened = true
		e.native, _ = runtime.OpenNative(runtime.Scope(e.dir, e.roots)...)
	}
	return e.native
}

// In sets the working directory the child runs in and the base its relative roots
// resolve against, for a host searching a tree other than its own CWD.
func (e *Engine) In(dir string) *Engine {
	e.dir = dir
	return e
}

// Close frees the warm corpus (idempotent). Cursors already materialized own
// their records and stay valid.
func (e *Engine) Close() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.native == nil {
		return nil
	}
	native := e.native
	e.native = nil
	return native.Close()
}

// Search runs req and returns a pull [Cursor]. The ctx is honored at record
// boundaries by both tiers: its deadline becomes the scan's wall-clock budget,
// and cancelling it stops an in-process scan cooperatively and kills a child.
func (e *Engine) Search(ctx context.Context, req analytic.Request) (*Cursor, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if native := e.warm(); native != nil {
		cur, err := searchNative(ctx, native, req)
		switch {
		case err == nil:
			return &Cursor{records: cur, buf: make([]analytic.Match, batch)}, nil
		case ctx.Err() != nil:
			return nil, err
		}
		// A pattern the linear-time engine cannot express, or an engine that could
		// not stand up: the child answers it correctly, so this is a tier change
		// and not a failure.
	}
	return e.cold(ctx, req)
}

// Files lists the paths with at least one matching line (`-l`), sorted.
func (e *Engine) Files(ctx context.Context, req analytic.Request) ([]string, error) {
	out, err := e.lines(ctx, req, "-l")
	if err != nil {
		return nil, err
	}
	slices.Sort(out)
	return out, nil
}

// Count totals the matching lines across the searched tree — one line counted
// once however many times the pattern hits it, the semantic every count surface
// in this kernel shares.
func (e *Engine) Count(ctx context.Context, req analytic.Request) (int, error) {
	out, err := e.lines(ctx, req, "--count", "--no-filename")
	if err != nil {
		return 0, err
	}
	total := 0
	for _, line := range out {
		if n, err := strconv.Atoi(strings.TrimSpace(line)); err == nil {
			total += n
		}
	}
	return total, nil
}

// Ranked is one row of the definition-first view: the engine's own def/use/gen
// class, not a reclassification of it.
type Ranked struct {
	Path       string
	LineNumber int64
	Kind       analytic.RankKind
	Count      int64
	Snippet    string
}

// Rank is the definition-first view of req's pattern: the top rows for it, each
// tagged with the engine's class, definitions ahead of call sites and generated
// files demoted. This is gist's one shape with no ripgrep equivalent; top <= 0
// takes the engine's default. Ranking reads the persisted index, so with none
// there is nothing to rank and the answer is empty.
func (e *Engine) Rank(ctx context.Context, req analytic.Request, top int) ([]Ranked, error) {
	rows, err := runtime.Run(ctx, runtime.Query{
		Op:     analytic.OpRank,
		Params: analytic.Rank{Pattern: req.Pattern, Top: top, Fixed: req.Fixed, IgnoreCase: req.IgnoreCase},
		Roots:  e.roots,
		Dir:    e.dir,
	})
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Ranked
	for row, err := range rows.All() {
		if err != nil {
			return out, err
		}
		kind, _ := analytic.ParseRankKind(row.Enum("kind").Label)
		out = append(out, Ranked{
			Path:       row.Text("path"),
			LineNumber: row.Int("line_number"),
			Kind:       kind,
			Count:      row.Int("count"),
			Snippet:    row.Text("snippet"),
		})
	}
	return out, nil
}

// lines runs one presentation-shaped query through the child, whose rendered
// answers (a path list, a per-file count) the pull ABI does not carry.
func (e *Engine) lines(ctx context.Context, req analytic.Request, flags ...string) ([]string, error) {
	argv := append(slices.Clone(flags), req.Argv(e.roots...)[1:]...) // [1:] drops Argv's --json
	out, err := runtime.Spawn(ctx, runtime.ToolGist, argv, e.dir)
	if err != nil {
		return nil, err
	}
	var kept []string
	for line := range strings.SplitSeq(out.Stdout, "\n") {
		if line != "" {
			kept = append(kept, line)
		}
	}
	return kept, nil
}

// Cursor is a pull result handle over one search. Drive it scanner-style —
// [Cursor.Next] advances, [Cursor.Match] reads the current record — range over
// [Cursor.All], or fill your own slice with [Cursor.NextBatch] to keep allocation
// off the hot path. Free it with [Cursor.Close].
type Cursor struct {
	records records
	buf     []analytic.Match
	held    []analytic.Match
	cur     analytic.Match
	err     error
	done    bool
}

// records is one search's supply, whichever tier produced it.
type records interface {
	NextBatch(dst []analytic.Match) (int, error)
	Matched() bool
	Close() error
}

// Next advances to the next record, returning false at end of stream or on error
// (check [Cursor.Err]).
func (c *Cursor) Next() bool {
	if len(c.held) == 0 {
		if c.done || c.err != nil {
			return false
		}
		n, err := c.records.NextBatch(c.buf)
		switch {
		case err != nil:
			c.err = err
			return false
		case n == 0:
			c.done = true
			return false
		}
		c.held = c.buf[:n]
	}
	c.cur, c.held = c.held[0], c.held[1:]
	return true
}

// Match is the record the last [Cursor.Next] landed on.
func (c *Cursor) Match() analytic.Match { return c.cur }

// NextBatch fills dst with up to len(dst) records and returns how many it wrote;
// 0 is a clean end of stream. Records are Go-owned, so a caller may keep every
// batch it pulls.
func (c *Cursor) NextBatch(dst []analytic.Match) (int, error) {
	if c.err != nil {
		return 0, c.err
	}
	n := copy(dst, c.held)
	c.held = c.held[n:]
	if n == len(dst) || c.done {
		return n, nil
	}
	more, err := c.records.NextBatch(dst[n:])
	if err != nil {
		c.err = err
		return n, err
	}
	if more == 0 {
		c.done = true
	}
	return n + more, nil
}

// Err is the failure that stopped iteration, or nil at a clean end of stream.
func (c *Cursor) Err() error { return c.err }

// Matched reports whether any file matched (the engine's exit-code boolean), even
// if a budget cut the scan short.
func (c *Cursor) Matched() bool { return c.records.Matched() }

// All ranges over the remaining records. The final yield carries any error with a
// zero Match; a clean end yields nothing extra.
func (c *Cursor) All() iter.Seq2[analytic.Match, error] {
	return func(yield func(analytic.Match, error) bool) {
		for c.Next() {
			if !yield(c.cur, nil) {
				return
			}
		}
		if c.err != nil {
			yield(analytic.Match{}, c.err)
		}
	}
}

// Collect drains the cursor into one slice.
func (c *Cursor) Collect() ([]analytic.Match, error) {
	var out []analytic.Match
	for c.Next() {
		out = append(out, c.cur)
	}
	return out, c.err
}

// Close releases the answer (idempotent).
func (c *Cursor) Close() error {
	if c.records == nil {
		return nil
	}
	r := c.records
	c.records, c.held, c.done = nil, nil, true
	return r.Close()
}

// cold answers one search by running `gist --json` and decoding its record
// stream, which is ripgrep's JSON-lines shape.
func (e *Engine) cold(ctx context.Context, req analytic.Request) (*Cursor, error) {
	out, err := runtime.Spawn(ctx, runtime.ToolGist, req.Argv(e.roots...), e.dir)
	if err != nil {
		return nil, err
	}
	found, err := decodeRecords(out.Stdout)
	if err != nil {
		return nil, err
	}
	return &Cursor{records: &coldRecords{rest: found, any: len(found) > 0}, buf: make([]analytic.Match, batch)}, nil
}

type coldRecords struct {
	rest []analytic.Match
	any  bool
}

func (c *coldRecords) NextBatch(dst []analytic.Match) (int, error) {
	n := copy(dst, c.rest)
	c.rest = c.rest[n:]
	return n, nil
}

func (c *coldRecords) Matched() bool { return c.any }
func (c *coldRecords) Close() error  { return nil }

// record is the ripgrep-shaped JSON-lines envelope the engine prints under
// --json. Only match and context records carry lines; the summary records are
// deliberately ignored, since a cursor's counters come from Stats.
type record struct {
	Type string `json:"type"`
	Data struct {
		Path struct {
			Text string `json:"text"`
		} `json:"path"`
		Lines struct {
			Text string `json:"text"`
		} `json:"lines"`
		LineNumber uint64 `json:"line_number"`
		Submatches []struct {
			Match struct {
				Text string `json:"text"`
			} `json:"match"`
			Start int `json:"start"`
			End   int `json:"end"`
		} `json:"submatches"`
	} `json:"data"`
}

func decodeRecords(stdout string) ([]analytic.Match, error) {
	var out []analytic.Match
	for line := range strings.SplitSeq(stdout, "\n") {
		if line == "" || line[0] != '{' {
			continue
		}
		var rec record
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			return nil, err
		}
		kind := analytic.KindMatch
		switch rec.Type {
		case "match":
		case "context":
			kind = analytic.KindContext
		default:
			continue
		}
		subs := make([]analytic.Submatch, 0, len(rec.Data.Submatches))
		for _, s := range rec.Data.Submatches {
			subs = append(subs, analytic.Submatch{Text: s.Match.Text, Start: s.Start, End: s.End})
		}
		if len(subs) == 0 {
			subs = nil
		}
		out = append(out, analytic.Match{
			Path:       rec.Data.Path.Text,
			LineNumber: rec.Data.LineNumber,
			Text:       strings.TrimSuffix(strings.TrimSuffix(rec.Data.Lines.Text, "\n"), "\r"),
			Kind:       kind,
			Submatches: subs,
		})
	}
	return out, nil
}
