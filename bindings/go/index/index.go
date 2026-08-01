// Package index is the lifecycle and introspection of the two persisted
// artifacts every other verb rides: the trigram index the exact engine prefilters
// with, and the kinship atlas (plus its codex shelf) the compression verbs sketch
// against.
//
// Neither artifact is a dependency. A missing or stale one costs speed, never
// correctness — a query folds in every file changed since the artifact's freshness
// anchor and degrades to a live scan when there is nothing to fold into. That is
// why this package reports readiness and staleness rather than gating on them: the
// honest question is "how warm am I", not "may I search".
//
// The kernel exposes no index lifecycle over the C ABI, so these verbs run the
// certified `gist` / `relate` binaries. A caller that cannot find them gets
// [runtime.ErrNoBinary], which is the same answer as "this machine has no index to
// speak of".
package index

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/The-Billy-Company/irregex/bindings/go/runtime"
)

// Corpus is the tree whose artifacts are being inspected or rebuilt.
type Corpus struct {
	roots []string
	dir   string
}

// Over scopes the lifecycle verbs to roots (none = each artifact's own recorded
// roots, which is what a refresh of an existing index wants).
func Over(roots ...string) *Corpus { return &Corpus{roots: roots} }

// In sets the working directory, which also selects WHICH tree's artifacts are
// read: an artifact records the tree it was built over, so one from another
// checkout is inert here rather than wrong.
func (c *Corpus) In(dir string) *Corpus {
	c.dir = dir
	return c
}

// Trigrams is the exact engine's persisted index. Age runs from the freshness
// anchor, and BoundHere is false when the artifact was built over another tree —
// in which case it accelerates nothing and queries answer live.
type Trigrams struct {
	State      string
	Path       string
	Files      int64
	Distinct   int64
	Postings   int64
	IndexBytes int64
	PathsBytes int64
	Age        time.Duration
	Roots      []string
	BoundHere  bool
	BuiltOver  string
}

// Ready reports whether an index is present and usable for this tree.
func (t Trigrams) Ready() bool { return t.State == "ready" && t.BoundHere }

// Artifact is one persisted compression artifact. Stale counts the files that
// changed since it was built, each of which a query re-sketches live — so a stale
// artifact is slower, never wrong.
type Artifact struct {
	State string
	Files int64
	Bytes int64
	Stale int64
	Built time.Time
}

// Ready reports whether the artifact is present and loadable.
func (a Artifact) Ready() bool { return a.State == "ready" }

// Atlas is the compression plane's readiness: the file-level kinship atlas, the
// function-level fragment atlas, and the codex shelf that quote and provenance
// need.
type Atlas struct {
	Kinship   Artifact
	Fragments Artifact
	Shelf     Artifact
}

// Status reads the trigram index's readiness, size and staleness.
func (c *Corpus) Status(ctx context.Context) (Trigrams, error) {
	var doc struct {
		State string `json:"state"`
		Index struct {
			Path       string `json:"path"`
			Files      int64  `json:"files_indexed"`
			Distinct   int64  `json:"distinct_trigrams"`
			Postings   int64  `json:"postings"`
			IndexBytes int64  `json:"index_bytes"`
			PathsBytes int64  `json:"paths_bytes"`
		} `json:"index"`
		Freshness struct {
			Age float64 `json:"age_seconds"`
		} `json:"freshness"`
		Roots     []string `json:"roots"`
		BoundHere bool     `json:"bound_here"`
		BuiltOver string   `json:"built_over"`
	}
	if err := c.read(ctx, runtime.ToolGist, &doc); err != nil {
		return Trigrams{}, err
	}
	return Trigrams{
		State:      doc.State,
		Path:       doc.Index.Path,
		Files:      doc.Index.Files,
		Distinct:   doc.Index.Distinct,
		Postings:   doc.Index.Postings,
		IndexBytes: doc.Index.IndexBytes,
		PathsBytes: doc.Index.PathsBytes,
		Age:        time.Duration(doc.Freshness.Age * float64(time.Second)),
		Roots:      doc.Roots,
		BoundHere:  doc.BoundHere,
		BuiltOver:  doc.BuiltOver,
	}, nil
}

// Atlas reads the kinship, fragment and shelf artifacts' readiness.
func (c *Corpus) Atlas(ctx context.Context) (Atlas, error) {
	type artifact struct {
		State string `json:"state"`
		Files int64  `json:"files"`
		Frags int64  `json:"fragments"`
		Bytes int64  `json:"bytes"`
		Stale int64  `json:"stale_files"`
		Built int64  `json:"built_unix_ns"`
	}
	var doc struct {
		Atlas artifact `json:"atlas"`
		Frag  artifact `json:"frag"`
		Shelf artifact `json:"shelf"`
	}
	if err := c.read(ctx, runtime.ToolRelate, &doc); err != nil {
		return Atlas{}, err
	}
	lift := func(a artifact, units int64) Artifact {
		out := Artifact{State: a.State, Files: units, Bytes: a.Bytes, Stale: a.Stale}
		if a.Built != 0 {
			out.Built = time.Unix(0, a.Built)
		}
		return out
	}
	return Atlas{
		Kinship:   lift(doc.Atlas, doc.Atlas.Files),
		Fragments: lift(doc.Frag, doc.Frag.Frags),
		Shelf:     lift(doc.Shelf, 0),
	}, nil
}

// Refresh rebuilds the trigram index and returns its new state. This is the
// re-anchor after a large sweep: correctness never needed it, but every query
// until then pays to fold the sweep's files in one at a time.
func (c *Corpus) Refresh(ctx context.Context) (Trigrams, error) {
	if _, err := runtime.Spawn(ctx, runtime.ToolGist, append([]string{"index"}, c.roots...), c.dir); err != nil {
		return Trigrams{}, err
	}
	return c.Status(ctx)
}

// RefreshAtlas rebuilds the kinship and fragment atlases, and with shelf the
// codex shelf that quote and provenance read. The shelf is the expensive one, so
// it is opt-in rather than implied. The compression artifacts cover the whole
// corpus by construction — a per-root kinship atlas could not answer a query that
// crosses roots — so this verb takes its scope from [Corpus.In] alone.
func (c *Corpus) RefreshAtlas(ctx context.Context, shelf bool) (Atlas, error) {
	argv := []string{"index"}
	if shelf {
		argv = append(argv, "--shelf")
	}
	if _, err := runtime.Spawn(ctx, runtime.ToolRelate, argv, c.dir); err != nil {
		return Atlas{}, err
	}
	return c.Atlas(ctx)
}

// read runs `<tool> status --json` and decodes it. A status verb exits 1 when the
// artifact is missing while still printing the document that says so, which is why
// the exit code is not consulted here.
func (c *Corpus) read(ctx context.Context, tool string, out any) error {
	res, err := runtime.Spawn(ctx, tool, []string{"status", "--json"}, c.dir)
	if err != nil && res.Stdout == "" {
		return err
	}
	if err := json.Unmarshal([]byte(res.Stdout), out); err != nil {
		return fmt.Errorf("irregex: %s status: %w", tool, err)
	}
	return nil
}
