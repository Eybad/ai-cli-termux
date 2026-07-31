#!/usr/bin/env python3
"""
patch_va39.py — Parche VA48→VA39 + faccessat2→faccessat para binarios
Go+TCMalloc en Android/Termux aarch64.

Análisis original:
  https://github.com/google-antigravity/antigravity-cli/issues/64
  (hjotha, Brajesh2022)

Problema 1 — TCMalloc:
  El binario usa TCMalloc compilado para un espacio de direcciones virtuales
  de 48 bits (VA48). Android expone solo 39 bits (VA39) en la mayoría de
  dispositivos. TCMalloc genera hints de mmap por encima del rango aceptado
  por el kernel → crash inmediato con "MmapAligned() failed".

  El parche reescribe instrucciones ARM64 que codifican:
    - ubfx/lsl con bit 42 (posición del tag en VA48) → bit 35 (VA39)
    - Máscaras de dirección random para mmap (48 bits → 39 bits)
    - Límite superior de MmapAlignedLocked (1<<48 → 1<<39)
    - Constantes de tag y deallocación inlined en el código

Problema 2 — faccessat2:
  Go usa la syscall faccessat2 (nr 439) para os/exec.LookPath.
  Android la bloquea vía seccomp → SIGSYS: bad system call.
  El parche reemplaza el número de syscall por faccessat (nr 48),
  que tiene la misma firma pero sin el parámetro flags.

Uso:
  python3 patch_va39.py <binario_entrada> [binario_salida]

Si no se especifica salida, se genera <entrada>.va39

Seguridad:
  - El script NO descarga nada, NO ejecuta nada, NO toca la red.
  - Solo lee un archivo, modifica bytes en memoria, y escribe otro.
  - Cada parche se aplica por pattern-matching de instrucciones ARM64,
    no por offsets fijos (sobrevive cambios de versión).
  - Si no encuentra patrones, avisa y aborta.
"""

import hashlib
import shutil
import struct
import sys
from pathlib import Path


def main():
    if len(sys.argv) < 2:
        print(f"Uso: {sys.argv[0]} <binario> [salida]", file=sys.stderr)
        sys.exit(2)

    src = Path(sys.argv[1])
    dst = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(str(src) + ".va39")

    if not src.exists():
        print(f"ERROR: No existe: {src}", file=sys.stderr)
        sys.exit(1)

    print(f"Entrada  : {src}")
    print(f"SHA512 in: {hashlib.sha512(src.read_bytes()).hexdigest()[:32]}...")
    print()

    shutil.copyfile(src, dst)
    data = bytearray(dst.read_bytes())

    def get(off):
        return struct.unpack_from("<I", data, off)[0]

    def put(off, word):
        struct.pack_into("<I", data, off, word)

    # ── Ya no restringimos a google_malloc ───────────────────────────────
    # En nuevas versiones (ej. 1.1.8), LTO o el linker mueven las rutinas de
    # TCMalloc fuera de google_malloc hacia .text o las inlinan.
    # Escaneamos el binario completo.
    lo, hi = 0, len(data)
    print("Escaneando binario completo (los parches de TCMalloc pueden estar inlined).")
    print()

    # ── Parche 1: ubfx #42,#3 → #35,#3 y lsl #42 → #35 ────────────────
    # Mueve la extracción/inserción del tag de TCMalloc del bit 42 al 35.
    ubfx_count = 0
    lsl_count = 0
    for off in range(lo, hi - 3, 4):
        w = get(off)
        if (w & 0x7F800000) == 0x53000000:  # familia bitfield-move
            immr = (w >> 16) & 0x3F
            imms = (w >> 10) & 0x3F
            if immr == 42 and imms == 44:  # ubfx Xn, Xm, #42, #3
                put(
                    off,
                    (w & ~((0x3F << 16) | (0x3F << 10)))
                    | (35 << 16)
                    | (37 << 10),
                )
                ubfx_count += 1
            elif immr == 22 and imms == 21:  # lsl Xn, Xm, #42
                put(
                    off,
                    (w & ~((0x3F << 16) | (0x3F << 10)))
                    | (29 << 16)
                    | (28 << 10),
                )
                lsl_count += 1

    print(f"[1] ubfx patches : {ubfx_count}  (esperado ~15)")
    print(f"    lsl patches  : {lsl_count}  (esperado ~2)")

    # ── Parche 2: Máscara de dirección random para mmap ─────────────────
    # mov x10, #-0x6c00000001; movk x10, #0, lsl #48
    #   → mov x10, #-1; lsr x10, x10, #29
    # Resultado: x10 = 0x7ffffffff (máscara de 39 bits)
    mask_count = 0
    for off in range(lo, hi - 7, 4):
        if get(off) == 0x92D3800A and get(off + 4) == 0xF2E0000A:
            put(off, 0x9280000A)      # mov x10, #-1
            put(off + 4, 0xD35DFD4A)  # lsr x10, x10, #29
            mask_count += 1

    print(f"[2] Random mask  : {mask_count}  (esperado ~3)")

    # ── Parche 3: MmapAlignedLocked upper bound: 1<<48 → 1<<39 ─────────
    mmap_count = 0
    for off in range(lo, hi - 3, 4):
        if get(off) == 0xF2E00029:
            put(off, 0xD3596129)  # 1<<39 en lugar de 1<<48
            mmap_count += 1

    print(f"[3] MmapAligned  : {mmap_count}  (esperado ~1)")

    # ── Parche 4: Constantes de tag y masks de deallocación inlined ──────
    # Mueve la posición del tag del bit 42 al bit 35 en todas las constantes
    # que TCMalloc genera como immediate en instrucciones mov/movk/and.
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
    counts = {old: 0 for old in word_rewrites}
    for off in range(lo, hi - 3, 4):
        w = get(off)
        if w in word_rewrites:
            put(off, word_rewrites[w])
            counts[w] += 1

    print(f"[4] Tag constants: {sum(counts.values())} words reescritas")

    # ── Parche 5: faccessat2 (nr 439) → faccessat (nr 48) ──────────────
    # Patrón: mov x5, #0; mov x6, #0; mov x0, #0x1b7 (439); bl <syscall>
    # Se reemplaza solo el mov x0 con el nr de syscall.
    faccessat2_count = 0
    for off in range(0, len(data) - 15, 4):
        if (
            get(off) == 0xAA1F03E5      # mov x5, xzr
            and get(off + 4) == 0xAA1F03E6   # mov x6, xzr
            and get(off + 8) == 0xD28036E0   # mov x0, #0x1b7 (439=faccessat2)
            and (get(off + 12) & 0xFC000000) == 0x94000000  # bl <target>
        ):
            put(off + 8, 0xD2800600)  # mov x0, #48 (faccessat)
            faccessat2_count += 1

    print(f"[5] faccessat2   : {faccessat2_count} syscall wrapper reescrito")

    # ── Escribir resultado ──────────────────────────────────────────────
    dst.write_bytes(data)
    dst.chmod(0o755)

    out_sha = hashlib.sha512(dst.read_bytes()).hexdigest()[:32]
    print()
    print(f"SHA512 out: {out_sha}...")
    print(f"Salida    : {dst}")
    print()

    total = (
        ubfx_count
        + lsl_count
        + mask_count
        + mmap_count
        + sum(counts.values())
        + faccessat2_count
    )

    if total == 0:
        print("[ERROR] NINGÚN parche aplicado — la estructura del binario cambió.")
        print("   NO uses el binario generado.")
        sys.exit(1)

    # Los parches ubfx (tag extraction) y la máscara random de mmap son
    # críticos: sin ellos el binario crashea con "MmapAligned() failed" en
    # kernels VA39 (la mayoría de los dispositivos Android). Si faltan,
    # el binario generado no es confiable → fallar.
    missing_critical = []
    if ubfx_count == 0:
        missing_critical.append("ubfx (tag extraction, esperado ~15)")
    if mask_count == 0:
        missing_critical.append("máscara random de mmap (esperado ~3)")

    if missing_critical:
        print("[ERROR] Faltan parches críticos:")
        for m in missing_critical:
            print(f"   - {m}")
        print("   El binario generado puede crashear en kernels VA39; no se usa.")
        return 1

    if lsl_count == 0:
        print("[WARN] No se encontraron parches lsl (tag insertion).")
    if mmap_count == 0:
        print("[WARN] No se encontró el límite de MmapAlignedLocked.")

    print("[OK] Parche aplicado (con los patrones encontrados).")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
