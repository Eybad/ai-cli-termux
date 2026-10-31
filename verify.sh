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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_DIR="$SCRIPT_DIR/registry"
HASH_FILE="$SCRIPT_DIR/sha256.txt"
# shellcheck source=registry/lib/releases.sh
source "$SCRIPT_DIR/registry/lib/releases.sh"

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

# Resolver loader según arquitectura
case "$(uname -m)" in
  aarch64)
    ARCH="arm64"
    LOADER="$GLIBC_LIB/ld-linux-aarch64.so.1"
    EXPECTED_ELF_ARCH="ARM aarch64"
    ;;
  x86_64)
    ARCH="amd64"
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
if [[ ! "$TOOL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: Nombre de herramienta inválido '$TOOL'."
  exit 1
fi

CONF="$REGISTRY_DIR/$TOOL.conf"

if [[ ! -f "$CONF" ]]; then
  echo "ERROR: Herramienta desconocida '$TOOL'. Creá registry/$TOOL.conf para registrarla."
  exit 1
fi

# Cargar configuración
APP_NAME=""; DISPLAY_NAME=""; ELF_NAME=""; CHECKSUM_ALGO="sha256"
CHECKSUM_SOURCE="hashfile"; NEEDS_PATCHELF=true; EXEC_DIRECT=false
ALIASES=""; EXTRA_BINS=""; WRAPPER_UNSET_ENV=""; WRAPPER_RUNNER=""
VERSION_MAJOR=""; RELEASE_CHANNEL=""; RELEASE_POLICY_FILE=""
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
M_CHECKSUM_SOURCE=""
M_WRAPPER_RUNNER=""
M_RUNNER_CHECKSUM_SHA256=""
M_RELEASE_SEQUENCE=""
M_RELEASE_CONTRACT=""
M_RELEASE_SOURCE_COMMIT=""

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
  M_RELEASE_SEQUENCE=$(manifest_get release_sequence "$MANIFEST")
  M_RELEASE_CONTRACT=$(manifest_get release_contract "$MANIFEST")
  M_RELEASE_SOURCE_COMMIT=$(manifest_get release_source_commit "$MANIFEST")
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

if [[ -n "$RELEASE_POLICY_FILE" ]]; then
  catalog_file="$SCRIPT_DIR/$RELEASE_POLICY_FILE"
  if [[ ! "$RELEASE_POLICY_FILE" =~ ^[a-zA-Z0-9._/-]+$ || "$RELEASE_POLICY_FILE" == /* || "$RELEASE_POLICY_FILE" =~ (^|/)[.][.]?(/|$) || ! -f "$catalog_file" || -L "$catalog_file" ]]; then
    fail "Ruta de catálogo inválida o ausente en el registro"
  elif [[ -z "$VERSION_MAJOR" || "$RELEASE_CHANNEL" != stable ]]; then
    fail "La política de catálogo requiere major y canal estable"
  elif ! command -v jq >/dev/null 2>&1; then
    fail "jq no está disponible para verificar el catálogo"
  elif ! release_catalog_validate "$catalog_file" "$APP_NAME" "$VERSION_MAJOR" "$SCRIPT_DIR"; then
    fail "Catálogo de releases inválido: $RELEASE_POLICY_FILE"
  elif ! catalog_entry=$(release_catalog_entry_by_tag "$catalog_file" "$M_TAG" 2>/dev/null); then
    fail "El tag del manifest no está aprobado en el catálogo: ${M_TAG:-vacío}"
  else
    catalog_sequence=$(printf '%s' "$catalog_entry" | jq -r '.sequence // empty')
    catalog_contract=$(printf '%s' "$catalog_entry" | jq -r '.contract // empty')
    catalog_source_commit=$(printf '%s' "$catalog_entry" | jq -r '.source_commit // empty')
    catalog_asset=$(release_catalog_asset "$catalog_file" "$M_TAG" "$ARCH" 2>/dev/null || true)
    catalog_sha256=$(printf '%s' "$catalog_asset" | jq -r '.sha256 // empty')
    if [[ "$M_RELEASE_SEQUENCE" != "$catalog_sequence" || "$M_RELEASE_CONTRACT" != "$catalog_contract" || "$M_RELEASE_SOURCE_COMMIT" != "$catalog_source_commit" || "$M_CHECKSUM_TARBALL" != "$catalog_sha256" ]]; then
      fail "El manifest no coincide con la secuencia, contrato y digest del catálogo"
    else
      pass "Manifest y catálogo coherentes ($M_TAG, secuencia $M_RELEASE_SEQUENCE)"
    fi
  fi
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

# ── 2. Binario presente y ejecutable ──────────────────────────────────────────
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

# ── 5. Integridad del binario post-patchelf ───────────────────────────────────
# Helper compartido por el binario principal y los compañeros (EXTRA_BINS):
# compara el checksum actual contra el registrado en el manifest.
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

# ── 5.2. Binarios compañeros (EXTRA_BINS) ─────────────────────────────────────
# El binario principal invoca a estos por PATH (ej: kiro-cli → kiro-cli-chat).
# El manifest registra su checksum post-patchelf. La lista de extras sale del
# manifest (fuente de verdad instalada): instalaciones previas a esta feature
# no la registran y solo emiten WARN, sin auditar nada.
M_EXTRA_BINS=""
[[ -f "$MANIFEST" ]] && M_EXTRA_BINS=$(manifest_get extra_bins "$MANIFEST")

# WARN solo si el .conf ACTUAL define EXTRA_BINS y el manifest no los registra
# (instalación previa a la feature): reinstalar audita los compañeros. Un tool
# sin EXTRA_BINS tiene el manifest sin el campo por diseño — no es una
# instalación vieja y no debe emitir ruido.
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

# ── 6. Cross-check tarball contra sha256.txt (solo CHECKSUM_SOURCE=hashfile) ──
# El source se toma del manifest (si está registrado) para no depender de
# cambios posteriores en el .conf. Fallback al .conf por compatibilidad.
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

# ── 8.0. Args por defecto (WRAPPER_DEFAULT_ARGS del .conf) ──────────────────
# Si el .conf define defaults, el wrapper debe contenerlos: un wrapper de una
# instalación previa al knob los omite. Solo WARN, el CLI sigue andando.
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

# ── 8.1. Aliases (ALIASES del .conf/manifest) ─────────────────────────────────
# El manifest es la fuente de verdad instalada; fallback al .conf (mismo
# patrón que extra_bins, sección 5.2). Sin aliases → se omite: la mayoría de
# los tools no define ninguno y no debe emitir ni warning ni ruido.
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

# ── 9. Loader glibc y DNS (solo modo overlay; ejecución directa no lo usa) ─────
# EXEC_DIRECT=true: el binario corre nativo (estático musl o bionic/Android),
# sin loader glibc ni resolv.conf de glibc. Fuente de verdad: el .conf actual
# con fallback al manifest (instalaciones previas no lo registran).
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
