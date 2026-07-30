# ai-cli-termux

Instalador de CLIs de IA para Termux (glibc overlay, sin proot).

## Comandos

```bash
bash install.sh <tool>          # instalar
bash install.sh <tool> -v X.Y.Z # versión específica
bash install.sh <tool> -r       # reinstalar
bash install.sh <tool> -u       # desinstalar
bash verify.sh <tool>           # verificar integridad post-instalación
shellcheck install.sh verify.sh # lint obligatorio antes de commit
```

El workflow `.github/workflows/update-hashes.yml` actualiza `sha256.txt` vía CI para tools con `RELEASE_SOURCE=github`.

## Design principles

- **`install.sh` debe mantenerse genérico.** Todo comportamiento específico de un tool pertenece a su `registry/*.conf` (hooks, env, configuración).
- **Preferir configuración sobre condicionales en el instalador.** No agregar `if tool == x` en `install.sh`.
- **Preservar fail-closed.** No omitir ni debilitar verificaciones de checksum.
- **Compatibilidad POSIX.** Usar bash 3.x+ portable. No asumir bash 4+ (arrays asociativos, etc.). Termux usa bash 5.x, pero el código debe funcionar en bash 3.
- **No agregar dependencias nuevas sin justificación.** Cada dep nueva es un punto de fallo en Termux.

## Antes de modificar install.sh

Preguntar: ¿esto se puede implementar como?

1. Configuración en `registry/*.conf`
2. Variable `WRAPPER_ENV`
3. Hook `pre_wrapper_hook` o `post_install_hook`

Si la respuesta es sí, no tocar `install.sh`.

## Dónde pertenece cada cambio

| Qué querés hacer | Dónde |
|---|---|
| Agregar/quitar un tool | `registry/<tool>.conf` + `sha256.txt` |
| Cambiar ENV, flags, o parches de un tool | `registry/<tool>.conf` (WRAPPER_ENV, hooks) |
| Modificar el pipeline de instalación | `install.sh` (solo si no se puede en .conf) |
| Agregar/quitar pasos de verificación | `verify.sh` |
| Actualizar hash de un release existente | `sha256.txt` |
| Automatizar actualización de hashes en CI | `.github/workflows/update-hashes.yml` |

## Invariants (nunca romper)

- **Fail-closed en checksums.** Sin hash verificado → no se instala.
- **Zero condicionales por tool en install.sh.** Ni `if`, ni `case $TOOL`, ni grep del nombre.
- **La lógica específica de un tool vive en registry/*.conf o sus hooks.** No en install.sh.
- **No bypassear verify.sh.** Si verify.sh falla, el cambio está incompleto.

## Verificación antes de commit

1. `shellcheck install.sh verify.sh` — cero warnings
2. `bash install.sh <tool> -v <version>` — instalación limpia
3. `bash verify.sh <tool>` — todos PASS
4. Revisar `git diff` — sin cambios espurios

## Archivos que leer antes de modificar

- `README.md` — contexto general y ejemplos de uso
- `registry/*.conf` — configuración existente (openicode.conf, agy.conf, kiro-cli.conf como referencia)
- `install.sh` — pipeline completo (especialmente las funciones `resolve_version` y `download`)
- `verify.sh` — pasos de verificación (si se toca verify.sh)
- `sha256.txt` — formato y entradas existentes

## Estructura

- `install.sh` — instalador genérico
- `verify.sh` — verificador post-instalación
- `sha256.txt` — hashes pineados
- `registry/<tool>.conf` — configuración por tool (descarga, checksum, env, hooks)

## RELEASE_SOURCE (en .conf)

| Tipo | Requiere | Checksum |
|---|---|---|
| `github` | `REPO`, `ARCHIVE_TEMPLATE` | `hashfile` vía `sha256.txt` o `--sha256` flag |
| `manifest_json` | `MANIFEST_URL`, `MANIFEST_KEY_*` | `manifest` remoto (ej: agy, Google Cloud) |
| `url_template` | `DOWNLOAD_URL_TEMPLATE` | `hashfile` + versión explícita con `-v` |

## Arch mapping

Termux `uname -m` → internal `ARCH`:
- `aarch64` → `arm64`; `x86_64` → `amd64`

Si un tool usa nombres distintos (opencode usa `x64`, kiro usa `aarch64`), definir `ARCH_OVERRIDE_AARCH64` / `ARCH_OVERRIDE_X86_64`.

## sha256.txt

```
tool/vX.Y.Z         hash   # lookup sin arch (por defecto arm64)
tool/vX.Y.Z:amd64   hash   # lookup con arch explícito
```

El lookup prueba `key:${ARCH}` primero, luego `key` solo.

## Agregar un tool nuevo

1. Crear `registry/<name>.conf`
2. Campos obligatorios: `APP_NAME`, `DISPLAY_NAME`, `RELEASE_SOURCE`, `CHECKSUM_ALGO`, `CHECKSUM_SOURCE`, `ELF_NAME`
3. `APP_NAME` = nombre del wrapper. `ELF_NAME` = nombre del binario real dentro del tarball (ej: `APP_NAME=agy`, `ELF_NAME=antigravity`).
4. Si `CHECKSUM_SOURCE=hashfile`, agregar entrada en `sha256.txt`
5. Hooks opcionales: `pre_wrapper_hook` (antes del wrapper), `post_install_hook` (después de verify)

## Pipeline (vista de alto nivel)

1. Preflight — detecta Termux, arquitectura, dependencias
2. Resolve version — según `RELEASE_SOURCE`
3. Resolve checksum — `sha256.txt` o manifest remoto
4. Check current — salta si ya instalado
5. Install deps — `pkg install` glibc-runner, patchelf, etc.
6. Download → verify tarball — fail-closed si mismatch
7. Verify attestation — solo si configurado, requiere `gh`
8. Extract & install — busca el ELF por nombre + arquitectura
9. Patch — modifica el binario para que ejecute contra el runtime glibc de Termux
10. Wrapper — script en `$PREFIX/bin/$APP_NAME` que limpia entorno bionic heredado y ejecuta el binario
11. Verify install → write manifest → hooks

## Wrapper (propósito)

El wrapper aísla el runtime glibc del entorno bionic de Termux. Exporta variables definidas en `WRAPPER_ENV` del `.conf`. Ejecuta el binario directo o vía loader glibc según `NEEDS_PATCHELF`.

## Mitigaciones Termux (agy.conf)

El `pre_wrapper_hook` de agy es el más complejo. Incluye:
- Parche de kernel VA39 + faccessat2 vía `registry/patch_va39.py`
- Shim de libc.so (Termux usa linker script, no ELF)
- Shims de navegador/portapapeles para OAuth
- DNS vía `getprop` + fallback

Esto es específico de agy. No copiar a otros tools sin necesidad.
