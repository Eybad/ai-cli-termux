#!/usr/bin/env python3
# Generates glibc C locale ctype tables for bionic_compat in Codex builds.
# Required because rusty_v8 uses glibc __ctype_b_loc in std::isalnum.

import sys

# Classification bit masks (glibc bits/ctype.h, little-endian, C locale).
_ISupper = 0x100
_ISlower = 0x200
_ISalpha = 0x400
_ISdigit = 0x800
_ISxdigit = 0x1000
_ISspace = 0x2000
_ISprint = 0x4000
_ISgraph = 0x8000
_ISblank = 0x0001
_IScntrl = 0x0002
_ISpunct = 0x0004
_ISalnum = 0x0008

CNTRL = _IScntrl
SPACE = _ISspace | _ISprint | _ISblank
PUNCT = _ISpunct | _ISprint | _ISgraph
DIGIT = _ISdigit | _ISxdigit | _ISprint | _ISgraph | _ISalnum
UHEX = _ISupper | _ISxdigit | _ISalpha | _ISprint | _ISgraph | _ISalnum
UPPER = _ISupper | _ISalpha | _ISprint | _ISgraph | _ISalnum
LHEX = _ISlower | _ISxdigit | _ISalpha | _ISprint | _ISgraph | _ISalnum
LOWER = _ISlower | _ISalpha | _ISprint | _ISgraph | _ISalnum

TABLE_LEN = 384
PUNTERO = 128
EOF_VALUE = 0xFFFFFFFF


def class_bits() -> list[int]:
    cls = [0] * 256
    for c in range(0x00, 0x20):
        cls[c] = CNTRL
    cls[0x20] = SPACE
    for lo, hi in ((0x21, 0x2F), (0x3A, 0x40), (0x5B, 0x60), (0x7B, 0x7E)):
        for c in range(lo, hi + 1):
            cls[c] = PUNCT
    for c in range(0x30, 0x3A):
        cls[c] = DIGIT
    for c in range(0x41, 0x47):
        cls[c] = UHEX
    for c in range(0x47, 0x5B):
        cls[c] = UPPER
    for c in range(0x61, 0x67):
        cls[c] = LHEX
    for c in range(0x67, 0x7B):
        cls[c] = LOWER
    cls[0x7F] = CNTRL
    return cls


def extend_class(tbl_256: list[int]) -> list[int]:
    return [tbl_256[(i - PUNTERO) % 256] for i in range(TABLE_LEN)]


def toupper_values() -> list[int]:
    tbl = list(range(256))
    for c in range(0x61, 0x7B):
        tbl[c] = c - 0x20
    return extend_conversion(tbl)


def tolower_values() -> list[int]:
    tbl = list(range(256))
    for c in range(0x41, 0x5B):
        tbl[c] = c + 0x20
    return extend_conversion(tbl)


def extend_conversion(tbl_256: list[int]) -> list[int]:
    out = []
    for i in range(TABLE_LEN):
        c = i - PUNTERO
        if c == -1:
            out.append(EOF_VALUE)
        else:
            out.append(tbl_256[c % 256])
    return out


def check_invariants(b_tbl: list[int], up: list[int], low: list[int]) -> None:
    errs = []
    for name, t in (("b_tbl", b_tbl), ("toupper_tbl", up), ("tolower_tbl", low)):
        if len(t) != TABLE_LEN:
            errs.append(f"{name}: largo {len(t)} != {TABLE_LEN}")
    if not errs:
        if b_tbl[PUNTERO + ord("a")] & _ISalnum == 0:
            errs.append("b_tbl: isalnum('a') vacío")
        if b_tbl[PUNTERO + ord("0")] & _ISdigit == 0:
            errs.append("b_tbl: isdigit('0') vacío")
        if b_tbl[PUNTERO + ord("-")] & _ISpunct == 0:
            errs.append("b_tbl: '-' sin _ISpunct (glibc lo clasifica como punct)")
        if b_tbl[PUNTERO + ord("a")] & _ISupper:
            errs.append("b_tbl: isupper('a') activo")
        if b_tbl[PUNTERO + ord("A")] & _ISupper == 0:
            errs.append("b_tbl: isupper('A') vacío")
        if b_tbl[PUNTERO + 0x20] & (_ISspace | _ISprint | _ISblank) != SPACE:
            errs.append("b_tbl: espacio != space|print|blank")
        if b_tbl[PUNTERO + 0x00] != CNTRL:
            errs.append("b_tbl: NUL != cntrl")
        if b_tbl[PUNTERO + 0x7F] != CNTRL:
            errs.append("b_tbl: DEL != cntrl")
        if b_tbl[PUNTERO + 0x80] != 0:
            errs.append("b_tbl: 0x80 clasificado (debe ser 0 en locale C)")
        if b_tbl[PUNTERO - 1] != 0:
            errs.append("b_tbl: EOF (-1) != 0")
        if b_tbl[PUNTERO + ord("0")] != 0xD808:
            errs.append(f"b_tbl['0'] = {b_tbl[PUNTERO + ord('0')]:#06x} != 0xd808 (glibc)")
        if b_tbl[PUNTERO + ord("A")] != 0xD508:
            errs.append(f"b_tbl['A'] = {b_tbl[PUNTERO + ord('A')]:#06x} != 0xd508 (glibc)")
        if b_tbl[PUNTERO + ord("a")] != 0xD608:
            errs.append(f"b_tbl['a'] = {b_tbl[PUNTERO + ord('a')]:#06x} != 0xd608 (glibc)")
        if b_tbl[PUNTERO + ord("-")] != 0xC004:
            errs.append(f"b_tbl['-'] = {b_tbl[PUNTERO + ord('-')]:#06x} != 0xc004 (glibc)")
        if b_tbl[PUNTERO + 0x20] != 0x6001:
            errs.append(f"b_tbl[' '] = {b_tbl[PUNTERO + 0x20]:#06x} != 0x6001 (glibc)")
        if up[PUNTERO + ord("a")] != ord("A"):
            errs.append("toupper('a') != 'A'")
        if up[PUNTERO + ord("Z")] != ord("Z"):
            errs.append("toupper('Z') != 'Z'")
        if up[PUNTERO - 1] != EOF_VALUE:
            errs.append("toupper(EOF) != EOF")
        if low[PUNTERO + ord("A")] != ord("a"):
            errs.append("tolower('A') != 'a'")
        if low[PUNTERO + ord("z")] != ord("z"):
            errs.append("tolower('z') != 'z'")
        if low[PUNTERO - 1] != EOF_VALUE:
            errs.append("tolower(EOF) != EOF")
        if sum(b_tbl) == 0:
            errs.append("b_tbl es toda ceros")
    if errs:
        sys.stderr.write("ERROR gen-ctype-tables.py:\n  " + "\n  ".join(errs) + "\n")
        sys.exit(1)


def fmt_table(values: list[int], ctype: str) -> str:
    width = 4 if ctype == "uint16_t" else 8
    lines = []
    for i in range(0, len(values), 12):
        chunk = ", ".join("0x%0*X" % (width, v) for v in values[i : i + 12])
        lines.append("    " + chunk + ",")
    return "\n".join(lines)


def emit(b_tbl: list[int], up: list[int], low: list[int]) -> None:
    sys.stdout.write(
        "/* Generated by scripts/gen-ctype-tables.py. Do not edit manually. */\n\n"
        "#include <stdint.h>\n\n"
    )
    sys.stdout.write("static const uint16_t b_tbl[%d] = {\n%s\n};\n\n" % (TABLE_LEN, fmt_table(b_tbl, "uint16_t")))
    sys.stdout.write("static const int32_t toupper_tbl[%d] = {\n%s\n};\n\n" % (TABLE_LEN, fmt_table(up, "int32_t")))
    sys.stdout.write("static const int32_t tolower_tbl[%d] = {\n%s\n};\n\n" % (TABLE_LEN, fmt_table(low, "int32_t")))
    sys.stdout.write(
        "const uint16_t **__ctype_b_loc(void) { static const uint16_t *p = b_tbl + %d; return &p; }\n"
        % PUNTERO
    )
    sys.stdout.write(
        "const int32_t **__ctype_toupper_loc(void) { static const int32_t *p = toupper_tbl + %d; return &p; }\n"
        % PUNTERO
    )
    sys.stdout.write(
        "const int32_t **__ctype_tolower_loc(void) { static const int32_t *p = tolower_tbl + %d; return &p; }\n"
        % PUNTERO
    )


def main() -> None:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, ValueError):
        pass
    b_tbl = extend_class(class_bits())
    up = toupper_values()
    low = tolower_values()
    check_invariants(b_tbl, up, low)
    if "--check" not in sys.argv[1:]:
        emit(b_tbl, up, low)


if __name__ == "__main__":
    main()
