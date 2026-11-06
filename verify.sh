#!/data/data/com.termux/files/usr/bin/bash

set -uo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="$PREFIX/glibc"
GLIBC_LIB="$GLIBC_PREFIX/lib"

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
    fail "Arquitectura no soportada: $(uname -m)"
    exit 1
    ;;
esac

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

if [[ $# -lt 1 ]]; then
  echo "Uso: verify.sh <herramienta>"
  echo "Herramientas disponibles:"
  for f in "$REGISTRY_DIR"/*.conf; do
    [[ -f "$f" ]] && printf '  - %s\n' "$(basename "$f" .conf)"
  done
  exit 1
fi

TOOL="$1"
if [[ ! "$TOOL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: Nombre de herramienta inválido '$TOOL'."
  exit 1
fi

CONF="$REGISTRY_DIR/$TOOL.conf"

if [[ ! -f "$CONF" ]]; then
  echo "ERROR: Herramienta desconocida '$TOOL'. Creá registry/$TOOL.conf para registrarla."
  exit 1
fi

APP_NAME=""; DISPLAY_NAME=""; ELF_NAME=""; CHECKSUM_ALGO="sha256"
CHECKSUM_SOURCE="hashfile"; NEEDS_PATCHELF=true; EXEC_DIRECT=false
ALIASES=""; EXTRA_BINS=""; WRAPPER_UNSET_ENV=""; WRAPPER_RUNNER=""
# shellcheck source=/dev/null
source "$CONF"

LIBEXEC_DIR="$PREFIX/libexec/$APP_NAME"
BIN_FILE="$LIBEXEC_DIR/$ELF_NAME"
MANIFEST="$LIBEXEC_DIR/manifest.txt"
WRAPPER="$PREFIX/bin/$APP_NAME"

printf '=== Verificación de %s en Termux ===\n\n' "$DISPLAY_NAME"

M_VERSION=""; M_TAG=""; M_CHECKSUM_PATCHED=""; M_CHECKSUM_TARBALL=""
M_INTERP=""; M_RPATH=""; M_ATTEST=""; M_NEEDS_PATCHELF=""
M_CHECKSUM_ALGO="$CHECKSUM_ALGO"
M_CHECKSUM_SOURCE=""
M_WRAPPER_RUNNER=""
M_RUNNER_CHECKSUM_SHA256=""

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
  M_CHECKSUM_SOURCE=$(manifest_get checksum_source "$MANIFEST")
  M_WRAPPER_RUNNER=$(manifest_get runner_name "$MANIFEST")
  M_RUNNER_CHECKSUM_SHA256=$(manifest_get runner_checksum_sha256 "$MANIFEST")
  pass "Manifest presente (versión $M_VERSION, instalado $(manifest_get installed_at "$MANIFEST"))"

  missing_fields=()
  [[ -n "$M_VERSION" ]]               || missing_fields+=(version)
  [[ -n "$M_TAG" ]]                   || missing_fields+=(tag)
  [[ -n "$M_CHECKSUM_PATCHED" ]]      || missing_fields+=(binary_checksum_patched)
  [[ -n "$M_CHECKSUM_ALGO" ]]         || missing_fields+=(checksum_algo)
  if [[ ${#missing_fields[@]} -gt 0 ]]; then
    fail "Manifest incompleto: faltan campos: ${missing_fields[*]}"
    note "Reinstalá con: bash install.sh $APP_NAME -r"
  fi
else
  warn "No hay manifest en $MANIFEST"
  note "Instalación previa o manual. Reinstalá con 'bash install.sh $APP_NAME -r'."
fi

if [[ -n "$WRAPPER_RUNNER" && -n "$M_WRAPPER_RUNNER" && "$M_WRAPPER_RUNNER" != "$WRAPPER_RUNNER" ]]; then
  fail "El manifest no registra el WRAPPER_RUNNER configurado ($WRAPPER_RUNNER)"
fi
if [[ -n "$M_WRAPPER_RUNNER" || -n "$WRAPPER_RUNNER" ]]; then
  if [[ -z "$M_WRAPPER_RUNNER" ]]; then
    fail "El manifest no registra el runner requerido por el registro"
  elif [[ ! "$M_WRAPPER_RUNNER" =~ ^[a-zA-Z0-9._-]+$ || "$M_WRAPPER_RUNNER" == "." || "$M_WRAPPER_RUNNER" == ".." ]]; then
    fail "Nombre de runner inválido en el manifest"
  else
    runner_file="$LIBEXEC_DIR/$M_WRAPPER_RUNNER"
    if [[ ! -f "$runner_file" || ! -x "$runner_file" || -L "$runner_file" ]]; then
      fail "Runner ausente, no ejecutable o fuera del bundle: $runner_file"
    elif [[ ! "$M_RUNNER_CHECKSUM_SHA256" =~ ^[a-f0-9]{64}$ ]]; then
      fail "Checksum SHA256 del runner ausente o inválido en el manifest"
    elif ! command -v sha256sum >/dev/null 2>&1; then
      fail "sha256sum no está disponible para verificar el runner"
    else
      runner_checksum_actual=$(sha256sum "$runner_file" | awk '{print $1}')
      if [[ "$runner_checksum_actual" == "$M_RUNNER_CHECKSUM_SHA256" ]]; then
        pass "Runner presente, ejecutable e íntegro: $M_WRAPPER_RUNNER"
      else
        fail "Checksum SHA256 incorrecto para el runner $M_WRAPPER_RUNNER"
      fi
      if [[ -x "$WRAPPER" ]] && ! grep -Fq "exec \"$runner_file\"" "$WRAPPER"; then
        fail "El wrapper no invoca el runner registrado"
      fi
    fi
  fi
fi

if [[ -f "$BIN_FILE" ]]; then
  pass "Binario presente: $BIN_FILE"
  if [[ -x "$BIN_FILE" ]]; then
    pass "Binario ejecutable"
  else
    fail "Binario sin permiso de ejecución (chmod 755 $BIN_FILE)"
  fi
else
  fail "Binario NO encontrado: $BIN_FILE"
fi

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

_needs_patchelf="${M_NEEDS_PATCHELF:-$NEEDS_PATCHELF}"
if [[ "$_needs_patchelf" == "true" && -f "$BIN_FILE" ]]; then
  if command -v patchelf >/dev/null 2>&1; then
    EXPECTED_INTERP="${M_INTERP:-$LOADER}"
    EXPECTED_RPATH="${M_RPATH:-$GLIBC_LIB}"

    INTERP=$(patchelf --print-interpreter "$BIN_FILE" 2>/dev/null || true)
    if [[ "$INTERP" == "$EXPECTED_INTERP" ]]; then
      pass "Interpreter: $INTERP"
    else
      fail "Interpreter incorrecto"
      note "Esperado: $EXPECTED_INTERP"
      note "Obtenido: ${INTERP:-<vacío>}"
      note "Reaplicá con: bash install.sh $APP_NAME -r"
    fi

    RP=$(patchelf --print-rpath "$BIN_FILE" 2>/dev/null || true)
    if [[ "$RP" == *"$EXPECTED_RPATH"* ]]; then
      pass "Rpath: $RP"
    else
      fail "Rpath incorrecto (esperado contener $EXPECTED_RPATH, obtenido: ${RP:-<vacío>})"
    fi
  else
    warn "patchelf no instalado; no se puede verificar interpreter/rpath"
  fi
fi

_verify_checksum() {
  local f="$1" expected="$2" desc="$3" actual="" algo="${M_CHECKSUM_ALGO:-sha256}"
  if [[ -z "$expected" ]]; then
    warn "Sin checksum registrado; no se puede verificar la integridad de $desc"
    note "Reinstalá con: bash install.sh $APP_NAME -r"
    return 0
  fi
  case "$algo" in
    sha256) actual=$(sha256sum "$f" | cut -d' ' -f1) ;;
    sha512) actual=$(sha512sum "$f" | cut -d' ' -f1) ;;
    *)      fail "Algoritmo de checksum desconocido en el manifest: $algo"
            return 0 ;;
  esac
  if [[ "$actual" == "$expected" ]]; then
    pass "Integridad $desc OK ($algo ${actual:0:16}...)"
  else
    fail "$desc cambió desde la instalación"
    note "Registrado: $expected"
    note "Actual:     $actual"
    note "Reinstalá con: bash install.sh $APP_NAME -r"
  fi
}

if [[ -f "$BIN_FILE" ]]; then
  _verify_checksum "$BIN_FILE" "$M_CHECKSUM_PATCHED" "del binario"
fi

M_EXTRA_BINS=""
[[ -f "$MANIFEST" ]] && M_EXTRA_BINS=$(manifest_get extra_bins "$MANIFEST")

if [[ -n "$EXTRA_BINS" && -z "$M_EXTRA_BINS" ]]; then
  warn "Manifest sin extra_bins (instalación previa a esta feature); auditoría de binarios compañeros omitida"
  note "Reinstalá con: bash install.sh $APP_NAME -r para auditar también los binarios compañeros"
elif [[ -n "$M_EXTRA_BINS" ]]; then
  for extra in $M_EXTRA_BINS; do
    extra_bin="$LIBEXEC_DIR/$extra"
    extra_wrapper="$PREFIX/bin/$extra"
    extra_sum=$(manifest_get "extra_checksum_$extra" "$MANIFEST")

    if [[ -f "$extra_bin" && -x "$extra_bin" ]]; then
      pass "Binario compañero presente y ejecutable: $extra"
      _verify_checksum "$extra_bin" "$extra_sum" "del binario compañero $extra"
    else
      fail "Binario compañero no encontrado o no ejecutable: $extra_bin"
    fi

    if [[ -x "$extra_wrapper" ]]; then
      pass "Wrapper del binario compañero: $extra_wrapper"
      if grep -q 'unset LD_PRELOAD' "$extra_wrapper" && grep -q 'unset LD_LIBRARY_PATH' "$extra_wrapper"; then
        pass "El wrapper de $extra limpia LD_PRELOAD y LD_LIBRARY_PATH"
      else
        fail "El wrapper de $extra no limpia LD_PRELOAD/LD_LIBRARY_PATH (riesgo de crash sobre glibc)"
      fi
    else
      fail "Falta wrapper del binario compañero: $extra_wrapper"
    fi
  done
fi

CHECKSUM_SOURCE_INSTALLED="${M_CHECKSUM_SOURCE:-$CHECKSUM_SOURCE}"
if [[ "$CHECKSUM_SOURCE_INSTALLED" == "hashfile" && -n "$M_CHECKSUM_TARBALL" && -n "$M_TAG" ]]; then
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

case "${M_ATTEST:-}" in
  verificada)  pass "Release attestation de GitHub verificada al instalar" ;;
  fallida)     warn "La attestation no pudo verificarse al instalar" ;;
  omitida)     warn "Attestation omitida al instalar (gh no estaba disponible)"
               note "Instalá gh y reinstalá con --require-attestation para verificación criptográfica." ;;
  "no-aplica") pass "Attestation: N/A (esta herramienta no publica GitHub attestations)" ;;
  "")          : ;;
  *)           warn "Estado de attestation desconocido: ${M_ATTEST:-}" ;;
esac

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

if [[ -n "$WRAPPER_UNSET_ENV" && -x "$WRAPPER" ]]; then
  while IFS= read -r env_name; do
    [[ -z "$env_name" || "$env_name" == \#* ]] && continue
    if [[ ! "$env_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      fail "WRAPPER_UNSET_ENV inválido en el registro"
    elif ! grep -Fxq "unset $env_name" "$WRAPPER"; then
      fail "El wrapper no limpia la variable configurada: $env_name"
    fi
  done <<< "$WRAPPER_UNSET_ENV"
fi

if [[ -n "${WRAPPER_DEFAULT_ARGS:-}" && -x "$WRAPPER" ]]; then
  _default_toks=()
  read -ra _default_toks <<< "$WRAPPER_DEFAULT_ARGS" || true
  _i=0
  for (( _i=0; _i<${#_default_toks[@]}; _i++ )); do
    if ! grep -qF -- "${_default_toks[_i]}" "$WRAPPER"; then
      warn "El wrapper no trae los args por defecto ($WRAPPER_DEFAULT_ARGS)"
      note "Reinstalá con: bash install.sh $APP_NAME -r"
      break
    fi
  done
  unset _default_toks _i
fi

M_ALIASES=""
[[ -f "$MANIFEST" ]] && M_ALIASES=$(manifest_get aliases "$MANIFEST")
[[ -n "$M_ALIASES" ]] || M_ALIASES="$ALIASES"
for alias_name in $M_ALIASES; do
  alias_target="$PREFIX/bin/$alias_name"
  if [[ -L "$alias_target" && "$(readlink "$alias_target")" == "$WRAPPER" ]]; then
    pass "Alias OK: $alias_target → $WRAPPER"
  else
    fail "Alias no encontrado o no apunta al wrapper: $alias_target"
  fi
done

EXEC_DIRECT_CONF="${EXEC_DIRECT:-false}"
M_EXEC_DIRECT=$(manifest_get exec_direct "$MANIFEST")
_EXEC_DIRECT="${M_EXEC_DIRECT:-$EXEC_DIRECT_CONF}"

if [[ "$_EXEC_DIRECT" == "true" ]]; then
  pass "Ejecución directa (EXEC_DIRECT): loader glibc y DNS de glibc N/A"
else
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

  if [[ -s "$GLIBC_PREFIX/etc/resolv.conf" ]]; then
    pass "resolv.conf de glibc presente (servidores DNS)"
  else
    warn "Falta $GLIBC_PREFIX/etc/resolv.conf; puede fallar la resolución DNS de glibc"
    note "Se regenera automáticamente al reinstalar: bash install.sh $APP_NAME -r"
  fi
fi

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
