#!/usr/bin/env python3
# gen-ctype-tables.py — Generador de las tablas ctype glibc (locale C) para el
# shim bionic_compat del build de codex.
#
# Por qué: el build arm64 de codex enlaza el prebuilt GLIBC de rusty_v8
# (librusty_v8_release_aarch64-unknown-linux-gnu.a, v149.2.0). Ese objeto
# instancia std::isalnum (libc++ de Chromium) como:
#
#     (*__ctype_b_loc())[c] & (unsigned short int) _ISalnum
#
# El shim bionic_compat.c define __ctype_b_loc()/__ctype_toupper_loc()/
# __ctype_tolower_loc() con la semántica glibc. El shim original usaba tablas
# de CEROS: isalnum devolvía false para todo carácter, y el CHECK
# IsValidMappingName("v8-sandbox") del init del sandbox de V8
# (src/sandbox/sandbox.cc → VirtualAddressSubspace::SetName) fallaba →
# SIGTRAP ("zsh: trace trap codex") al usar el code tool (V8 se inicializa
# lazy, cuando el modelo llama el tool de código; por eso "buscar archivos"
# crashea y el chat normal no).
#
# Semántica de la tabla (fuente: bits/ctype.h y locale/C-ctype.c de glibc):
# la tabla __ctype_b es de 384 unsigned short, indexada -128..255. Los bits de
# clasificación se almacenan SIEMPRE en network byte order (big endian); para
# un host little-endian el enum adapta los bits: _ISbit(bit) =
#   bit < 8 ? 1 << (bit+8) : 1 << (bit-8)
# o sea: _ISupper=0x100 ... _ISgraph=0x8000, _ISblank=0x1, _IScntrl=0x2,
# _ISpunct=0x4, _ISalnum=0x8 (verificado contra la tabla literal de glibc:
# '0'=0xD808, 'A'=0xD508, 'a'=0xD608, punct=0xC004, space=0x6001, NUL=0x2).
# La extensión de índices negativos replica 128..255; EOF (-1) vale 0 en la
# tabla de clases y 0xffffffff en las de conversión (tolower/toupper(EOF)=EOF).
#
# Este script imprime las tres tablas y las funciones __ctype_*_loc.
# Determinista: la salida es idéntica siempre (solo aritmética de enteros; no
# depende del locale del host). Fail-closed: verifica invariantes y aborta
# (exit 1) si algo no cierra; el workflow también valida el fragmento
# generado antes de compilar.
#
# Uso:
#   gen-ctype-tables.py            → fragmento C a stdout (append a bionic_compat.c)
#   gen-ctype-tables.py --check    → verifica invariantes, sin imprimir

import sys

# ── Bits de clasificación glibc (bits/ctype.h, little-endian, locale C) ───────
# Almacenados en network byte order: _ISbit(k) adapta el bit al host.
_ISupper = 0x100
_ISlower = 0x200
_ISalpha = 0x400
_ISdigit = 0x800
_ISxdigit = 0x1000
_ISspace = 0x2000
_ISprint = 0x4000
_ISgraph = 0x8000
_ISblank = 0x0001  # _ISbit(8): (1<<8)>>8 en little-endian
_IScntrl = 0x0002  # _ISbit(9)
_ISpunct = 0x0004  # _ISbit(10)
_ISalnum = 0x0008  # _ISbit(11)

CNTRL = _IScntrl
SPACE = _ISspace | _ISprint | _ISblank          # 0x6001
PUNCT = _ISpunct | _ISprint | _ISgraph          # 0xC004
DIGIT = _ISdigit | _ISxdigit | _ISprint | _ISgraph | _ISalnum  # 0xD808
UHEX = _ISupper | _ISxdigit | _ISalpha | _ISprint | _ISgraph | _ISalnum  # 0xD508
UPPER = _ISupper | _ISalpha | _ISprint | _ISgraph | _ISalnum      # 0xC508
LHEX = _ISlower | _ISxdigit | _ISalpha | _ISprint | _ISgraph | _ISalnum  # 0xD608
LOWER = _ISlower | _ISalpha | _ISprint | _ISgraph | _ISalnum      # 0xC608

TABLE_LEN = 384  # glibc: índice -128..255
PUNTERO = 128     # las funciones exponen la tabla + 128
EOF_VALUE = 0xFFFFFFFF  # tolower/toupper(EOF) = EOF (-1), como glibc


def class_bits() -> list[int]:
    """Bits de clasificación para c en 0..255 (locale C de glibc)."""
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
    # 0x80..0xFF quedan sin clasificar en locale C (0), como glibc.
    return cls


def extend_class(tbl_256: list[int]) -> list[int]:
    """glibc extiende a 384: entrada i = valor de (i - 128) mod 256.
    Para la tabla de clases, EOF (-1) vale 0, que coincide con la copia de
    0xFF (sin clasificar en locale C)."""
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
    """Extensión de las tablas de conversión: los índices negativos replican
    128..255 salvo EOF (-1), que devuelve EOF (-1) como glibc."""
    out = []
    for i in range(TABLE_LEN):
        c = i - PUNTERO
        if c == -1:
            out.append(EOF_VALUE)
        else:
            out.append(tbl_256[c % 256])
    return out


def check_invariants(b_tbl: list[int], up: list[int], low: list[int]) -> None:
    """Fail-closed: si algo no cierra, mensaje + exit 1 (nada se imprime)."""
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
        # Valores literales verificados contra locale/C-ctype.c de glibc
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
        "/* ── Tablas ctype glibc (locale C) ───────────────────────────────\n"
        "   Generadas por scripts/gen-ctype-tables.py — NO editar a mano.\n"
        "   El prebuilt glibc de rusty_v8 usa (*__ctype_b_loc())[c] &\n"
        "   (unsigned short) _ISalnum en std::isalnum: las tablas de ceros\n"
        "   del shim previo hacían fallar IsValidMappingName() del sandbox\n"
        "   de V8 (SIGTRAP al usar el code tool / buscar archivos). */\n\n"
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
    # El fragmento C lleva comentarios con caracteres no-ASCII (─, →): fijar
    # UTF-8 para no depender del encoding que derive del locale del runner
    # (locale C puro → UnicodeEncodeError → build abortado).
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
