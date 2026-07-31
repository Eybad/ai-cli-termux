# Handoff: agy v1.1.9 no instala (parche VA39 desactualizado)

Fecha: 2026-07-31. Autora del handoff: sesión anterior (opencode).

## Problema

`bash install.sh agy` falla con v1.1.9 (la única versión que sirve el manifest
de Google). El parche VA39 (`registry/patch_va39.py`) no matchea la estructura
del binario nuevo → fail-closed correcto → no se instala → rollback a 1.1.8.

El instalador **funciona bien**: el fail-closed hizo su trabajo (rechazó un
binario que crashea en kernels VA39). Lo que falta es actualizar los patrones
del parche para v1.1.9.

## Estado actual

- agy **1.1.8 instalado y verificado** (`verify.sh agy`: 0 fallos, 0 warnings).
- El `--update` de agy está bloqueado mientras el parche no soporte 1.1.9:
  cada corrida resuelve 1.1.9 → falla patch_va39 → falla-closed.
- No hay pin de agy en `sha256.txt` (pinning opcional solo cubre checksums de
  tarballs, no resuelve la incompatibilidad del parche).

## Evidencia recopilada

Salida del parche sobre el binario v1.1.9 (binario completo, 182,472,600 bytes):

```
[1] ubfx patches : 1  (esperado ~15)   ← tag extraction (crítico, casi ausente)
    lsl patches  : 17 (esperado ~2)    ← tag insertion (desbalanceado)
[2] Random mask  : 0  (esperado ~3)    ← CRÍTICO: patrón no encontrado
[3] MmapAligned  : 6  (esperado ~1)    ← patrón encontrado 6× (¿falsos positivos?)
[4] Tag constants: 7 words reescritas  ← constante 4<<42 etc. SÍ presentes
[5] faccessat2   : 1 syscall wrapper reescrito ← OK
```

Interpretación:
- El binario 1.1.9 mantiene el tag en bit 42 (las constantes `mov xN, #K, lsl #42`
  del parche 4 se encuentran), pero el código que lo **extrae** (ubfx #42,#3)
  cambió de forma radical (1 vs ~15).
- La máscara random de mmap (`mov x10,#-0x6c00000001; movk x10,#0,lsl #48`)
  desapareció → Google cambió el algoritmo de hint de mmap en TCMalloc.
- `lsl #42` con 17 ocurrencias sugiere que la inserción del tag ahora se hace
  distinto (o hay falsos positivos en otro código del binario).

Consecuencia: `ubfx_count == 0`? No — ubfx_count == 1, pero el script exige
`mask_count > 0` (Random mask) y eso da 0 → `missing_critical` → exit 1.

## Recursos guardados

- **Binario crudo v1.1.9 (sin parchear)**:
  `/data/data/com.termux/files/usr/tmp/opencode/agy-raw-v1.1.9.bin`
  (182,472,600 bytes, sha512 `9e5240be122ef936...`)
- Si falta, se re-descarga desde el manifest:
  `https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json`
  → clave `.url` (tarball cli_linux_arm64.tar.gz; binario interno: `antigravity`).
- Checksums de referencia (sha512):
  - tarball v1.1.9: `9d28ab7e...` (ver manifest; es el que verifica install.sh)
  - binario crudo v1.1.9: `9e5240be122ef93681ecb371163e7f0304cce08b75891004971c5221c11ab5f80c067456abb62a6e5515142b71fbdc1d4d33008e1315be5483bb78cfbc1fa0f2`
  - binario 1.1.8 parcheado (el que funciona hoy):
    `328a8431e1ccfd674275dad655ae9d40adcd91d3b411336d4d5f9b8c94c01afb5b237df6a9e1aaccda68c3b744ee7b8ea7466ceab25e6fa98c72504262316a54`
  - binario 1.1.8 crudo (original, `binary_checksum_original` del manifest 1.1.8):
    `e03be7d5b58210246415705679bc813925eac71ea66c5366c311758c34ce9021c8928882857b5032aefa8160d3927899817230db185cab73a715c57334deacd7`

## Análisis técnico de referencia

- Issue original con el análisis del parche (hjotha, Brajesh2022):
  `https://github.com/google-antigravity/antigravity-cli/issues/64`
- El parche reescribe instrucciones ARM64 por pattern-matching (no offsets):
  - ubfx/lsl bit 42 → bit 35 (extracción/inserción de tag TCMalloc)
  - máscaras de dirección random para mmap (48 → 39 bits)
  - límite de MmapAlignedLocked (1<<48 → 1<<39, `0xF2E00029` → `0xD3596129`)
  - constantes inlined: `0xD2C20009` (4<<42), `0xD2C10009` (2<<42),
    `0xD2C3000D` (6<<42), `0xD2C08008` (1<<42), masks `0xF2C20008/09`,
    `0xF2C38008/09`, tag masks `0x92560A6C/6A`
  - faccessat2 (nr 439) → faccessat (nr 48): patrón
    `mov x5,xzr; mov x6,xzr; mov x0,#0x1b7; bl <syscall>`

## Plan sugerido

1. **RE del binario v1.1.9** (guardado en tmp): buscar con qué se reemplazó
   - la extracción de tag (antes ubfx #42,#3): buscar `and`+`lsr` o `ubfx`
     con otros inmediatos alrededor de las constantes de tag que SÍ aparecen
   - la máscara random de mmap: buscar hints de mmap en TCMalloc (google_malloc/
     MmapAligned), quizás `movk x10,#K,lsl #48` con otra constante
   - los 6× `0xF2E00029`: confirmar cuáles son MmapAligned reales y cuáles
     falsos positivos
2. **Actualizar `registry/patch_va39.py`** con los nuevos patrones, manteniendo
   fail-closed (si un patrón crítico no se encuentra → exit 1).
3. **Probar en orden**:
   - `bash -n install.sh verify.sh && shellcheck install.sh verify.sh`
   - `bash install.sh agy` → debe instalar 1.1.9
   - `bash verify.sh agy` → todos PASS
   - `agy --version` → 1.1.9
   - `bash install.sh agy --update` → "ya está actualizado"
4. Re-evaluar la política del hook en `registry/agy.conf`: hoy el hook **no
   aborta** si el parche falla ("el binario sin parche podría funcionar en
   VA48") y el fallo real lo detecta `verify_install` (SIGSYS). Para agy eso
   es engañoso: el binario sin parche **no puede funcionar** en Android
   (faccessat2 bloqueado por seccomp → SIGSYS garantizado). Considerar
   fail-fast en el hook cuando los parches críticos faltan.

## Restricciones (AGENTS.md)

- **No tocar `install.sh`**: todo cambio de agy va en `registry/agy.conf` o
  `registry/patch_va39.py`. El instalador es genérico.
- **Preservar fail-closed**: sin parches críticos → no instalar.
- **No bypassear `verify.sh`**: si falla, el cambio está incompleto.
- `shellcheck install.sh verify.sh` debe quedar en cero antes de commit.

## Hallazgos laterales (menores, ya resueltos en la sesión)

- El rollback tras fallo de agy restauró bien la versión previa; el estado
  "raro" (binario crudo modo 700) provenía de un extract manual, no del script.
- Backups huérfanos `.agy.backup.*` / `.opencode.backup.*` quedaban de
  instalaciones viejas interrumpidas (175MB) → limpiados manualmente. Si
  reaparecen, `verify.sh` no los detecta (mejora posible futura).
- Mensaje engañoso post-fallo: "Probá cerrar y reabrir Termux" cuando el
  problema real es el parche. Mejorable en `install.sh` o el hook.
