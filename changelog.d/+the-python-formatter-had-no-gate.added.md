`ruff check` ran here and `ruff format --check` did not, which is half a gate: the lint rules were enforced and the formatting they assume was not. Thirty-four files had drifted out. They are formatted now and the check runs in CI beside the lint, so the two stay in step.

The reformat is mechanical. I parsed all 72 files before and after and the syntax trees are identical, so nothing here changed behavior.
