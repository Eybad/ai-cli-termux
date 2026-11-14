#!/data/data/com.termux/files/usr/bin/bash

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
GLIBC_PREFIX="$PREFIX/glibc"
RPATH="$GLIBC_PREFIX/lib"
LOADER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY_DIR="$SCRIPT_DIR/registry"
HASH_FILE="$SCRIPT_DIR/sha256.txt"
# shellcheck source=registry/lib/releases.sh disable=SC1091
source "$SCRIPT_DIR/registry/lib/releases.sh"

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

usage() {
  cat <<EOF
Generic installer for AI CLIs on Termux (glibc overlay, no PRoot)

Usage: install.sh <tool> [options]

Available tools:
$(list_tools)

Options:
  -h, --help                 Show this help message
  -v, --version <version>    Install a specific version
                             (e.g., 1.18.9; accepts -prerelease/+build, e.g., 0.146.0+android1)
  -u, --uninstall            Uninstall
  -r, --reinstall            Force reinstallation
      --update               Update to the latest available version if an earlier
                             version is already installed
      --sha256 <hash>        Pin tarball checksum explicitly
      --require-attestation  Abort if GitHub release attestation cannot be verified
                             (only for tools with ATTEST_PREDICATE)
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

[[ $# -lt 1 ]] && { err "Missing tool name."; usage; }

TOOL="$1"; shift

if [[ ! "$TOOL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  err "Invalid tool name: '$TOOL'"
  exit 1
fi

REQUESTED_VERSION=""
PINNED_CHECKSUM=""
UNINSTALL=false
REINSTALL=false
REQUIRE_ATTEST=false
UPDATE=false
RESOLVE_VERSION=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage ;;
    -v|--version)
      [[ $# -ge 2 ]] || { err "--version requires an argument"; exit 2; }
      REQUESTED_VERSION="$2"; shift 2 ;;
    --sha256)
      [[ $# -ge 2 ]] || { err "--sha256 requires an argument"; exit 2; }
      PINNED_CHECKSUM="$2"; shift 2 ;;
    --require-attestation) REQUIRE_ATTEST=true; shift ;;
    -u|--uninstall) UNINSTALL=true; shift ;;
    -r|--reinstall) REINSTALL=true; shift ;;
    --update) UPDATE=true; shift ;;
    --resolve-version) RESOLVE_VERSION=true; shift ;;
    *)
      err "Unknown option: $1"
      err "Use --help to see available options."
      exit 2 ;;
  esac
done

[[ "$UPDATE" != true || -z "$REQUESTED_VERSION" ]] || {
  err "--update is incompatible with -v (--update always targets the latest version)."
  exit 2
}

if [[ "$RESOLVE_VERSION" == true ]]; then
  bad=""
  [[ "$UNINSTALL" == true ]] && bad+=" -u"
  [[ "$REINSTALL" == true ]] && bad+=" -r"
  [[ "$UPDATE" == true ]] && bad+=" --update"
  [[ -n "$REQUESTED_VERSION" ]] && bad+=" -v"
  [[ -n "$PINNED_CHECKSUM" ]] && bad+=" --sha256"
  if [[ -n "$bad" ]]; then
    err "--resolve-version (internal machine interface) is incompatible with:$bad"
    err "Contract: print 'TARGET_VERSION=<version>' on stdout and nothing else."
    exit 2
  fi
fi

CONF="$REGISTRY_DIR/$TOOL.conf"
if [[ ! -f "$CONF" ]]; then
  err "Unknown tool: '$TOOL'"
  err "Available:"
  list_tools >&2
  err "To add '$TOOL': create $REGISTRY_DIR/$TOOL.conf"
  exit 1
fi

APP_NAME=""; DISPLAY_NAME=""; REPO=""
RELEASE_SOURCE=""; ARCHIVE_TEMPLATE=""; MANIFEST_URL=""
VERSION_MAJOR=""; RELEASE_CHANNEL=""
DOWNLOAD_MAX_TIME=300
MANIFEST_URL_AARCH64=""; MANIFEST_URL_X86_64=""
MANIFEST_KEY_VERSION="version"; MANIFEST_KEY_URL="url"; MANIFEST_KEY_CHECKSUM="sha512"
CHECKSUM_ALGO="sha256"; CHECKSUM_SOURCE="hashfile"
ATTEST_PREDICATE=""; ATTEST_REPO=""; ELF_NAME=""; NEEDS_PATCHELF=true
EXEC_DIRECT=false
ARCH_OVERRIDE_AARCH64=""
ARCH_OVERRIDE_X86_64=""
WRAPPER_ENV=""
WRAPPER_UNSET_ENV=""
WRAPPER_RUNNER=""
DOWNLOAD_URL=""
EXTRA_BINS=""
ENTRY_POINT=""
ALIASES=""
WRAPPER_DENY_ARGS=""
WRAPPER_DEFAULT_ARGS=""

# shellcheck source=/dev/null
source "$CONF"

if [[ ! "$DOWNLOAD_MAX_TIME" =~ ^[1-9][0-9]{0,4}$ ]]; then
  err "$CONF: DOWNLOAD_MAX_TIME must be an integer between 1 and 99999 seconds."
  exit 1
fi

if ! release_policy_fields_valid "$VERSION_MAJOR" "$RELEASE_CHANNEL"; then
  err "$CONF: VERSION_MAJOR must be a canonical decimal integer and RELEASE_CHANNEL must be empty or stable."
  exit 1
fi

for _field in APP_NAME DISPLAY_NAME RELEASE_SOURCE CHECKSUM_ALGO CHECKSUM_SOURCE ELF_NAME; do
  [[ -n "${!_field:-}" ]] || { err "$CONF: field '$_field' is required."; exit 1; }
done

_name_is_valid() {
  [[ "$1" =~ ^[a-zA-Z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]
}
for _field in APP_NAME ELF_NAME; do
  _name_is_valid "${!_field}" || {
    err "$CONF: '$_field' invalid: '${!_field}' (only [a-zA-Z0-9._-], no '.' or '..')."
    exit 1
  }
done
if [[ -n "$WRAPPER_RUNNER" ]]; then
  _name_is_valid "$WRAPPER_RUNNER" || {
    err "$CONF: WRAPPER_RUNNER invalid: '$WRAPPER_RUNNER' (must be a safe basename)."
    exit 1
  }
fi
while IFS= read -r _env_name; do
  [[ -z "$_env_name" || "$_env_name" == \#* ]] && continue
  [[ "$_env_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || {
    err "$CONF: WRAPPER_UNSET_ENV invalid: '$_env_name' (must contain valid environment identifiers)."
    exit 1
  }
done <<< "$WRAPPER_UNSET_ENV"
for _bad in '"' "'" '$' '`'; do
  if printf '%s' "$DISPLAY_NAME" | grep -qF "$_bad"; then
    err "$CONF: DISPLAY_NAME invalid: contains quotes, \$, backticks, or control characters."
    exit 1
  fi
done
  # Match newline via case pattern; grep -F with \n is treated as multiple empty patterns.
case "$DISPLAY_NAME" in
  *$'\n'*|*$'\r'*|*[$'\x01'-$'\x1f'$'\x7f']*)
    err "$CONF: DISPLAY_NAME invalid: contains quotes, \$, backticks, or control characters."
    exit 1 ;;
esac

if [[ -n "$EXTRA_BINS" ]]; then
  if [[ "$NEEDS_PATCHELF" != true ]]; then
    err "$CONF: EXTRA_BINS requires NEEDS_PATCHELF=true (companion binaries also require the glibc overlay)."
    exit 1
  fi
  for _extra in $EXTRA_BINS; do
    _name_is_valid "$_extra" || {
      err "$CONF: EXTRA_BINS invalid: '$_extra' (only [a-zA-Z0-9._-], no '.' or '..')."
      exit 1
    }
  done
fi

if [[ -n "$ENTRY_POINT" ]]; then
  _name_is_valid "$ENTRY_POINT" || {
    err "$CONF: ENTRY_POINT invalid: '$ENTRY_POINT' (only [a-zA-Z0-9._-], no '.' or '..')."
    exit 1
  }
  if [[ "$NEEDS_PATCHELF" != true ]]; then
    err "$CONF: ENTRY_POINT requires NEEDS_PATCHELF=true (the script launches the glibc overlay ELF)."
    exit 1
  fi
fi

if [[ -n "$ALIASES" ]]; then
  for _alias in $ALIASES; do
    _name_is_valid "$_alias" || {
      err "$CONF: ALIASES invalid: '$_alias' (only [a-zA-Z0-9._-], no '.' or '..')."
      exit 1
    }
    if [[ "$_alias" == "$APP_NAME" ]]; then
      err "$CONF: ALIASES cannot repeat APP_NAME ('$APP_NAME' is already the wrapper)."
      exit 1
    fi
  done
fi

if [[ "$EXEC_DIRECT" == true && "$NEEDS_PATCHELF" == true ]]; then
  err "$CONF: EXEC_DIRECT=true requires NEEDS_PATCHELF=false (binary runs natively, without glibc overlay)."
  exit 1
fi

case "$RELEASE_SOURCE" in
  github)
    [[ -n "$REPO" && -n "$ARCHIVE_TEMPLATE" ]] || {
      err "$CONF: RELEASE_SOURCE=github requires REPO and ARCHIVE_TEMPLATE."; exit 1; }
    ;;
  manifest_json)
    [[ -n "$MANIFEST_URL$MANIFEST_URL_AARCH64$MANIFEST_URL_X86_64" ]] || {
      err "$CONF: RELEASE_SOURCE=manifest_json requires MANIFEST_URL (or MANIFEST_URL_AARCH64/_X86_64)."; exit 1; }
    ;;
  url_template)
    [[ -n "$DOWNLOAD_URL_TEMPLATE" ]] || {
      err "$CONF: RELEASE_SOURCE=url_template requires DOWNLOAD_URL_TEMPLATE."; exit 1; }
    ;;
esac

LIBEXEC_DIR="$PREFIX/libexec/$APP_NAME"
BIN_FILE="$LIBEXEC_DIR/$ELF_NAME"
MANIFEST="$LIBEXEC_DIR/manifest.txt"
WRAPPER="$PREFIX/bin/$APP_NAME"

TMP_FILE=""
EXTRACT_DIR=""
BACKUP_DIR=""
FRESH_INSTALL=false
INSTALL_DONE=false
VERSION=""; TAG=""; TARBALL_CHECKSUM=""; BIN_CHECKSUM_ORIG=""; BIN_CHECKSUM_PATCHED=""
EXTRA_PATCHED=""
ATTEST_STATUS="skipped"
RELEASE_JSON=""

cleanup() {
  local rc=$?
  [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]]   && rm -f "$TMP_FILE"
  [[ -n "$EXTRACT_DIR" && -d "$EXTRACT_DIR" ]] && rm -rf "$EXTRACT_DIR"

  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    if [[ $rc -ne 0 && "$INSTALL_DONE" != true ]]; then
      warn "Installation failed ($DISPLAY_NAME): restoring previous version..."
      _remove_orphan_shims "$BACKUP_DIR/shims.txt"
      _remove_orphan_aliases "$BACKUP_DIR/$(basename "$MANIFEST")"
      rm -rf "$LIBEXEC_DIR"
      mv "$BACKUP_DIR" "$LIBEXEC_DIR"
      if [[ -f "$LIBEXEC_DIR/.wrapper" ]]; then
        mv "$LIBEXEC_DIR/.wrapper" "$WRAPPER"
      else
        rm -f "$WRAPPER"
      fi
    else
      rm -rf "$BACKUP_DIR"
    fi
  elif [[ $rc -ne 0 && "$INSTALL_DONE" != true && "$FRESH_INSTALL" == true ]]; then
    warn "Installation failed ($DISPLAY_NAME): cleaning up incomplete files..."
    _remove_registered_shims
    rm -rf "$LIBEXEC_DIR"
    rm -f "$WRAPPER"
    _remove_extra_wrappers "$(installed_extra_bins)"
    _remove_aliases "$(installed_aliases)"
  fi
  exit $rc
}
trap cleanup EXIT

normalize_version() {
  local out
  out=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "${1:-}" | head -1 || true)
  printf '%s' "$out"
}

# Single-char classes ([.] and [+]) avoid mawk escape warnings.
VERSION_CORE_RE='[0-9]+[.][0-9]+[.][0-9]+'
VERSION_SUFFIX_RE='(-[0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?'

parse_version_tag() {
  local raw="$1" out=""
  local version_re="^v?${VERSION_CORE_RE}${VERSION_SUFFIX_RE}$"
  if [[ "$raw" =~ $version_re ]]; then
    out="${raw#v}"
  fi
  printf '%s' "$out"
}

PARSED_REQUESTED_VERSION=""
validate_requested_version() {
  [[ -n "$REQUESTED_VERSION" ]] || return 0

  PARSED_REQUESTED_VERSION=$(parse_version_tag "$REQUESTED_VERSION")
  [[ -n "$PARSED_REQUESTED_VERSION" ]] || {
    err "Invalid version: '$REQUESTED_VERSION'"
    err "Expected format: X.Y.Z (optional: -prerelease and/or +build, e.g., 0.146.0+android1)"
    exit 2
  }

  if [[ -n "$VERSION_MAJOR" ]]; then
    local requested_major
    requested_major=$(release_version_major "$PARSED_REQUESTED_VERSION")
    if [[ "$requested_major" != "$VERSION_MAJOR" ]]; then
      err "$DISPLAY_NAME only supports major $VERSION_MAJOR; requested version is $PARSED_REQUESTED_VERSION."
      exit 2
    fi
  fi

  if [[ "$RELEASE_CHANNEL" == stable ]] && ! release_version_is_stable "$PARSED_REQUESTED_VERSION"; then
    err "$DISPLAY_NAME only supports stable releases; requested version includes a prerelease."
    exit 2
  fi
}

validate_requested_version

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

latest_hashfile_version() {
  [[ -f "$HASH_FILE" ]] || return 0
  awk -v app="$APP_NAME" -v arch="${ARCH:-}" -v core="$VERSION_CORE_RE" -v suf="$VERSION_SUFFIX_RE" '
    {
      sub(/\r$/, "")
      if ($1 !~ "^" app "/v" core suf "($|:" arch "$)") next
      v = $1
      sub("^" app "/v", "", v)
      sub(":.*$", "", v)
      print v
    }' "$HASH_FILE" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

json_get() {
  local payload="$1" key="$2"
  if [[ "$key" == .* ]]; then
    printf '%s' "$payload" | jq -r "$key" 2>/dev/null || true
  else
    printf '%s' "$payload" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null || true
  fi
}

manifest_get() {
  local key="$1"
  [[ -f "$MANIFEST" ]] || return 0
  awk -F= -v k="$key" '{ sub(/\r$/, "") } $1==k { sub(/^[^=]*=/,""); print; exit }' "$MANIFEST"
}

installed_extra_bins() {
  local list=""
  [[ -f "$MANIFEST" ]] && list=$(manifest_get extra_bins "$MANIFEST")
  [[ -z "$list" ]] && list="$EXTRA_BINS"
  printf '%s' "$list"
}

installed_aliases() {
  local list=""
  [[ -f "$MANIFEST" ]] && list=$(manifest_get aliases "$MANIFEST")
  [[ -z "$list" ]] && list="$ALIASES"
  printf '%s' "$list"
}

_remove_extra_wrappers() {
  local list="$1" extra
  for extra in $list; do
    _name_is_valid "$extra" || continue
    rm -f "$PREFIX/bin/$extra"
  done
}

_remove_aliases() {
  local list="$1" alias target
  for alias in $list; do
    _name_is_valid "$alias" || continue
    target="$PREFIX/bin/$alias"
    if [[ -L "$target" && "$(readlink "$target")" == "$WRAPPER" ]]; then
      rm -f "$target"
    fi
  done
}

_shim_used_by_other_tool() {
  local shim_name="$1" other_shims other_dir other_base
  for other_shims in "$PREFIX/libexec"/*/shims.txt; do
    [[ -f "$other_shims" ]] || continue
    other_dir="${other_shims%/*}"
    other_base="${other_dir##*/}"
    case "$other_base" in
      .*|"$APP_NAME") continue ;;
    esac
    [[ -f "$other_dir/manifest.txt" ]] || continue
    if grep -qxF "$shim_name" "$other_shims" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

_shim_is_owned() {
  local shim_path="$1"
  [[ -f "$shim_path" && ! -L "$shim_path" ]] || return 1
  grep -qF "termux-shim: ai-cli-termux" "$shim_path" 2>/dev/null \
    || grep -qF "termux-shim: $APP_NAME" "$shim_path" 2>/dev/null
}

_remove_registered_shims() {
  local shims_file="$LIBEXEC_DIR/shims.txt"
  [[ -f "$shims_file" ]] || return 0
  local name shim
  while IFS= read -r name; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    _name_is_valid "$name" || continue
    _shim_used_by_other_tool "$name" && continue
    shim="$PREFIX/bin/$name"
    if _shim_is_owned "$shim"; then
      rm -f "$shim"
    fi
  done < "$shims_file"
}

_remove_orphan_shims() {
  local prev_file="$1" name shim
  [[ -f "$LIBEXEC_DIR/shims.txt" ]] || return 0
  [[ -f "$prev_file" ]] || return 0
  while IFS= read -r name; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    _name_is_valid "$name" || continue
    grep -qxF "$name" "$prev_file" && continue
    _shim_used_by_other_tool "$name" && continue
    shim="$PREFIX/bin/$name"
    if _shim_is_owned "$shim"; then
      rm -f "$shim"
    fi
  done < "$LIBEXEC_DIR/shims.txt"
}

_remove_orphan_aliases() {
  local prev_manifest="$1" prev_aliases="" alias target
  [[ -f "$prev_manifest" ]] || return 0
  prev_aliases=$(awk -F= -v k=aliases '{ sub(/\r$/, "") } $1==k { sub(/^[^=]*=/,""); print; exit }' "$prev_manifest")
  for alias in $(installed_aliases); do
    [[ -n "$prev_aliases" ]] && grep -qxF "$alias" <<< "$prev_aliases" && continue
    _name_is_valid "$alias" || continue
    target="$PREFIX/bin/$alias"
    if [[ -L "$target" && "$(readlink "$target")" == "$WRAPPER" ]]; then
      rm -f "$target"
    fi
  done
}

checksum_of() {
  case "$CHECKSUM_ALGO" in
    sha256) sha256sum "$1" | cut -d' ' -f1 ;;
    sha512) sha512sum "$1" | cut -d' ' -f1 ;;
    *) err "Unknown checksum algorithm: $CHECKSUM_ALGO"; exit 1 ;;
  esac
}

expand_template() {
  local tmpl="$1"
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

preflight() {
  if [[ "$RESOLVE_VERSION" != true && ! -d /data/data/com.termux ]]; then
    err "This only runs on Termux (/data/data/com.termux not detected)."
    exit 1
  fi
  case "$(uname -m)" in
    aarch64) ARCH="arm64" ;;
    x86_64)  ARCH="amd64" ;;
    *)
      err "Unsupported architecture: $(uname -m). Only aarch64 and x86_64 are supported."
      exit 1 ;;
  esac

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
    err "Missing tools: ${missing[*]}"
    err "Install with: pkg install curl tar coreutils gawk jq"
    exit 1
  fi
}

uninstall() {
  info "Uninstalling $DISPLAY_NAME..."
  local extras aliases
  extras=$(installed_extra_bins)
  aliases=$(installed_aliases)
  _remove_registered_shims
  rm -rf "$LIBEXEC_DIR"
  rm -f "$WRAPPER"
  _remove_extra_wrappers "$extras"
  _remove_aliases "$aliases"
  info "$DISPLAY_NAME removed."
  info "To remove unused dependencies: pkg remove glibc-runner patchelf glibc-repo"
  exit 0
}

[[ "$UNINSTALL" == true ]] && uninstall

_github_api_fetch() {
  local url="$1" out_file="$2" allow_404="${3:-false}"
  local code auth_header=()
  local token="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
  [[ -n "$token" ]] && auth_header=(-H "Authorization: Bearer $token")
  code=$(curl -sS --proto '=https' --tlsv1.2 -L \
           --connect-timeout 10 --max-time 300 \
           --retry 3 --retry-delay 2 --retry-all-errors \
           -H 'Accept: application/vnd.github+json' \
           "${auth_header[@]}" \
           -o "$out_file" -w '%{http_code}' \
           "$url" 2>/dev/null || echo 000)
  case "$code" in
    200) return 0 ;;
    404)
      if [[ "$allow_404" == true ]]; then
        return 1
      fi
      err "GitHub API: HTTP $code. Use -v <version>"; rm -f "$out_file"; exit 1 ;;
    403|429) err "GitHub API: HTTP $code (rate limit). Use -v <version>"; rm -f "$out_file"; exit 1 ;;
    000)     err "No connection to GitHub API. Use -v <version>"; rm -f "$out_file"; exit 1 ;;
    *)       err "GitHub API: HTTP $code. Use -v <version>"; rm -f "$out_file"; exit 1 ;;
  esac
}

github_release_json() {
  local ref="$1" body
  body=$(mktemp)
  _github_api_fetch "https://api.github.com/repos/$REPO/releases/$ref" "$body"
  cat "$body"
  rm -f "$body"
}

github_latest_release_with_asset() {
  local asset_name="$1"
  local body page=1 page_count selected="" resp_type=""

  body=$(mktemp)
  if _github_api_fetch "https://api.github.com/repos/$REPO/releases/latest" "$body" true; then
    resp_type=$(jq -r 'type' "$body" 2>/dev/null || true)
    case "$resp_type" in
      object)
        if ! selected=$(jq -c '[.]' "$body" | release_select_from_page "$asset_name" "$VERSION_MAJOR" "$RELEASE_CHANNEL" 2>/dev/null); then
          err "GitHub API returned an invalid release or ambiguous assets for '$asset_name'."
          rm -f "$body"
          exit 1
        fi
        if [[ -n "$selected" ]]; then
          printf '%s\n' "$selected"
          rm -f "$body"
          return 0
        fi
        ;;
      array)
        if ! selected=$(release_select_from_page "$asset_name" "$VERSION_MAJOR" "$RELEASE_CHANNEL" < "$body" 2>/dev/null); then
          err "GitHub API returned an invalid list or ambiguous assets for '$asset_name'."
          rm -f "$body"
          exit 1
        fi
        if [[ -n "$selected" ]]; then
          printf '%s\n' "$selected"
          rm -f "$body"
          return 0
        fi
        page_count=$(jq -er 'length' "$body" 2>/dev/null || echo 0)
        if [[ "$page_count" -eq 0 ]]; then
          rm -f "$body"
          return 0
        fi
        # URL-blind mocks return page 1 on the first call; continue at page 2.
        page=2
        ;;
      *)
        err "GitHub API returned an invalid releases response."
        rm -f "$body"
        exit 1
        ;;
    esac
  fi
  rm -f "$body"

  while (( page <= 10 )); do
    body=$(mktemp)
    _github_api_fetch "https://api.github.com/repos/$REPO/releases?per_page=30&page=$page" "$body"

    if ! selected=$(release_select_from_page "$asset_name" "$VERSION_MAJOR" "$RELEASE_CHANNEL" < "$body" 2>/dev/null); then
      err "GitHub API returned an invalid list or ambiguous assets for '$asset_name'."
      rm -f "$body"
      exit 1
    fi
    if [[ -n "$selected" ]]; then
      printf '%s\n' "$selected"
      rm -f "$body"
      return 0
    fi

    if ! page_count=$(jq -er 'if type == "array" then length else error("release response is not an array") end' "$body" 2>/dev/null); then
      err "GitHub API returned an invalid releases list."
      rm -f "$body"
      exit 1
    fi
    rm -f "$body"
    [[ "$page_count" -gt 0 ]] || break
    if [[ "$page" -eq 10 ]]; then
      err "No eligible release found in the first ten pages of GitHub API."
      exit 1
    fi
    page=$((page + 1))
  done
}

resolve_version() {
  case "$RELEASE_SOURCE" in

    github)
      if [[ -n "$REQUESTED_VERSION" ]]; then
        VERSION="$PARSED_REQUESTED_VERSION"
      else
        local asset_name
        asset_name=$(expand_template "$ARCHIVE_TEMPLATE")
        RELEASE_JSON=$(github_latest_release_with_asset "$asset_name")
        if [[ -z "$RELEASE_JSON" ]]; then
          err "No release in $REPO contains asset '$asset_name'."
          err "Use -v <version> to install a specific version."
          exit 1
        fi
        local raw
        raw=$(printf '%s' "$RELEASE_JSON" | jq -r '.tag_name // empty' 2>/dev/null || true)
        VERSION=$(parse_version_tag "$raw")
        [[ -n "$VERSION" ]] || {
          err "Could not extract version from GitHub API (tag: '${raw:-empty}')"
          exit 1
        }
      fi
      TAG="v$VERSION"
      if [[ -n "$VERSION_MAJOR$RELEASE_CHANNEL" ]]; then
        local asset_name expected_url
        asset_name=$(expand_template "$ARCHIVE_TEMPLATE")
        if [[ -z "$RELEASE_JSON" ]]; then
          RELEASE_JSON=$(github_release_json "tags/$TAG")
        fi
        if ! release_validate_object "$RELEASE_JSON" "$asset_name" "$VERSION_MAJOR" "$RELEASE_CHANNEL" "$TAG"; then
          err "Release $TAG does not meet version/channel policy or does not contain unique asset '$asset_name'."
          exit 1
        fi
        expected_url="https://github.com/$REPO/releases/download/$TAG/$asset_name"
        if ! DOWNLOAD_URL=$(printf '%s' "$RELEASE_JSON" | release_asset_url "$asset_name" "$expected_url" 2>/dev/null); then
          err "Asset URL for '$asset_name' does not match release $TAG."
          exit 1
        fi
      fi
      ;;

    manifest_json)
      local manifest_url="$MANIFEST_URL"
      case "$(uname -m)" in
        aarch64) [[ -n "$MANIFEST_URL_AARCH64" ]] && manifest_url="$MANIFEST_URL_AARCH64" ;;
        x86_64)  [[ -n "$MANIFEST_URL_X86_64" ]]  && manifest_url="$MANIFEST_URL_X86_64" ;;
      esac
      [[ -n "$manifest_url" ]] || {
        err "No MANIFEST_URL for this architecture ($(uname -m)) in $CONF."
        exit 1
      }
      local expanded_url version_key url_key checksum_key
      expanded_url=$(expand_template "$manifest_url")
      info "Fetching remote manifest..."
      local manifest_json
      manifest_json=$(curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 --retry-all-errors "$expanded_url" 2>/dev/null || true)
      [[ -n "$manifest_json" ]] || { err "Failed to download manifest from $expanded_url"; exit 1; }

      version_key=$(expand_template "$MANIFEST_KEY_VERSION")
      url_key=$(expand_template "$MANIFEST_KEY_URL")
      checksum_key=$(expand_template "$MANIFEST_KEY_CHECKSUM")

      local v_expr u_expr c_expr manifest_fields="" raw_version="" _extra=""
      # shellcheck disable=SC2016
      [[ "$version_key" == .* ]]  && v_expr="(${version_key} // \"\")"  || v_expr='(.[$kv] // "")'
      # shellcheck disable=SC2016
      [[ "$url_key" == .* ]]      && u_expr="(${url_key} // \"\")"      || u_expr='(.[$ku] // "")'
      # shellcheck disable=SC2016
      [[ "$checksum_key" == .* ]] && c_expr="(${checksum_key} // \"\")" || c_expr='(.[$kc] // "")'

      if ! manifest_fields=$(printf '%s' "$manifest_json" | jq -er \
        --arg kv "$version_key" --arg ku "$url_key" --arg kc "$checksum_key" \
        "if type != \"object\" then error(\"manifest is not a JSON object\") else [$v_expr, $u_expr, ($c_expr | tostring | ascii_downcase)] | map(tostring) | if any(.[]; contains(\"\n\") or contains(\"\r\") or contains(\"\u001f\")) then error(\"invalid control characters in manifest\") else join(\"\u001f\") end end" 2>/dev/null); then
        err "Remote manifest is incomplete or malformed."
        exit 1
      fi
      IFS=$'\x1f' read -r raw_version DOWNLOAD_URL REMOTE_CHECKSUM _extra <<< "$manifest_fields" || true
      [[ -z "$_extra" ]] || { err "Remote manifest is incomplete or malformed."; exit 1; }
      VERSION=$(parse_version_tag "$raw_version")
      [[ -n "$VERSION" ]] || {
        err "Remote manifest returned an invalid version: '$raw_version'"
        exit 1
      }

      [[ -n "$VERSION" && -n "$REMOTE_CHECKSUM" ]] || {
        err "Remote manifest is incomplete or malformed."
        err "  version:  ${VERSION:-(empty)}"
        err "  checksum: ${REMOTE_CHECKSUM:-(empty)}"
        exit 1
      }
      [[ -n "$DOWNLOAD_URL" || -n "$DOWNLOAD_URL_TEMPLATE" ]] || {
        err "Remote manifest does not provide download URL."
        err "  Define DOWNLOAD_URL_TEMPLATE in $CONF to resolve download URL."
        exit 1
      }

      if [[ -n "$REQUESTED_VERSION" ]]; then
        local req
        req=$(parse_version_tag "$REQUESTED_VERSION")
        [[ "$req" == "$VERSION" ]] || {
          warn "Available version ($VERSION) does not match requested version ($req)."
          warn "Only the latest version is available in remote manifest."
        }
      fi
      TAG="v$VERSION"
      ;;

    url_template)
      if [[ -n "$REQUESTED_VERSION" ]]; then
        VERSION="$PARSED_REQUESTED_VERSION"
      else
        VERSION=$(latest_hashfile_version)
        if [[ -z "$VERSION" ]]; then
          err "$DISPLAY_NAME: no version registered in $HASH_FILE."
          err "Add current version checksum (instructions inside $HASH_FILE) or use -v <version>."
          exit 1
        fi
        info "$DISPLAY_NAME: using latest registered version ($VERSION)."
      fi
      TAG="v$VERSION"
      ;;

    *)
      err "Unknown RELEASE_SOURCE in $CONF: '$RELEASE_SOURCE'"
      exit 1
      ;;
    esac

  local resolved_major
  resolved_major=$(release_version_major "$VERSION")
  if [[ -n "$VERSION_MAJOR" && "$resolved_major" != "$VERSION_MAJOR" ]]; then
    err "Resolved version $VERSION does not belong to major $VERSION_MAJOR of $DISPLAY_NAME."
    exit 1
  fi
  if [[ "$RELEASE_CHANNEL" == stable ]] && ! release_version_is_stable "$VERSION"; then
    err "Resolved version $VERSION does not belong to stable channel of $DISPLAY_NAME."
    exit 1
  fi

  info "Target version: $VERSION ($DISPLAY_NAME)"
}

resolve_expected_checksum() {
  if [[ -n "$PINNED_CHECKSUM" ]]; then
    EXPECTED_CHECKSUM=$(printf '%s' "$PINNED_CHECKSUM" | tr 'A-F' 'a-f' | tr -d '[:space:]')
    warn "Using checksum passed via --sha256 (verify it yourself)."
  else
    case "$CHECKSUM_SOURCE" in
      hashfile)
        EXPECTED_CHECKSUM=$(lookup_hashfile "$APP_NAME/$TAG")
        if [[ -z "$EXPECTED_CHECKSUM" ]]; then
          err "No $CHECKSUM_ALGO registered for $APP_NAME/$TAG in $HASH_FILE."
          [[ ! -f "$HASH_FILE" ]] && err "$HASH_FILE does not exist either (did you clone the full repository?)."
          err ""
          err "Fail-closed: installation aborted without verification. Options:"
          err "  1. Add hash to sha256.txt (instructions inside file)."
          err "  2. Install a registered version: -v <version>"
          err "  3. Pin checksum explicitly: --sha256 <hash>"
          exit 1
        fi
        ;;
      manifest)
        EXPECTED_CHECKSUM="${REMOTE_CHECKSUM:-}"
        [[ -n "$EXPECTED_CHECKSUM" ]] || { err "Remote manifest does not contain a checksum"; exit 1; }
        ;;
      release_digest)
        EXPECTED_CHECKSUM=$(lookup_hashfile "$APP_NAME/$TAG")
        if [[ -n "$EXPECTED_CHECKSUM" ]]; then
          warn "Using pinned checksum from sha256.txt for $APP_NAME/$TAG."
        else
          local release_json="$RELEASE_JSON"
          if [[ -z "$release_json" ]]; then
            release_json=$(github_release_json "tags/$TAG")
          fi
          local digest archive_name
          archive_name=$(expand_template "$ARCHIVE_TEMPLATE")
          digest=$(printf '%s' "$release_json" \
            | jq -r --arg n "$archive_name" '.assets[]? | select(.name == $n) | .digest // empty' \
              2>/dev/null | head -1 || true)
          [[ -n "$digest" ]] || {
            err "Could not retrieve SHA256 digest for asset '$archive_name' in $APP_NAME/$TAG."
            err "Options: register hash in sha256.txt or use --sha256 <hash>."
            exit 1
          }
          EXPECTED_CHECKSUM="${digest#sha256:}"
          info "SHA256 release digest retrieved from GitHub API."
        fi
        ;;
      *)
        err "Unknown CHECKSUM_SOURCE in $CONF: '$CHECKSUM_SOURCE'"
        exit 1 ;;
    esac
  fi

  local expected_len
  case "$CHECKSUM_ALGO" in sha256) expected_len=64 ;; sha512) expected_len=128 ;; esac
  if [[ ! "$EXPECTED_CHECKSUM" =~ ^[0-9a-f]{${expected_len}}$ ]]; then
    err "Expected checksum format is incorrect ($CHECKSUM_ALGO, ${expected_len} hex chars):"
    err "  '$EXPECTED_CHECKSUM'"
    exit 1
  fi
}

check_current() {
  [[ "$REINSTALL" == true ]] && return 0

  local installed_tag=""
  [[ -f "$MANIFEST" ]] && installed_tag=$(manifest_get tag)
  if [[ -n "$installed_tag" ]]; then
    if [[ "$installed_tag" == "$TAG" && -x "$BIN_FILE" && -x "$WRAPPER" ]]; then
      if [[ "$UPDATE" == true ]]; then
        info "$DISPLAY_NAME is already up to date ($VERSION)."
      else
        info "$DISPLAY_NAME $VERSION is already installed. Use -r to reinstall."
      fi
      exit 0
    fi
    info "Installed version: $installed_tag -> updating to $TAG"
    return 0
  fi

  local installed version_core
  installed=$(normalize_version "$("$WRAPPER" --version 2>/dev/null || true)")
  version_core=$(normalize_version "$VERSION")
  if [[ -n "$installed" && "$installed" == "$version_core" && -x "$BIN_FILE" && -x "$WRAPPER" ]]; then
    if [[ "$UPDATE" == true ]]; then
      info "$DISPLAY_NAME is already up to date ($VERSION)."
    else
      info "$DISPLAY_NAME $VERSION is already installed. Use -r to reinstall."
    fi
    exit 0
  fi
  [[ -n "$installed" ]] && info "Installed version: $installed -> updating to $VERSION"
  return 0
}

install_deps() {
  local deps=() cmd
  for cmd in file jq curl; do
    command -v "$cmd" >/dev/null 2>&1 || deps+=("$cmd")
  done
  if [[ "$NEEDS_PATCHELF" == true ]] && ! command -v patchelf >/dev/null 2>&1; then
    deps+=(patchelf)
  fi
  if [[ "$EXEC_DIRECT" != true && ! -f "$LOADER" ]]; then
    deps+=(glibc-repo glibc-runner)
  fi

  if [[ ${#deps[@]} -eq 0 ]]; then
    if [[ "$EXEC_DIRECT" != true ]]; then
      info "Dependencies satisfied (glibc loader: $LOADER)."
    else
      info "Dependencies satisfied."
    fi
    return 0
  fi

  info "Installing missing dependencies (${deps[*]})..."
  pkg update -y >/dev/null 2>&1 || warn "pkg update failed; continuing with existing package indexes."
  if ! pkg install "${deps[@]}" -y; then
    err "Failed to install dependencies."
    err "Ensure Termux is up to date: pkg update && pkg upgrade"
    exit 1
  fi
  if [[ "$EXEC_DIRECT" != true && ! -f "$LOADER" ]]; then
    err "Glibc loader not found: $LOADER"
    err "Run: pkg install glibc-repo glibc-runner"
    exit 1
  fi
  [[ "$EXEC_DIRECT" != true ]] && info "Glibc loader: $LOADER"
  return 0
}

download() {
  local url
  case "$RELEASE_SOURCE" in
    github)
      local archive_name
      archive_name=$(expand_template "$ARCHIVE_TEMPLATE")
      url="${DOWNLOAD_URL:-https://github.com/$REPO/releases/download/$TAG/$archive_name}"
      ;;
    manifest_json)
      url=$(expand_template "${DOWNLOAD_URL_TEMPLATE:-$DOWNLOAD_URL}")
      ;;
    url_template)
      url=$(expand_template "$DOWNLOAD_URL_TEMPLATE")
      ;;
  esac

  local tmp_dir="${TMPDIR:-$PREFIX/tmp}"
  mkdir -p "$tmp_dir"
  TMP_FILE=$(mktemp "$tmp_dir/$APP_NAME-install-XXXXXX.tar.gz")

  info "Downloading $DISPLAY_NAME $VERSION..."
  if ! curl -fL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time "$DOWNLOAD_MAX_TIME" --retry 3 --retry-delay 2 --retry-all-errors -o "$TMP_FILE" "$url"; then
    err "Download failed from $(printf '%s' "$url" | tr -d '[:cntrl:]')"
    exit 1
  fi
}

verify_tarball() {
  TARBALL_CHECKSUM=$(checksum_of "$TMP_FILE")
  if [[ "$TARBALL_CHECKSUM" != "$EXPECTED_CHECKSUM" ]]; then
    err "Tarball ${CHECKSUM_ALGO^^} MISMATCH!"
    err "  Expected: $EXPECTED_CHECKSUM"
    err "  Actual:   $TARBALL_CHECKSUM"
    err "Installation aborted."
    exit 1
  fi
  info "Tarball ${CHECKSUM_ALGO^^} verified: ${TARBALL_CHECKSUM:0:24}..."

  if ! file "$TMP_FILE" 2>/dev/null | grep -qi 'gzip compressed'; then
    err "Downloaded file is not a gzip tarball:"
    file "$TMP_FILE" >&2 || true
    exit 1
  fi
}

verify_attestation() {
  ATTEST_STATUS="n/a"
  [[ -z "$ATTEST_PREDICATE" ]] && return 0

  ATTEST_STATUS="skipped"
  if ! command -v gh >/dev/null 2>&1; then
    [[ "$REQUIRE_ATTEST" == true ]] && {
      err "--require-attestation specified but gh is not installed: pkg install gh"
      exit 1
    }
    info "gh is not installed: skipping attestation (pkg install gh to enable)."
    return 0
  fi

  info "Verifying GitHub release attestation..."
  local out
  if out=$(gh attestation verify "$TMP_FILE" \
             --repo "${ATTEST_REPO:-$REPO}" \
             --predicate-type "$ATTEST_PREDICATE" 2>&1); then
    ATTEST_STATUS="verified"
    info "Attestation valid: tarball published by $REPO."
    return 0
  fi

  ATTEST_STATUS="failed"
  [[ "$REQUIRE_ATTEST" == true ]] && {
    err "Attestation verification failed:"
    printf '%s\n' "$out" >&2
    exit 1
  }
  warn "Could not verify attestation (unauthenticated gh?)."
  warn "Checksum already verified; proceeding."
  warn "Detail: $(printf '%s' "$out" | head -1)"
}

extract_install() {
  local tmp_dir="${TMPDIR:-$PREFIX/tmp}"
  EXTRACT_DIR=$(mktemp -d "$tmp_dir/$APP_NAME-extract-XXXXXX")
  tar -xzf "$TMP_FILE" -C "$EXTRACT_DIR"
  rm -f "$TMP_FILE"; TMP_FILE=""

  local found=""
  local cand
  while IFS= read -r cand; do
    if file "$cand" 2>/dev/null | grep -qi "ELF 64-bit.*$EXPECTED_ELF_ARCH"; then
      found="$cand"; break
    fi
  done < <(find "$EXTRACT_DIR" -type f -name "$ELF_NAME" 2>/dev/null)

  if [[ -z "$found" ]]; then
    err "Could not find a 64-bit ELF ($EXPECTED_ELF_ARCH) named '$ELF_NAME' in tarball."
    err "Tarball contents:"
    find "$EXTRACT_DIR" -type f 2>/dev/null | head -20 >&2
    exit 1
  fi

  BIN_CHECKSUM_ORIG=$(checksum_of "$found")
  info "Binary located (${CHECKSUM_ALGO} original: ${BIN_CHECKSUM_ORIG:0:16}...)"

  if [[ -d "$LIBEXEC_DIR" ]]; then
    BACKUP_DIR="$(dirname "$LIBEXEC_DIR")/.$APP_NAME.backup.$$"
    rm -rf "$BACKUP_DIR"
    mv "$LIBEXEC_DIR" "$BACKUP_DIR"
    if [[ -f "$WRAPPER" ]]; then
      cp -a "$WRAPPER" "$BACKUP_DIR/.wrapper"
    fi
  else
    FRESH_INSTALL=true
  fi

  mkdir -p "$LIBEXEC_DIR"
  local root; root=$(dirname "$found")
  (
    shopt -s dotglob nullglob
    items=("$root"/*)
    if (( ${#items[@]} > 0 )); then
      mv -f -- "${items[@]}" "$LIBEXEC_DIR/" 2>/dev/null || cp -a "$root/." "$LIBEXEC_DIR/"
    fi
  )
  if [[ ! -f "$BIN_FILE" && -f "$found" ]]; then
    mv -f "$found" "$BIN_FILE" 2>/dev/null || cp -a "$found" "$BIN_FILE"
  fi
  chmod 755 "$BIN_FILE"
  rm -rf "$EXTRACT_DIR"; EXTRACT_DIR=""
  info "Binary installed in $BIN_FILE"
}

_patch_elf() {
  local target="$1"
  file "$target" 2>/dev/null | grep -qi "ELF 64-bit.*$EXPECTED_ELF_ARCH" || {
    err "Target to patch is not a 64-bit ELF ($EXPECTED_ELF_ARCH): $target"
    err "Check ELF_NAME/EXTRA_BINS in registry/$APP_NAME.conf"
    exit 1
  }
  # Separate patchelf calls: patchelf 0.19.1 corrupts non-PIE ELFs when --set-interpreter and --set-rpath are combined.
  patchelf --set-rpath "$RPATH" "$target" || {
    err "patchelf (rpath) failed on $target"; exit 1
  }
  patchelf --set-interpreter "$LOADER" "$target" || {
    err "patchelf (interpreter) failed on $target"; exit 1
  }
  local got_interp got_rpath
  got_interp=$(patchelf --print-interpreter "$target" 2>/dev/null || true)
  got_rpath=$(patchelf --print-rpath "$target" 2>/dev/null || true)
  [[ "$got_interp" == "$LOADER" ]] || {
    err "patchelf did not set interpreter correctly on $target."
    err "  Expected: $LOADER"; err "  Found:    ${got_interp:-<empty>}"; exit 1
  }
  [[ "$got_rpath" == *"$RPATH"* ]] || {
    err "patchelf did not set rpath correctly on $target."
    err "  Expected to contain: $RPATH"; err "  Found:               ${got_rpath:-<empty>}"; exit 1
  }
}

patch_interpreter() {
  [[ "$NEEDS_PATCHELF" == true ]] || return 0

  info "Applying patchelf (interpreter + rpath -> glibc overlay)..."
  _patch_elf "$BIN_FILE"
  BIN_CHECKSUM_PATCHED=$(checksum_of "$BIN_FILE")

  local extra
  for extra in $EXTRA_BINS; do
    [[ -f "$LIBEXEC_DIR/$extra" ]] || {
      err "EXTRA_BINS: '$extra' does not exist in installed tarball ($LIBEXEC_DIR)."
      err "Check registry/$APP_NAME.conf."; exit 1
    }
    _patch_elf "$LIBEXEC_DIR/$extra"
    EXTRA_PATCHED+="$extra=$(checksum_of "$LIBEXEC_DIR/$extra") "
  done

  info "Interpreter and rpath verified."
}

ensure_nsswitch() {
  [[ "$EXEC_DIRECT" != true ]] || return 0
  local ns="$GLIBC_PREFIX/etc/nsswitch.conf"
  [[ -f "$ns" ]] && return 0
  mkdir -p "${ns%/*}"
  printf 'hosts: files dns\n' > "$ns"
  info "Created $ns (glibc DNS resolution)."
}

_is_ip_literal() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && return 0
  [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+(%[a-zA-Z0-9._-]+)?$ ]] && return 0
  return 1
}

ensure_glibc_resolv() {
  [[ "$EXEC_DIRECT" != true ]] || return 0
  local resolv="$GLIBC_PREFIX/etc/resolv.conf"
  [[ -s "$resolv" ]] && return 0
  if [[ -L "$resolv" ]]; then
    warn "Skipping $resolv: dangling or empty symlink (left untouched)."
    return 0
  fi
  mkdir -p "${resolv%/*}"
  local dns1="" dns2="" servers=()
  if command -v getprop >/dev/null 2>&1; then
    dns1=$(getprop net.dns1 2>/dev/null | tr -d '[:space:]' || true)
    dns2=$(getprop net.dns2 2>/dev/null | tr -d '[:space:]' || true)
  fi
  _is_ip_literal "$dns1" && servers+=("$dns1")
  if [[ "$dns2" != "$dns1" ]] && _is_ip_literal "$dns2"; then
    servers+=("$dns2")
  fi
  if [[ ${#servers[@]} -eq 0 ]]; then
    servers=(8.8.8.8 1.1.1.1)
  fi
  {
    local s
    for s in "${servers[@]}"; do
      printf 'nameserver %s\n' "$s"
    done
  } > "$resolv"
  info "Created $resolv (glibc DNS resolution)."
}

run_pre_wrapper_hook() {
  if declare -f pre_wrapper_hook >/dev/null 2>&1; then
    info "Running pre_wrapper_hook..."
    pre_wrapper_hook
  fi
}

_write_wrapper() {
  local wrapper_path="$1" bin_path="$2"
  local exec_target="${3:-$bin_path}"
  local use_runner="${4:-true}"

  local runner_path=""
  if [[ "$use_runner" == true && -n "$WRAPPER_RUNNER" ]]; then
    runner_path="$LIBEXEC_DIR/$WRAPPER_RUNNER"
    if [[ ! -f "$runner_path" || ! -x "$runner_path" || -L "$runner_path" ]]; then
      err "WRAPPER_RUNNER does not exist as an executable file in bundle: $runner_path"
      exit 1
    fi
  fi

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

  local unset_block="" env_name
  while IFS= read -r env_name; do
    [[ -z "$env_name" || "$env_name" == \#* ]] && continue
    unset_block+="unset $env_name"$'\n'
  done <<< "$WRAPPER_UNSET_ENV"

  local default_args="" tok
  if [[ -n "$WRAPPER_DEFAULT_ARGS" ]]; then
    local -a default_toks=()
    read -ra default_toks <<< "$WRAPPER_DEFAULT_ARGS" || true
    local i
    for (( i=0; i<${#default_toks[@]}; i++ )); do
      tok="${default_toks[i]}"
      [[ "$tok" =~ ^(--?)?[a-zA-Z0-9_][a-zA-Z0-9_.,=+-]*$ ]] || {
        err "Invalid WRAPPER_DEFAULT_ARGS in $CONF: '$tok' (only [a-zA-Z0-9_.,=+-] tokens with optional leading '-'/'--', no spaces or metacharacters)."
        exit 1
      }
      default_args+=" $tok"
    done
    unset default_toks
  fi
  local exec_cmd="exec \"\$EXEC_TARGET\"${default_args} \"\$@\""
  if [[ "$NEEDS_PATCHELF" == false && "$EXEC_DIRECT" != true ]]; then
    exec_cmd="exec \"$LOADER\" --library-path \"$RPATH\" \"\$EXEC_TARGET\"${default_args} \"\$@\""
  fi
  if [[ -n "$runner_path" ]]; then
    if [[ "$NEEDS_PATCHELF" == false && "$EXEC_DIRECT" != true ]]; then
      exec_cmd="exec \"$runner_path\" \"$LOADER\" --library-path \"$RPATH\" \"\$EXEC_TARGET\"${default_args} \"\$@\""
    else
      exec_cmd="exec \"$runner_path\" \"\$EXEC_TARGET\"${default_args} \"\$@\""
    fi
  fi

  local deny_block=""
  if [[ -n "$WRAPPER_DENY_ARGS" ]]; then
    local item deny_items=""
    for item in $WRAPPER_DENY_ARGS; do
      [[ "$item" =~ ^[a-zA-Z0-9_-]+$ ]] || {
        err "Invalid WRAPPER_DENY_ARGS in $CONF: '$item' (only [a-zA-Z0-9_-])"
        exit 1
      }
      deny_items+=" $item"
    done
    # shellcheck disable=SC2016  # $1/$a must remain literal in wrapper
    deny_block=$(printf '%s\n' \
      'if [[ $# -gt 0 ]]; then' \
      "  for a in ${deny_items# }; do" \
      '    [[ "$1" == "$a" ]] || continue' \
      "    echo \"ERROR: command '\$a' is disabled for $DISPLAY_NAME.\" >&2" \
      "    echo \"Updates are managed by the installer:\" >&2" \
      "    echo \"  bash install.sh $APP_NAME --update\" >&2" \
      '    exit 1' \
      '  done' \
      'fi')
  fi

  cat > "$wrapper_path" <<WRAPPER_EOF
#!$PREFIX/bin/bash
set -euo pipefail

BIN="$bin_path"
EXEC_TARGET="$exec_target"

if [[ ! -f "\$BIN" ]]; then
  echo "ERROR: $DISPLAY_NAME not found at \$BIN" >&2
  echo "Reinstall with: bash install.sh $APP_NAME -r" >&2
  exit 1
fi
if [[ ! -x "\$BIN" ]]; then
  echo "ERROR: $DISPLAY_NAME lacks execute permission at \$BIN" >&2
  echo "Reinstall with: bash install.sh $APP_NAME -r" >&2
  exit 1
fi

# libtermux-exec.so is bionic: preloading it into a glibc process crashes.
unset LD_PRELOAD
# Inherited bionic LD_LIBRARY_PATH causes segfaults under glibc.
unset LD_LIBRARY_PATH

${unset_block}
${env_block}
${deny_block}
${exec_cmd}
WRAPPER_EOF
  chmod 755 "$wrapper_path"
}

create_wrapper() {
  mkdir -p "$(dirname "$WRAPPER")"

  local exec_target="$BIN_FILE"
  if [[ -n "$ENTRY_POINT" ]]; then
    local entry_file="$LIBEXEC_DIR/$ENTRY_POINT"
    if [[ ! -f "$entry_file" || ! -x "$entry_file" ]]; then
      err "ENTRY_POINT: '$ENTRY_POINT' does not exist or is not executable in $LIBEXEC_DIR."
      err "Check registry/$APP_NAME.conf."
      exit 1
    fi
    exec_target="$entry_file"
    info "Entry point: $exec_target"
  fi

  _write_wrapper "$WRAPPER" "$BIN_FILE" "$exec_target"
  info "Wrapper created at $WRAPPER"

  local extra
  for extra in $EXTRA_BINS; do
    _write_wrapper "$PREFIX/bin/$extra" "$LIBEXEC_DIR/$extra" "$LIBEXEC_DIR/$extra" false
    info "Wrapper created at $PREFIX/bin/$extra"
  done

  local alias_name target
  for alias_name in $ALIASES; do
    target="$PREFIX/bin/$alias_name"
    if [[ -L "$target" && "$(readlink "$target")" == "$WRAPPER" ]]; then
      info "Alias already present (reinstall): $target -> $WRAPPER"
      continue
    fi
    if [[ -e "$target" || -L "$target" ]]; then
      err "ALIASES: '$alias_name' already exists in $PREFIX/bin and is not a symlink to $WRAPPER."
      err "Fail-closed: will not overwrite existing binary."
      err "Rename or remove $target, or remove alias from .conf."
      exit 1
    fi
    ln -s "$WRAPPER" "$target"
    info "Alias created: $target -> $WRAPPER"
  done
}

write_manifest() {
  local extra_line="" pair name hash
  for pair in $EXTRA_PATCHED; do
    name="${pair%%=*}"
    hash="${pair#*=}"
    extra_line+="extra_checksum_${name}=${hash}"$'\n'
  done

  local runner_checksum_sha256=""
  if [[ -n "$WRAPPER_RUNNER" ]]; then
    runner_checksum_sha256=$(sha256sum "$LIBEXEC_DIR/$WRAPPER_RUNNER" | awk '{print $1}')
  fi

  cat > "$MANIFEST" <<EOF
# Generated by install.sh. Do not edit manually.
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
exec_direct=${EXEC_DIRECT:-false}
entry_point=$ENTRY_POINT
aliases=$ALIASES
interpreter=${LOADER}
rpath=${RPATH}
attestation=$ATTEST_STATUS
extra_bins=$EXTRA_BINS
runner_name=$WRAPPER_RUNNER
runner_checksum_sha256=$runner_checksum_sha256
${extra_line}installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 644 "$MANIFEST"
  info "Integrity manifest written to $MANIFEST"
}

verify_install() {
  info "Verifying installation..."
  local out
  if ! out=$("$WRAPPER" --version 2>&1); then
    err "Wrapper failed to execute $DISPLAY_NAME."
    err "Output: $(printf '%s' "$out" | head -3)"
    err "Try restarting Termux, or check 'bash verify.sh $APP_NAME'."
    exit 1
  fi
  local got version_core
  got=$(normalize_version "$out")
  version_core=$(normalize_version "$VERSION")
  [[ -n "$got" && "$got" != "$version_core" ]] && \
    warn "Reported version ($got) != expected ($VERSION)."
  INSTALL_DONE=true
  info "$DISPLAY_NAME ${got:-$VERSION} is working properly."
}

show_summary() {
  local attest_display="$ATTEST_STATUS"
  [[ "$ATTEST_STATUS" == "n/a" ]] && attest_display="N/A (no attestation configured)"
  local mode_label="glibc overlay, no PRoot"
  [[ "$EXEC_DIRECT" == true ]] && mode_label="native, no PRoot"

  printf '\n'
  printf '%s%s %s installed on Termux (%s)%s\n' \
    "$GREEN" "$DISPLAY_NAME" "$VERSION" "$mode_label" "$NC"
  printf '\n'
  printf '%sIntegrity:%s\n' "$MUTED" "$NC"
  printf '  tarball %-7s  %s\n' "$CHECKSUM_ALGO" "$TARBALL_CHECKSUM"
  printf '  attestation      %s\n' "$attest_display"
  printf '\n'
  printf '%sUsage:%s  %s%s%s\n' "$MUTED" "$NC" "$GREEN" "$APP_NAME" "$NC"
  printf '\n'
  printf '%sVerify:  bash verify.sh %s%s\n' "$MUTED" "$APP_NAME" "$NC"
}

run_post_install_hook() {
  if declare -f post_install_hook >/dev/null 2>&1; then
    info "Running post_install_hook..."
    post_install_hook
  fi
}

main() {
  preflight

  if [[ "$RESOLVE_VERSION" == true ]]; then
    # fd 9 preserves stdout without conflicting with caller descriptors.
    exec 9>&1
    exec 1>&2
    resolve_version
    exec 1>&9
    exec 9>&-
    printf 'TARGET_VERSION=%s\n' "$VERSION"
    exit 0
  fi

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
  ensure_glibc_resolv
  run_pre_wrapper_hook
  create_wrapper
  verify_install
  write_manifest
  run_post_install_hook
  show_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main
fi
