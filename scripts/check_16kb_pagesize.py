#!/usr/bin/env python3
"""check_16kb_pagesize.py — 16 KB page-size compliance gate (Phase 3).

Google Play requires every native library in an APK/AAB to be compatible
with 16 KB memory pages: each PT_LOAD segment must be aligned to at least
16384 bytes (docs/PLATFORMS.md, Android edition [S22][S46]).

Usage:
  check_16kb_pagesize.py <file.apk>            check every lib/**/*.so
  check_16kb_pagesize.py <libfoo.so> [...]     check individual ELF files
  check_16kb_pagesize.py --selftest            run the built-in unit tests

Exit codes: 0 = compliant, 1 = violations found / malformed input.
"""

import struct
import sys
import zipfile
from pathlib import Path

PAGE_MIN = 16384
PT_LOAD = 1


def load_alignments(elf: bytes):
    """Return (True, [(segment_index, p_align)]) for a 64-bit ELF image,
    (None, []) for anything that is not a 64-bit ELF."""
    if len(elf) < 64 or elf[:4] != b"\x7fELF":
        return None, []
    is64 = elf[4] == 2
    if not is64:
        return None, []
    endian = "<" if elf[5] == 1 else ">"
    e_phoff = struct.unpack_from(endian + "Q", elf, 0x20)[0]
    e_phentsize = struct.unpack_from(endian + "H", elf, 0x36)[0]
    e_phnum = struct.unpack_from(endian + "H", elf, 0x38)[0]
    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type = struct.unpack_from(endian + "I", elf, off)[0]
        if p_type != PT_LOAD:
            continue
        p_align = struct.unpack_from(endian + "Q", elf, off + 0x30)[0]
        segs.append((i, p_align))
    return True, segs


def check_elf(name: str, elf: bytes, report):
    ok, segs = load_alignments(elf)
    if ok is None:
        report.append((name, False, "not a 64-bit ELF"))
        return False
    if not segs:
        report.append((name, False, "no PT_LOAD segments"))
        return False
    bad = [(i, a) for i, a in segs if a < PAGE_MIN]
    if bad:
        worst = min(a for _, a in bad)
        report.append(
            (name, False,
             f"{len(bad)}/{len(segs)} PT_LOAD segments below {PAGE_MIN} (min {worst})")
        )
        return False
    report.append((name, True,
                   f"{len(segs)} PT_LOAD segments, min align {min(a for _, a in segs)}"))
    return True


def check_apk(apk_path: str, report):
    ok_all = True
    try:
        with zipfile.ZipFile(apk_path) as zf:
            sos = [n for n in zf.namelist() if n.startswith("lib/") and n.endswith(".so")]
            if not sos:
                report.append(("<apk>", False, "no lib/**/*.so entries — nothing to assert"))
                return False
            for n in sorted(sos):
                if not check_elf(n, zf.read(n), report):
                    ok_all = False
    except zipfile.BadZipFile as e:
        report.append((apk_path, False, f"malformed archive: {e}"))
        return False
    return ok_all


def make_elf(align: int) -> bytes:
    """Minimal synthetic ELF64 with one PT_LOAD of the given p_align."""
    e = bytearray(64 + 56)
    e[:4] = b"\x7fELF"
    e[4] = 2  # 64-bit
    e[5] = 1  # little endian
    struct.pack_into("<Q", e, 0x20, 64)  # e_phoff
    struct.pack_into("<H", e, 0x36, 56)  # e_phentsize
    struct.pack_into("<H", e, 0x38, 1)  # e_phnum
    struct.pack_into("<I", e, 64, PT_LOAD)  # p_type
    struct.pack_into("<Q", e, 64 + 0x30, align)  # p_align
    return bytes(e)


def selftest() -> int:
    failures = []

    rep = []
    if not check_elf("good.so", make_elf(16384), rep):
        failures.append(f"16KB ELF must pass: {rep}")
    if not check_elf("good64k.so", make_elf(65536), rep):
        failures.append(f"64KB ELF must pass: {rep}")

    rep.clear()
    if check_elf("bad.so", make_elf(4096), rep):
        failures.append("4KB ELF must fail")
    if not any("below 16384" in r[2] for r in rep):
        failures.append(f"failure message unclear: {rep}")

    rep.clear()
    if check_elf("also_bad.so", make_elf(8192), rep):
        failures.append("8KB ELF must fail")

    rep.clear()
    if check_elf("junk.so", b"MZgarbage", rep):
        failures.append("garbage must fail")

    import tempfile
    with tempfile.TemporaryDirectory() as td:
        bad_zip = Path(td) / "empty.apk"
        bad_zip.write_bytes(b"PK\x03\x04 not a real zip")
        rep.clear()
        if check_apk(str(bad_zip), rep):
            failures.append("malformed apk must fail")
        empty_zip = Path(td) / "no_libs.apk"
        with zipfile.ZipFile(empty_zip, "w") as zf:
            zf.writestr("assets/x.txt", "hi")
        rep.clear()
        if check_apk(str(empty_zip), rep):
            failures.append("apk without .so must fail")

    if failures:
        for f in failures:
            print(f"SELFTEST FAIL: {f}", file=sys.stderr)
        return 1
    print("selftest: 7/7 checks behaved as expected")
    return 0


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1
    if argv[1] == "--selftest":
        return selftest()

    report = []
    target = argv[1]
    if target.endswith(".apk") or target.endswith(".aab"):
        ok = check_apk(target, report)
    else:
        ok = True
        for p in argv[1:]:
            if not check_elf(Path(p).name, Path(p).read_bytes(), report):
                ok = False

    for name, good, msg in report:
        print(f"{'PASS' if good else 'FAIL'}  {name}  {msg}")
    if ok:
        print(f"16 KB page-size: ALL COMPLIANT (>= {PAGE_MIN})")
        return 0
    print(
        "16 KB page-size: VIOLATIONS — rebuild with "
        "-Wl,-z,max-page-size=16384 (see rust/.cargo/config.toml)",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
