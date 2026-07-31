#!/usr/bin/env python3
"""
patch_va39.py — Parche adaptativo VA48→VA39 + faccessat2→faccessat
para binarios Go+TCMalloc en Android/Termux aarch64.

Análisis original:
  https://github.com/google-antigravity/antigravity-cli/issues/64
  (hjotha, Brajesh2022)

Problema 1 — faccessat2 (nr 439):
  Go usa la syscall faccessat2 (nr 439) para os/exec.LookPath.
  Android la bloquea vía seccomp → SIGSYS: bad system call garantizado
  (probado: el binario crudo de agy crashea en clipboard.init al
  arrancar, antes de llegar al main). El parche reemplaza el número
  de syscall por faccessat (nr 48), misma firma sin el flags.

Problema 2 — TCMalloc VA48 (solo versiones que lo usan):
  Algunas versiones de agy usan TCMalloc compilado para un espacio de
  direcciones virtuales de 48 bits (VA48). Android expone solo 39 bits
  (VA39) → hints de mmap por encima del rango aceptado por el kernel →
  crash "MmapAligned() failed". Desde agy 1.1.9 Google lo corrigió (el
  binario ya no contiene la maquinaria de tags en bit 42), pero 1.1.8
  y anteriores sí la tienen.

Estrategia (v2 — adaptativa):
  Fase A (siempre): faccessat2 → faccessat. El patrón lo genera el
    compilador de Go y es estable entre versiones:
    `mov x0, #0x1b7` seguido de `bl <thunk syscall>`. Se reemplazan
    TODOS los sitios (el parche v1 solo cubría 1 de 5; los otros 4
    quedaban como trampas SIGSYS latentes).
  Fase B (condicional): TCMalloc VA48→VA39. Solo si el binario muestra
    firmas fuertes de tags en bit 42. El discriminador es la constante
    "cold tag" 2<<42 (única de TCMalloc): binarios sanos con ubfx #42
    casuales (ej. opencode: 2 sitios, no es TCMalloc) no la tienen:
      - cold2 (mov xN, #2, lsl #42)                 ≥ 2
      - cold2 ≥ 1 Y ubfx Xn,Xm,#42,#3 ≥ 2           (extracción)
      - máscara random de mmap (92D3800A F2E0000A)  ≥ 1
      - masks de deallocación (F2C20008/09,
        F2C38008/09, 92560A6C/6A)                    ≥ 1
    Todas las cuentas y reescrituras se restringen a segmentos LOAD
    ejecutables (parseo ELF nativo, sin dependencias): los falso
    positivos en .rodata/.bun no se tocan.
    Con firmas presentes pero sin ningún parche aplicable → exit 1
    (fail-closed: la estructura cambió a fondo; el binario NO se usa).
    Sin firmas → el binario queda intacto: reescribir constantes que
    parecen tags pero no lo son (thresholds de size-class, floats,
    hashes) corrompería la versión.
  Fase C (gate final, en el instalador): el hook ejecuta el binario
    parcheado (--version). El SIGSYS de faccessat2 y el crash de
    MmapAligned ocurren en init/primera asignación, así que cualquier
    estructura no cubierta aborta la instalación y restaura la versión
    anterior. No confiamos solo en conteos estáticos.

Uso:
  python3 patch_va39.py <binario_entrada> [binario_salida]

Si no se especifica salida, se genera <entrada>.va39

Exit codes:
  0 — binario parcheado, o sin nada que parchear (binario compatible).
  1 — firmas de problemas presentes pero estructura no reconocida.
  2 — uso incorrecto.

Seguridad:
  - El script NO descarga nada, NO ejecuta nada, NO toca la red.
  - Solo lee un archivo, modifica bytes en memoria, y escribe otro.
  - Cada parche se aplica por pattern-matching de instrucciones ARM64,
    no por offsets fijos (sobrevive cambios de versión).
"""

import array
import hashlib
import struct
import sys
from pathlib import Path


def exec_load_ranges(raw):
    """Rangos de bytes de los segmentos PT_LOAD ejecutables (PF_X).

    Escaneamos solo código ejecutable: instrucciones falsas positivas en
    .rodata/.bun/.lrodata no se cuentan ni se reescriben. Si el ELF no
    se puede parsear, devolvemos None → se escanea el archivo completo
    (comportamiento conservador, equivalente al parche v1).
    """
    if raw[:4] != b"\x7fELF":
        return None
    if raw[4] == 1:  # ELF32
        e_phoff = struct.unpack_from("<I", raw, 28)[0]
        _, e_phnum = struct.unpack_from("<HH", raw, 42)
        p_fmt, p_size = "<IIIIIIII", 32
    elif raw[4] == 2:  # ELF64
        e_phoff = struct.unpack_from("<Q", raw, 32)[0]
        _, e_phnum = struct.unpack_from("<HH", raw, 54)
        p_fmt, p_size = "<IIQQQQQQ", 56
    else:
        return None
    ranges = []
    for i in range(e_phnum):
        p = struct.unpack_from(p_fmt, raw, e_phoff + i * p_size)
        if p[0] == 1 and (p[1] & 4):  # PT_LOAD con PF_X
            ranges.append((p[4], p[4] + p[5]))
    return ranges or None


def in_ranges(off, ranges):
    if ranges is None:
        return True
    return any(lo <= off < hi for lo, hi in ranges)


def main():
    if len(sys.argv) < 2:
        print(f"Uso: {sys.argv[0]} <binario> [salida]", file=sys.stderr)
        sys.exit(2)

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(str(src) + ".va39")

    if not src.exists():
        print(f"ERROR: No existe: {src}", file=sys.stderr)
        sys.exit(1)

    raw = src.read_bytes()
    print(f"Entrada  : {src}")
    print(f"SHA512 in: {hashlib.sha512(raw).hexdigest()[:32]}...")
    print()

    exec_ranges = exec_load_ranges(raw)

    data = bytearray(raw)
    # Lectura veloz: palabras little-endian alineadas a 4 bytes.
    words = array.array("I")
    words.frombytes(raw[: len(raw) - (len(raw) % 4)])
    del raw
    n = len(words)

    def get(off):
        return struct.unpack_from("<I", data, off)[0]

    def put(off, word):
        struct.pack_into("<I", data, off, word)

    # ── Fase A: faccessat2 (nr 439) → faccessat (nr 48) ─────────────────
    # Patrón generado por Go: mov x0, #0x1b7; bl <thunk syscall>.
    # El thunk mueve el número a x8 y ejecuta svc (r8=439 en el crash).
    fa_count = 0
    for i in range(n - 1):
        off = i * 4
        if not in_ranges(off, exec_ranges):
            continue
        if words[i] == 0xD28036E0:  # mov x0, #0x1b7 (439)
            if (words[i + 1] & 0xFC000000) == 0x94000000:  # bl <thunk>
                put(off, 0xD2800600)  # mov x0, #48 (faccessat)
                fa_count += 1
    if fa_count:
        print(f"[A] faccessat2   : {fa_count} wrappers reescritos "
              f"(nr 439 → 48)")
    else:
        print("[A] faccessat2   : 0 — no presente, versión sin el problema.")

    # ── Detección de firmas TCMalloc VA48 (un solo recorrido) ───────────
    ubfx42 = []    # ubfx Xn, Xm, #42, #3 → (immr=42, imms=44)
    lsl42 = []     # lsl  Xn, Xm, #42     → (immr=22, imms=21)
    mask_pat = []  # mov x10,#-0x6c00000001; movk x10,#0,lsl #48
    mmap29 = []    # movk x9, #0x1, lsl #48 (límite MmapAlignedLocked)
    word_rewrites = {
        0xD2C20009: 0xD2C00409,  # P0 tag x9:  4<<42 → 4<<35
        0xD2C2000A: 0xD2C0040A,  # P0 tag x10: 4<<42 → 4<<35
        0xF2C20008: 0xF2DFF408,  # dealloc mask x8
        0xF2C20009: 0xF2DFF409,  # dealloc mask x9
        0xD2C10009: 0xD2C00209,  # cold tag x9:  2<<42 → 2<<35
        0xD2C1000A: 0xD2C0020A,  # cold tag x10: 2<<42 → 2<<35
        0xF2C38008: 0xF2DFF708,  # cold/tagged dealloc mask x8
        0xF2C38009: 0xF2DFF709,  # cold/tagged dealloc mask x9
        0x92560A6C: 0x925D0A6C,  # tag mask 0x1c0000000000 → 0x3800000000 x12
        0x92560A6A: 0x925D0A6A,  # tag mask x10
        0xD2C3000D: 0xD2C0060D,  # P1 tag x13: 6<<42 → 6<<35
        0xD2C3000C: 0xD2C0060C,  # P1 tag x12: 6<<42 → 6<<35
        0xD2C08008: 0xD2C00108,  # kTagFree: 1<<42 → 1<<35
    }
    # Firmas de detección: tags "cold" 2<<42 y masks de deallocación.
    cold2_keys = (0xD2C10009, 0xD2C1000A)
    dealloc_keys = (0xF2C20008, 0xF2C20009, 0xF2C38008, 0xF2C38009,
                    0x92560A6C, 0x92560A6A)
    tag_hits = {old: [] for old in word_rewrites}

    for i in range(n):
        off = i * 4
        if not in_ranges(off, exec_ranges):
            continue
        w = words[i]
        if (w & 0x7F800000) == 0x53000000:  # familia bitfield-move
            immr = (w >> 16) & 0x3F
            imms = (w >> 10) & 0x3F
            if immr == 42 and imms == 44:
                ubfx42.append(off)
            elif immr == 22 and imms == 21:
                lsl42.append(off)
        elif w == 0x92D3800A and i + 1 < n and words[i + 1] == 0xF2E0000A:
            mask_pat.append(off)
        elif w == 0xF2E00029:
            mmap29.append(off)
        elif w in word_rewrites:
            tag_hits[w].append(off)

    ubfx_n = len(ubfx42)
    lsl_n = len(lsl42)
    mask_n = len(mask_pat)
    mmap_n = len(mmap29)
    cold2_n = sum(len(tag_hits[k]) for k in cold2_keys)
    dealloc_n = sum(len(tag_hits[k]) for k in dealloc_keys)

    # ── Fase B: TCMalloc VA48→VA39 (solo si hay firmas fuertes) ────────
    # ubfx #42,3 aislado NO dispara (opencode sano tiene 2; agy 1.1.9
    # tiene 1 en data). La constante 2<<42 es exclusiva de TCMalloc.
    va48 = (cold2_n >= 2
            or (cold2_n >= 1 and ubfx_n >= 2)
            or mask_n >= 1
            or dealloc_n >= 1)

    if not va48:
        print(f"[B] TCMalloc VA48 no detectado (ubfx={ubfx_n}, "
              f"2<<42={cold2_n}, mask={mask_n}, dealloc={dealloc_n}):")
        print("    binario compatible con VA39, se deja intacto.")
    else:
        print(f"[B] TCMalloc VA48 detectado (ubfx={ubfx_n}, 2<<42={cold2_n}, "
              f"mask={mask_n}, dealloc={dealloc_n}); aplicando parche...")
        total = 0
        for off in ubfx42:
            w = get(off)
            put(off, (w & ~((0x3F << 16) | (0x3F << 10)))
                | (35 << 16) | (37 << 10))  # ubfx #35, #3
            total += 1
        for off in lsl42:
            w = get(off)
            put(off, (w & ~((0x3F << 16) | (0x3F << 10)))
                | (29 << 16) | (28 << 10))  # lsl #35
            total += 1
        for off in mask_pat:
            put(off, 0x9280000A)      # mov x10, #-1
            put(off + 4, 0xD35DFD4A)  # lsr x10, x10, #29
            total += 2
        for off in mmap29:
            put(off, 0xD3596129)      # 1<<39 en lugar de 1<<48
            total += 1
        for old, sites in tag_hits.items():
            for off in sites:
                put(off, word_rewrites[old])
                total += 1
        if total == 0:
            print("[ERROR] Firmas VA48 presentes pero NINGÚN parche aplicado.")
            print("   La estructura del binario cambió a fondo; NO se usa.")
            return 1
        print(f"    {total} reescrituras aplicadas "
              f"(ubfx={ubfx_n}, lsl={lsl_n}, mask={mask_n}, "
              f"mmap={mmap_n}, tags={sum(len(v) for v in tag_hits.values())})")

    # ── Escribir resultado ──────────────────────────────────────────────
    dst.write_bytes(data)
    dst.chmod(0o755)

    out_sha = hashlib.sha512(data).hexdigest()[:32]
    print()
    print(f"SHA512 out: {out_sha}...")
    print(f"Salida    : {dst}")
    print()
    print("[OK] Listo. El instalador ejecuta el binario parcheado como "
          "gate final (fail-closed).")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
