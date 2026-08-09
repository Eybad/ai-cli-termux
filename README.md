<div align="center">

# ai-cli-termux

**CLIs de IA ejecutadas de forma nativa en Termux, sin proot**

[![Update hashes](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/update-hashes.yml?style=flat-square&label=update-hashes)](https://github.com/Eybad/ai-cli-termux/actions)
[![Build codex](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/build-codex.yml?style=flat-square&label=build-codex)](https://github.com/Eybad/ai-cli-termux/actions)
[![Android](https://img.shields.io/badge/Android-10%2B-3ddc84?style=flat-square&logo=android&logoColor=white)](https://www.android.com/)
[![Termux](https://img.shields.io/badge/Termux-F--Droid-000000?style=flat-square&logo=terminal)](https://f-droid.org/en/packages/com.termux/)

[Features](#features) • [Herramientas soportadas](#herramientas-soportadas) • [Requisitos](#requisitos) • [Instalación](#instalación) • [Gestor aicli](#gestor-aicli) • [Actualización automática](#actualización-automática) • [Verificación](#verificación) • [Cómo funciona](#cómo-funciona) • [Soluciones técnicas de Android](#soluciones-técnicas-de-android) • [Agregar una CLI nueva](#agregar-una-cli-nueva) • [Estructura del repositorio](#estructura-del-repositorio)

</div>

Instala y audita CLIs de inteligencia artificial — [opencode](https://github.com/anomalyco/opencode), [Antigravity CLI](https://antigravity.google), [Kiro CLI](https://kiro.dev), [OpenAI Codex](https://github.com/openai/codex) y [Cursor Agent CLI](https://cursor.com) — directamente en **Termux** para Android (`aarch64`) y Linux (`x86_64`). Los binarios ELF glibc corren **nativos sobre el kernel de Android** vía el overlay de librerías glibc del ecosistema Termux: sin `proot`, sin máquinas virtuales, con rendimiento 1:1.

> [!TIP]
> Agregar una herramienta nueva solo requiere crear un archivo `registry/<tool>.conf`. El instalador es genérico y no se toca.

## Features

- **Gestor `aicli`** — fachada de línea de comandos: `list` (estado + actualizaciones), `install`/`update`/`remove`, `verify`, `doctor`, completions y auto-instalación del propio gestor.
- **Nativo, sin proot** — binarios ELF glibc ejecutados vía el loader de Termux (`ld-linux-aarch64.so.1`), con `patchelf` y wrappers que resuelven las diferencias con Android (seccomp, DNS, certificados).
- **Framework modular** — cada CLI vive en un `registry/*.conf`: variables, entorno, parches y hooks. Todo lo específico de una herramienta está en su registro.
- **Última versión automática** — versión y checksum se resuelven solos desde la GitHub API, el manifest de Google o el manifest del CDN de Amazon.
- **Fail-closed** — sin checksum verificado no se instala. `sha256.txt` queda como pinning opcional para verificaciones independientes del vendor.
- **Parches adaptativos** — agy se auto-parchea (syscall `faccessat2` + TCMalloc VA48→VA39 si aplica) con smoke test posterior. `--update` funciona sin mantenimiento manual entre versiones.
- **Build en CI** — codex se compila en GitHub Actions desde el código oficial (bionic arm64 para Android, musl verificado para amd64) y se publica con digest y attestation en un repo de distribución dedicado.
- **Auditable** — `verify.sh` audita la instalación en 10 pasos y detecta adulteración posterior al chequeo de hashes registrados en `manifest.txt`.

## Herramientas soportadas

| Herramienta | Distribución | Verificación de integridad | Notas |
|---|---|---|---|
| **`opencode`** | [GitHub Releases](https://github.com/anomalyco/opencode) | SHA256 del asset vía GitHub API + [Attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations) (Sigstore) | Invocación directa vía loader glibc (`NEEDS_PATCHELF=false`) |
| **`agy`** (Antigravity CLI) | [endpoint de actualización de Google](https://antigravity.google) (Cloud Run, manifest JSON) | SHA512 dinámico del manifest | Parche adaptativo VA39 + `faccessat2`, shim `libc.so`, DNS cgo |
| **`kiro-cli`** (Kiro CLI) | [CDN de Amazon](https://prod.download.cli.kiro.dev) | SHA256 del `manifest.json` oficial | TUI vía runtime bun parcheado; `EXTRA_BINS` |
| **`codex`** (OpenAI Codex) | [Repo de distribución](https://github.com/Eybad/ai-cli-termux-dist) — **build propio en CI** desde el código oficial (Apache-2.0) | SHA256 del asset vía GitHub API + attestation SLSA del workflow | Binario nativo bionic (arm64, sin proot) o musl verificado (amd64); `EXEC_DIRECT` |
| **`cursor-agent`** (Cursor Agent CLI) | [CDN propio](https://downloads.cursor.com/lab/...) (`url_template`, sin endpoint "latest" público) | SHA256 del tarball pineado a mano en `sha256.txt` | Bundle node embebido patcheado, alias `agent`, `agent update` bloqueado |

## Requisitos

- **Dispositivo**: Android 10+ (`aarch64`) o host Linux (`x86_64`).
- **Termux**: instalado desde **F-Droid** o **GitHub Releases** (la versión de Google Play está obsoleta).
- **Paquetes base**:

  ```bash
  pkg install git python ca-certificates -y
  ```

- **Almacenamiento**: ~400 MB por herramienta (kiro-cli: ~1 GB; codex: ~1.3 GB, binario sin strip).
- **gh** (opcional): para verificar la attestation SLSA de los releases de codex (`verify.sh` emite un WARN si no está instalado; el resto de la verificación no lo requiere).

## Instalación

```bash
git clone https://github.com/Eybad/ai-cli-termux.git
cd ai-cli-termux
bash aicli self-install   # instala el gestor en $PREFIX/bin
```

Desde cualquier directorio:

```bash
aicli install opencode    # instala la última versión verificada
aicli list                # estado local + actualizaciones disponibles
```

## Gestor aicli

`aicli` es la fachada recomendada sobre `install.sh`/`verify.sh`: gestiona los CLIs sin reemplazar sus comandos propios (cada CLI se usa con su propia ayuda: `opencode --help`, `codex exec`, ...).

| Subcomando | Descripción |
|---|---|
| `aicli list [--offline] [--json] [<tool>]` | Estado local (manifest) + actualización disponible. UPDATE: `sí`/`no`/`n/d`. Exit 0 siempre (informativo) |
| `aicli install <tool> [-v X.Y.Z \| --sha256 <hash> \| --require-attestation]` | Instalar (passthrough de flags a `install.sh`) |
| `aicli update <tool>` (`upgrade`) | Actualizar a la última versión (`install.sh <tool> --update`) |
| `aicli remove <tool>` (`uninstall`) | Desinstalar (`install.sh <tool> -u`) |
| `aicli verify <tool>` | Auditar integridad (10 pasos, `verify.sh`) |
| `aicli help [<subcomando>\|<tool>]` | Ayuda general, de un subcomando o de una herramienta (`aicli help codex`) |
| `aicli doctor` | Diagnóstico del entorno (repo, arch, deps, wrapper, loader glibc) |
| `aicli completion <bash\|zsh\|fish>` | Completions a stdout (tools del registry dinámicos) |
| `aicli self-install` / `self-update` | Instalar / actualizar el wrapper propio (fail-closed: nunca pisa un binario ajeno) |

Convenciones: `--help`/`--version` a stdout con exit 0, errores a stderr, exit `2` = uso inválido, `NO_COLOR`/`TERM=dumb`/no-TTY/`--no-color` desactivan colores.

> [!NOTE]
> `install.sh` y `verify.sh` siguen funcionando directo; los comandos del gestor son equivalentes (`aicli update <tool>` = `bash install.sh <tool> --update`).

### Instalación por herramienta

```bash
aicli install agy         # última versión (manifest oficial de Google)
aicli install kiro-cli    # última versión (manifest del CDN de Amazon)
aicli install codex -v 0.146.0+android1   # ejemplo: release con el parche de locks Android
aicli install cursor-agent -v 2026.07.23-e383d2b  # ejemplo: versión pineada (ver sha256.txt)
```

**opencode** — digest SHA256 verificado contra la GitHub API (el pin de `sha256.txt` gana si existe).

**agy** — el hook de instalación aplica el parche adaptativo (VA39 + `faccessat2`, ver [Soluciones técnicas de Android](#soluciones-técnicas-de-android)) y ejecuta un smoke test (`--version`) post-parche: si algo no se puede resolver, la instalación aborta y se restaura la versión anterior.

**kiro-cli** — el TUI delega el render en un runtime bun que el cliente descarga a `~/.local/share/kiro-cli/`; el build descargado es glibc y no corre en Termux. Ver [TUI en Termux: fix del runtime bun](#tui-en-termux-fix-del-runtime-bun).

**codex** — por qué no se instala el binario oficial de OpenAI: los assets Linux oficiales son **musl estáticos**, que en Android no resuelven DNS (leen `/etc/resolv.conf` de la raíz del sistema, inexistente sin proot) — el login y la API fallan. El workflow [build-codex.yml](.github/workflows/build-codex.yml) compila el CLI en CI desde el código oficial (`openai/codex`, Apache-2.0) para **bionic nativo** (`aarch64-linux-android`, NDK API 29): DNS (netd) y TLS (rustls/webpki) funcionan sin proot. En `amd64` (host Linux) se re-empaqueta el asset oficial musl con su digest SHA256 verificado contra la API upstream (fail-closed).

- **Parches de build**: (1) **locks Android**: desde Rust 1.89, `File::lock*` devuelve `Unsupported` en Android (rust-lang/rust#148325) y el TUI/exec de codex fallan. El build de arm64 aplica un parche generado ([`gen-codex-lock-patch.py`](scripts/gen-codex-lock-patch.py) → módulo `file_lock_shim` con `flock(2)`). (2) **símbolos glibc del prebuilt de V8**: bionic no provee `__xstat`/`__fxstat`/`__lxstat`/`bcmp`/`__ctype_*_loc` y el shim `bionic_compat` los define (con las tablas ctype glibc reales, generadas por [`gen-ctype-tables.py`](scripts/gen-ctype-tables.py); las tablas de ceros del shim original hacían crashear el code tool). (3) **prebuilt de V8 con sandbox**: el graph del host activa las features `v8_enable_pointer_compression` + `v8_enable_sandbox` del crate v8 (que denoland no publica); el CI usa el par prebuilt+binding `ptrcomp_sandbox` que OpenAI publica en su release `rusty-v8-v150.4.0` (mismo v8 150.4.0, digest verificado contra la API). (4) **shims de `mprotect` y `madvise` no expansivos**: el sandbox de V8 de openai emite `mprotect()` + `madvise(MADV_DONTNEED)` sobre rangos cuyo final no está alineado a página (los últimos ~20 bytes de su región). El kernel de escritorio tolera el addr no alineado, pero Android devuelve `EINVAL` — y la alineación expansiva (floor→ceil) de un shim convierte esas llamadas en revocación de la página entera: `PROT_NONE`/`MADV_DONTNEED` sobre una página con datos vivos de V8 → `SIGSEGV` (`0x…f02a`, `code-mode host closed its stdout`) al abrir o leer archivos con el code tool. El fix: las operaciones **destructivas** (`PROT_NONE`, `MADV_DONTNEED`, `MADV_FREE`) se aplican solo a páginas **completamente contenidas** en el rango pedido (`ceil(addr)`..`floor(addr+len)`); un rango fraccional es un no-op con retorno 0 (el CHECK de V8 solo reintenta ante `ENOMEM`, así que el éxito es correcto). Las llamadas **aditivas** (`PROT_READ|PROT_WRITE|PROT_EXEC`) mantienen la alineación expansiva (inocua). El CI verifica con `readelf -sW` que los símbolos quedaron definidos en el host (fail-closed, con `used+retain` para sobrevivir a gc-sections del lld del NDK). El release lleva build metadata semver: `vX.Y.Z+androidN` (`+android2` fix de locks, `+android3` shim mprotect, `+android4` shim madvise, `+android5` shims no expansivos — SIGSEGV del code tool resuelto). El instalador preserva el `+build` en versión y tag, y `--update` migra automáticamente entre releases. `codex update` está bloqueado en el wrapper (todo pasa por `aicli update codex`).
- **Code mode host (0.147+)**: el code tool (V8) corre en un binario separado, `codex-code-mode-host`, que viaja junto al ejecutable en el bundle (arm64 compilado en CI; amd64 re-empaquetado del asset oficial musl con digest verificado). Sin él, el code tool falla fail-closed (`host executable was not found`); el resto del CLI no lo usa.
- **Escalable**: el CI detecta cada release nuevo de OpenAI (cron diario) y publica el asset en el [repo de distribución](https://github.com/Eybad/ai-cli-termux-dist) con digest y attestation. Si un release upstream rompe el build bionic, no se publica y la última versión buena sigue instalable.
- **Ripgrep**: si codex reporta la falta de `rg`, instalalo con `pkg install ripgrep` (se busca por PATH).

> [!IMPORTANT]
> El sandbox de codex usa `landlock` por defecto; en kernels Android que no lo soporten (`zgrep LANDLOCK /proc/config.gz`), configurá `sandbox_mode = "off"` en `~/.codex/config.toml`. Desactivarlo elimina el aislamiento de los comandos que el agente ejecuta sobre tus archivos: aplicálo solo si el kernel realmente no lo soporta.

**cursor-agent** — Cursor distribuye un tarball con un runtime **node embebido** (ELF glibc de 125 MB, no-PIE) que se patchea al overlay (`ELF_NAME="node"`) y se lanza vía el launcher bash del bundle (`ENTRY_POINT="cursor-agent"`). El instalador oficial expone el comando como `agent`; se replica con `ALIASES` (symlink gestionado).

- **Sin checksums del vendor**: Cursor no publica checksums ni manifest, y la versión va hardcodeada en el script de [cursor.com/install](https://cursor.com/install). El pin se mantiene a mano en `sha256.txt` (ver el comentario del archivo): detectar la versión nueva, descargar el tarball (`https://downloads.cursor.com/lab/<version>/linux/arm64/agent-cli-package.tar.gz`), `sha256sum`, actualizar la entrada y `aicli update cursor-agent`. El CDN tuvo incidentes de 403 históricos (artifacts no publicados): el pin evita instalar versiones rotas. Nota: el primer hash es *trust-on-first-use* — asume confianza en `downloads.cursor.com` (protege contra cambios posteriores, no contra un CDN envenenado).
- **`agent update` bloqueado** (`WRAPPER_DENY_ARGS`): el updater interno descargaría versiones sin verificación de checksum; las actualizaciones pasan siempre por `aicli update cursor-agent` (fail-closed). El deny es *policy* del wrapper, no una frontera — ejecutar el launcher del bundle directo (`libexec/cursor-agent/cursor-agent update`) la esquiva.
- **Login**: requiere cuenta de cursor.com (`agent login` abre el navegador vía `termux-open-url`, redirigido por los shims).

#### TUI en Termux: fix del runtime bun

El TUI de `kiro-cli` (sin argumentos) delega el render en un runtime [bun](https://bun.sh) que el cliente descarga a `~/.local/share/kiro-cli/` (`bun` + `tui.js`). El build que descarga es glibc y no puede ejecutarse en Termux (interpreter del sistema inexistente): el TUI muestra `Launching...` y falla con `error: No such file or directory (os error 2)`.

Fix (una sola vez; repetir si el cliente re-descarga el build glibc):

1. Ejecutar `timeout 5 kiro-cli` una vez para que el cliente descargue `bun` + `tui.js` y registre `bun.sha256` (hash esperado por el launcher; sin él re-descarga el build glibc en cada arranque).
2. Reemplazar el runtime por la build Android oficial de bun (bionic PIE, corre nativa en Termux):

```bash
curl -fsSL -o /tmp/bun-android.zip \
  https://github.com/oven-sh/bun/releases/download/bun-v1.3.14/bun-linux-aarch64-android.zip
# Fail-closed: digest del asset publicado por la GitHub API para bun-v1.3.14.
if echo "992bcf239c91bedd873f8150cceef3db3b0618fa78161badd3c14dc6d24fe560  /tmp/bun-android.zip" \
    | sha256sum -c - >/dev/null 2>&1; then
  unzip -o /tmp/bun-android.zip -d /tmp/bun-android
  cp /tmp/bun-android/bun-linux-aarch64-android/bun ~/.local/share/kiro-cli/bun
  chmod 755 ~/.local/share/kiro-cli/bun
  echo "OK: runtime bun Android instalado (digest verificado)"
else
  echo "ERROR: checksum del zip no coincide. Borrá /tmp/bun-android.zip y repetí."
fi
```

> [!NOTE]
> El digest corresponde a `bun-v1.3.14` (la build Android más cercana a la v1.3.13 que espera el launcher). Si en el futuro el fix se aplica a otra versión, verificá el digest del asset en la GitHub API antes de pegar el bloque.

`bun.sha256` no se toca: el launcher compara ese archivo contra el hash del build glibc v1.3.13 que espera, y solo re-descarga si difieren; el binario en sí no se valida. Por eso el binario queda en v1.3.14 (la build Android más cercana; las builds Android de bun existen desde v1.3.14, no hay build Android de v1.3.13) con el sha file de v1.3.13.

## Opciones comunes

| Opción | Descripción |
|---|---|
| `-v, --version <X.Y.Z>` | Instalar una versión específica |
| `--update` | Actualizar a la última versión disponible si ya hay una anterior |
| `-r, --reinstall` | Forzar reinstalación |
| `-u, --uninstall` | Desinstalar por completo |
| `--sha256 <hash>` | Pinear el checksum del tarball explícitamente |
| `--require-attestation` | Abortar si no se puede verificar la attestation (solo tools de GitHub) |
| `-h, --help` | Mostrar la ayuda completa |

> [!IMPORTANT]
> `--sha256 <hash>` desactiva la resolución automática de checksum: el hash se toma tal cual lo pasás. Verificá vos mismo que sea el correcto antes de instalarlo.

## Actualización automática

Cada instalación registra un `manifest.txt` con la versión y los hashes del binario. Para actualizar una herramienta:

```bash
aicli update <tool>
```

- **opencode**: última release de GitHub; digest SHA256 verificado contra la GitHub API (el pin de `sha256.txt` gana si existe).
- **agy**: última versión del manifest de Google, con re-aplicación del parche adaptativo.
- **kiro-cli**: última versión del `manifest.json` del CDN de Amazon.
- **codex**: última versión publicada por el build propio de CI en el repo de distribución ([`build-codex.yml`](.github/workflows/build-codex.yml)); digest + attestation del workflow (emitida por el repo del proyecto).
- **cursor-agent**: última versión registrada en `sha256.txt` (pin manual; el vendor no publica endpoint "latest" — ver [Instalación por herramienta](#instalación-por-herramienta)). Detecta versiones con prerelease/build (ej: `2026.07.23-e383d2b`).

> [!NOTE]
> Para la mayoría de las herramientas no hace falta tocar `sha256.txt`: la versión y el checksum se resuelven automáticamente y fail-closed desde la fuente del vendor (el archivo queda como capa opcional de pinning). **Excepción: `cursor-agent`** — su pin en `sha256.txt` es la única fuente de versiones (CDN sin manifest), y `--update` toma de ahí la última registrada.

El workflow CI [update-hashes.yml](.github/workflows/update-hashes.yml) actualiza `sha256.txt` automáticamente para las tools con `RELEASE_SOURCE=github`.

## Verificación

```bash
aicli verify <tool>    # ej: aicli verify agy
```

Audita la instalación en 10 pasos: manifest local, binario presente y ejecutable (formato ELF correcto), interpreter/rpath de `patchelf`, integridad post-modificación contra `manifest.txt`, consistencia con `sha256.txt`, estado de la attestation, wrapper (limpia `LD_PRELOAD`/`LD_LIBRARY_PATH`), entorno glibc (loader, `nsswitch.conf`, DNS), ejecución real (`--version`) y resumen final. **Exit code 1 ante cualquier fallo.**

## Cómo funciona

```
Android (kernel aarch64 + seccomp)
  └─ Termux (bionic libc)
       └─ Overlay glibc ($PREFIX/glibc/lib/ld-linux-aarch64.so.1)
            ├─ 1. patchelf          → interpreter y rpath apuntan a glibc
            ├─ 2. pre_wrapper_hook  → parches de kernel, shims, DNS
            └─ 3. wrapper           → SSL_CERT_FILE, GODEBUG, LD_LIBRARY_PATH
                 └─ binario ejecutado de forma nativa (sin VM, sin emulación)
```

Los parches puntuales que resuelven cada incompatibilidad de Android están detallados en [Soluciones técnicas de Android](#soluciones-técnicas-de-android).

## Soluciones técnicas de Android

### 1. Parche de kernel VA39 + syscall `faccessat2` (agy)

Los binarios de Google se compilan para Linux servidor y traen dos incompatibilidades con Android:

- La política seccomp bloquea `faccessat2` (syscall 439, usada por Go en `os/exec.LookPath`) → `SIGSYS` garantizado en **todas** las versiones (probado en 1.1.8 y 1.1.9).
- Algunas versiones (ej. 1.1.8) usan TCMalloc compilado para **VA48**; Android expone solo 39 bits → crash `MmapAligned() failed` (corregido por Google desde 1.1.9).

> [!IMPORTANT]
> `ai-cli-termux` integra un script auditable de hex-patching local (`registry/patch_va39.py`), ejecutado automáticamente durante el `pre_wrapper_hook`:
> - **Fase A (siempre)**: reescribe `faccessat2` (nr 439) → `faccessat` (nr 48) en todos los sitios del binario.
> - **Fase B (adaptativa)**: solo si el binario muestra firmas fuertes de TCMalloc VA48 (tags `2<<42`, máscara random de mmap), reescribe las instrucciones ARM64 (bit 42→35) y el límite de `MmapAligned` (`1<<48`→`1<<39`), limitado a segmentos ejecutables para no corromper datos.
> - **Fail-closed**: si hay firmas de problemas que el parche no puede resolver, la instalación aborta y se restaura la versión anterior. Resultado: `--update` funciona automáticamente entre versiones de agy, sin mantenimiento manual.

Análisis técnico original: [google-antigravity/antigravity-cli#64](https://github.com/google-antigravity/antigravity-cli/issues/64).

### 2. Resolución DNS y TLS en binarios Go

Android no tiene `/etc/resolv.conf` en la raíz. El hook genera `$GLIBC_PREFIX/etc/resolv.conf` con los servidores DNS activos de Android (`getprop net.dns1`/`net.dns2`, fallback a `8.8.8.8`/`1.1.1.1`) y el wrapper fuerza `GODEBUG=netdns=cgo` (resolución vía glibc) y exporta `SSL_CERT_FILE` al almacén de certificados de Termux.

### 3. Shim para el linker script `libc.so` de glibc Termux

En la glibc de Termux, `/usr/glibc/lib/libc.so` es un script ASCII del linker, no un ELF: cualquier binario que lo cargue dinámicamente falla con `invalid ELF header`. El hook crea un directorio de shim con symlinks al ELF real y lo inyecta en el `LD_LIBRARY_PATH` del wrapper.

### 4. Intercepción de navegador y portapapeles (`xdg-open` / `xclip`)

`glibc-runner` crashea silenciosamente si un proceso invoca un binario inexistente como `xdg-open` o `xclip` (usados por las CLIs para abrir URLs y copiar texto). Se instalan wrappers ligeros que redirigen a `termux-open-url` y `termux-clipboard-set`.

## Integridad (doble capa de hashes)

Como `patchelf` y `patch_va39.py` modifican el binario durante la instalación, el sistema registra dos checksums:

1. **Tarball**: verificado al descargar (digest del vendor, pin de `sha256.txt` o `--sha256`) — sin hash verificado no se instala.
2. **Binario instalado**: hash recalculado tras los parches y guardado en `manifest.txt`; `verify.sh` lo compara en cada auditoría para detectar adulteración posterior.

## Agregar una CLI nueva

1. Crear `registry/<tool>.conf` con los campos obligatorios: `APP_NAME`, `DISPLAY_NAME`, `RELEASE_SOURCE`, `CHECKSUM_ALGO`, `CHECKSUM_SOURCE`, `ELF_NAME`.
2. Si `CHECKSUM_SOURCE=hashfile`, agregar la entrada correspondiente en `sha256.txt`.
3. Si la CLI delega el TUI a binarios compañeros del mismo bundle (ej: `kiro-cli` → `kiro-cli-chat`), listarlos en `EXTRA_BINS`: se patchean igual que el binario principal y reciben wrapper propio en `$PREFIX/bin`.
4. Si la CLI necesita entorno o parches, implementar `pre_wrapper_hook` o `post_install_hook` (ver `registry/agy.conf`).
5. Usar `registry/opencode.conf`, `registry/agy.conf` y `registry/kiro-cli.conf` como ejemplos canónicos.

| `RELEASE_SOURCE` | Requiere | Checksum |
|---|---|---|
| `github` | `REPO`, `ARCHIVE_TEMPLATE` | `release_digest` (SHA256 del asset vía GitHub API) o `hashfile` |
| `manifest_json` | `MANIFEST_URL`, `MANIFEST_KEY_*` | `manifest` (agy: Google; kiro-cli: Amazon) |
| `url_template` | `DOWNLOAD_URL_TEMPLATE` | `hashfile` (disponible para CDNs sin manifest) |

| `CHECKSUM_SOURCE` | Descripción | Fail-closed |
|---|---|---|
| `release_digest` | SHA256 del asset publicado por GitHub | Sí |
| `manifest` | SHA256/SHA512 del manifest JSON del vendor | Sí |
| `hashfile` | Hash pineado en `sha256.txt` (independiente del vendor) | Sí |
| `--sha256 <hash>` | Pin explícito por línea de comandos | Sí |

> [!NOTE]
> El detalle fino — arch mapping (`aarch64`→`arm64`, `x86_64`→`amd64`), formato de `sha256.txt`, pipeline completo de instalación y las invariants del proyecto — está documentado en [AGENTS.md](AGENTS.md).

## Estructura del repositorio

```
ai-cli-termux/
├── aicli                        # Gestor (fachada sobre install.sh/verify.sh)
├── install.sh                   # Instalador genérico (fail-closed)
├── verify.sh                    # Verificador post-instalación (10 pasos)
├── sha256.txt                   # Pinning opcional de hashes
├── AGENTS.md                    # Invariants y convenciones para contribuir
├── registry/                    # Configuración por herramienta
│   ├── opencode.conf
│   ├── agy.conf
│   ├── kiro-cli.conf
│   ├── codex.conf
│   ├── cursor-agent.conf
│   └── patch_va39.py            # Parche adaptativo ARM64 (VA39 + faccessat2)
├── scripts/
│   ├── gen-codex-lock-patch.py  # Generador fail-closed del parche de locks (CI)
│   └── gen-ctype-tables.py      # Tablas ctype glibc para el shim de V8 (CI)
├── docs/
│   └── adr/0001-release-scheme.md
└── .github/workflows/
    ├── build-codex.yml          # Build bionic arm64 + musl verificado (cron diario)
    └── update-hashes.yml        # Actualiza sha256.txt (CI)
```
