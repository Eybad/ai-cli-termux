#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
runtime="$repo_dir/registry/lib/opencode-v2-runtime.sh"
test_tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
mkdir -p "$test_tmp_base"
test_root=$(mktemp -d "$test_tmp_base/opencode-v2-transactions.XXXXXX")
trap 'rm -rf "$test_root"' 0 HUP INT TERM

cat > "$test_root/verify.sh" <<'EOF'
#!/bin/sh
exit "${VERIFY_RESULT:-0}"
EOF
chmod 755 "$test_root/verify.sh"

write_synthetic_wrapper() {
  synthetic_wrapper_version="$1"
  synthetic_wrapper_file="$2"
  synthetic_wrapper_prefix="$3"
  cat > "$synthetic_wrapper_file" <<EOF
#!/bin/sh
BIN="$synthetic_wrapper_prefix/libexec/opencode-v2/opencode"
EXEC_TARGET="$synthetic_wrapper_prefix/libexec/opencode-v2/opencode"
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' '$synthetic_wrapper_version'
  exit 0
fi
exec "$synthetic_wrapper_prefix/libexec/opencode-v2/opencode-v2-runtime.sh" "\$EXEC_TARGET" "\$@"
EOF
  chmod 755 "$synthetic_wrapper_file"
}

setup_transaction() {
  test_case_root="$1"
  old_version="$2"
  old_tag="$3"
  old_sequence="$4"
  new_version="$5"
  new_tag="$6"
  new_sequence="$7"
  export HOME="$test_case_root/home"
  export PREFIX="$test_case_root/prefix"
  export TMPDIR="$PREFIX/tmp"
  mkdir -p "$PREFIX/libexec/opencode-v2" "$PREFIX/bin" "$PREFIX/tmp"
  printf 'synthetic candidate archive\n' > "$test_case_root/archive-fixture"
  tar -czf "$PREFIX/tmp/candidate.tar.gz" -C "$test_case_root" archive-fixture
  TMP_FILE="$PREFIX/tmp/candidate.tar.gz"
  mkdir -p "$HOME/.local/share/ai-cli-termux/opencode-v2/config" \
    "$HOME/.local/share/ai-cli-termux/opencode-v2/data" \
    "$HOME/.local/share/ai-cli-termux/opencode-v2/state"
  printf 'old config %s\n' "$old_version" > \
    "$HOME/.local/share/ai-cli-termux/opencode-v2/config/settings.json"
  printf 'old database %s\n' "$old_version" > \
    "$HOME/.local/share/ai-cli-termux/opencode-v2/data/opencode-v2.db"
  printf 'old state %s\n' "$old_version" > \
    "$HOME/.local/share/ai-cli-termux/opencode-v2/state/state.json"
  printf 'old binary %s\n' "$old_version" > "$PREFIX/libexec/opencode-v2/opencode"
  chmod 755 "$PREFIX/libexec/opencode-v2/opencode"
  printf 'old runtime\n' > "$PREFIX/libexec/opencode-v2/opencode-v2-runtime.sh"
  chmod 755 "$PREFIX/libexec/opencode-v2/opencode-v2-runtime.sh"
  old_binary_checksum=$(sha256sum "$PREFIX/libexec/opencode-v2/opencode" | awk '{ print $1 }')
  old_runner_checksum=$(sha256sum "$PREFIX/libexec/opencode-v2/opencode-v2-runtime.sh" |
    awk '{ print $1 }')
  cat > "$PREFIX/libexec/opencode-v2/manifest.txt" <<EOF
app=opencode-v2
elf_name=opencode
version=$old_version
tag=$old_tag
release_sequence=$old_sequence
release_contract=termux-glibc-1
release_source_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
tarball_checksum=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
binary_checksum_original=$old_binary_checksum
runner_name=opencode-v2-runtime.sh
runner_checksum_sha256=$old_runner_checksum
EOF
  write_synthetic_wrapper "$old_version" "$PREFIX/bin/opencode-v2" "$PREFIX"
  APP_NAME=opencode-v2
  LIBEXEC_DIR="$PREFIX/libexec/opencode-v2"
  WRAPPER="$PREFIX/bin/opencode-v2"
  MANIFEST="$LIBEXEC_DIR/manifest.txt"
  VERSION="$new_version"
  TAG="$new_tag"
  TARBALL_CHECKSUM=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
  CATALOG_SEQUENCE="$new_sequence"
  CATALOG_CONTRACT=termux-glibc-1
  CATALOG_SOURCE_COMMIT=dddddddddddddddddddddddddddddddddddddddd
  opencode_v2_runtime_project_root="$test_root"
  opencode_v2_runtime_init_paths
}

create_candidate() {
  candidate_version="$1"
  candidate_tag="$2"
  candidate_sequence="$3"
  mv "$LIBEXEC_DIR" "$BACKUP_DIR"
  cp -a "$WRAPPER" "$BACKUP_DIR/.wrapper"
  mkdir -p "$LIBEXEC_DIR"
  printf 'new binary %s\n' "$candidate_version" > "$LIBEXEC_DIR/opencode"
  chmod 755 "$LIBEXEC_DIR/opencode"
  printf 'new runtime %s\n' "$candidate_version" > "$LIBEXEC_DIR/opencode-v2-runtime.sh"
  chmod 755 "$LIBEXEC_DIR/opencode-v2-runtime.sh"
  candidate_binary_checksum=$(sha256sum "$LIBEXEC_DIR/opencode" | awk '{ print $1 }')
  candidate_runner_checksum=$(sha256sum "$LIBEXEC_DIR/opencode-v2-runtime.sh" |
    awk '{ print $1 }')
  cat > "$MANIFEST" <<EOF
app=opencode-v2
elf_name=opencode
version=$candidate_version
tag=$candidate_tag
release_sequence=$candidate_sequence
release_contract=termux-glibc-1
release_source_commit=dddddddddddddddddddddddddddddddddddddddd
tarball_checksum=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
binary_checksum_original=$candidate_binary_checksum
runner_name=opencode-v2-runtime.sh
runner_checksum_sha256=$candidate_runner_checksum
EOF
  write_synthetic_wrapper "$candidate_version" "$WRAPPER" "$PREFIX"
}

# shellcheck source=registry/lib/opencode-v2-runtime.sh
. "$runtime"

symlink_root="$test_root/symlink-ancestor"
mkdir -p "$symlink_root"
setup_transaction "$symlink_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
mv "$HOME/.local" "$symlink_root/local"
ln -s "$symlink_root/local" "$HOME/.local"
symlink_prepare_status=0
if opencode_v2_runtime_transaction_prepare 2> "$symlink_root/prepare.err"; then
  symlink_prepare_status=0
else
  symlink_prepare_status=$?
fi
[ "$symlink_prepare_status" -eq 1 ] || {
  printf 'FAIL: prepare aceptó un antecesor symlink de HOME\n' >&2
  exit 1
}
grep -Fq 'atraviesa un symlink' "$symlink_root/prepare.err" || {
  printf 'FAIL: prepare no explicó el rechazo del antecesor symlink\n' >&2
  exit 1
}
[ ! -e "$symlink_root/local/share/ai-cli-termux/recovery/opencode-v2" ] || {
  printf 'FAIL: prepare escribió recuperación bajo el destino del symlink\n' >&2
  exit 1
}
grep -Fxq 'old config 2.2.6' \
  "$symlink_root/local/share/ai-cli-termux/opencode-v2/config/settings.json" || {
    printf 'FAIL: prepare alteró el perfil detrás del symlink\n' >&2
    exit 1
  }
printf 'PASS: prepare rechaza antecesores symlink sin escribir en su destino\n'

profile_symlink_root="$test_root/profile-symlink"
mkdir -p "$profile_symlink_root"
setup_transaction "$profile_symlink_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
mv "$HOME/.local/share/ai-cli-termux/opencode-v2" "$profile_symlink_root/profile-target"
ln -s "$profile_symlink_root/profile-target" \
  "$HOME/.local/share/ai-cli-termux/opencode-v2"
profile_symlink_status=0
if opencode_v2_runtime_transaction_prepare 2> "$profile_symlink_root/prepare.err"; then
  profile_symlink_status=0
else
  profile_symlink_status=$?
fi
if [ "$profile_symlink_status" -ne 1 ] ||
   ! grep -Fq 'atraviesa un symlink' "$profile_symlink_root/prepare.err" ||
   [ -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2" ] ||
   ! grep -Fxq 'old config 2.2.6' "$profile_symlink_root/profile-target/config/settings.json"; then
  printf 'FAIL: prepare siguió o alteró un perfil symlink\n' >&2
  exit 1
fi
printf 'PASS: prepare rechaza el perfil symlink antes de medirlo o copiarlo\n'

wrapper_collision_root="$test_root/wrapper-collision"
mkdir -p "$wrapper_collision_root"
setup_transaction "$wrapper_collision_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
write_synthetic_wrapper 2.2.6 "$WRAPPER" "$wrapper_collision_root/foreign"
wrapper_collision_status=0
if opencode_v2_runtime_transaction_prepare 2> "$wrapper_collision_root/prepare.err"; then
  wrapper_collision_status=0
else
  wrapper_collision_status=$?
fi
if [ "$wrapper_collision_status" -ne 1 ] ||
   ! grep -Fq 'wrapper anterior no apunta' "$wrapper_collision_root/prepare.err" ||
   ! grep -Fxq 'version=2.2.6' "$MANIFEST" ||
   [ -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/current" ]; then
  printf 'FAIL: prepare aceptó o alteró un wrapper de otro bundle\n' >&2
  exit 1
fi
printf 'PASS: prepare rechaza wrappers cuyo target no corresponde al bundle\n'

successful_root="$test_root/success"
mkdir -p "$successful_root"
setup_transaction "$successful_root" 2.2.5 v2.2.5 1 2.2.6 v2.2.6 2
old_profile_digest=$(opencode_v2_runtime_transaction_tree_digest \
  "$HOME/.local/share/ai-cli-termux/opencode-v2")
opencode_v2_runtime_transaction_prepare
[ "$BACKUP_DIR" = "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/current/bundle" ] || {
  printf 'FAIL: prepare no reservó el respaldo esperado\n' >&2
  exit 1
}
concurrent_lock_status=0
if opencode_v2_runtime_acquire_run_lock 2> "$successful_root/concurrent.err"; then
  concurrent_lock_status=0
else
  concurrent_lock_status=$?
fi
if [ "$concurrent_lock_status" -ne 1 ] ||
   [ ! -d "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] ||
   [ ! -f "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" ]; then
  printf 'FAIL: una reentrada aceptó la ejecución concurrente o tocó la transacción\n' >&2
  exit 1
fi
create_candidate 2.2.6 v2.2.6 2
VERIFY_RESULT=0 opencode_v2_runtime_transaction_validate
opencode_v2_runtime_transaction_commit
[ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" ] || {
  printf 'FAIL: commit dejó un journal pendiente\n' >&2
  exit 1
}
[ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] || {
  printf 'FAIL: commit dejó el lock activo\n' >&2
  exit 1
}
grep -Fxq 'version=2.2.5' \
  "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/previous/bundle/manifest.txt" || {
  printf 'FAIL: commit no conservó el bundle anterior\n' >&2
  exit 1
}
if [ "$("$WRAPPER" --version)" != 2.2.6 ]; then
  printf 'FAIL: commit alteró el wrapper candidato\n' >&2
  exit 1
fi
[ "$(opencode_v2_runtime_transaction_tree_digest \
  "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/previous/profile")" = "$old_profile_digest" ] || {
  printf 'FAIL: commit no conservó el perfil anterior\n' >&2
  exit 1
}
printf 'PASS: prepare, validate y commit conservan bundle, wrapper y perfil\n'
HOME="$HOME" PREFIX="$PREFIX" sh "$runtime" status > "$successful_root/status.out"
grep -Fxq 'previous=v2.2.5' "$successful_root/status.out" || {
  printf 'FAIL: status no mostró el tag anterior\n' >&2
  exit 1
}
grep -Fxq 'previous_contract=termux-glibc-1' "$successful_root/status.out" || {
  printf 'FAIL: status no mostró el contrato del respaldo\n' >&2
  exit 1
}
printf 'candidate database 2.2.6\n' > \
  "$HOME/.local/share/ai-cli-termux/opencode-v2/data/opencode-v2.db"
mkdir -p "$HOME/.local/share/ai-cli-termux/opencode-v2/cache"
printf 'stale candidate cache\n' > \
  "$HOME/.local/share/ai-cli-termux/opencode-v2/cache/index"
HOME="$HOME" PREFIX="$PREFIX" sh "$runtime" rollback
grep -Fxq 'version=2.2.5' "$MANIFEST" || {
  printf 'FAIL: rollback offline no restauró el bundle anterior\n' >&2
  exit 1
}
if [ "$("$WRAPPER" --version)" != 2.2.5 ]; then
  printf 'FAIL: rollback offline no restauró el wrapper anterior\n' >&2
  exit 1
fi
grep -Fxq 'old database 2.2.5' \
  "$HOME/.local/share/ai-cli-termux/opencode-v2/data/opencode-v2.db" || {
    printf 'FAIL: rollback offline no restauró el perfil anterior\n' >&2
    exit 1
  }
grep -Fxq 'candidate database 2.2.6' \
  "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/displaced/profile/data/opencode-v2.db" || {
    printf 'FAIL: rollback offline no conservó el perfil desplazado\n' >&2
    exit 1
  }
[ ! -e "$HOME/.local/share/ai-cli-termux/opencode-v2/cache" ] || {
  printf 'FAIL: rollback offline conservó la caché de la versión desplazada\n' >&2
  exit 1
}
[ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/previous" ] &&
  [ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" ] || {
    printf 'FAIL: rollback offline dejó un estado pendiente\n' >&2
    exit 1
  }
printf 'PASS: rollback offline restaura el conjunto y conserva el perfil desplazado\n'

manual_interrupted_root="$test_root/manual-interrupted"
mkdir -p "$manual_interrupted_root"
setup_transaction "$manual_interrupted_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
opencode_v2_runtime_transaction_prepare
create_candidate 2.2.7 v2.2.7 3
VERIFY_RESULT=0 opencode_v2_runtime_transaction_validate
opencode_v2_runtime_transaction_commit
printf 'candidate database 2.2.7\n' > \
  "$HOME/.local/share/ai-cli-termux/opencode-v2/data/opencode-v2.db"
real_mv=$(command -v mv)
mkdir -p "$manual_interrupted_root/bin"
cat > "$manual_interrupted_root/bin/mv" <<'EOF'
#!/bin/sh
previous_arg=''
last_arg=''
for argument do
  previous_arg=$last_arg
  last_arg=$argument
done
if [ "$previous_arg" = "$FAIL_MV_SOURCE" ] && [ "$last_arg" = "$FAIL_MV_TARGET" ]; then
  exit 77
fi
exec "$REAL_MV" "$@"
EOF
chmod 755 "$manual_interrupted_root/bin/mv"
export REAL_MV="$real_mv"
export FAIL_MV_SOURCE="$PREFIX/libexec/.opencode-v2-restore"
export FAIL_MV_TARGET="$PREFIX/libexec/opencode-v2"
rollback_status=0
if PATH="$manual_interrupted_root/bin:$PATH" HOME="$HOME" PREFIX="$PREFIX" \
  sh "$runtime" rollback 2> "$manual_interrupted_root/rollback.err"; then
  rollback_status=0
else
  rollback_status=$?
fi
[ "$rollback_status" -eq 1 ] || {
  printf 'FAIL: el rollback de prueba no se interrumpió en el punto esperado\n' >&2
  exit 1
}
unset REAL_MV FAIL_MV_SOURCE FAIL_MV_TARGET
[ -d "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/displaced/profile" ] &&
  [ -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" ] || {
    printf 'FAIL: la interrupción no conservó journal y perfil desplazado\n' >&2
    exit 1
  }
HOME="$HOME" PREFIX="$PREFIX" sh "$runtime" status > "$manual_interrupted_root/status.out"
if ! grep -Fxq 'pending=manual-restoring' "$manual_interrupted_root/status.out" ||
   ! grep -Fxq 'previous_contract=termux-glibc-1' "$manual_interrupted_root/status.out"; then
  printf 'FAIL: status no informó fase y contrato del rollback interrumpido\n' >&2
  exit 1
fi
grep -Fxq 'phase=manual-restoring' "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" || {
  printf 'FAIL: el journal no conservó la fase de recuperación\n' >&2
  exit 1
}
HOME="$HOME" PREFIX="$PREFIX" sh "$runtime" rollback
grep -Fxq 'version=2.2.6' "$MANIFEST" || {
  printf 'FAIL: la reanudación no restauró el bundle anterior\n' >&2
  exit 1
}
grep -Fxq 'candidate database 2.2.7' \
  "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/displaced/profile/data/opencode-v2.db" || {
    printf 'FAIL: la reanudación no conservó el perfil desplazado\n' >&2
    exit 1
  }
[ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" ] || {
  printf 'FAIL: la reanudación dejó un journal pendiente\n' >&2
  exit 1
}
printf 'PASS: rollback offline reanuda después de mover el perfil desplazado\n'

initial_snapshot_root="$test_root/initial-snapshot"
mkdir -p "$initial_snapshot_root"
setup_transaction "$initial_snapshot_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
legacy_previous="$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/previous"
mkdir -p "$legacy_previous/profile"
opencode_v2_runtime_tx_phase=committing
opencode_v2_runtime_tx_restore_from_previous=false
opencode_v2_runtime_tx_had_bundle=0
opencode_v2_runtime_tx_had_wrapper=0
opencode_v2_runtime_tx_had_profile=0
opencode_v2_runtime_tx_old_version=''
opencode_v2_runtime_tx_old_tag=''
opencode_v2_runtime_tx_old_sequence=''
opencode_v2_runtime_tx_old_contract=''
opencode_v2_runtime_tx_old_source_commit=''
opencode_v2_runtime_tx_old_digest=''
opencode_v2_runtime_tx_old_bundle_digest=''
opencode_v2_runtime_tx_old_wrapper_digest=''
opencode_v2_runtime_tx_profile_digest=$(opencode_v2_runtime_transaction_tree_digest \
  "$legacy_previous/profile")
opencode_v2_runtime_tx_candidate_version=2.2.5
opencode_v2_runtime_tx_candidate_tag=v2.2.5
opencode_v2_runtime_tx_candidate_sequence=1
opencode_v2_runtime_tx_candidate_contract=termux-glibc-1
opencode_v2_runtime_tx_candidate_source_commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
opencode_v2_runtime_tx_candidate_digest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
opencode_v2_runtime_tx_candidate_bundle_digest=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
opencode_v2_runtime_tx_candidate_wrapper_digest=dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
opencode_v2_runtime_transaction_write_journal committing
mv "$opencode_v2_runtime_journal" "$legacy_previous/transaction.txt"
opencode_v2_runtime_transaction_prepare
create_candidate 2.2.7 v2.2.7 3
VERIFY_RESULT=0 opencode_v2_runtime_transaction_validate
opencode_v2_runtime_transaction_commit
grep -Fxq 'version=2.2.6' \
  "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/previous/bundle/manifest.txt" || {
  printf 'FAIL: el snapshot inicial impidió guardar la v2 previa\n' >&2
  exit 1
}
[ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/previous.old" ] || {
  printf 'FAIL: conservó una generación de recuperación extra\n' >&2
  exit 1
}
printf 'PASS: una reinstalación rota conserva la última v2 confirmada\n'

corrupt_previous_root="$test_root/corrupt-previous"
mkdir -p "$corrupt_previous_root"
setup_transaction "$corrupt_previous_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
opencode_v2_runtime_transaction_prepare
create_candidate 2.2.7 v2.2.7 3
VERIFY_RESULT=0 opencode_v2_runtime_transaction_validate
opencode_v2_runtime_transaction_commit
printf 'corrupt previous runner\n' > \
  "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/previous/bundle/opencode-v2-runtime.sh"
VERSION=2.2.8
TAG=v2.2.8
TARBALL_CHECKSUM=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
CATALOG_SEQUENCE=4
corrupt_previous_prepare_status=0
if opencode_v2_runtime_transaction_prepare 2> "$corrupt_previous_root/prepare.err"; then
  corrupt_previous_prepare_status=0
else
  corrupt_previous_prepare_status=$?
fi
[ "$corrupt_previous_prepare_status" -eq 1 ] || {
  printf 'FAIL: prepare aceptó un respaldo anterior alterado\n' >&2
  exit 1
}
grep -Fxq 'version=2.2.7' "$MANIFEST" || {
  printf 'FAIL: rechazo del respaldo alterado tocó el bundle activo\n' >&2
  exit 1
}
[ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/current" ] || {
  printf 'FAIL: rechazo del respaldo alterado dejó un snapshot parcial\n' >&2
  exit 1
}
printf 'PASS: prepare rechaza un respaldo previo corrupto sin tocar la versión activa\n'

orphan_root="$test_root/orphan-snapshot"
mkdir -p "$orphan_root/home/.local/share/ai-cli-termux/recovery/opencode-v2/current"
export HOME="$orphan_root/home"
export PREFIX="$orphan_root/prefix"
mkdir -p "$PREFIX/tmp"
opencode_v2_runtime_init_paths
orphan_status=0
if opencode_v2_runtime_status > "$orphan_root/status.out" 2> "$orphan_root/status.err"; then
  orphan_status=0
else
  orphan_status=$?
fi
[ "$orphan_status" -eq 1 ] || {
  printf 'FAIL: status no rechazó el snapshot sin journal\n' >&2
  exit 1
}
grep -Fxq 'state=incomplete' "$orphan_root/status.out" || {
  printf 'FAIL: status no bloqueó un snapshot sin journal\n' >&2
  exit 1
}
orphan_run_lock_status=0
if opencode_v2_runtime_acquire_run_lock 2> "$orphan_root/run.err"; then
  orphan_run_lock_status=0
else
  orphan_run_lock_status=$?
fi
[ "$orphan_run_lock_status" -eq 1 ] &&
  [ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] || {
    printf 'FAIL: el runner ignoró un snapshot sin journal\n' >&2
    exit 1
  }
printf 'PASS: snapshots sin journal bloquean status y la ejecución normal\n'

journal_symlink_root="$test_root/journal-symlink"
mkdir -p "$journal_symlink_root/home/.local/share/ai-cli-termux/recovery/opencode-v2" \
  "$journal_symlink_root/prefix/bin" "$journal_symlink_root/prefix/libexec"
printf 'preserve this target\n' > "$journal_symlink_root/external-journal"
ln -s "$journal_symlink_root/external-journal" \
  "$journal_symlink_root/home/.local/share/ai-cli-termux/recovery/opencode-v2/journal"
export HOME="$journal_symlink_root/home"
export PREFIX="$journal_symlink_root/prefix"
journal_status=0
if opencode_v2_runtime_status > "$journal_symlink_root/status.out" \
  2> "$journal_symlink_root/status.err"; then
  journal_status=0
else
  journal_status=$?
fi
journal_rollback_status=0
if opencode_v2_runtime_rollback 2> "$journal_symlink_root/rollback.err"; then
  journal_rollback_status=0
else
  journal_rollback_status=$?
fi
if [ "$journal_status" -ne 1 ] || [ "$journal_rollback_status" -ne 1 ] ||
   [ ! -L "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" ] ||
   ! grep -Fxq 'preserve this target' "$journal_symlink_root/external-journal"; then
  printf 'FAIL: status o rollback siguió o reemplazó un journal symlink\n' >&2
  exit 1
fi
printf 'PASS: status y rollback rechazan journals symlink sin tocar el destino\n'

space_root="$test_root/insufficient-space"
mkdir -p "$space_root"
setup_transaction "$space_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
mkdir -p "$space_root/bin"
cat > "$space_root/bin/df" <<'EOF'
#!/bin/sh
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'synthetic 1000000 999999 1 100%% /\n'
EOF
chmod 755 "$space_root/bin/df"
space_prepare_status=0
if PATH="$space_root/bin:$PATH" opencode_v2_runtime_transaction_prepare \
  2> "$space_root/prepare.err"; then
  space_prepare_status=0
else
  space_prepare_status=$?
fi
[ "$space_prepare_status" -eq 1 ] || {
  printf 'FAIL: prepare aceptó espacio libre insuficiente\n' >&2
  exit 1
}
if ! grep -Fxq 'version=2.2.6' "$MANIFEST" ||
   [ -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/current" ] ||
   [ -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" ] ||
   [ -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ]; then
  printf 'FAIL: el gate de espacio insuficiente alteró el conjunto activo\n' >&2
  exit 1
fi
printf 'PASS: espacio insuficiente aborta antes del snapshot y el reemplazo\n'

failed_root="$test_root/validate-failure"
mkdir -p "$failed_root"
setup_transaction "$failed_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
old_profile_digest=$(opencode_v2_runtime_transaction_tree_digest \
  "$HOME/.local/share/ai-cli-termux/opencode-v2")
opencode_v2_runtime_transaction_prepare
create_candidate 2.2.7 v2.2.7 3
printf 'candidate migration\n' > "$HOME/.local/share/ai-cli-termux/opencode-v2/data/opencode-v2.db"
validation_status=0
if VERIFY_RESULT=1 opencode_v2_runtime_transaction_validate; then
  validation_status=0
else
  validation_status=$?
fi
[ "$validation_status" -eq 1 ] || { printf 'FAIL: validate fallido no abortó\n' >&2; exit 1; }
opencode_v2_runtime_transaction_rollback
grep -Fxq 'version=2.2.6' "$MANIFEST" || {
  printf 'FAIL: rollback no restauró el manifest anterior\n' >&2
  exit 1
}
if [ "$("$WRAPPER" --version)" != 2.2.6 ]; then
  printf 'FAIL: rollback no restauró el wrapper anterior\n' >&2
  exit 1
fi
[ "$(opencode_v2_runtime_transaction_tree_digest \
  "$HOME/.local/share/ai-cli-termux/opencode-v2")" = "$old_profile_digest" ] || {
  printf 'FAIL: rollback no restauró el perfil anterior\n' >&2
  exit 1
}
[ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" ] &&
  [ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] || {
    printf 'FAIL: rollback no liberó el estado transaccional\n' >&2
    exit 1
  }
printf 'PASS: validate fallido restaura el conjunto anterior\n'

move_interrupted_root="$test_root/interrupted-bundle-move"
mkdir -p "$move_interrupted_root"
setup_transaction "$move_interrupted_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
opencode_v2_runtime_transaction_prepare
mkdir -p "$BACKUP_DIR"
cp -a "$LIBEXEC_DIR/opencode" "$BACKUP_DIR/opencode"
printf 'partial copy\n' > "$BACKUP_DIR/opencode-v2-runtime.sh"
move_rollback_status=0
if opencode_v2_runtime_transaction_rollback 2> "$move_interrupted_root/rollback.err"; then
  move_rollback_status=0
else
  move_rollback_status=$?
fi
if [ "$move_rollback_status" -ne 0 ] ||
   ! grep -Fxq 'version=2.2.6' "$MANIFEST" ||
   [ -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/current" ]; then
  printf 'FAIL: rollback no recuperó el bundle original ante un respaldo parcial\n' >&2
  exit 1
fi
printf 'PASS: rollback descarta copia parcial si el bundle activo sigue íntegro\n'

wrapper_move_interrupted_root="$test_root/interrupted-wrapper-move"
mkdir -p "$wrapper_move_interrupted_root"
setup_transaction "$wrapper_move_interrupted_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
opencode_v2_runtime_transaction_prepare
mv "$LIBEXEC_DIR" "$BACKUP_DIR"
opencode_v2_runtime_transaction_rollback
if ! grep -Fxq 'version=2.2.6' "$MANIFEST" ||
   [ "$("$WRAPPER" --version)" != 2.2.6 ] ||
   [ -e "$LIBEXEC_DIR/.wrapper" ]; then
  printf 'FAIL: rollback no usó el wrapper activo íntegro tras mover el bundle\n' >&2
  exit 1
fi
printf 'PASS: rollback restaura el bundle movido antes de copiar el wrapper\n'

version_root="$test_root/wrong-version"
mkdir -p "$version_root"
setup_transaction "$version_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
opencode_v2_runtime_transaction_prepare
create_candidate 2.2.7 v2.2.7 3
write_synthetic_wrapper 9.9.9 "$WRAPPER" "$PREFIX"
version_validation_status=0
if VERIFY_RESULT=0 opencode_v2_runtime_transaction_validate \
  2> "$version_root/validate.err"; then
  version_validation_status=0
else
  version_validation_status=$?
fi
[ "$version_validation_status" -eq 1 ] || {
  printf 'FAIL: validate aceptó una versión distinta del candidato\n' >&2
  exit 1
}
grep -Fq 'no coincide con el candidato' "$version_root/validate.err" || {
  printf 'FAIL: validate no explicó la versión incorrecta\n' >&2
  exit 1
}
opencode_v2_runtime_transaction_rollback
grep -Fxq 'version=2.2.6' "$MANIFEST" || {
  printf 'FAIL: rollback por versión incorrecta no restauró el bundle anterior\n' >&2
  exit 1
}
printf 'PASS: versión reportada incorrecta aborta y restaura el conjunto\n'

runner_root="$test_root/runner-tampered"
mkdir -p "$runner_root"
setup_transaction "$runner_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
opencode_v2_runtime_transaction_prepare
create_candidate 2.2.7 v2.2.7 3
printf 'tampered runner\n' > "$LIBEXEC_DIR/opencode-v2-runtime.sh"
runner_validation_status=0
if VERIFY_RESULT=0 opencode_v2_runtime_transaction_validate \
  2> "$runner_root/validate.err"; then
  runner_validation_status=0
else
  runner_validation_status=$?
fi
[ "$runner_validation_status" -eq 1 ] || {
  printf 'FAIL: validate aceptó un runner cuyo hash no coincide\n' >&2
  exit 1
}
grep -Fq 'no coincide con sus hashes' "$runner_root/validate.err" || {
  printf 'FAIL: validate no explicó el hash incorrecto del runner\n' >&2
  exit 1
}
opencode_v2_runtime_transaction_rollback
grep -Fxq 'version=2.2.6' "$MANIFEST" || {
  printf 'FAIL: rollback por runner alterado no restauró el bundle anterior\n' >&2
  exit 1
}
printf 'PASS: el hash del runner se valida antes de confirmar\n'

prepared_root="$test_root/interrupted-prepare"
mkdir -p "$prepared_root"
setup_transaction "$prepared_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
opencode_v2_runtime_transaction_prepare
cat > "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/lock/owner" <<'EOF'
schema=1
kind=transaction
pid=999999999
start_time=1
EOF
HOME="$HOME" PREFIX="$PREFIX" sh "$runtime" rollback
grep -Fxq 'version=2.2.6' "$MANIFEST" || {
  printf 'FAIL: recuperación tras prepare no conservó el bundle anterior\n' >&2
  exit 1
}
if [ "$("$WRAPPER" --version)" != 2.2.6 ]; then
  printf 'FAIL: recuperación tras prepare eliminó el wrapper anterior\n' >&2
  exit 1
fi
printf 'PASS: recovery tras interrupción en prepare limpia el lock huérfano\n'

promoted_root="$test_root/interrupted-promote"
mkdir -p "$promoted_root"
setup_transaction "$promoted_root" 2.2.6 v2.2.6 2 2.2.7 v2.2.7 3
opencode_v2_runtime_transaction_prepare
create_candidate 2.2.7 v2.2.7 3
VERIFY_RESULT=0 opencode_v2_runtime_transaction_validate
opencode_v2_runtime_tx_phase=committing
opencode_v2_runtime_transaction_write_journal committing
cp "$opencode_v2_runtime_journal" "$opencode_v2_runtime_tx_snapshot/transaction.txt"
chmod 600 "$opencode_v2_runtime_tx_snapshot/transaction.txt"
mv "$opencode_v2_runtime_tx_snapshot" "$opencode_v2_runtime_recovery/previous"
opencode_v2_runtime_tx_snapshot="$opencode_v2_runtime_recovery/previous"
opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_tx_snapshot/profile"
opencode_v2_runtime_tx_bundle_backup="$opencode_v2_runtime_tx_snapshot/bundle"
opencode_v2_runtime_transaction_write_journal promoted
cat > "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/lock/owner" <<'EOF'
schema=1
kind=transaction
pid=999999999
start_time=1
EOF
HOME="$HOME" PREFIX="$PREFIX" sh "$runtime" rollback
grep -Fxq 'version=2.2.6' "$MANIFEST" || {
  printf 'FAIL: recovery tras promote no restauró el bundle anterior\n' >&2
  exit 1
}
grep -Fxq 'old database 2.2.6' \
  "$HOME/.local/share/ai-cli-termux/opencode-v2/data/opencode-v2.db" || {
    printf 'FAIL: recovery tras promote no restauró el perfil anterior\n' >&2
    exit 1
  }
[ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/journal" ] &&
  [ ! -e "$HOME/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] || {
    printf 'FAIL: recovery tras promote dejó lock o journal\n' >&2
    exit 1
  }
printf 'PASS: recovery tras interrupción en promote restaura el conjunto previo\n'

fresh_root="$test_root/fresh"
mkdir -p "$fresh_root/home" "$fresh_root/prefix/libexec" \
  "$fresh_root/prefix/bin" "$fresh_root/prefix/tmp"
export HOME="$fresh_root/home"
export PREFIX="$fresh_root/prefix"
export TMPDIR="$PREFIX/tmp"
printf 'synthetic candidate archive\n' > "$fresh_root/archive-fixture"
tar -czf "$PREFIX/tmp/candidate.tar.gz" -C "$fresh_root" archive-fixture
TMP_FILE="$PREFIX/tmp/candidate.tar.gz"
APP_NAME=opencode-v2
LIBEXEC_DIR="$PREFIX/libexec/opencode-v2"
WRAPPER="$PREFIX/bin/opencode-v2"
MANIFEST="$LIBEXEC_DIR/manifest.txt"
VERSION=2.2.5
TAG=v2.2.5
TARBALL_CHECKSUM=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
CATALOG_SEQUENCE=1
CATALOG_CONTRACT=termux-glibc-1
CATALOG_SOURCE_COMMIT=dddddddddddddddddddddddddddddddddddddddd
opencode_v2_runtime_init_paths
opencode_v2_runtime_transaction_prepare
mkdir -p "$LIBEXEC_DIR"
printf 'candidate\n' > "$LIBEXEC_DIR/opencode"
printf '#!/bin/sh\nexit 0\n' > "$WRAPPER"
chmod 755 "$WRAPPER"
opencode_v2_runtime_transaction_rollback
[ ! -e "$LIBEXEC_DIR" ] && [ ! -e "$WRAPPER" ] &&
  [ ! -e "$HOME/.local/share/ai-cli-termux/opencode-v2" ] || {
    printf 'FAIL: rollback de alta inicial no restauró la ausencia\n' >&2
    exit 1
  }
printf 'PASS: rollback de alta inicial restaura la ausencia\n'

invalid_transaction_status=0
if sh "$runtime" transaction invalid > "$test_root/transaction.out" \
  2> "$test_root/transaction.err"; then
  invalid_transaction_status=0
else
  invalid_transaction_status=$?
fi
if [ "$invalid_transaction_status" -ne 2 ] ||
   ! grep -Fq 'Fase transaccional inválida' "$test_root/transaction.err"; then
  printf 'FAIL: transaction no rechazó una fase inválida como error de uso\n' >&2
  exit 1
fi
printf 'PASS: transaction rechaza fases inválidas con exit 2\n'
