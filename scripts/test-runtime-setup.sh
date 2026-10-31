#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

repo_dir=$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
[[ -d "$tmp_base" && -w "$tmp_base" ]] || {
  printf 'No hay un temporal escribible en TMPDIR o PREFIX/tmp.\n' >&2
  exit 1
}
test_root=$(mktemp -d "$tmp_base/runtime-setup.XXXXXX")
trap 'rm -rf "$test_root"' EXIT

export PREFIX="$test_root/prefix"
mkdir -p "$PREFIX/glibc/lib" "$PREFIX/glibc/etc"
touch "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
chmod 700 "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
printf 'hosts: files dns\n' > "$PREFIX/glibc/etc/nsswitch.conf"

set -- opencode
# shellcheck source=install.sh
source "$repo_dir/install.sh"
trap - EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

[[ "$RUNTIME_SETUP" == managed ]] || fail 'el default de RUNTIME_SETUP dejó de ser managed'

LOADER="$GLIBC_PREFIX/lib/ld-linux-aarch64.so.1"
RUNTIME_SETUP=existing
pkg() {
  fail 'RUNTIME_SETUP=existing intentó invocar pkg'
}

check_existing_runtime || fail 'rechazó el runtime glibc sintético válido'
install_deps
ensure_nsswitch
[[ -f "$GLIBC_PREFIX/etc/nsswitch.conf" ]] || fail 'el runtime existente perdió nsswitch.conf'
printf 'PASS: runtime existente aceptado sin modificar paquetes ni nsswitch.conf\n'

rm -f "$LOADER"
if check_existing_runtime > "$test_root/missing-loader.log" 2>&1; then
  fail 'aceptó la ausencia del loader'
fi
grep -q 'requiere un loader glibc ejecutable' "$test_root/missing-loader.log" ||
  fail 'la ausencia del loader no produjo diagnóstico'
printf 'PASS: ausencia del loader rechazada\n'

touch "$LOADER"
chmod 700 "$LOADER"
rm -f "$GLIBC_PREFIX/etc/nsswitch.conf"
if check_existing_runtime > "$test_root/missing-nsswitch.log" 2>&1; then
  fail 'aceptó la ausencia de nsswitch.conf'
fi
ensure_nsswitch
[[ ! -e "$GLIBC_PREFIX/etc/nsswitch.conf" ]] ||
  fail 'ensure_nsswitch escribió configuración para runtime existente'
grep -q 'requiere DNS glibc configurado' "$test_root/missing-nsswitch.log" ||
  fail 'la ausencia de DNS glibc no produjo diagnóstico'
printf 'PASS: nsswitch.conf ausente rechazada sin crear archivos\n'

printf 'Todas las pruebas de runtime existente pasaron.\n'
