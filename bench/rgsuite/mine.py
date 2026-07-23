#!/usr/bin/env python3
"""Mine ripgrep's tests/*.rs integration suite into a self-contained, tool- agnostic spec (fixtures + argv + comparison mode) → spec.json.

We use LIVE `rg` as the oracle in run.py, so we deliberately do NOT parse the
hardcoded `expected` strings — only what's needed to reproduce each scenario:
files/dirs/symlinks to create, the argv, piped stdin, and how the test compares
output. Every fixture byte is base64-embedded, so the emitted spec.json is fully
self-contained and needs neither the ripgrep checkout nor the network to replay.

A single `rgtest!` body may execute `rg` more than once (`cmd.stdout()`,
`dir.command()…`, `.pipe(…)`, `.assert_err()`, …). We emit ONE record per rg
invocation — `<name>`, or `<name>#1`, `<name>#2`, … when a body runs N>1 times —
all sharing the same fixture. Concatenating multiple invocations into one argv
(the old behavior) produced bogus argv like `['--files','--files','a/src']`.

Regenerate only when bumping the pinned ripgrep the suite tracks:
    python3 mine.py [path/to/ripgrep/tests]   # default: <repo>/.etc/ripgrep/tests

Each record carries status ok|skip so the scoreboard stays honest about what it
could and couldn't reproduce.
"""

import base64
import contextlib
import json
from pathlib import Path
import re
import sys


HERE = Path(__file__).resolve().parent
_DEFAULT = HERE.parents[4] / ".etc" / "ripgrep" / "tests"  # …/upstream/ripgrep/tests
TESTS = Path(sys.argv[1]) if len(sys.argv) > 1 else _DEFAULT
FILES = ["binary.rs", "feature.rs", "json.rs", "misc.rs", "multiline.rs", "regression.rs"]


# ---------------------------------------------------------------- string literals
def parse_str(src: str, i: int):
    """src[i] is a quote or the 'r' of a raw string. Return (bytes, end_idx_after)."""
    if src[i] == "r":
        j = i + 1
        hashes = 0
        while src[j] == "#":
            hashes += 1
            j += 1
        if src[j] != '"':
            raise AssertionError
        j += 1
        close = '"' + "#" * hashes
        end = src.index(close, j)
        return src[j:end].encode(), end + len(close)
    if src[i] != '"':
        raise AssertionError
    out = bytearray()
    j = i + 1
    while True:
        c = src[j]
        if c == "\\":
            n = src[j + 1]
            simple = {
                "n": b"\n",
                "t": b"\t",
                "r": b"\r",
                '"': b'"',
                "\\": b"\\",
                "0": b"\x00",
                "'": b"'",
            }
            if n in simple:
                out += simple[n]
                j += 2
            elif n == "x":
                out.append(int(src[j + 2 : j + 4], 16))
                j += 4
            elif n == "u":
                k = src.index("}", j)
                out += chr(int(src[j + 3 : k], 16)).encode()
                j = k + 1
            elif n == "\n":  # line continuation
                j += 2
                while src[j] in " \t":
                    j += 1
            else:
                out += n.encode()
                j += 2
        elif c == '"':
            return bytes(out), j + 1
        else:
            out += c.encode()
            j += 1


def strip_comments(src: str) -> str:
    """Remove Rust // line and /* */ block comments, string/char-literal aware (so `//` inside a regex string or a URL in an expected block survives).

    A
        `// comment` inside a `.args(&[…])` array would otherwise wreck tokenizing.

    """
    out = []
    j = 0
    n = len(src)
    while j < n:
        c = src[j]
        if c == "b" and (
            src[j + 1 : j + 2] == '"' or (src[j + 1 : j + 2] == "r" and src[j + 2 : j + 3] in '"#')
        ):
            out.append("b")
            j += 1
            c = src[j]
        if c == '"' or (c == "r" and src[j + 1 : j + 2] in '"#'):
            with contextlib.suppress(Exception):
                _, end = parse_str(src, j)
                out.append(src[j:end])
                j = end
                continue
        if c == "/" and src[j + 1 : j + 2] == "/":
            while j < n and src[j] != "\n":
                j += 1
            continue
        if c == "/" and src[j + 1 : j + 2] == "*":
            end = src.find("*/", j + 2)
            j = (end + 2) if end != -1 else n
            continue
        out.append(c)
        j += 1
    return "".join(out)


def blank_strings(src: str) -> str:
    """Replace every string-literal body with `""` so a keyword scan only sees real code.

    Without this, an expected-output block containing the word
        "match"/"if"/"for" would be misread as control flow.

    """
    out = []
    j = 0
    n = len(src)
    while j < n:
        c = src[j]
        if c == "b" and (
            src[j + 1 : j + 2] == '"' or (src[j + 1 : j + 2] == "r" and src[j + 2 : j + 3] in '"#')
        ):
            j += 1
            c = src[j]
        if c == '"' or (c == "r" and src[j + 1 : j + 2] in '"#'):
            with contextlib.suppress(Exception):
                _, end = parse_str(src, j)
                out.append('""')
                j = end
                continue
        out.append(c)
        j += 1
    return "".join(out)


def read_stmt(src: str, i: int):
    """From src[i], read a Rust expression/statement up to the terminating top-level ';'.

    String/bracket aware. Return (text, idx_of_semicolon).

    """
    depth = 0
    j = i
    while j < len(src):
        c = src[j]
        if c == '"' or (c == "r" and src[j + 1 : j + 2] in ('"', "#")):
            with contextlib.suppress(Exception):
                _, j = parse_str(src, j)
                continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == ";" and depth == 0:
            return src[i:j], j
        j += 1
    return src[i:], len(src)


# ---------------------------------------------------------------- value resolution
def resolve_value(expr: str, consts: dict, binds: list, pos: int):
    """Resolve a Rust expr yielding a string/bytes value → bytes, or None.

    Handles string / raw-string / byte-string literals, `include_bytes!` /
    `include_str!` (read relative to the tests dir), `const` upper-case names,
    a trailing `.as_bytes()`, and local `let name = …` scalar bindings (the
    most recent binding textually before `pos`).
    """
    expr = expr.strip()
    if expr.startswith("&"):
        expr = expr[1:].strip()
    expr = re.sub(r"\.as_bytes\(\)\s*$", "", expr).strip()

    # byte string: b"…", br"…", br#"…"#  → parse from the leading quote/'r'.
    if expr.startswith(('b"', 'br"', "br#")):
        try:
            b, _ = parse_str(expr[1:], 0)
        except Exception:
            return None
        else:
            return b
    if expr.startswith(('"', 'r"', "r#")):
        try:
            b, _ = parse_str(expr, 0)
        except Exception:
            return None
        else:
            return b

    m = re.match(r"include_(?:bytes|str)!\s*\(\s*(.*?)\s*,?\s*\)\s*$", expr, re.DOTALL)
    if m:
        try:
            rel, _ = parse_str(m.group(1).strip(), 0)
        except Exception:
            return None
        try:
            return (TESTS / rel.decode()).read_bytes()
        except Exception:
            return None

    if re.fullmatch(r"[A-Z_][A-Z0-9_]*", expr):
        return consts.get(expr)
    if re.fullmatch(r"[a-z_]\w*", expr):
        return _latest(binds, expr, pos, "bytes")
    return None


def resolve_token(expr: str, consts: dict, binds: list, pos: int):
    """A single argv token (string) → str, or None if unresolvable."""
    b = resolve_value(expr, consts, binds, pos)
    if b is None:
        return None
    try:
        return b.decode()
    except Exception:
        return None


def resolve_array(expr: str, consts: dict, binds: list, pos: int):
    """A Rust `&[…]` / `[…]` slice (or a local binding to one) → list[str]."""
    toks = _array_tokens(expr)
    if toks is None:
        e = expr.strip()
        if e.startswith("&"):
            e = e[1:].strip()
        if re.fullmatch(r"[a-z_]\w*", e):
            toks = _latest(binds, e, pos, "array")
        if toks is None:
            return None
    out = []
    for t in toks:
        s = resolve_token(t, consts, binds, pos)
        if s is None:
            return None
        out.append(s)
    return out


def _latest(binds: list, name: str, pos: int, kind: str):
    """Most recent binding of `name` (of `kind`) declared textually before pos."""
    best = None
    for bpos, bname, bkind, payload in binds:
        if bname == name and bkind == kind and bpos < pos and (best is None or bpos > best[0]):
            best = (bpos, payload)
    return best[1] if best else None


# ---------------------------------------------------------------- consts + bindings
def load_consts():
    """Load consts from disk."""
    consts = {}
    for f in ["hay.rs", *FILES]:
        src = strip_comments((TESTS / f).read_text())
        for m in re.finditer(
            r"\bconst\s+([A-Z_][A-Z0-9_]*)\s*:\s*&(?:\'static\s+)?(?:\[u8\]|str)\s*=\s*", src
        ):
            val, _ = read_stmt(src, m.end())
            b = resolve_value(val.strip(), consts, [], 0)
            if b is not None:
                consts.setdefault(m.group(1), b)
    return consts


def _array_tokens(expr: str):
    """`&[…]` / `[…]` / `vec![…]` literal → list of raw element exprs, or None."""
    e = expr.strip()
    if e.startswith("&"):
        e = e[1:].strip()
    if e.startswith("vec!"):
        e = e[4:].strip()
    if not e.startswith("["):
        return None
    try:
        return split_top(e[1 : e.rindex("]")])
    except ValueError:
        return None


def parse_bindings(body: str, consts: dict):
    """Local `let (mut)? name = …;` bindings inside a test body → resolved scalars (bytes) and array-literal token lists, for later argv/fixture use.

    Also models `name.extend(other)` mutations (used by the f1842_* tests) by
        recording a fresh, appended array binding at the extend's position.

    """
    binds = []
    for m in re.finditer(r"\blet\s+(?:mut\s+)?([a-z_]\w*)\s*=\s*", body):
        val, _ = read_stmt(body, m.end())
        toks = _array_tokens(val)
        if toks is not None:
            binds.append((m.start(), m.group(1), "array", toks))
        else:
            b = resolve_value(val.strip(), consts, binds, m.start())
            if b is not None:
                binds.append((m.start(), m.group(1), "bytes", b))
    for m in re.finditer(r"\b([a-z_]\w*)\.extend\s*\(", body):
        name = m.group(1)
        inner, _ = match_paren(body, m.end() - 1)
        add = _array_tokens(inner) or _latest(binds, inner.strip(), m.start(), "array")
        prev = _latest(binds, name, m.start(), "array")
        if add is not None and prev is not None:
            binds.append((m.start(), name, "array", prev + add))
    return binds


# ---------------------------------------------------------------- arg-list parse
def match_paren(src: str, i: int):
    """src[i] == '('. Return (inner, end_after_close), string-aware."""
    depth = 0
    j = i
    while j < len(src):
        c = src[j]
        if c == '"' or (c == "r" and j + 1 < len(src) and src[j + 1] in '#"'):
            with contextlib.suppress(Exception):
                _, j = parse_str(src, j)
                continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return src[i + 1 : j], j + 1
        j += 1
    return src[i + 1 :], len(src)


def split_top(inner: str):
    """Split a call arg list on top-level commas (string+bracket aware)."""
    parts = []
    depth = 0
    buf = ""
    j = 0
    while j < len(inner):
        c = inner[j]
        if c == '"' or (c == "r" and j + 1 < len(inner) and inner[j + 1] in '#"'):
            with contextlib.suppress(Exception):
                _, nj = parse_str(inner, j)
                buf += inner[j:nj]
                j = nj
                continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        if c == "," and depth == 0:
            parts.append(buf.strip())
            buf = ""
        else:
            buf += c
        j += 1
    if buf.strip():
        parts.append(buf.strip())
    return parts


# ---------------------------------------------------------------- block extract
def extract_blocks(src: str):
    """Yield (name, body) for each rgtest! block."""
    for m in re.finditer(r"rgtest!\(\s*([a-zA-Z0-9_]+)\s*,", src):
        i = src.index("|", m.end())
        i = src.index("|", i + 1)  # end of closure params
        b = src.index("{", i)
        depth = 0
        j = b
        while j < len(src):
            c = src[j]
            if c == '"' or (c == "r" and j + 1 < len(src) and src[j + 1] in '#"'):
                with contextlib.suppress(Exception):
                    _, j = parse_str(src, j)
                    continue
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        yield m.group(1), src[b + 1 : j]


# Fixture-building calls (shared by every invocation in the body) and the
# command/run-point calls that delimit invocations. Each is matched with a
# trailing '(' so `.arg(` never swallows `.args(`, nor `dir.create(` the
# `dir.create_bytes(` etc.
FIXTURE_HEADS = [
    "dir.create_bytes",
    "dir.try_create_bytes",
    "dir.create_dir",
    "dir.create_size",
    "dir.create",
    "dir.try_create",
    "dir.link_dir",
    "dir.link_file",
    "dir.remove",
]
RUN_HEADS = [
    ".stdout",
    ".assert_err",
    ".assert_exit_code",
    ".assert_non_empty_stderr",
    ".output",
    ".raw_output",
]
CMD_HEADS = [".args", ".arg", ".current_dir", ".pipe", ".command"]
ALL_HEADS = FIXTURE_HEADS + RUN_HEADS + CMD_HEADS

_PCRE2_GUARD = re.compile(r"if\s*(!?)\s*dir\.is_pcre2\(\)\s*\{\s*return\s*;?\s*\}")


def _fresh():
    return {
        "argv": [],
        "current_dir": None,
        "stdin": None,
        "terminal": "stdout",
        "exit_code": None,
        "pending": False,
        "skip": [],
    }


def mine_block(name, body, consts, srcfile):
    """Return a list of one-or-more spec records (one per rg invocation)."""
    pcre2 = (
        bool(_PCRE2_GUARD.search(body) and re.search(r"if\s*!\s*dir\.is_pcre2", body))
        or "setup_pcre2" in body
        or "dir.pcre2" in body
    )
    # A block's comparison bar mirrors the macro it asserts stdout with. Any
    # `sort_lines` use (`eqnice!(sort_lines(…), sort_lines(…))`) is order-agnostic.
    # A block that never byte-asserts (`eqnice!`) yet checks stdout via
    # `assert!(got.contains(…))` — rg 15.2's #3320/#3376 multi-root ORDER tests,
    # the f411 `--stats` probes, r2944's byte-count — is order-agnostic too: its
    # own bar is substring presence, not byte order, so holding it to byte-exact
    # is stricter than ripgrep's own test (and, for the multi-root walks whose
    # emit order is genuinely nondeterministic, spuriously flaps PASS↔ORDER). Only
    # a real `eqnice!` byte assertion stays "plain".
    cmp = "sort" if ("sort_lines" in body or ("eqnice!" not in body and ".contains(" in body)) else "plain"
    # Scan code only (string bodies blanked) so keywords inside expected-output
    # blocks — e.g. the word "match" in a binary-warning string — don't masquerade
    # as control flow.
    code = blank_strings(_PCRE2_GUARD.sub(" ", body))
    if re.search(r"\bfor\b|\bwhile\b|\bif\b|\bmatch\b|\.lines\(\)|cmd_exists|is_cross", code):
        base = _rec(name, srcfile, [], [], [], [], _fresh(), pcre2, cmp)
        base["status"] = "skip"
        base["skip"] = ["control-flow"]
        return [base]
    # A `helper(dir)` call builds fixtures we can't see (e.g. sort_setup, which
    # also uses PathBuf::join'd paths + access-time ordering) → honest skip.
    if re.search(r"\b\w+\(\s*dir\s*\)", code):
        base = _rec(name, srcfile, [], [], [], [], _fresh(), pcre2, cmp)
        base["status"] = "skip"
        base["skip"] = ["fixture-helper"]
        return [base]

    binds = parse_bindings(body, consts)
    files, dirs, symlinks, sized, removed = [], [], [], [], set()
    block_skip = []

    occ = []
    for h in ALL_HEADS:
        start = 0
        while True:
            p = body.find(h + "(", start)
            if p < 0:
                break
            occ.append((p, h))
            start = p + len(h) + 1
    occ.sort()

    # ripgrep's TestCommand ACCUMULATES args across runs on the same variable —
    # only `dir.command()` starts a fresh command. So a run-point snapshots the
    # current argv (copy) and keeps accumulating; `.command` resets. Per-run
    # stdin (from `.pipe`) is reset after each snapshot.
    invs = []
    cur = _fresh()

    def new_cmd():
        nonlocal cur
        cur = _fresh()

    def emit(term, exit_code=None):
        cur["pending"] = False
        invs.append(
            {
                "argv": list(cur["argv"]),
                "current_dir": cur["current_dir"],
                "stdin": cur["stdin"],
                "terminal": term,
                "exit_code": exit_code,
                "skip": list(cur["skip"]),
            }
        )
        cur["stdin"] = None

    for pos, head in occ:
        inner, _ = match_paren(body, pos + len(head))
        args = split_top(inner)

        if head in ("dir.create", "dir.try_create", "dir.create_bytes", "dir.try_create_bytes"):
            if len(args) < 2:
                block_skip.append(f"{head}:argc")
                continue
            path = resolve_token(args[0], consts, binds, pos)
            content = resolve_value(args[1], consts, binds, pos)
            if path is None or content is None:
                block_skip.append(f"{head}:unresolved")
                continue
            files.append({"path": path, "b64": base64.b64encode(content).decode()})
        elif head == "dir.create_dir":
            p = resolve_token(args[0], consts, binds, pos)
            (dirs.append(p) if p else block_skip.append("create_dir:unresolved"))
        elif head == "dir.create_size":
            path = resolve_token(args[0], consts, binds, pos)
            m = re.match(r"(\d[\d_]*)", args[1].strip()) if len(args) > 1 else None  # drop suffix
            size = int(m.group(1).replace("_", "")) if m else None
            (
                sized.append({"path": path, "size": size})
                if path is not None and size is not None
                else block_skip.append("create_size:unresolved")
            )
        elif head in ("dir.link_dir", "dir.link_file"):
            if len(args) < 2:
                block_skip.append(f"{head}:argc")
                continue
            src = resolve_token(args[0], consts, binds, pos)
            tgt = resolve_token(args[1], consts, binds, pos)
            (
                symlinks.append({"path": tgt, "target": src})
                if src and tgt
                else block_skip.append("symlink:unresolved")
            )
        elif head == "dir.remove":
            p = resolve_token(args[0], consts, binds, pos)
            if p:
                removed.add(p)
        elif head == ".command":
            new_cmd()
        elif head == ".arg":
            t = resolve_token(args[0], consts, binds, pos)
            cur["pending"] = True
            (cur["argv"].append(t) if t is not None else cur["skip"].append("arg:unresolved"))
        elif head == ".args":
            arr = resolve_array(args[0], consts, binds, pos)
            cur["pending"] = True
            (cur["argv"].extend(arr) if arr is not None else cur["skip"].append("args:unresolved"))
        elif head == ".current_dir":
            cur["current_dir"] = resolve_token(args[0], consts, binds, pos)
            cur["pending"] = True
        elif head == ".pipe":
            b = resolve_value(args[0], consts, binds, pos)
            if b is None:
                cur["skip"].append("pipe:unresolved")
            else:
                cur["stdin"] = base64.b64encode(b).decode()
            emit("stdout")
        elif head == ".stdout":
            emit("stdout")
        elif head == ".assert_err":
            emit("err")
        elif head == ".assert_exit_code":
            code = None
            with contextlib.suppress(ValueError, IndexError):
                code = int(args[0])
            emit("exit", code)
        elif head == ".assert_non_empty_stderr":
            emit("stderr")
        elif head in (".output", ".raw_output"):
            emit("output")  # full-Output inspection (usually stderr/status) — not a stdout diff

    if cur["pending"] and cur["argv"]:  # trailing args never closed by an explicit run-point
        emit("stdout")

    # Files created then removed before any run never exist on disk.
    files = [f for f in files if f["path"] not in removed]

    if not invs:
        base = _rec(name, srcfile, files, dirs, symlinks, sized, _fresh(), pcre2, cmp)
        base["status"] = "skip"
        base["skip"] = block_skip or ["no-invocation"]
        return [base]

    recs = []
    multi = len(invs) > 1
    for k, inv in enumerate(invs, 1):
        rec = _rec(
            name if not multi else f"{name}#{k}",
            srcfile,
            files,
            dirs,
            symlinks,
            sized,
            inv,
            pcre2,
            cmp,
        )
        rec["skip"] = block_skip + inv["skip"]
        rec["status"] = "skip" if (inv["skip"] or not inv["argv"]) else "ok"
        recs.append(rec)
    return recs


def _rec(name, srcfile, files, dirs, symlinks, sized, inv, pcre2, cmp):
    return {
        "file": srcfile,
        "name": name,
        "files": files,
        "dirs": dirs,
        "symlinks": symlinks,
        "sized": sized,
        "argv": inv["argv"],
        "stdin": inv["stdin"],
        "cmp": cmp,
        "terminal": inv["terminal"],
        "exit_code": inv["exit_code"],
        "current_dir": inv["current_dir"],
        "pcre2": pcre2,
        "status": "ok",
        "skip": [],
    }


def main():
    """CLI entry point."""
    if not TESTS.is_dir():
        sys.exit(f"ripgrep tests not found at {TESTS} — pass the path as argv[1]")
    consts = load_consts()
    out = []
    for f in FILES:
        for name, body in extract_blocks(strip_comments((TESTS / f).read_text())):
            out.extend(mine_block(name, body, consts, f))
    (HERE / "spec.json").write_text(json.dumps(out, indent=1))
    from collections import Counter

    st = Counter(r["status"] for r in out)
    print(f"mined {len(out)} records → status {dict(st)}")
    sk = Counter(s for r in out for s in r["skip"])
    print("skip reasons:", dict(sk.most_common()))


if __name__ == "__main__":
    main()
