# bench/certificate/guard

The **gates that stand between a mint and a release** — reproducibility, layer
completeness, ratio floors, and cross-machine coverage. `artifacts.py` imports
`layers.py` and `release.py` imports `artifacts.py`, so all four stay siblings.

| File                  | Guard                                                                                                                                                                                  |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `layers.py`           | the **layer roster** — one row per layer (ledger probe · strict header · side-car), read by the ledger, `artifacts.py`, and `splice.sh`, so adding a layer is one row not three copies |
| `artifacts.py`        | **reproducibility gate** — required files + Layer B–G headers/side-cars + corpus hashes + tool identities + raw-cell matrix (was `check_artifacts.py`)                                 |
| `release.py`          | **release gate** — refuses a release until a valid certificate is attached for **both** the Mac and the Linux machine; run by Town Crier / `changelog build` (was `check_release.py`)  |
| `ratio.py`            | principia-style **ratio** regression — committed `../artifact/certify_macro.csv` vs `ratio_baseline.json` floors; live remeasure behind `GIST_BENCH=1` (was `ratio_regress.py`)        |
| `ratio_baseline.json` | min gist/rg cold-speedup floors (hardware cancels; refresh only after a deliberate republish)                                                                                          |
| `test_release.py`     | unit test for the release gate                                                                                                                                                         |

```bash
python3 bench/certificate/guard/release.py         # 0 only when both machines are covered
python3 bench/certificate/guard/ratio.py --committed
```
