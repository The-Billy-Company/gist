---
doc_radar:
  sentinels:
    - file: pkg/kernels/irregex/contract/search_api.toml
      contains: ["[row_enums]", "[row_schemas]", "[analytic.verbs]"]
      description: The row-schema table this package mirrors is a contract section, not a Python declaration.
---

# `irregex.contract` — the mirrored contract

Everything in this package is **generated from or checked against**
`pkg/kernels/irregex/contract/search_api.toml`. Nothing here decides anything; it is what the rest of
the binding is allowed to believe.

| Module             | What it carries                                                                                                                                                |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `abi.py`           | the mirrored TOML constants — engine/ABI versions, the request-option vocabulary and agent aliases, statuses, exit codes, match kinds                          |
| `grades.py`        | the kinship calibration: channels, grade bands, `grade_of` — mirroring `pkg/kernels/irregex/src/kernel/kinship/metric/channel.zig`, which stays the authority |
| `table.py`         | an indexed view of `schema.gen.py`: row schemas, their fields, the enum tables, and each verb's `(op, params family, schema, streams-many)` row                |
| `../schema.gen.py` | the generated table itself — produced by `pkg/kernels/irregex/tools/build_schema_tables.py`, never hand-edited                                                |

`table.DIGEST` is the fingerprint the runtime compares against
`irregex_schema_digest()` before it decodes a single native row. If the two
disagree, the library and this table describe different rows, and every field
read would be plausible and wrong — see `../runtime/README.md`.

The one deliberate asymmetry: `grades.py` holds _calibration_, which the Zig
kernel owns and this side only mirrors so a decoded band is comparable
(`row.grade.meets("strong")`). `pkg/kernels/irregex/bindings/python/tests/test_grade_parity.py` reads the Zig source
as its oracle.
