#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

repo_dir=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
[[ -d "$tmp_base" && -w "$tmp_base" ]] || {
  printf 'No hay un temporal escribible en TMPDIR o PREFIX/tmp.\n' >&2
  exit 1
}
test_root=$(mktemp -d "$tmp_base/wrapper-runner.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

export PREFIX="$test_root/prefix"
mkdir -p "$PREFIX/glibc/lib" "$PREFIX/libexec/opencode"
set -- opencode
# shellcheck source=install.sh
source "$repo_dir/install.sh"
trap - EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

LIBEXEC_DIR="$PREFIX/libexec/opencode"
BIN_FILE="$LIBEXEC_DIR/opencode"
MANIFEST="$LIBEXEC_DIR/manifest.txt"
WRAPPER="$PREFIX/bin/opencode"
mkdir -p "$PREFIX/bin"
printf '#!/bin/sh\nexit 0\n' > "$BIN_FILE"
chmod 700 "$BIN_FILE"

WRAPPER_RUNNER=runner.sh
WRAPPER_UNSET_ENV=$(printf 'TEST_WRAPPER_SECRET\nTEST_WRAPPER_CONFIG')
WRAPPER_ENV='TEST_WRAPPER_CONFIG=configured'
WRAPPER_DEFAULT_ARGS='--default=ok'
NEEDS_PATCHELF=false
EXEC_DIRECT=false
LOADER="$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
RPATH="$PREFIX/glibc/lib"
runner_file="$LIBEXEC_DIR/$WRAPPER_RUNNER"
args_file="$test_root/runner-args"
secret_file="$test_root/runner-secret"
config_file="$test_root/runner-config"

cat > "$runner_file" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
printf '%s\n' "$@" > "$RUNNER_ARGS_FILE"
printf '%s\n' "${TEST_WRAPPER_SECRET-<unset>}" > "$RUNNER_SECRET_FILE"
printf '%s\n' "${TEST_WRAPPER_CONFIG-<unset>}" > "$RUNNER_CONFIG_FILE"
EOF
chmod 700 "$runner_file"

export RUNNER_ARGS_FILE="$args_file"
export RUNNER_SECRET_FILE="$secret_file"
export RUNNER_CONFIG_FILE="$config_file"
_write_wrapper "$WRAPPER" "$BIN_FILE" "$BIN_FILE"
TEST_WRAPPER_SECRET=inherited TEST_WRAPPER_CONFIG=inherited \
  "$WRAPPER" 'argument with spaces' '--option=two words'

cat > "$test_root/expected-args" <<EOF
$LOADER
--library-path
$RPATH
$BIN_FILE
--default=ok
argument with spaces
--option=two words
EOF
cmp -s "$test_root/expected-args" "$args_file" || fail 'el runner no recibió el argv separado y completo'
grep -Fxq '<unset>' "$secret_file" || fail 'WRAPPER_UNSET_ENV no limpió la variable heredada'
grep -Fxq 'configured' "$config_file" || fail 'WRAPPER_ENV no se aplicó después de limpiar el entorno'
printf 'PASS: runner recibe argv exacto y entorno saneado\n'

APP_NAME=opencode
VERSION=2.2.5
TAG=v2.2.5
TARBALL_CHECKSUM=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
BIN_CHECKSUM_ORIG=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
BIN_CHECKSUM_PATCHED="$BIN_CHECKSUM_ORIG"
EXTRA_PATCHED=''
ATTEST_STATUS=no-aplica
write_manifest
runner_checksum=$(sha256sum "$runner_file" | awk '{print $1}')
grep -Fxq "runner_name=$WRAPPER_RUNNER" "$MANIFEST" || fail 'el manifest no registró el runner'
grep -Fxq "runner_checksum_sha256=$runner_checksum" "$MANIFEST" ||
  fail 'el manifest no registró el SHA256 del runner'
printf 'PASS: manifest registra el runner y su SHA256\n'

verify_repo="$test_root/verify-repo"
verify_prefix="$test_root/verify-prefix"
verify_libexec="$verify_prefix/libexec/opencode"
verify_runner="$verify_libexec/runner.sh"
verify_binary="$verify_libexec/opencode"
verify_wrapper="$verify_prefix/bin/opencode"
case "$(uname -m)" in
  aarch64) verify_loader="$verify_prefix/glibc/lib/ld-linux-aarch64.so.1" ;;
  x86_64) verify_loader="$verify_prefix/glibc/lib/ld-linux-x86-64.so.2" ;;
  *) fail 'arquitectura no soportada por verify.sh' ;;
esac
mkdir -p "$verify_repo/registry" "$verify_libexec" "$verify_prefix/bin" \
  "$(dirname "$verify_loader")" "$verify_prefix/glibc/etc"
cp "$repo_dir/verify.sh" "$verify_repo/verify.sh"
cp "$repo_dir/registry/opencode.conf" "$verify_repo/registry/opencode.conf"
printf '\nWRAPPER_RUNNER="runner.sh"\nWRAPPER_UNSET_ENV="TEST_WRAPPER_SECRET"\n' \
  >> "$verify_repo/registry/opencode.conf"
cp "$BASH" "$verify_binary"
chmod 700 "$verify_binary"
cat > "$verify_runner" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
printf 'opencode v2.2.5\n'
EOF
chmod 700 "$verify_runner"
cat > "$verify_wrapper" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
unset LD_PRELOAD
unset LD_LIBRARY_PATH
unset TEST_WRAPPER_SECRET
exec "$verify_runner" --version
EOF
chmod 700 "$verify_wrapper"
touch "$verify_loader"
chmod 700 "$verify_loader"
printf 'hosts: files dns\n' > "$verify_prefix/glibc/etc/nsswitch.conf"
printf 'nameserver 127.0.0.1\n' > "$verify_prefix/glibc/etc/resolv.conf"
verify_binary_checksum=$(sha256sum "$verify_binary" | awk '{print $1}')
verify_runner_checksum=$(sha256sum "$verify_runner" | awk '{print $1}')
cat > "$verify_libexec/manifest.txt" <<EOF
manifest_version=2
app=opencode
display_name=OpenCode
elf_name=opencode
version=2.2.5
tag=v2.2.5
release_source=github
checksum_algo=sha256
checksum_source=release_digest
tarball_checksum=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
binary_checksum_patched=$verify_binary_checksum
needs_patchelf=false
exec_direct=false
entry_point=
aliases=
interpreter=$verify_loader
rpath=$verify_prefix/glibc/lib
attestation=no-aplica
extra_bins=
runner_name=runner.sh
runner_checksum_sha256=$verify_runner_checksum
EOF

if ! PREFIX="$verify_prefix" "$verify_repo/verify.sh" opencode > "$test_root/verify.out" 2>&1; then
  cat "$test_root/verify.out" >&2
  fail 'verify.sh rechazó el bundle sintético íntegro'
fi
grep -Fq 'Runner presente, ejecutable e íntegro: runner.sh' "$test_root/verify.out" ||
  fail 'verify.sh no informó integridad del runner'
if grep -Fq 'WRAPPER_RUNNER' "$test_root/verify.out"; then
  fail 'verify.sh reportó un problema con WRAPPER_RUNNER'
fi
printf 'PASS: verify.sh acepta runner y wrapper sintéticos íntegros\n'

printf '\n' >> "$verify_runner"
if PREFIX="$verify_prefix" "$verify_repo/verify.sh" opencode > "$test_root/verify-tampered.out" 2>&1; then
  fail 'verify.sh aceptó un runner modificado'
fi
grep -Fq 'Checksum SHA256 incorrecto para el runner runner.sh' "$test_root/verify-tampered.out" ||
  fail 'verify.sh no detectó el cambio del runner'
printf 'PASS: verify.sh detecta cambios posteriores del runner\n'
