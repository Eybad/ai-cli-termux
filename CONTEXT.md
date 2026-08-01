# ai-cli-termux

Instalador genérico de CLIs de IA para Termux (sin proot): un instalador común con configuración por herramienta. Los binarios que no existen para Android se compilan en CI y se distribuyen desde un repo de distribución dedicado.

## Language

**Tool**:
CLI de IA instalable (opencode, agy, kiro-cli, codex).
_Avoid_: herramienta, app

**Instalador genérico**:
install.sh + verify.sh; toda lógica específica de un tool vive en su configuración (`registry/<tool>.conf`) y sus hooks.
_Avoid_: script de instalación, setup

**Versión upstream**:
Versión del software publicada por el vendor (ej. 0.146.0 de openai/codex).
_Avoid_: versión del tool

**Tag de distribución**:
Tag `vX.Y.Z` del repo de distribución que espeja la versión upstream de un tool.
_Avoid_: release propio, tag espejo

**Release de distribución**:
Release del repo de distribución cuyo único contenido son assets instalables de un tool (ej. `codex-arm64.tar.gz`); es la fuente de descarga de install.sh.
_Avoid_: release propio, release binario

**Repo de distribución**:
Repositorio dedicado (`Eybad/ai-cli-termux-dist`) que solo contiene releases de distribución.
_Avoid_: repo de artifacts, repo de releases

**Release del proyecto**:
Release del repo del proyecto que versiona el instalador en sí (`v1.0.0+`); no contiene assets de tools.
_Avoid_: release del repo

**Última versión instalable**:
Release de distribución más reciente cuyo asset coincide con el template esperado (`ARCHIVE_TEMPLATE` expandido); es lo que resuelve `--update`.
_Avoid_: última release, latest

**Repo emisor de attestation**:
Repo donde corre el workflow de build y que firma la provenance SLSA de los assets (puede diferir del repo de distribución).
_Avoid_: repo de attestation

**Overlay glibc**:
Conjunto loader + librerías instalado por el proyecto que permite correr binarios glibc en Termux sin proot.
_Avoid_: glibc del sistema

**EXEC_DIRECT**:
Modo de un tool cuyo binario corre nativo (ELF estático musl o compilado bionic/Android) sin overlay glibc.
_Avoid_: modo nativo, ejecución directa

**Shim**:
Binario de interposición en `$PREFIX/bin` (ej. `xdg-open` → `termux-open-url`) registrado para eliminarse al desinstalar.
_Avoid_: alias, proxy

**Pinning opcional**:
Entrada en `sha256.txt` que, si existe para el tag instalado, gana sobre el checksum resuelto automáticamente.
_Avoid_: hash fijo
