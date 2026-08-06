# Changelog

Todas las versiones notables de ai-cli-termux se documentan en este archivo.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es/1.1.0/) y el proyecto usa [Versionado Semántico](https://semver.org/lang/es/).

## [1.2.0] - 2026-08-06

### Added

- **Gestor `aicli`**: fachada sobre `install.sh`/`verify.sh` (no duplica lógica de instalación). Subcomandos: `install`/`update`/`remove`/`verify` (delegación pura), `list` (estado local desde el manifest + actualización disponible consultada en paralelo con `timeout` por tool; columnas UPDATE: sí/no/n/d; `--offline`, `--json`, filtro por tool; exit 0 siempre), `help` (general, por subcomando y por herramienta), `doctor` (repo, arch, deps, wrapper, loader glibc, tools), `completion <bash|zsh|fish>` (a stdout, con tools dinámicos), `self-install`/`self-update` (wrapper en `$PREFIX/bin` con marca de propiedad `aicli-managed: ai-cli-termux`, fail-closed: nunca pisa un binario ajeno). Exit codes estándar (0 ok · 1 ejecución · 2 uso), `--version`, `--no-color` global, `NO_COLOR`/`TERM=dumb`/no-TTY respetados, sugerencia de typo por prefijo.
- `install.sh --resolve-version` (interfaz máquina interna, plumbing oculto del usage): imprime `TARGET_VERSION=<v>` (sin `v`, preserva `+build`) en stdout y nada más; logs a stderr vía redirección del fd 1; sin efectos (no corre `check_current`, no toca `$PREFIX`); incompatible con `-u`/`-r`/`--update`/`-v`/`--sha256` (exit 2). Lo usa `aicli list` para la columna UPDATE.
- `DESCRIPTION` opcional en `registry/*.conf` (una línea): alimenta `aicli help <tool>` y `aicli list` (JSON y tabla).
- Completions dinámicos: incluyen los tools del registry en el momento de generación.

## [1.1.0] - 2026-08-05

### Added

- Nueva herramienta: **cursor-agent** (Cursor Agent CLI) desde el CDN propio de Cursor (`url_template` + pin manual en `sha256.txt`). Bundle node embebido patcheado al overlay glibc, `ENTRY_POINT` (launcher bash del bundle), alias `agent` gestionado, `agent update` bloqueado, `EXTRA_BINS` para `cursorsandbox`/`crepectl`, shims de navegador y DNS para el login OAuth.
- `ENTRY_POINT` en `install.sh`: el wrapper principal puede execar un script del bundle en vez del ELF (validado fail-closed: existencia + ejecutable, rollback vía trap).
- `ALIASES` en `install.sh`: symlinks gestionados del wrapper (ej: `agent` → `cursor-agent`) con collision-check fail-closed y limpieza con guardia de propiedad en uninstall; verificados por el paso 8.1 de `verify.sh`.
- `latest_hashfile_version` acepta prerelease y build metadata (`2026.07.23-e383d2b`, `0.146.0+android1`): `--update` funciona para esos formatos. Regex compartida (`VERSION_CORE_RE`/`VERSION_SUFFIX_RE`) como fuente única con `parse_version_tag`, portable a mawk/gawk (clases `[.]`/`[+]`).

### Fixed

- `patchelf` 0.19.1 corrompía ELFs grandes no-PIE (`ET_EXEC` con debug_info, ej. el node embebido de cursor-agent) al combinar `--set-interpreter` + `--set-rpath` en una sola invocación (grow simultáneo de `.dynstr` e `.interp` → LOAD solapado → SIGSEGV del loader antes de resolver libs). El paso 10 de `install.sh` ahora aplica el patcheo en dos invocaciones separadas (rpath → interpreter): el ELF reubica los segmentos correctamente. Sin cambios de comportamiento para los tools existentes (regresión opencode/kiro-cli: 0 fallos).
- Hardening del preflight (security review): charset `[a-zA-Z0-9._-]` para `APP_NAME`/`ELF_NAME`/`EXTRA_BINS`/`ENTRY_POINT`/`ALIASES` y rechazo de comillas/`$`/backtick en `DISPLAY_NAME` (vía `grep -F`): ningún valor de `.conf` puede romper las comillas del heredoc del wrapper (el `case` con `[\"'\$\`]` resultó frágil en bash — `\"` dentro de `[ ]` termina el contexto de comillas dobles).
- El rollback de un upgrade fallido ahora restaura también el wrapper de la versión previa (se respalda junto a `libexec`): con `ENTRY_POINT` el wrapper nuevo puede apuntar a un entry point del bundle nuevo inexistente en el viejo; sin el restore, un `--update` fallido dejaba el CLI roto.
- El fresh-fail de `cleanup()` ahora limpia los shims del hook (`_remove_registered_shims` antes del `rm -rf libexec`) y los aliases creados por la corrida fallida; el hook de cursor-agent no pisa archivos existentes (guardia `-e`/`-L`).
- El registro de shims (`shims.txt`) se reconstruye completo en cada corrida: los shims propios de corridas anteriores se re-registran (con la guardia del marcador `termux-*`). Antes, un reinstall dejaba el registro incompleto y el uninstall dejaba shims huérfanos en `$PREFIX/bin`. Aplicado también a `codex.conf` (guardia `-e`/`-L` + re-registro en los shims de navegador y portapapeles).
- Ownership por tool en los shims: cada shim lleva un marcador específico (`# termux-shim: <tool>`) y el registro/borrado (`shims.txt`, `_remove_registered_shims`) solo toca shims con SU marcador. Antes, codex y cursor-agent (que comparten los mismos nombres de navegador) se pisaban entre sí: el uninstall de uno podía borrar los shims del otro. La migración de shims con el marcador viejo (pre-ownership) solo aplica a archivos con la forma exacta del shim antiguo (shebang + exec, sin marcador ajeno): un shim de otro tool o un archivo del usuario no se reescribe. Se aplicó el mismo esquema a `agy.conf` (antes creaba shims sin registro ni marcador). Guardias ahora FIFO-safe (`[[ -f ]]` antes del grep: un FIFO ajeno colgaba el instalador).
- El rollback de un upgrade fallido limpia el delta de la corrida: los shims/aliases NUEVOS que la versión previa no registraba se eliminan (con guardia de propiedad) antes de restaurar el backup; antes quedaban huérfanos con el registro viejo.
- Validación de nombres endurecida: `.`/`..` como token completo rechazados en `APP_NAME`/`ELF_NAME`/`EXTRA_BINS`/`ENTRY_POINT`/`ALIASES` (un path de navegación validaba el charset pero apuntaba a directorios), y `DISPLAY_NAME` rechaza también newline/CR y el resto de los bytes de control (0x01-0x1f, 0x7f — un ESC viajaría al terminal vía ANSI injection). Regex compartida ahora estricta según semver: sin `_` en prerelease/build. Defensa en profundidad: los removedores revalidan con el mismo charset los nombres leídos de `shims.txt`/manifest antes de construir `$PREFIX/bin/$name`.
- `verify.sh`: el WARN de `extra_bins` solo se emite si el `.conf` actual define `EXTRA_BINS` pero el manifest no los registra (instalación previa a la feature). Antes era un falso positivo para todos los tools sin `EXTRA_BINS` (codex, opencode, agy) y el "Reinstalá con -r" sugerido no resolvía nada. `EXTRA_BINS` pre-declarada en la carga del conf (con `set -u` su ausencia en el `.conf` rompía la sección 5.2 con "unbound variable").

## [1.0.0] - 2026-08-01

### Added

- Instalador genérico de CLIs de IA para Termux sin proot: `install.sh` con instalación por tool, versión específica (`-v`), `--update`, reinstalación (`-r`) y desinstalación (`-u`).
- Verificación post-instalación (`verify.sh`): integridad del binario, checksum, wrapper, loader, y ejecución real.
- Checksums automáticos fail-closed: digest del asset vía GitHub API (`release_digest`) o manifest del vendor (`manifest`); pinning opcional en `sha256.txt` (el pin del repo gana).
- Herramientas soportadas: opencode (invocación vía loader glibc), agy (parche adaptativo VA39, shim libc, DNS cgo), kiro-cli (runtime bun del TUI parcheado, `EXTRA_BINS`), codex (build propio en CI).
- Patrón "build en CI" (codex): compilación bionic/Android del código oficial en GitHub Actions con attestation SLSA, publicado en el repo de distribución dedicado (`ai-cli-termux-dist`).
- `EXEC_DIRECT`: binarios nativos sin overlay glibc (ELF estático musl o compilado bionic/Android).
- Shims de navegador y portapapeles para el flujo OAuth en Termux (`xdg-open` → `termux-open-url`, etc.), registrados en `shims.txt` y removidos en la desinstalación.
- Workflow CI de actualización de hashes (`update-hashes.yml`).
