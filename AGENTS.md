# ai-cli-termux

Instalador de CLIs de IA para Termux (glibc overlay, sin proot).

## Comandos

```bash
bash install.sh <tool>          # instalar (última versión, checksum automático)
bash install.sh <tool> -v X.Y.Z # versión específica
bash install.sh <tool> --update # actualizar a la última versión si hay una anterior
bash install.sh <tool> -r       # reinstalar
bash install.sh <tool> -u       # desinstalar
bash verify.sh <tool>           # verificar integridad post-instalación
shellcheck install.sh verify.sh # lint obligatorio antes de commit
```

El workflow `.github/workflows/update-hashes.yml` actualiza `sha256.txt` vía CI (solo tools con `RELEASE_SOURCE=github`).

## Checksums (fail-closed, sin mantenimiento manual)

La versión y el checksum default se resuelven automáticamente: digest del asset desde la GitHub API (`CHECKSUM_SOURCE=release_digest`, opencode y codex) o manifest JSON del vendor (`manifest`, agy y kiro-cli). `sha256.txt` es **pinning opcional**: si hay entrada para el tag instalado, el pin del repo gana. Nunca instalar sin hash verificado.

## Design principles

- **`install.sh` debe mantenerse genérico.** Todo comportamiento específico de un tool pertenece a su `registry/*.conf` (hooks, env, configuración).
- **Preferir configuración sobre condicionales en el instalador.** No agregar `if tool == x` en `install.sh`.
- **Preservar fail-closed.** No omitir ni debilitar verificaciones de checksum.
- **Prefer portable POSIX shell constructs.** No usar Bash 4+ features sin una razón fuerte.
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
| Build propio de un tool (sin builds compatibles con Android) | `.github/workflows/build-codex.yml` (patrón codex) |
| Parche de source upstream (generado, no versionado) | `scripts/gen-codex-lock-patch.py` (inventario fail-closed) |
| Agregar/quitar subcomandos o comportamiento del gestor | `aicli` (fachada; nunca lógica de instalación) |
| Cambiar el contrato de resolución de versión | `install.sh` (`--resolve-version`) + `aicli` (parse de `TARGET_VERSION=`) |

## EXEC_DIRECT (binarios nativos sin overlay glibc)

`EXEC_DIRECT=true` (requiere `NEEDS_PATCHELF=false`) marca un binario que corre **nativo** sin el overlay glibc de Termux: ELF estático (musl) o compilado bionic/Android. El wrapper hace `exec "$BIN" "$@"` (sin loader glibc) y `verify.sh` omite los checks de loader/interpreter/rpath. Casos de uso: `codex` (arm64 bionic build propio, amd64 musl verificado).

## Patrón "build en CI" (codex)

Si un vendor solo publica builds incompatibles con Android (ej. musl estático sin DNS en Android), no se instala ese binario: se compila en CI desde el código oficial (pin por tag + commit SHA; si el `Cargo.lock` del tag upstream está desincronizado con su `Cargo.toml`, el workflow lo regenera con `cargo update` y valida con `--locked`) y se publica un release de distribución en el repo de distribución dedicado (`Eybad/ai-cli-termux-dist`) con digest + attestation del workflow (emitida por el repo del proyecto: `ATTEST_REPO`). El instalador queda igual (`RELEASE_SOURCE=github` + `release_digest` apuntando al repo de distribución) y `--update` sobrevive a cada release upstream: el cron del workflow rebuilda solo cuando hay versión nueva. El publish cross-repo usa el secret `DIST_REPO_TOKEN` (PAT fine-grained con `Contents: read/write` sobre el repo de dist; el `GITHUB_TOKEN` del workflow no puede escribir en otro repo). Si el build falla, no se publica (fail-closed: la última buena sigue instalable). Ver `.github/workflows/build-codex.yml`.

### Patch series con semver build metadata (vX.Y.Z+androidN)

Si el build de Android necesita un parche sobre el source upstream, el tag de dist lleva build metadata: `vX.Y.Z+androidN` (`patch_rev`, default 1; re-emitir una corrección = `patch_rev=2`). El parche **se genera, no se versiona**: `scripts/gen-codex-lock-patch.py` reescribe el source (inventario fail-closed de call sites; desvío → abort del build) y el workflow lo aplica al checkout antes de compilar. `install.sh` preserva `+build` (versión y tag) y `check_current` compara el **tag del manifest**; `verify.sh` compara núcleos normalizados (el asset amd64 oficial convive en el mismo tag). Caso de uso: `File::lock*` → `Unsupported` en Android (rust-lang/rust#148325), shim `file_lock_shim` con `flock(2)`. Detalles: `docs/adr/0001-release-scheme.md`.

## Invariants (nunca romper)

- **Fail-closed en checksums.** Sin hash verificado → no se instala.
- **Evitar condicionales por tool en install.sh.** Si es inevitable, documentar por qué un hook de registry no puede resolverlo.
- **La lógica específica de un tool vive en registry/*.conf o sus hooks.** No en install.sh.
- **No bypassear verify.sh.** Si verify.sh falla, el cambio está incompleto.

## Verificación antes de commit

1. Leer `README.md`, `registry/*.conf` relevantes, `install.sh`, `verify.sh`, `sha256.txt`
2. `shellcheck install.sh verify.sh` — cero warnings
3. `bash install.sh <tool> -v <version>` — instalación limpia
4. `bash verify.sh <tool>` — todos PASS
5. Revisar `git diff` — sin cambios espurios

## Agregar un tool nuevo

1. Crear `registry/<name>.conf`
2. Campos obligatorios: `APP_NAME`, `DISPLAY_NAME`, `RELEASE_SOURCE`, `CHECKSUM_ALGO`, `CHECKSUM_SOURCE`, `ELF_NAME`
3. `APP_NAME` = nombre del wrapper. `ELF_NAME` = nombre del binario real dentro del tarball.
4. Si `CHECKSUM_SOURCE=hashfile`, agregar entrada en `sha256.txt`
5. Campos opcionales: `EXTRA_BINS` (binarios compañeros del bundle que el binario
   principal invoca por PATH — se patchean igual que `ELF_NAME` y reciben wrapper
   propio en `$PREFIX/bin`, auditados por verify.sh)
6. Hooks opcionales: `pre_wrapper_hook` (antes del wrapper), `post_install_hook` (después de verify)

> Ver `registry/opencode.conf`, `agy.conf`, `kiro-cli.conf` como ejemplos canónicos.

## Gestor aicli (fachada)

`aicli` es una fachada bash sobre `install.sh`/`verify.sh`: orquesta, no duplica. No contiene lógica de instalación ni de verificación; cualquier cambio de pipeline va a `install.sh`/`verify.sh`/`registry/*.conf` y el gestor solo ajusta su interfaz si el contrato cambia.

### Contrato `install.sh --resolve-version` (no romper)

- stdout = **exactamente** `TARGET_VERSION=<v>` (sin prefijo `v`, preserva `+build`) y nada más.
- Logs del instalador → stderr (en modo resolve, `main()` redirige fd 1→2 con `exec 9>&1/1>&2/1>&9/9>&-`, sin pisar fds bajos del llamador).
- Sin efectos colaterales: no corre `check_current`, no descarga a disco persistente, no toca `$PREFIX`.
- Incompatible con `-u`/`-r`/`--update`/`-v`/`--sha256` → exit 2. Resuelto → exit 0.
- Oculto del `usage()` (plumbing): `aicli list` es su único consumidor. El parse en aicli es defensivo (`TARGET_VERSION=*`; desvío → columna `n/d`, el listado nunca se rompe).

### Reglas del gestor

- **Interfaz**: exit codes 0 ok / 1 ejecución / 2 uso; `--help`/`--version` a stdout con exit 0; errores a stderr; `NO_COLOR`/`TERM=dumb`/no-TTY/`--no-color` → sin colores; `list` nunca sale con error por fallo de red.
- **Wrapper** (`self-install`/`self-update`): lleva la marca `aicli-managed: ai-cli-termux`; fail-closed — si `$PREFIX/bin/aicli` existe sin la marca, no se pisa (error + sugerencia). `self-update` exige marca previa.
- **`DESCRIPTION`** en `registry/*.conf` (opcional, 1 línea): alimenta `aicli help <tool>` y `aicli list` (`--json` y tabla). No cambiar su formato (una sola línea, sin comillas internas).
- Al cambiar `aicli`, `shellcheck aicli` también es obligatorio.

## Estructura

- `install.sh` — instalador genérico
- `verify.sh` — verificador post-instalación
- `sha256.txt` — hashes pineados
- `registry/<tool>.conf` — configuración por tool

## Ver también

- `README.md` — formato sha256.txt, arch mapping, RELEASE_SOURCE, pipeline completo, mitigaciones específicas
