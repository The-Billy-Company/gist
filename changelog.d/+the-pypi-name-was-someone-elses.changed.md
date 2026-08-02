The Python distribution is `gist-search`; the import is still `gist`. `gist` on
PyPI belongs to an unrelated author, so the name was never available to publish
under - and, worse, a plain `pip install gist` fetches that stranger's package
into a tree that then imports `gist` and gets whatever it contains. Splitting
the two names closes that: `pip install gist-search`, `import gist`, which is
the same shape bs4, PIL, and cv2 already ship. Only `[project].name` moved; the
package directory, the wheel's `packages` entry, and every `import gist` in the
tree are untouched, so nothing a caller writes changes. The release workflow was
already publishing under `gist-search`, and `contract/surface.toml` now declares
the split it was silently contradicting.
