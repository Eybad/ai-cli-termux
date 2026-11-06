#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

repo_dir=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
if [[ ! -d "$tmp_base" || ! -w "$tmp_base" ]]; then
  tmp_base=/tmp
fi
[[ -d "$tmp_base" && -w "$tmp_base" ]] || {
  printf 'No hay un temporal escribible en TMPDIR, PREFIX/tmp o /tmp.\n' >&2
  exit 1
}

test_root=$(mktemp -d "$tmp_base/opencode-runner-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

runner_script="$repo_dir/registry/lib/opencode-runner.sh"
[[ -f "$runner_script" && -x "$runner_script" ]] || fail "opencode-runner.sh no encontrado o no ejecutable"

# Helper directory for isolated TMPDIR during tests
runner_tmpdir="$test_root/tmp"
mkdir -p "$runner_tmpdir"

# Mock binary that records invocations and verifies direct exec behavior
mock_bin="$test_root/mock-opencode"
manifest_file="$test_root/manifest.txt"
cat > "$manifest_file" <<'EOF'
manifest_version=2
version=2.2.5
EOF

cat > "$mock_bin" <<'EOF'
#!/bin/sh
# Check if any runner dir was created
if ls -d "$TMPDIR"/opencode-runner.* >/dev/null 2>&1; then
  echo "TMPDIR_CREATED" > "$MOCK_INVOKE_LOG"
else
  echo "DIRECT_EXEC" > "$MOCK_INVOKE_LOG"
fi
printf '%s\n' "$@" >> "$MOCK_INVOKE_LOG"
exit 0
EOF
chmod 755 "$mock_bin"

invoke_log="$test_root/mock-invoke.log"
export MOCK_INVOKE_LOG="$invoke_log"

# 1. Test direct exec (no temporary files created)
direct_exec_cases=(
  "-h"
  "--help"
  "help"
  "-v"
  "--version"
  "--completions"
  "--completions=bash"
  "debug paths"
  "serve"
  "--server http://127.0.0.1:1234"
  "--server=http://127.0.0.1:1234"
)

for c in "${direct_exec_cases[@]}"; do
  rm -f "$invoke_log"
  # shellcheck disable=SC2086
  TMPDIR="$runner_tmpdir" sh "$runner_script" "$mock_bin" $c
  grep -Fxq "DIRECT_EXEC" "$invoke_log" || fail "direct exec falló para: $c (creó temporales)"
done

printf 'PASS: exec directo sin crear temporales para comandos de inspección\n'

# 2. Test option skipping: flags with values do not trigger subcommand blocks
rm -f "$invoke_log"
# In mock mode, if it does not trigger the block, it will attempt to launch the ephemeral server.
# Here we test with direct exec flags combined with option skipping
TMPDIR="$runner_tmpdir" sh "$runner_script" "$mock_bin" --title upgrade --version
grep -Fxq "DIRECT_EXEC" "$invoke_log" || fail "opción --title upgrade interfirió con direct exec"

printf 'PASS: flags con valor no interfieren con la detección de subcomandos\n'

# 3. Test blocked subcommands (must exit 1 with specific error message on stderr)
test_blocked() {
  subcmd="$1"
  expected_msg="$2"
  err_file="$test_root/blocked-$subcmd.err"
  if TMPDIR="$runner_tmpdir" sh "$runner_script" "$mock_bin" "$subcmd" 2>"$err_file"; then
    fail "subcomando bloqueado '$subcmd' no salió con error"
  else
    rc=$?
    [[ $rc -eq 1 ]] || fail "subcomando '$subcmd' devolvió exit code $rc en vez de 1"
    grep -Fq "$expected_msg" "$err_file" || fail "mensaje de error inesperado para '$subcmd'"
  fi
}

test_blocked "upgrade" "Internal updater is disabled on Termux. Use: aicli update opencode"
test_blocked "update" "Internal updater is disabled on Termux. Use: aicli update opencode"
test_blocked "uninstall" "Uninstallation on Termux is managed with aicli. Use: aicli remove opencode"
test_blocked "service" "Background daemon ('opencode service') is not supported"

printf 'PASS: subcomandos bloqueados devuelven exit code 1 y mensajes esperados\n'

# 4. Test ephemeral server orchestration mock
# Create mock opencode that implements server and client modes
cat > "$mock_bin" <<'EOF'
#!/bin/sh
if [ "$1" = "serve" ]; then
  for a in "$@"; do
    if [ "$a" = "--stubborn" ]; then
      trap '' TERM
      while true; do sleep 1; done
    fi
  done

  # 1. Verify environment does NOT contain passwords
  if [ -n "${OPENCODE_PASSWORD+x}" ] || [ -n "${OPENCODE_SERVER_PASSWORD+x}" ]; then
    echo "PASSWORD_LEAK_IN_SERVER_ENV" > "$TEST_ROOT/server-env-check.err"
    exit 1
  fi
  # Verify /proc/$$/environ if accessible
  if [ -r "/proc/$$/environ" ]; then
    if tr '\0' '\n' < "/proc/$$/environ" | grep -E '^OPENCODE_(SERVER_)?PASSWORD=' >/dev/null; then
      echo "PASSWORD_LEAK_IN_SERVER_PROC" > "$TEST_ROOT/server-env-check.err"
      exit 1
    fi
  fi

  # Start minimal HTTP server serving /api/info in python
  port_file="$TEST_ROOT/server_port.$$"
  SERVER_PID=$$ python3 -c "
import http.server, socketserver, json, os

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/api/info':
            auth = self.headers.get('Authorization', '')
            if not auth.startswith('Basic '):
                self.send_response(401)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            srv_pid = int(os.environ.get('SERVER_PID', os.getpid()))
            data = json.dumps({'version': '2.2.5', 'pid': srv_pid})
            self.wfile.write(data.encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()
    def log_message(self, format, *args):
        pass

with socketserver.TCPServer(('127.0.0.1', 0), Handler) as httpd:
    port = httpd.server_address[1]
    with open('$port_file', 'w') as f:
        f.write(str(port))
    httpd.serve_forever()
" &
  py_pid=$!
  trap 'kill -TERM "$py_pid" 2>/dev/null; exit 0' TERM INT EXIT

  while [ ! -f "$port_file" ]; do
    sleep 0.05 2>/dev/null || sleep 1
  done
  srv_port=$(cat "$port_file")

  printf 'server listening on http://127.0.0.1:%s\n' "$srv_port"
  printf 'server password test-pw-1234567890\n'
  wait "$py_pid" 2>/dev/null || true
  exit 0
else
  # Client mode
  # Check OPENCODE_PASSWORD
  if [ "$OPENCODE_PASSWORD" != "test-pw-1234567890" ]; then
    echo "CLIENT_BAD_PASSWORD: $OPENCODE_PASSWORD" > "$TEST_ROOT/client-check.err"
    exit 1
  fi
  # Read stdin
  stdin_content=$(cat)
  echo "STDIN:$stdin_content" > "$TEST_ROOT/client-stdin.log"
  echo "CLIENT_OK" > "$TEST_ROOT/client-check.log"
  exit 0
fi
EOF
chmod 755 "$mock_bin"

export TEST_ROOT="$test_root"
echo "hello from stdin" | TMPDIR="$runner_tmpdir" sh "$runner_script" "$mock_bin" run --title test

[[ -f "$test_root/client-check.log" ]] || fail "el cliente no ejecutó correctamente"
grep -Fxq "CLIENT_OK" "$test_root/client-check.log" || fail "falló la verificación del cliente"
grep -Fxq "STDIN:hello from stdin" "$test_root/client-stdin.log" || fail "falló la preservación de stdin (fd 3)"
[[ ! -f "$test_root/server-env-check.err" ]] || fail "fuga de contraseñas detectada en el entorno del servidor"

printf 'PASS: orquestación de servidor efímero, exclusión de credenciales y stdin preservado\n'

# 5. Test concurrency: 3 concurrent sessions
pids=()
for i in 1 2 3; do
  (
    echo "session-$i" | TMPDIR="$runner_tmpdir" sh "$runner_script" "$mock_bin" run --title "session-$i" >/dev/null
  ) &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid" || fail "sesión concurrente $pid falló"
done

# Verify no leftover runner directories
leftovers=$(find "$runner_tmpdir" -mindepth 1 -maxdepth 1 -name 'opencode-runner.*' 2>/dev/null || true)
[[ -z "$leftovers" ]] || fail "quedaron directorios temporales residuales tras concurrencia"

printf 'PASS: 3 sesiones concurrentes completadas sin residuos temporales\n'

# 6. Test reap_stale_runners
# Create stale directory with dead runner and a server process
stale_dir=$(mktemp -d "$runner_tmpdir/opencode-runner.staleXXXXXX")
# Launch background process matching server cmdline
# We invoke mock_bin serve --hostname 127.0.0.1 --port 0
"$mock_bin" serve --hostname 127.0.0.1 --port 0 >/dev/null 2>&1 &
stale_srv_pid=$!
# Wait for server to start
sleep 0.2

# Find start time
get_proc_start() {
  awk '{n=split($0, a, ") "); split(a[2], b, " "); print b[20]}' "/proc/$1/stat" 2>/dev/null || echo ""
}
stale_srv_start=$(get_proc_start "$stale_srv_pid")

cat > "$stale_dir/owner.env" <<EOF
runner_pid=99999999
runner_start=1
server_pid=$stale_srv_pid
server_start=$stale_srv_start
EOF

# Invoking ephemeral server mode triggers reap_stale_runners
echo "dummy" | TMPDIR="$runner_tmpdir" sh "$runner_script" "$mock_bin" run --title reap1 >/dev/null

# Stale server should have been terminated with SIGTERM
if kill -0 "$stale_srv_pid" 2>/dev/null; then
  kill -9 "$stale_srv_pid" 2>/dev/null || true
  fail "reap_stale_runners no terminó el servidor huérfano"
fi
[[ ! -d "$stale_dir" ]] || fail "reap_stale_runners no eliminó el directorio huérfano"

# Active session directory (runner_pid = $$) must NOT be reaped
active_dir=$(mktemp -d "$runner_tmpdir/opencode-runner.activeXXXXXX")
cat > "$active_dir/owner.env" <<EOF
runner_pid=$$
runner_start=$(get_proc_start "$$")
server_pid=99999998
server_start=1
EOF

echo "dummy" | TMPDIR="$runner_tmpdir" sh "$runner_script" "$mock_bin" run --title reap2 >/dev/null
[[ -d "$active_dir" ]] || fail "reap_stale_runners eliminó un directorio de sesión activa"
rm -rf "$active_dir"

# Server ignoring SIGTERM: reap_stale_runners must NOT send SIGKILL, preserves owner.env and warns on stderr
stubborn_dir=$(mktemp -d "$runner_tmpdir/opencode-runner.stubbornXXXXXX")
"$mock_bin" serve --hostname 127.0.0.1 --port 0 --stubborn >/dev/null 2>&1 &
stubborn_pid=$!
sleep 0.2
stubborn_start=$(get_proc_start "$stubborn_pid")

cat > "$stubborn_dir/owner.env" <<EOF
runner_pid=99999999
runner_start=1
server_pid=$stubborn_pid
server_start=$stubborn_start
EOF

warn_log="$test_root/reap-warn.log"
echo "dummy" | TMPDIR="$runner_tmpdir" sh "$runner_script" "$mock_bin" run --title reap3 2>"$warn_log" >/dev/null || true

# Stubborn server must STILL be alive (runner must NOT send SIGKILL)
if ! kill -0 "$stubborn_pid" 2>/dev/null; then
  fail "reap_stale_runners envió SIGKILL al servidor renuente"
fi
kill -9 "$stubborn_pid" 2>/dev/null || true
wait "$stubborn_pid" 2>/dev/null || true

[[ -d "$stubborn_dir" ]] || fail "reap_stale_runners no conservó el directorio del servidor renuente"
[[ -f "$stubborn_dir/owner.env" ]] || fail "reap_stale_runners no conservó owner.env"
grep -Fq "WARN: Failed to terminate orphaned server" "$warn_log" || fail "reap_stale_runners did not emit expected WARN on stderr"
rm -rf "$stubborn_dir"

printf 'PASS: reap_stale_runners limpia huérfanos con SIGTERM, respeta sesiones vivas y es conservador\n'
