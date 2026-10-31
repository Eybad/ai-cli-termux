#!/bin/sh
set -eu

repo_dir=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
[ -d "$tmp_base" ] && [ -w "$tmp_base" ] || {
  printf 'No hay un temporal escribible en TMPDIR o PREFIX/tmp.\n' >&2
  exit 1
}
test_root=$(mktemp -d "$tmp_base/opencode-coexistence.XXXXXX")
trap 'rm -rf "$test_root"' 0

mock_bin="$test_root/bin"
mock_pages="$test_root/pages"
test_home="$test_root/home"
test_prefix="$test_root/prefix"
test_tmp="$test_root/tmp"
stdout_file="$test_root/stdout"
stderr_file="$test_root/stderr"
curl_log="$test_root/curl.log"
pkg_log="$test_root/pkg.log"
hook_marker="$test_root/hook-ran"

mkdir -p "$mock_bin" "$mock_pages" "$test_home/.config/opencode/scripts" "$test_tmp"

cat > "$mock_bin/curl" <<'EOF'
#!/bin/sh
set -eu
output_file=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output_file=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
[ -n "$output_file" ] && [ -n "$url" ] || exit 97
printf '%s\n' "$url" >> "$CURL_LOG"
case "$url" in
  *page=1) page=1 ;;
  *page=2) page=2 ;;
  *page=3) page=3 ;;
  *page=4) page=4 ;;
  *page=5) page=5 ;;
  *page=6) page=6 ;;
  *page=7) page=7 ;;
  *page=8) page=8 ;;
  *page=9) page=9 ;;
  *page=10) page=10 ;;
  *) page=1 ;;
esac
page_file="$MOCK_RELEASES_DIR/page$page.json"
if [ -f "$page_file" ]; then
  cat "$page_file" > "$output_file"
else
  printf '[]' > "$output_file"
fi
printf '%s' "${MOCK_HTTP_CODE:-200}"
EOF

cat > "$mock_bin/pkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$PKG_LOG"
exit 98
EOF

cat > "$test_home/.config/opencode/scripts/attach-preflight.py" <<'EOF'
import os
from pathlib import Path

Path(os.environ["HOOK_MARKER"]).write_text("called", encoding="utf-8")
EOF

chmod 700 "$mock_bin/curl" "$mock_bin/pkg"

cat > "$mock_pages/page1.json" <<'EOF'
[
  {"tag_name":"v2.2.5","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v2.2.5/opencode-linux-arm64.tar.gz"}]},
  {"tag_name":"v1.20.0-rc.1","draft":false,"prerelease":true,"assets":[{"name":"opencode-linux-arm64.tar.gz"}]},
  {"tag_name":"v1.18.0","draft":true,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz"}]},
  {"tag_name":"v12.0.0","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz"}]}
]
EOF

cat > "$mock_pages/page2.json" <<'EOF'
[
  {"tag_name":"v1.19.5","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v1.19.5/opencode-linux-arm64.tar.gz"}]}
]
EOF

. "$repo_dir/registry/lib/releases.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

assert_tag() {
  actual_tag=$(printf '%s' "$1" | jq -r '.tag_name // empty')
  [ "$actual_tag" = "$2" ] || fail "esperaba tag $2, recibí ${actual_tag:-vacío}"
}

if ! release_policy_fields_valid '' stable ||
   ! release_policy_fields_valid 0 '' ||
   ! release_policy_fields_valid 12 stable; then
  fail 'rechazó campos de política válidos'
fi
if release_policy_fields_valid 01 stable ||
   release_policy_fields_valid 1x stable ||
   release_policy_fields_valid 1 beta; then
  fail 'aceptó campos de política inválidos'
fi
pass 'valida campos declarativos major y canal'

legacy_page='[{"tag_name":"v2.0.0-rc.1","draft":true,"prerelease":true,"assets":[{"name":"asset"}]}]'
selected=$(printf '%s' "$legacy_page" | release_select_from_page asset '' '')
assert_tag "$selected" v2.0.0-rc.1
legacy_tag_page='[{"tag_name":"nightly","assets":[{"name":"asset"}]}]'
selected=$(printf '%s' "$legacy_tag_page" | release_select_from_page asset '' '')
assert_tag "$selected" nightly
pass 'mantiene el comportamiento previo con campos nuevos vacíos'

selected=$(release_select_from_page opencode-linux-arm64.tar.gz 1 stable < "$mock_pages/page1.json")
[ -z "$selected" ] || fail 'la política major 1/canal stable aceptó un candidato de otra línea'
selected=$(release_select_from_page opencode-linux-arm64.tar.gz 12 stable < "$mock_pages/page1.json")
assert_tag "$selected" v12.0.0
selected=$(release_select_from_page opencode-linux-arm64.tar.gz 2 stable < "$mock_pages/page1.json")
assert_tag "$selected" v2.2.5
pass 'filtra major exacta y excluye prerelease y draft'

build_page=$(jq -cn --arg asset opencode-linux-arm64.tar.gz '{tag_name:"v1.19.5+android3",draft:false,prerelease:false,assets:[{name:$asset}]} | [. ]')
selected=$(printf '%s' "$build_page" | release_select_from_page opencode-linux-arm64.tar.gz 1 stable)
assert_tag "$selected" v1.19.5+android3
pass 'preserva build metadata al resolver'

ambiguous_page='[{"tag_name":"v1.19.5","draft":false,"prerelease":false,"assets":[{"name":"asset"},{"name":"asset"}]}]'
if printf '%s' "$ambiguous_page" | release_select_from_page asset 1 stable >/dev/null 2>&1; then
  fail 'aceptó assets duplicados'
fi
pass 'rechaza assets ambiguos'

stable_object='{"tag_name":"v1.19.5+android3","draft":false,"prerelease":false,"assets":[{"name":"asset","browser_download_url":"https://github.com/org/repo/releases/download/v1.19.5+android3/asset"}]}'
release_validate_object "$stable_object" asset 1 stable v1.19.5+android3 || fail 'rechazó release estable válido'
printf '%s' "$stable_object" | release_asset_url asset 'https://github.com/org/repo/releases/download/v1.19.5+android3/asset' >/dev/null || fail 'rechazó URL del asset exacto'
if release_validate_object "$stable_object" asset 2 stable v1.19.5+android3; then
  fail 'aceptó release de major distinta'
fi
if release_validate_object "$stable_object" asset 1 stable v1.19.5-rc.1; then
  fail 'aceptó tag distinto al esperado'
fi
pass 'valida metadata, asset único y URL del mismo release'

export PATH="$mock_bin:$PATH"
export HOME="$test_home"
export PREFIX="$test_prefix"
export TMPDIR="$test_tmp"
export CURL_LOG="$curl_log"
export PKG_LOG="$pkg_log"
export HOOK_MARKER="$hook_marker"
export MOCK_RELEASES_DIR="$mock_pages"

run_installer() {
  if bash "$repo_dir/install.sh" "$@" > "$stdout_file" 2> "$stderr_file"; then
    command_status=0
  else
    command_status=$?
  fi
}

: > "$curl_log"
run_installer opencode --resolve-version
[ "$command_status" -eq 0 ] || fail 'falló --resolve-version con releases sintéticos'
printf 'TARGET_VERSION=1.19.5\n' > "$test_root/expected-stdout"
cmp -s "$test_root/expected-stdout" "$stdout_file" || fail '--resolve-version contaminó stdout'
[ "$(grep -c 'page=1$' "$curl_log")" -eq 1 ] || fail 'no consultó la primera página'
[ "$(grep -c 'page=2$' "$curl_log")" -eq 1 ] || fail 'no paginó hasta encontrar major 1'
[ ! -e "$hook_marker" ] || fail '--resolve-version ejecutó un hook'
[ ! -e "$pkg_log" ] || fail '--resolve-version llamó pkg'
[ ! -e "$test_prefix" ] || fail '--resolve-version escribió en PREFIX'
pass '--resolve-version pagina, conserva stdout y no muta ni ejecuta hooks'

: > "$curl_log"
run_installer opencode --resolve-version --update
[ "$command_status" -eq 2 ] || fail 'aceptó flags incompatibles con --resolve-version'
[ ! -s "$curl_log" ] || fail 'flags incompatibles consultaron la API'
pass 'rechaza combinaciones incompatibles de --resolve-version'

: > "$curl_log"
for invalid_version in 2.2.5 3.0.0 1.20.0-rc.1; do
  run_installer opencode -v "$invalid_version"
  [ "$command_status" -eq 2 ] || fail "-v $invalid_version no devolvió exit 2"
done
[ ! -s "$curl_log" ] || fail 'una versión incompatible consultó la API'
[ ! -e "$pkg_log" ] || fail 'una versión incompatible llamó pkg'
[ ! -e "$test_prefix" ] || fail 'una versión incompatible escribió en PREFIX'
pass 'rechaza major y prerelease incompatibles antes de red o mutaciones'

mkdir -p "$test_root/empty-pages"
printf '[]' > "$test_root/empty-pages/page1.json"
MOCK_RELEASES_DIR="$test_root/empty-pages" run_installer opencode --resolve-version
[ "$command_status" -eq 1 ] || fail 'no falló al recibir una página vacía sin candidato'
[ "$(wc -l < "$curl_log")" -eq 1 ] || fail 'consultó páginas después de una respuesta vacía'
pass 'falla sin candidato y detiene la paginación en página vacía'

mkdir -p "$test_root/cap-pages"
for page in 1 2 3 4 5 6 7 8 9 10; do
  cp "$mock_pages/page1.json" "$test_root/cap-pages/page$page.json"
done
: > "$curl_log"
MOCK_RELEASES_DIR="$test_root/cap-pages" run_installer opencode --resolve-version
[ "$command_status" -eq 1 ] || fail 'no falló al agotar diez páginas sin major 1'
[ "$(wc -l < "$curl_log")" -eq 10 ] || fail 'no aplicó el límite de diez páginas'
pass 'falla explícitamente al agotar diez páginas'

mkdir -p "$test_root/malformed-pages"
printf '{"not":"an array"}' > "$test_root/malformed-pages/page1.json"
: > "$curl_log"
MOCK_RELEASES_DIR="$test_root/malformed-pages" run_installer opencode --resolve-version
[ "$command_status" -eq 1 ] || fail 'no falló ante JSON de releases malformado'
[ "$(wc -l < "$curl_log")" -eq 1 ] || fail 'siguió paginando tras JSON malformado'
pass 'falla cerrada ante JSON de releases malformado'

mkdir -p "$test_prefix/libexec/opencode"
cat > "$test_prefix/libexec/opencode/manifest.txt" <<'EOF'
app=opencode
tag=v1.19.0
installed_at=synthetic
EOF
: > "$curl_log"
if MOCK_HTTP_CODE=429 MOCK_RELEASES_DIR="$mock_pages" bash "$repo_dir/aicli" list --json opencode > "$stdout_file" 2> "$stderr_file"; then
  :
else
  fail 'aicli list falló ante un rate limit'
fi
jq -e '.tools[0].latest_version == null and .tools[0].update_available == null' "$stdout_file" >/dev/null || fail 'aicli list no mostró n/d tras un rate limit'
[ ! -e "$pkg_log" ] || fail 'aicli list llamó pkg'
pass 'aicli list conserva exit 0 y n/d ante un fallo de red'
