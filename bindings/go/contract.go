// Package irregex is the contract plane of the Go binding for Billy's
// irregular-expression kernel: the generated row-schema table
// ([Digest] and friends in schema_gen.go), the constants mirrored from
// `contract/search_api.toml`, the search request/record shapes, and the kinship
// calibration every analytic row is graded against.
//
// Nothing in this package talks to the kernel. The transports — cgo, the
// analytic dispatch, the generic row decoder, and the subprocess fallback — live
// in the runtime subpackage, and the verbs in exact (pattern search), relate
// (kinship + retrieval), compose (the both-engines verbs) and index (the warm
// artifacts). Dependencies point one way: contract ← runtime ← verbs.
//
// The pull-cursor Engine that used to live here is now exact.Engine; a search
// request and its records did not move, so [Request], [Match] and [Submatch]
// still resolve from this import path.
package irregex

import (
	"slices"
	"sync"
)

// ABI and engine versions, mirrored from [meta]. Additive C symbols do not bump
// ABIVersion; the analytic plane's own compatibility axis is [Digest].
const (
	ABIVersion    = 2
	EngineVersion = "0.2.0"
)

// Process exit codes ([exit_codes]) — ripgrep's three, preserved end to end. A
// kinship verb that emits no row exits ExitNoMatch, which is an answer.
const (
	ExitMatched = 0
	ExitNoMatch = 1
	ExitError   = 2
)

// Status is what every C-ABI entry point returns ([status_codes]). Non-negative
// is a result; StatusStale is a declinature (a correct answer exists one tier
// down); the rest are faults.
type Status int32

// The six statuses. Their dispositions are contract, not judgment: only
// StatusStale means "ask the next tier".
const (
	StatusOK         Status = 0
	StatusMatch      Status = 1
	StatusStale      Status = -1
	StatusOOM        Status = -2
	StatusOpenFailed Status = -3
	StatusInvalid    Status = -4
)

// Result reports whether s carries an answer (matched or not).
func (s Status) Result() bool { return s >= 0 }

// Declined reports whether s is the declinature — never surface it as an error.
func (s Status) Declined() bool { return s == StatusStale }

// Which tier answered an analytic query (irregex_stats.source).
const (
	SourceLive  uint32 = 0
	SourceAtlas uint32 = 1
	SourceShelf uint32 = 2
)

// Tag is the wire type of one row field ([row_schemas] `type`). A field's tag
// comes from its declaration; the tag on the wire is what lets a decoder fail
// rather than mis-read when the two disagree.
type Tag uint32

// The seven value tags ([analytic].value_tags).
const (
	TagText  Tag = 0
	TagInt   Tag = 1
	TagFloat Tag = 2
	TagBool  Tag = 3
	TagEnum  Tag = 4
	TagTexts Tag = 5
	TagRows  Tag = 6
)

func (t Tag) String() string {
	if int(t) >= len(tagNames) {
		return "tag?"
	}
	return tagNames[t]
}

var tagNames = [...]string{"text", "i64", "f64", "bool", "enum", "texts", "rows"}

// Op is an analytic verb's op code ([analytic.verbs]) — the wire discriminant
// for irregex_analytic_run, append-only.
type Op uint32

// The seventeen analytic verbs.
const (
	OpSimilar Op = iota + 1
	OpDups
	OpClusters
	OpEchoes
	OpConcepts
	OpFragments
	OpDistinct
	OpRecall
	OpPack
	OpQuote
	OpPatterns
	OpPatternCounts
	OpContext
	OpFamily
	OpProvenance
	OpBlast
	OpRank
)

// String is the verb's contract name ("similar", "pattern_counts"), or "op?"
// for a code this binding's table does not declare.
func (o Op) String() string {
	if v, ok := Verb(o); ok {
		return v.Name
	}
	return "op?"
}

// Params is the [analytic.params] family this op's request struct must be —
// "kinship", "retrieval", "sweep", "compose" or "rank". A mismatched family is
// IRREGEX_INVALID at the seam, so callers check it before dispatching.
func (o Op) Params() string {
	v, _ := Verb(o)
	return v.Params
}

// Schema is the row schema this op answers with, and whether it may return more
// than one row ([analytic.verbs] `stream`).
func (o Op) Schema() (SchemaDef, bool) {
	v, ok := Verb(o)
	if !ok {
		return SchemaDef{}, false
	}
	return Schema(v.Schema)
}

// Analytic params flag bits (irregex.h IRREGEX_AN_*). The two threshold bits
// exist because 0.0 is a meaningful threshold, so "unset" cannot be zero.
const (
	AnMaxDistance uint32 = 1 << 0
	AnMinEcho     uint32 = 1 << 1
	AnNoIndex     uint32 = 1 << 2
	AnFixed       uint32 = 1 << 3
	AnIgnoreCase  uint32 = 1 << 4
	AnMatchAll    uint32 = 1 << 5
	AnByPattern   uint32 = 1 << 6
	AnByFile      uint32 = 1 << 7
	AnDistinct    uint32 = 1 << 8
)

// MaxFields is the ceiling a row schema may declare, because the presence mask
// is one uint64.
func MaxFields() int { return maxFields }

// SchemaCount is how many row schemas this binding declares (ids are 1..count).
func SchemaCount() int { return len(schemas) }

// Schema resolves a row schema by its wire id.
func Schema(id uint32) (SchemaDef, bool) {
	if id == 0 || int(id) > len(schemas) {
		return SchemaDef{}, false
	}
	return schemas[id-1], true
}

// SchemaByName resolves a row schema by its [row_schemas] key.
func SchemaByName(name string) (SchemaDef, bool) {
	for _, s := range schemas {
		if s.Name == name {
			return s, true
		}
	}
	return SchemaDef{}, false
}

// Verb resolves an analytic verb by op code.
func Verb(op Op) (VerbDef, bool) {
	if op == 0 || int(op) > len(verbs) {
		return VerbDef{}, false
	}
	return verbs[op-1], true
}

// VerbByName resolves an analytic verb by its contract name.
func VerbByName(name string) (VerbDef, bool) {
	for _, v := range verbs {
		if v.Name == name {
			return v, true
		}
	}
	return VerbDef{}, false
}

// Field resolves one declared field by name, with its position in the row's
// value array.
func (s SchemaDef) Field(name string) (FieldDef, int, bool) {
	i, ok := index()[s.ID][name]
	if !ok {
		return FieldDef{}, -1, false
	}
	return s.Fields[i], i, true
}

var index = sync.OnceValue(func() map[uint32]map[string]int {
	byID := make(map[uint32]map[string]int, len(schemas))
	for _, s := range schemas {
		at := make(map[string]int, len(s.Fields))
		for i, f := range s.Fields {
			at[f.Name] = i
		}
		byID[s.ID] = at
	}
	return byID
})

// EnumName is the [row_enums] key a field's Nested id refers to.
func EnumName(id uint32) (string, bool) {
	name, ok := enumByID[id]
	return name, ok
}

// EnumVariants are the labels enum id declares, in ordinal order — what a caller
// rendering choices, or checking an operator's spelling, needs. The copy is
// deliberate: the generated table is shared by every decode on this process.
func EnumVariants(id uint32) ([]string, bool) {
	name, ok := enumByID[id]
	if !ok {
		return nil, false
	}
	return slices.Clone(enums[name]), true
}

// VerbCount is how many analytic verbs this binding declares (ops are 1..count).
func VerbCount() int { return len(verbs) }

// EnumLabel resolves an ordinal within enum id. An ordinal past the variants
// this binding knows is UNKNOWN — ok is false and the caller must surface it as
// such rather than guess a neighbor, because variants are append-only.
func EnumLabel(id uint32, ordinal int64) (string, bool) {
	name, ok := enumByID[id]
	if !ok {
		return "", false
	}
	return labelOf(name, ordinal)
}

// EnumOrdinal resolves a label back to its ordinal within enum id — the reverse
// direction the subprocess transport needs, since a CLI row spells an enum as its
// label. A label this binding does not know is NOT ordinal 0: ok is false, and the
// caller carries it as unknown.
func EnumOrdinal(id uint32, label string) (int64, bool) {
	name, ok := enumByID[id]
	if !ok {
		return 0, false
	}
	return ordinalOf(name, label)
}

func labelOf(enum string, ordinal int64) (string, bool) {
	variants := enums[enum]
	if ordinal < 0 || ordinal >= int64(len(variants)) {
		return "", false
	}
	return variants[ordinal], true
}

func ordinalOf(enum, label string) (int64, bool) {
	for i, v := range enums[enum] {
		if v == label {
			return int64(i), true
		}
	}
	return 0, false
}
