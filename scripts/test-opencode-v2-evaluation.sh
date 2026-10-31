#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd)
test_tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
mkdir -p "$test_tmp_base"
test_root=$(mktemp -d "$test_tmp_base/opencode-v2-evaluation-test.XXXXXX")
trap 'rm -rf "$test_root"' 0 HUP INT TERM

fake_bin="$test_root/bin"
prefix="$test_root/prefix with spaces"
mkdir -p "$fake_bin" "$prefix/tmp" "$prefix/glibc/lib"

cat > "$fake_bin/loader" <<'EOF'
#!/bin/sh
set -eu
[ "$1" = --library-path ] || exit 80
shift 2
exec "$@"
EOF

cat > "$fake_bin/opencode" <<'EOF'
#!/bin/sh
set -eu

case "${1:-}" in
  --version|-v)
    printf 'opencode v2.2.5\n'
    ;;
  debug)
    [ "${2:-}" = paths ] || exit 81
    printf '%s\n' "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$OPENCODE_DB"
    ;;
  serve)
    printf 'server listening on http://127.0.0.1:43129\n'
    exec sleep 120
    ;;
  --server)
    shift 2
    if [ "$#" -eq 0 ]; then
      printf 'TUI\n'
      exit 0
    fi
    [ "$#" -eq 4 ] && [ "$1" = session ] && [ "$2" = list ] &&
      [ "$3" = --format ] && [ "$4" = json ] || exit 82
    printf '[]\n'
    ;;
  *)
    exit 83
    ;;
esac
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/bin/sh
set -eu
output=''
url=''
follow_redirects=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output=$2
      shift 2
      ;;
    --config|-H|--connect-timeout|--max-time|--retry|--retry-delay|--proto|--proto-redir)
      shift 2
      ;;
    --tlsv1.2|--fail|--silent|--show-error|--retry-all-errors)
      shift
      ;;
    --location)
      follow_redirects=true
      shift
      ;;
    *)
      url=$1
      shift
      ;;
  esac
done
case "$url" in
  https://api.github.com/repos/anomalyco/opencode/releases/tags/v2.2.5)
    printf 'api\n' >> "$FAKE_CURL_LOG"
    cp "$FAKE_RELEASE_JSON" "$output"
    ;;
  https://github.com/anomalyco/opencode/releases/download/v2.2.5/opencode-linux-arm64.tar.gz)
    printf 'asset\n' >> "$FAKE_CURL_LOG"
    if [ "$follow_redirects" = true ]; then
      cp "$FAKE_ARCHIVE" "$output"
    else
      : > "$output"
    fi
    ;;
  http://127.0.0.1:*/api/info)
    cat >/dev/null
    printf '{"version":"2.2.5"}\n'
    ;;
  *)
    printf 'unexpected curl URL: %s\n' "$url" >&2
    exit 84
    ;;
esac
EOF

chmod 755 "$fake_bin/loader" "$fake_bin/opencode" "$fake_bin/curl"
cp "$fake_bin/loader" "$prefix/glibc/lib/ld-linux-aarch64.so.1"
chmod 755 "$prefix/glibc/lib/ld-linux-aarch64.so.1"
mkdir "$test_root/archive"
cp "$fake_bin/opencode" "$test_root/archive/opencode"
tar -czf "$test_root/candidate.tar.gz" -C "$test_root/archive" opencode
printf 'version=v2.2.5\n' > "$test_root/archive/manifest.txt"
archive_sha256=$(sha256sum "$test_root/candidate.tar.gz" | awk '{ print $1 }')
cat > "$test_root/release.json" <<EOF
{"tag_name":"v2.2.5","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v2.2.5/opencode-linux-arm64.tar.gz","digest":"sha256:$archive_sha256"}]}
EOF

export FAKE_RELEASE_JSON="$test_root/release.json"
export FAKE_ARCHIVE="$test_root/candidate.tar.gz"
export FAKE_CURL_LOG="$test_root/curl.log"
export PATH="$fake_bin:$PATH"
export PREFIX="$prefix"
export TMPDIR="$prefix/tmp"

if sh "$repo_dir/scripts/opencode-v2-maintenance.sh" evaluate --version 2.2.5 \
  > "$test_root/evaluate.out" 2> "$test_root/evaluate.err"; then
  :
else
  cat "$test_root/evaluate.err" >&2
  exit 1
fi
grep -Fxq 'tag=v2.2.5' "$test_root/evaluate.out" || {
  printf 'FAIL: no informó el tag evaluado\n' >&2
  exit 1
}
grep -Fxq "sha256=$archive_sha256" "$test_root/evaluate.out" || {
  printf 'FAIL: no informó el digest verificado\n' >&2
  exit 1
}
grep -Fxq 'result=runner-profile-session-list-pass' "$test_root/evaluate.out" || {
  printf 'FAIL: no ejecutó la ruta de sesión con el runner\n' >&2
  exit 1
}
if ! grep -Fxq api "$FAKE_CURL_LOG" || ! grep -Fxq asset "$FAKE_CURL_LOG"; then
  printf 'FAIL: no consultó release y asset por los endpoints esperados\n' >&2
  exit 1
fi
for evaluation_path in "$TMPDIR"/opencode-v2-evaluate.*; do
  [ ! -e "$evaluation_path" ] || {
    printf 'FAIL: dejó el temporal de evaluación\n' >&2
    exit 1
  }
done
printf 'PASS: evalúa release exacto, digest, loader, perfil sintético y session list con el runner\n'

daily_home="$test_root/daily-home"
mkdir -m 700 "$daily_home"
if env -i PATH="$PATH" HOME="$daily_home" PREFIX="$prefix" TMPDIR="$prefix/tmp" TERM=dumb \
  sh "$repo_dir/registry/lib/opencode-v2-runtime.sh" \
    "$prefix/glibc/lib/ld-linux-aarch64.so.1" --library-path "$prefix/glibc/lib" \
    "$test_root/archive/opencode" > "$test_root/daily.out" 2> "$test_root/daily.err"; then
  :
else
  cat "$test_root/daily.err" >&2
  exit 1
fi
grep -Fxq TUI "$test_root/daily.out" || {
  printf 'FAIL: la invocación habitual sin argumentos no llegó a la TUI\n' >&2
  exit 1
}
[ ! -e "$daily_home/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] || {
  printf 'FAIL: la invocación habitual dejó el lock abierto\n' >&2
  exit 1
}
printf 'PASS: la invocación diaria sin argumentos llega a la TUI por el runner\n'

curl_calls_before=$(wc -l < "$FAKE_CURL_LOG" | tr -d ' ')
invalid_status=0
if sh "$repo_dir/scripts/opencode-v2-maintenance.sh" evaluate --version 1.19.5 \
  > "$test_root/invalid.out" 2> "$test_root/invalid.err"; then
  invalid_status=0
else
  invalid_status=$?
fi
[ "$invalid_status" -eq 2 ] || {
  printf 'FAIL: aceptó una versión fuera de major 2\n' >&2
  exit 1
}
curl_calls_after=$(wc -l < "$FAKE_CURL_LOG" | tr -d ' ')
[ "$curl_calls_before" = "$curl_calls_after" ] || {
  printf 'FAIL: consultó la red antes de rechazar una versión inválida\n' >&2
  exit 1
}
printf 'PASS: rechaza major ajena antes de consultar la red\n'

printf 'tampered asset\n' > "$test_root/tampered.tar.gz"
export FAKE_ARCHIVE="$test_root/tampered.tar.gz"
digest_status=0
if sh "$repo_dir/scripts/opencode-v2-maintenance.sh" evaluate --version 2.2.5 \
  > "$test_root/digest.out" 2> "$test_root/digest.err"; then
  digest_status=0
else
  digest_status=$?
fi
[ "$digest_status" -eq 1 ] || {
  printf 'FAIL: aceptó un asset con digest distinto\n' >&2
  exit 1
}
grep -q 'no coincide con el digest' "$test_root/digest.err" || {
  printf 'FAIL: no explicó el rechazo del digest\n' >&2
  exit 1
}
for evaluation_path in "$TMPDIR"/opencode-v2-evaluate.*; do
  [ ! -e "$evaluation_path" ] || {
    printf 'FAIL: dejó el temporal tras fallar el digest\n' >&2
    exit 1
  }
done
printf 'PASS: verifica digest antes de extraer y limpia temporales al fallar\n'
