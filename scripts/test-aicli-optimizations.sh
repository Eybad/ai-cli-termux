#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

repo_dir=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
if [[ ! -d "$tmp_base" || ! -w "$tmp_base" ]]; then
  tmp_base=/tmp
fi
[[ -d "$tmp_base" && -w "$tmp_base" ]] || {
  printf 'No writable temp directory in TMPDIR, PREFIX/tmp, or /tmp.\n' >&2
  exit 1
}

test_root=$(mktemp -d "$tmp_base/aicli-opt-test.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

# 1. aicli list cache hit/miss, --refresh, APP_NAME manifest lookup, TTL validation, json_escape
mock_repo="$test_root/mock-repo"
mock_prefix="$test_root/prefix"
mock_tmp="$test_root/tmp"
mkdir -p "$mock_repo/registry/lib" "$mock_prefix/libexec/customapp" "$mock_prefix/bin" "$mock_tmp"

cp "$repo_dir/aicli" "$mock_repo/aicli"
cp "$repo_dir/verify.sh" "$mock_repo/verify.sh"
cp "$repo_dir/registry/lib/releases.sh" "$mock_repo/registry/lib/releases.sh"
touch "$mock_repo/sha256.txt"

cat > "$mock_repo/registry/customtool.conf" <<'EOF'
APP_NAME="customapp"
DISPLAY_NAME="Custom App"
DESCRIPTION="Custom tool for regression checks" # trailing comment
RELEASE_SOURCE="github"
REPO="example/custom"
ARCHIVE_TEMPLATE="custom-{ARCH}.tar.gz"
CHECKSUM_ALGO="sha256"
CHECKSUM_SOURCE="release_digest"
ELF_NAME="customapp"
EOF

cat > "$mock_prefix/libexec/customapp/manifest.txt" <<'EOF'
manifest_version=2
app=customapp
tag=v1.2.3+android1
installed_at=2026-11-01T00:00:00Z
EOF

resolve_count_file="$test_root/resolve-count"
printf '0\n' > "$resolve_count_file"

cat > "$mock_repo/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cnt=\$(cat "$resolve_count_file")
cnt=\$((cnt + 1))
printf '%s\n' "\$cnt" > "$resolve_count_file"
if [[ "\$cnt" -eq 1 ]]; then
  printf 'TARGET_VERSION=1.2.3+android1\n'
else
  printf 'TARGET_VERSION=1.2.4+android1\n'
fi
EOF
chmod 755 "$mock_repo/install.sh"

out1=$(PREFIX="$mock_prefix" TMPDIR="$mock_tmp" AI_CLI_TERMUX_DIR="$mock_repo" \
  bash "$mock_repo/aicli" --no-color list --json 2>/dev/null)
[[ "$(cat "$resolve_count_file")" == "1" ]] || fail "cold list should invoke --resolve-version once"
printf '%s' "$out1" | jq -e '.tools[] | select(.name == "customtool") | .installed == true and .version == "1.2.3+android1" and .latest_version == "1.2.3+android1" and .update_available == false' >/dev/null \
  || fail "cold list JSON mismatch for APP_NAME!=tool: $out1"
[[ -f "$mock_tmp/aicli_resolve/customtool.latest" ]] || fail "cache file was not created"

out2=$(PREFIX="$mock_prefix" TMPDIR="$mock_tmp" AI_CLI_TERMUX_DIR="$mock_repo" \
  bash "$mock_repo/aicli" --no-color list --json 2>/dev/null)
[[ "$(cat "$resolve_count_file")" == "1" ]] || fail "warm list should hit cache without calling --resolve-version"
printf '%s' "$out2" | jq -e '.tools[] | select(.name == "customtool") | .latest_version == "1.2.3+android1"' >/dev/null \
  || fail "warm list JSON mismatch"

out3=$(PREFIX="$mock_prefix" TMPDIR="$mock_tmp" AI_CLI_TERMUX_DIR="$mock_repo" \
  bash "$mock_repo/aicli" --no-color list --refresh --json 2>/dev/null)
[[ "$(cat "$resolve_count_file")" == "2" ]] || fail "--refresh should bypass cache and invoke --resolve-version"
printf '%s' "$out3" | jq -e '.tools[] | select(.name == "customtool") | .latest_version == "1.2.4+android1" and .update_available == true' >/dev/null \
  || fail "--refresh JSON mismatch: $out3"

out4=$(PREFIX="$mock_prefix" TMPDIR="$mock_tmp" AICLI_CACHE_TTL="not-a-number" AI_CLI_TERMUX_DIR="$mock_repo" \
  bash "$mock_repo/aicli" --no-color list --json 2>/dev/null)
[[ "$(cat "$resolve_count_file")" == "2" ]] || fail "invalid AICLI_CACHE_TTL should fall back to 900 and use cache"
printf '%s' "$out4" | jq -e '.tools[] | select(.name == "customtool") | .latest_version == "1.2.4+android1"' >/dev/null \
  || fail "invalid AICLI_CACHE_TTL fallback JSON mismatch"

printf '1\n0.0.1\n' > "$mock_tmp/aicli_resolve/stale.latest"
PREFIX="$mock_prefix" TMPDIR="$mock_tmp" AI_CLI_TERMUX_DIR="$mock_repo" \
  bash "$mock_repo/aicli" --no-color list --json >/dev/null 2>&1
[[ ! -e "$mock_tmp/aicli_resolve/stale.latest" ]] || fail "_cleanup_resolve_cache did not remove expired cache file"

bash -c '
  set -euo pipefail
  source <(sed "\$d" "$1")
  RESOLVE_CACHE_TTL=900
  val_ascii=$(json_escape "plain \"quoted\" \\path")
  [[ "$val_ascii" == "plain \\\"quoted\\\" \\\\path" ]]
  printf "\"%s\"" "$val_ascii" | jq -e . >/dev/null

  val_utf8=$(json_escape "café — OK")
  printf "\"%s\"" "$val_utf8" | jq -e . >/dev/null

  ctrl_in=$(printf "a\x01b\x7fc\xffd")
  val_ctrl=$(json_escape "$ctrl_in")
  [[ "$val_ctrl" == "a\\u0001b\\u007fc\\u00ffd" ]]
  printf "\"%s\"" "$val_ctrl" | jq -e . >/dev/null

  [[ "$(conf_get "$2/registry/customtool.conf" APP_NAME)" == "customapp" ]]
  [[ "$(manifest_get tag "$3/libexec/customapp/manifest.txt")" == "v1.2.3+android1" ]]
' _ "$repo_dir/aicli" "$mock_repo" "$mock_prefix" || fail "aicli helper checks failed"

bash "$repo_dir/aicli" help list | grep -Fq -- '--refresh' || fail "aicli help list missing --refresh"
bash "$repo_dir/aicli" completion bash | grep -Fq -- '--refresh' || fail "bash completion missing --refresh"
bash "$repo_dir/aicli" completion zsh  | grep -Fq -- '--refresh' || fail "zsh completion missing --refresh"
bash "$repo_dir/aicli" completion fish | grep -Fq -- '--refresh' || fail "fish completion missing --refresh"

pass "aicli list cache, --refresh, APP_NAME lookup, TTL fallback, and json_escape"

# 2. Shared shims.sh registration & refcounted removal
shim_prefix="$test_root/shim-prefix"
mkdir -p "$shim_prefix/bin" "$shim_prefix/libexec/codex" "$shim_prefix/libexec/opencode" "$shim_prefix/libexec/.codex.backup.999"

cat > "$shim_prefix/bin/xdg-open" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec termux-open-url "$@"
EOF
chmod 755 "$shim_prefix/bin/xdg-open"

cat > "$shim_prefix/bin/open" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
exec termux-open-url "$@"
# termux-shim: legacytool
EOF
chmod 755 "$shim_prefix/bin/open"

cat > "$shim_prefix/bin/xclip" <<'EOF'
#!/bin/sh
echo foreign
EOF
chmod 755 "$shim_prefix/bin/xclip"

printf 'pbcopy\n' > "$shim_prefix/libexec/.codex.backup.999/shims.txt"
printf 'manifest_version=2\n' > "$shim_prefix/libexec/.codex.backup.999/manifest.txt"

PREFIX="$shim_prefix" bash -euo pipefail -c '
  repo_dir="$1"
  shim_prefix="$2"
  test_root="$3"
  fail() { printf "FAIL: %s\n" "$1" >&2; exit 1; }

  set -- codex
  source "$repo_dir/install.sh"
  trap - EXIT
  source "$repo_dir/registry/lib/shims.sh"

  LIBEXEC_DIR="$shim_prefix/libexec/codex"
  APP_NAME="codex"
  tool_shims_reset
  tool_browser_shims
  tool_clipboard_shims
  printf "manifest_version=2\napp=codex\n" > "$LIBEXEC_DIR/manifest.txt"

  grep -qF "termux-shim: ai-cli-termux" "$shim_prefix/bin/xdg-open" || fail "legacy 2-line shim was not migrated"
  grep -qF "termux-shim: ai-cli-termux" "$shim_prefix/bin/open" || fail "legacy per-tool shim was not migrated"
  grep -qF "echo foreign" "$shim_prefix/bin/xclip" || fail "foreign xclip was overwritten"
  grep -qxF "xdg-open" "$LIBEXEC_DIR/shims.txt" || fail "codex shims.txt missing xdg-open"
  ! grep -qxF "xclip" "$LIBEXEC_DIR/shims.txt" || fail "codex shims.txt should not claim foreign xclip"

  LIBEXEC_DIR="$shim_prefix/libexec/opencode"
  APP_NAME="opencode"
  tool_shims_reset
  tool_browser_shims
  tool_clipboard_shims
  printf "manifest_version=2\napp=opencode\n" > "$LIBEXEC_DIR/manifest.txt"

  [[ -s "$LIBEXEC_DIR/shims.txt" ]] || fail "second tool shims.txt should not be empty"
  grep -qxF "xdg-open" "$LIBEXEC_DIR/shims.txt" || fail "opencode shims.txt missing xdg-open"
  grep -qxF "pbcopy" "$LIBEXEC_DIR/shims.txt" || fail "opencode shims.txt missing pbcopy"

  LIBEXEC_DIR="$shim_prefix/libexec/codex"
  APP_NAME="codex"
  _remove_registered_shims
  [[ -f "$shim_prefix/bin/xdg-open" ]] || fail "removing codex deleted shared xdg-open"
  [[ -f "$shim_prefix/bin/pbcopy" ]] || fail "removing codex deleted shared pbcopy"

  cat > "$shim_prefix/bin/unique-shim" <<'"'"'EOS'"'"'
#!/data/data/com.termux/files/usr/bin/bash
# termux-shim: ai-cli-termux
EOS
  printf "xdg-open\nunique-shim\n" > "$LIBEXEC_DIR/shims.txt"
  printf "pbcopy\n" > "$test_root/prev-shims.txt"
  _remove_orphan_shims "$test_root/prev-shims.txt"
  [[ ! -e "$shim_prefix/bin/unique-shim" ]] || fail "orphan unique-shim was not removed"
  [[ -f "$shim_prefix/bin/xdg-open" ]] || fail "orphan cleanup deleted shared xdg-open"

  rm -rf "$shim_prefix/libexec/codex"

  cat > "$shim_prefix/bin/wslview" <<'"'"'EOS'"'"'
#!/data/data/com.termux/files/usr/bin/bash
exec termux-open-url "$@"
# termux-shim: opencode
EOS
  LIBEXEC_DIR="$shim_prefix/libexec/opencode"
  APP_NAME="opencode"
  _remove_registered_shims
  [[ ! -e "$shim_prefix/bin/xdg-open" ]] || fail "last tool removal kept xdg-open"
  [[ ! -e "$shim_prefix/bin/pbcopy" ]] || fail "last tool removal kept pbcopy (backup dir should be ignored)"
  [[ ! -e "$shim_prefix/bin/wslview" ]] || fail "last tool removal kept legacy opencode-marked wslview"
  [[ -f "$shim_prefix/bin/xclip" ]] || fail "foreign xclip was deleted"
' _ "$repo_dir" "$shim_prefix" "$test_root" || fail "shared shims test failed"

pass "shared shims registration, migration, and refcounted removal"

# 3. install_deps skips glibc when EXEC_DIRECT=true and skips pkg when tools exist
deps_bin="$test_root/deps-bin"
deps_prefix="$test_root/deps-prefix"
pkg_log="$test_root/pkg.log"
mkdir -p "$deps_bin" "$deps_prefix/glibc/lib"

ln -s "$BASH" "$deps_bin/bash"
for sys_cmd in date dirname basename mkdir grep sed rm chmod; do
  ln -s "$(command -v "$sys_cmd")" "$deps_bin/$sys_cmd"
done
for tool_cmd in file jq curl; do
  printf '#!/bin/sh\nexit 0\n' > "$deps_bin/$tool_cmd"
  chmod 755 "$deps_bin/$tool_cmd"
done
cat > "$deps_bin/pkg" <<EOF
#!/bin/sh
echo "\$*" >> "$pkg_log"
case "\$*" in
  *glibc-runner*)
    mkdir -p "$deps_prefix/glibc/lib"
    : > "$deps_prefix/glibc/lib/ld-linux-aarch64.so.1"
    : > "$deps_prefix/glibc/lib/ld-linux-x86-64.so.2"
    ;;
esac
exit 0
EOF
chmod 755 "$deps_bin/pkg"

PREFIX="$deps_prefix" PATH="$deps_bin" bash -euo pipefail -c '
  repo_dir="$1"
  deps_bin="$2"
  deps_prefix="$3"
  pkg_log="$4"
  fail() { printf "FAIL: %s\n" "$1" >&2; exit 1; }

  set -- codex
  source "$repo_dir/install.sh"
  trap - EXIT
  EXEC_DIRECT=true
  NEEDS_PATCHELF=false
  LOADER="$deps_prefix/glibc/lib/ld-linux-aarch64.so.1"
  install_deps >/dev/null
  [[ ! -s "$pkg_log" ]] || fail "pkg should not be invoked when EXEC_DIRECT=true and file/jq/curl exist"

  rm -f "$deps_bin/jq"
  install_deps >/dev/null
  grep -Fq "install jq -y" "$pkg_log" || fail "pkg install jq was not called"
  ! grep -Fq "glibc-" "$pkg_log" || fail "EXEC_DIRECT=true must not install glibc packages"

  printf "#!/bin/sh\nexit 0\n" > "$deps_bin/jq"
  chmod 755 "$deps_bin/jq"
  : > "$pkg_log"
  EXEC_DIRECT=false
  install_deps >/dev/null
  grep -Fq "install glibc-repo glibc-runner -y" "$pkg_log" || fail "EXEC_DIRECT=false with missing loader must install glibc"

  : > "$pkg_log"
  install_deps >/dev/null
  [[ ! -s "$pkg_log" ]] || fail "pkg should not be invoked when EXEC_DIRECT=false and loader+tools exist"
' _ "$repo_dir" "$deps_bin" "$deps_prefix" "$pkg_log" || fail "install_deps test failed"

pass "install_deps skips glibc for EXEC_DIRECT=true and skips pkg when satisfied"

# 4. extract_install moves files (including dotfiles) cleanly on same filesystem
ext_prefix="$test_root/ext-prefix"
ext_tmp="$test_root/ext-tmp"
ext_src="$test_root/ext-src"
mkdir -p "$ext_prefix/libexec" "$ext_tmp" "$ext_src/bundle"

cp "$BASH" "$ext_src/bundle/codex"
printf 'companion\n' > "$ext_src/bundle/companion.dat"
printf 'hidden\n' > "$ext_src/bundle/.hidden-meta"
tar -C "$ext_src" -czf "$ext_tmp/bundle.tar.gz" bundle

PREFIX="$ext_prefix" TMPDIR="$ext_tmp" bash -euo pipefail -c '
  repo_dir="$1"
  ext_prefix="$2"
  ext_tmp="$3"
  fail() { printf "FAIL: %s\n" "$1" >&2; exit 1; }

  set -- codex
  source "$repo_dir/install.sh"
  trap - EXIT
  case "$(uname -m)" in
    aarch64) ARCH="arm64"; EXPECTED_ELF_ARCH="ARM aarch64" ;;
    x86_64)  ARCH="amd64"; EXPECTED_ELF_ARCH="x86-64" ;;
    *) fail "unsupported arch" ;;
  esac
  TMP_FILE="$ext_tmp/bundle.tar.gz"
  LIBEXEC_DIR="$ext_prefix/libexec/codex"
  BIN_FILE="$LIBEXEC_DIR/codex"
  extract_install >/dev/null
  [[ -x "$BIN_FILE" ]] || fail "extracted binary missing"
  [[ -f "$LIBEXEC_DIR/companion.dat" ]] || fail "companion file missing after mv"
  [[ -f "$LIBEXEC_DIR/.hidden-meta" ]] || fail "dotfile missing after mv"
  [[ -z "$EXTRACT_DIR" ]] || fail "EXTRACT_DIR was not cleared"
' _ "$repo_dir" "$ext_prefix" "$ext_tmp" || fail "extract_install test failed"

pass "extract_install moves files and dotfiles cleanly"

# 5. ensure_glibc_resolv
res_prefix="$test_root/res-prefix"
res_bin="$test_root/res-bin"
mkdir -p "$res_prefix/glibc/etc" "$res_bin"
cat > "$res_bin/getprop" <<'EOF'
#!/bin/sh
case "$1" in
  net.dns1) printf '10.1.2.3\n' ;;
  net.dns2) printf '10.1.2.4\n' ;;
esac
EOF
chmod 755 "$res_bin/getprop"

PREFIX="$res_prefix" PATH="$res_bin:$PATH" bash -euo pipefail -c '
  repo_dir="$1"
  res_prefix="$2"
  res_bin="$3"
  fail() { printf "FAIL: %s\n" "$1" >&2; exit 1; }

  set -- opencode
  source "$repo_dir/install.sh"
  trap - EXIT
  EXEC_DIRECT=true
  ensure_glibc_resolv >/dev/null
  [[ ! -e "$res_prefix/glibc/etc/resolv.conf" ]] || fail "EXEC_DIRECT=true should not create resolv.conf"

  EXEC_DIRECT=false
  ensure_glibc_resolv >/dev/null
  grep -qxF "nameserver 10.1.2.3" "$res_prefix/glibc/etc/resolv.conf" || fail "missing dns1"
  grep -qxF "nameserver 10.1.2.4" "$res_prefix/glibc/etc/resolv.conf" || fail "missing dns2"

  rm -f "$res_prefix/glibc/etc/resolv.conf"
  printf "#!/bin/sh\nexit 0\n" > "$res_bin/getprop"
  chmod 755 "$res_bin/getprop"
  ensure_glibc_resolv >/dev/null
  grep -qxF "nameserver 8.8.8.8" "$res_prefix/glibc/etc/resolv.conf" || fail "missing 8.8.8.8 fallback"
  grep -qxF "nameserver 1.1.1.1" "$res_prefix/glibc/etc/resolv.conf" || fail "missing 1.1.1.1 fallback"
' _ "$repo_dir" "$res_prefix" "$res_bin" || fail "ensure_glibc_resolv test failed"

pass "ensure_glibc_resolv populates Android DNS with fallback"

# 6. opencode-runner.sh direct exec for mcp add vs server mode for mcp list/auth/logout
mcp_tmp="$test_root/mcp-tmp"
mkdir -p "$mcp_tmp"
mcp_log="$test_root/mcp-invoke.log"
mcp_mock="$test_root/mock-opencode-mcp"
cat > "$mcp_mock" <<EOF
#!/bin/sh
if [ "\$1" = "serve" ]; then
  printf 'SERVER_MODE\n' > "$mcp_log"
  exit 1
fi
if ls -d "\$TMPDIR"/opencode-runner.* >/dev/null 2>&1; then
  echo "TMPDIR_CREATED" > "$mcp_log"
else
  echo "DIRECT_EXEC" > "$mcp_log"
fi
printf '%s\n' "\$@" >> "$mcp_log"
EOF
chmod 755 "$mcp_mock"

TMPDIR="$mcp_tmp" sh "$repo_dir/registry/lib/opencode-runner.sh" "$mcp_mock" mcp add myserver --stdio
grep -Fxq 'DIRECT_EXEC' "$mcp_log" || fail "opencode mcp add did not execute directly"
! grep -Fxq -- '--server' "$mcp_log" || fail "opencode mcp add received --server"

for sub in list auth logout; do
  : > "$mcp_log"
  if TMPDIR="$mcp_tmp" sh "$repo_dir/registry/lib/opencode-runner.sh" "$mcp_mock" mcp "$sub" >/dev/null 2>&1; then
    fail "opencode mcp $sub should have entered server mode"
  fi
  grep -Fxq 'SERVER_MODE' "$mcp_log" || fail "opencode mcp $sub did not route via server mode"
done

pass "opencode-runner.sh runs mcp add directly and routes mcp list/auth/logout via server"

# 7. codex.conf post_install_hook runs hostbin mprotect/madvise checks even when ctype passes
codex_dir="$test_root/codex-hook"
mkdir -p "$codex_dir"
bash -euo pipefail -c '
  repo_dir="$1"
  codex_dir="$2"
  fail() { printf "FAIL: %s\n" "$1" >&2; exit 1; }

  source "$repo_dir/registry/codex.conf"
  ARCH="arm64"
  LIBEXEC_DIR="$codex_dir"
  printf "version=0.167.2+android1\n" > "$codex_dir/manifest.txt"
  ctype_bytes=$(printf "\x08\xd8\x08\xd8\x08\xd8\x08\xd8\x08\xd8\x08\xd8\x08\xd8\x08\xd8\x08\xd8\x08\xd8")

  printf "__ctype_b_loc %s\n" "$ctype_bytes" > "$codex_dir/codex"
  printf "__ctype_b_loc %s mprotect madvise\n" "$ctype_bytes" > "$codex_dir/codex-code-mode-host"
  chmod 755 "$codex_dir/codex" "$codex_dir/codex-code-mode-host"
  warn_ok=$(post_install_hook 2>&1)
  [[ -z "$warn_ok" ]] || fail "unexpected warning on valid codex build: $warn_ok"

  printf "__ctype_b_loc %s mprotect mprotect madvise\n" "$ctype_bytes" > "$codex_dir/codex-code-mode-host"
  warn_mprotect=$(post_install_hook 2>&1)
  grep -Fq "unaligned" <<< "$warn_mprotect" || fail "post_install_hook missed unaligned mprotect when ctype passed"
  grep -Fq "mprotect" <<< "$warn_mprotect" || fail "post_install_hook warning did not mention mprotect"

  printf "__ctype_b_loc zeroed\n" > "$codex_dir/codex"
  printf "mprotect madvise madvise\n" > "$codex_dir/codex-code-mode-host"
  warn_both=$(post_install_hook 2>&1)
  grep -Fq "zeroed ctype tables" <<< "$warn_both" || fail "missing zeroed ctype warning"
  grep -Fq "madvise" <<< "$warn_both" || fail "missing madvise warning"
' _ "$repo_dir" "$codex_dir" || fail "codex.conf post_install_hook test failed"

pass "codex.conf post_install_hook checks hostbin even when ctype passes"

# 8. opencode.conf SSL_CERT_FILE + agy.conf GOMEMLIMIT + manifest_json single jq call
cert_prefix="$test_root/cert-prefix"
mkdir -p "$cert_prefix/etc/tls" "$cert_prefix/libexec/opencode"
PREFIX="$cert_prefix" bash -euo pipefail -c '
  repo_dir="$1"
  cert_prefix="$2"
  fail() { printf "FAIL: %s\n" "$1" >&2; exit 1; }

  SCRIPT_DIR="$repo_dir"
  LIBEXEC_DIR="$cert_prefix/libexec/opencode"
  source "$repo_dir/registry/opencode.conf"
  pre_wrapper_hook
  [[ "$WRAPPER_ENV" == "OPENCODE_DISABLE_AUTOUPDATE=1" ]] || fail "unexpected WRAPPER_ENV without cert.pem: $WRAPPER_ENV"

  rm -f "$LIBEXEC_DIR/$WRAPPER_RUNNER"
  touch "$cert_prefix/etc/tls/cert.pem"
  pre_wrapper_hook
  grep -Fxq "OPENCODE_DISABLE_AUTOUPDATE=1" <<< "$WRAPPER_ENV" || fail "missing OPENCODE_DISABLE_AUTOUPDATE=1"
  grep -Fxq "SSL_CERT_FILE=$cert_prefix/etc/tls/cert.pem" <<< "$WRAPPER_ENV" || fail "missing dynamic SSL_CERT_FILE"
' _ "$repo_dir" "$cert_prefix" || fail "opencode.conf pre_wrapper_hook test failed"

bash -euo pipefail -c '
  source "$1/registry/agy.conf"
  grep -Fxq "AGY_CLI_DISABLE_AUTO_UPDATE=true" <<< "$WRAPPER_ENV"
  grep -Fxq "GOMEMLIMIT=1536MiB" <<< "$WRAPPER_ENV"
' _ "$repo_dir" || fail "agy.conf WRAPPER_ENV test failed"

mj_bin="$test_root/mj-bin"
mkdir -p "$mj_bin"
cat > "$mj_bin/curl" <<'EOF'
#!/bin/sh
printf '{"version":"2.4.0","url":"https://example.test/agy.tar.gz","sha512":"AABBCC"}'
EOF
chmod 755 "$mj_bin/curl"
PATH="$mj_bin:$PATH" bash -euo pipefail -c '
  repo_dir="$1"
  fail() { printf "FAIL: %s\n" "$1" >&2; exit 1; }

  set -- agy
  source "$repo_dir/install.sh"
  trap - EXIT
  ARCH="arm64"
  resolve_version >/dev/null
  [[ "$VERSION" == "2.4.0" ]] || fail "manifest_json VERSION mismatch: $VERSION"
  [[ "$DOWNLOAD_URL" == "https://example.test/agy.tar.gz" ]] || fail "manifest_json URL mismatch: $DOWNLOAD_URL"
  [[ "$REMOTE_CHECKSUM" == "aabbcc" ]] || fail "manifest_json checksum lowercase mismatch: $REMOTE_CHECKSUM"
' _ "$repo_dir" || fail "manifest_json single jq call test failed"

# 9. github_latest_release_with_asset object fast-path (1 request on hit, per_page=30 fallback on miss)
gh_bin="$test_root/gh-bin"
gh_urls="$test_root/gh-urls.log"
mkdir -p "$gh_bin"
cat > "$gh_bin/curl" <<EOF
#!/bin/sh
out_file=""
url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    https://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "\$url" >> "$gh_urls"
case "\$url" in
  */releases/latest)
    if [ "\${MOCK_LATEST_MODE:-hit}" = "hit" ]; then
      cat > "\$out_file" <<'JSON'
{"tag_name":"v2.5.0","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","digest":"sha256:aaa","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v2.5.0/opencode-linux-arm64.tar.gz"}]}
JSON
    else
      cat > "\$out_file" <<'JSON'
{"tag_name":"v1.19.5","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","digest":"sha256:bbb","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v1.19.5/opencode-linux-arm64.tar.gz"}]}
JSON
    fi
    ;;
  *"per_page=30&page=1"*)
    cat > "\$out_file" <<'JSON'
[{"tag_name":"v2.4.9","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","digest":"sha256:ccc","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v2.4.9/opencode-linux-arm64.tar.gz"}]}]
JSON
    ;;
  *)
    printf '[]' > "\$out_file"
    ;;
esac
printf '200'
EOF
chmod 755 "$gh_bin/curl"

: > "$gh_urls"
out_hit=$(PATH="$gh_bin:$PATH" MOCK_LATEST_MODE=hit bash "$repo_dir/install.sh" opencode --resolve-version 2>/dev/null)
[[ "$out_hit" == "TARGET_VERSION=2.5.0" ]] || fail "fast-path hit mismatch: $out_hit"
[[ "$(wc -l < "$gh_urls")" -eq 1 ]] || fail "fast-path hit should make only 1 API request"
grep -Fq '/releases/latest' "$gh_urls" || fail "fast-path hit did not query /releases/latest"

: > "$gh_urls"
out_miss=$(PATH="$gh_bin:$PATH" MOCK_LATEST_MODE=miss bash "$repo_dir/install.sh" opencode --resolve-version 2>/dev/null)
[[ "$out_miss" == "TARGET_VERSION=2.4.9" ]] || fail "fast-path miss fallback mismatch: $out_miss"
[[ "$(wc -l < "$gh_urls")" -eq 2 ]] || fail "fast-path miss should query /releases/latest then page=1"
grep -Fq 'per_page=30&page=1' "$gh_urls" || fail "fallback did not use per_page=30"

# 10. Audit regressions: no negative caching on empty resolve, CRLF conf_get, dangling symlink resolv.conf, manifest_json newline rejection, 404 fallback
fail_flag="$test_root/fail-once"
: > "$fail_flag"
cat > "$mock_repo/install.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ -f "$fail_flag" ]]; then
  rm -f "$fail_flag"
  exit 1
fi
printf 'TARGET_VERSION=1.2.5+android1\n'
EOF
chmod 755 "$mock_repo/install.sh"
rm -f "$mock_tmp/aicli_resolve/customtool.latest" "$mock_tmp/aicli_resolve/customtool.result"
out_fail=$(PREFIX="$mock_prefix" TMPDIR="$mock_tmp" AI_CLI_TERMUX_DIR="$mock_repo" \
  bash "$mock_repo/aicli" --no-color list --json 2>/dev/null)
[[ ! -e "$mock_tmp/aicli_resolve/customtool.latest" ]] || fail "empty resolve failure must not be cached"
printf '%s' "$out_fail" | jq -e '.tools[] | select(.name == "customtool") | .latest_version == null' >/dev/null \
  || fail "failed resolve should degrade cleanly to null latest_version"
out_retry=$(PREFIX="$mock_prefix" TMPDIR="$mock_tmp" AI_CLI_TERMUX_DIR="$mock_repo" \
  bash "$mock_repo/aicli" --no-color list --json 2>/dev/null)
printf '%s' "$out_retry" | jq -e '.tools[] | select(.name == "customtool") | .latest_version == "1.2.5+android1"' >/dev/null \
  || fail "subsequent list call stayed poisoned instead of retrying after transient failure"

printf 'APP_NAME="crlfapp"\r\n' > "$test_root/crlf.conf"
bash -c 'source <(sed "\$d" "$1"); [[ "$(conf_get "$2" APP_NAME)" == "crlfapp" ]]' _ "$repo_dir/aicli" "$test_root/crlf.conf" \
  || fail "conf_get failed to strip trailing CR before closing quote"

rm -f "$res_prefix/glibc/etc/resolv.conf"
ln -s "$test_root/nonexistent-host-resolv.conf" "$res_prefix/glibc/etc/resolv.conf"
PREFIX="$res_prefix" PATH="$res_bin:$PATH" bash -euo pipefail -c '
  repo_dir="$1"
  set -- opencode
  source "$repo_dir/install.sh"
  trap - EXIT
  EXEC_DIRECT=false
  ensure_glibc_resolv 2>/dev/null
' _ "$repo_dir" || fail "ensure_glibc_resolv aborted on dangling symlink"
[[ ! -e "$test_root/nonexistent-host-resolv.conf" ]] || fail "ensure_glibc_resolv wrote through dangling symlink target"

cat > "$mj_bin/curl" <<'EOF'
#!/bin/sh
printf '{"version":"2.4.0","url":"https://example.test/a\\nb","sha512":"AABBCC"}'
EOF
chmod 755 "$mj_bin/curl"
if PATH="$mj_bin:$PATH" bash "$repo_dir/install.sh" agy --resolve-version >/dev/null 2>&1; then
  fail "manifest_json with embedded newline should fail closed"
fi

cat > "$gh_bin/curl" <<EOF
#!/bin/sh
out_file=""
url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out_file="\$2"; shift 2 ;;
    https://*) url="\$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "\$url" >> "$gh_urls"
case "\$url" in
  */releases/latest)
    printf '{"message":"Not Found"}' > "\$out_file"
    printf '404'
    exit 0
    ;;
  *"per_page=30&page=1"*)
    cat > "\$out_file" <<'JSON'
[{"tag_name":"v2.4.8","draft":false,"prerelease":false,"assets":[{"name":"opencode-linux-arm64.tar.gz","digest":"sha256:ddd","browser_download_url":"https://github.com/anomalyco/opencode/releases/download/v2.4.8/opencode-linux-arm64.tar.gz"}]}]
JSON
    printf '200'
    ;;
  *)
    printf '[]' > "\$out_file"
    printf '200'
    ;;
esac
EOF
chmod 755 "$gh_bin/curl"
: > "$gh_urls"
out_404=$(PATH="$gh_bin:$PATH" bash "$repo_dir/install.sh" opencode --resolve-version 2>/dev/null)
[[ "$out_404" == "TARGET_VERSION=2.4.8" ]] || fail "404 fast-path fallback mismatch: $out_404"

pass "opencode.conf SSL_CERT_FILE, agy.conf GOMEMLIMIT, manifest_json, releases/latest fallback, and audit regressions"
