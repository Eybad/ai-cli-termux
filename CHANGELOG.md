# Changelog

Todas las versiones notables de ai-cli-termux se documentan en este archivo.

El formato sigue [Keep a Changelog](https://keepachangelog.com/es/1.1.0/) y el proyecto usa [Versionado Semántico](https://semver.org/lang/es/).

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
