#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
runtime="$repo_dir/registry/lib/opencode-v2-runtime.sh"
test_tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
mkdir -p "$test_tmp_base"
test_root=$(mktemp -d "$test_tmp_base/opencode-v2-test.XXXXXX")
trap 'rm -rf "$test_root"' 0 HUP INT TERM

fake_bin="$test_root/bin"
fake_lib="$test_root/lib"
prefix="$test_root/prefix"
mkdir -p "$fake_bin" "$fake_lib" "$prefix/tmp"

cat > "$fake_bin/loader" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = --library-path ] || exit 90
shift 2
exec "$@"
EOF

cat > "$fake_bin/opencode" <<'EOF'
#!/bin/sh
set -eu
[ -z "${OPENCODE_CLI_CONFIG_CONTENT:-}" ] || exit 80

case "${1:-}" in
  --version|-v)
    printf '2.2.5\n'
    exit 0
    ;;
  debug)
    [ "$2" = paths ] || exit 89
    printf '%s\n' "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$OPENCODE_DB"
    exit 0
    ;;
  serve)
    printf 'serve\n' >> "$SERVER_CALLS"
    printf '%s\n' "$$" > "$SERVER_PID_FILE"
    [ -n "${OPENCODE_PASSWORD:-}" ] || exit 91
    [ -z "${OPENCODE_CLI_CONFIG_CONTENT:-}" ] || exit 100
    [ "$XDG_CONFIG_HOME" = "$EXPECTED_HOME/.local/share/ai-cli-termux/opencode-v2/config" ] || exit 92
    [ "$XDG_DATA_HOME" = "$EXPECTED_HOME/.local/share/ai-cli-termux/opencode-v2/data" ] || exit 93
    [ "$OPENCODE_DB" = "$XDG_DATA_HOME/opencode-v2.db" ] || exit 94
    [ -f "$XDG_CONFIG_HOME/opencode/opencode.json" ] || exit 102
    grep -Fq '"update":"disable"' "$XDG_CONFIG_HOME/opencode/opencode.json" || exit 103
    grep -Fq '"effect":"ask"' "$XDG_CONFIG_HOME/opencode/opencode.json" || exit 104
    printf 'server listening on http://127.0.0.1:43129\n'
    exec sleep 120
    ;;
  --server)
    shift
    printf '%s\n' "$$" > "$CLIENT_PID_FILE"
    printf '%s\n' "$OPENCODE_PASSWORD" > "$CLIENT_PASSWORD_FILE"
    printf '%s\n' "$@" > "$CLIENT_ARGS_FILE"
    [ -z "${OPENCODE_CONFIG_CONTENT:-}" ] || exit 95
    [ -z "${OPENCODE_CLI_CONFIG_CONTENT:-}" ] || exit 101
    [ -z "${OPENCODE_SERVER:-}" ] || exit 96
    touch "$CLIENT_STARTED_FILE"
    case "$CLIENT_MODE" in
      block)
        while [ ! -e "$CLIENT_RELEASE_FILE" ]; do sleep 1; done
        exit 23
        ;;
      hold)
        exec sleep 120
        ;;
      *) exit 97 ;;
    esac
    ;;
  *) exit 98 ;;
esac
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/bin/sh
set -eu
for curl_arg do :; done
case "$curl_arg" in
  http://127.0.0.1:*/api/info) ;;
  *) exit 99 ;;
esac
cat > "$CURL_CONFIG_FILE"
printf '{"version":"2.2.5"}\n'
EOF

chmod 755 "$fake_bin/loader" "$fake_bin/opencode" "$fake_bin/curl"

run_root="$test_root/normal"
run_home="$run_root/home"
mkdir -p "$run_home"
help_home="$test_root/help/home"
mkdir -p "$help_home"
if HOME="$help_home" OPENCODE_CONFIG_CONTENT='synthetic config' \
  sh "$runtime" "$fake_bin/loader" --library-path "$fake_lib" \
    "$fake_bin/opencode" --version > "$test_root/version.out"; then
  :
else
  printf 'FAIL: --version no pasó directo al binario\n' >&2
  exit 1
fi
grep -Fxq '2.2.5' "$test_root/version.out" || {
  printf 'FAIL: --version cambió su salida\n' >&2
  exit 1
}
[ ! -e "$help_home/.local/share/ai-cli-termux" ] || {
  printf 'FAIL: --version creó el perfil o el lock\n' >&2
  exit 1
}

debug_root="$test_root/debug"
debug_home="$debug_root/home"
mkdir -p "$debug_home"
export SERVER_CALLS="$debug_root/server-calls"
if HOME="$debug_home" PREFIX="$prefix" XDG_CONFIG_HOME=/outside \
  OPENCODE_DB=/outside/db sh "$runtime" "$fake_bin/loader" --library-path "$fake_lib" \
    "$fake_bin/opencode" debug paths > "$debug_root/paths.out"; then
  :
else
  printf 'FAIL: debug paths no funcionó sin servidor\n' >&2
  exit 1
fi
cat > "$debug_root/expected-paths" <<EOF
$debug_home/.local/share/ai-cli-termux/opencode-v2/config
$debug_home/.local/share/ai-cli-termux/opencode-v2/data
$debug_home/.local/share/ai-cli-termux/opencode-v2/data/opencode-v2.db
EOF
cmp -s "$debug_root/expected-paths" "$debug_root/paths.out" || {
  printf 'FAIL: debug paths heredó rutas ajenas al perfil v2\n' >&2
  exit 1
}
[ ! -e "$SERVER_CALLS" ] || { printf 'FAIL: debug paths inició un servidor\n' >&2; exit 1; }
[ ! -e "$debug_home/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] || {
  printf 'FAIL: debug paths dejó el lock\n' >&2
  exit 1
}
printf 'PASS: --version no crea perfil y debug paths usa el perfil aislado sin servidor\n'

existing_config_root="$test_root/existing-config"
existing_config_home="$existing_config_root/home"
existing_config_dir="$existing_config_home/.local/share/ai-cli-termux/opencode-v2/config/opencode"
mkdir -p "$existing_config_dir"
printf '{"model":"synthetic"}\n' > "$existing_config_dir/opencode.json"
cp "$existing_config_dir/opencode.json" "$existing_config_root/expected.json"
if HOME="$existing_config_home" PREFIX="$prefix" TMPDIR="$prefix/tmp" \
  sh "$runtime" "$fake_bin/loader" --library-path "$fake_lib" \
    "$fake_bin/opencode" debug paths > "$existing_config_root/paths.out"; then
  :
else
  printf 'FAIL: no aceptó una configuración v2 existente\n' >&2
  exit 1
fi
cmp -s "$existing_config_root/expected.json" "$existing_config_dir/opencode.json" || {
  printf 'FAIL: reemplazó la configuración v2 existente\n' >&2
  exit 1
}
printf 'PASS: conserva la configuración v2 existente\n'

symlink_root="$test_root/symlink"
symlink_home="$symlink_root/home"
symlink_target="$symlink_root/outside"
mkdir -p "$symlink_home/.local/share/ai-cli-termux/opencode-v2" "$symlink_target"
ln -s "$symlink_target" "$symlink_home/.local/share/ai-cli-termux/opencode-v2/config"
symlink_status=0
if HOME="$symlink_home" PREFIX="$prefix" sh "$runtime" \
  "$fake_bin/loader" --library-path "$fake_lib" "$fake_bin/opencode" debug paths \
  > "$symlink_root/paths.out" 2> "$symlink_root/paths.err"; then
  symlink_status=0
else
  symlink_status=$?
fi
[ "$symlink_status" -eq 1 ] || { printf 'FAIL: aceptó un directorio de perfil enlazado\n' >&2; exit 1; }
grep -qi 'symlink' "$symlink_root/paths.err" || {
  printf 'FAIL: no explicó el symlink rechazado\n' >&2
  exit 1
}
[ -d "$symlink_target" ] || { printf 'FAIL: alteró el destino del symlink\n' >&2; exit 1; }
[ ! -e "$symlink_home/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] || {
  printf 'FAIL: dejó el lock tras rechazar el symlink\n' >&2
  exit 1
}
printf 'PASS: rechaza symlinks del perfil sin tocar su destino\n'

external_root="$test_root/external-server"
external_home="$external_root/home"
mkdir -p "$external_home"
external_status=0
if HOME="$external_home" PREFIX="$prefix" sh "$runtime" \
  "$fake_bin/loader" --library-path "$fake_lib" "$fake_bin/opencode" \
  --server https://example.invalid > "$external_root/out" 2> "$external_root/err"; then
  external_status=0
else
  external_status=$?
fi
[ "$external_status" -eq 1 ] || { printf 'FAIL: permitió seleccionar un servidor externo\n' >&2; exit 1; }
grep -q 'servidores externos' "$external_root/err" || {
  printf 'FAIL: no explicó el rechazo del servidor externo\n' >&2
  exit 1
}
[ ! -e "$external_home/.local/share/ai-cli-termux" ] || {
  printf 'FAIL: creó estado antes de rechazar el servidor externo\n' >&2
  exit 1
}
printf 'PASS: rechaza --server externo antes de crear estado\n'

export SERVER_CALLS="$run_root/server-calls"
export CLIENT_STARTED_FILE="$run_root/client-started"
export CLIENT_RELEASE_FILE="$run_root/release-client"
export SERVER_PID_FILE="$run_root/server-pid"
export CLIENT_PID_FILE="$run_root/client-pid"
export CLIENT_PASSWORD_FILE="$run_root/client-password"
export CLIENT_ARGS_FILE="$run_root/client-args"
export CURL_CONFIG_FILE="$run_root/curl-config"
export EXPECTED_HOME="$run_home"
export CLIENT_MODE=block
export PATH="$fake_bin:$PATH"

mkdir -p "$run_home/.local/share/ai-cli-termux/opencode-v2/" "$prefix/libexec/opencode-v2"
printf 'version=2.2.5\n' > "$fake_bin/manifest.txt"

HOME="$run_home" PREFIX="$prefix" TMPDIR="$prefix/tmp" \
  OPENCODE_CLI_CONFIG_CONTENT='{"keybinds":{"app.exit":"none"}}' \
  sh "$runtime" "$fake_bin/loader" --library-path "$fake_lib" \
    "$fake_bin/opencode" --model 'small model' run 'prompt with spaces' \
    > "$run_root/runner.out" 2> "$run_root/runner.err" &
runner_pid=$!

attempt=0
while [ "$attempt" -lt 10 ] && [ ! -e "$CLIENT_STARTED_FILE" ]; do
  sleep 1
  attempt=$((attempt + 1))
done
if [ ! -e "$CLIENT_STARTED_FILE" ]; then
  cat "$run_root/runner.err" >&2
  kill -TERM "$runner_pid" 2>/dev/null || true
  wait "$runner_pid" 2>/dev/null || true
  printf 'FAIL: el runner no alcanzó el cliente local\n' >&2
  exit 1
fi

second_status=0
if HOME="$run_home" PREFIX="$prefix" TMPDIR="$prefix/tmp" \
  sh "$runtime" "$fake_bin/loader" --library-path "$fake_lib" \
    "$fake_bin/opencode" run 'segunda sesión' > "$run_root/second.out" 2> "$run_root/second.err"; then
  second_status=0
else
  second_status=$?
fi
[ "$second_status" -eq 1 ] || { printf 'FAIL: permitió una segunda sesión\n' >&2; exit 1; }
grep -q 'ya tiene una ejecución' "$run_root/second.err" || {
  printf 'FAIL: no explicó el lock ocupado\n' >&2
  exit 1
}
[ "$(wc -l < "$SERVER_CALLS" | tr -d ' ')" -eq 1 ] || {
  printf 'FAIL: la segunda sesión inició otro servidor\n' >&2
  exit 1
}
lock_dir="$run_home/.local/share/ai-cli-termux/recovery/opencode-v2/lock"
owner_server_pid=$(awk -F= '$1 == "server_pid" { print $2 }' "$lock_dir/owner")
owner_client_pid=$(awk -F= '$1 == "client_pid" { print $2 }' "$lock_dir/owner")
[ "$owner_server_pid" = "$(cat "$SERVER_PID_FILE")" ] || {
  printf 'FAIL: el lock no registró el PID real del servidor\n' >&2
  exit 1
}
[ "$owner_client_pid" = "$(cat "$CLIENT_PID_FILE")" ] || {
  printf 'FAIL: el lock no registró el PID real del cliente\n' >&2
  exit 1
}

curl_password=$(sed -n 's/^user = "opencode:\([a-f0-9]*\)"$/\1/p' "$CURL_CONFIG_FILE")
client_password=$(cat "$CLIENT_PASSWORD_FILE")
[ "${#curl_password}" -eq 48 ] && [ "$curl_password" = "$client_password" ] || {
  printf 'FAIL: la contraseña aleatoria no coincidió entre health y cliente\n' >&2
  exit 1
}
cat > "$run_root/expected-args" <<'EOF'
http://127.0.0.1:43129
--model
small model
run
prompt with spaces
EOF
cmp -s "$run_root/expected-args" "$CLIENT_ARGS_FILE" || {
  printf 'FAIL: el runner alteró los argumentos del usuario\n' >&2
  exit 1
}
grep -q 'opencode-v2-runner' "$run_root/runner.err" && {
  printf 'FAIL: el runner expuso su directorio temporal\n' >&2
  exit 1
}

touch "$CLIENT_RELEASE_FILE"
if wait "$runner_pid"; then
  runner_status=0
else
  runner_status=$?
fi
[ "$runner_status" -eq 23 ] || { printf 'FAIL: no propagó el exit del cliente\n' >&2; exit 1; }
[ ! -e "$lock_dir" ] || { printf 'FAIL: dejó el lock luego de cerrar\n' >&2; exit 1; }
if kill -0 "$(cat "$SERVER_PID_FILE")" 2>/dev/null; then
  printf 'FAIL: dejó el servidor efímero activo\n' >&2
  exit 1
fi
for temp_path in "$run_home/.local/share/ai-cli-termux/opencode-v2/tmp"/opencode-v2-runner.*; do
  [ ! -e "$temp_path" ] || { printf 'FAIL: dejó temporales del runner\n' >&2; exit 1; }
done
printf 'PASS: ejecución diaria con servidor privado, lock, argumentos y cleanup\n'

signal_root="$test_root/signal"
signal_home="$signal_root/home"
mkdir -p "$signal_home" "$prefix/libexec/opencode-v2"
export SERVER_CALLS="$signal_root/server-calls"
export CLIENT_STARTED_FILE="$signal_root/client-started"
export CLIENT_RELEASE_FILE="$signal_root/release-client"
export SERVER_PID_FILE="$signal_root/server-pid"
export CLIENT_PID_FILE="$signal_root/client-pid"
export CLIENT_PASSWORD_FILE="$signal_root/client-password"
export CLIENT_ARGS_FILE="$signal_root/client-args"
export CURL_CONFIG_FILE="$signal_root/curl-config"
export EXPECTED_HOME="$signal_home"
export CLIENT_MODE=hold

HOME="$signal_home" PREFIX="$prefix" TMPDIR="$prefix/tmp" \
  sh "$runtime" "$fake_bin/loader" --library-path "$fake_lib" \
    "$fake_bin/opencode" > "$signal_root/runner.out" 2> "$signal_root/runner.err" &
signal_runner_pid=$!
attempt=0
while [ "$attempt" -lt 10 ] && [ ! -e "$CLIENT_STARTED_FILE" ]; do
  sleep 1
  attempt=$((attempt + 1))
done
if [ ! -e "$CLIENT_STARTED_FILE" ]; then
  cat "$signal_root/runner.err" >&2
  kill -TERM "$signal_runner_pid" 2>/dev/null || true
  wait "$signal_runner_pid" 2>/dev/null || true
  printf 'FAIL: el runner no alcanzó el cliente antes de la señal\n' >&2
  exit 1
fi
kill -TERM "$signal_runner_pid"
if wait "$signal_runner_pid"; then
  signal_status=0
else
  signal_status=$?
fi
[ "$signal_status" -eq 143 ] || { printf 'FAIL: no propagó TERM como exit 143\n' >&2; exit 1; }
[ ! -e "$signal_home/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] || {
  printf 'FAIL: dejó el lock luego de TERM\n' >&2
  exit 1
}
if kill -0 "$(cat "$SERVER_PID_FILE")" 2>/dev/null || kill -0 "$(cat "$CLIENT_PID_FILE")" 2>/dev/null; then
  printf 'FAIL: dejó un proceso privado luego de TERM\n' >&2
  exit 1
fi
printf 'PASS: TERM cierra y espera cliente, servidor y lector privados\n'

if [ -d /data/data/com.termux ]; then
  transaction_root="$test_root/installer-transaction"
  transaction_repo="$transaction_root/repo"
  transaction_bin="$transaction_root/bin"
  transaction_home="$transaction_root/home"
  transaction_prefix="$transaction_root/prefix"
  transaction_tmp="$transaction_root/tmp"
  transaction_recovery="$transaction_home/.local/share/ai-cli-termux/recovery/fake"
  transaction_phases="$transaction_root/phases"
  mkdir -p "$transaction_repo/registry/lib" "$transaction_bin" "$transaction_home" \
    "$transaction_prefix/tmp" "$transaction_tmp"
  cp "$repo_dir/install.sh" "$transaction_repo/install.sh"
  cp "$repo_dir/registry/lib/releases.sh" "$transaction_repo/registry/lib/releases.sh"
  cat > "$transaction_bin/curl" <<'EOF'
#!/bin/sh
set -eu
output_file=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output_file=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output_file" ] || exit 97
printf 'synthetic installer archive\n' > "$output_file"
EOF
  cat > "$transaction_bin/tar" <<'EOF'
#!/bin/sh
set -eu
extract_dir=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C) extract_dir=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$extract_dir" ] || exit 98
mkdir -p "$extract_dir"
cat > "$extract_dir/fake" <<BINARY
#!/bin/sh
printf '%s\n' '$MOCK_BINARY_VERSION'
BINARY
chmod 755 "$extract_dir/fake"
EOF
  cat > "$transaction_bin/file" <<'EOF'
#!/bin/sh
set -eu
case "$(uname -m)" in
  aarch64) elf_arch='ARM aarch64' ;;
  x86_64) elf_arch='x86-64' ;;
  *) exit 99 ;;
esac
case "$1" in
  *.tar.gz) printf 'gzip compressed data\n' ;;
  *) printf 'ELF 64-bit LSB pie executable, %s\n' "$elf_arch" ;;
esac
EOF
  cat > "$transaction_bin/pkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MOCK_TX_PKG_LOG"
exit 99
EOF
  chmod 755 "$transaction_bin/curl" "$transaction_bin/tar" \
    "$transaction_bin/file" "$transaction_bin/pkg"

  cat > "$transaction_repo/registry/fake.conf" <<'EOF'
APP_NAME="fake"
DISPLAY_NAME="Synthetic CLI"
RELEASE_SOURCE="url_template"
DOWNLOAD_URL_TEMPLATE="https://fixture.invalid/fake-{VERSION}-{ARCH}.tar.gz"
CHECKSUM_ALGO="sha256"
CHECKSUM_SOURCE="hashfile"
ELF_NAME="fake"
NEEDS_PATCHELF=false
EXEC_DIRECT=true
RUNTIME_SETUP="existing"
VERSION_MAJOR="1"
RELEASE_CHANNEL="stable"

if [[ "${MOCK_TX_HOOK:-0}" == 1 ]]; then
  install_transaction_hook() {
    local phase="$1"
    printf '%s\n' "$phase" >> "$MOCK_TX_PHASES"
    case "$phase" in
      prepare)
        BACKUP_DIR="$MOCK_TX_RECOVERY/current/bundle"
        mkdir -p "$(dirname "$BACKUP_DIR")"
        ;;
      validate)
        [[ -f "$MANIFEST" && "$INSTALL_DONE" == false ]] || return 1
        [[ "$MOCK_TX_FAIL_PHASE" != validate ]] || return 1
        ;;
      commit)
        [[ "$MOCK_TX_FAIL_PHASE" != commit ]] || return 1
        if [[ -d "$BACKUP_DIR" ]]; then
          if [[ -d "$MOCK_TX_RECOVERY/previous" ]]; then
            mv "$MOCK_TX_RECOVERY/previous" "$MOCK_TX_RECOVERY/previous.old"
          fi
          mv "$BACKUP_DIR" "$MOCK_TX_RECOVERY/previous"
          rm -rf "$MOCK_TX_RECOVERY/previous.old"
        fi
        ;;
      rollback)
        if [[ -d "$BACKUP_DIR" ]]; then
          rm -rf "$LIBEXEC_DIR"
          mv "$BACKUP_DIR" "$LIBEXEC_DIR"
          if [[ -f "$LIBEXEC_DIR/.wrapper" ]]; then
            mv "$LIBEXEC_DIR/.wrapper" "$WRAPPER"
          else
            rm -f "$WRAPPER"
          fi
        elif [[ "$FRESH_INSTALL" == true ]]; then
          rm -rf "$LIBEXEC_DIR"
          rm -f "$WRAPPER"
        fi
        ;;
      *) return 2 ;;
    esac
  }
fi
EOF
  printf 'synthetic installer archive\n' > "$transaction_root/archive"
  transaction_hash=$(sha256sum "$transaction_root/archive" | awk '{print $1}')
  printf 'fake/v1.0.0 %s\nfake/v1.1.0 %s\nfake/v1.2.0 %s\n' \
    "$transaction_hash" "$transaction_hash" "$transaction_hash" \
    > "$transaction_repo/sha256.txt"
  export MOCK_TX_PKG_LOG="$transaction_root/pkg.log"
  export MOCK_TX_PHASES="$transaction_phases"
  export MOCK_TX_RECOVERY="$transaction_recovery"

  run_transaction_install() {
    txn_hook_mode="$1"
    txn_binary_version="$2"
    txn_fail_phase="$3"
    shift 3
    if MOCK_TX_HOOK="$txn_hook_mode" MOCK_BINARY_VERSION="$txn_binary_version" \
      MOCK_TX_FAIL_PHASE="$txn_fail_phase" PREFIX="$transaction_prefix" \
      HOME="$transaction_home" TMPDIR="$transaction_tmp" \
      PATH="$transaction_bin:$PATH" bash "$transaction_repo/install.sh" fake "$@" \
      > "$transaction_root/stdout" 2> "$transaction_root/stderr"; then
      txn_status=0
    else
      txn_status=$?
    fi
  }

  run_transaction_install 0 1.0.0 '' -v 1.0.0
  [ "$txn_status" -eq 0 ] || {
    cat "$transaction_root/stderr" >&2
    printf 'FAIL: el flujo legado sin hook transaccional dejó de instalar\n' >&2
    exit 1
  }
  [ ! -e "$transaction_phases" ] || { printf 'FAIL: ejecutó hooks sin declararlos\n' >&2; exit 1; }
  [ "$("$transaction_prefix/bin/fake" --version)" = 1.0.0 ] || {
    printf 'FAIL: el flujo legado no conservó el wrapper funcional\n' >&2
    exit 1
  }

  run_transaction_install 1 1.1.0 '' -r -v 1.1.0
  [ "$txn_status" -eq 0 ] || {
    cat "$transaction_root/stderr" >&2
    printf 'FAIL: el flujo transaccional no completó prepare/validate/commit\n' >&2
    exit 1
  }
  printf 'prepare\nvalidate\ncommit\n' > "$transaction_root/expected-phases"
  cmp -s "$transaction_root/expected-phases" "$transaction_phases" || {
    printf 'FAIL: el instalador no respetó el orden de fases\n' >&2
    exit 1
  }
  grep -Fxq 'version=1.0.0' "$transaction_recovery/previous/manifest.txt" || {
    printf 'FAIL: commit no conservó el bundle anterior\n' >&2
    exit 1
  }
  [ "$("$transaction_prefix/bin/fake" --version)" = 1.1.0 ] || {
    printf 'FAIL: el wrapper nuevo no quedó funcional después del commit\n' >&2
    exit 1
  }

  : > "$transaction_phases"
  run_transaction_install 1 1.2.0 validate -r -v 1.2.0
  [ "$txn_status" -eq 1 ] || { printf 'FAIL: no propagó el fallo de validate\n' >&2; exit 1; }
  printf 'prepare\nvalidate\nrollback\n' > "$transaction_root/expected-phases"
  cmp -s "$transaction_root/expected-phases" "$transaction_phases" || {
    printf 'FAIL: no ejecutó rollback después de fallar validate\n' >&2
    exit 1
  }
  [ "$("$transaction_prefix/bin/fake" --version)" = 1.1.0 ] || {
    printf 'FAIL: validate fallido no restauró el wrapper anterior\n' >&2
    exit 1
  }
  grep -Fxq 'version=1.1.0' "$transaction_prefix/libexec/fake/manifest.txt" || {
    printf 'FAIL: validate fallido dejó un manifest mezclado\n' >&2
    exit 1
  }

  : > "$transaction_phases"
  run_transaction_install 1 1.2.0 commit -r -v 1.2.0
  [ "$txn_status" -eq 1 ] || { printf 'FAIL: no propagó el fallo de commit\n' >&2; exit 1; }
  printf 'prepare\nvalidate\ncommit\nrollback\n' > "$transaction_root/expected-phases"
  cmp -s "$transaction_root/expected-phases" "$transaction_phases" || {
    printf 'FAIL: no ejecutó rollback después de fallar commit\n' >&2
    exit 1
  }
  [ "$("$transaction_prefix/bin/fake" --version)" = 1.1.0 ] || {
    printf 'FAIL: commit fallido no restauró el wrapper anterior\n' >&2
    exit 1
  }
  [ ! -s "$MOCK_TX_PKG_LOG" ] || { printf 'FAIL: la transacción invocó pkg\n' >&2; exit 1; }
  printf 'PASS: hooks transaccionales: flujo legado, orden, validate/commit fallidos y rollback\n'
else
  printf 'SKIP: integración real de install.sh requiere ejecutarse dentro de Termux\n'
fi
