<div align="center">

# ai-cli-termux

**CLIs de IA ejecutadas de forma nativa en Termux, sin proot**

[![CI](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/ci.yml?style=flat-square&label=ci)](https://github.com/Eybad/ai-cli-termux/actions)
[![Build codex](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/build-codex.yml?style=flat-square&label=build-codex)](https://github.com/Eybad/ai-cli-termux/actions)
[![Android](https://img.shields.io/badge/Android-10%2B-3ddc84?style=flat-square&logo=android&logoColor=white)](https://www.android.com/)
[![Termux](https://img.shields.io/badge/Termux-F--Droid-000000?style=flat-square&logo=terminal)](https://f-droid.org/en/packages/com.termux/)

[Features](#features) • [Herramientas soportadas](#herramientas-soportadas) • [Requisitos](#requisitos) • [Instalación](#instalación) • [Gestor aicli](#gestor-aicli) • [Opciones](#opciones) • [Actualización automática](#actualización-automática) • [Verificación](#verificación) • [Cómo funciona](#cómo-funciona) • [Soluciones técnicas de Android](#soluciones-técnicas-de-android) • [Agregar una CLI nueva](#agregar-una-cli-nueva) • [Estructura del repositorio](#estructura-del-repositorio)

</div>

Instala y audita CLIs de inteligencia artificial — [opencode](https://github.com/anomalyco/opencode), [Antigravity CLI](https://antigravity.google) y [OpenAI Codex](https://github.com/openai/codex) — directamente en **Termux** para Android (`aarch64`) y Linux (`x86_64`). Los binarios ELF glibc corren **nativos sobre el kernel de Android** vía el overlay de librerías glibc del ecosistema Termux: sin `proot`, sin máquinas virtuales, con rendimiento 1:1.

> [!TIP]
> Agregar una herramienta nueva solo requiere crear un archivo `registry/<tool>.conf`. El instalador es genérico y no se toca.

## Features

- **Gestor `aicli`** — fachada de línea de comandos: `list` (estado + actualizaciones), `install`/`update`/`remove`, `verify`, `doctor`, completions y auto-instalación del propio gestor.
- **Nativo, sin proot** — binarios ELF glibc ejecutados vía el loader de Termux (`ld-linux-aarch64.so.1`), con `patchelf` y wrappers que resuelven las diferencias con Android (seccomp, DNS, certificados).
- **Framework modular** — cada CLI vive en un `registry/*.conf`: variables, entorno, parches y hooks. Todo lo específico de una herramienta está en su registro.
- **Última versión automática** — versión y checksum se resuelven solos desde la GitHub API o el manifest de Google.
- **Fail-closed** — sin checksum verificado no se instala. `sha256.txt` es la fuente obligatoria para tools `hashfile` (CDN sin manifest) y pinning opcional para el resto.
- **Binario nativo** — agy usa el build Android oficial de Google (bionic, `EXEC_DIRECT`): instalación directa sin parches ni mantenimiento manual entre versiones.
- **Build en CI** — codex se compila en GitHub Actions desde el código oficial (bionic arm64 para Android, musl verificado para amd64) y se publica con digest y attestation en un repo de distribución dedicado.
- **Auditable** — `verify.sh` audita la instalación en 10 pasos y detecta adulteración posterior al chequeo de hashes registrados en `manifest.txt`.

## Herramientas soportadas

| Herramienta | Distribución | Verificación de integridad | Notas |
|---|---|---|---|
| **`opencode`** | [GitHub Releases](https://github.com/anomalyco/opencode) | SHA256 del asset vía GitHub API | Invocación vía runner glibc (`opencode-runner.sh`), rutas XDG estándar (`NEEDS_PATCHELF=false`) |
| **`agy`** (Antigravity CLI) | [endpoint de actualización de Google](https://antigravity.google) (Cloud Run, manifest JSON) | SHA512 dinámico del manifest | Binario nativo bionic en Android (manifest `android_arm64`, `EXEC_DIRECT`) |
| **`codex`** (OpenAI Codex) | [Repo de distribución](https://github.com/Eybad/ai-cli-termux-dist) — **build propio en CI** desde el código oficial (Apache-2.0) | SHA256 del asset vía GitHub API + attestation SLSA del workflow | Binario nativo bionic (arm64, sin proot) o musl verificado (amd64); `EXEC_DIRECT` |

## Requisitos

- **Dispositivo**: Android 10+ (`aarch64`) o host Linux (`x86_64`).
- **Termux**: desde **F-Droid** o **GitHub Releases**.
- **Paquetes base** — cubren el clon, el instalador y el TLS de las CLIs:

  ```bash
  pkg install git curl tar coreutils gawk jq ca-certificates -y
  ```

  - Opcionales: `gh` (attestation de codex), `bash-completion` (completions), `ripgrep` (code tool de codex).

- **Almacenamiento**: ~400 MB por herramienta (codex: ~1.3 GB).

> [!TIP]
> El overlay glibc (`glibc-repo` + `glibc-runner`) se instala automáticamente durante la primera instalación; `patchelf` también, cuando la herramienta lo requiere. No hay que instalarlos a mano.

## Instalación

```bash
git clone https://github.com/Eybad/ai-cli-termux.git
cd ai-cli-termux
bash aicli self-install   # deja aicli disponible desde cualquier directorio
```

Primeros pasos:

```bash
aicli list                    # 1) ver las herramientas disponibles y su estado
aicli install <herramienta>   # 2) instalar la última versión verificada (ej: opencode)
aicli verify <herramienta>    # 3) auditar la instalación (opcional)
```

`<herramienta>` es el nombre de la CLI (`<tool>` en la ayuda del gestor): opencode, agy, codex, ...

## Gestor aicli

`aicli` es la fachada recomendada sobre `install.sh`/`verify.sh`: gestiona los CLIs sin reemplazar sus comandos propios.

### Uso rápido

| Si querés… | Ejecutá |
|---|---|
| Instalar una CLI | `aicli install <tool>` |
| Actualizar una CLI | `aicli update <tool>` |
| Actualizar todas las instaladas | `aicli update --all` |
| Desinstalar una CLI | `aicli remove <tool>` |
| Verificar la integridad | `aicli verify <tool>` |
| Ver estado y actualizaciones | `aicli list` |
| Diagnosticar el entorno | `aicli doctor` |
| Ayuda | `aicli help [comando \| tool]` |

`<tool>` es el nombre de la CLI (opencode, agy, codex, ...).

### Subcomandos

| Comando | Qué hace |
|---|---|
| `aicli list [--offline] [--json] [<tool>]` | Estado local (versión del manifest) y actualización disponible (`sí`/`no`/`n/d`). Exit 0 siempre (informativo) |
| `aicli install <tool> [-v X.Y.Z \| --sha256 <hash> \| --require-attestation]` | Instalar (flags passthrough a `install.sh`) |
| `aicli update <tool>` | Actualizar a la última versión disponible |
| `aicli update --all` | Actualizar todas las instaladas (una falla no detiene al resto; exit 1 si hubo fallas) |
| `aicli remove <tool>` | Desinstalar por completo |
| `aicli verify <tool>` | Auditar la integridad (10 pasos; exit 1 ante cualquier fallo) |
| `aicli help [<subcomando> \| <tool>]` | Ayuda general, de un subcomando o de una CLI |
| `aicli doctor` | Diagnóstico del entorno (repo, arch, deps, wrapper, loader glibc) |
| `aicli completion <bash \| zsh \| fish>` | Completions a stdout (herramientas del registry dinámicas) |
| `aicli self-install` / `self-update` | Instalar / actualizar el wrapper propio (nunca pisa un binario ajeno) |

> [!NOTE]
> `--help`/`--version` a stdout con exit 0, errores a stderr, exit `2` = uso inválido, `NO_COLOR`/`TERM=dumb`/no-TTY/`--no-color` desactivan colores.

> [!NOTE]
> `install.sh` y `verify.sh` siguen funcionando directo; los subcomandos del gestor son equivalentes (`aicli update <tool>` = `bash install.sh <tool> --update`).

### Instalación por herramienta

```bash
aicli install opencode    # última versión estable (GitHub Releases)
aicli install agy         # última versión (manifest oficial de Google)
aicli install codex -v 0.146.0+android1   # ejemplo: release con el parche de locks Android
```

**opencode** — v2 estable; digest SHA256 verificado contra la GitHub API (el pin de `sha256.txt` gana si existe). Orquesta el servidor efímero glibc vía `opencode-runner.sh` y utiliza rutas XDG estándar.

**agy** — build Android oficial de Google (bionic nativo, `EXEC_DIRECT`): instalación directa sin parches; `verify_install` confirma `--version` y `verify.sh` audita el hash post-instalación.

**codex** — por qué no se instala el binario oficial de OpenAI: los assets Linux oficiales son **musl estáticos**, que en Android no resuelven DNS (leen `/etc/resolv.conf` de la raíz del sistema, inexistente sin proot) — el login y la API fallan. El workflow [build-codex.yml](.github/workflows/build-codex.yml) compila el CLI en CI desde el código oficial (`openai/codex`, Apache-2.0) para **bionic nativo** (`aarch64-linux-android`, NDK API 29): DNS (netd) y TLS (rustls/webpki) funcionan sin proot. En `amd64` (host Linux) se re-empaqueta el asset oficial musl con su digest SHA256 verificado contra la API upstream (fail-closed).

- **Parches de build**: (1) **locks Android**: desde Rust 1.89, `File::lock*` devuelve `Unsupported` en Android (rust-lang/rust#148325) y el TUI/exec de codex fallan. El build de arm64 aplica un parche generado ([`gen-codex-lock-patch.py`](scripts/gen-codex-lock-patch.py) → módulo `file_lock_shim` con `flock(2)`). (2) **símbolos glibc del prebuilt de V8**: bionic no provee `__xstat`/`__fxstat`/`__lxstat`/`bcmp`/`__ctype_*_loc` y el shim `bionic_compat` los define (con las tablas ctype glibc reales, generadas por [`gen-ctype-tables.py`](scripts/gen-ctype-tables.py); las tablas de ceros del shim original hacían crashear el code tool). (3) **prebuilt de V8 con sandbox**: el graph del host activa las features `v8_enable_pointer_compression` + `v8_enable_sandbox` del crate v8 (que denoland no publica); el CI usa el par prebuilt+binding `ptrcomp_sandbox` que OpenAI publica en su release `rusty-v8-v<VER>` (mismo v8, digest verificado contra la API). La versión se deriva del crate `v8` del `Cargo.lock` upstream (sin pin manual; si el release no existe, el digest falla fail-closed). (4) **shims de `mprotect` y `madvise` no expansivos**: el sandbox de V8 de openai emite `mprotect()` + `madvise(MADV_DONTNEED)` sobre rangos cuyo final no está alineado a página (los últimos ~20 bytes de su región). El kernel de escritorio tolera el addr no alineado, pero Android devuelve `EINVAL` — y la alineación expansiva (floor→ceil) de un shim convierte esas llamadas en revocación de la página entera: `PROT_NONE`/`MADV_DONTNEED` sobre una página con datos vivos de V8 → `SIGSEGV` (`0x…f02a`, `code-mode host closed its stdout`) al abrir o leer archivos con el code tool. El fix: las operaciones **destructivas** (`PROT_NONE`, `MADV_DONTNEED`, `MADV_FREE`) se aplican solo a páginas **completamente contenidas** en el rango pedido (`ceil(addr)`..`floor(addr+len)`); un rango fraccional es un no-op con retorno 0 (el CHECK de V8 solo reintenta ante `ENOMEM`, así que el éxito es correcto). Las llamadas **aditivas** (`PROT_READ|PROT_WRITE|PROT_EXEC`) mantienen la alineación expansiva (inocua). El CI verifica con `readelf -sW` que los símbolos quedaron definidos en el host (fail-closed, con `used+retain` para sobrevivir a gc-sections del lld del NDK). El release lleva build metadata semver: `vX.Y.Z+androidN` (`+android2` fix de locks, `+android3` shim mprotect, `+android4` shim madvise, `+android5` shims no expansivos — SIGSEGV del code tool resuelto). El instalador preserva el `+build` en versión y tag, y `--update` migra automáticamente entre releases. `codex update` está bloqueado en el wrapper (todo pasa por `aicli update codex`).
- **Code mode host (0.147+)**: el code tool (V8) corre en un binario separado, `codex-code-mode-host`, que viaja junto al ejecutable en el bundle (arm64 compilado en CI; amd64 re-empaquetado del asset oficial musl con digest verificado). Sin él, el code tool falla fail-closed (`host executable was not found`); el resto del CLI no lo usa.
- **Escalable**: el CI detecta cada release nuevo de OpenAI (cron diario) y publica el asset en el [repo de distribución](https://github.com/Eybad/ai-cli-termux-dist) con digest y attestation. Si un release upstream rompe el build bionic, no se publica y la última versión buena sigue instalable.
- **Ripgrep**: si codex reporta la falta de `rg`, instalalo con `pkg install ripgrep` (se busca por PATH).

> [!IMPORTANT]
> El sandbox de codex usa `landlock` por defecto; en kernels Android que no lo soporten (`zgrep LANDLOCK /proc/config.gz`), configurá `sandbox_mode = "off"` en `~/.codex/config.toml`. Desactivarlo elimina el aislamiento de los comandos que el agente ejecuta sobre tus archivos: aplicálo solo si el kernel realmente no lo soporta.

## Opciones

### Instalación (passthrough a `install.sh`)

| Opción | Descripción |
|---|---|
| `-v, --version <X.Y.Z>` | Instalar una versión específica |
| `--sha256 <hash>` | Pinear el checksum del tarball explícitamente |
| `--require-attestation` | Abortar si no se puede verificar la attestation (solo tools de GitHub) |

> [!IMPORTANT]
> `--sha256 <hash>` desactiva la resolución automática de checksum: el hash se toma tal cual lo pasás. Verificá vos mismo que sea el correcto antes de instalarlo.

### Instalador directo (`install.sh`)

| Opción | Descripción |
|---|---|
| `--update` | Actualizar a la última versión disponible |
| `-r, --reinstall` | Forzar reinstalación |
| `-u, --uninstall` | Desinstalar por completo |
| `-h, --help` | Mostrar la ayuda completa |

El gestor los expone como subcomandos: `aicli update <tool>` y `aicli remove <tool>`.

### Globales de `aicli`

| Opción | Descripción |
|---|---|
| `-h, --help` | Ayuda |
| `--version` | Versión del gestor |
| `--no-color` | Desactivar colores |
| `--offline`, `--json` | De `aicli list`: sin red / salida máquina |

## Actualización automática

Cada instalación registra un `manifest.txt` con la versión y los hashes del binario. Para actualizar una herramienta:

```bash
aicli update <tool>
```

- **opencode**: última release v2 estable de GitHub; digest SHA256 verificado contra la GitHub API (el pin de `sha256.txt` gana si existe).
- **agy**: última versión del manifest de Google, con re-aplicación del parche adaptativo.
- **codex**: última versión publicada por el build propio de CI en el repo de distribución ([`build-codex.yml`](.github/workflows/build-codex.yml)); digest + attestation del workflow (emitida por el repo del proyecto).

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

### 1. Build nativo Android (agy)

Google publica un build específico para Android (`cli_android_arm64.tar.gz`, ELF bionic con interpreter `/system/bin/linker64`), distinto del build Linux servidor. `registry/agy.conf` lo consume vía `MANIFEST_URL_AARCH64` con `EXEC_DIRECT=true`: ejecución directa sin overlay glibc, sin `patchelf`, sin parches binarios y sin `python3`. En `x86_64` (host Linux) se usa el manifest linux como fallback. El ruteo por arquitectura es genérico en `install.sh` (cualquier tool con manifests por OS puede reusarlo).

> [!NOTE]
> Hasta la versión 1.2.x agy se instalaba desde el build Linux con un hex-patch adaptativo local (`faccessat2`→`faccessat` + TCMalloc VA48→VA39). El build oficial Android lo volvió innecesario y el parche se eliminó. Detalle histórico: [google-antigravity/antigravity-cli#64](https://github.com/google-antigravity/antigravity-cli/issues/64).

### 2. Resolución DNS y TLS en binarios Go

Android no tiene `/etc/resolv.conf` en la raíz. El hook genera `$GLIBC_PREFIX/etc/resolv.conf` con los servidores DNS activos de Android (`getprop net.dns1`/`net.dns2`, fallback a `8.8.8.8`/`1.1.1.1`) y el wrapper fuerza `GODEBUG=netdns=cgo` (resolución vía glibc) y exporta `SSL_CERT_FILE` al almacén de certificados de Termux.

### 3. Shim para el linker script `libc.so` de glibc Termux

En la glibc de Termux, `/usr/glibc/lib/libc.so` es un script ASCII del linker, no un ELF: cualquier binario que lo cargue dinámicamente falla con `invalid ELF header`. El hook crea un directorio de shim con symlinks al ELF real y lo inyecta en el `LD_LIBRARY_PATH` del wrapper.

### 4. Intercepción de navegador y portapapeles (`xdg-open` / `xclip`)

`glibc-runner` crashea silenciosamente si un proceso invoca un binario inexistente como `xdg-open` o `xclip` (usados por las CLIs para abrir URLs y copiar texto). Se instalan wrappers ligeros que redirigen a `termux-open-url` y `termux-clipboard-set`.

## Integridad (doble capa de hashes)

Como `patchelf` modifica el binario durante la instalación, el sistema registra dos checksums:

1. **Tarball**: verificado al descargar (digest del vendor, pin de `sha256.txt` o `--sha256`) — sin hash verificado no se instala.
2. **Binario instalado**: hash recalculado tras los parches y guardado en `manifest.txt`; `verify.sh` lo compara en cada auditoría para detectar adulteración posterior.

## Agregar una CLI nueva

1. Crear `registry/<tool>.conf` con los campos obligatorios: `APP_NAME`, `DISPLAY_NAME`, `RELEASE_SOURCE`, `CHECKSUM_ALGO`, `CHECKSUM_SOURCE`, `ELF_NAME`.
2. Si `CHECKSUM_SOURCE=hashfile`, agregar la entrada correspondiente en `sha256.txt`.
3. Si la CLI delega el TUI a binarios compañeros del mismo bundle, listarlos en `EXTRA_BINS`: se patchean igual que el binario principal y reciben wrapper propio en `$PREFIX/bin`.
4. Si la CLI necesita entorno o parches, implementar `pre_wrapper_hook` o `post_install_hook` (ver `registry/codex.conf`).
5. Usar `registry/opencode.conf` y `registry/agy.conf` como ejemplos canónicos.

| `RELEASE_SOURCE` | Requiere | Checksum |
|---|---|---|
| `github` | `REPO`, `ARCHIVE_TEMPLATE` | `release_digest` (SHA256 del asset vía GitHub API) o `hashfile` |
| `manifest_json` | `MANIFEST_URL`, `MANIFEST_KEY_*` (+ `MANIFEST_URL_AARCH64`/`_X86_64` opcionales por OS) | `manifest` (agy: Google) |
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
│   ├── codex.conf
│   ├── lib/opencode-runner.sh   # Runner de servidor efímero glibc para OpenCode v2
│   ├── lib/shims.sh             # Helpers compartidos de hooks (shims, etc.)
├── scripts/
│   ├── gen-codex-lock-patch.py  # Generador fail-closed del parche de locks (CI)
│   ├── test-gen-codex-lock-patch.py  # Tests del generador (fixtures sintéticos, CI)
│   └── gen-ctype-tables.py      # Tablas ctype glibc para el shim de V8 (CI)
├── docs/
│   └── adr/0001-release-scheme.md
└── .github/
    ├── dependabot.yml           # Actualización semanal de actions (pins por SHA)
    └── workflows/
        ├── build-codex.yml      # Build bionic arm64 + musl verificado (cron diario)
        └── ci.yml               # Lint + validación de confs (push/PR)
```

## Seguridad

¿Encontraste una vulnerabilidad en el instalador, los registros o los workflows? Consultá [SECURITY.md](SECURITY.md) para el canal de reporte privado y el modelo de confianza de la cadena (checksums fail-closed, attestation).
