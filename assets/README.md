---
doc_radar:
  counts:
    - description: "checked-in README figures stay as the five published PNGs"
      glob: assets/*.png
      unit: files
      equals: 5
---

# `assets/` — README / certificate figures

Checked-in PNGs embedded by the package narrative and Dominance-and-Fit
Certificate write-ups. **Not** runtime inputs — the engine never opens this
folder.

| File                        | Typical use                         |
| --------------------------- | ----------------------------------- |
| `gist-certify-forest.png`   | Certificate forest / layer overview |
| `gist-cold-field.png`       | Cold-path field race summary        |
| `gist-regex-matrix.png`     | Regex engine admission / matrix     |
| `gist-scan-progression.png` | Scan / verify progression           |
| `gist-warm-dominance.png`   | Warm-path dominance evidence        |

Regenerate from real bench artifacts after an evidence refresh (see
[`../bench/`](../bench/) and the repo `bviz` / dataviz pipeline) — do not
hand-draw replacements that disagree with the gates.
