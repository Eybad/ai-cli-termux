#!/data/data/com.termux/files/usr/bin/bash
# install.sh — Instalador genérico de CLIs de IA en Termux (overlay glibc, sin proot)
#
# Uso: install.sh <herramienta> [opciones]
# Ejemplos:
#   install.sh opencode
#   install.sh agy
#   install.sh opencode -v 1.18.9
#   install.sh agy -r
#   install.sh opencode -u
#
# Modelo de integridad en dos capas:
#   1. Instalación: verifica el checksum del tarball (SHA256 o SHA512)
#      y, si está configurado, la release attestation firmada por GitHub.
#   2. Post-instalación: registra un manifest con el hash del binario ya
#      parcheado para que verify.sh detecte manipulación posterior.
#
# patchelf MODIFICA los bytes del binario (PT_INTERP y DT_RUNPATH), por lo
# que el hash del binario instalado nunca coincide con el del tarball.
# Por eso se registran por separado en el manifest.
#
# Para agregar una herramienta nueva: creá registry/<nombre>.conf

set -euo pipefail

# ── Constantes de entorno ──────────────────────────────────────────────────────
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="$PREFIX/glibc"
RPATH="$GLIBC_PREFIX/lib"
# LOADER se resuelve en preflight() según la arquitectura detectada.
LOADER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_DIR="$SCRIPT_DIR/registry"
HASH_FILE="$SCRIPT_DIR/sha256.txt"

# ── Colores ────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  MUTED=$'\033[0;2m'; GREEN=$'\033[0;32m'; RED=$'\033[0;31m'
  ORANGE=$'\033[38;5;214m'; NC=$'\033[0m'
else
  MUTED=''; GREEN=''; RED=''; ORANGE=''; NC=''
fi

log()  { printf '%s[%s]%s %s\n' "$MUTED" "$(date +%H:%M:%S)" "$NC" "$*"; }
info() { log "${GREEN}INFO${NC}: $*"; }
warn() { log "${ORANGE}WARN${NC}: $*" >&2; }
err()  { log "${RED}ERROR${NC}: $*" >&2; }

# ── Uso ────────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Instalador genérico de CLIs de IA para Termux (overlay glibc, sin proot)

Uso: install.sh <herramienta> [opciones]

Herramientas disponibles:
$(list_tools)

Opciones:
  -h, --help                 Mostrar esta ayuda
  -v, --version <version>    Instalar una versión específica (ej: 1.18.9)
  -u, --uninstall            Desinstalar
  -r, --reinstall            Forzar reinstalación
      --sha256 <hash>        Pinear el checksum del tarball explícitamente
      --require-attestation  Abortar si no se puede verificar la attestation
                             de GitHub (solo herramientas con ATTEST_PREDICATE)
EOF
  exit 0
}

list_tools() {
  if [[ -d "$REGISTRY_DIR" ]]; then
    for f in "$REGISTRY_DIR"/*.conf; do
      [[ -f "$f" ]] && printf '  - %s\n' "$(basename "$f" .conf)"
    done
  fi
}

# ── Argumentos ────────────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && { err "Falta el nombre de la herramienta."; usage; }

TOOL="$1"; shift

if [[ ! "$TOOL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  err "Nombre de herramienta inválido: '$TOOL'"
  exit 1
fi

REQUESTED_VERSION=""
PINNED_CHECKSUM=""
UNINSTALL=false
REINSTALL=false
REQUIRE_ATTEST=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -v|--version)
      [[ $# -ge 2 ]] || { err "--version requiere un argumento"; exit 2; }
      REQUESTED_VERSION="$2"; shift 2 ;;
    --sha256)
      [[ $# -ge 2 ]] || { err "--sha256 requiere un argumento"; exit 2; }
      PINNED_CHECKSUM="$2"; shift 2 ;;
    --require-attestation) REQUIRE_ATTEST=true; shift ;;
    -u|--uninstall) UNINSTALL=true; shift ;;
    -r|--reinstall) REINSTALL=true; shift ;;
    *)
      err "Opción desconocida: $1"
      err "Usá --help para ver las opciones."
      exit 2 ;;
  esac
done

# ── Cargar configuración de la herramienta ─────────────────────────────────────
CONF="$REGISTRY_DIR/$TOOL.conf"
if [[ ! -f "$CONF" ]]; then
  err "Herramienta desconocida: '$TOOL'"
  err "Disponibles:"
  list_tools >&2
  err "Para agregar '$TOOL': creá $REGISTRY_DIR/$TOOL.conf"
  exit 1
fi

# Variables con defaults seguros antes de cargar el .conf
APP_NAME=""; DISPLAY_NAME=""; REPO=""
RELEASE_SOURCE=""; ARCHIVE_TEMPLATE=""; MANIFEST_URL=""
MANIFEST_KEY_VERSION="version"; MANIFEST_KEY_URL="url"; MANIFEST_KEY_CHECKSUM="sha512"
CHECKSUM_ALGO="sha256"; CHECKSUM_SOURCE="hashfile"
ATTEST_PREDICATE=""; ELF_NAME=""; NEEDS_PATCHELF=true
# Overrides de nombre de arquitectura para templates de descarga.
# Cada herramienta puede definir su propio mapping si los assets usan nombres
# distintos al canónico de Termux (arm64/amd64).
ARCH_OVERRIDE_AARCH64=""
ARCH_OVERRIDE_X86_64=""
# Variables de entorno extra para el wrapper (ej: GODEBUG, SSL_CERT_FILE).
# Array asociativo no es portable en bash 3; se usa un string con newlines.
WRAPPER_ENV=""

# shellcheck source=/dev/null
source "$CONF"

# Validar campos obligatorios del .conf
for _field in APP_NAME DISPLAY_NAME RELEASE_SOURCE CHECKSUM_ALGO CHECKSUM_SOURCE ELF_NAME; do
  [[ -n "${!_field:-}" ]] || { err "$CONF: el campo '$_field' es obligatorio."; exit 1; }
done

# ── Rutas derivadas de la configuración ────────────────────────────────────────
LIBEXEC_DIR="$PREFIX/libexec/$APP_NAME"
BIN_FILE="$LIBEXEC_DIR/$ELF_NAME"
MANIFEST="$LIBEXEC_DIR/manifest.txt"
WRAPPER="$PREFIX/bin/$APP_NAME"

# ── Estado para rollback ───────────────────────────────────────────────────────
TMP_FILE=""
EXTRACT_DIR=""
BACKUP_DIR=""
FRESH_INSTALL=false
INSTALL_DONE=false
VERSION=""; TAG=""; TARBALL_CHECKSUM=""; BIN_CHECKSUM_ORIG=""; BIN_CHECKSUM_PATCHED=""
ATTEST_STATUS="omitida"

cleanup() {
  local rc=$?
  [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]]   && rm -f "$TMP_FILE"
  [[ -n "$EXTRACT_DIR" && -d "$EXTRACT_DIR" ]] && rm -rf "$EXTRACT_DIR"

  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    if [[ $rc -ne 0 && "$INSTALL_DONE" != true ]]; then
      warn "Instalación fallida ($DISPLAY_NAME): restaurando versión anterior..."
      rm -rf "$LIBEXEC_DIR"
      mv "$BACKUP_DIR" "$LIBEXEC_DIR"
    else
      rm -rf "$BACKUP_DIR"
    fi
  elif [[ $rc -ne 0 && "$INSTALL_DONE" != true && "$FRESH_INSTALL" == true ]]; then
    warn "Instalación fallida ($DISPLAY_NAME): limpiando archivos incompletos..."
    rm -rf "$LIBEXEC_DIR"
    rm -f "$WRAPPER"
  fi
  exit $rc
}
trap cleanup EXIT

# ── Helpers ───────────────────────────────────────────────────────────────────

normalize_version() {
  local out
  out=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "${1:-}" | head -1 || true)
  printf '%s' "$out"
}

lookup_hashfile() {
  local key="$1"   # ej: opencode/v1.18.9
  [[ -f "$HASH_FILE" ]] || return 0
  local res=""
  res=$(awk -v t="${key}:${ARCH}" '{ sub(/\r$/, "") } $1==t { print $2; exit }' "$HASH_FILE")
  if [[ -z "$res" ]]; then
    res=$(awk -v t="$key" '{ sub(/\r$/, "") } $1==t { print $2; exit }' "$HASH_FILE")
  fi
  printf '%s' "$res"
}

# Última versión de la herramienta registrada en sha256.txt.
# Solo considera entradas compatibles con la arquitectura actual:
#   tool/vX.Y.Z            (genérica, sirve para cualquier arch)
#   tool/vX.Y.Z:$ARCH      (específica de la arquitectura detectada)
# Requiere que ARCH esté resuelto (preflight corrió antes).
latest_hashfile_version() {
  [[ -f "$HASH_FILE" ]] || return 0
  awk -v app="$APP_NAME" -v arch="${ARCH:-}" '
    {
      sub(/\r$/, "")
      if ($1 !~ "^" app "/v[0-9]+\\.[0-9]+\\.[0-9]+($|:" arch "$)") next
      v = $1
      sub("^" app "/v", "", v)
      sub(":.*$", "", v)
      print v
    }' "$HASH_FILE" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

# Parser JSON: usa jq (dependencia obligatoria verificada en preflight).
json_get() {
  local payload="$1" key="$2"
  printf '%s' "$payload" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null
}

manifest_get() {
  local key="$1"
  [[ -f "$MANIFEST" ]] || return 0
  awk -F= -v k="$key" '{ sub(/\r$/, "") } $1==k { sub(/^[^=]*=/,""); print; exit }' "$MANIFEST"
}

checksum_of() {
  case "$CHECKSUM_ALGO" in
    sha256) sha256sum "$1" | cut -d' ' -f1 ;;
    sha512) sha512sum "$1" | cut -d' ' -f1 ;;
    *) err "Algoritmo de checksum desconocido: $CHECKSUM_ALGO"; exit 1 ;;
  esac
}

expand_template() {
  local tmpl="$1"
  # Resolver el arch label para esta herramienta: si el .conf definió un
  # override para la arquitectura actual, usarlo; si no, usar ARCH canónico.
  local arch_label="$ARCH"
  case "$(uname -m)" in
    aarch64) [[ -n "$ARCH_OVERRIDE_AARCH64" ]] && arch_label="$ARCH_OVERRIDE_AARCH64" ;;
    x86_64)  [[ -n "$ARCH_OVERRIDE_X86_64" ]]  && arch_label="$ARCH_OVERRIDE_X86_64" ;;
  esac
  tmpl="${tmpl//\{VERSION\}/$VERSION}"
  tmpl="${tmpl//\{ARCH\}/$arch_label}"
  tmpl="${tmpl//\{PLATFORM\}/linux_${arch_label}}"
  printf '%s' "$tmpl"
}

# ── Paso 1: Preflight ─────────────────────────────────────────────────────────
preflight() {
  if [[ ! -d /data/data/com.termux ]]; then
    err "Esto solo funciona en Termux (no se detectó /data/data/com.termux)."
    exit 1
  fi
  case "$(uname -m)" in
    aarch64) ARCH="arm64" ;;
    x86_64)  ARCH="amd64" ;;
    *)
      err "Arquitectura no soportada: $(uname -m). Se soporta aarch64 y x86_64."
      exit 1 ;;
  esac

  # Resolver el loader glibc según la arquitectura detectada
  case "$ARCH" in
    arm64)
      LOADER="$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1"
      EXPECTED_ELF_ARCH="ARM aarch64"
      ;;
    amd64)
      LOADER="$GLIBC_PREFIX/lib/ld-linux-x86-64.so.2"
      EXPECTED_ELF_ARCH="x86-64"
      ;;
  esac

  local missing=()
  for c in curl tar awk jq; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  command -v sha256sum >/dev/null 2>&1 || missing+=(sha256sum)
  if [[ "$CHECKSUM_ALGO" == "sha512" ]]; then
    command -v sha512sum >/dev/null 2>&1 || missing+=(sha512sum)
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Faltan herramientas: ${missing[*]}"
    err "Instalá con: pkg install curl tar coreutils gawk jq"
    exit 1
  fi
}

uninstall() {
  info "Desinstalando $DISPLAY_NAME..."
  rm -rf "$LIBEXEC_DIR"
  rm -f "$WRAPPER"
  info "$DISPLAY_NAME eliminado."
  info "Para remover dependencias si no las necesitás: pkg remove glibc-runner patchelf glibc-repo"
  exit 0
}

[[ "$UNINSTALL" == true ]] && uninstall

# ── Paso 2: Resolver versión ───────────────────────────────────────────────────
resolve_version() {
  case "$RELEASE_SOURCE" in

    github)
      if [[ -n "$REQUESTED_VERSION" ]]; then
        VERSION=$(normalize_version "$REQUESTED_VERSION")
        [[ -n "$VERSION" ]] || { err "Versión inválida: '$REQUESTED_VERSION'"; exit 2; }
      else
        local body code auth_header=()
        local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
        [[ -n "$token" ]] && auth_header=(-H "Authorization: Bearer $token")
        body=$(mktemp)
        code=$(curl -sS --proto '=https' --tlsv1.2 -L \
                 --connect-timeout 10 --max-time 300 \
                 -H 'Accept: application/vnd.github+json' \
                 "${auth_header[@]}" \
                 -o "$body" -w '%{http_code}' \
                 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || echo 000)
        case "$code" in
          200) : ;;
          403|429) err "GitHub API: HTTP $code (rate limit). Usá -v <version>"; rm -f "$body"; exit 1 ;;
          000)     err "Sin conexión a GitHub API. Usá -v <version>"; rm -f "$body"; exit 1 ;;
          *)       err "GitHub API: HTTP $code. Usá -v <version>"; rm -f "$body"; exit 1 ;;
        esac
        local raw
        raw=$(jq -r '.tag_name // empty' "$body" 2>/dev/null || true)
        rm -f "$body"
        VERSION=$(normalize_version "$raw")
        [[ -n "$VERSION" ]] || { err "No se pudo extraer la versión de GitHub API"; exit 1; }
      fi
      TAG="v$VERSION"
      ;;

    manifest_json)
      # La versión la provee el manifest remoto de Google.
      # Si se pasó -v, se usa solo para verificación post-descarga.
      local expanded_url
      expanded_url=$(expand_template "$MANIFEST_URL")
      info "Consultando manifest remoto..."
      local manifest_json
      manifest_json=$(curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 "$expanded_url" 2>/dev/null || true)
      [[ -n "$manifest_json" ]] || { err "No se pudo descargar el manifest desde $expanded_url"; exit 1; }

      VERSION=$(json_get "$manifest_json" "$MANIFEST_KEY_VERSION")
      DOWNLOAD_URL=$(json_get "$manifest_json" "$MANIFEST_KEY_URL")
      REMOTE_CHECKSUM=$(json_get "$manifest_json" "$MANIFEST_KEY_CHECKSUM")

      [[ -n "$VERSION" && -n "$DOWNLOAD_URL" && -n "$REMOTE_CHECKSUM" ]] || {
        err "El manifest remoto está incompleto o malformado."
        err "  version: ${VERSION:-(vacío)}"
        err "  url:     ${DOWNLOAD_URL:-(vacío)}"
        err "  checksum: ${REMOTE_CHECKSUM:-(vacío)}"
        exit 1
      }

      if [[ -n "$REQUESTED_VERSION" ]]; then
        local req
        req=$(normalize_version "$REQUESTED_VERSION")
        [[ "$req" == "$VERSION" ]] || {
          warn "La versión disponible ($VERSION) no coincide con la solicitada ($req)."
          warn "Solo está disponible la última versión en el manifest de Google."
        }
      fi
      TAG="v$VERSION"
      ;;

    url_template)
      if [[ -n "$REQUESTED_VERSION" ]]; then
        VERSION=$(normalize_version "$REQUESTED_VERSION")
        [[ -n "$VERSION" ]] || { err "Versión inválida: '$REQUESTED_VERSION'"; exit 2; }
      else
        VERSION=$(latest_hashfile_version)
        if [[ -z "$VERSION" ]]; then
          err "$DISPLAY_NAME: no hay ninguna versión registrada en $HASH_FILE."
          err "Agregá el hash de la versión actual (ver update-hashes.yml) o usá -v <version>."
          exit 1
        fi
        info "$DISPLAY_NAME: usando última versión registrada ($VERSION)."
      fi
      TAG="v$VERSION"
      ;;

    *)
      err "RELEASE_SOURCE desconocido en $CONF: '$RELEASE_SOURCE'"
      exit 1
      ;;
  esac

  info "Versión objetivo: $VERSION ($DISPLAY_NAME)"
}

# ── Paso 3: Resolver checksum esperado ────────────────────────────────────────
resolve_expected_checksum() {
  if [[ -n "$PINNED_CHECKSUM" ]]; then
    EXPECTED_CHECKSUM=$(printf '%s' "$PINNED_CHECKSUM" | tr 'A-F' 'a-f' | tr -d '[:space:]')
    warn "Usando checksum pasado con --sha256 (verificalo vos mismo)."
  else
    case "$CHECKSUM_SOURCE" in
      hashfile)
        EXPECTED_CHECKSUM=$(lookup_hashfile "$APP_NAME/$TAG")
        if [[ -z "$EXPECTED_CHECKSUM" ]]; then
          err "No hay $CHECKSUM_ALGO registrado para $APP_NAME/$TAG en $HASH_FILE."
          [[ ! -f "$HASH_FILE" ]] && err "Tampoco existe $HASH_FILE (¿clonaste el repo completo?)."
          err ""
          err "Fail-closed: no se instala sin verificar. Opciones:"
          err "  1. Agregá el hash a sha256.txt (instrucciones dentro del archivo)."
          err "  2. Instalá una versión registrada: -v <version>"
          err "  3. Pineá el hash: --sha256 <hash>"
          exit 1
        fi
        ;;
      manifest)
        # Ya se obtuvo en resolve_version() al descargar el manifest JSON
        EXPECTED_CHECKSUM="${REMOTE_CHECKSUM:-}"
        [[ -n "$EXPECTED_CHECKSUM" ]] || { err "El manifest remoto no tiene checksum"; exit 1; }
        ;;
      *)
        err "CHECKSUM_SOURCE desconocido en $CONF: '$CHECKSUM_SOURCE'"
        exit 1 ;;
    esac
  fi

  # Validar formato: 64 hex (sha256) o 128 hex (sha512).
  # Aplica también al checksum pineado con --sha256 (fail-closed).
  local expected_len
  case "$CHECKSUM_ALGO" in sha256) expected_len=64 ;; sha512) expected_len=128 ;; esac
  if [[ ! "$EXPECTED_CHECKSUM" =~ ^[0-9a-f]{${expected_len}}$ ]]; then
    err "El checksum esperado no tiene el formato correcto ($CHECKSUM_ALGO, ${expected_len} chars hex):"
    err "  '$EXPECTED_CHECKSUM'"
    exit 1
  fi
}

# ── Paso 4: Verificar versión instalada ────────────────────────────────────────
check_current() {
  [[ "$REINSTALL" == true ]] && return 0

  local installed
  installed=$(normalize_version "$(manifest_get version)")
  if [[ -z "$installed" && -x "$WRAPPER" ]]; then
    installed=$(normalize_version "$("$WRAPPER" --version 2>/dev/null || true)")
  fi

  if [[ -n "$installed" && "$installed" == "$VERSION" && -x "$BIN_FILE" && -x "$WRAPPER" ]]; then
    info "$DISPLAY_NAME $VERSION ya está instalado. Usá -r para reinstalar."
    exit 0
  fi
  [[ -n "$installed" ]] && info "Versión instalada: $installed → actualizando a $VERSION"
  return 0
}

# ── Paso 5: Dependencias ──────────────────────────────────────────────────────
install_deps() {
  info "Instalando dependencias (glibc-repo, glibc-runner, patchelf, file, jq, curl)..."
  pkg update -y >/dev/null 2>&1 || warn "pkg update falló; continuando con índices actuales."
  local deps=(glibc-repo glibc-runner file jq curl)
  [[ "$NEEDS_PATCHELF" == true ]] && deps+=(patchelf)
  if ! pkg install "${deps[@]}" -y; then
    err "Falló la instalación de dependencias."
    err "Verificá que Termux esté actualizado: pkg update && pkg upgrade"
    exit 1
  fi
  if [[ "$NEEDS_PATCHELF" == true && ! -f "$LOADER" ]]; then
    err "Loader glibc no encontrado: $LOADER"
    err "Ejecutá: pkg install glibc-repo glibc-runner"
    exit 1
  fi
  info "Loader glibc: $LOADER"
}

# ── Paso 6: Descarga ──────────────────────────────────────────────────────────
download() {
  local url
  case "$RELEASE_SOURCE" in
    github)
      local archive_name
      archive_name=$(expand_template "$ARCHIVE_TEMPLATE")
      url="https://github.com/$REPO/releases/download/$TAG/$archive_name"
      ;;
    manifest_json)
      url="$DOWNLOAD_URL"
      ;;
    url_template)
      url=$(expand_template "$DOWNLOAD_URL_TEMPLATE")
      ;;
  esac

  local tmp_dir="${TMPDIR:-$PREFIX/tmp}"
  mkdir -p "$tmp_dir"
  TMP_FILE=$(mktemp "$tmp_dir/$APP_NAME-install-XXXXXX.tar.gz")

  info "Descargando $DISPLAY_NAME $VERSION..."
  if ! curl -fL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 -o "$TMP_FILE" "$url"; then
    err "Falló la descarga desde $url"
    exit 1
  fi
}

# ── Paso 7: Verificar tarball ─────────────────────────────────────────────────
verify_tarball() {
  TARBALL_CHECKSUM=$(checksum_of "$TMP_FILE")
  if [[ "$TARBALL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]]; then
    err "${CHECKSUM_ALGO^^} MISMATCH del tarball!"
    err "  Esperado: $EXPECTED_CHECKSUM"
    err "  Obtenido: $TARBALL_CHECKSUM"
    err "No se instala nada."
    exit 1
  fi
  info "${CHECKSUM_ALGO^^} del tarball verificado: ${TARBALL_CHECKSUM:0:24}..."

  if ! file "$TMP_FILE" 2>/dev/null | grep -qi 'gzip compressed'; then
    err "El archivo descargado no es un tarball gzip:"
    file "$TMP_FILE" >&2 || true
    exit 1
  fi
}

# ── Paso 8: Attestation (solo para herramientas con ATTEST_PREDICATE) ─────────
verify_attestation() {
  ATTEST_STATUS="no-aplica"
  [[ -z "$ATTEST_PREDICATE" ]] && return 0

  ATTEST_STATUS="omitida"
  if ! command -v gh >/dev/null 2>&1; then
    [[ "$REQUIRE_ATTEST" == true ]] && {
      err "--require-attestation pero gh no está instalado: pkg install gh"
      exit 1
    }
    info "gh no instalado: se omite la attestation (pkg install gh para habilitarla)."
    return 0
  fi

  info "Verificando release attestation de GitHub..."
  local out
  if out=$(gh attestation verify "$TMP_FILE" \
             --repo "$REPO" \
             --predicate-type "$ATTEST_PREDICATE" 2>&1); then
    ATTEST_STATUS="verificada"
    info "Attestation válida: tarball publicado por $REPO."
    return 0
  fi

  ATTEST_STATUS="fallida"
  [[ "$REQUIRE_ATTEST" == true ]] && {
    err "Falló la verificación de la attestation:"
    printf '%s\n' "$out" >&2
    exit 1
  }
  warn "No se pudo verificar la attestation (¿gh sin autenticar?)."
  warn "El checksum ya fue verificado; continuando."
  warn "Detalle: $(printf '%s' "$out" | head -1)"
}

# ── Paso 9: Extraer e instalar ────────────────────────────────────────────────
extract_install() {
  local tmp_dir="${TMPDIR:-$PREFIX/tmp}"
  EXTRACT_DIR=$(mktemp -d "$tmp_dir/$APP_NAME-extract-XXXXXX")
  tar -xzf "$TMP_FILE" -C "$EXTRACT_DIR"
  rm -f "$TMP_FILE"; TMP_FILE=""

  # Buscar el binario ELF por nombre exacto y arquitectura
  local found=""
  local cand
  while IFS= read -r cand; do
    if file "$cand" 2>/dev/null | grep -qi "ELF 64-bit.*$EXPECTED_ELF_ARCH"; then
      found="$cand"; break
    fi
  done < <(find "$EXTRACT_DIR" -type f -name "$ELF_NAME" 2>/dev/null)

  if [[ -z "$found" ]]; then
    err "No se encontró un ELF 64-bit ($EXPECTED_ELF_ARCH) llamado '$ELF_NAME' en el tarball."
    err "Contenido del tarball:"
    find "$EXTRACT_DIR" -type f 2>/dev/null | head -20 >&2
    exit 1
  fi

  BIN_CHECKSUM_ORIG=$(checksum_of "$found")
  info "Binario localizado (${CHECKSUM_ALGO} original: ${BIN_CHECKSUM_ORIG:0:16}...)"

  # Respaldar instalación previa para rollback
  if [[ -d "$LIBEXEC_DIR" ]]; then
    BACKUP_DIR="$(dirname "$LIBEXEC_DIR")/.$APP_NAME.backup.$$"
    rm -rf "$BACKUP_DIR"
    mv "$LIBEXEC_DIR" "$BACKUP_DIR"
  else
    FRESH_INSTALL=true
  fi

  mkdir -p "$LIBEXEC_DIR"
  local root; root=$(dirname "$found")
  cp -a "$root/." "$LIBEXEC_DIR/"
  # El binario puede tener nombre diferente a APP_NAME (ej: antigravity → agy)
  if [[ ! -f "$BIN_FILE" ]]; then
    cp -a "$found" "$BIN_FILE"
  fi
  chmod 755 "$BIN_FILE"
  rm -rf "$EXTRACT_DIR"; EXTRACT_DIR=""
  info "Binario instalado en $BIN_FILE"
}

# ── Paso 10: patchelf ─────────────────────────────────────────────────────────
patch_interpreter() {
  [[ "$NEEDS_PATCHELF" == true ]] || return 0

  info "Aplicando patchelf (interpreter + rpath → overlay glibc)..."
  patchelf --set-interpreter "$LOADER" --set-rpath "$RPATH" "$BIN_FILE" || {
    err "Falló patchelf sobre $BIN_FILE"; exit 1
  }

  local got_interp got_rpath
  got_interp=$(patchelf --print-interpreter "$BIN_FILE" 2>/dev/null || true)
  got_rpath=$(patchelf --print-rpath "$BIN_FILE" 2>/dev/null || true)

  [[ "$got_interp" == "$LOADER" ]] || {
    err "patchelf no aplicó el interpreter correctamente."
    err "  Esperado: $LOADER"; err "  Obtenido: ${got_interp:-<vacío>}"; exit 1
  }
  [[ "$got_rpath" == *"$RPATH"* ]] || {
    err "patchelf no aplicó el rpath correctamente."
    err "  Esperado contener: $RPATH"; err "  Obtenido: ${got_rpath:-<vacío>}"; exit 1
  }

  BIN_CHECKSUM_PATCHED=$(checksum_of "$BIN_FILE")
  info "Interpreter y rpath verificados."
}

# ── Paso 11: nsswitch.conf (DNS de glibc) ─────────────────────────────────────
ensure_nsswitch() {
  local ns="$GLIBC_PREFIX/etc/nsswitch.conf"
  [[ -f "$ns" ]] && return 0
  mkdir -p "$(dirname "$ns")"
  printf 'hosts: files dns\n' > "$ns"
  info "Creado $ns (resolución DNS de glibc)."
}

# ── Paso 12: Hook pre-wrapper ─────────────────────────────────────────────────
run_pre_wrapper_hook() {
  if declare -f pre_wrapper_hook >/dev/null 2>&1; then
    info "Ejecutando pre_wrapper_hook..."
    pre_wrapper_hook
  fi
}

# ── Paso 13: Crear wrapper ────────────────────────────────────────────────────
create_wrapper() {
  mkdir -p "$(dirname "$WRAPPER")"

  # Construir bloque de exports para variables de entorno del .conf
  local env_block=""
  if [[ -n "$WRAPPER_ENV" ]]; then
    local line var_name var_val
    while IFS= read -r line; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
        var_name="${BASH_REMATCH[1]}"
        var_val="${BASH_REMATCH[2]}"
        env_block+="export ${var_name}=${var_val@Q}"$'\n'
      fi
    done <<< "$WRAPPER_ENV"
  fi

  local exec_cmd="exec \"\$BIN\" \"\$@\""
  if [[ "$NEEDS_PATCHELF" == false ]]; then
    exec_cmd="exec \"$LOADER\" --library-path \"$RPATH\" \"\$BIN\" \"\$@\""
  fi

  # El wrapper siempre se llama APP_NAME; el binario interno puede ser ELF_NAME
  cat > "$WRAPPER" <<WRAPPER_EOF
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

BIN="$BIN_FILE"

if [[ ! -f "\$BIN" ]]; then
  echo "ERROR: $DISPLAY_NAME no encontrado en \$BIN" >&2
  echo "Reinstalá con: bash install.sh $APP_NAME -r" >&2
  exit 1
fi
if [[ "$NEEDS_PATCHELF" == true && ! -x "\$BIN" ]]; then
  echo "ERROR: $DISPLAY_NAME sin permiso de ejecución en \$BIN" >&2
  echo "Reinstalá con: bash install.sh $APP_NAME -r" >&2
  exit 1
fi

# libtermux-exec.so es bionic: precargarla en un proceso glibc lo crashea.
# Contrapartida: se pierde el hook execve() que reescribe shebangs.
unset LD_PRELOAD
# LD_LIBRARY_PATH heredada apuntando a bionic → segfault al enlazar glibc.
unset LD_LIBRARY_PATH

# Variables de entorno específicas de esta herramienta (definidas en el .conf)
${env_block}
${exec_cmd}
WRAPPER_EOF
  chmod 755 "$WRAPPER"
  info "Wrapper creado en $WRAPPER"
}

# ── Paso 14: Escribir manifest ────────────────────────────────────────────────
write_manifest() {
  cat > "$MANIFEST" <<EOF
# Generado por install.sh. No editar a mano.
# verify.sh compara el estado instalado contra estos valores.
manifest_version=2
app=$APP_NAME
display_name=$DISPLAY_NAME
elf_name=$ELF_NAME
version=$VERSION
tag=$TAG
release_source=$RELEASE_SOURCE
checksum_algo=$CHECKSUM_ALGO
checksum_source=$CHECKSUM_SOURCE
tarball_checksum=$TARBALL_CHECKSUM
binary_checksum_original=$BIN_CHECKSUM_ORIG
binary_checksum_patched=${BIN_CHECKSUM_PATCHED:-${BIN_CHECKSUM_ORIG}}
needs_patchelf=$NEEDS_PATCHELF
interpreter=${LOADER}
rpath=${RPATH}
attestation=$ATTEST_STATUS
installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 644 "$MANIFEST"
  info "Manifest de integridad escrito en $MANIFEST"
}

# ── Paso 15: Verificar instalación ────────────────────────────────────────────
verify_install() {
  info "Verificando la instalación..."
  local out
  if ! out=$("$WRAPPER" --version 2>&1); then
    err "El wrapper no pudo ejecutar $DISPLAY_NAME."
    err "Salida: $(printf '%s' "$out" | head -3)"
    err "Probá cerrar y reabrir Termux, o revisá 'bash verify.sh $APP_NAME'."
    exit 1
  fi
  local got
  got=$(normalize_version "$out")
  [[ -n "$got" && "$got" != "$VERSION" ]] && \
    warn "Versión reportada ($got) ≠ esperada ($VERSION)."
  INSTALL_DONE=true
  info "$DISPLAY_NAME ${got:-$VERSION} funcionando correctamente."
}

# ── Paso 16: Resumen ──────────────────────────────────────────────────────────
show_summary() {
  local attest_display="$ATTEST_STATUS"
  [[ "$ATTEST_STATUS" == "no-aplica" ]] && attest_display="N/A (sin attestation configurada)"

  printf '\n'
  printf '%s%s %s instalado en Termux (overlay glibc, sin proot)%s\n' \
    "$GREEN" "$DISPLAY_NAME" "$VERSION" "$NC"
  printf '\n'
  printf '%sIntegridad:%s\n' "$MUTED" "$NC"
  printf '  tarball %-7s  %s\n' "$CHECKSUM_ALGO" "$TARBALL_CHECKSUM"
  printf '  attestation      %s\n' "$attest_display"
  printf '\n'
  printf '%sUso:%s  %s%s%s\n' "$MUTED" "$NC" "$GREEN" "$APP_NAME" "$NC"
  printf '\n'
  printf '%sVerificar:  bash verify.sh %s%s\n' "$MUTED" "$APP_NAME" "$NC"
}

# ── Hook post-install ─────────────────────────────────────────────────────────
run_post_install_hook() {
  if declare -f post_install_hook >/dev/null 2>&1; then
    info "Ejecutando post_install_hook..."
    post_install_hook
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  preflight
  resolve_version
  resolve_expected_checksum
  check_current
  install_deps
  download
  verify_tarball
  verify_attestation
  extract_install
  patch_interpreter
  ensure_nsswitch
  run_pre_wrapper_hook
  create_wrapper
  # El manifest se escribe DESPUÉS de verificar la instalación.
  # Si se escribiera antes, una instalación fallida dejaría un manifest válido
  # y la próxima corrida la tomaría por buena.
  verify_install
  write_manifest
  run_post_install_hook
  show_summary
}

main
