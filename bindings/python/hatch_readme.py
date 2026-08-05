"""Hatchling hooks: the project's README is the PyPI landing page.

The distribution's long description is the repository's own ``README.md``, two
levels up, not a Python-flavored retelling of it beside this file. There is one
front door and PyPI opens onto it.

It cannot be handed over verbatim - a relative link resolves against whatever
page displays it, so every one of them would 404 under ``pypi.org``. Correcting
that is ``tools/registry_readme.py``'s job, shared with the crates.io copy so
one rewriter serves every index. This file is the Hatchling end of it: a
metadata hook that hands the corrected page to PyPI, and a build hook that puts
it inside the sdist.

The sdist is the one artifact with no repository above it. It carries the
corrected copy so a source build reads that instead of being asked for a file
the archive does not contain - which is also why the rewriter is loaded lazily
here, since ``tools/`` is not in the sdist either.
"""

from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path
from typing import Any

from hatchling.builders.hooks.plugin.interface import BuildHookInterface
from hatchling.metadata.plugin.interface import MetadataHookInterface

SHIPPED = "PROJECT_README.md"


def _rewriter(path: Path):
    spec = importlib.util.spec_from_file_location("registry_readme", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _description(project: Path, repo: str) -> str:
    """The corrected README, from the repository if it is there and from the copy
    an sdist carries if it is not. The rewriter's presence is what says which
    case this is - it is the repository's, and an sdist has no repository above
    it. Rewriting happens once, at the end that can check every target."""
    root = project.parents[1]
    if (rewriter := root / "tools" / "registry_readme.py").is_file():
        return _rewriter(rewriter).render(root, repo)
    return (project / SHIPPED).read_text(encoding="utf-8")


class ProjectReadme(MetadataHookInterface):
    PLUGIN_NAME = "custom"

    def update(self, metadata: dict[str, Any]) -> None:
        metadata["readme"] = {
            "content-type": "text/markdown",
            "text": _description(
                Path(self.root).resolve(), metadata["urls"]["Repository"].rstrip("/")
            ),
        }


class ShipTheDescription(BuildHookInterface):
    """Put the corrected README in the sdist, so a source build has one to read."""

    PLUGIN_NAME = "custom"

    def initialize(self, version: str, build_data: dict[str, Any]) -> None:
        if self.target_name != "sdist":
            return
        project = Path(self.root).resolve()
        repo = self.metadata.core.urls["Repository"].rstrip("/")
        # Held on the instance so the file outlives this call and is still there
        # when hatchling reads what it was told to include.
        self._staging = tempfile.TemporaryDirectory(prefix="project-readme-")
        shipped = Path(self._staging.name) / SHIPPED
        shipped.write_text(_description(project, repo), encoding="utf-8")
        build_data.setdefault("force_include", {})[str(shipped)] = SHIPPED

    def finalize(self, version: str, build_data: dict[str, Any], artifact_path: str) -> None:
        if staging := getattr(self, "_staging", None):
            staging.cleanup()
            self._staging = None
