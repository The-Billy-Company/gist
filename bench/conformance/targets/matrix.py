#!/usr/bin/env python3
"""The population under measurement: which targets, which queries, which lanes.

Layer H's whole claim is about a *set*, so the set is declared here as data
rather than discovered at run time — a sweep that quietly shrank its matrix
would otherwise look like a cleaner win. Three kinds of fact live here:

  MATRIX   the gist targets, each mapped to the ripgrep triples it covers and
           to the lane this host could execute it on.
  PROBES   the twelve canonical query classes, transcribed from
           `bench/harness/probes.zig` and held to it by `portable.py selftest`.
  lanes    why a target has no execution lane *on this machine* — always a fact
           about the host, never about the artifact.

stdlib only, no side effects: importing this module measures nothing.
"""

from __future__ import annotations

import platform

# Ordered weakest → strongest, and `conforms-wine` sits deliberately *below*
# `conforms`: a Windows binary whose whole probe slate came back byte-identical to
# the native oracle did so through Wine's reimplementation of Win32, not through
# Microsoft's. That is strictly stronger than `runs` and strictly weaker than a
# real kernel, so it gets its own rung rather than being folded into either.
TIERS = ("tree-broken", "unbuilt", "builds", "runs", "conforms-wine", "conforms")
RANK = {t: i for i, t in enumerate(TIERS)}

# The tiers a lane is *capable* of certifying. A translation-layer lane cannot
# mint `conforms` no matter how clean its output is, and the ceiling lives here
# rather than in the scorer so a new lane cannot forget to declare one.
LANE_CEILING = {"wine": "conforms-wine"}


def lane_ceiling(lane: str) -> str:
    """The strongest tier `lane` is allowed to certify."""
    return LANE_CEILING.get(lane.split(":", 1)[0], "conforms")

# The twelve canonical query classes, transcribed from `bench/harness/probes.zig`
# (kept in step by `selftest`, which parses that file and fails on any drift —
# a Python harness cannot `@import` Zig data, so the check replaces the copy's
# honesty). `kind` is load-bearing: the literal classes run under `-F`, and `})`
# is not a valid regex, so mislabeling one silently drops a class.
PROBES = [
    ("literal-rare", "literal", "pgxpool"),
    ("literal-dotted", "literal", "context.Context"),
    ("literal-common", "literal", "func"),
    ("literal-punct2", "literal", "})"),
    ("regex-decl", "regex", r"func\s+\w+\("),
    ("regex-dotted", "regex", r"pgxpool\.\w+"),
    ("regex-anchored", "regex", r"^func\s"),
    ("regex-classcount", "regex", "[0-9a-f]{8}-[0-9a-f]{4}"),
    ("regex-alternation", "regex", "return|continue|break"),
    ("regex-dense-scan", "regex", r"\w{3,8}"),
    ("regex-eol", "regex", ";$"),
    ("regex-litalt", "regex", "panic|0x"),
]

# A lookbehind: unrepresentable in the linear engine, so serving it proves the
# vendored PCRE2 cross-compiled and linked for this target rather than merely
# that the Zig half did. `func new…` exists in every generated corpus file.
PCRE2_PROBE = r"(?<=func )new\w+"

# `-n --sort path --uncap` is the comparison shape: line numbers and paths make a
# diff informative, `--sort path` removes walk-order nondeterminism, and `--uncap`
# defeats gist's ~100 KB agent output cap — without it the dense classes would be
# compared as truncated prefixes and "conforms" would cover a third of the bytes.
SLATE_FLAGS = ["-n", "--sort", "path", "--uncap"]

# One row per gist target: `(zig triple, -Dcpu, rg triples it covers, execution
# lane)`. A row may cover more than one rg triple — an x86_64 Windows artifact
# stands for both of ripgrep's x86_64 Windows assets, which differ only in libc
# flavor. `docker:<platform>` needs Docker with binfmt for that architecture;
# `none` means this host has no machine of that kind, so the row honestly stops
# at `builds` rather than being scored on a lane that never ran.
#
# Windows: Zig's hermetic Windows libc is mingw-w64, so a `-windows-gnu` artifact
# substitutes for an `-msvc` asset — the ABI flavor differs, the machine does not,
# and ripgrep ships a windows-gnu asset itself. Recorded as `substituted-gnu`,
# never claimed as an msvc build.
MATRIX = [
    # ── covering ripgrep's declared matrix ───────────────────────────────────
    ("aarch64-macos", None, ("aarch64-apple-darwin",), "native"),
    ("x86_64-macos", None, ("x86_64-apple-darwin",), "rosetta"),
    ("x86_64-linux-musl", None, ("x86_64-unknown-linux-musl",), "docker:linux/amd64"),
    ("aarch64-linux-gnu", None, ("aarch64-unknown-linux-gnu",), "docker:linux/arm64"),
    ("aarch64-linux-musl", None, ("aarch64-unknown-linux-musl",), "docker:linux/arm64"),
    ("arm-linux-gnueabihf", "generic+v7a", ("armv7-unknown-linux-gnueabihf",), "docker:linux/arm/v7"),
    ("arm-linux-musleabihf", "generic+v7a", ("armv7-unknown-linux-musleabihf",), "docker:linux/arm/v7"),
    ("arm-linux-musleabi", "generic+v7a", ("armv7-unknown-linux-musleabi",), "docker:linux/arm/v7"),
    ("s390x-linux-gnu", None, ("s390x-unknown-linux-gnu",), "docker:linux/s390x"),
    ("x86-linux-gnu", None, ("i686-unknown-linux-gnu",), "docker:linux/386"),
    ("x86_64-windows-gnu", None, ("x86_64-pc-windows-gnu", "x86_64-pc-windows-msvc"), "wine:linux/amd64"),
    ("aarch64-windows-gnu", None, ("aarch64-pc-windows-msvc",), "none"),
    ("x86-windows-gnu", None, ("i686-pc-windows-msvc",), "wine:linux/amd64"),
    # ── targets ripgrep publishes nothing for ────────────────────────────────
    ("riscv64-linux-musl", None, (), "docker:linux/riscv64"),
    ("powerpc64le-linux-musl", None, (), "docker:linux/ppc64le"),
    ("x86-linux-musl", None, (), "docker:linux/386"),
    ("x86_64-linux-gnu", None, (), "docker:linux/amd64"),
    ("riscv64-linux-gnu", None, (), "docker:linux/riscv64"),
    ("powerpc64-linux-gnu", None, (), "none"),
    ("x86_64-freebsd", None, (), "none"),
    ("aarch64-freebsd", None, (), "none"),
    ("x86_64-netbsd", None, (), "none"),
]

# rg triples whose ABI flavor gist substitutes rather than reproduces.
FLAVOR_SUBSTITUTED = {"x86_64-pc-windows-msvc", "aarch64-pc-windows-msvc", "i686-pc-windows-msvc"}

# The image a lane runs in is chosen by the artifact's **libc**, not by taste: a
# `-gnu` artifact links glibc dynamically and cannot start on Alpine (musl only),
# which is exactly how the first sweep scored five perfectly good glibc targets as
# `builds` with "slate produced no probe rows". musl artifacts are static and would
# run anywhere, but they stay on Alpine because it is a tenth the size to pull for
# seven foreign architectures.
# `trixie` rather than `bookworm` for the glibc side: bookworm-slim publishes no
# `linux/riscv64` manifest, so the riscv64 glibc row had no image it could load in
# (measured — `docker manifest inspect` lists 386 · amd64 · arm · arm64 · ppc64le ·
# riscv64 · s390x for trixie-slim, which is every Linux architecture in the matrix).
CONTAINER_IMAGE = {"musl": "alpine:3.20", "gnu": "debian:trixie-slim"}

# The Windows lane's image, built here rather than pulled: no official Wine image
# publishes a stable digest, and a harness that depends on someone's `latest` is
# not reproducible. Debian's `wine` package is the same PE loader either way. The
# image is built on demand and cached under this tag, so a re-mint on a cold
# machine costs one build and every later sweep costs nothing.
# `wine32:i386` alongside `wine64` is what lets the 32-bit row execute at all:
# a PE32 loads through WoW64, and without the i386 multiarch loader Wine reports
# `failed to load \\??\\C:\\windows\\syswow64\\ntdll.dll` and refuses the image.
WINE_IMAGE = "gist-wine:trixie2"
WINE_DOCKERFILE = """\
FROM debian:trixie-slim
RUN dpkg --add-architecture i386 \\
 && apt-get -qq update \\
 && apt-get -qq install -y wine wine64 wine32:i386 \\
 && rm -rf /var/lib/apt/lists/*
ENV WINEDEBUG=-all WINEPREFIX=/wine XDG_RUNTIME_DIR=/tmp
"""


def image_for(triple: str) -> str:
    """The container image whose libc can actually load `triple`'s artifact."""
    return CONTAINER_IMAGE["gnu" if "-gnu" in triple else "musl"]


# Why a `none`-lane row cannot be executed *here*. Every one of these is a fact
# about the measuring host, never about the artifact — so the row is recorded at
# `builds` with the reason attached instead of being emulated into a fake pass.
NO_LANE_WHY = {
    # Windows rows that DO have a lane never consult this table. These two are the
    # arch Wine itself cannot load here: it emulates Win32, not the CPU, so an
    # ARM64 PE needs an ARM64 Wine host, which an x86 container lane is not.
    "aarch64-windows": "Wine emulates Win32, not the CPU: an aarch64 PE needs an aarch64 Wine host, "
                       "which this x86-only container lane cannot provide",
    "windows": "no Windows machine and no Windows container runtime on this host",
    "freebsd": "FreeBSD runs no Linux container; executing this needs a real FreeBSD host or a full-system VM",
    "netbsd": "NetBSD runs no Linux container; executing this needs a real NetBSD host or a full-system VM",
    # Docker Hub publishes linux/ppc64le but no big-endian linux/ppc64 platform,
    # so there is no image this artifact could be loaded by under any emulation.
    "powerpc64-linux": "Docker publishes no big-endian linux/ppc64 platform, only ppc64le",
}


def no_lane_why(triple: str) -> str:
    """The recorded reason `triple` has no execution lane on this host."""
    for key, why in NO_LANE_WHY.items():
        if key in triple:
            return why
    return f"no execution lane for this target on {platform.machine()} {platform.system()}"


def host_triple() -> str:
    """This machine's own Zig triple — the control build's target."""
    if platform.system() == "Darwin":
        return f"{'aarch64' if platform.machine() == 'arm64' else 'x86_64'}-macos"
    return f"{platform.machine()}-linux-gnu"
