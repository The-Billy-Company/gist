// The cold tier's raising half: a child's NDJSON back into rows of the verb's
// declared schema. It is the mirror of plan.go — that file spells a query as argv,
// this one reads the answer — and the two are kept apart because a CLI's row
// vocabulary drifts on a different clock than its flag vocabulary.

package runtime

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"

	irregex "irregex/bindings/go"
)

// jsonKeys maps a schema field onto the JSON path(s) a CLI row spells it with,
// first present winning. Most fields need no entry — the names already agree —
// so this table is exactly the divergences, and a row field with no entry and no
// matching key decodes as ABSENT rather than as a zero.
var jsonKeys = map[string][]string{
	"similar.path":                {"unit", "path"},
	"recalled.path":               {"unit", "path"},
	"echo.byte_distance":          {"bytes"},
	"echo.structure_distance":     {"structure"},
	"concept.byte_distance":       {"bytes"},
	"concept.structure_distance":  {"structure"},
	"cluster.paths":               {"members", "paths"},
	"cluster.max_distance":        {"distance", "max_distance"},
	"family.edge":                 {"echo", "distance"},
	"family.score":                {"distance", "echo"},
	"distinct.member":             {"unit", "member"},
	"distinct.byte_distance":      {"bytes"},
	"distinct.structure_distance": {"structure"},
	"blast.symbol":                {"seed.symbol"},
	"blast.kind":                  {"seed.kind"},
	"blast.definitions":           {"seed.def"},
	"blast.dependents":            {"direct.dependents"},
	"blast.dependencies":          {"direct.dependencies"},
	"blast.twins":                 {"tangential.twins"},
	"blast.ripple":                {"tangential.ripple"},
	"blast.omitted":               {"stats.omitted"},
	"reference.enclosing":         {"in", "enclosing"},
	"reference.defines":           {"use", "defines"},
	"region.line_start":           {"line", "line_start"},
	"region.line_end":             {"line_end", "line"},
}

// rowsPerObject decodes one JSON object per line into one row of schema.
func rowsPerObject(schema uint32, stdout string) ([]Row, error) {
	objects, err := ndjson(stdout)
	if err != nil {
		return nil, err
	}
	answer := summary(stdout, "")
	rows := make([]Row, 0, len(objects))
	for _, obj := range objects {
		row, err := rowFromJSON(schema, obj, answer)
		if err != nil {
			return nil, err
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// headThenRows decodes the one-row verbs whose CLI prints a summary object and
// then the members of its nested field (quote's phrases).
func headThenRows(schema uint32, stdout string) ([]Row, error) {
	objects, err := ndjson(stdout)
	if err != nil || len(objects) == 0 {
		return nil, err
	}
	def, ok := irregex.Schema(schema)
	if !ok {
		return nil, fmt.Errorf("irregex: unknown row schema id %d", schema)
	}
	head, err := rowFromJSON(schema, objects[0], nil)
	if err != nil {
		return nil, err
	}
	for i, f := range def.Fields {
		if irregex.Tag(f.Tag) != irregex.TagRows {
			continue
		}
		children := make([]Row, 0, len(objects)-1)
		for _, obj := range objects[1:] {
			child, err := rowFromJSON(f.Nested, obj, nil)
			if err != nil {
				return nil, err
			}
			children = append(children, child)
		}
		head.values[i] = Nested(children)
		head.present |= 1 << uint(i)
		break
	}
	return []Row{head}, nil
}

// rankRow is one `--rank` line: index, path:line, the engine's own def/use/gen
// class, the per-file count behind a multiplication sign, then the snippet. Rank
// is the one verb whose CLI answer is a rendered view rather than NDJSON.
var rankRow = regexp.MustCompile(`^\s*\d+\.\s+(.+?):(\d+)\s+\[(def|use|gen)\]\s+\x{00d7}(\d+)\s*(.*)$`)

var rankClass = map[string]string{"def": "definition", "use": "use", "gen": "generated"}

func rankedRows(schema uint32, stdout string) ([]Row, error) {
	var rows []Row
	for line := range strings.SplitSeq(stdout, "\n") {
		m := rankRow.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		row, err := rowFromJSON(schema, map[string]any{
			"path":        m[1],
			"line_number": m[2],
			"kind":        rankClass[m[3]],
			"count":       m[4],
			"snippet":     m[5],
		}, nil)
		if err != nil {
			return nil, err
		}
		rows = append(rows, row)
	}
	return rows, nil
}

// inherited names the row fields the CLI states once per answer instead of once
// per row, mapped to the summary key that carries them. These are not guesses: the
// summary asserts the unit and channel the whole answer was computed in, and the
// row's own same-named key means something else entirely (a member path).
var inherited = map[string]string{
	"family.unit":    "unit",
	"family.channel": "channel",
	"distinct.unit":  "unit",
}

// rowFromJSON assembles one row of schema from a decoded JSON object, with answer
// the verb's summary record (nil when there is none). It walks the schema's
// declared fields — never the object's keys — so a field the tool did not report
// stays absent, and a key the contract does not declare cannot smuggle itself into
// a row.
func rowFromJSON(schema uint32, obj, answer map[string]any) (Row, error) {
	def, ok := irregex.Schema(schema)
	if !ok {
		return Row{}, fmt.Errorf("irregex: unknown row schema id %d", schema)
	}
	values, present := make([]Value, len(def.Fields)), uint64(0)
	for i, f := range def.Fields {
		raw, found := lookup(obj, answer, def.Name, f.Name)
		if !found || raw == nil {
			continue
		}
		v, ok, err := valueFromJSON(f, raw)
		if err != nil {
			return Row{}, fmt.Errorf("irregex: %s.%s: %w", def.Name, f.Name, err)
		}
		if !ok {
			continue
		}
		values[i] = v
		present |= 1 << uint(i)
	}
	return Assemble(schema, values, present)
}

func lookup(obj, answer map[string]any, schema, field string) (any, bool) {
	if key, ok := inherited[schema+"."+field]; ok {
		if v, ok := answer[key]; ok && v != nil {
			return v, true
		}
	}
	paths := jsonKeys[schema+"."+field]
	if paths == nil {
		paths = []string{field}
	}
	for _, path := range paths {
		if v, ok := walk(obj, path); ok && v != nil {
			return v, true
		}
	}
	return nil, false
}

func walk(obj map[string]any, path string) (any, bool) {
	cur := any(obj)
	for step := range strings.SplitSeq(path, ".") {
		node, ok := cur.(map[string]any)
		if !ok {
			return nil, false
		}
		if cur, ok = node[step]; !ok {
			return nil, false
		}
	}
	return cur, true
}

// valueFromJSON coerces one JSON value into its declared tag. ok is false when
// the tool reported something that is not a measurement — a non-finite number, an
// enum label this binding does not know — which is absence, not a zero.
func valueFromJSON(f irregex.FieldDef, raw any) (Value, bool, error) {
	switch irregex.Tag(f.Tag) {
	case irregex.TagText:
		return Text(text(raw)), true, nil
	case irregex.TagInt:
		n, ok := number(raw)
		return Int(int64(n)), ok, nil
	case irregex.TagFloat:
		n, ok := number(raw)
		return Float(n), ok, nil
	case irregex.TagBool:
		return Bool(truthy(raw)), true, nil
	case irregex.TagEnum:
		return enumValue(f.Nested, raw)
	case irregex.TagTexts:
		items, ok := raw.([]any)
		if !ok {
			return Value{}, false, fmt.Errorf("expected a list, got %T", raw)
		}
		out := make([]string, len(items))
		for i, item := range items {
			out[i] = text(item)
		}
		return Texts(out), true, nil
	case irregex.TagRows:
		// A single-member nested field (distinct's member and its nearest miss)
		// arrives unwrapped, so one row and a list of one are the same answer.
		items, ok := raw.([]any)
		if !ok {
			items = []any{raw}
		}
		rows := make([]Row, 0, len(items))
		for _, item := range items {
			child, err := childRow(f.Nested, item)
			if err != nil {
				return Value{}, false, err
			}
			rows = append(rows, child)
		}
		return Nested(rows), true, nil
	}
	return Value{}, false, fmt.Errorf("field declares tag %d, which this decoder does not know", f.Tag)
}

// childRow decodes one nested member. A member may arrive as an object, or — for
// the family and cluster shapes — as the string `path#Lnnn`, which lifts into the
// nested schema's own path/line fields rather than being dropped.
func childRow(schema uint32, item any) (Row, error) {
	if obj, ok := item.(map[string]any); ok {
		return rowFromJSON(schema, obj, nil)
	}
	path, line, found := strings.Cut(text(item), "#L")
	lifted := map[string]any{"path": path}
	if found {
		if n, err := strconv.ParseInt(line, 10, 64); err == nil {
			lifted["line"] = float64(n)
		}
	}
	return rowFromJSON(schema, lifted, nil)
}

func enumValue(id uint32, raw any) (Value, bool, error) {
	if label, ok := raw.(string); ok {
		ordinal, known := irregex.EnumOrdinal(id, label)
		if !known {
			// A label this table cannot name must not become a neighboring
			// ordinal; -1 is outside every variant list, so it reads back unknown.
			return EnumOf(id, -1), true, nil
		}
		return EnumOf(id, ordinal), true, nil
	}
	n, ok := number(raw)
	return EnumOf(id, int64(n)), ok, nil
}

func text(raw any) string {
	switch v := raw.(type) {
	case nil:
		return ""
	case string:
		return v
	case float64:
		return strconv.FormatFloat(v, 'g', -1, 64)
	case bool:
		return strconv.FormatBool(v)
	default:
		return fmt.Sprint(v)
	}
}

// number narrows a JSON scalar to a finite float. A non-finite value (the engine
// prints a bare `nan` for a channel it could not measure) is NOT a measurement,
// so it reads as absent.
func number(raw any) (float64, bool) {
	switch v := raw.(type) {
	case float64:
		return v, !math.IsNaN(v) && !math.IsInf(v, 0)
	case bool:
		if v {
			return 1, true
		}
		return 0, true
	case string:
		f, err := strconv.ParseFloat(v, 64)
		return f, err == nil && !math.IsNaN(f) && !math.IsInf(f, 0)
	}
	return 0, false
}

// truthy reads a boolean field. The CLI spells one as a JSON bool, or as the
// classifier that decided it (`"use": "def"` behind `reference.defines`).
func truthy(raw any) bool {
	switch v := raw.(type) {
	case bool:
		return v
	case string:
		switch v {
		case "def", "true", "yes", "verified":
			return true
		}
		return false
	case float64:
		return v != 0
	}
	return false
}

// ndjson decodes a verb's stdout — one JSON object per non-empty line — and
// withholds the summary record. Every face marks that record with a "verb" key
// and no row schema declares such a field, so the discriminator is the CLI's own
// convention rather than a position: pack prints its summary last, echoes first.
func ndjson(stdout string) ([]map[string]any, error) {
	var out []map[string]any
	for line := range strings.SplitSeq(stdout, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] != '{' {
			continue
		}
		var obj map[string]any
		if err := json.Unmarshal(finite([]byte(line)), &obj); err != nil {
			return nil, fmt.Errorf("irregex: undecodable row from the engine: %w", err)
		}
		if _, isSummary := obj["verb"]; !isSummary {
			out = append(out, obj)
		}
	}
	return out, nil
}

// summary is the verb's own account of the answer, read from stdout where the
// faces print it now and from stderr for a binary that still prints it there.
func summary(stdout, stderr string) map[string]any {
	for line := range strings.SplitSeq(stdout, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line[0] != '{' {
			continue
		}
		var obj map[string]any
		if json.Unmarshal(finite([]byte(line)), &obj) == nil {
			if _, ok := obj["verb"]; ok {
				return obj
			}
		}
	}
	return diagnostic(stderr)
}

// finite rewrites the bare `nan` / `inf` tokens the engine prints for an
// unmeasurable channel into JSON `null`. They are not JSON, and a strict decoder
// would reject the whole row over a field the answer does not depend on; null
// carries the same meaning the presence mask does — not measured.
func finite(line []byte) []byte {
	var out []byte
	for i, inString := 0, false; i < len(line); {
		switch c := line[i]; {
		case c == '"':
			inString = !inString
			out, i = append(out, c), i+1
		case c == '\\' && inString && i+1 < len(line):
			out, i = append(out, c, line[i+1]), i+2
		case !inString && (c == 'n' || c == 'i' || c == '-'):
			if n := nonFinite(line[i:]); n > 0 {
				out, i = append(out, "null"...), i+n
				continue
			}
			out, i = append(out, c), i+1
		default:
			out, i = append(out, c), i+1
		}
	}
	return out
}

func nonFinite(s []byte) int {
	for _, token := range [...]string{"-nan", "-inf", "-infinity", "nan", "inf", "infinity"} {
		if len(s) >= len(token) && strings.EqualFold(string(s[:len(token)]), token) {
			return len(token)
		}
	}
	return 0
}

// diagnostic is the verb's stderr summary record under --json — how large a
// population the answer was drawn from, and whether it came warm from a persisted
// artifact or from a live build.
func diagnostic(stderr string) map[string]any {
	for _, raw := range slices.Backward(strings.Split(stderr, "\n")) {
		line := strings.TrimSpace(raw)
		if line == "" || line[0] != '{' {
			continue
		}
		var obj map[string]any
		if json.Unmarshal(finite([]byte(line)), &obj) == nil {
			return obj
		}
	}
	return nil
}
