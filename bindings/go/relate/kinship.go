// Package relate is the compression plane: the questions a regex cannot ask.
// What resembles this file, what repeats in this corpus, which files explain this
// text most cheaply, and where did this pasted snippet come from.
//
// Every verb here scores kinship by how cheaply one thing describes another, and
// every score arrives banded ([irregex.Grade]) so background never reads as a
// hit: an answer of five strangers at distance 0.78 says so instead of looking
// like a find. Ask for a floor with Kinship.MinGrade rather than filtering after
// the fact — the engine withholds weaker rows, which is cheaper and honest.
//
// A [Corpus] is a scope, not a handle: it holds no resources and is safe to keep
// and share. Each verb runs one query through the runtime's ladder — the
// in-process analytic plane when it can, the certified `relate` binary otherwise.
package relate

import (
	"context"
	"path/filepath"
	"slices"
	"strings"

	irregex "irregex/bindings/go"
	"irregex/bindings/go/runtime"
)

// Corpus is the scope every verb asks its question inside: the roots, and the
// directory relative paths resolve against.
type Corpus struct {
	roots []string
	dir   string
}

// Over scopes the compression verbs to roots (none = the index roots).
func Over(roots ...string) *Corpus { return &Corpus{roots: roots} }

// In sets the working directory the query resolves relative paths against.
func (c *Corpus) In(dir string) *Corpus {
	c.dir = dir
	return c
}

// Rows runs any analytic verb and hands back the undecoded cursor — the escape
// hatch for a caller that wants [runtime.Stats], a nested row this package's
// typed views flatten, or a verb added to the contract after this binding shipped.
func (c *Corpus) Rows(ctx context.Context, op irregex.Op, params irregex.Params) (*runtime.Rows, error) {
	return runtime.Run(ctx, runtime.Query{Op: op, Params: params, Roots: c.roots, Dir: c.dir})
}

// collect drains one verb into a typed slice. Stats are dropped here on purpose:
// a typed row list is the common case, and a caller who needs the answer-level
// counters (foreign, omitted) reaches for Rows instead.
func collect[T any](ctx context.Context, c *Corpus, op irregex.Op, params irregex.Params, scan func(runtime.Row) T) ([]T, error) {
	rows, err := c.Rows(ctx, op, params)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []T
	for row, err := range rows.All() {
		if err != nil {
			return out, err
		}
		out = append(out, scan(row))
	}
	return out, nil
}

// Region is a span of one file — a whole file when the unit is file, the
// enclosing function when it is not.
type Region struct {
	Path      string
	LineStart int64
	LineEnd   int64
	Headline  string
}

func region(r runtime.Row) Region {
	return Region{
		Path:      r.Text("path"),
		LineStart: r.Int("line_start"),
		LineEnd:   r.Int("line_end"),
		Headline:  r.Text("headline"),
	}
}

func regions(r runtime.Row, field string) []Region {
	nested := r.Rows(field)
	out := make([]Region, 0, len(nested))
	for _, child := range nested {
		out = append(out, region(child))
	}
	return out
}

// Neighbor is one ranked kinship answer: how far the probe is from this path, in
// which channel, and what that distance is worth.
type Neighbor struct {
	Path     string
	Distance float64
	Grade    irregex.Grade
	Channel  irregex.Channel
}

// Neighbors decodes the similar rows nested inside another answer (blast's
// twins), so a composed verb reuses this view rather than restating it.
func Neighbors(rows []runtime.Row) []Neighbor {
	out := make([]Neighbor, 0, len(rows))
	for _, row := range rows {
		out = append(out, neighbor(row))
	}
	return out
}

func neighbor(r runtime.Row) Neighbor {
	grade, _ := irregex.ParseGrade(r.Enum("grade").Label)
	channel, _ := irregex.ParseChannel(r.Enum("channel").Label)
	return Neighbor{Path: r.Text("path"), Distance: r.Float("distance"), Grade: grade, Channel: channel}
}

// Similar ranks the corpus against one probe — a path, `path#Lnnn` for the
// function containing that line, or bare text. The probe's shape decides how it
// is priced, which is why one verb covers "what resembles this file" and "what
// does this sentence sound like".
//
// A file is never its own kin: a distance-0 row for the probe itself is dropped,
// so the top row is the nearest OTHER thing regardless of which tier answered.
func (c *Corpus) Similar(ctx context.Context, k irregex.Kinship) ([]Neighbor, error) {
	near, err := collect(ctx, c, irregex.OpSimilar, k, neighbor)
	self := c.resolve(k.Target)
	if self == "" {
		return near, err
	}
	return slices.DeleteFunc(near, func(n Neighbor) bool { return c.resolve(n.Path) == self }), err
}

// resolve is a probe or row path's identity for comparison, "" when it does not
// name a file (bare text, or a `path#Lnnn` function probe, is not a whole unit and
// so cannot collide with one).
func (c *Corpus) resolve(path string) string {
	if path == "" || strings.Contains(path, "#L") {
		return ""
	}
	full := path
	if !filepath.IsAbs(full) {
		full = filepath.Join(c.dir, path)
	}
	resolved, err := filepath.EvalSymlinks(full)
	if err != nil {
		return ""
	}
	return resolved
}

// Pair is two paths close enough in bytes to be the same thing twice.
type Pair struct {
	A, B     string
	Distance float64
	Grade    irregex.Grade
}

// Dups are the near-duplicate pairs, closest first — copy-paste and its drift.
func (c *Corpus) Dups(ctx context.Context, k irregex.Kinship) ([]Pair, error) {
	return collect(ctx, c, irregex.OpDups, k, func(r runtime.Row) Pair {
		grade, _ := irregex.ParseGrade(r.Enum("grade").Label)
		return Pair{A: r.Text("a"), B: r.Text("b"), Distance: r.Float("distance"), Grade: grade}
	})
}

// Cluster is a fork family: the transitive closure of the verified duplicate
// graph, graded by its loosest edge.
type Cluster struct {
	Paths       []string
	MaxDistance float64
	Grade       irregex.Grade
}

// Clusters are the fork families, largest first — the restructure-ready unit a
// pair list makes a caller re-derive with its own union-find.
func (c *Corpus) Clusters(ctx context.Context, k irregex.Kinship) ([]Cluster, error) {
	return collect(ctx, c, irregex.OpClusters, k, func(r runtime.Row) Cluster {
		grade, _ := irregex.ParseGrade(r.Enum("grade").Label)
		return Cluster{Paths: r.Strings("paths"), MaxDistance: r.Float("max_distance"), Grade: grade}
	})
}

// Echo is a pair far apart in bytes but close in structure: the same skeleton
// wearing different vocabulary. Echo is that gap, and higher is stronger — the
// inverse polarity of a distance, which is why it has its own column.
type Echo struct {
	A, B      string
	Echo      float64
	Bytes     float64
	Structure float64
	Grade     irregex.Grade
}

// Echoes are the DRY candidates duplicate detection cannot see, widest gap first.
func (c *Corpus) Echoes(ctx context.Context, k irregex.Kinship) ([]Echo, error) {
	return collect(ctx, c, irregex.OpEchoes, k, func(r runtime.Row) Echo {
		grade, _ := irregex.ParseGrade(r.Enum("grade").Label)
		return Echo{
			A: r.Text("a"), B: r.Text("b"),
			Echo:      r.Float("echo"),
			Bytes:     r.Float("byte_distance"),
			Structure: r.Float("structure_distance"),
			Grade:     grade,
		}
	})
}

// Concept is one repeated implementation shape across several functions — the
// abstraction candidate. Bytes and Echo are optional because a family of
// structurally identical fragments may have no measurable byte kinship at all.
type Concept struct {
	Members       []Region
	RepeatedLines int64
	Confidence    float64
	Structure     float64
	Bytes         *float64
	Echo          *float64
}

// Concepts are the function-level shape families: what this corpus keeps
// re-implementing under different names.
func (c *Corpus) Concepts(ctx context.Context, k irregex.Kinship) ([]Concept, error) {
	return collect(ctx, c, irregex.OpConcepts, k, func(r runtime.Row) Concept {
		return Concept{
			Members:       regions(r, "members"),
			RepeatedLines: r.Int("repeated_lines"),
			Confidence:    r.Float("confidence"),
			Structure:     r.Float("structure_distance"),
			Bytes:         opt(r, "byte_distance"),
			Echo:          opt(r, "echo"),
		}
	})
}

// Family is one repetition family with its own rank, unit and channel — the
// generalized cluster, reused by the composed `family` verb.
type Family struct {
	Rank          int64
	Unit          irregex.Unit
	Channel       irregex.Channel
	Edge          float64
	RepeatedLines int64
	Score         float64
	Members       []Region
}

// ScanFamily decodes one family row, so the composed plane reuses this view.
func ScanFamily(r runtime.Row) Family {
	unit, _ := irregex.ParseUnit(r.Enum("unit").Label)
	channel, _ := irregex.ParseChannel(r.Enum("channel").Label)
	return Family{
		Rank:          r.Int("rank"),
		Unit:          unit,
		Channel:       channel,
		Edge:          r.Float("edge"),
		RepeatedLines: r.Int("repeated_lines"),
		Score:         r.Float("score"),
		Members:       regions(r, "members"),
	}
}

// Fragments are the function-level families: a twelve-line helper cloned into six
// files is a family here even where those files share three percent of their bytes.
func (c *Corpus) Fragments(ctx context.Context, k irregex.Kinship) ([]Family, error) {
	return collect(ctx, c, irregex.OpFragments, k, ScanFamily)
}

// Lone is a unit with no relative, priced by its nearest miss — the complement
// that turns "which of these fourteen implementations is genuinely unique" into a
// measurement.
type Lone struct {
	Unit      irregex.Unit
	Member    Region
	Nearest   *Region
	Bytes     float64
	Structure float64
}

// Distinct are the unrepeated units, each carrying the closest thing to a
// relative it has.
func (c *Corpus) Distinct(ctx context.Context, k irregex.Kinship) ([]Lone, error) {
	return collect(ctx, c, irregex.OpDistinct, k, func(r runtime.Row) Lone {
		unit, _ := irregex.ParseUnit(r.Enum("unit").Label)
		l := Lone{
			Unit:      unit,
			Bytes:     r.Float("byte_distance"),
			Structure: r.Float("structure_distance"),
		}
		if members := r.Rows("member"); len(members) > 0 {
			l.Member = region(members[0])
		}
		if nearest := r.Rows("nearest"); len(nearest) > 0 {
			near := region(nearest[0])
			l.Nearest = &near
		}
		return l
	})
}

// opt reads a measurement that may not have been taken. A zero distance means
// identical, so absence cannot be spelled as zero.
func opt(r runtime.Row, field string) *float64 {
	v, ok := r.OptFloat(field)
	if !ok {
		return nil
	}
	return &v
}
