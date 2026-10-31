#!/usr/bin/env bash
set -euo pipefail

repo_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd)
test_tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
[[ -d "$test_tmp_base" && -w "$test_tmp_base" ]] || {
  printf 'No hay un temporal escribible en TMPDIR o PREFIX/tmp.\n' >&2
  exit 1
}
test_root=$(mktemp -d "$test_tmp_base/opencode-v2-config.XXXXXX")
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

test_home="$test_root/home with spaces"
mkdir -p "$test_home"
export HOME="$test_home"
SCRIPT_DIR=$repo_dir
. "$repo_dir/registry/opencode-v2.conf"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ "$APP_NAME" == opencode-v2 && "$DISPLAY_NAME" == 'OpenCode v2' ]] ||
  fail 'la identidad del registro no coincide con v2'
[[ "$REPO" == anomalyco/opencode && "$ELF_NAME" == opencode ]] ||
  fail 'la fuente o el ELF no coinciden con el release oficial'
[[ "$ARCHIVE_TEMPLATE" == 'opencode-linux-{ARCH}.tar.gz' ]] ||
  fail 'el asset configurado no es el tarball arm64 publicado'
[[ "$CHECKSUM_SOURCE" == release_digest && "$CHECKSUM_ALGO" == sha256 ]] ||
  fail 'la integridad no usa el digest SHA256 publicado'
[[ "$VERSION_MAJOR" == 2 && "$RELEASE_CHANNEL" == stable ]] ||
  fail 'la política no limita la release a stable major 2'
[[ "$RELEASE_POLICY_FILE" == registry/releases/opencode-v2.json ]] ||
  fail 'el instalador no usa el catálogo v2'
[[ "$DOWNLOAD_MAX_TIME" == 600 ]] ||
  fail 'el tiempo de descarga no alcanza para el asset de v2'
[[ "$RUNTIME_SETUP" == existing && "$NEEDS_PATCHELF" == false &&
  "$EXEC_DIRECT" == false ]] || fail 'v2 intentaría provisionar o ejecutar otro runtime'
[[ "$WRAPPER_RUNNER" == opencode-v2-runtime.sh ]] ||
  fail 'el wrapper no usa el runner de v2'
[[ "$DESCRIPTION" != *'"'* && "$DESCRIPTION" != *$'\n'* ]] ||
  fail 'DESCRIPTION no cumple el contrato de una línea'
[[ "$WRAPPER_ENV" == *"XDG_CONFIG_HOME=$HOME/.local/share/ai-cli-termux/opencode-v2/config"* ]] ||
  fail 'WRAPPER_ENV no conserva rutas HOME con espacios'
for environment_name in \
  OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT \
  OPENCODE_CLI_CONFIG_CONTENT OPENCODE_TUI_CONFIG OPENCODE_PERMISSION \
  OPENCODE_SERVER OPENCODE_SERVER_PASSWORD OPENCODE_PASSWORD \
  OPENCODE_CONFIG_PROJECT_DISABLE; do
  grep -Fxq "$environment_name" <<< "$WRAPPER_UNSET_ENV" ||
    fail "falta limpiar $environment_name"
done
[[ ! -e "$HOME/.local/share/ai-cli-termux" ]] ||
  fail 'cargar el registro creó datos persistentes'
printf 'PASS: el registro define v2 aislada y no crea perfil al cargarse\n'

LIBEXEC_DIR="$test_root/bundle"
mkdir -p "$LIBEXEC_DIR"
pre_wrapper_hook
cmp -s "$repo_dir/registry/lib/opencode-v2-runtime.sh" \
  "$LIBEXEC_DIR/$WRAPPER_RUNNER" || fail 'el hook no copió el runner exacto'
[[ -x "$LIBEXEC_DIR/$WRAPPER_RUNNER" ]] || fail 'el runner copiado no quedó ejecutable'
if pre_wrapper_hook > /dev/null 2> "$test_root/pre-wrapper.err"; then
  fail 'el hook sobrescribió un runner existente'
fi
cmp -s "$repo_dir/registry/lib/opencode-v2-runtime.sh" \
  "$LIBEXEC_DIR/$WRAPPER_RUNNER" || fail 'el rechazo alteró el runner existente'
printf 'PASS: el hook instala el runner una sola vez y evita sobrescrituras\n'

hook_repo="$test_root/hook repo"
hook_log="$test_root/transaction.log"
mkdir -p "$hook_repo/registry/lib"
cat > "$hook_repo/registry/lib/opencode-v2-runtime.sh" <<'EOF'
opencode_v2_runtime_transaction() {
  printf '%s:%s\n' "$1" "$opencode_v2_runtime_project_root" >> "$OPENCODE_HOOK_LOG"
}
EOF
export OPENCODE_HOOK_LOG="$hook_log"
SCRIPT_DIR=$hook_repo
. "$repo_dir/registry/opencode-v2.conf"
for transaction_phase in prepare validate commit rollback; do
  install_transaction_hook "$transaction_phase"
done
cat > "$test_root/expected-phases" <<EOF
prepare:$hook_repo
validate:$hook_repo
commit:$hook_repo
rollback:$hook_repo
EOF
cmp -s "$test_root/expected-phases" "$hook_log" ||
  fail 'el hook no delegó cada fase con la raíz correcta'
if install_transaction_hook invalid > /dev/null 2> "$test_root/invalid-phase.err"; then
  fail 'el hook aceptó una fase transaccional inválida'
fi
printf 'PASS: el hook delega las cuatro fases y rechaza fases desconocidas\n'
