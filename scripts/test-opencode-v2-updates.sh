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
    [ "$XDG_CONFIG_HOME" = "$EXPECTED_HOME/.local/share/ai-cli-termux/opencode-v2/config" ] || exit 92
    [ "$XDG_DATA_HOME" = "$EXPECTED_HOME/.local/share/ai-cli-termux/opencode-v2/data" ] || exit 93
    [ "$OPENCODE_DB" = "$XDG_DATA_HOME/opencode-v2.db" ] || exit 94
    printf 'server listening on http://127.0.0.1:43129\n'
    exec sleep 120
    ;;
  --server)
    shift
    printf '%s\n' "$$" > "$CLIENT_PID_FILE"
    printf '%s\n' "$OPENCODE_PASSWORD" > "$CLIENT_PASSWORD_FILE"
    printf '%s\n' "$@" > "$CLIENT_ARGS_FILE"
    [ -z "${OPENCODE_CONFIG_CONTENT:-}" ] || exit 95
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
