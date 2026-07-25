package runtime

import (
	"errors"
	"strconv"
	"strings"
	"testing"

	irregex "irregex/bindings/go"
)

// schemaOf resolves a contract schema by name, so every expectation below is
// derived from the generated table rather than from a literal this test invented.
func schemaOf(t *testing.T, name string) irregex.SchemaDef {
	t.Helper()
	s, ok := irregex.SchemaByName(name)
	if !ok {
		t.Fatalf("contract declares no row schema %q", name)
	}
	return s
}

// full is the presence mask with every one of n fields present.
func full(n int) uint64 { return 1<<uint(n) - 1 }

// zeros is one tag-correct zero value per declared field — the row a transport
// would hand over with everything present and nothing interesting in it.
func zeros(s irregex.SchemaDef) []Value {
	out := make([]Value, len(s.Fields))
	for i, f := range s.Fields {
		switch irregex.Tag(f.Tag) {
		case irregex.TagInt:
			out[i] = Int(0)
		case irregex.TagFloat:
			out[i] = Float(0)
		case irregex.TagBool:
			out[i] = Bool(false)
		case irregex.TagEnum:
			out[i] = EnumOf(f.Nested, 0)
		case irregex.TagTexts:
			out[i] = Texts(nil)
		case irregex.TagRows:
			out[i] = Nested(nil)
		default:
			out[i] = Text("")
		}
	}
	return out
}

// TestAbsentIsNotZero pins the distinction the presence mask exists for: a
// concept whose byte kinship was never measured must not read as a concept whose
// byte distance is 0.0, because zero distance means identical.
func TestAbsentIsNotZero(t *testing.T) {
	concept := schemaOf(t, "concept")
	_, bytesAt, ok := concept.Field("byte_distance")
	if !ok {
		t.Fatal("concept schema declares no byte_distance")
	}

	values := zeros(concept)
	measured, err := Assemble(concept.ID, values, full(len(concept.Fields)))
	if err != nil {
		t.Fatalf("assemble measured: %v", err)
	}
	if v, ok := measured.OptFloat("byte_distance"); !ok || v != 0 {
		t.Fatalf("byte_distance = (%v, %v), want (0, true) — a measured zero is a measurement", v, ok)
	}

	absent, err := Assemble(concept.ID, values, full(len(concept.Fields))&^(1<<uint(bytesAt)))
	if err != nil {
		t.Fatalf("assemble absent: %v", err)
	}
	if v, ok := absent.OptFloat("byte_distance"); ok {
		t.Fatalf("byte_distance = (%v, true), want absent", v)
	}
	if _, ok := absent.Value("byte_distance"); ok {
		t.Fatal("Value reported an absent field as present")
	}
	if strings.Contains(absent.String(), "byte_distance") {
		t.Fatalf("String() rendered an absent field: %s", absent)
	}
}

// TestUnknownEnumOrdinal pins that an ordinal past this binding's variants stays
// unknown. Guessing it into the nearest known band would turn an engine that
// appended a grade into a silently wrong answer.
func TestUnknownEnumOrdinal(t *testing.T) {
	similar := schemaOf(t, "similar")
	field, at, ok := similar.Field("grade")
	if !ok {
		t.Fatal("similar schema declares no grade")
	}
	variants, ok := irregex.EnumVariants(field.Nested)
	if !ok || len(variants) == 0 {
		t.Fatalf("contract declares no variants for enum id %d", field.Nested)
	}

	values := zeros(similar)
	values[at] = EnumOf(field.Nested, int64(len(variants)))
	row, err := Assemble(similar.ID, values, full(len(similar.Fields)))
	if err != nil {
		t.Fatalf("assemble: %v", err)
	}
	got := row.Enum("grade")
	if got.Known {
		t.Fatalf("ordinal %d resolved to %q, want unknown", got.Ordinal, got.Label)
	}
	if want := "unknown(" + strconv.Itoa(len(variants)) + ")"; got.String() != want {
		t.Fatalf("String() = %q, want %q", got.String(), want)
	}

	values[at] = EnumOf(field.Nested, int64(len(variants))-1)
	row, err = Assemble(similar.ID, values, full(len(similar.Fields)))
	if err != nil {
		t.Fatalf("assemble known: %v", err)
	}
	if last := row.Enum("grade"); !last.Known || last.Label != variants[len(variants)-1] {
		t.Fatalf("last variant = %+v, want %q known", last, variants[len(variants)-1])
	}
}

// TestNestedRows pins recursion into a rows: field, and that a child of the wrong
// schema is refused rather than decoded against the wrong field order.
func TestNestedRows(t *testing.T) {
	blast, site := schemaOf(t, "blast"), schemaOf(t, "site")
	def, err := Assemble(site.ID, []Value{Text("libs/x.zig"), Int(42)}, full(len(site.Fields)))
	if err != nil {
		t.Fatalf("assemble site: %v", err)
	}

	_, at, _ := blast.Field("definitions")
	values := zeros(blast)
	values[at] = Nested([]Row{def})
	row, err := Assemble(blast.ID, values, 1<<uint(at))
	if err != nil {
		t.Fatalf("assemble blast: %v", err)
	}
	nested := row.Rows("definitions")
	if len(nested) != 1 || nested[0].Text("path") != "libs/x.zig" || nested[0].Int("line") != 42 {
		t.Fatalf("nested definitions = %v, want one site{libs/x.zig, 42}", nested)
	}

	wrong := schemaOf(t, "mention")
	stray, err := Assemble(wrong.ID, []Value{Text("a"), Int(1), Text("c")}, full(len(wrong.Fields)))
	if err != nil {
		t.Fatalf("assemble mention: %v", err)
	}
	values[at] = Nested([]Row{stray})
	if _, err := Assemble(blast.ID, values, 1<<uint(at)); err == nil {
		t.Fatal("a child of the wrong schema decoded silently")
	}
}

// TestTagAndSchemaRefusals pins that the decoder fails loudly rather than
// reinterpreting bytes when a transport hands it something the schema disagrees
// with.
func TestTagAndSchemaRefusals(t *testing.T) {
	similar := schemaOf(t, "similar")
	_, at, _ := similar.Field("distance")
	values := zeros(similar)
	values[at] = Int(1) // declared f64
	if _, err := Assemble(similar.ID, values, 1<<uint(at)); err == nil {
		t.Fatal("an integer decoded into a declared f64 field")
	}
	for _, id := range []uint32{0, uint32(irregex.SchemaCount()) + 1} {
		if _, err := Assemble(id, nil, 0); err == nil {
			t.Fatalf("unknown schema id %d assembled", id)
		}
	}
}

// TestShortAndLongValueLists pins the append-only compatibility rule: an older
// engine that sends fewer values leaves the tail absent, and a newer one that
// appended fields stops at this binding's knowledge instead of failing.
func TestShortAndLongValueLists(t *testing.T) {
	site := schemaOf(t, "site")
	short, err := Assemble(site.ID, []Value{Text("a.zig")}, full(1))
	if err != nil {
		t.Fatalf("short: %v", err)
	}
	if short.Len() != 1 {
		t.Fatalf("Len = %d, want 1", short.Len())
	}
	if _, ok := short.OptInt("line"); ok {
		t.Fatal("a field the transport never sent read as present")
	}

	long := append(make([]Value, 0, len(site.Fields)+1), Text("a.zig"), Int(7), Bool(true))
	row, err := Assemble(site.ID, long, full(len(long)))
	if err != nil {
		t.Fatalf("long: %v", err)
	}
	if row.Len() != len(site.Fields) {
		t.Fatalf("Len = %d, want %d (the fields this binding declares)", row.Len(), len(site.Fields))
	}
}

// TestVerbTableAgreesWithSchemas pins the two generated tables against each
// other: every verb's params family must be one the params structs implement, and
// every schema it answers with must resolve.
func TestVerbTableAgreesWithSchemas(t *testing.T) {
	families := map[string]bool{}
	for _, p := range []irregex.Params{irregex.Kinship{}, irregex.Retrieval{}, irregex.Sweep{}, irregex.Compose{}, irregex.Rank{}} {
		families[p.Family()] = true
	}
	for op := irregex.Op(1); int(op) <= irregex.VerbCount(); op++ {
		verb, ok := irregex.Verb(op)
		if !ok {
			t.Fatalf("op %d missing from the verb table", op)
		}
		if !families[verb.Params] {
			t.Errorf("%s declares params family %q, which no params struct implements", verb.Name, verb.Params)
		}
		if _, ok := irregex.Schema(verb.Schema); !ok {
			t.Errorf("%s answers with unknown schema %d", verb.Name, verb.Schema)
		}
	}
	if irregex.Digest == "" {
		t.Error("the generated table carries no digest to check a library against")
	}
}

// TestNextBatchFillsCallerSlice pins the allocation-free shape: NextBatch writes
// into the caller's slice, spans an underlying batch boundary, and reports a clean
// end with 0 rather than an error.
func TestNextBatchFillsCallerSlice(t *testing.T) {
	site := schemaOf(t, "site")
	made := make([]Row, 0, 150)
	for i := range 150 {
		row, err := Assemble(site.ID, []Value{Text("f"), Int(int64(i))}, full(len(site.Fields)))
		if err != nil {
			t.Fatalf("assemble: %v", err)
		}
		made = append(made, row)
	}
	rows := newRows(&sliceSource{rows: made, facts: Stats{Rows: 150, Foreign: 3, Omitted: 7}})
	defer rows.Close()

	dst := make([]Row, 32)
	seen := 0
	for {
		n, err := rows.NextBatch(dst)
		if err != nil {
			t.Fatalf("NextBatch: %v", err)
		}
		if n == 0 {
			break
		}
		for i := range n {
			if got := dst[i].Int("line"); got != int64(seen+i) {
				t.Fatalf("row %d = line %d, want %d — batch boundary lost order", seen+i, got, seen+i)
			}
		}
		seen += n
	}
	if seen != len(made) {
		t.Fatalf("drained %d rows, want %d", seen, len(made))
	}
	if s := rows.Stats(); s.Foreign != 3 || s.Omitted != 7 {
		t.Fatalf("stats = %+v, want foreign 3 / omitted 7 preserved", s)
	}
	if err := rows.Close(); err != nil {
		t.Fatalf("close: %v", err)
	}
	if s := rows.Stats(); s.Omitted != 7 {
		t.Fatalf("stats after Close = %+v, want the final snapshot", s)
	}
}

// TestRowsSurfaceSourceErrors pins that a mid-stream fault reaches the caller
// through Err and through All's final yield, instead of looking like end of stream.
func TestRowsSurfaceSourceErrors(t *testing.T) {
	boom := errors.New("engine went away")
	site := schemaOf(t, "site")
	row, err := Assemble(site.ID, []Value{Text("f"), Int(1)}, full(len(site.Fields)))
	if err != nil {
		t.Fatalf("assemble: %v", err)
	}
	rows := newRows(&sliceSource{rows: []Row{row}, fail: boom})
	var yielded error
	for _, err := range rows.All() {
		if err != nil {
			yielded = err
		}
	}
	if !errors.Is(yielded, boom) || !errors.Is(rows.Err(), boom) {
		t.Fatalf("All yielded %v, Err %v, want %v from both", yielded, rows.Err(), boom)
	}
}

// sliceSource serves already-assembled rows, so the cursor's batching is tested
// without a transport.
type sliceSource struct {
	rows  []Row
	facts Stats
	fail  error
	batch int
}

func (s *sliceSource) fill(dst []Row) (int, error) {
	if len(s.rows) == 0 {
		return 0, s.fail
	}
	// A short fill mid-stream is legal, and is what a real tier does at a page
	// boundary; alternating it here keeps the cursor honest about that.
	limit := len(dst)
	if s.batch++; s.batch%2 == 0 && limit > 5 {
		limit = 5
	}
	n := copy(dst[:limit], s.rows)
	s.rows = s.rows[n:]
	return n, nil
}

func (s *sliceSource) stats() Stats { return s.facts }
func (s *sliceSource) close() error { return nil }
