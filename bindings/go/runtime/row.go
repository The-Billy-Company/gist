// Package runtime carries the kernel to the verbs: the cgo declarations, the
// analytic dispatch, the one schema-driven row decoder, the subprocess runner,
// and the ladder between them.
//
// Two tiers answer every analytic verb. The in-process plane (ADR-377) dispatches
// through irregex_analytic_run when this build has cgo, the library exports the
// plane, and its row-schema digest matches the table this decoder was generated
// from. Otherwise — no cgo, no plane, no library, or a tier that DECLINES
// (IRREGEX_STALE) — the same verb answers by running the certified `gist` /
// `relate` / `irregex` binary and decoding its NDJSON. The two produce identical
// rows, so which tier answered is a fact about speed, reported in [Stats], and
// never an error.
//
// A row is decoded once, generically: [Assemble] walks a schema's declared fields
// positionally over the values a transport handed it, honoring the presence mask
// (absent is not zero), resolving enum ordinals through the generated table, and
// recursing into nested rows. There is no per-verb decoder to drift.
package runtime

import (
	"fmt"
	"iter"
	"strconv"
	"strings"
	"time"

	irregex "irregex/bindings/go"
)

// Enum is a decoded enum field: the ordinal is the ABI, the label is this
// binding's reading of it. An ordinal past the variants this binding knows is
// Known == false — appended variants must surface as unknown, never be guessed
// into a neighbor.
type Enum struct {
	Enum    string
	Ordinal int64
	Label   string
	Known   bool
}

func (e Enum) String() string {
	if e.Known {
		return e.Label
	}
	return "unknown(" + strconv.FormatInt(e.Ordinal, 10) + ")"
}

// Value is one decoded row field. Tag selects which accessor carries the
// payload; the others are zero.
type Value struct {
	Tag    irregex.Tag
	num    int64
	real   float64
	text   string
	texts  []string
	rows   []Row
	enumID uint32
}

// Text builds a TEXT value.
func Text(s string) Value { return Value{Tag: irregex.TagText, text: s} }

// Int builds an I64 value.
func Int(i int64) Value { return Value{Tag: irregex.TagInt, num: i} }

// Float builds an F64 value.
func Float(f float64) Value { return Value{Tag: irregex.TagFloat, real: f} }

// Bool builds a BOOL value.
func Bool(b bool) Value {
	v := Value{Tag: irregex.TagBool}
	if b {
		v.num = 1
	}
	return v
}

// EnumOf builds an ENUM value for enum id and ordinal, resolving the label
// against this binding's table.
func EnumOf(id uint32, ordinal int64) Value {
	return Value{Tag: irregex.TagEnum, num: ordinal, enumID: id}
}

// Texts builds a TEXTS (string list) value.
func Texts(ss []string) Value { return Value{Tag: irregex.TagTexts, texts: ss} }

// Nested builds a ROWS value from already-assembled child rows.
func Nested(rows []Row) Value { return Value{Tag: irregex.TagRows, rows: rows} }

// Str is the value's text ("" for any other tag).
func (v Value) Str() string { return v.text }

// I64 is the value's integer (also a bool's 0/1 and an enum's ordinal).
func (v Value) I64() int64 { return v.num }

// F64 is the value's real (0 for any other tag).
func (v Value) F64() float64 { return v.real }

// Bool is the value's boolean.
func (v Value) Bool() bool { return v.num != 0 }

// Enum is the value's resolved enum.
func (v Value) Enum() Enum {
	name, _ := irregex.EnumName(v.enumID)
	label, ok := irregex.EnumLabel(v.enumID, v.num)
	return Enum{Enum: name, Ordinal: v.num, Label: label, Known: ok}
}

// Strings is the value's string list.
func (v Value) Strings() []string { return v.texts }

// Rows is the value's nested rows.
func (v Value) Rows() []Row { return v.rows }

// Row is one decoded analytic result. Its schema is the field order, and the
// presence mask distinguishes an absent field from a zero one — `distance = 0.0`
// means identical, so "no distance" and "no distance between them" cannot share a
// spelling.
type Row struct {
	schema  irregex.SchemaDef
	values  []Value
	present uint64
}

// Assemble decodes positional values against row schema id. It fails — rather
// than mis-reading — when the schema is unknown or a value's tag disagrees with
// the field's declaration. A short value list (an older engine) leaves the tail
// absent, and a long one (a newer engine that appended fields) stops at this
// binding's knowledge, which is what makes the field list append-only-compatible.
func Assemble(id uint32, values []Value, present uint64) (Row, error) {
	schema, ok := irregex.Schema(id)
	if !ok {
		return Row{}, fmt.Errorf("irregex: unknown row schema id %d (this binding declares 1..%d)", id, irregex.SchemaCount())
	}
	n := min(len(values), len(schema.Fields))
	row := Row{schema: schema, values: values[:n:n], present: present & mask(n)}
	for i, v := range row.values {
		if !row.at(i) {
			continue
		}
		f := schema.Fields[i]
		if v.Tag != irregex.Tag(f.Tag) {
			return Row{}, fmt.Errorf("irregex: %s.%s declared %s, decoded %s", schema.Name, f.Name, irregex.Tag(f.Tag), v.Tag)
		}
		if v.Tag == irregex.TagRows {
			for _, child := range v.rows {
				if child.schema.ID != f.Nested {
					return Row{}, fmt.Errorf("irregex: %s.%s nests schema %d, decoded %d", schema.Name, f.Name, f.Nested, child.schema.ID)
				}
			}
		}
	}
	return row, nil
}

func mask(n int) uint64 {
	if n >= 64 {
		return ^uint64(0)
	}
	return 1<<uint(n) - 1
}

// Schema is the row's declared schema.
func (r Row) Schema() irregex.SchemaDef { return r.schema }

// Len is how many fields this row carries.
func (r Row) Len() int { return len(r.values) }

func (r Row) at(i int) bool { return r.present&(1<<uint(i)) != 0 }

// Value reads one field. ok is false when the field is absent or the schema does
// not declare it — never a zero standing in for either.
func (r Row) Value(field string) (Value, bool) {
	_, i, ok := r.schema.Field(field)
	if !ok || i >= len(r.values) || !r.at(i) {
		return Value{}, false
	}
	return r.values[i], true
}

// At reads field i positionally, for a caller walking a schema it already holds.
func (r Row) At(i int) (Value, bool) {
	if i < 0 || i >= len(r.values) || !r.at(i) {
		return Value{}, false
	}
	return r.values[i], true
}

// Text reads a text field, "" when absent.
func (r Row) Text(field string) string { v, _ := r.Value(field); return v.Str() }

// Int reads an integer field, 0 when absent.
func (r Row) Int(field string) int64 { v, _ := r.Value(field); return v.I64() }

// Float reads a real field, 0 when absent — use [Row.OptFloat] wherever zero is
// a meaningful measurement.
func (r Row) Float(field string) float64 { v, _ := r.Value(field); return v.F64() }

// Bool reads a boolean field, false when absent.
func (r Row) Bool(field string) bool { v, _ := r.Value(field); return v.Bool() }

// Enum reads an enum field; an absent one is Known == false with ordinal 0.
func (r Row) Enum(field string) Enum {
	v, ok := r.Value(field)
	if !ok {
		if f, _, declared := r.schema.Field(field); declared {
			name, _ := irregex.EnumName(f.Nested)
			return Enum{Enum: name}
		}
		return Enum{}
	}
	return v.Enum()
}

// Strings reads a string-list field, nil when absent.
func (r Row) Strings(field string) []string { v, _ := r.Value(field); return v.Strings() }

// Rows reads a nested-row field, nil when absent.
func (r Row) Rows(field string) []Row { v, _ := r.Value(field); return v.Rows() }

// OptText reads a text field with its presence.
func (r Row) OptText(field string) (string, bool) {
	v, ok := r.Value(field)
	return v.Str(), ok
}

// OptInt reads an integer field with its presence.
func (r Row) OptInt(field string) (int64, bool) {
	v, ok := r.Value(field)
	return v.I64(), ok
}

// OptFloat reads a real field with its presence — the accessor a threshold or a
// distance must use, because 0.0 is a measurement and absence is not.
func (r Row) OptFloat(field string) (float64, bool) {
	v, ok := r.Value(field)
	return v.F64(), ok
}

// String renders the row as `schema{field=value, …}`, absent fields omitted.
func (r Row) String() string {
	var b strings.Builder
	b.WriteString(r.schema.Name)
	b.WriteByte('{')
	first := true
	for i, f := range r.schema.Fields[:len(r.values)] {
		v, ok := r.At(i)
		if !ok {
			continue
		}
		if !first {
			b.WriteString(", ")
		}
		first = false
		b.WriteString(f.Name)
		b.WriteByte('=')
		switch v.Tag {
		case irregex.TagText:
			b.WriteString(strconv.Quote(v.Str()))
		case irregex.TagFloat:
			b.WriteString(strconv.FormatFloat(v.F64(), 'g', 4, 64))
		case irregex.TagBool:
			b.WriteString(strconv.FormatBool(v.Bool()))
		case irregex.TagEnum:
			b.WriteString(v.Enum().String())
		case irregex.TagTexts:
			fmt.Fprintf(&b, "[%d]", len(v.Strings()))
		case irregex.TagRows:
			fmt.Fprintf(&b, "%s[%d]", nestedName(f.Nested), len(v.Rows()))
		default:
			b.WriteString(strconv.FormatInt(v.I64(), 10))
		}
	}
	b.WriteByte('}')
	return b.String()
}

func nestedName(id uint32) string {
	if s, ok := irregex.Schema(id); ok {
		return s.Name
	}
	return "schema?"
}

// Stats are the answer-level facts no row can carry (irregex_rows_stats).
// Foreign is load-bearing for the retrieval verbs: it counts query fingerprints
// the corpus has NEVER seen, which is how "your text isn't in this repo" stays
// distinguishable from "no results". Omitted is what a budget trimmed, so a
// truncated answer says so.
type Stats struct {
	Source          uint32
	Elapsed         time.Duration
	FilesConsidered uint64
	Refreshed       uint64
	Foreign         uint64
	Omitted         uint64
	Rows            uint64
}

// Warm reports whether a persisted artifact (the atlas or the codex shelf)
// answered rather than a live build.
func (s Stats) Warm() bool { return s.Source != irregex.SourceLive }

// SourceName names the tier that answered.
func (s Stats) SourceName() string {
	switch s.Source {
	case irregex.SourceAtlas:
		return "atlas"
	case irregex.SourceShelf:
		return "shelf"
	default:
		return "live"
	}
}

// rows is a tier's row supply: fill writes into a caller slice and reports how
// many it wrote (0 = end of stream).
type source interface {
	fill(dst []Row) (int, error)
	stats() Stats
	close() error
}

// Rows is a pull cursor over one analytic answer. Drive it scanner-style with
// [Rows.Next] / [Rows.Row], range over [Rows.All], or fill your own slice with
// [Rows.NextBatch] to keep allocation off the hot path. Free it with
// [Rows.Close].
type Rows struct {
	src   source
	batch []Row
	held  []Row
	cur   Row
	last  Stats
	err   error
	done  bool
}

// defaultBatch is the rows-per-native-call [Rows.Next] pulls under the hood —
// enough to amortize the cgo crossing without holding a large transient buffer.
const defaultBatch = 64

func newRows(src source) *Rows {
	return &Rows{src: src, batch: make([]Row, defaultBatch)}
}

// Next advances to the next row, returning false at end of stream or on error
// (check [Rows.Err]).
func (r *Rows) Next() bool {
	if len(r.held) == 0 {
		if r.done || r.err != nil {
			return false
		}
		n, err := r.src.fill(r.batch)
		switch {
		case err != nil:
			r.err = err
			return false
		case n == 0:
			r.done = true
			return false
		}
		r.held = r.batch[:n]
	}
	r.cur, r.held = r.held[0], r.held[1:]
	return true
}

// Row is the row the last [Rows.Next] landed on.
func (r *Rows) Row() Row { return r.cur }

// NextBatch fills dst with up to len(dst) rows and returns how many it wrote; 0
// is a clean end of stream. Rows are Go-owned, so a caller may keep every batch
// it pulls.
func (r *Rows) NextBatch(dst []Row) (int, error) {
	if r.err != nil {
		return 0, r.err
	}
	n := copy(dst, r.held)
	r.held = r.held[n:]
	if n == len(dst) || r.done {
		return n, nil
	}
	more, err := r.src.fill(dst[n:])
	if err != nil {
		r.err = err
		return n, err
	}
	if more == 0 {
		r.done = true
	}
	return n + more, nil
}

// All ranges over the remaining rows. The final yield carries any error with a
// zero Row; a clean end yields nothing extra.
func (r *Rows) All() iter.Seq2[Row, error] {
	return func(yield func(Row, error) bool) {
		for r.Next() {
			if !yield(r.cur, nil) {
				return
			}
		}
		if r.err != nil {
			yield(Row{}, r.err)
		}
	}
}

// Collect drains the cursor into one slice — the shape most verbs want, since a
// `--top` bounded answer is small by construction.
func (r *Rows) Collect() ([]Row, error) {
	var out []Row
	for r.Next() {
		out = append(out, r.cur)
	}
	return out, r.err
}

// Err is the failure that stopped iteration, or nil at a clean end of stream.
func (r *Rows) Err() error { return r.err }

// Stats are this answer's tier, timings and counters. They are final once the
// cursor is drained, and survive [Rows.Close].
func (r *Rows) Stats() Stats {
	if r.src != nil {
		r.last = r.src.stats()
	}
	return r.last
}

// Close releases the answer (idempotent).
func (r *Rows) Close() error {
	if r.src == nil {
		return nil
	}
	src := r.src
	r.last = src.stats()
	r.src, r.held, r.done = nil, nil, true
	return src.close()
}
