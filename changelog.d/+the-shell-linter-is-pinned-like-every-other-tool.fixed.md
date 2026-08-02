The discipline job's shell linter is pinned now, like everything else it runs.

Every other tool in that job is a Python distribution installed at an exact version into uv's isolated environment, so the job's verdict moves when we move it and not when a tool ships a release. ShellCheck was the one exception and came with the runner image, which meant a runner carrying an older build could report a finding nobody here caused - SC2317 against a `trap`-invoked cleanup that newer ShellCheck reads correctly. Pinning `shellcheck-py` closes the gap over all thirty-six tracked scripts.
