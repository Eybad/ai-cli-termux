<div align="center">

# ai-cli-termux

**CLIs de IA ejecutadas de forma nativa en Termux, sin proot**

[![Update hashes](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/update-hashes.yml?style=flat-square&label=update-hashes)](https://github.com/Eybad/ai-cli-termux/actions)
[![Build codex](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/build-codex.yml?style=flat-square&label=build-codex)](https://github.com/Eybad/ai-cli-termux/actions)
[![Android](https://img.shields.io/badge/Android-10%2B-3ddc84?style=flat-square&logo=android&logoColor=white)](https://www.android.com/)
[![Termux](https://img.shields.io/badge/Termux-F--Droid-000000?style=flat-square&logo=terminal)](https://f-droid.org/en/packages/com.termux/)

[Features](#features) • [Herramientas soportadas](#herramientas-soportadas) • [Requisitos](#requisitos) • [Instalación](#instalación) • [Actualización automática](#actualización-automática) • [Verificación](#verificación) • [Cómo funciona](#cómo-funciona) • [Soluciones técnicas de Android](#soluciones-técnicas-de-android) • [Agregar una CLI nueva](#agregar-una-cli-nueva) • [Estructura del repositorio](#estructura-del-repositorio)

</div>

`ai-cli-termux` instala y audita CLIs de inteligencia artificial ([opencode](https://github.com/anomalyco/opencode), [Antigravity CLI](https://antigravity.google), [Kiro CLI](https://kiro.dev) y [OpenAI Codex](https://github.com/openai/codex)) directamente en **Termux** para Android (`aarch64`) y Linux (`x86_64`), usando el overlay de librerías glibc del ecosistema Termux. Sin `proot`, sin máquinas virtuales: los binarios corren nativos sobre el kernel de Android, con rendimiento 1:1.

> [!TIP]
> Agregar una herramienta nueva solo requiere crear un archivo `registry/<tool>.conf`. El instalador es genérico y no se toca.

## Features

- **Nativo, sin proot** — binarios ELF glibc ejecutados directamente vía el loader de Termux (`ld-linux-aarch64.so.1`), con `patchelf` y wrappers que resuelven las diferencias con Android (seccomp, DNS, certificados).
- **Framework modular** — cada CLI vive en un `registry/*.conf`: variables, entorno, parches y hooks. Todo lo específico de una herramienta está en su registro.
- **Última versión automática** — versión y checksum se resuelven solos desde la GitHub API, el manifest de Google o el manifest del CDN de Amazon.
- **Fail-closed** — sin checksum verificado no se instala. `sha256.txt` queda como pinning opcional para verificaciones independientes del vendor.
- **Parches adaptativos** — agy se auto-parchea (syscall `faccessat2` + TCMalloc VA48→VA39 si aplica) con smoke test posterior. `--update` funciona sin mantenimiento manual entre versiones.
- **Build en CI** — codex se compila en GitHub Actions desde el código oficial (bionic arm64 para Android, musl verificado para amd64) y se publica con digest y attestation en un repo de distribución dedicado.
- **Auditable** — `verify.sh` audita la instalación en 10 pasos y detecta adulteración posterior al chequeo de hashes registrados en `manifest.txt`.

## Herramientas soportadas

| Herramienta | Distribución | Verificación de integridad | Mitigaciones específicas |
|---|---|---|---|
| **`opencode`** | [GitHub Releases](https://github.com/anomalyco/opencode) | SHA256 del asset vía GitHub API + [Attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations) (Sigstore) | Invocación directa vía loader glibc (`NEEDS_PATCHELF=false`) |
| **`agy`** (Antigravity CLI) | [Google Cloud Storage](https://antigravity.google) (manifest JSON) | SHA512 dinámico del manifest | Parche adaptativo VA39 + `faccessat2`, shim `libc.so`, DNS cgo |
| **`kiro-cli`** (Kiro CLI) | [CDN de Amazon](https://prod.download.cli.kiro.dev) | SHA256 del `manifest.json` oficial | Última versión automática del manifest |
| **`codex`** (OpenAI Codex) | [Repo de distribución](https://github.com/Eybad/ai-cli-termux-dist) — **build propio en CI** desde el código oficial (Apache-2.0) | SHA256 del asset vía GitHub API + attestation SLSA del workflow | Binario nativo bionic (arm64, sin proot) o musl verificado (amd64); `EXEC_DIRECT` |
| **`cursor-agent`** (Cursor Agent CLI) | [CDN propio](https://downloads.cursor.com/lab/...) (`url_template`, sin endpoint "latest" público) | SHA256 del tarball pineado a mano en `sha256.txt` | Bundle node embebido patcheado (`ELF_NAME` + `ENTRY_POINT`), alias `agent`, `agent update` bloqueado, shims de navegador y DNS (patrón agy), `rg` del sistema por PATH |

## Requisitos

- **Dispositivo**: Android 10+ (`aarch64`) o host Linux (`x86_64`).
- **Termux**: instalado desde **F-Droid** o **GitHub Releases** (la versión de Google Play está obsoleta).
- **Paquetes base**:

  ```bash
  pkg install git python ca-certificates -y
  ```

- **Almacenamiento**: ~400 MB por herramienta (kiro-cli: ~1 GB).

## Instalación

```bash
git clone https://github.com/Eybad/ai-cli-termux.git
cd ai-cli-termux
```

### opencode

```bash
bash install.sh opencode                    # última versión (digest SHA256 de GitHub)
bash install.sh opencode -v 1.18.9          # versión específica
bash install.sh opencode --update           # actualizar a la última versión
bash install.sh opencode -u                 # desinstalar
```

### agy (Antigravity CLI)

```bash
bash install.sh agy                         # última versión (manifest oficial de Google)
bash install.sh agy --update                # actualizar a la última versión
bash install.sh agy -r                      # reinstalar (re-aplica los parches)
bash install.sh agy -u                      # desinstalar
```

### kiro-cli

```bash
bash install.sh kiro-cli                    # última versión (manifest del CDN de Amazon)
bash install.sh kiro-cli --update           # actualizar a la última versión
bash install.sh kiro-cli -r                 # reinstalación forzada
bash install.sh kiro-cli -u                 # desinstalar
```

### codex (OpenAI Codex)

```bash
bash install.sh codex                    # última versión (release de distribución generado por CI)
bash install.sh codex -v 0.146.0         # versión específica (release estándar)
bash install.sh codex -v 0.146.0+android1  # release con el parche de locks Android
bash install.sh codex --update           # actualizar a la última versión
bash install.sh codex -u                 # desinstalar
```

**Por qué no se instala el binario oficial de OpenAI**: los assets Linux oficiales son **musl estáticos**, que en Android no resuelven DNS (leen `/etc/resolv.conf` de la raíz del sistema, inexistente sin proot) — el login y la API fallan. Por eso el workflow [build-codex.yml](.github/workflows/build-codex.yml) compila el CLI en CI desde el código oficial (`openai/codex`, Apache-2.0) para **bionic nativo** (`aarch64-linux-android`, NDK API 29): DNS (netd) y TLS (rustls/webpki) funcionan sin proot. En `amd64` (host Linux) se re-empaqueta el asset oficial musl con su digest SHA256 verificado contra la API upstream (fail-closed).

- **Parche de locks Android**: desde Rust 1.89, `File::lock*` devuelve `Unsupported` en Android (rust-lang/rust#148325) y el TUI/exec de codex fallan. El build de arm64 aplica un parche generado ([`gen-codex-lock-patch.py`](scripts/gen-codex-lock-patch.py) → módulo `file_lock_shim` con `flock(2)`) y publica con tag `vX.Y.Z+androidN` (build metadata semver; `N` = `patch_rev`). El instalador preserva el `+build` en versión y tag, y `--update` migra automáticamente del release estándar al parcheado. `codex update` está bloqueado en el wrapper (todo pasa por `install.sh codex --update`).
- **Escalable**: el CI detecta cada release nuevo de OpenAI (cron diario) y publica el asset en el [repo de distribución](https://github.com/Eybad/ai-cli-termux-dist) (`codex-arm64.tar.gz`/`codex-amd64.tar.gz`) con digest y attestation. `--update` funciona sin tocar nada. Si un release upstream rompe el build bionic, no se publica y la última versión buena sigue instalable.
> [!IMPORTANT]
> El sandbox de codex usa `landlock` por defecto; en kernels Android que no lo soporten, configurá `sandbox_mode = "off"` en `~/.codex/config.toml`.

- **Ripgrep**: si codex reporta la falta de `rg`, instalalo con `pkg install ripgrep` (se busca por PATH, como los shims de agy).
- **Releases del proyecto vs de distribución**: los releases `v0.146.0+` de codex viven en el repo de distribución dedicado (solo binarios). Los releases `v1.0.0+` de este repo versionan el instalador en sí (este README, `install.sh`, `verify.sh`, `registry/`). El instalador distingue por asset, no por repo.

### cursor-agent (Cursor Agent CLI)

```bash
bash install.sh cursor-agent -v 2026.07.23-e383d2b  # versión específica (ver pin en sha256.txt)
bash install.sh cursor-agent --update               # última versión registrada en sha256.txt
bash install.sh cursor-agent -r                     # reinstalar
bash install.sh cursor-agent -u                     # desinstalar (borra también el alias `agent`)
```

- **Bundle node**: Cursor distribuye un tarball con un runtime **node embebido** (ELF glibc de 125 MB, no-PIE) que se patchea al overlay (`ELF_NAME="node"`) y se lanza vía el launcher bash del bundle (`ENTRY_POINT="cursor-agent"`). El instalador oficial expone el comando como `agent`; se replica con `ALIASES` (symlink gestionado).
- **Sin checksums del vendor**: Cursor no publica checksums ni manifest, y la versión va hardcodeada en el script de [cursor.com/install](https://cursor.com/install). El pin se mantiene a mano en `sha256.txt` (ver el comentario del archivo): detectar la versión nueva, descargar el tarball (`https://downloads.cursor.com/lab/<version>/linux/arm64/agent-cli-package.tar.gz`), `sha256sum`, actualizar la entrada y `bash install.sh cursor-agent --update`. El CDN tuvo incidentes de 403 históricos (artifacts no publicados): el pin evita instalar versiones rotas.
- **`agent update` bloqueado** (`WRAPPER_DENY_ARGS`): el updater interno descargaría versiones sin verificación de checksum; las actualizaciones pasan siempre por `install.sh cursor-agent --update` (fail-closed). Nota: el deny es *policy* del wrapper, no una frontera — ejecutar el launcher del bundle directo (`libexec/cursor-agent/cursor-agent update`) o `node index.js update` la esquiva. El código JS del CLI (`index.js`, chunks) se cubre con el pin del tarball al instalar, pero no se audita individualmente después (verify.sh hashea los ELFs).
- **`rg` del sistema**: el CLI busca `rg` por PATH (`pkg install ripgrep`); no se usa el binario del bundle. `cursorsandbox` y `crepectl` (búsqueda/sandbox del bundle) se patchean y auditan vía `EXTRA_BINS`.
- **Login**: requiere cuenta de cursor.com (`agent login` abre el navegador vía `termux-open-url`, redirigido por los shims).

#### TUI en Termux: fix del runtime bun

El TUI de `kiro-cli` (sin argumentos) delega el render en un runtime [bun](https://bun.sh) que el cliente descarga a `~/.local/share/kiro-cli/` (`bun` + `tui.js`). El build que descarga es glibc y no puede ejecutarse en Termux (interpreter del sistema inexistente): el TUI muestra `Launching...` y falla con `error: No such file or directory (os error 2)`.

Fix (una sola vez; repetir si el cliente re-descarga el build glibc):

1. Ejecutar `timeout 5 kiro-cli` una vez para que el cliente descargue `bun` + `tui.js` y registre `bun.sha256` (hash esperado por el launcher; sin él re-descarga el build glibc en cada arranque).
2. Reemplazar el runtime por la build Android oficial de bun (bionic PIE, corre nativa en Termux):

```bash
curl -fsSL -o /tmp/bun-android.zip \
  https://github.com/oven-sh/bun/releases/download/bun-v1.3.14/bun-linux-aarch64-android.zip
unzip -o /tmp/bun-android.zip -d /tmp/bun-android
cp /tmp/bun-android/bun-linux-aarch64-android/bun ~/.local/share/kiro-cli/bun
chmod 755 ~/.local/share/kiro-cli/bun
# Fail-closed: debe ser la build Android (bionic, interpreter /system/bin/linker64).
file ~/.local/share/kiro-cli/bun | grep -q 'linker64' \
  || { echo "ERROR: el binario descargado no es la build Android de bun"; exit 1; }
```

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
bash install.sh <tool> --update
```

- **opencode**: última release de GitHub; digest SHA256 verificado contra la GitHub API (el pin de `sha256.txt` gana si existe).
- **agy**: última versión del manifest de Google. El parche adaptativo (`registry/patch_va39.py`) resuelve los cambios de estructura por pattern-matching de instrucciones ARM64, y el hook ejecuta un smoke test (`--version`) post-parche: si algo no se puede resolver, la instalación aborta y se restaura la versión anterior.
- **kiro-cli**: última versión del `manifest.json` del CDN de Amazon.
- **codex**: última versión publicada por el build propio de CI en el repo de distribución ([`build-codex.yml`](.github/workflows/build-codex.yml)); digest + attestation del workflow (emitida por el repo del proyecto).
- **cursor-agent**: última versión registrada en `sha256.txt` (pin manual; el vendor no publica endpoint "latest" — ver [cursor-agent](#cursor-agent-cursor-agent-cli)). Detecta versiones con prerelease/build (ej: `2026.07.23-e383d2b`).

> [!NOTE]
> Para la mayoría de las herramientas no hace falta tocar `sha256.txt`: la versión y el checksum se resuelven automáticamente y fail-closed desde la fuente del vendor (el archivo queda como capa opcional de pinning). **Excepción: `cursor-agent`** — su pin en `sha256.txt` es la única fuente de versiones (CDN sin manifest), y `--update` toma de ahí la última registrada.

## Verificación

```bash
bash verify.sh <tool>    # ej: bash verify.sh agy
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

Esta sección describe las capas del runtime; los parches puntuales que resuelven cada incompatibilidad de Android están detallados en [Soluciones técnicas de Android](#soluciones-técnicas-de-android).

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

## Integridad (doble capa de hashes)

Como `patchelf` y `patch_va39.py` modifican el binario durante la instalación, el sistema registra dos checksums:

1. **Tarball**: verificado al descargar (digest del vendor, pin de `sha256.txt` o `--sha256`) — sin hash verificado no se instala.
2. **Binario instalado**: hash recalculado tras los parches y guardado en `manifest.txt`; `verify.sh` lo compara en cada auditoría para detectar adulteración posterior.

## Estructura del repositorio

```
ai-cli-termux/
├── install.sh                  # Instalador genérico (fail-closed)
├── verify.sh                   # Verificador post-instalación (10 pasos)
├── sha256.txt                  # Pinning opcional de hashes
├── AGENTS.md                   # Invariants y convenciones para contribuir
├── registry/                   # Configuración por herramienta
│   ├── opencode.conf
│   ├── agy.conf
│   ├── kiro-cli.conf
│   ├── codex.conf
│   ├── cursor-agent.conf
│   └── patch_va39.py           # Parche adaptativo ARM64 (VA39 + faccessat2)
├── scripts/
│   └── gen-codex-lock-patch.py # Generador fail-closed del parche de locks (CI)
├── docs/
│   └── adr/0001-release-scheme.md
└── .github/workflows/
    ├── build-codex.yml         # Build bionic arm64 + musl verificado (cron diario)
    └── update-hashes.yml       # Actualiza sha256.txt (manual)
```
