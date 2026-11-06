<div align="center">

# ai-cli-termux

**CLIs de IA ejecutadas de forma nativa en Termux, sin proot**

[![CI](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/ci.yml?style=flat-square&label=ci)](https://github.com/Eybad/ai-cli-termux/actions)
[![Build codex](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/build-codex.yml?style=flat-square&label=build-codex)](https://github.com/Eybad/ai-cli-termux/actions)
[![Android](https://img.shields.io/badge/Android-10%2B-3ddc84?style=flat-square&logo=android&logoColor=white)](https://www.android.com/)
[![Termux](https://img.shields.io/badge/Termux-F--Droid-000000?style=flat-square&logo=terminal)](https://f-droid.org/en/packages/com.termux/)

[Features](#features) • [Requisitos](#requisitos) • [Inicio rápido](#inicio-rápido) • [Uso](#uso) • [Configuración](#configuración) • [Testing](#testing)

</div>

Instala y gestiona CLIs de inteligencia artificial — [opencode](https://github.com/anomalyco/opencode), [Antigravity CLI](https://antigravity.google) y [OpenAI Codex](https://github.com/openai/codex) — directamente en **Termux** para Android (`aarch64`) y Linux (`x86_64`). Los binarios se ejecutan de forma nativa sobre el kernel (bionic directo o mediante el overlay glibc de Termux), sin `proot`, sin emulación y con rendimiento 1:1.

> [!TIP]
> El instalador es genérico y extensible. Incorporar una nueva herramienta solo requiere definir un archivo declarativo en `registry/<tool>.conf`.

## Features

- **Gestor unificado `aicli`**: Interfaz central para listado, instalación, actualización (individual o `--all`), desinstalación, verificación y diagnóstico.
- **Ejecución nativa sin proot**: Binarios bionic nativos (`EXEC_DIRECT`) o binarios Linux vinculados al loader glibc de Termux (`ld-linux-aarch64.so.1`) mediante `patchelf`.
- **Integridad fail-closed**: Verificación criptográfica obligatoria previa a la extracción (`release_digest`, manifest JSON de upstream o pinning en `sha256.txt`).
- **Builds Android propios**: Compilación automatizada en CI para herramientas sin soporte nativo Android oficial (ej. Codex bionic arm64 con shims de compatibilidad).
- **Auditoría post-instalación**: Verificación en 10 pasos que valida formato ELF, intérprete dinámico, rpath, integridad contra `manifest.txt` y ejecución real.

## Requisitos

- **Entorno**: Android 10+ (`aarch64`) o Linux (`x86_64`) en Termux (F-Droid o GitHub Releases).
- **Paquetes base**:
  ```bash
  pkg install git curl tar coreutils gawk jq ca-certificates -y
  ```
  - *Opcionales*: `gh` (verificación de attestation SLSA para codex), `bash-completion` (autocompletado), `ripgrep` (búsqueda de archivos en codex).
- **Almacenamiento**: ~400 MB por herramienta (~1.3 GB para codex con dependencias de CI/build).

> [!NOTE]
> El overlay glibc (`glibc-repo` + `glibc-runner`) y `patchelf` se instalan de forma automática durante la primera instalación si la herramienta los requiere.

## Inicio rápido

1. Clonar el repositorio y registrar el comando global:
   ```bash
   git clone https://github.com/Eybad/ai-cli-termux.git
   cd ai-cli-termux
   bash aicli self-install
   ```

2. Listar herramientas e instalar:
   ```bash
   aicli list                    # Ver herramientas y estado local/remoto
   aicli install opencode        # Instalar la última versión verificada
   aicli verify opencode         # Auditar integridad de la instalación
   ```

## Uso

### Comandos de `aicli`

| Comando | Descripción |
|---|---|
| `aicli list [--offline] [--json] [<tool>]` | Muestra estado local y disponibilidad de actualizaciones upstream. |
| `aicli install <tool> [-v <ver>] [--sha256 <hash>]` | Instala una herramienta o versión específica con checksum verificado. |
| `aicli update <tool \| --all>` | Actualiza una o todas las herramientas instaladas preservando manifests. |
| `aicli remove <tool>` | Desinstala binarios, shims y registros de manifest. |
| `aicli verify <tool>` | Ejecuta la auditoría de integridad en 10 pasos (exit code 1 ante fallo). |
| `aicli doctor` | Diagnostica el entorno (arquitectura, loader glibc, DNS, certificados). |
| `aicli completion <bash \| zsh \| fish>` | Genera scripts de autocompletado para la shell activa. |
| `aicli self-install` / `self-update` | Instala o actualiza el wrapper global en `$PREFIX/bin`. |
| `aicli help [<subcomando> \| <tool>]` | Ayuda integrada por subcomando o por herramienta del registry. |

> [!NOTE]
> `install.sh` y `verify.sh` pueden ejecutarse de forma directa (`bash install.sh <tool> [opciones]`). Para pipelines no interactivos, `NO_COLOR=1`, `TERM=dumb` o `--no-color` desactivan secuencias ANSI.

### Herramientas soportadas

| Herramienta | Distribución | Verificación de integridad | Modo de ejecución |
|---|---|---|---|
| **`opencode`** | [GitHub Releases](https://github.com/anomalyco/opencode) | SHA256 vía GitHub API o pin `sha256.txt` | Overlay glibc vía `opencode-runner.sh` (`NEEDS_PATCHELF=false`) |
| **`agy`** (Antigravity CLI) | [Endpoint de Google](https://antigravity.google) (manifest JSON) | SHA512 del manifest dinámico | Nativo bionic en Android (`android_arm64`, `EXEC_DIRECT=true`) |
| **`codex`** (OpenAI Codex) | [Distribución CI](https://github.com/Eybad/ai-cli-termux-dist) (código oficial Apache-2.0) | SHA256 del asset + attestation SLSA | Nativo bionic (`aarch64`, `EXEC_DIRECT=true`) o musl (`x86_64`) |

- **`opencode`**: Inicia el servidor efímero glibc mediante `opencode-runner.sh` preservando rutas XDG estándar.
- **`agy`**: Descarga el binario oficial compilado por Google para Android bionic (`cli_android_arm64.tar.gz`), ejecutándose sin parches en el ELF.
- **`codex`**: Binario bionic (`aarch64-linux-android`) compilado en CI ([`build-codex.yml`](.github/workflows/build-codex.yml)) para resolver DNS sin musl. Incorpora shims de locks (`flock(2)` para [rust-lang/rust#148325](https://github.com/rust-lang/rust/issues/148325)), tablas ctype para V8 y empaqueta el binario companion `codex-code-mode-host`.

## Configuración

### Registro de herramientas (`registry/<tool>.conf`)

Cada herramienta se define de forma modular en su archivo de configuración:
- `RELEASE_SOURCE`: Origen del release (`github`, `manifest_json`, `url_template`).
- `CHECKSUM_SOURCE`: Método de verificación (`release_digest`, `manifest`, `hashfile`).
- `EXEC_DIRECT`: `true` para binarios bionic nativos sin overlay glibc.
- `EXTRA_BINS`: Lista de binarios secundarios a patchear y enlazar en `$PREFIX/bin`.
- Hooks opcionales: `pre_wrapper_hook` y `post_install_hook` para lógica de entorno o parches específicos.

### Parámetros de runtime y sandbox

- **Sandbox de codex**: Emplea `landlock` por defecto. En kernels Android sin soporte (`zgrep LANDLOCK /proc/config.gz`), configurar:
  ```toml
  # ~/.codex/config.toml
  sandbox_mode = "off"
  ```
- **Pinning de versiones**: Se puede fijar un hash local en `sha256.txt` para garantizar reproducibilidad e independencia de APIs externas.
- **Red y certificados**: Los hooks configuran automáticamente `$GLIBC_PREFIX/etc/resolv.conf` desde `net.dns` y exportan `SSL_CERT_FILE` al bundle CA de Termux.

## Testing

Suite de validación e integridad del repositorio:

```bash
# Análisis estático de shell scripts
shellcheck install.sh verify.sh aicli registry/lib/*.sh registry/opencode.conf scripts/*.sh

# Validación del registro de herramientas y manifests
bash scripts/test-registry-integrity.sh

# Pruebas funcionales de runners y wrappers
bash scripts/test-opencode-runner.sh
bash scripts/test-wrapper-runner.sh

# Verificación de generadores de CI y parches
python3 scripts/test-gen-codex-lock-patch.py
python3 scripts/gen-ctype-tables.py --check
```
