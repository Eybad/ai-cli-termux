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
  */releases/tags/*)
    tag=${url##*/}
    tag_file="$MOCK_TAG_RELEASES_DIR/$tag.json"
    if [ -f "$tag_file" ]; then
      cat "$tag_file" > "$output_file"
      printf '200'
    else
      printf '{}' > "$output_file"
      printf '404'
    fi
    exit 0
    ;;
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

stable_object='{"tag_name":"v1.19.5+android3","draft":false,"prerelease":false,"assets":[{"name":"asset","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","browser_download_url":"https://github.com/org/repo/releases/download/v1.19.5+android3/asset"}]}'
release_validate_object "$stable_object" asset 1 stable v1.19.5+android3 || fail 'rechazó release estable válido'
printf '%s' "$stable_object" | release_asset_url asset 'https://github.com/org/repo/releases/download/v1.19.5+android3/asset' >/dev/null || fail 'rechazó URL del asset exacto'
printf '%s' "$stable_object" | release_asset_digest asset >/dev/null || fail 'rechazó digest del asset exacto'
if release_validate_object "$stable_object" asset 2 stable v1.19.5+android3; then
  fail 'aceptó release de major distinta'
fi
if release_validate_object "$stable_object" asset 1 stable v1.19.5-rc.1; then
  fail 'aceptó tag distinto al esperado'
fi
pass 'valida metadata, asset único y URL del mismo release'

release_catalog_validate "$repo_dir/registry/releases/opencode-v2.json" opencode-v2 2 "$repo_dir" ||
  fail 'rechazó el catálogo v2 vacío y válido'
if release_catalog_preferred_tag "$repo_dir/registry/releases/opencode-v2.json" arm64 >/dev/null 2>&1; then
  fail 'el catálogo v2 vacío devolvió una versión preferida'
fi
pass 'valida el esquema vacío sin aprobar releases antes de tiempo'

catalog_root="$test_root/catalog-root"
catalog_file="$catalog_root/catalog.json"
mkdir -p "$catalog_root/docs/compatibility/opencode-v2"
: > "$catalog_root/docs/compatibility/opencode-v2/v1.19.4-arm64.md"
: > "$catalog_root/docs/compatibility/opencode-v2/v1.19.5-arm64.md"
cat > "$catalog_file" <<'EOF'
{
  "schema": 1,
  "app": "opencode",
  "preferred": {"arm64": "v1.19.5+termux1"},
  "releases": [
    {
      "sequence": 1,
      "tag": "v1.19.4+termux1",
      "source_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "contract": "termux-glibc-1",
      "assets": {
        "arm64": {
          "name": "opencode-linux-arm64.tar.gz",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "evidence": "docs/compatibility/opencode-v2/v1.19.4-arm64.md"
        }
      }
    },
    {
      "sequence": 2,
      "tag": "v1.19.5+termux1",
      "source_commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "contract": "termux-glibc-1",
      "assets": {
        "arm64": {
          "name": "opencode-linux-arm64.tar.gz",
          "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "evidence": "docs/compatibility/opencode-v2/v1.19.5-arm64.md"
        }
      }
    }
  ]
}
EOF
release_catalog_validate "$catalog_file" opencode 1 "$catalog_root" || fail 'rechazó catálogo sintético válido'
[ "$(release_catalog_preferred_tag "$catalog_file" arm64)" = v1.19.5+termux1 ] || fail 'resolvió mal el tag preferido'
catalog_entry=$(release_catalog_entry_by_version "$catalog_file" 1.19.5+termux1)
[ "$(printf '%s' "$catalog_entry" | jq -r '.sequence')" = 2 ] || fail 'perdió la secuencia del tag'
catalog_asset=$(release_catalog_asset "$catalog_file" v1.19.5+termux1 arm64)
[ "$(printf '%s' "$catalog_asset" | jq -r '.sha256')" = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ] || fail 'resolvió mal el digest catalogado'
if release_catalog_validate "$catalog_file" opencode 2 "$catalog_root"; then
  fail 'aceptó una major distinta a la configuración'
fi
jq '.releases[0].contract = "unknown-contract"' "$catalog_file" > "$test_root/catalog-unknown-contract.json"
if release_catalog_validate "$test_root/catalog-unknown-contract.json" opencode 1 "$catalog_root"; then
  fail 'aceptó un contrato no soportado por el registro'
fi
jq '.releases[1].sequence = 1' "$catalog_file" > "$test_root/catalog-bad-sequence.json"
if release_catalog_validate "$test_root/catalog-bad-sequence.json" opencode 1 "$catalog_root"; then
  fail 'aceptó una secuencia duplicada'
fi
jq '.preferred.arm64 = "v1.19.4+termux1"' "$catalog_file" > "$test_root/catalog-old-preferred.json"
if release_catalog_validate "$test_root/catalog-old-preferred.json" opencode 1 "$catalog_root"; then
  fail 'aceptó un preferred anterior a la última secuencia'
fi
pass 'valida major, contrato, evidencia, secuencia, assets y preferred'

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

catalog_repo="$test_root/catalog-repo"
catalog_prefix="$test_root/catalog-prefix"
catalog_tmp="$test_root/catalog-tmp"
catalog_tags="$test_root/catalog-tags"
mkdir -p "$catalog_repo/registry/lib" "$catalog_repo/registry/releases" \
  "$catalog_repo/docs/compatibility/opencode-v2" "$catalog_tmp" "$catalog_tags"
cp "$repo_dir/install.sh" "$catalog_repo/install.sh"
cp "$repo_dir/registry/lib/releases.sh" "$catalog_repo/registry/lib/releases.sh"
cp "$repo_dir/registry/opencode.conf" "$catalog_repo/registry/opencode.conf"
cp "$repo_dir/docs/compatibility/opencode-v2/v2.2.5-arm64.md" \
  "$catalog_repo/docs/compatibility/opencode-v2/v1.19.5-arm64.md"
: > "$catalog_repo/sha256.txt"
cat >> "$catalog_repo/registry/opencode.conf" <<'EOF'
RELEASE_POLICY_FILE="registry/releases/test.json"
EOF
cat > "$catalog_repo/registry/releases/test.json" <<'EOF'
{
  "schema": 1,
  "app": "opencode",
  "preferred": {"arm64": "v1.19.5+termux1"},
  "releases": [
    {
      "sequence": 1,
      "tag": "v1.19.4+termux1",
      "source_commit": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "contract": "termux-glibc-1",
      "assets": {
        "arm64": {
          "name": "opencode-linux-arm64.tar.gz",
          "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "evidence": "docs/compatibility/opencode-v2/v1.19.5-arm64.md"
        }
      }
    },
    {
      "sequence": 2,
      "tag": "v1.19.5+termux1",
      "source_commit": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "contract": "termux-glibc-1",
      "assets": {
        "arm64": {
          "name": "opencode-linux-arm64.tar.gz",
          "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "evidence": "docs/compatibility/opencode-v2/v1.19.5-arm64.md"
        }
      }
    }
  ]
}
EOF
cat > "$catalog_tags/v1.19.5+termux1.json" <<'EOF'
{"tag_name":"v1.19.5+termux1","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v1.19.5+termux1/opencode-linux-arm64.tar.gz"}]}
EOF
cat > "$catalog_tags/v1.19.4+termux1.json" <<'EOF'
{"tag_name":"v1.19.4+termux1","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","digest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v1.19.4+termux1/opencode-linux-arm64.tar.gz"}]}
EOF
export MOCK_TAG_RELEASES_DIR="$catalog_tags"

run_catalog_installer() {
  if PREFIX="$catalog_prefix" TMPDIR="$catalog_tmp" \
    bash "$catalog_repo/install.sh" "$@" > "$stdout_file" 2> "$stderr_file"; then
    command_status=0
  else
    command_status=$?
  fi
}

: > "$curl_log"
: > "$pkg_log"
run_catalog_installer opencode --resolve-version
[ "$command_status" -eq 0 ] || fail 'falló resolve-version con catálogo sintético'
printf 'TARGET_VERSION=1.19.5+termux1\n' > "$test_root/expected-catalog-stdout"
cmp -s "$test_root/expected-catalog-stdout" "$stdout_file" || fail 'el catálogo contaminó stdout o perdió +build'
grep -Fq '/releases/tags/v1.19.5+termux1' "$curl_log" || fail 'no consultó el tag preferido exacto'
[ ! -s "$pkg_log" ] || fail 'resolve-version con catálogo llamó pkg'
[ ! -e "$catalog_prefix" ] || fail 'resolve-version con catálogo escribió en PREFIX'
pass 'resuelve solo el tag preferido catalogado y preserva +build'

cp "$catalog_repo/registry/releases/test.json" "$test_root/catalog-valid-backup.json"
printf '{invalid json\n' > "$catalog_repo/registry/releases/test.json"
: > "$curl_log"
run_catalog_installer opencode --resolve-version
[ "$command_status" -eq 1 ] || fail 'aceptó un catálogo JSON malformado'
[ ! -s "$curl_log" ] || fail 'un catálogo malformado consultó la API'
mv "$test_root/catalog-valid-backup.json" "$catalog_repo/registry/releases/test.json"
pass 'falla antes de red ante un catálogo malformado'

: > "$curl_log"
: > "$pkg_log"
run_catalog_installer opencode -v 1.19.6
[ "$command_status" -eq 1 ] || fail 'aceptó una versión ausente del catálogo'
[ ! -s "$curl_log" ] || fail 'una versión ausente del catálogo consultó la API'
[ ! -s "$pkg_log" ] || fail 'una versión ausente del catálogo llamó pkg'
pass 'rechaza versiones fuera del catálogo antes de red y paquetes'

jq '.assets[0].digest = "sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"' \
  "$catalog_tags/v1.19.5+termux1.json" > "$test_root/catalog-bad-digest.json"
mv "$test_root/catalog-bad-digest.json" "$catalog_tags/v1.19.5+termux1.json"
: > "$curl_log"
run_catalog_installer opencode --resolve-version
[ "$command_status" -eq 1 ] || fail 'aceptó un digest API distinto al catálogo'
[ ! -s "$pkg_log" ] || fail 'un digest API distinto llamó pkg'
pass 'falla cerrada cuando el digest API difiere del catálogo'

cat > "$catalog_tags/v1.19.5+termux1.json" <<'EOF'
{"tag_name":"v1.19.5+termux1","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","digest":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v1.19.5+termux1/opencode-linux-arm64.tar.gz"}]}
EOF
: > "$curl_log"
run_catalog_installer opencode --sha256 cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
[ "$command_status" -eq 1 ] || fail 'permitió --sha256 distinto al catálogo'
[ ! -s "$pkg_log" ] || fail 'un --sha256 discordante llamó pkg'
pass 'un pin CLI no puede reemplazar el digest aprobado'

printf 'opencode/v1.19.5+termux1 cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\n' \
  > "$catalog_repo/sha256.txt"
run_catalog_installer opencode
[ "$command_status" -eq 1 ] || fail 'permitió un pin sha256.txt distinto al catálogo'
grep -q 'pin de sha256.txt no coincide' "$stderr_file" || fail 'no explicó el pin de hash discordante'
pass 'un pin sha256.txt no puede reemplazar el digest aprobado'

: > "$catalog_repo/sha256.txt"
printf 'opencode/v1.19.5+termux1 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' \
  > "$catalog_repo/sha256.txt"
: > "$pkg_log"
run_catalog_installer opencode -v 1.19.5+termux1
[ "$command_status" -eq 1 ] || fail 'falló antes de instalar un tag catalogado con -v'
grep -q '^install ' "$pkg_log" || fail '-v catalogado no alcanzó la fase de dependencias'
pass 'acepta -v exacto del catálogo y conserva la pin de hash coincidente'

mkdir -p "$catalog_prefix/bin"
printf 'foreign-wrapper\n' > "$catalog_prefix/bin/opencode"
: > "$curl_log"
: > "$pkg_log"
run_catalog_installer opencode -r
[ "$command_status" -eq 1 ] || fail '-r sobrescribió un wrapper sin manifest'
grep -q 'sin un manifest de catálogo' "$stderr_file" || fail 'no explicó la colisión sin manifest'
[ "$(cat "$catalog_prefix/bin/opencode")" = foreign-wrapper ] || fail 'alteró un wrapper sin manifest'
[ ! -s "$pkg_log" ] || fail 'una colisión de wrapper llamó pkg'
rm -f "$catalog_prefix/bin/opencode"
pass 'reinstall conserva wrappers ajenos sin manifest de catálogo'

mkdir -p "$catalog_prefix/libexec/opencode"
cat > "$catalog_prefix/libexec/opencode/manifest.txt" <<'EOF'
app=opencode
tag=v1.19.5+termux1
release_sequence=2
release_contract=termux-glibc-1
release_source_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
tarball_checksum=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
EOF
: > "$curl_log"
: > "$pkg_log"
run_catalog_installer opencode -v 1.19.4+termux1
[ "$command_status" -eq 1 ] || fail 'permitió un downgrade a una secuencia anterior'
grep -q 'anterior a la instalada' "$stderr_file" || fail 'no explicó el downgrade bloqueado'
[ ! -s "$pkg_log" ] || fail 'un downgrade bloqueado llamó pkg'
pass 'rechaza secuencias anteriores antes de instalar'

: > "$curl_log"
: > "$pkg_log"
run_installer opencode --resolve-version
[ "$command_status" -eq 0 ] || fail 'falló --resolve-version con releases sintéticos'
printf 'TARGET_VERSION=1.19.5\n' > "$test_root/expected-stdout"
cmp -s "$test_root/expected-stdout" "$stdout_file" || fail '--resolve-version contaminó stdout'
[ "$(grep -c 'page=1$' "$curl_log")" -eq 1 ] || fail 'no consultó la primera página'
[ "$(grep -c 'page=2$' "$curl_log")" -eq 1 ] || fail 'no paginó hasta encontrar major 1'
[ ! -e "$hook_marker" ] || fail '--resolve-version ejecutó un hook'
[ ! -s "$pkg_log" ] || fail '--resolve-version llamó pkg'
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
[ ! -s "$pkg_log" ] || fail 'una versión incompatible llamó pkg'
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
[ ! -s "$pkg_log" ] || fail 'aicli list llamó pkg'
pass 'aicli list conserva exit 0 y n/d ante un fallo de red'
