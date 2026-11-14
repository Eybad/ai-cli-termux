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
    fail "Unsupported architecture: $(uname -m)"
    exit 1
    ;;
esac

normalize_version() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<< "${1:-}" | head -1 || true; }

manifest_get() {
  local key="$1" mf="$2" line
  [[ -f "$mf" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      "$key"=*)
        printf '%s\n' "${line#*=}"
        return 0
        ;;
    esac
  done < "$mf"
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
  echo "Usage: verify.sh <tool>"
  echo "Available tools:"
  for f in "$REGISTRY_DIR"/*.conf; do
    [[ -f "$f" ]] && printf '  - %s\n' "$(basename "$f" .conf)"
  done
  exit 1
fi

TOOL="$1"
if [[ ! "$TOOL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: Invalid tool name '$TOOL'."
  exit 1
fi

CONF="$REGISTRY_DIR/$TOOL.conf"

if [[ ! -f "$CONF" ]]; then
  echo "ERROR: Unknown tool '$TOOL'. Create registry/$TOOL.conf to register it."
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

printf '=== Verification of %s on Termux ===\n\n' "$DISPLAY_NAME"

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
  pass "Manifest present (version $M_VERSION, installed $(manifest_get installed_at "$MANIFEST"))"

  missing_fields=()
  [[ -n "$M_VERSION" ]]               || missing_fields+=(version)
  [[ -n "$M_TAG" ]]                   || missing_fields+=(tag)
  [[ -n "$M_CHECKSUM_PATCHED" ]]      || missing_fields+=(binary_checksum_patched)
  [[ -n "$M_CHECKSUM_ALGO" ]]         || missing_fields+=(checksum_algo)
  if [[ ${#missing_fields[@]} -gt 0 ]]; then
    fail "Incomplete manifest: missing fields: ${missing_fields[*]}"
    note "Reinstall using: bash install.sh $APP_NAME -r"
  fi
else
  warn "No manifest found at $MANIFEST"
  note "Previous or manual installation. Reinstall using 'bash install.sh $APP_NAME -r'."
fi

if [[ -n "$WRAPPER_RUNNER" && -n "$M_WRAPPER_RUNNER" && "$M_WRAPPER_RUNNER" != "$WRAPPER_RUNNER" ]]; then
  fail "Manifest does not record configured WRAPPER_RUNNER ($WRAPPER_RUNNER)"
fi
if [[ -n "$M_WRAPPER_RUNNER" || -n "$WRAPPER_RUNNER" ]]; then
  if [[ -z "$M_WRAPPER_RUNNER" ]]; then
    fail "Manifest does not record runner required by registry"
  elif [[ ! "$M_WRAPPER_RUNNER" =~ ^[a-zA-Z0-9._-]+$ || "$M_WRAPPER_RUNNER" == "." || "$M_WRAPPER_RUNNER" == ".." ]]; then
    fail "Invalid runner name in manifest"
  else
    runner_file="$LIBEXEC_DIR/$M_WRAPPER_RUNNER"
    if [[ ! -f "$runner_file" || ! -x "$runner_file" || -L "$runner_file" ]]; then
      fail "Runner missing, not executable, or outside bundle: $runner_file"
    elif [[ ! "$M_RUNNER_CHECKSUM_SHA256" =~ ^[a-f0-9]{64}$ ]]; then
      fail "Runner SHA256 checksum missing or invalid in manifest"
    elif ! command -v sha256sum >/dev/null 2>&1; then
      fail "sha256sum is not available to verify runner"
    else
      runner_checksum_actual=$(sha256sum "$runner_file" | awk '{print $1}')
      if [[ "$runner_checksum_actual" == "$M_RUNNER_CHECKSUM_SHA256" ]]; then
        pass "Runner present, executable, and verified: $M_WRAPPER_RUNNER"
      else
        fail "Incorrect SHA256 checksum for runner $M_WRAPPER_RUNNER"
      fi
      if [[ -x "$WRAPPER" ]] && ! grep -Fq "exec \"$runner_file\"" "$WRAPPER"; then
        fail "Wrapper does not invoke registered runner"
      fi
    fi
  fi
fi

if [[ -f "$BIN_FILE" ]]; then
  pass "Binary present: $BIN_FILE"
  if [[ -x "$BIN_FILE" ]]; then
    pass "Binary executable"
  else
    fail "Binary lacks execution permission (chmod 755 $BIN_FILE)"
  fi
else
  fail "Binary NOT found: $BIN_FILE"
fi

if [[ -f "$BIN_FILE" ]]; then
  if command -v file >/dev/null 2>&1; then
    FT=$(file "$BIN_FILE" 2>/dev/null || true)
    if grep -qi "ELF 64-bit.*$EXPECTED_ELF_ARCH" <<< "$FT"; then
      pass "Format: ELF 64-bit $EXPECTED_ELF_ARCH"
    else
      fail "Unexpected format: ${FT:-<unknown>}"
    fi
  else
    warn "'file' utility not available; unable to verify ELF format"
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
      fail "Incorrect interpreter"
      note "Expected: $EXPECTED_INTERP"
      note "Found:    ${INTERP:-<empty>}"
      note "Reapply using: bash install.sh $APP_NAME -r"
    fi

    RP=$(patchelf --print-rpath "$BIN_FILE" 2>/dev/null || true)
    if [[ "$RP" == *"$EXPECTED_RPATH"* ]]; then
      pass "Rpath: $RP"
    else
      fail "Incorrect rpath (expected to contain $EXPECTED_RPATH, found: ${RP:-<empty>})"
    fi
  else
    warn "patchelf not installed; unable to verify interpreter/rpath"
  fi
fi

_verify_checksum() {
  local f="$1" expected="$2" desc="$3" actual="" algo="${M_CHECKSUM_ALGO:-sha256}"
  if [[ -z "$expected" ]]; then
    warn "No registered checksum; unable to verify integrity of $desc"
    note "Reinstall using: bash install.sh $APP_NAME -r"
    return 0
  fi
  case "$algo" in
    sha256) actual=$(sha256sum "$f" | cut -d' ' -f1) ;;
    sha512) actual=$(sha512sum "$f" | cut -d' ' -f1) ;;
    *)      fail "Unknown checksum algorithm in manifest: $algo"
            return 0 ;;
  esac
  if [[ "$actual" == "$expected" ]]; then
    pass "Integrity of $desc OK ($algo ${actual:0:16}...)"
  else
    fail "$desc changed since installation"
    note "Recorded: $expected"
    note "Current:  $actual"
    note "Reinstall using: bash install.sh $APP_NAME -r"
  fi
}

if [[ -f "$BIN_FILE" ]]; then
  _verify_checksum "$BIN_FILE" "$M_CHECKSUM_PATCHED" "binary"
fi

M_EXTRA_BINS=""
[[ -f "$MANIFEST" ]] && M_EXTRA_BINS=$(manifest_get extra_bins "$MANIFEST")

if [[ -n "$EXTRA_BINS" && -z "$M_EXTRA_BINS" ]]; then
  warn "Manifest lacks extra_bins (installed before this feature); companion binary audit skipped"
  note "Reinstall using: bash install.sh $APP_NAME -r to audit companion binaries as well"
elif [[ -n "$M_EXTRA_BINS" ]]; then
  for extra in $M_EXTRA_BINS; do
    extra_bin="$LIBEXEC_DIR/$extra"
    extra_wrapper="$PREFIX/bin/$extra"
    extra_sum=$(manifest_get "extra_checksum_$extra" "$MANIFEST")

    if [[ -f "$extra_bin" && -x "$extra_bin" ]]; then
      pass "Companion binary present and executable: $extra"
      _verify_checksum "$extra_bin" "$extra_sum" "companion binary $extra"
    else
      fail "Companion binary not found or not executable: $extra_bin"
    fi

    if [[ -x "$extra_wrapper" ]]; then
      pass "Companion binary wrapper: $extra_wrapper"
      if grep -q 'unset LD_PRELOAD' "$extra_wrapper" && grep -q 'unset LD_LIBRARY_PATH' "$extra_wrapper"; then
        pass "Wrapper for $extra unsets LD_PRELOAD and LD_LIBRARY_PATH"
      else
        fail "Wrapper for $extra does not unset LD_PRELOAD/LD_LIBRARY_PATH (risk of glibc crash)"
      fi
    else
      fail "Missing companion binary wrapper: $extra_wrapper"
    fi
  done
fi

CHECKSUM_SOURCE_INSTALLED="${M_CHECKSUM_SOURCE:-$CHECKSUM_SOURCE}"
if [[ "$CHECKSUM_SOURCE_INSTALLED" == "hashfile" && -n "$M_CHECKSUM_TARBALL" && -n "$M_TAG" ]]; then
  REG=$(lookup_hashfile "$APP_NAME/$M_TAG")
  if [[ -z "$REG" ]]; then
    warn "sha256.txt has no entry for $APP_NAME/$M_TAG"
  elif [[ "$REG" == "$M_CHECKSUM_TARBALL" ]]; then
    pass "Installed tarball matches sha256.txt"
  else
    fail "Installed tarball checksum does not match sha256.txt"
    note "Manifest:   $M_CHECKSUM_TARBALL"
    note "sha256.txt: $REG"
  fi
fi

case "${M_ATTEST:-}" in
  verified|verificada) pass "GitHub release attestation verified during installation" ;;
  failed|fallida)      warn "Attestation could not be verified during installation" ;;
  skipped|omitida)     warn "Attestation skipped during installation (gh was not available)"
                       note "Install gh and reinstall with --require-attestation for cryptographic verification." ;;
  "n/a"|"no-aplica")   pass "Attestation: N/A (this tool does not publish GitHub attestations)" ;;
  "")                  : ;;
  *)                   warn "Unknown attestation status: ${M_ATTEST:-}" ;;
esac

if [[ -x "$WRAPPER" ]]; then
  pass "Wrapper present: $WRAPPER"
  if grep -q 'unset LD_PRELOAD' "$WRAPPER" && grep -q 'unset LD_LIBRARY_PATH' "$WRAPPER"; then
    pass "Wrapper unsets LD_PRELOAD and LD_LIBRARY_PATH"
  else
    fail "Wrapper does not unset LD_PRELOAD/LD_LIBRARY_PATH (risk of glibc crash)"
  fi
else
  fail "Wrapper not found or not executable: $WRAPPER"
fi

if [[ -n "$WRAPPER_UNSET_ENV" && -x "$WRAPPER" ]]; then
  while IFS= read -r env_name; do
    [[ -z "$env_name" || "$env_name" == \#* ]] && continue
    if [[ ! "$env_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
      fail "Invalid WRAPPER_UNSET_ENV in registry"
    elif ! grep -Fxq "unset $env_name" "$WRAPPER"; then
      fail "Wrapper does not unset configured variable: $env_name"
    fi
  done <<< "$WRAPPER_UNSET_ENV"
fi

if [[ -n "${WRAPPER_DEFAULT_ARGS:-}" && -x "$WRAPPER" ]]; then
  _default_toks=()
  read -ra _default_toks <<< "$WRAPPER_DEFAULT_ARGS" || true
  _i=0
  for (( _i=0; _i<${#_default_toks[@]}; _i++ )); do
    if ! grep -qF -- "${_default_toks[_i]}" "$WRAPPER"; then
      warn "Wrapper does not include default arguments ($WRAPPER_DEFAULT_ARGS)"
      note "Reinstall using: bash install.sh $APP_NAME -r"
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
    pass "Alias OK: $alias_target -> $WRAPPER"
  else
    fail "Alias not found or does not point to wrapper: $alias_target"
  fi
done

EXEC_DIRECT_CONF="${EXEC_DIRECT:-false}"
M_EXEC_DIRECT=$(manifest_get exec_direct "$MANIFEST")
_EXEC_DIRECT="${M_EXEC_DIRECT:-$EXEC_DIRECT_CONF}"

if [[ "$_EXEC_DIRECT" == "true" ]]; then
  pass "Direct execution (EXEC_DIRECT): glibc loader and glibc DNS N/A"
else
  if [[ -f "$LOADER" ]]; then
    pass "Glibc loader present: $LOADER"
  else
    fail "Glibc loader NOT found. Run: pkg install glibc-repo glibc-runner"
  fi

  if [[ -f "$GLIBC_PREFIX/etc/nsswitch.conf" ]]; then
    pass "nsswitch.conf present (glibc DNS resolution)"
  else
    warn "Missing $GLIBC_PREFIX/etc/nsswitch.conf; DNS resolution may fail"
    note "Fix: printf 'hosts: files dns\n' > $GLIBC_PREFIX/etc/nsswitch.conf"
  fi

  if [[ -s "$GLIBC_PREFIX/etc/resolv.conf" ]]; then
    pass "Glibc resolv.conf present (DNS servers)"
  else
    warn "Missing $GLIBC_PREFIX/etc/resolv.conf; glibc DNS resolution may fail"
    note "Automatically regenerated on reinstall: bash install.sh $APP_NAME -r"
  fi
fi

if [[ -x "$WRAPPER" ]]; then
  if OUT=$("$WRAPPER" --version 2>&1); then
    RUNV=$(normalize_version "$OUT")
    pass "Execution successful (--version -> ${RUNV:-$OUT})"
    if [[ -n "${M_VERSION:-}" && -n "$RUNV" && "$RUNV" != "$(normalize_version "$M_VERSION")" ]]; then
      fail "Executed version ($RUNV) != manifest ($M_VERSION)"
    fi
  else
    fail "$APP_NAME failed to execute"
    note "Output: $(printf '%s' "$OUT" | head -2)"
  fi
fi

printf '\n=== Result: %d failures, %d warnings ===\n' "$FAILS" "$WARNS"
[[ "$FAILS" -gt 0 ]] && exit 1
exit 0
