#!/usr/bin/env python3
"""What a cross-compiled artifact actually *is* — read from its own bytes.

A portability certificate that trusts the filename it wrote proves nothing: the
interesting failure is a build step that silently produced a host-native binary,
or an ELF for the wrong `e_machine`, under the name of a foreign target. So this
module answers the question from the artifact's header — ELF, Mach-O, or PE —
and never by shelling `file`/`otool`/`readelf`, which would make the certificate
depend on whichever binutils the machine happens to carry.

Three facts per artifact, each load-bearing for a portability claim:

- **arch + bits + endian** — checked against what the Zig triple promised, so a
  mislabeled artifact fails instead of being counted.
- **static** — no `PT_INTERP` in the program headers. This is the real
  portability property of a Linux binary: a static musl artifact runs on any
  distribution of that architecture, which is exactly why it can be executed
  under an arbitrary foreign-arch container image.
- **size** — recorded, never estimated.

stdlib only.
"""

from __future__ import annotations

import struct
from pathlib import Path

# ELF `e_machine` → the architecture name this harness speaks. Values are from
# the SysV gABI / Linux `elf.h`; only the arches in gist's matrix are listed, so
# an unlisted machine surfaces as `em-<n>` rather than being guessed at.
ELF_MACHINES = {
    3: "x86",
    21: "powerpc64",
    22: "s390x",
    40: "arm",
    62: "x86_64",
    183: "aarch64",
    243: "riscv64",
    258: "loongarch64",
}

# Mach-O `cputype` (<mach/machine.h>): CPU_ARCH_ABI64 | the base type.
MACHO_CPUS = {0x01000007: "x86_64", 0x0100000C: "aarch64", 7: "x86", 12: "arm"}

# PE COFF `Machine` (<winnt.h> IMAGE_FILE_MACHINE_*).
PE_MACHINES = {0x014C: "x86", 0x8664: "x86_64", 0xAA64: "aarch64", 0x01C4: "arm"}

PT_INTERP = 3

# Zig arch spelling → the `e_machine` family name `ELF_MACHINES` reports. Only the
# arches whose triple spelling differs from their machine name need a row.
ARCH_CANON = {"powerpc64le": "powerpc64", "mipsel": "mips", "mips64el": "mips64"}

# The arches whose default byte order is *not* little. Recorded explicitly rather
# than inferred, because getting this wrong in either direction silently turns the
# identity check into a rubber stamp (accepting a wrong-endian artifact) or into a
# false alarm (rejecting a correct one).
ARCH_ENDIAN = {"s390x": "big", "powerpc64": "big", "powerpc": "big", "mips": "big", "mips64": "big"}


class NotAnObject(Exception):
    """The bytes are not an ELF, Mach-O, or PE image."""


def identify(path: Path) -> dict:
    """Read `path`'s header and report format · arch · bits · endian · static · size.

    Raises `NotAnObject` when the leading bytes match no known container, which
    is itself a useful verdict: a build that emitted a script or an archive
    where an executable was promised must not be scored as "builds".
    """
    data = path.read_bytes()
    size = len(data)
    if data[:4] == b"\x7fELF":
        out = _elf(data)
    elif data[:4] in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe"):
        out = _macho(data)
    elif data[:2] == b"MZ":
        out = _pe(data)
    else:
        raise NotAnObject(f"{path}: unrecognized image magic {data[:4]!r}")
    return {**out, "size": size}


def _elf(data: bytes) -> dict:
    bits = 64 if data[4] == 2 else 32
    endian = "little" if data[5] == 1 else "big"
    e = "<" if endian == "little" else ">"
    (machine,) = struct.unpack_from(e + "H", data, 18)
    (etype,) = struct.unpack_from(e + "H", data, 16)
    return {
        "format": "elf",
        "arch": ELF_MACHINES.get(machine, f"em-{machine}"),
        "bits": bits,
        "endian": endian,
        "osabi": data[7],
        # A PIE (ET_DYN) with no interpreter is still static; presence of a
        # PT_INTERP segment is the only thing that makes a Linux image depend on
        # a runtime loader, so that — not `e_type` — is what is asked here.
        "static": not _elf_has_interp(data, bits, e),
        "etype": "exec" if etype == 2 else "dyn" if etype == 3 else str(etype),
    }


def _elf_has_interp(data: bytes, bits: int, e: str) -> bool:
    """True iff a `PT_INTERP` program header is present (⇒ dynamically loaded)."""
    if bits == 64:
        (phoff,) = struct.unpack_from(e + "Q", data, 32)
        phentsize, phnum = struct.unpack_from(e + "HH", data, 54)
    else:
        (phoff,) = struct.unpack_from(e + "I", data, 28)
        phentsize, phnum = struct.unpack_from(e + "HH", data, 42)
    for i in range(phnum):
        off = phoff + i * phentsize
        if off + 4 > len(data):
            return False
        (ptype,) = struct.unpack_from(e + "I", data, off)
        if ptype == PT_INTERP:
            return True
    return False


def _macho(data: bytes) -> dict:
    (cputype,) = struct.unpack_from("<i", data, 4)
    cpu = cputype & 0xFFFFFFFF
    return {
        "format": "macho",
        "arch": MACHO_CPUS.get(cpu, f"cpu-{cpu}"),
        "bits": 64 if data[:4] == b"\xcf\xfa\xed\xfe" else 32,
        "endian": "little",
        "osabi": None,
        # Mach-O executables always load through dyld against libSystem; there is
        # no static-libc posture on macOS to claim, so this is honestly False.
        "static": False,
        "etype": "exec",
    }


def _pe(data: bytes) -> dict:
    (lfanew,) = struct.unpack_from("<I", data, 0x3C)
    if data[lfanew : lfanew + 4] != b"PE\x00\x00":
        raise NotAnObject("MZ header without a PE signature")
    (machine,) = struct.unpack_from("<H", data, lfanew + 4)
    return {
        "format": "pe",
        "arch": PE_MACHINES.get(machine, f"pe-{machine:#x}"),
        "bits": 64 if machine in (0x8664, 0xAA64) else 32,
        "endian": "little",
        "osabi": None,
        "static": True,  # Zig's windows-gnu artifacts carry no libgcc/msvcrt DLL floor
        "etype": "exec",
    }


# The (format, arch, bits, endian) a Zig triple must produce. The driver asserts
# against this rather than trusting the `-Dtarget=` it passed, so a toolchain
# that quietly fell back to the host is a failure and not a silent pass.
def expected(triple: str) -> dict:
    """Derive the artifact identity a Zig target triple promises."""
    arch, os_tag = triple.split("-")[0], triple.split("-")[1]
    fmt = {"macos": "macho", "windows": "pe"}.get(os_tag, "elf")
    return {
        "format": fmt,
        # An ELF `e_machine` names an *architecture family*, not a byte order:
        # powerpc64 and powerpc64le are both EM_PPC64 (21), and it is `e_ident[5]`
        # that tells them apart. So the triple's `le` suffix is folded into the
        # endian field, where the header actually answers it, rather than being
        # compared against a machine number that cannot carry it.
        "arch": ARCH_CANON.get(arch, arch),
        "bits": 32 if arch in ("x86", "arm", "mips", "mipsel", "powerpc") else 64,
        "endian": ARCH_ENDIAN.get(arch, "little"),
    }


def verify(path: Path, triple: str) -> tuple[bool, dict, str]:
    """`(ok, identity, why)` — does `path` match what `triple` promised?"""
    try:
        got = identify(path)
    except (NotAnObject, struct.error, IndexError) as exc:
        return False, {}, str(exc)
    want = expected(triple)
    bad = [k for k, v in want.items() if got.get(k) != v]
    why = "" if not bad else "; ".join(f"{k}: want {want[k]}, got {got.get(k)}" for k in bad)
    return not bad, got, why
