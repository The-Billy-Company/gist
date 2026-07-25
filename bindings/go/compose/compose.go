// Package compose is the plane where both engines answer one question (ADR-367):
// the exact pattern set narrows the corpus to a typed candidate set, and the
// compression kernel then reasons only INSIDE that subset.
//
// That containment is the point. A hand-rolled `gist -l | relate …` pipe throws
// the match information away between the two steps and then pays whole-corpus
// statistical noise; here the exact and statistical scores stay in separate
// fields and are never fused into one number.
//
// Scope is mandatory for [Corpus.Context] and [Corpus.Family] — a composed query
// must not silently sweep vendored trees. [Corpus.Blast] is corpus-wide by
// design, since a blast radius that stops at a directory boundary is a lie.
package compose

import (
	"context"
	"errors"

	irregex "irregex/bindings/go"
	"irregex/bindings/go/relate"
	"irregex/bindings/go/runtime"
)

// ErrUnscoped reports a composed query with neither roots nor All.
var ErrUnscoped = errors.New("irregex: composed query needs roots or Over().All()")

// Corpus is the scope a composed verb runs inside.
type Corpus struct {
	roots []string
	dir   string
	all   bool
}

// Over scopes the composed verbs to roots.
func Over(roots ...string) *Corpus { return &Corpus{roots: roots} }

// All declares the deliberate whole-corpus sweep, the only way to run a composed
// verb without roots.
func (c *Corpus) All() *Corpus {
	c.all = true
	return c
}

// In sets the working directory the query resolves relative paths against.
func (c *Corpus) In(dir string) *Corpus {
	c.dir = dir
	return c
}

func (c *Corpus) rows(ctx context.Context, op irregex.Op, p irregex.Compose, scoped bool) (*runtime.Rows, error) {
	if scoped && len(c.roots) == 0 && !c.all {
		return nil, ErrUnscoped
	}
	return runtime.Run(ctx, runtime.Query{Op: op, Params: p, Roots: c.roots, Dir: c.dir})
}

// Context is the reading set among the files that actually match — coverage
// packing restricted to the candidate set, so each pick reports both the patterns
// that admitted it and the novelty it adds over the picks before it.
func (c *Corpus) Context(ctx context.Context, p irregex.Compose) ([]relate.Pick, error) {
	rows, err := c.rows(ctx, irregex.OpContext, p, true)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []relate.Pick
	for row, err := range rows.All() {
		if err != nil {
			return out, err
		}
		out = append(out, relate.ScanPick(row))
	}
	return out, nil
}

// Family finds the fork families among only the matching files. Set
// Compose.MaxDistance for byte copy-paste; set Compose.MinEcho for the same
// skeleton under renamed vocabulary — which is what test families usually are, so
// a byte threshold there finds no edges at all.
func (c *Corpus) Family(ctx context.Context, p irregex.Compose) ([]relate.Family, error) {
	rows, err := c.rows(ctx, irregex.OpFamily, p, true)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []relate.Family
	for row, err := range rows.All() {
		if err != nil {
			return out, err
		}
		out = append(out, relate.ScanFamily(row))
	}
	return out, nil
}

// Attribution is one phrase of a pasted text traced to its source. Verified is
// the composed part: the exact engine re-checked the phrase against the source
// file's CURRENT bytes, so a stale statistical attribution cannot pass as live
// provenance.
type Attribution struct {
	Text        string
	Occurrences int64
	Source      string
	Verified    bool
	Line        int64
	Located     bool
}

// Provenance traces a pasted text back to the files it came from, each phrase
// re-verified against current bytes. Needs the codex shelf
// (`relate index --shelf`).
func (c *Corpus) Provenance(ctx context.Context, p irregex.Compose) ([]Attribution, error) {
	rows, err := c.rows(ctx, irregex.OpProvenance, p, false)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Attribution
	for row, err := range rows.All() {
		if err != nil {
			return out, err
		}
		line, located := row.OptInt("line")
		out = append(out, Attribution{
			Text:        row.Text("text"),
			Occurrences: row.Int("occurrences"),
			Source:      row.Text("source"),
			Verified:    row.Bool("verified"),
			Line:        line,
			Located:     located,
		})
	}
	return out, nil
}

// Reference is one place that mentions a symbol. Defines separates the definition
// from the two hundred call sites, and Enclosing names the function it sits in.
type Reference struct {
	Path      string
	Line      int64
	Enclosing string
	Defines   bool
}

// Dependency is a symbol the seed's own body depends on.
type Dependency struct {
	Symbol string
	Path   string
	Line   int64
}

// Ripple is a file reached indirectly, through Via, in Hops steps.
type Ripple struct {
	Path string
	Via  string
	Hops int64
}

// Mention is prose — a comment or doc line — that names the symbol. Renaming
// without these leaves the comments lying.
type Mention struct {
	Path string
	Line int64
	Text string
}

// Site is a definition's location.
type Site struct {
	Path string
	Line int64
}

// Blast is the live blast radius of one symbol, computed from CURRENT bytes with
// no precomputed graph, which is what makes it safe to consult mid-edit. Omitted
// is what Compose.Budget trimmed from the low-priority tail, so a bounded answer
// admits it was bounded.
type Blast struct {
	Symbol       string
	Kind         string
	Definitions  []Site
	Dependents   []Reference
	Dependencies []Dependency
	Twins        []relate.Neighbor
	Ripple       []Ripple
	Comments     []Mention
	Notes        []string
	Omitted      int64
}

// Blast answers "what moves if I change this symbol" before the edit: the
// definition and its kind, the direct dependents split into definitions and uses,
// what the body itself depends on, tangential twins, the same-language ripple, and
// the comments that name it.
func (c *Corpus) Blast(ctx context.Context, p irregex.Compose) (Blast, error) {
	rows, err := c.rows(ctx, irregex.OpBlast, p, false)
	if err != nil {
		return Blast{}, err
	}
	defer rows.Close()
	if !rows.Next() {
		return Blast{}, rows.Err()
	}
	row := rows.Row()
	b := Blast{
		Symbol:  row.Text("symbol"),
		Kind:    row.Text("kind"),
		Twins:   relate.Neighbors(row.Rows("twins")),
		Notes:   row.Strings("notes"),
		Omitted: row.Int("omitted"),
	}
	for _, d := range row.Rows("definitions") {
		b.Definitions = append(b.Definitions, Site{Path: d.Text("path"), Line: d.Int("line")})
	}
	for _, d := range row.Rows("dependents") {
		b.Dependents = append(b.Dependents, Reference{
			Path:      d.Text("path"),
			Line:      d.Int("line"),
			Enclosing: d.Text("enclosing"),
			Defines:   d.Bool("defines"),
		})
	}
	for _, d := range row.Rows("dependencies") {
		b.Dependencies = append(b.Dependencies, Dependency{Symbol: d.Text("symbol"), Path: d.Text("path"), Line: d.Int("line")})
	}
	for _, d := range row.Rows("ripple") {
		b.Ripple = append(b.Ripple, Ripple{Path: d.Text("path"), Via: d.Text("via"), Hops: d.Int("hops")})
	}
	for _, d := range row.Rows("comments") {
		b.Comments = append(b.Comments, Mention{Path: d.Text("path"), Line: d.Int("line"), Text: d.Text("text")})
	}
	return b, rows.Err()
}
