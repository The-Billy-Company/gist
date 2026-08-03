"""The page a visitor to an index lands on.

Two halves, because there are two of them. `tools/registry_readme.py` corrects
the repository README for any index that is not GitHub; `hatch_readme.py` is the
Hatchling end that hands the result to PyPI and puts a copy in the sdist.
Nothing here needs a built library or a network.
"""

from __future__ import annotations

import importlib.util
import re
import tomllib
from pathlib import Path

import pytest

_PROJECT = Path(__file__).resolve().parents[1]
_REPOSITORY = _PROJECT.parents[1]
_ELSEWHERE = "https://example.invalid/repo"

# A target that resolves against the page displaying it rather than against the
# repository - which on PyPI means `pypi.org/project/<name>/<target>`, a 404.
_RELATIVE = re.compile(r"!?\[[^\]]*\]\((?!#|https?://|mailto:)([^)\s]+)\)")
_HEADING = re.compile(r"^#{1,6} .*", re.M)


def _load(path: Path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(scope="module")
def rewriter():
    """The shared corrector, the one every index's copy comes out of."""
    return _load(_REPOSITORY / "tools" / "registry_readme.py")


@pytest.fixture(scope="module")
def described() -> str:
    """The long description as built, from the hook that builds it."""
    metadata = tomllib.loads((_PROJECT / "pyproject.toml").read_text())["project"]
    _load(_PROJECT / "hatch_readme.py").ProjectReadme(str(_PROJECT), {}).update(metadata)
    return metadata["readme"]["text"]


def test_the_index_shows_the_readme_the_repository_shows(described):
    """One front door. The description is the README a visitor to the repository
    reads, not a second one kept beside the Python sources - which would be a
    document nobody proofreads because nobody following a link ever sees it."""
    readme = (_REPOSITORY / "README.md").read_text()
    assert _HEADING.findall(described) == _HEADING.findall(readme)


def test_no_link_in_the_description_is_relative(described):
    """Relative links are the whole reason this is built rather than read. Every
    index resolves them against its own URL, so each one would 404 on a page
    whose job is to send people to the sources."""
    assert _RELATIVE.findall(described) == []


def test_a_link_to_nothing_fails_the_build(rewriter):
    """Fail closed. A target that is not in the repository would be rewritten
    into a well-formed absolute URL pointing at a file that does not exist - a
    dead link that looks alive, published, in the place it is hardest to
    notice."""
    with pytest.raises(ValueError, match="not in the repository"):
        rewriter.absolutize("src/no/such/file.zig", _REPOSITORY, _ELSEWHERE)


def test_an_image_resolves_to_the_bytes_and_not_to_a_web_page(rewriter):
    """The failure this exists for is silent: point an image at `blob` and the
    URL resolves, returns GitHub's page for the file, and renders as a broken
    image. Nothing 404s, so nothing notices."""
    both = rewriter.rewrite("![plot](README.md)\n[text](README.md)\n", _REPOSITORY, _ELSEWHERE)
    assert f"![plot]({_ELSEWHERE}/raw/main/README.md)" in both
    assert f"[text]({_ELSEWHERE}/blob/main/README.md)" in both


def test_a_code_fence_is_left_as_it_was_written(rewriter):
    """Inside a fence, `[a](b)` is a sample someone is meant to copy, not a link.
    Rewriting it would edit the documented code."""
    rewritten = rewriter.rewrite(
        "```md\n[doc](README.md)\n```\n\n[doc](README.md)\n", _REPOSITORY, _ELSEWHERE
    )
    assert "[doc](README.md)" in rewritten
    assert f"[doc]({_ELSEWHERE}/blob/main/README.md)" in rewritten


def test_the_go_modules_page_is_checked_rather_than_corrected(rewriter):
    """pkg.go.dev renders the Go module's README as written and resolves its
    links against the repository, so that one needs no rewriting - but it can
    still go dead, and there is no build step in a Go module to catch it."""
    module = _REPOSITORY / "bindings/go"
    assert rewriter.dead_targets((module / "README.md").read_text(), module) == []
    planted = "[gone](no/such/file.go)\n\n```md\n[fine](also/absent.go)\n```\n"
    assert rewriter.dead_targets(planted, module) == ["no/such/file.go"]


def test_the_base_is_the_address_the_package_claims(rewriter):
    """Read from the manifest, never passed in. A hand-supplied base could send
    readers of one package's page at another package's repository, and the page
    would look perfectly well-formed while doing it."""
    for manifest in (_PROJECT / "pyproject.toml", _REPOSITORY / "bindings/rust/Cargo.toml"):
        assert rewriter.declared_repository(manifest).startswith("https://")


def test_an_sdist_reads_the_copy_it_carries(tmp_path):
    """An sdist is the one artifact with no repository above it. It ships the
    corrected README instead, already rewritten at the end that had every target
    to check - so a source build gets the same description as a release build
    rather than failing on a file the archive does not contain."""
    hook = _load(_PROJECT / "hatch_readme.py")
    project = tmp_path / "checkout" / "bindings" / "python"
    project.mkdir(parents=True)
    (project / hook.SHIPPED).write_text("# shipped\n")
    assert hook._description(project, _ELSEWHERE) == "# shipped\n"
