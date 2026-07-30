# ai-cli-termux

Instalador de CLIs de IA para Termux (glibc overlay, sin proot).

## Estructura

- `install.sh` — instalador genérico (bash, `set -euo pipefail`)
- `verify.sh` — verificador de integridad post-instalación
- `sha256.txt` — hashes pineados de tarballs por tool+versión+arquitectura
- `registry/<tool>.conf` — define fuente de descarga, checksum, ENV, hooks

## Comandos

```bash
# Instalar (según RELEASE_SOURCE del .conf)
bash install.sh opencode                            # github: resuelve latest
bash install.sh opencode -v 1.18.9                  # github: versión fija
bash install.sh agy                                 # manifest_json: latest
bash install.sh kiro-cli -v 2.15.2                  # url_template: requiere -v

bash install.sh <tool> -r                           # reinstalar
bash install.sh <tool> -u                           # desinstalar

# Verificar
bash verify.sh <tool>

# Actualizar hash en sha256.txt (via CI)
# .github/workflows/update-hashes.yml — solo para RELEASE_SOURCE=github
```

## RELEASE_SOURCE (en registry/*.conf)

| Tipo | Requiere | Checksum |
|---|---|---|
| `github` | `REPO`, `ARCHIVE_TEMPLATE` | `hashfile` (sha256.txt) o `--sha256` |
| `manifest_json` | `MANIFEST_URL`, `MANIFEST_KEY_*` | `manifest` (remoto) |
| `url_template` | `DOWNLOAD_URL_TEMPLATE` |-v` explícito + `hashfile` |

### Arch mapping

Termux `uname -m` → variable interna `ARCH`:
- `aarch64` → `arm64`
- `x86_64` → `amd64`

Si el tool usa nombres distintos (opencode usa `x64`, kiro usa `aarch64`), definir `ARCH_OVERRIDE_AARCH64` / `ARCH_OVERRIDE_X86_64` en el `.conf`.

### sha256.txt

```
opencode/v1.18.9       b16bd7...   # lookup por tool/tag (arch por defecto)
kiro-cli/v2.15.2:arm64 8fa63f...  # lookup por tool/tag:arch
```

`lookup_hashfile()` intenta `key:${ARCH}` primero, fallback a `key`.

## Agregar un tool nuevo

1. Crear `registry/<name>.conf`
2. Campos obligatorios: `APP_NAME`, `DISPLAY_NAME`, `RELEASE_SOURCE`, `CHECKSUM_ALGO`, `CHECKSUM_SOURCE`, `ELF_NAME`
3. Si `CHECKSUM_SOURCE=hashfile`, agregar entrada en `sha256.txt`
4. Si el binario dentro del tarball no se llama `APP_NAME`, diferencias: `APP_NAME` es el wrapper, `ELF_NAME` es el binario real (ej: APP_NAME=agy, ELF_NAME=antigravity)
5. Hooks opcionales: `pre_wrapper_hook` (antes del wrapper), `post_install_hook` (después de verify)

## Pipeline de instalación

1. preflight (detecta Termux, arquitectura, dependencias)
2. resolve_version (según RELEASE_SOURCE)
3. resolve_expected_checksum (sha256.txt o manifest remoto)
4. check_current (salta si ya instalado y misma versión)
5. install_deps (pkg install glibc-repo glibc-runner patchelf file jq curl)
6. download → verify_tarball (fail-closed si mismatch)
7. verify_attestation (solo si ATTEST_PREDICATE set, requiere gh)
8. extract_install (busca ELF por nombre + arquitectura dentro del tarball)
9. patch_interpreter (patchelf: PT_INTERP + DT_RUNPATH al loader glibc)
10. ensure_nsswitch → run_pre_wrapper_hook → create_wrapper
11. verify_install → write_manifest → run_post_install_hook

## Wrapper

Creado en `$PREFIX/bin/$APP_NAME`. Siempre:
- `unset LD_PRELOAD` (evita crash bionic+glibc)
- `unset LD_LIBRARY_PATH`
- Exporta variables definidas en `WRAPPER_ENV` del .conf
- Ejecuta el binario directo (NEEDS_PATCHELF=true) o vía loader (NEEDS_PATCHELF=false)

## Mitigaciones Termux (agy.conf)

El `pre_wrapper_hook` de agy hace:
1. Parche VA39 (TCMalloc 48→39bit + faccessat2) vía `registry/patch_va39.py`
2. Shim libc.so (linker script → symlink al ELF real)
3. Shims de navegador/portapapeles (xdg-open → termux-open-url, xclip → termux-clipboard-set)
4. LD_LIBRARY_PATH con shim dir + glibc lib
5. DNS: consulta `getprop net.dns1/2`, fallback a 8.8.8.8/1.1.1.1

Esto es específico de agy. Otros tools pueden necesitar subconjunto.

## hashfile lookup details

```bash
# lookup_hashfile() en install.sh y verify.sh
# Busca primero con "tool/tag:arch", luego "tool/tag"
# ARCH = arm64 | amd64
# Si el tag es v2.15.2, la clave es tool/v2.15.2 (no "v2.15.2" con "v")
```
