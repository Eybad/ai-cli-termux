<div align="center">

# ai-cli-termux

**Run AI CLIs natively on Termux without PRoot**

[![CI](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/ci.yml?style=flat-square&label=ci)](https://github.com/Eybad/ai-cli-termux/actions)
[![Build codex](https://img.shields.io/github/actions/workflow/status/Eybad/ai-cli-termux/build-codex.yml?style=flat-square&label=build-codex)](https://github.com/Eybad/ai-cli-termux/actions)
[![Android](https://img.shields.io/badge/Android-10%2B-3ddc84?style=flat-square&logo=android&logoColor=white)](https://www.android.com/)
[![Termux](https://img.shields.io/badge/Termux-F--Droid-000000?style=flat-square&logo=terminal)](https://f-droid.org/en/packages/com.termux/)

[Features](#features) • [Requirements](#requirements) • [Quickstart](#quickstart) • [Usage](#usage) • [Configuration](#configuration) • [Testing](#testing)

</div>

Install and manage AI command-line interfaces — [OpenCode](https://github.com/anomalyco/opencode), [Antigravity CLI](https://antigravity.google), and [OpenAI Codex](https://github.com/openai/codex) — directly on **Termux** for Android (`aarch64`) and Linux (`x86_64`). Binaries run natively on the host kernel (direct Bionic execution or via the Termux glibc overlay), without `proot`, without virtualization, and with 1:1 performance.

> [!TIP]
> The installer is generic and extensible. Adding a new tool only requires a declarative configuration file in `registry/<tool>.conf`.

## Features

- **Unified `aicli` manager**: Central interface for listing, installation, atomic or global (`--all`) updates, uninstallation, verification, and diagnostics.
- **Native execution without PRoot**: Direct Bionic binaries (`EXEC_DIRECT`) or Linux binaries linked against Termux's glibc dynamic loader (`ld-linux-aarch64.so.1`) via `patchelf`.
- **Fail-closed integrity**: Mandatory cryptographic verification prior to extraction (`release_digest`, upstream JSON manifests, or pinning in `sha256.txt`).
- **Custom Android builds**: Automated CI compilation for tools lacking official Android support (e.g., Codex Bionic arm64 with compatibility shims).
- **Post-installation audit**: A 10-step verification suite checking ELF headers, dynamic interpreters, rpath settings, `manifest.txt` checksums, and runtime execution.

## Requirements

- **Environment**: Android 10+ (`aarch64`) or Linux (`x86_64`) on Termux (F-Droid or GitHub Releases).
- **Base packages**:
  ```bash
  pkg install git curl tar coreutils gawk jq ca-certificates -y
  ```
  - *Optional*: `gh` (SLSA attestation verification for Codex), `bash-completion` (shell completions), `ripgrep` (file search in Codex).
- **Disk storage**: ~400 MB per tool (~1.3 GB for Codex with build dependencies).

> [!NOTE]
> The glibc overlay (`glibc-repo` + `glibc-runner`) and `patchelf` are installed automatically during the first installation when required by the tool.

## Quickstart

1. Clone the repository and register the global command:
   ```bash
   git clone https://github.com/Eybad/ai-cli-termux.git
   cd ai-cli-termux
   bash aicli self-install
   ```

2. List tools and install:
   ```bash
   aicli list                    # Inspect available tools and local/remote versions
   aicli install opencode        # Install the latest verified release
   aicli verify opencode         # Audit installation integrity
   ```

## Usage

### `aicli` Commands

| Command | Description |
|---|---|
| `aicli list [--offline] [--refresh] [--json] [<tool>]` | Displays local status and upstream update availability. |
| `aicli install <tool> [-v <ver>] [--sha256 <hash>]` | Installs a tool or specific version with verified checksum. |
| `aicli update <tool \| --all>` | Updates one or all installed tools while preserving manifests. |
| `aicli remove <tool>` | Uninstalls binaries, shims, and manifest records. |
| `aicli verify <tool>` | Runs the 10-step integrity audit (exit code 1 on failure). |
| `aicli doctor` | Diagnoses the environment (architecture, glibc loader, DNS, certificates). |
| `aicli completion <bash \| zsh \| fish>` | Emits shell completion scripts to stdout. |
| `aicli self-install` / `self-update` | Installs or updates the global wrapper in `$PREFIX/bin`. |
| `aicli help [<subcommand> \| <tool>]` | Built-in reference for commands and registry tools. |

> [!NOTE]
> `install.sh` and `verify.sh` support standalone execution (`bash install.sh <tool> [options]`). For non-interactive automation, `NO_COLOR=1`, `TERM=dumb`, or `--no-color` disable ANSI styling.

### Supported Tools

| Tool | Distribution | Integrity Verification | Execution Mode |
|---|---|---|---|
| **`opencode`** | [GitHub Releases](https://github.com/anomalyco/opencode) | SHA256 via GitHub API or `sha256.txt` pin | Glibc overlay via `opencode-runner.sh` (`NEEDS_PATCHELF=false`) |
| **`agy`** (Antigravity CLI) | [Google Endpoint](https://antigravity.google) (JSON manifest) | SHA512 from dynamic manifest | Native Bionic on Android (`android_arm64`, `EXEC_DIRECT=true`) |
| **`codex`** (OpenAI Codex) | [CI Distribution](https://github.com/Eybad/ai-cli-termux-dist) (Apache-2.0 upstream) | Asset SHA256 + SLSA attestation | Native Bionic (`aarch64`, `EXEC_DIRECT=true`) or musl (`x86_64`) |

- **`opencode`**: Launches the ephemeral glibc server using `opencode-runner.sh`, preserving standard XDG filesystem paths.
- **`agy`**: Downloads the official Android Bionic binary built by Google (`cli_android_arm64.tar.gz`), running unmodified with the system dynamic linker.
- **`codex`**: Upstream musl assets fail on Android due to missing `/etc/resolv.conf`. The [`build-codex.yml`](.github/workflows/build-codex.yml) workflow builds native Bionic (`aarch64-linux-android`) in CI:
  - Integrates an `flock(2)` file-lock shim to resolve [rust-lang/rust#148325](https://github.com/rust-lang/rust/issues/148325).
  - Supplies full generated ctype tables for V8 compatibility.
  - Bundles the companion `codex-code-mode-host` binary for V8 code execution.
  - Versioned with SemVer build metadata: `vX.Y.Z+androidN`.

> [!IMPORTANT]
> Codex defaults to `landlock` for sandboxing. On older Android kernels lacking Landlock support (`zgrep LANDLOCK /proc/config.gz`), configure:
> ```toml
> # ~/.codex/config.toml
> sandbox_mode = "off"
> ```

## Configuration

### Tool Registries (`registry/<tool>.conf`)

Tools are declaratively configured with modular fields:
- `RELEASE_SOURCE`: Release origin (`github`, `manifest_json`, `url_template`).
- `CHECKSUM_SOURCE`: Integrity verification mechanism (`release_digest`, `manifest`, `hashfile`).
- `EXEC_DIRECT`: Set to `true` for native Bionic binaries that bypass the glibc overlay.
- `EXTRA_BINS`: Auxiliary binaries to patch and link into `$PREFIX/bin`.
- Optional hooks: `pre_wrapper_hook` and `post_install_hook` for custom environment setup or runtime patching.

### Runtime and Sandbox Settings

- **Codex Sandbox**: Uses `landlock` by default. Set `sandbox_mode = "off"` in `~/.codex/config.toml` if unsupported by the host kernel.
- **Version Pinning**: Store target hashes in `sha256.txt` to guarantee reproducible installs independent of upstream API changes.
- **Network and Certificates**: Installer hooks configure `$GLIBC_PREFIX/etc/resolv.conf` from Android's `net.dns` properties and set `SSL_CERT_FILE` to Termux's CA bundle.

## Testing

Validation and integrity test suite for development:

```bash
# Static analysis for shell scripts
shellcheck install.sh verify.sh aicli registry/lib/*.sh registry/opencode.conf scripts/*.sh

# Tool registry and manifest validation
bash scripts/test-registry-integrity.sh

# Functional tests for runners and wrappers
bash scripts/test-opencode-runner.sh
bash scripts/test-wrapper-runner.sh

# CI generators and patch verification
python3 scripts/test-gen-codex-lock-patch.py
python3 scripts/gen-ctype-tables.py --check
```
