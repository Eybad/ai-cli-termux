# Security Policy

## Alcance

Este repositorio contiene el instalador y el gestor (`install.sh`, `verify.sh`, `aicli`), la configuración por herramienta (`registry/`) y los workflows de CI/build (`.github/workflows/`). Los binarios que se instalan son **artefactos de terceros**: este proyecto no los compila (salvo codex, cuyo build en CI usa el código oficial de OpenAI) y su seguridad depende de la cadena de verificación descrita abajo.

## Reportar una vulnerabilidad

- Reportá en **privado** usando el flujo de advisory de GitHub: la pestaña **Security → Report a vulnerability** del repositorio (no abras un issue público para fallos de seguridad activos).
- Incluí: versión afectada, descripción, pasos para reproducir y, si aplica, un parche propuesto.
- Plazo de respuesta: 7 días hábiles para triaje inicial. El fix se publica con advisory (GHSA) cuando corresponde.

## Modelo de confianza (cómo se protege la cadena)

- **Fail-closed en checksums**: sin hash verificado no se instala nada. La fuente del checksum varía por herramienta (digest de la GitHub API, manifest JSON del vendor, o pin manual en `sha256.txt` para vendors sin manifest). Un mismatch aborta la instalación.
- **Attestation**: los builds propios (codex) publican attestation del workflow (Sigstore/SLSA v1); `install.sh` la verifica con `gh attestation verify` cuando el vendor la emite.
- **TOFU documentado**: `cursor-agent` se descarga de un CDN propio de Cursor que no publica checksums; el pin en `sha256.txt` se fija a mano con la versión detectada en el instalador oficial (TOFU — primera confianza). Cualquier cambio de política de ese CDN debe revisarse explícitamente.
- **Sandbox de codex**: `sandbox_mode` usa landlock; en kernels Android sin soporte se documenta `sandbox_mode = "off"` en `~/.codex/config.toml` (riesgo asumido por el usuario).
- **Superficie reducida**: el instalador no descarga ni ejecuta scripts de terceros; el código del repo se audita con `verify.sh` post-instalación y CI (shellcheck + validación de registros).

## Dependencias

- **GitHub Actions**: pineadas por commit SHA (no por tag mutable) y actualizadas por Dependabot (`.github/dependabot.yml`).
- **NDK del build de codex**: verificado contra el checksum oficial de Google.
- **Binarios instalados**: verificados en cada instalación/actualización contra el hash de su fuente oficial.
