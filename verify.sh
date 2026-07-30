#!/data/data/com.termux/files/usr/bin/bash
# verify.sh — Verificador de integridad de CLIs instaladas en Termux
#
# Uso: verify.sh <herramienta>
# Ejemplos:
#   verify.sh opencode
#   verify.sh agy
#
# Verifica: manifest, binario (presencia, permisos, formato ELF), interpreter/rpath,
# integridad del binario post-patchelf, coherencia con sha256.txt, attestation
# registrada, wrapper (LD_PRELOAD/LD_LIBRARY_PATH), loader glibc, nsswitch, y
# ejecución real. Sale con código 1 si hay fallos.

set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="$PREFIX/glibc"
GLIBC_LIB="$GLIBC_PREFIX/lib"

# Resolver loader según arquitectura
case "$(uname -m)" in
  aarch64)
    LOADER="$GLIBC_LIB/ld-linux-aarch64.so.1"
    EXPECTED_ELF_ARCH="ARM aarch64"
    ;;
  x86_64)
    LOADER="$GLIBC_LIB/ld-linux-x86-64.so.2"
    EXPECTED_ELF_ARCH="x86-64"
    ;;
  *)
    LOADER="$GLIBC_LIB/ld-linux-aarch64.so.1"
    EXPECTED_ELF_ARCH="ARM aarch64"
    ;;  # fallback
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_DIR="$SCRIPT_DIR/registry"
HASH_FILE="$SCRIPT_DIR/sha256.txt"

if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; ORANGE=$'\033[38;5;214m'
  MUTED=$'\033[0;2m'; NC=$'\033[0m'
else
  GREEN=''; RED=''; ORANGE=''; MUTED=''; NC=''
fi

FAILS=0
WARNS=0

pass() { printf '%sPASS%s: %s\n' "$GREEN" "$NC" "$1"; }
fail() { printf '%sFAIL%s: %s\n' "$RED"   "$NC" "$1"; FAILS=$((FAILS + 1)); }
warn() { printf '%sWARN%s: %s\n' "$ORANGE" "$NC" "$1"; WARNS=$((WARNS + 1)); }
note() { printf '%s      %s%s\n' "$MUTED" "$1" "$NC"; }

normalize_version() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "${1:-}" | head -1 || true; }

manifest_get() {
  local key="$1" mf="$2"
  [[ -f "$mf" ]] || return 0
  awk -F= -v k="$key" '{ sub(/\r$/, "") } $1==k { sub(/^[^=]*=/,""); print; exit }' "$mf"
}

lookup_hashfile() {
  local key="$1"
  [[ -f "$HASH_FILE" ]] || return 0
  local res="" arch_name=""
  case "$(uname -m)" in
    aarch64) arch_name="arm64" ;;
    x86_64)  arch_name="amd64" ;;
  esac
  if [[ -n "$arch_name" ]]; then
    res=$(awk -v t="${key}:${arch_name}" '{ sub(/\r$/, "") } $1==t { print $2; exit }' "$HASH_FILE")
  fi
  if [[ -z "$res" ]]; then
    res=$(awk -v t="$key" '{ sub(/\r$/, "") } $1==t { print $2; exit }' "$HASH_FILE")
  fi
  printf '%s' "$res"
}

# ── Argumento ─────────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Uso: verify.sh <herramienta>"
  echo "Herramientas disponibles:"
  for f in "$REGISTRY_DIR"/*.conf; do
    [[ -f "$f" ]] && printf '  - %s\n' "$(basename "$f" .conf)"
  done
  exit 1
fi

TOOL="$1"
CONF="$REGISTRY_DIR/$TOOL.conf"

if [[ ! -f "$CONF" ]]; then
  echo "ERROR: Herramienta desconocida '$TOOL'. Creá registry/$TOOL.conf para registrarla."
  exit 1
fi

# Cargar configuración
APP_NAME=""; DISPLAY_NAME=""; ELF_NAME=""; CHECKSUM_ALGO="sha256"
CHECKSUM_SOURCE="hashfile"; NEEDS_PATCHELF=true; ATTEST_PREDICATE=""; REPO=""
# shellcheck source=/dev/null
source "$CONF"

LIBEXEC_DIR="$PREFIX/libexec/$APP_NAME"
BIN_FILE="$LIBEXEC_DIR/$ELF_NAME"
MANIFEST="$LIBEXEC_DIR/manifest.txt"
WRAPPER="$PREFIX/bin/$APP_NAME"

printf '=== Verificación de %s en Termux ===\n\n' "$DISPLAY_NAME"

# ── 1. Manifest ───────────────────────────────────────────────────────────────
M_VERSION=""; M_TAG=""; M_CHECKSUM_PATCHED=""; M_CHECKSUM_TARBALL=""
M_INTERP=""; M_RPATH=""; M_ATTEST=""; M_NEEDS_PATCHELF=""
M_CHECKSUM_ALGO="$CHECKSUM_ALGO"

if [[ -f "$MANIFEST" ]]; then
  M_VERSION=$(manifest_get version "$MANIFEST")
  M_TAG=$(manifest_get tag "$MANIFEST")
  M_CHECKSUM_PATCHED=$(manifest_get binary_checksum_patched "$MANIFEST")
  M_CHECKSUM_TARBALL=$(manifest_get tarball_checksum "$MANIFEST")
  M_INTERP=$(manifest_get interpreter "$MANIFEST")
  M_RPATH=$(manifest_get rpath "$MANIFEST")
  M_ATTEST=$(manifest_get attestation "$MANIFEST")
  M_NEEDS_PATCHELF=$(manifest_get needs_patchelf "$MANIFEST")
  M_CHECKSUM_ALGO=$(manifest_get checksum_algo "$MANIFEST")
  pass "Manifest presente (versión $M_VERSION, instalado $(manifest_get installed_at "$MANIFEST"))"
else
  warn "No hay manifest en $MANIFEST"
  note "Instalación previa o manual. Reinstalá con 'bash install.sh $APP_NAME -r'."
fi

# ── 2. Binario presente y ejecutable ──────────────────────────────────────────
if [[ -f "$BIN_FILE" ]]; then
  pass "Binario presente: $BIN_FILE"
  [[ -x "$BIN_FILE" ]] && pass "Binario ejecutable" || \
    fail "Binario sin permiso de ejecución (chmod 755 $BIN_FILE)"
else
  fail "Binario NO encontrado: $BIN_FILE"
fi

# ── 3. Formato ELF ────────────────────────────────────────────────────────────
if [[ -f "$BIN_FILE" ]]; then
  if command -v file >/dev/null 2>&1; then
    FT=$(file "$BIN_FILE" 2>/dev/null || true)
    if grep -qi "ELF 64-bit.*$EXPECTED_ELF_ARCH" <<< "$FT"; then
      pass "Formato: ELF 64-bit $EXPECTED_ELF_ARCH"
    else
      fail "Formato inesperado: ${FT:-<desconocido>}"
    fi
  else
    warn "'file' no disponible; no se puede verificar el formato ELF"
  fi
fi

# ── 4. Interpreter y rpath (solo si patchelf fue aplicado) ────────────────────
_needs_patchelf="${M_NEEDS_PATCHELF:-$NEEDS_PATCHELF}"
if [[ "$_needs_patchelf" == "true" && -f "$BIN_FILE" ]]; then
  if command -v patchelf >/dev/null 2>&1; then
    EXPECTED_INTERP="${M_INTERP:-$LOADER}"
    EXPECTED_RPATH="${M_RPATH:-$GLIBC_LIB}"

    INTERP=$(patchelf --print-interpreter "$BIN_FILE" 2>/dev/null || true)
    [[ "$INTERP" == "$EXPECTED_INTERP" ]] && \
      pass "Interpreter: $INTERP" || {
        fail "Interpreter incorrecto"
        note "Esperado: $EXPECTED_INTERP"
        note "Obtenido: ${INTERP:-<vacío>}"
        note "Reaplicá con: bash install.sh $APP_NAME -r"
      }

    RP=$(patchelf --print-rpath "$BIN_FILE" 2>/dev/null || true)
    [[ "$RP" == *"$EXPECTED_RPATH"* ]] && \
      pass "Rpath: $RP" || \
      fail "Rpath incorrecto (esperado contener $EXPECTED_RPATH, obtenido: ${RP:-<vacío>})"
  else
    warn "patchelf no instalado; no se puede verificar interpreter/rpath"
  fi
fi

# ── 5. Integridad del binario post-patchelf ───────────────────────────────────
if [[ -f "$BIN_FILE" ]]; then
  if [[ -n "$M_CHECKSUM_PATCHED" ]]; then
    case "${M_CHECKSUM_ALGO:-sha256}" in
      sha256) ACTUAL=$(sha256sum "$BIN_FILE" | cut -d' ' -f1) ;;
      sha512) ACTUAL=$(sha512sum "$BIN_FILE" | cut -d' ' -f1) ;;
      *)      ACTUAL="" ;;
    esac
    [[ "$ACTUAL" == "$M_CHECKSUM_PATCHED" ]] && \
      pass "Integridad del binario OK (${M_CHECKSUM_ALGO:-sha256} ${ACTUAL:0:16}...)" || {
        fail "El binario instalado cambió desde la instalación"
        note "Registrado: $M_CHECKSUM_PATCHED"
        note "Actual:     $ACTUAL"
        note "Puede ser una actualización del stack glibc, re-patchelf o manipulación."
      }
  else
    warn "Sin checksum registrado; no se puede verificar la integridad del binario"
  fi
fi

# ── 6. Cross-check tarball contra sha256.txt (solo CHECKSUM_SOURCE=hashfile) ──
if [[ "$CHECKSUM_SOURCE" == "hashfile" && -n "$M_CHECKSUM_TARBALL" && -n "$M_TAG" ]]; then
  REG=$(lookup_hashfile "$APP_NAME/$M_TAG")
  if [[ -z "$REG" ]]; then
    warn "sha256.txt no tiene entrada para $APP_NAME/$M_TAG"
  elif [[ "$REG" == "$M_CHECKSUM_TARBALL" ]]; then
    pass "El tarball instalado coincide con sha256.txt"
  else
    fail "El checksum del tarball instalado no coincide con sha256.txt"
    note "Manifest:   $M_CHECKSUM_TARBALL"
    note "sha256.txt: $REG"
  fi
fi

# ── 7. Estado de attestation ──────────────────────────────────────────────────
case "${M_ATTEST:-}" in
  verificada)  pass "Release attestation de GitHub verificada al instalar" ;;
  fallida)     warn "La attestation no pudo verificarse al instalar" ;;
  omitida)     warn "Attestation omitida al instalar (gh no estaba disponible)"
               note "Instalá gh y reinstalá con --require-attestation para verificación criptográfica." ;;
  "no-aplica") pass "Attestation: N/A (esta herramienta no publica GitHub attestations)" ;;
  "")          : ;;
  *)           warn "Estado de attestation desconocido: ${M_ATTEST:-}" ;;
esac

# ── 8. Wrapper ────────────────────────────────────────────────────────────────
if [[ -x "$WRAPPER" ]]; then
  pass "Wrapper presente: $WRAPPER"
  if grep -q 'unset LD_PRELOAD' "$WRAPPER" && grep -q 'unset LD_LIBRARY_PATH' "$WRAPPER"; then
    pass "El wrapper limpia LD_PRELOAD y LD_LIBRARY_PATH"
  else
    fail "El wrapper no limpia LD_PRELOAD/LD_LIBRARY_PATH (riesgo de crash sobre glibc)"
  fi
else
  fail "Wrapper no encontrado o no ejecutable: $WRAPPER"
fi

# ── 9. Loader glibc y DNS ─────────────────────────────────────────────────────
[[ "$_needs_patchelf" == "true" ]] && {
  if [[ -f "$LOADER" ]]; then
    pass "Loader glibc presente: $LOADER"
  else
    fail "Loader glibc NO encontrado. Ejecutá: pkg install glibc-repo glibc-runner"
  fi

  if [[ -f "$GLIBC_PREFIX/etc/nsswitch.conf" ]]; then
    pass "nsswitch.conf presente (resolución DNS de glibc)"
  else
    warn "Falta $GLIBC_PREFIX/etc/nsswitch.conf; puede fallar la resolución DNS"
    note "Solución: printf 'hosts: files dns\n' > $GLIBC_PREFIX/etc/nsswitch.conf"
  fi
}

# ── 10. Ejecución real ────────────────────────────────────────────────────────
if [[ -x "$WRAPPER" ]]; then
  if OUT=$("$WRAPPER" --version 2>&1); then
    RUNV=$(normalize_version "$OUT")
    pass "Ejecución correcta (--version → ${RUNV:-$OUT})"
    if [[ -n "${M_VERSION:-}" && -n "$RUNV" && "$RUNV" != "$(normalize_version "$M_VERSION")" ]]; then
      fail "Versión ejecutada ($RUNV) ≠ manifest ($M_VERSION)"
    fi
  else
    fail "$APP_NAME no se pudo ejecutar"
    note "Salida: $(printf '%s' "$OUT" | head -2)"
  fi
fi

printf '\n=== Resultado: %d fallos, %d advertencias ===\n' "$FAILS" "$WARNS"
[[ "$FAILS" -gt 0 ]] && exit 1
exit 0
