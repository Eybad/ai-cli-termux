#!/bin/sh

opencode_v2_runtime_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

opencode_v2_runtime_init_paths() {
  case "${HOME:-}" in
    /*) ;;
    *) opencode_v2_runtime_error 'HOME debe ser una ruta absoluta.'; return 1 ;;
  esac

  opencode_v2_runtime_base="$HOME/.local/share/ai-cli-termux"
  opencode_v2_runtime_profile="$opencode_v2_runtime_base/opencode-v2"
  opencode_v2_runtime_recovery="$opencode_v2_runtime_base/recovery/opencode-v2"
  opencode_v2_runtime_lock="$opencode_v2_runtime_recovery/lock"
  opencode_v2_runtime_journal="$opencode_v2_runtime_recovery/journal"
}

opencode_v2_runtime_validate_path_ancestors() {
  opencode_v2_runtime_path="$1"
  case "$opencode_v2_runtime_path" in
    /|/*/) opencode_v2_runtime_error 'La ruta privada debe ser absoluta y no puede ser la raíz.'; return 1 ;;
    /*) ;;
    *) opencode_v2_runtime_error 'La ruta privada debe ser absoluta.'; return 1 ;;
  esac
  opencode_v2_runtime_path_rest=${opencode_v2_runtime_path#/}
  opencode_v2_runtime_path_current=''
  while [ -n "$opencode_v2_runtime_path_rest" ]; do
    case "$opencode_v2_runtime_path_rest" in
      */*)
        opencode_v2_runtime_path_component=${opencode_v2_runtime_path_rest%%/*}
        opencode_v2_runtime_path_rest=${opencode_v2_runtime_path_rest#*/}
        ;;
      *)
        opencode_v2_runtime_path_component=$opencode_v2_runtime_path_rest
        opencode_v2_runtime_path_rest=''
        ;;
    esac
    case "$opencode_v2_runtime_path_component" in
      ''|.) continue ;;
      ..) opencode_v2_runtime_error "La ruta privada no puede contener el componente '..'."; return 1 ;;
    esac
    opencode_v2_runtime_path_current="$opencode_v2_runtime_path_current/$opencode_v2_runtime_path_component"
    if [ -L "$opencode_v2_runtime_path_current" ]; then
      opencode_v2_runtime_error "La ruta privada atraviesa un symlink: $opencode_v2_runtime_path_current"
      return 1
    fi
  done
  return 0
}

opencode_v2_runtime_proc_start_time() {
  awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null
}

opencode_v2_runtime_proc_state() {
  awk '{ sub(/^.*\) /, ""); print $1 }' "/proc/$1/stat" 2>/dev/null
}

opencode_v2_runtime_process_matches() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(opencode_v2_runtime_proc_start_time "$1")" = "$2" ] || return 1
  case "$(opencode_v2_runtime_proc_state "$1")" in
    Z|X|'') return 1 ;;
  esac
}

opencode_v2_runtime_owner_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$1"
}

opencode_v2_runtime_write_owner() {
  opencode_v2_runtime_owner_tmp=$(mktemp "$opencode_v2_runtime_lock/.owner.XXXXXX") || return 1
  if ! chmod 600 "$opencode_v2_runtime_owner_tmp"; then
    rm -f "$opencode_v2_runtime_owner_tmp"
    return 1
  fi
  if ! cat > "$opencode_v2_runtime_owner_tmp" <<EOF
schema=1
kind=$1
pid=$2
start_time=$3
server_pid=$4
server_start_time=$5
reader_pid=$6
reader_start_time=$7
client_pid=$8
client_start_time=$9
EOF
  then
    rm -f "$opencode_v2_runtime_owner_tmp"
    return 1
  fi
  if ! mv -f "$opencode_v2_runtime_owner_tmp" "$opencode_v2_runtime_lock/owner"; then
    rm -f "$opencode_v2_runtime_owner_tmp"
    return 1
  fi
  sync
}

opencode_v2_runtime_create_private_dir() {
  opencode_v2_runtime_validate_path_ancestors "$1" || return 1
  mkdir -p "$1" || return 1
  chmod 700 "$1"
}

opencode_v2_runtime_acquire_run_lock() {
  umask 077
  opencode_v2_runtime_create_private_dir "$opencode_v2_runtime_recovery" || return 1

  if [ -L "$opencode_v2_runtime_journal" ] || [ -L "$opencode_v2_runtime_lock" ]; then
    opencode_v2_runtime_error 'El journal o el lock de recuperación es un symlink.'
    return 1
  fi
  for opencode_v2_runtime_incomplete_path in \
    "$opencode_v2_runtime_recovery/current" \
    "$opencode_v2_runtime_recovery/previous.old" \
    "$opencode_v2_runtime_recovery/manual"; do
    if [ -e "$opencode_v2_runtime_incomplete_path" ] || [ -L "$opencode_v2_runtime_incomplete_path" ]; then
      opencode_v2_runtime_error 'Hay un snapshot de recuperación sin cierre; consultá status y ejecutá rollback.'
      return 1
    fi
  done
  if [ -e "$opencode_v2_runtime_journal" ]; then
    opencode_v2_runtime_error 'Hay una transacción pendiente; consultá status y ejecutá rollback antes de volver a abrir OpenCode v2.'
    return 1
  fi

  if ! mkdir "$opencode_v2_runtime_lock" 2>/dev/null; then
    opencode_v2_runtime_owner_file="$opencode_v2_runtime_lock/owner"
    if [ -f "$opencode_v2_runtime_owner_file" ]; then
      opencode_v2_runtime_owner_pid=$(opencode_v2_runtime_owner_value "$opencode_v2_runtime_owner_file" pid)
      opencode_v2_runtime_owner_start=$(opencode_v2_runtime_owner_value "$opencode_v2_runtime_owner_file" start_time)
      if opencode_v2_runtime_process_matches "$opencode_v2_runtime_owner_pid" "$opencode_v2_runtime_owner_start"; then
        opencode_v2_runtime_error 'OpenCode v2 ya tiene una ejecución u operación activa.'
      else
        opencode_v2_runtime_error 'El lock de OpenCode v2 parece huérfano; revisá status y recuperalo explícitamente.'
      fi
    else
      opencode_v2_runtime_error 'El lock de OpenCode v2 existe sin identidad verificable; requiere recuperación explícita.'
    fi
    return 1
  fi

  if ! chmod 700 "$opencode_v2_runtime_lock"; then
    rmdir "$opencode_v2_runtime_lock" 2>/dev/null || true
    return 1
  fi
  opencode_v2_runtime_owner_start=$(opencode_v2_runtime_proc_start_time "$$")
  case "$opencode_v2_runtime_owner_start" in
    ''|*[!0-9]*)
      rmdir "$opencode_v2_runtime_lock" 2>/dev/null || true
      opencode_v2_runtime_error 'No se pudo verificar la identidad del proceso para adquirir el lock.'
      return 1
      ;;
  esac
  opencode_v2_runtime_server_pid=''
  opencode_v2_runtime_server_start=''
  opencode_v2_runtime_reader_pid=''
  opencode_v2_runtime_reader_start=''
  if ! opencode_v2_runtime_write_owner run "$$" "$opencode_v2_runtime_owner_start" '' '' '' '' '' ''; then
    rm -f "$opencode_v2_runtime_lock/owner" "$opencode_v2_runtime_lock"/.owner.*
    rmdir "$opencode_v2_runtime_lock" 2>/dev/null || true
    opencode_v2_runtime_error 'No se pudo registrar el lock de OpenCode v2.'
    return 1
  fi
}

opencode_v2_runtime_prepare_profile() {
  umask 077
  opencode_v2_runtime_create_private_dir "$opencode_v2_runtime_profile" || return 1
  opencode_v2_runtime_profile_symlink=$(find "$opencode_v2_runtime_profile" -type l -print -quit) || return 1
  if [ -n "$opencode_v2_runtime_profile_symlink" ]; then
    opencode_v2_runtime_error 'El perfil contiene symlinks y no se puede aislar con seguridad.'
    return 1
  fi
  for opencode_v2_runtime_directory in config data cache state log tmp; do
    opencode_v2_runtime_create_private_dir "$opencode_v2_runtime_profile/$opencode_v2_runtime_directory" || return 1
  done
  opencode_v2_runtime_config_dir="$opencode_v2_runtime_profile/config"
  opencode_v2_runtime_data_dir="$opencode_v2_runtime_profile/data"
  opencode_v2_runtime_cache_dir="$opencode_v2_runtime_profile/cache"
  opencode_v2_runtime_state_dir="$opencode_v2_runtime_profile/state"
  opencode_v2_runtime_tmp_dir="$opencode_v2_runtime_profile/tmp"

  export XDG_CONFIG_HOME="$opencode_v2_runtime_config_dir"
  export XDG_DATA_HOME="$opencode_v2_runtime_data_dir"
  export XDG_CACHE_HOME="$opencode_v2_runtime_cache_dir"
  export XDG_STATE_HOME="$opencode_v2_runtime_state_dir"
  export OPENCODE_DB="$opencode_v2_runtime_data_dir/opencode-v2.db"
  export OPENCODE_DISABLE_PROJECT_CONFIG=1
  export OPENCODE_PURE=1
  export OPENCODE_DISABLE_DEFAULT_PLUGINS=1
  export OPENCODE_DISABLE_EXTERNAL_SKILLS=1
  export OPENCODE_DISABLE_CLAUDE_CODE=1
  export TMPDIR="$opencode_v2_runtime_tmp_dir"

  unset OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT OPENCODE_CLI_CONFIG_CONTENT OPENCODE_TUI_CONFIG
  unset OPENCODE_PERMISSION OPENCODE_SERVER OPENCODE_SERVER_PASSWORD OPENCODE_PASSWORD
  unset OPENCODE_CONFIG_PROJECT_DISABLE
}

opencode_v2_runtime_random_password() {
  opencode_v2_runtime_password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n') || return 1
  [ "${#opencode_v2_runtime_password}" -eq 48 ] || return 1
}

opencode_v2_runtime_launch() {
  if [ -n "$opencode_v2_runtime_loader" ]; then
    "$opencode_v2_runtime_loader" --library-path "$opencode_v2_runtime_library_path" \
      "$opencode_v2_runtime_binary" "$@"
  else
    "$opencode_v2_runtime_binary" "$@"
  fi
}

opencode_v2_runtime_server_output() {
  while IFS= read -r opencode_v2_runtime_line; do
    case "$opencode_v2_runtime_line" in
      *'server listening on http://127.0.0.1:'*)
        opencode_v2_runtime_port=$(printf '%s\n' "$opencode_v2_runtime_line" |
          sed -n 's/.*http:\/\/127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p')
        case "$opencode_v2_runtime_port" in
          ''|*[!0-9]*) continue ;;
        esac
        if [ "$opencode_v2_runtime_port" -gt 0 ] && [ "$opencode_v2_runtime_port" -le 65535 ]; then
          printf '%s\n' "$opencode_v2_runtime_port" > "$opencode_v2_runtime_port_file.tmp"
          mv -f "$opencode_v2_runtime_port_file.tmp" "$opencode_v2_runtime_port_file"
        fi
        ;;
    esac
  done < "$opencode_v2_runtime_fifo"
}

opencode_v2_runtime_stop_child() {
  opencode_v2_runtime_child_pid="$1"
  opencode_v2_runtime_child_start="$2"
  [ -n "$opencode_v2_runtime_child_pid" ] || return 0
  if opencode_v2_runtime_process_matches "$opencode_v2_runtime_child_pid" "$opencode_v2_runtime_child_start"; then
    kill -TERM "$opencode_v2_runtime_child_pid" 2>/dev/null || true
    opencode_v2_runtime_wait=0
    while [ "$opencode_v2_runtime_wait" -lt 3 ]; do
      opencode_v2_runtime_process_matches "$opencode_v2_runtime_child_pid" "$opencode_v2_runtime_child_start" || break
      sleep 1
      opencode_v2_runtime_wait=$((opencode_v2_runtime_wait + 1))
    done
    if opencode_v2_runtime_process_matches "$opencode_v2_runtime_child_pid" "$opencode_v2_runtime_child_start"; then
      kill -KILL "$opencode_v2_runtime_child_pid" 2>/dev/null || true
    fi
  fi
  wait "$opencode_v2_runtime_child_pid" 2>/dev/null || true
}

opencode_v2_runtime_release_run_lock() {
  opencode_v2_runtime_owner_file="$opencode_v2_runtime_lock/owner"
  if [ -f "$opencode_v2_runtime_owner_file" ] &&
     [ "$(opencode_v2_runtime_owner_value "$opencode_v2_runtime_owner_file" pid)" = "$$" ] &&
     [ "$(opencode_v2_runtime_owner_value "$opencode_v2_runtime_owner_file" start_time)" = "$opencode_v2_runtime_owner_start" ]; then
    rm -f "$opencode_v2_runtime_owner_file"
    rmdir "$opencode_v2_runtime_lock/recover" 2>/dev/null || true
    rmdir "$opencode_v2_runtime_lock" 2>/dev/null || true
    sync || true
  fi
}

opencode_v2_runtime_launch_client() {
  opencode_v2_runtime_connect_server="$1"
  shift

  if [ "$opencode_v2_runtime_connect_server" = true ]; then
    if [ -n "$opencode_v2_runtime_loader" ]; then
      OPENCODE_PASSWORD="$opencode_v2_runtime_password" "$opencode_v2_runtime_loader" \
        --library-path "$opencode_v2_runtime_library_path" "$opencode_v2_runtime_binary" \
        --server "http://127.0.0.1:$opencode_v2_runtime_port" "$@" &
    else
      OPENCODE_PASSWORD="$opencode_v2_runtime_password" "$opencode_v2_runtime_binary" \
        --server "http://127.0.0.1:$opencode_v2_runtime_port" "$@" &
    fi
  elif [ -n "$opencode_v2_runtime_loader" ]; then
    "$opencode_v2_runtime_loader" --library-path "$opencode_v2_runtime_library_path" \
      "$opencode_v2_runtime_binary" "$@" &
  else
    "$opencode_v2_runtime_binary" "$@" &
  fi

  opencode_v2_runtime_client_pid=$!
  opencode_v2_runtime_client_start=$(opencode_v2_runtime_proc_start_time "$opencode_v2_runtime_client_pid")
  case "$opencode_v2_runtime_client_start" in
    ''|*[!0-9]*) opencode_v2_runtime_error 'No se pudo verificar la identidad del cliente privado.'; return 1 ;;
  esac
  opencode_v2_runtime_write_owner run "$$" "$opencode_v2_runtime_owner_start" \
    "${opencode_v2_runtime_server_pid:-}" "${opencode_v2_runtime_server_start:-}" \
    "${opencode_v2_runtime_reader_pid:-}" "${opencode_v2_runtime_reader_start:-}" \
    "$opencode_v2_runtime_client_pid" "$opencode_v2_runtime_client_start" || return 1

  if [ -t 0 ] && [ -t 1 ]; then
    trap '' INT
  fi
  if wait "$opencode_v2_runtime_client_pid"; then
    opencode_v2_runtime_client_status=0
  else
    opencode_v2_runtime_client_status=$?
  fi
  opencode_v2_runtime_client_pid=''
  opencode_v2_runtime_client_start=''
  opencode_v2_runtime_write_owner run "$$" "$opencode_v2_runtime_owner_start" \
    "${opencode_v2_runtime_server_pid:-}" "${opencode_v2_runtime_server_start:-}" \
    "${opencode_v2_runtime_reader_pid:-}" "${opencode_v2_runtime_reader_start:-}" '' '' || return 1
  return "$opencode_v2_runtime_client_status"
}

opencode_v2_runtime_cleanup_run() {
  opencode_v2_runtime_status=$?
  trap - 0 HUP INT TERM
  opencode_v2_runtime_stop_child "${opencode_v2_runtime_client_pid:-}" "${opencode_v2_runtime_client_start:-}"
  opencode_v2_runtime_stop_child "${opencode_v2_runtime_server_pid:-}" "${opencode_v2_runtime_server_start:-}"
  opencode_v2_runtime_stop_child "${opencode_v2_runtime_reader_pid:-}" "${opencode_v2_runtime_reader_start:-}"
  [ -z "${opencode_v2_runtime_tmp_root:-}" ] || rm -rf "$opencode_v2_runtime_tmp_root"
  opencode_v2_runtime_release_run_lock
  exit "$opencode_v2_runtime_status"
}

opencode_v2_runtime_signal() {
  case "$1" in
    HUP) opencode_v2_runtime_signal_status=129 ;;
    INT) opencode_v2_runtime_signal_status=130 ;;
    TERM) opencode_v2_runtime_signal_status=143 ;;
  esac
  if [ "$1" != INT ] && [ -n "${opencode_v2_runtime_client_pid:-}" ] &&
     opencode_v2_runtime_process_matches "$opencode_v2_runtime_client_pid" "$opencode_v2_runtime_client_start"; then
    kill -"$1" "$opencode_v2_runtime_client_pid" 2>/dev/null || true
  fi
  exit "$opencode_v2_runtime_signal_status"
}

opencode_v2_runtime_check_health() {
  opencode_v2_runtime_health_url="http://127.0.0.1:$opencode_v2_runtime_port/api/info"
  opencode_v2_runtime_expected_version=''
  if [ -f "$opencode_v2_runtime_bundle/manifest.txt" ]; then
    opencode_v2_runtime_expected_version=$(awk -F= '$1 == "version" { print substr($0, index($0, "=") + 1); exit }' \
      "$opencode_v2_runtime_bundle/manifest.txt")
  fi
  [ -n "$opencode_v2_runtime_expected_version" ] || {
    opencode_v2_runtime_error 'El manifest no contiene la versión esperada del servidor.'
    return 1
  }
  opencode_v2_runtime_expected_version=${opencode_v2_runtime_expected_version%%+*}
  opencode_v2_runtime_expected_version=${opencode_v2_runtime_expected_version#v}

  opencode_v2_runtime_attempt=0
  while [ "$opencode_v2_runtime_attempt" -lt 10 ]; do
    if opencode_v2_runtime_health=$(printf 'user = "opencode:%s"\n' "$opencode_v2_runtime_password" |
      curl --config - --fail --silent --show-error --connect-timeout 1 --max-time 2 \
        "$opencode_v2_runtime_health_url" 2>/dev/null); then
      if printf '%s' "$opencode_v2_runtime_health" |
        jq -e --arg version "$opencode_v2_runtime_expected_version" '.version == $version' >/dev/null 2>&1; then
        return 0
      fi
    fi
    opencode_v2_runtime_attempt=$((opencode_v2_runtime_attempt + 1))
    sleep 1
  done
  opencode_v2_runtime_error 'El servidor efímero no confirmó su versión por la API local.'
  return 1
}

opencode_v2_runtime_transaction_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$1"
}

opencode_v2_runtime_transaction_key_file_valid() {
  awk -F= -v expected="$2" '
    NF != 2 || $1 !~ /^[a-z_]+$/ || seen[$1]++ { exit 1 }
    { count++ }
    END { if (count != expected) exit 1 }
  ' "$1"
}

opencode_v2_runtime_transaction_tree_digest() {
  opencode_v2_runtime_digest_root="$1"
  [ -d "$opencode_v2_runtime_digest_root" ] || return 1
  if (cd "$opencode_v2_runtime_digest_root" && find . -type l -print -quit) | grep -q .; then
    return 1
  fi
  (
    cd "$opencode_v2_runtime_digest_root" || exit 1
    find . -type f -exec sha256sum {} + 2>/dev/null |
      LC_ALL=C sort | sha256sum | awk '{ print $1 }'
  )
}

opencode_v2_runtime_transaction_profile_digest() {
  opencode_v2_runtime_profile_digest_root="$1"
  [ -d "$opencode_v2_runtime_profile_digest_root" ] &&
    [ ! -L "$opencode_v2_runtime_profile_digest_root" ] || return 1
  if (cd "$opencode_v2_runtime_profile_digest_root" && find . -type l -print -quit) | grep -q .; then
    return 1
  fi
  (
    cd "$opencode_v2_runtime_profile_digest_root" || exit 1
    for opencode_v2_runtime_profile_directory in config data state; do
      if [ -e "$opencode_v2_runtime_profile_directory" ]; then
        [ -d "$opencode_v2_runtime_profile_directory" ] &&
          find "./$opencode_v2_runtime_profile_directory" -type f -exec sha256sum {} + || exit 1
      fi
    done | LC_ALL=C sort | sha256sum | awk '{ print $1 }'
  )
}

opencode_v2_runtime_transaction_active_profile_digest() {
  if [ -e "$opencode_v2_runtime_profile" ] || [ -L "$opencode_v2_runtime_profile" ]; then
    opencode_v2_runtime_transaction_profile_digest "$opencode_v2_runtime_profile"
  else
    printf '' | sha256sum | awk '{ print $1 }'
  fi
}

opencode_v2_runtime_transaction_bundle_digest() {
  opencode_v2_runtime_bundle_root="$1"
  [ -d "$opencode_v2_runtime_bundle_root" ] && [ ! -L "$opencode_v2_runtime_bundle_root" ] || return 1
  if (cd "$opencode_v2_runtime_bundle_root" && find . -type l -print -quit) | grep -q .; then
    return 1
  fi
  (
    cd "$opencode_v2_runtime_bundle_root" || exit 1
    find . -type f ! -path './.wrapper' -exec sha256sum {} + 2>/dev/null |
      LC_ALL=C sort | sha256sum | awk '{ print $1 }'
  )
}

opencode_v2_runtime_transaction_verify_bundle() {
  opencode_v2_runtime_verify_bundle_root="$1"
  opencode_v2_runtime_verify_manifest="$opencode_v2_runtime_verify_bundle_root/manifest.txt"
  [ -d "$opencode_v2_runtime_verify_bundle_root" ] &&
    [ ! -L "$opencode_v2_runtime_verify_bundle_root" ] &&
    [ -f "$opencode_v2_runtime_verify_manifest" ] && [ ! -L "$opencode_v2_runtime_verify_manifest" ] || return 1
  [ "$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_verify_manifest" app)" = opencode-v2 ] || return 1
  opencode_v2_runtime_verify_elf=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_verify_manifest" elf_name)
  case "$opencode_v2_runtime_verify_elf" in
    ''|*[!A-Za-z0-9._-]*|.|..) return 1 ;;
  esac
  opencode_v2_runtime_verify_binary="$opencode_v2_runtime_verify_bundle_root/$opencode_v2_runtime_verify_elf"
  [ -f "$opencode_v2_runtime_verify_binary" ] && [ -x "$opencode_v2_runtime_verify_binary" ] &&
    [ ! -L "$opencode_v2_runtime_verify_binary" ] || return 1
  opencode_v2_runtime_verify_expected=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_verify_manifest" binary_checksum_patched)
  [ -n "$opencode_v2_runtime_verify_expected" ] ||
    opencode_v2_runtime_verify_expected=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_verify_manifest" binary_checksum_original)
  printf '%s\n' "$opencode_v2_runtime_verify_expected" | grep -Eq '^[a-f0-9]{64}$' || return 1
  opencode_v2_runtime_verify_actual=$(sha256sum "$opencode_v2_runtime_verify_binary" | awk '{ print $1 }') || return 1
  [ "$opencode_v2_runtime_verify_actual" = "$opencode_v2_runtime_verify_expected" ] || return 1

  opencode_v2_runtime_verify_runner=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_verify_manifest" runner_name)
  [ "$opencode_v2_runtime_verify_runner" = opencode-v2-runtime.sh ] || return 1
  opencode_v2_runtime_verify_runner_file="$opencode_v2_runtime_verify_bundle_root/$opencode_v2_runtime_verify_runner"
  [ -f "$opencode_v2_runtime_verify_runner_file" ] &&
    [ -x "$opencode_v2_runtime_verify_runner_file" ] &&
    [ ! -L "$opencode_v2_runtime_verify_runner_file" ] || return 1
  opencode_v2_runtime_verify_runner_expected=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_verify_manifest" runner_checksum_sha256)
  printf '%s\n' "$opencode_v2_runtime_verify_runner_expected" | grep -Eq '^[a-f0-9]{64}$' || return 1
  opencode_v2_runtime_verify_runner_actual=$(sha256sum "$opencode_v2_runtime_verify_runner_file" |
    awk '{ print $1 }') || return 1
  [ "$opencode_v2_runtime_verify_runner_actual" = "$opencode_v2_runtime_verify_runner_expected" ]
}

opencode_v2_runtime_transaction_verify_wrapper() {
  opencode_v2_runtime_verify_wrapper_file="$1"
  opencode_v2_runtime_verify_wrapper_bundle="$2"
  opencode_v2_runtime_verify_wrapper_libexec="$3"
  [ -f "$opencode_v2_runtime_verify_wrapper_file" ] &&
    [ -x "$opencode_v2_runtime_verify_wrapper_file" ] &&
    [ ! -L "$opencode_v2_runtime_verify_wrapper_file" ] || return 1
  [ "$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_verify_wrapper_bundle/manifest.txt" app)" = opencode-v2 ] || return 1
  opencode_v2_runtime_verify_wrapper_elf=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_verify_wrapper_bundle/manifest.txt" elf_name)
  opencode_v2_runtime_verify_wrapper_runner=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_verify_wrapper_bundle/manifest.txt" runner_name)
  case "$opencode_v2_runtime_verify_wrapper_elf" in
    ''|*[!A-Za-z0-9._-]*|.|..) return 1 ;;
  esac
  [ "$opencode_v2_runtime_verify_wrapper_runner" = opencode-v2-runtime.sh ] || return 1
  opencode_v2_runtime_verify_wrapper_target="$opencode_v2_runtime_verify_wrapper_libexec/$opencode_v2_runtime_verify_wrapper_elf"
  opencode_v2_runtime_verify_wrapper_bin_line="BIN=\"$opencode_v2_runtime_verify_wrapper_target\""
  opencode_v2_runtime_verify_wrapper_target_line="EXEC_TARGET=\"$opencode_v2_runtime_verify_wrapper_target\""
  opencode_v2_runtime_verify_wrapper_exec_prefix="exec \"$opencode_v2_runtime_verify_wrapper_libexec/$opencode_v2_runtime_verify_wrapper_runner\" "
  awk -v expected_bin="$opencode_v2_runtime_verify_wrapper_bin_line" \
    -v expected_target="$opencode_v2_runtime_verify_wrapper_target_line" \
    -v expected_exec_prefix="$opencode_v2_runtime_verify_wrapper_exec_prefix" '
      $0 == expected_bin { bin_count++ }
      $0 == expected_target { target_count++ }
      index($0, expected_exec_prefix) == 1 && index($0, "\"$EXEC_TARGET\"") > 0 { runner_count++ }
      END { exit !(bin_count == 1 && target_count == 1 && runner_count == 1) }
    ' "$opencode_v2_runtime_verify_wrapper_file"
}

opencode_v2_runtime_transaction_validate_previous() {
  opencode_v2_runtime_previous="$opencode_v2_runtime_recovery/previous"
  [ -d "$opencode_v2_runtime_previous" ] && [ ! -L "$opencode_v2_runtime_previous" ] || return 1
  opencode_v2_runtime_transaction_load_journal "$opencode_v2_runtime_previous/transaction.txt" || return 1
  [ "$opencode_v2_runtime_tx_phase" = committing ] &&
    [ "$opencode_v2_runtime_tx_had_bundle" = 1 ] &&
    [ "$opencode_v2_runtime_tx_had_wrapper" = 1 ] || return 1
  opencode_v2_runtime_previous_bundle="$opencode_v2_runtime_previous/bundle"
  opencode_v2_runtime_previous_profile="$opencode_v2_runtime_previous/profile"
  opencode_v2_runtime_transaction_verify_bundle "$opencode_v2_runtime_previous_bundle" || return 1
  [ "$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_previous_bundle/manifest.txt" version)" = "$opencode_v2_runtime_tx_old_version" ] &&
    [ "$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_previous_bundle/manifest.txt" tag)" = "$opencode_v2_runtime_tx_old_tag" ] &&
    [ "$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_previous_bundle/manifest.txt" release_sequence)" = "$opencode_v2_runtime_tx_old_sequence" ] &&
    [ "$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_previous_bundle/manifest.txt" release_contract)" = "$opencode_v2_runtime_tx_old_contract" ] &&
    [ "$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_previous_bundle/manifest.txt" release_source_commit)" = "$opencode_v2_runtime_tx_old_source_commit" ] &&
    [ "$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_previous_bundle/manifest.txt" tarball_checksum)" = "$opencode_v2_runtime_tx_old_digest" ] || return 1
  opencode_v2_runtime_previous_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
    "$opencode_v2_runtime_previous_bundle") || return 1
  [ "$opencode_v2_runtime_previous_bundle_digest" = "$opencode_v2_runtime_tx_old_bundle_digest" ] || return 1
  [ -f "$opencode_v2_runtime_previous_bundle/.wrapper" ] &&
    [ -x "$opencode_v2_runtime_previous_bundle/.wrapper" ] &&
    [ ! -L "$opencode_v2_runtime_previous_bundle/.wrapper" ] || return 1
  opencode_v2_runtime_transaction_verify_wrapper \
    "$opencode_v2_runtime_previous_bundle/.wrapper" "$opencode_v2_runtime_previous_bundle" \
    "$opencode_v2_runtime_tx_libexec" || return 1
  opencode_v2_runtime_previous_wrapper_digest=$(sha256sum \
    "$opencode_v2_runtime_previous_bundle/.wrapper" | awk '{ print $1 }') || return 1
  [ "$opencode_v2_runtime_previous_wrapper_digest" = "$opencode_v2_runtime_tx_old_wrapper_digest" ] || return 1
  opencode_v2_runtime_previous_profile_digest=$(opencode_v2_runtime_transaction_tree_digest \
    "$opencode_v2_runtime_previous_profile") || return 1
  [ "$opencode_v2_runtime_previous_profile_digest" = "$opencode_v2_runtime_tx_profile_digest" ]
}

opencode_v2_runtime_transaction_write_journal() {
  opencode_v2_runtime_journal_tmp=$(mktemp "$opencode_v2_runtime_recovery/.journal.XXXXXX") || return 1
  chmod 600 "$opencode_v2_runtime_journal_tmp" || {
    rm -f "$opencode_v2_runtime_journal_tmp"
    return 1
  }
  if ! cat > "$opencode_v2_runtime_journal_tmp" <<EOF
schema=1
phase=$1
restore_from_previous=$opencode_v2_runtime_tx_restore_from_previous
had_bundle=$opencode_v2_runtime_tx_had_bundle
had_wrapper=$opencode_v2_runtime_tx_had_wrapper
had_profile=$opencode_v2_runtime_tx_had_profile
old_version=$opencode_v2_runtime_tx_old_version
old_tag=$opencode_v2_runtime_tx_old_tag
old_sequence=$opencode_v2_runtime_tx_old_sequence
old_contract=$opencode_v2_runtime_tx_old_contract
old_source_commit=$opencode_v2_runtime_tx_old_source_commit
old_digest=$opencode_v2_runtime_tx_old_digest
old_bundle_digest=$opencode_v2_runtime_tx_old_bundle_digest
old_wrapper_digest=$opencode_v2_runtime_tx_old_wrapper_digest
profile_digest=$opencode_v2_runtime_tx_profile_digest
candidate_version=$opencode_v2_runtime_tx_candidate_version
candidate_tag=$opencode_v2_runtime_tx_candidate_tag
candidate_sequence=$opencode_v2_runtime_tx_candidate_sequence
candidate_contract=$opencode_v2_runtime_tx_candidate_contract
candidate_source_commit=$opencode_v2_runtime_tx_candidate_source_commit
candidate_digest=$opencode_v2_runtime_tx_candidate_digest
candidate_bundle_digest=$opencode_v2_runtime_tx_candidate_bundle_digest
candidate_wrapper_digest=$opencode_v2_runtime_tx_candidate_wrapper_digest
EOF
  then
    rm -f "$opencode_v2_runtime_journal_tmp"
    return 1
  fi
  mv -f "$opencode_v2_runtime_journal_tmp" "$opencode_v2_runtime_journal" || {
    rm -f "$opencode_v2_runtime_journal_tmp"
    return 1
  }
  sync
}

opencode_v2_runtime_transaction_load_journal() {
  opencode_v2_runtime_journal_source=${1:-$opencode_v2_runtime_journal}
  [ -f "$opencode_v2_runtime_journal_source" ] && [ ! -L "$opencode_v2_runtime_journal_source" ] || return 1
  opencode_v2_runtime_transaction_key_file_valid "$opencode_v2_runtime_journal_source" 23 || return 1
  opencode_v2_runtime_tx_schema=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" schema)
  opencode_v2_runtime_tx_phase=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" phase)
  opencode_v2_runtime_tx_restore_from_previous=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal_source" restore_from_previous)
  opencode_v2_runtime_tx_had_bundle=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" had_bundle)
  opencode_v2_runtime_tx_had_wrapper=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" had_wrapper)
  opencode_v2_runtime_tx_had_profile=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" had_profile)
  opencode_v2_runtime_tx_old_version=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" old_version)
  opencode_v2_runtime_tx_old_tag=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" old_tag)
  opencode_v2_runtime_tx_old_sequence=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" old_sequence)
  opencode_v2_runtime_tx_old_contract=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" old_contract)
  opencode_v2_runtime_tx_old_source_commit=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" old_source_commit)
  opencode_v2_runtime_tx_old_digest=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" old_digest)
  opencode_v2_runtime_tx_old_bundle_digest=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" old_bundle_digest)
  opencode_v2_runtime_tx_old_wrapper_digest=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" old_wrapper_digest)
  opencode_v2_runtime_tx_profile_digest=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" profile_digest)
  opencode_v2_runtime_tx_candidate_version=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" candidate_version)
  opencode_v2_runtime_tx_candidate_tag=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" candidate_tag)
  opencode_v2_runtime_tx_candidate_sequence=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" candidate_sequence)
  opencode_v2_runtime_tx_candidate_contract=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" candidate_contract)
  opencode_v2_runtime_tx_candidate_source_commit=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" candidate_source_commit)
  opencode_v2_runtime_tx_candidate_digest=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" candidate_digest)
  opencode_v2_runtime_tx_candidate_bundle_digest=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" candidate_bundle_digest)
  opencode_v2_runtime_tx_candidate_wrapper_digest=$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal_source" candidate_wrapper_digest)
  [ "$opencode_v2_runtime_tx_schema" = 1 ] || return 1
  case "$opencode_v2_runtime_tx_phase" in
    prepared|validated|committing|promoted|rolled-back) ;;
    *) return 1 ;;
  esac
  case "$opencode_v2_runtime_tx_restore_from_previous" in
    true|false) ;;
    *) return 1 ;;
  esac
  case "$opencode_v2_runtime_tx_had_bundle:$opencode_v2_runtime_tx_had_wrapper:$opencode_v2_runtime_tx_had_profile" in
    0:0:0|0:0:1|1:1:0|1:1:1) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$opencode_v2_runtime_tx_candidate_tag" |
    grep -Eq '^v?2\.[0-9]+\.[0-9]+([+]android[0-9]+)?$' || return 1
  printf '%s\n' "$opencode_v2_runtime_tx_candidate_version" |
    grep -Eq '^2\.[0-9]+\.[0-9]+([+]android[0-9]+)?$' || return 1
  [ "${opencode_v2_runtime_tx_candidate_tag#v}" = "$opencode_v2_runtime_tx_candidate_version" ] || return 1
  printf '%s\n' "$opencode_v2_runtime_tx_candidate_digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
  printf '%s\n' "$opencode_v2_runtime_tx_candidate_sequence" | grep -Eq '^[1-9][0-9]*$' || return 1
  [ "$opencode_v2_runtime_tx_candidate_contract" = termux-glibc-1 ] || return 1
  printf '%s\n' "$opencode_v2_runtime_tx_candidate_source_commit" | grep -Eq '^[a-f0-9]{40}$' || return 1
  printf '%s\n' "$opencode_v2_runtime_tx_profile_digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
  if [ "$opencode_v2_runtime_tx_had_bundle" = 1 ]; then
    printf '%s\n' "$opencode_v2_runtime_tx_old_tag" |
      grep -Eq '^v?2\.[0-9]+\.[0-9]+([+]android[0-9]+)?$' || return 1
    printf '%s\n' "$opencode_v2_runtime_tx_old_version" |
      grep -Eq '^2\.[0-9]+\.[0-9]+([+]android[0-9]+)?$' || return 1
    [ "${opencode_v2_runtime_tx_old_tag#v}" = "$opencode_v2_runtime_tx_old_version" ] || return 1
    printf '%s\n' "$opencode_v2_runtime_tx_old_sequence" | grep -Eq '^[1-9][0-9]*$' || return 1
    [ "$opencode_v2_runtime_tx_old_contract" = termux-glibc-1 ] || return 1
    printf '%s\n' "$opencode_v2_runtime_tx_old_source_commit" | grep -Eq '^[a-f0-9]{40}$' || return 1
    printf '%s\n' "$opencode_v2_runtime_tx_old_digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
    printf '%s\n' "$opencode_v2_runtime_tx_old_bundle_digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
    printf '%s\n' "$opencode_v2_runtime_tx_old_wrapper_digest" | grep -Eq '^[a-f0-9]{64}$' || return 1
  else
    [ "$opencode_v2_runtime_tx_old_version$opencode_v2_runtime_tx_old_tag$opencode_v2_runtime_tx_old_sequence" = '' ] || return 1
    [ "$opencode_v2_runtime_tx_old_contract$opencode_v2_runtime_tx_old_source_commit$opencode_v2_runtime_tx_old_digest" = '' ] || return 1
    [ "$opencode_v2_runtime_tx_old_bundle_digest$opencode_v2_runtime_tx_old_wrapper_digest" = '' ] || return 1
  fi
  case "$opencode_v2_runtime_tx_phase" in
    validated|committing|promoted|rolled-back)
      printf '%s\n' "$opencode_v2_runtime_tx_candidate_bundle_digest" \
        "$opencode_v2_runtime_tx_candidate_wrapper_digest" | grep -Eqv '^[a-f0-9]{64}$' && return 1
      ;;
  esac
  return 0
}

opencode_v2_runtime_transaction_context() {
  opencode_v2_runtime_init_paths || return 1
  opencode_v2_runtime_tx_prefix=${PREFIX:-}
  case "$opencode_v2_runtime_tx_prefix" in
    /*) ;;
    *) opencode_v2_runtime_error 'PREFIX debe ser una ruta absoluta para la transacción.'; return 1 ;;
  esac
  opencode_v2_runtime_tx_libexec="$opencode_v2_runtime_tx_prefix/libexec/opencode-v2"
  opencode_v2_runtime_tx_wrapper="$opencode_v2_runtime_tx_prefix/bin/opencode-v2"
  opencode_v2_runtime_tx_manifest="$opencode_v2_runtime_tx_libexec/manifest.txt"
  opencode_v2_runtime_tx_snapshot="$opencode_v2_runtime_recovery/current"
  opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_tx_snapshot/profile"
  opencode_v2_runtime_tx_bundle_backup="$opencode_v2_runtime_tx_snapshot/bundle"
  opencode_v2_runtime_validate_path_ancestors "$opencode_v2_runtime_profile" || return 1
  opencode_v2_runtime_validate_path_ancestors "$opencode_v2_runtime_recovery" || return 1
  opencode_v2_runtime_validate_path_ancestors "$opencode_v2_runtime_tx_libexec" || return 1
  opencode_v2_runtime_validate_path_ancestors "$opencode_v2_runtime_tx_wrapper" || return 1

  [ "${APP_NAME:-}" = opencode-v2 ] &&
    [ "${LIBEXEC_DIR:-}" = "$opencode_v2_runtime_tx_libexec" ] &&
    [ "${WRAPPER:-}" = "$opencode_v2_runtime_tx_wrapper" ] &&
    [ "${MANIFEST:-}" = "$opencode_v2_runtime_tx_manifest" ] || {
      opencode_v2_runtime_error 'El contexto del instalador no corresponde a opencode-v2.'
      return 1
    }
  printf '%s\n' "${VERSION:-}" | grep -Eq '^2\.[0-9]+\.[0-9]+([+]android[0-9]+)?$' || return 1
  printf '%s\n' "${TAG:-}" | grep -Eq '^v?2\.[0-9]+\.[0-9]+([+]android[0-9]+)?$' || return 1
  printf '%s\n' "${TARBALL_CHECKSUM:-}" | grep -Eq '^[a-f0-9]{64}$' || return 1
  printf '%s\n' "${CATALOG_SEQUENCE:-}" | grep -Eq '^[1-9][0-9]*$' || return 1
  [ "${CATALOG_CONTRACT:-}" = termux-glibc-1 ] || return 1
  printf '%s\n' "${CATALOG_SOURCE_COMMIT:-}" | grep -Eq '^[a-f0-9]{40}$' || return 1
}

opencode_v2_runtime_transaction_recovery_context() {
  opencode_v2_runtime_init_paths || return 1
  opencode_v2_runtime_tx_prefix=${PREFIX:-}
  case "$opencode_v2_runtime_tx_prefix" in
    /*) ;;
    *) opencode_v2_runtime_error 'PREFIX debe ser una ruta absoluta para recuperar v2.'; return 1 ;;
  esac
  opencode_v2_runtime_tx_libexec="$opencode_v2_runtime_tx_prefix/libexec/opencode-v2"
  opencode_v2_runtime_tx_wrapper="$opencode_v2_runtime_tx_prefix/bin/opencode-v2"
  opencode_v2_runtime_tx_manifest="$opencode_v2_runtime_tx_libexec/manifest.txt"
  opencode_v2_runtime_tx_snapshot="$opencode_v2_runtime_recovery/current"
  opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_tx_snapshot/profile"
  opencode_v2_runtime_tx_bundle_backup="$opencode_v2_runtime_tx_snapshot/bundle"
  opencode_v2_runtime_validate_path_ancestors "$opencode_v2_runtime_recovery" || return 1
  opencode_v2_runtime_validate_path_ancestors "$opencode_v2_runtime_tx_libexec" || return 1
  opencode_v2_runtime_validate_path_ancestors "$opencode_v2_runtime_tx_wrapper" || return 1
}

opencode_v2_runtime_transaction_profile_snapshot() {
  opencode_v2_runtime_tx_had_profile=0
  if [ -e "$opencode_v2_runtime_profile" ] || [ -L "$opencode_v2_runtime_profile" ]; then
    [ -d "$opencode_v2_runtime_profile" ] && [ ! -L "$opencode_v2_runtime_profile" ] || return 1
    opencode_v2_runtime_tx_had_profile=1
    if find "$opencode_v2_runtime_profile" -type l -print -quit | grep -q .; then
      opencode_v2_runtime_error 'El perfil contiene symlinks; la transacción no lo modificará.'
      return 1
    fi
    opencode_v2_runtime_profile_unknown=$(find "$opencode_v2_runtime_profile" -mindepth 1 -maxdepth 1 \
      ! -name config ! -name data ! -name cache ! -name state ! -name log ! -name tmp -print -quit)
    [ -z "$opencode_v2_runtime_profile_unknown" ] || {
      opencode_v2_runtime_error 'El perfil contiene una ruta no reconocida; la transacción no lo modificará.'
      return 1
    }
  fi

  mkdir -p "$opencode_v2_runtime_tx_profile_snapshot" || return 1
  for opencode_v2_runtime_directory in config data state; do
    if [ -e "$opencode_v2_runtime_profile/$opencode_v2_runtime_directory" ] ||
       [ -L "$opencode_v2_runtime_profile/$opencode_v2_runtime_directory" ]; then
      [ -d "$opencode_v2_runtime_profile/$opencode_v2_runtime_directory" ] &&
        [ ! -L "$opencode_v2_runtime_profile/$opencode_v2_runtime_directory" ] || return 1
      cp -a "$opencode_v2_runtime_profile/$opencode_v2_runtime_directory" \
        "$opencode_v2_runtime_tx_profile_snapshot/" || return 1
    fi
  done
  opencode_v2_runtime_tx_profile_digest=$(opencode_v2_runtime_transaction_tree_digest \
    "$opencode_v2_runtime_tx_profile_snapshot") || return 1
}

opencode_v2_runtime_transaction_check_space() {
  [ -n "${TMP_FILE:-}" ] && [ -f "$TMP_FILE" ] && [ ! -L "$TMP_FILE" ] || return 1
  command -v gzip >/dev/null 2>&1 && command -v df >/dev/null 2>&1 &&
    command -v du >/dev/null 2>&1 || return 1
  opencode_v2_runtime_archive_bytes=$(gzip -l "$TMP_FILE" 2>/dev/null |
    awk 'NR == 2 { print $2 }')
  printf '%s\n' "$opencode_v2_runtime_archive_bytes" | grep -Eq '^[0-9]+$' || return 1
  opencode_v2_runtime_candidate_kb=$(((opencode_v2_runtime_archive_bytes + 1023) / 1024))

  opencode_v2_runtime_profile_kb=0
  for opencode_v2_runtime_directory in config data state; do
    opencode_v2_runtime_profile_path="$opencode_v2_runtime_profile/$opencode_v2_runtime_directory"
    if [ -d "$opencode_v2_runtime_profile_path" ]; then
      opencode_v2_runtime_directory_kb=$(du -sk "$opencode_v2_runtime_profile_path" |
        awk 'NR == 1 { print $1 }')
      printf '%s\n' "$opencode_v2_runtime_directory_kb" | grep -Eq '^[0-9]+$' || return 1
      opencode_v2_runtime_profile_kb=$((opencode_v2_runtime_profile_kb + opencode_v2_runtime_directory_kb))
    fi
  done
  opencode_v2_runtime_bundle_kb=0
  if [ -d "$opencode_v2_runtime_tx_libexec" ]; then
    opencode_v2_runtime_bundle_kb=$(du -sk "$opencode_v2_runtime_tx_libexec" | awk 'NR == 1 { print $1 }')
    printf '%s\n' "$opencode_v2_runtime_bundle_kb" | grep -Eq '^[0-9]+$' || return 1
  fi

  opencode_v2_runtime_recovery_device=$(df -Pk "$opencode_v2_runtime_recovery" |
    awk 'NR == 2 { print $1 }')
  opencode_v2_runtime_prefix_device=$(df -Pk "$opencode_v2_runtime_tx_prefix" |
    awk 'NR == 2 { print $1 }')
  opencode_v2_runtime_tmp_dir=${TMPDIR:-$opencode_v2_runtime_tx_prefix/tmp}
  [ -d "$opencode_v2_runtime_tmp_dir" ] || return 1
  opencode_v2_runtime_tmp_device=$(df -Pk "$opencode_v2_runtime_tmp_dir" |
    awk 'NR == 2 { print $1 }')
  [ -n "$opencode_v2_runtime_recovery_device" ] &&
    [ -n "$opencode_v2_runtime_prefix_device" ] &&
    [ -n "$opencode_v2_runtime_tmp_device" ] || return 1

  opencode_v2_runtime_recovery_need=$opencode_v2_runtime_profile_kb
  if [ "$opencode_v2_runtime_recovery_device" != "$opencode_v2_runtime_prefix_device" ]; then
    opencode_v2_runtime_recovery_need=$((opencode_v2_runtime_recovery_need + opencode_v2_runtime_bundle_kb))
  fi
  opencode_v2_runtime_prefix_need=$opencode_v2_runtime_candidate_kb
  opencode_v2_runtime_tmp_need=$opencode_v2_runtime_candidate_kb
  if [ "$opencode_v2_runtime_prefix_device" = "$opencode_v2_runtime_tmp_device" ]; then
    opencode_v2_runtime_prefix_need=$((opencode_v2_runtime_candidate_kb * 2))
    opencode_v2_runtime_tmp_need=0
  fi
  if [ "$opencode_v2_runtime_recovery_device" = "$opencode_v2_runtime_prefix_device" ]; then
    opencode_v2_runtime_recovery_need=$((opencode_v2_runtime_recovery_need + opencode_v2_runtime_prefix_need))
  fi
  if [ "$opencode_v2_runtime_recovery_device" = "$opencode_v2_runtime_tmp_device" ] &&
     [ "$opencode_v2_runtime_prefix_device" != "$opencode_v2_runtime_tmp_device" ]; then
    opencode_v2_runtime_recovery_need=$((opencode_v2_runtime_recovery_need + opencode_v2_runtime_tmp_need))
  fi

  opencode_v2_runtime_recovery_available=$(df -Pk "$opencode_v2_runtime_recovery" |
    awk 'NR == 2 { print $4 }')
  opencode_v2_runtime_prefix_available=$(df -Pk "$opencode_v2_runtime_tx_prefix" |
    awk 'NR == 2 { print $4 }')
  opencode_v2_runtime_tmp_available=$(df -Pk "$opencode_v2_runtime_tmp_dir" |
    awk 'NR == 2 { print $4 }')
  printf '%s\n' "$opencode_v2_runtime_recovery_available" "$opencode_v2_runtime_prefix_available" \
    "$opencode_v2_runtime_tmp_available" | grep -Eqv '^[0-9]+$' && return 1
  [ "$opencode_v2_runtime_recovery_available" -ge "$((opencode_v2_runtime_recovery_need + 1024))" ] || return 1
  if [ "$opencode_v2_runtime_prefix_device" != "$opencode_v2_runtime_recovery_device" ]; then
    [ "$opencode_v2_runtime_prefix_available" -ge "$((opencode_v2_runtime_prefix_need + 1024))" ] || return 1
  fi
  if [ "$opencode_v2_runtime_tmp_device" != "$opencode_v2_runtime_recovery_device" ] &&
     [ "$opencode_v2_runtime_tmp_device" != "$opencode_v2_runtime_prefix_device" ]; then
    [ "$opencode_v2_runtime_tmp_available" -ge "$((opencode_v2_runtime_tmp_need + 1024))" ] || return 1
  fi
}

opencode_v2_runtime_transaction_prepare_cleanup() {
  [ ! -L "$opencode_v2_runtime_tx_snapshot" ] && [ -d "$opencode_v2_runtime_tx_snapshot" ] &&
    rm -rf "$opencode_v2_runtime_tx_snapshot"
  opencode_v2_runtime_release_run_lock
}

opencode_v2_runtime_transaction_prepare() {
  opencode_v2_runtime_transaction_context || return 1
  [ ! -e "$opencode_v2_runtime_journal" ] && [ ! -L "$opencode_v2_runtime_journal" ] || {
    opencode_v2_runtime_error 'Hay una transacción previa sin recuperar; no se iniciará otra.'
    return 1
  }
  opencode_v2_runtime_acquire_run_lock || return 1
  if [ -e "$opencode_v2_runtime_recovery/previous.old" ] ||
     [ -L "$opencode_v2_runtime_recovery/previous.old" ]; then
    opencode_v2_runtime_error 'Hay un respaldo anterior sin rotación completada; revisá status antes de continuar.'
    opencode_v2_runtime_release_run_lock
    return 1
  fi
  if [ -e "$opencode_v2_runtime_tx_snapshot" ] || [ -L "$opencode_v2_runtime_tx_snapshot" ]; then
    opencode_v2_runtime_error 'Hay un snapshot incompleto; revisá status antes de continuar.'
    opencode_v2_runtime_release_run_lock
    return 1
  fi
  opencode_v2_runtime_write_owner transaction "$$" "$opencode_v2_runtime_owner_start" \
    '' '' '' '' '' '' || {
      opencode_v2_runtime_release_run_lock
      return 1
    }

  opencode_v2_runtime_transaction_check_space || {
    opencode_v2_runtime_error 'No hay espacio verificable para el candidato y el respaldo transaccional.'
    opencode_v2_runtime_release_run_lock
    return 1
  }
  if [ -e "$opencode_v2_runtime_recovery/previous" ] ||
     [ -L "$opencode_v2_runtime_recovery/previous" ]; then
    opencode_v2_runtime_transaction_validate_previous || {
      opencode_v2_runtime_error 'El respaldo anterior no coincide con su journal; se conserva para recuperación.'
      opencode_v2_runtime_release_run_lock
      return 1
    }
  fi

  opencode_v2_runtime_tx_had_bundle=0
  opencode_v2_runtime_tx_had_wrapper=0
  opencode_v2_runtime_tx_old_version=''
  opencode_v2_runtime_tx_restore_from_previous=false
  opencode_v2_runtime_tx_old_tag=''
  opencode_v2_runtime_tx_old_sequence=''
  opencode_v2_runtime_tx_old_contract=''
  opencode_v2_runtime_tx_old_source_commit=''
  opencode_v2_runtime_tx_old_digest=''
  opencode_v2_runtime_tx_old_bundle_digest=''
  opencode_v2_runtime_tx_old_wrapper_digest=''
  opencode_v2_runtime_tx_profile_digest=''
  opencode_v2_runtime_tx_candidate_version="$VERSION"
  opencode_v2_runtime_tx_candidate_tag="$TAG"
  opencode_v2_runtime_tx_candidate_sequence="$CATALOG_SEQUENCE"
  opencode_v2_runtime_tx_candidate_contract="$CATALOG_CONTRACT"
  opencode_v2_runtime_tx_candidate_source_commit="$CATALOG_SOURCE_COMMIT"
  opencode_v2_runtime_tx_candidate_digest="$TARBALL_CHECKSUM"
  opencode_v2_runtime_tx_candidate_bundle_digest=''
  opencode_v2_runtime_tx_candidate_wrapper_digest=''

  if [ -e "$opencode_v2_runtime_tx_libexec" ] || [ -L "$opencode_v2_runtime_tx_libexec" ]; then
    [ -d "$opencode_v2_runtime_tx_libexec" ] && [ ! -L "$opencode_v2_runtime_tx_libexec" ] &&
      [ -f "$opencode_v2_runtime_tx_manifest" ] && [ ! -L "$opencode_v2_runtime_tx_manifest" ] || {
        opencode_v2_runtime_error 'El bundle anterior no tiene un manifest regular; se conserva intacto.'
        opencode_v2_runtime_tx_had_bundle=0
        opencode_v2_runtime_transaction_prepare_cleanup
        return 1
      }
    opencode_v2_runtime_tx_old_app=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_tx_manifest" app)
    opencode_v2_runtime_tx_old_version=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_tx_manifest" version)
    opencode_v2_runtime_tx_old_tag=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_tx_manifest" tag)
    opencode_v2_runtime_tx_old_sequence=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_tx_manifest" release_sequence)
    opencode_v2_runtime_tx_old_contract=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_tx_manifest" release_contract)
    opencode_v2_runtime_tx_old_source_commit=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_tx_manifest" release_source_commit)
    opencode_v2_runtime_tx_old_digest=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_tx_manifest" tarball_checksum)
    [ "$opencode_v2_runtime_tx_old_app" = opencode-v2 ] &&
      [ -f "$opencode_v2_runtime_tx_wrapper" ] && [ -x "$opencode_v2_runtime_tx_wrapper" ] &&
      [ ! -L "$opencode_v2_runtime_tx_wrapper" ] || {
        opencode_v2_runtime_error 'El bundle o wrapper anterior no pertenece a una instalación verificable de v2.'
        opencode_v2_runtime_tx_had_bundle=0
        opencode_v2_runtime_transaction_prepare_cleanup
        return 1
      }
    opencode_v2_runtime_transaction_verify_bundle "$opencode_v2_runtime_tx_libexec" || {
      opencode_v2_runtime_error 'El bundle anterior no coincide con sus hashes del manifest.'
      opencode_v2_runtime_tx_had_bundle=0
      opencode_v2_runtime_transaction_prepare_cleanup
      return 1
    }
    opencode_v2_runtime_transaction_verify_wrapper "$opencode_v2_runtime_tx_wrapper" \
      "$opencode_v2_runtime_tx_libexec" "$opencode_v2_runtime_tx_libexec" || {
        opencode_v2_runtime_error 'El wrapper anterior no apunta al bundle y runner registrados.'
        opencode_v2_runtime_tx_had_bundle=0
        opencode_v2_runtime_transaction_prepare_cleanup
        return 1
      }
    printf '%s\n' "$opencode_v2_runtime_tx_old_tag" |
      grep -Eq '^v?2\.[0-9]+\.[0-9]+([+]android[0-9]+)?$' || {
        opencode_v2_runtime_transaction_prepare_cleanup
        return 1
      }
    printf '%s\n' "$opencode_v2_runtime_tx_old_sequence" | grep -Eq '^[1-9][0-9]*$' || {
      opencode_v2_runtime_transaction_prepare_cleanup
      return 1
    }
    [ "$opencode_v2_runtime_tx_old_contract" = termux-glibc-1 ] || {
      opencode_v2_runtime_transaction_prepare_cleanup
      return 1
    }
    printf '%s\n' "$opencode_v2_runtime_tx_old_source_commit" | grep -Eq '^[a-f0-9]{40}$' || {
      opencode_v2_runtime_transaction_prepare_cleanup
      return 1
    }
    printf '%s\n' "$opencode_v2_runtime_tx_old_digest" | grep -Eq '^[a-f0-9]{64}$' || {
      opencode_v2_runtime_transaction_prepare_cleanup
      return 1
    }
    opencode_v2_runtime_tx_old_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
      "$opencode_v2_runtime_tx_libexec") || {
        opencode_v2_runtime_transaction_prepare_cleanup
        return 1
      }
    opencode_v2_runtime_tx_old_wrapper_digest=$(sha256sum "$opencode_v2_runtime_tx_wrapper" |
      awk '{ print $1 }') || {
        opencode_v2_runtime_transaction_prepare_cleanup
        return 1
      }
    opencode_v2_runtime_tx_had_bundle=1
    opencode_v2_runtime_tx_had_wrapper=1
  elif [ -e "$opencode_v2_runtime_tx_wrapper" ] || [ -L "$opencode_v2_runtime_tx_wrapper" ]; then
    opencode_v2_runtime_error 'Hay un wrapper sin bundle administrado; no se sobrescribirá.'
    opencode_v2_runtime_transaction_prepare_cleanup
    return 1
  fi

  if ! opencode_v2_runtime_transaction_profile_snapshot; then
    opencode_v2_runtime_error 'No se pudo respaldar el perfil v2 de forma consistente.'
    opencode_v2_runtime_transaction_prepare_cleanup
    return 1
  fi

  if [ -e "$opencode_v2_runtime_recovery/previous" ] || [ -L "$opencode_v2_runtime_recovery/previous" ]; then
    [ -d "$opencode_v2_runtime_recovery/previous" ] && [ ! -L "$opencode_v2_runtime_recovery/previous" ] || {
      opencode_v2_runtime_transaction_prepare_cleanup
      return 1
    }
  fi
  if ! opencode_v2_runtime_transaction_write_journal prepared; then
    if [ ! -e "$opencode_v2_runtime_journal" ]; then
      opencode_v2_runtime_transaction_prepare_cleanup
    else
      opencode_v2_runtime_error 'El journal quedó escrito pero sync falló; se conserva el estado para rollback explícito.'
    fi
    return 1
  fi
  # shellcheck disable=SC2034
  BACKUP_DIR="$opencode_v2_runtime_tx_bundle_backup"
}

opencode_v2_runtime_transaction_validate() {
  opencode_v2_runtime_transaction_context || return 1
  opencode_v2_runtime_transaction_load_journal || {
    opencode_v2_runtime_error 'El journal transaccional está ausente o no es válido.'
    return 1
  }
  [ "$opencode_v2_runtime_tx_phase" = prepared ] &&
    [ "$opencode_v2_runtime_tx_candidate_tag" = "$TAG" ] &&
    [ "$opencode_v2_runtime_tx_candidate_digest" = "$TARBALL_CHECKSUM" ] || return 1
  [ -d "$opencode_v2_runtime_tx_libexec" ] && [ ! -L "$opencode_v2_runtime_tx_libexec" ] &&
    [ -f "$opencode_v2_runtime_tx_manifest" ] && [ ! -L "$opencode_v2_runtime_tx_manifest" ] &&
    [ -f "$opencode_v2_runtime_tx_wrapper" ] && [ -x "$opencode_v2_runtime_tx_wrapper" ] &&
    [ ! -L "$opencode_v2_runtime_tx_wrapper" ] || return 1
  opencode_v2_runtime_candidate_app=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_tx_manifest" app)
  opencode_v2_runtime_candidate_version=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_tx_manifest" version)
  opencode_v2_runtime_candidate_tag=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_tx_manifest" tag)
  opencode_v2_runtime_candidate_sequence=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_tx_manifest" release_sequence)
  opencode_v2_runtime_candidate_contract=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_tx_manifest" release_contract)
  opencode_v2_runtime_candidate_source_commit=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_tx_manifest" release_source_commit)
  opencode_v2_runtime_candidate_digest=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_tx_manifest" tarball_checksum)
  [ "$opencode_v2_runtime_candidate_app" = opencode-v2 ] &&
    [ "$opencode_v2_runtime_candidate_version" = "$VERSION" ] &&
    [ "$opencode_v2_runtime_candidate_tag" = "$TAG" ] &&
    [ "$opencode_v2_runtime_candidate_sequence" = "$CATALOG_SEQUENCE" ] &&
    [ "$opencode_v2_runtime_candidate_contract" = "$CATALOG_CONTRACT" ] &&
    [ "$opencode_v2_runtime_candidate_source_commit" = "$CATALOG_SOURCE_COMMIT" ] &&
    [ "$opencode_v2_runtime_candidate_digest" = "$TARBALL_CHECKSUM" ] || return 1
  opencode_v2_runtime_transaction_verify_bundle "$opencode_v2_runtime_tx_libexec" || {
    opencode_v2_runtime_error 'El bundle candidato no coincide con sus hashes del manifest.'
    return 1
  }
  opencode_v2_runtime_transaction_verify_wrapper "$opencode_v2_runtime_tx_wrapper" \
    "$opencode_v2_runtime_tx_libexec" "$opencode_v2_runtime_tx_libexec" || {
      opencode_v2_runtime_error 'El wrapper candidato no apunta al bundle y runner registrados.'
      return 1
    }
  if [ "$opencode_v2_runtime_tx_had_bundle" = 1 ]; then
    opencode_v2_runtime_current_backup_digest=$(opencode_v2_runtime_transaction_bundle_digest \
      "$opencode_v2_runtime_tx_bundle_backup") || return 1
    [ "$opencode_v2_runtime_current_backup_digest" = "$opencode_v2_runtime_tx_old_bundle_digest" ] || return 1
    opencode_v2_runtime_current_wrapper_digest=$(sha256sum \
      "$opencode_v2_runtime_tx_bundle_backup/.wrapper" | awk '{ print $1 }') || return 1
    [ "$opencode_v2_runtime_current_wrapper_digest" = "$opencode_v2_runtime_tx_old_wrapper_digest" ] || return 1
  fi
  if [ -n "${opencode_v2_runtime_project_root:-}" ]; then
    bash "$opencode_v2_runtime_project_root/verify.sh" opencode-v2 || return 1
  else
    opencode_v2_runtime_error 'No se configuró verify.sh para validar el bundle candidato.'
    return 1
  fi
  opencode_v2_runtime_candidate_version_output=$("$opencode_v2_runtime_tx_wrapper" --version 2>&1) || {
    opencode_v2_runtime_error 'El candidato no respondió a --version.'
    return 1
  }
  opencode_v2_runtime_candidate_version_core=$(printf '%s\n' "$opencode_v2_runtime_candidate_version_output" |
    grep -Eo '[0-9]+[.][0-9]+[.][0-9]+' | head -1)
  opencode_v2_runtime_expected_version_core=${VERSION%%+*}
  opencode_v2_runtime_expected_version_core=${opencode_v2_runtime_expected_version_core#v}
  [ "$opencode_v2_runtime_candidate_version_core" = "$opencode_v2_runtime_expected_version_core" ] || {
    opencode_v2_runtime_error 'La versión ejecutada por el wrapper no coincide con el candidato.'
    return 1
  }
  opencode_v2_runtime_tx_candidate_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
    "$opencode_v2_runtime_tx_libexec") || return 1
  opencode_v2_runtime_tx_candidate_wrapper_digest=$(sha256sum \
    "$opencode_v2_runtime_tx_wrapper" | awk '{ print $1 }') || return 1
  opencode_v2_runtime_tx_phase=validated
  opencode_v2_runtime_transaction_write_journal validated
}

opencode_v2_runtime_transaction_restore_profile() {
  [ -d "$opencode_v2_runtime_tx_profile_snapshot" ] &&
    [ ! -L "$opencode_v2_runtime_tx_profile_snapshot" ] || return 1
  opencode_v2_runtime_current_profile_digest=$(opencode_v2_runtime_transaction_tree_digest \
    "$opencode_v2_runtime_tx_profile_snapshot") || return 1
  [ "$opencode_v2_runtime_current_profile_digest" = "$opencode_v2_runtime_tx_profile_digest" ] || return 1
  if [ "$opencode_v2_runtime_tx_had_profile" = 0 ]; then
    if [ -e "$opencode_v2_runtime_profile" ] || [ -L "$opencode_v2_runtime_profile" ]; then
      [ -d "$opencode_v2_runtime_profile" ] && [ ! -L "$opencode_v2_runtime_profile" ] || return 1
      if find "$opencode_v2_runtime_profile" -type l -print -quit | grep -q .; then
        return 1
      fi
      opencode_v2_runtime_profile_unknown=$(find "$opencode_v2_runtime_profile" -mindepth 1 -maxdepth 1 \
        ! -name config ! -name data ! -name cache ! -name state ! -name log ! -name tmp -print -quit)
      [ -z "$opencode_v2_runtime_profile_unknown" ] || return 1
      rm -rf "${opencode_v2_runtime_profile:?}" || return 1
    fi
    return 0
  fi
  if [ -e "$opencode_v2_runtime_profile" ] || [ -L "$opencode_v2_runtime_profile" ]; then
    [ -d "$opencode_v2_runtime_profile" ] && [ ! -L "$opencode_v2_runtime_profile" ] || return 1
    if find "$opencode_v2_runtime_profile" -type l -print -quit | grep -q .; then
      return 1
    fi
    opencode_v2_runtime_profile_unknown=$(find "$opencode_v2_runtime_profile" -mindepth 1 -maxdepth 1 \
      ! -name config ! -name data ! -name cache ! -name state ! -name log ! -name tmp -print -quit)
    [ -z "$opencode_v2_runtime_profile_unknown" ] || return 1
  else
    mkdir -p "$opencode_v2_runtime_profile" || return 1
  fi
  for opencode_v2_runtime_directory in config data state; do
    rm -rf "${opencode_v2_runtime_profile:?}/$opencode_v2_runtime_directory" || return 1
    if [ -d "$opencode_v2_runtime_tx_profile_snapshot/$opencode_v2_runtime_directory" ]; then
      cp -a "$opencode_v2_runtime_tx_profile_snapshot/$opencode_v2_runtime_directory" \
        "$opencode_v2_runtime_profile/" || return 1
    fi
  done
  if [ -e "$opencode_v2_runtime_profile/cache" ] || [ -L "$opencode_v2_runtime_profile/cache" ]; then
    [ ! -L "$opencode_v2_runtime_profile/cache" ] || return 1
    rm -rf "$opencode_v2_runtime_profile/cache" || return 1
  fi
}

opencode_v2_runtime_transaction_current_owner() {
  opencode_v2_runtime_owner_file="$opencode_v2_runtime_lock/owner"
  [ -f "$opencode_v2_runtime_owner_file" ] && [ ! -L "$opencode_v2_runtime_owner_file" ] || return 1
  [ "$(opencode_v2_runtime_owner_value "$opencode_v2_runtime_owner_file" pid)" = "$$" ] || return 1
  opencode_v2_runtime_owner_kind=$(opencode_v2_runtime_owner_value "$opencode_v2_runtime_owner_file" kind)
  case "$opencode_v2_runtime_owner_kind" in
    transaction|recovery) ;;
    *) return 1 ;;
  esac
  opencode_v2_runtime_owner_start=$(opencode_v2_runtime_owner_value "$opencode_v2_runtime_owner_file" start_time)
  opencode_v2_runtime_process_matches "$$" "$opencode_v2_runtime_owner_start"
}

opencode_v2_runtime_recovery_stop_recorded_child() {
  opencode_v2_runtime_recorded_pid=$(opencode_v2_runtime_owner_value "$1" "$2")
  opencode_v2_runtime_recorded_start=$(opencode_v2_runtime_owner_value "$1" "$3")
  [ -n "$opencode_v2_runtime_recorded_pid" ] || return 0
  printf '%s\n' "$opencode_v2_runtime_recorded_pid" "$opencode_v2_runtime_recorded_start" |
    grep -Eqv '^[0-9]+$' && return 1
  if opencode_v2_runtime_process_matches "$opencode_v2_runtime_recorded_pid" \
    "$opencode_v2_runtime_recorded_start"; then
    opencode_v2_runtime_stop_child "$opencode_v2_runtime_recorded_pid" \
      "$opencode_v2_runtime_recorded_start"
  fi
}

opencode_v2_runtime_recovery_acquire_lock() {
  umask 077
  opencode_v2_runtime_create_private_dir "$opencode_v2_runtime_recovery" || return 1
  if [ -L "$opencode_v2_runtime_lock" ]; then
    opencode_v2_runtime_error 'El lock es un symlink; no se recuperará.'
    return 1
  fi
  opencode_v2_runtime_recovery_new_lock=false
  if [ -e "$opencode_v2_runtime_lock" ]; then
    [ -d "$opencode_v2_runtime_lock" ] || return 1
    opencode_v2_runtime_stale_owner="$opencode_v2_runtime_lock/owner"
    [ -f "$opencode_v2_runtime_stale_owner" ] && [ ! -L "$opencode_v2_runtime_stale_owner" ] || {
      opencode_v2_runtime_error 'El lock no tiene identidad verificable; no se recuperará automáticamente.'
      return 1
    }
    [ "$(opencode_v2_runtime_owner_value "$opencode_v2_runtime_stale_owner" schema)" = 1 ] || return 1
    case "$(opencode_v2_runtime_owner_value "$opencode_v2_runtime_stale_owner" kind)" in
      run|transaction|recovery) ;;
      *) return 1 ;;
    esac
    opencode_v2_runtime_stale_pid=$(opencode_v2_runtime_owner_value \
      "$opencode_v2_runtime_stale_owner" pid)
    opencode_v2_runtime_stale_start=$(opencode_v2_runtime_owner_value \
      "$opencode_v2_runtime_stale_owner" start_time)
    printf '%s\n' "$opencode_v2_runtime_stale_pid" "$opencode_v2_runtime_stale_start" |
      grep -Eqv '^[0-9]+$' && return 1
    if opencode_v2_runtime_process_matches "$opencode_v2_runtime_stale_pid" \
      "$opencode_v2_runtime_stale_start"; then
      opencode_v2_runtime_error 'OpenCode v2 mantiene una ejecución u operación activa.'
      return 1
    fi
    if ! mkdir "$opencode_v2_runtime_lock/recover" 2>/dev/null; then
      opencode_v2_runtime_error 'Otro proceso está recuperando el lock de OpenCode v2.'
      return 1
    fi
    if ! opencode_v2_runtime_recovery_stop_recorded_child "$opencode_v2_runtime_stale_owner" \
      server_pid server_start_time ||
      ! opencode_v2_runtime_recovery_stop_recorded_child "$opencode_v2_runtime_stale_owner" \
        reader_pid reader_start_time ||
      ! opencode_v2_runtime_recovery_stop_recorded_child "$opencode_v2_runtime_stale_owner" \
        client_pid client_start_time; then
      rmdir "$opencode_v2_runtime_lock/recover" 2>/dev/null || true
      return 1
    fi
  else
    if ! mkdir "$opencode_v2_runtime_lock" 2>/dev/null; then
      opencode_v2_runtime_error 'OpenCode v2 adquirió el lock antes de la recuperación.'
      return 1
    fi
    opencode_v2_runtime_recovery_new_lock=true
    chmod 700 "$opencode_v2_runtime_lock" || {
      rmdir "$opencode_v2_runtime_lock" 2>/dev/null || true
      return 1
    }
  fi
  opencode_v2_runtime_owner_start=$(opencode_v2_runtime_proc_start_time "$$")
  case "$opencode_v2_runtime_owner_start" in
    ''|*[!0-9]*)
      [ "$opencode_v2_runtime_recovery_new_lock" = true ] &&
        rmdir "$opencode_v2_runtime_lock" 2>/dev/null || true
      return 1
      ;;
  esac
  opencode_v2_runtime_write_owner recovery "$$" "$opencode_v2_runtime_owner_start" \
    '' '' '' '' '' '' || {
      if [ "$opencode_v2_runtime_recovery_new_lock" = true ]; then
        rmdir "$opencode_v2_runtime_lock" 2>/dev/null || true
      else
        rmdir "$opencode_v2_runtime_lock/recover" 2>/dev/null || true
      fi
      return 1
    }
}

opencode_v2_runtime_manual_write_journal() {
  opencode_v2_runtime_manual_journal_tmp=$(mktemp "$opencode_v2_runtime_recovery/.journal.XXXXXX") || return 1
  chmod 600 "$opencode_v2_runtime_manual_journal_tmp" || {
    rm -f "$opencode_v2_runtime_manual_journal_tmp"
    return 1
  }
  if ! cat > "$opencode_v2_runtime_manual_journal_tmp" <<EOF
schema=1
operation=manual-rollback
phase=$1
previous_tag=$opencode_v2_runtime_manual_previous_tag
previous_contract=$opencode_v2_runtime_manual_previous_contract
previous_bundle_digest=$opencode_v2_runtime_manual_previous_bundle_digest
previous_wrapper_digest=$opencode_v2_runtime_manual_previous_wrapper_digest
previous_profile_digest=$opencode_v2_runtime_manual_previous_profile_digest
previous_had_profile=$opencode_v2_runtime_manual_previous_had_profile
current_tag=$opencode_v2_runtime_manual_current_tag
current_contract=$opencode_v2_runtime_manual_current_contract
current_bundle_digest=$opencode_v2_runtime_manual_current_bundle_digest
current_wrapper_digest=$opencode_v2_runtime_manual_current_wrapper_digest
current_profile_digest=$opencode_v2_runtime_manual_current_profile_digest
current_had_profile=$opencode_v2_runtime_manual_current_had_profile
EOF
  then
    rm -f "$opencode_v2_runtime_manual_journal_tmp"
    return 1
  fi
  mv -f "$opencode_v2_runtime_manual_journal_tmp" "$opencode_v2_runtime_journal" || {
    rm -f "$opencode_v2_runtime_manual_journal_tmp"
    return 1
  }
  sync
}

opencode_v2_runtime_manual_load_journal() {
  [ -f "$opencode_v2_runtime_journal" ] && [ ! -L "$opencode_v2_runtime_journal" ] || return 1
  opencode_v2_runtime_transaction_key_file_valid "$opencode_v2_runtime_journal" 15 || return 1
  [ "$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal" schema)" = 1 ] &&
    [ "$(opencode_v2_runtime_transaction_value "$opencode_v2_runtime_journal" operation)" = manual-rollback ] || return 1
  opencode_v2_runtime_manual_phase=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" phase)
  case "$opencode_v2_runtime_manual_phase" in
    manual-prepared|manual-restoring|manual-restored) ;;
    *) return 1 ;;
  esac
  opencode_v2_runtime_manual_previous_tag=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" previous_tag)
  opencode_v2_runtime_manual_previous_contract=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" previous_contract)
  opencode_v2_runtime_manual_previous_bundle_digest=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" previous_bundle_digest)
  opencode_v2_runtime_manual_previous_wrapper_digest=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" previous_wrapper_digest)
  opencode_v2_runtime_manual_previous_profile_digest=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" previous_profile_digest)
  opencode_v2_runtime_manual_previous_had_profile=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" previous_had_profile)
  opencode_v2_runtime_manual_current_tag=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" current_tag)
  opencode_v2_runtime_manual_current_contract=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" current_contract)
  opencode_v2_runtime_manual_current_bundle_digest=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" current_bundle_digest)
  opencode_v2_runtime_manual_current_wrapper_digest=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" current_wrapper_digest)
  opencode_v2_runtime_manual_current_profile_digest=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" current_profile_digest)
  opencode_v2_runtime_manual_current_had_profile=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" current_had_profile)
  printf '%s\n' "$opencode_v2_runtime_manual_previous_tag" "$opencode_v2_runtime_manual_current_tag" |
    grep -Eqv '^v?2\.[0-9]+\.[0-9]+([+]android[0-9]+)?$' && return 1
  [ "$opencode_v2_runtime_manual_previous_contract" = termux-glibc-1 ] &&
    [ "$opencode_v2_runtime_manual_current_contract" = termux-glibc-1 ] || return 1
  printf '%s\n' "$opencode_v2_runtime_manual_previous_bundle_digest" \
    "$opencode_v2_runtime_manual_previous_wrapper_digest" \
    "$opencode_v2_runtime_manual_previous_profile_digest" \
    "$opencode_v2_runtime_manual_current_bundle_digest" \
    "$opencode_v2_runtime_manual_current_wrapper_digest" \
    "$opencode_v2_runtime_manual_current_profile_digest" | grep -Eqv '^[a-f0-9]{64}$' && return 1
  case "$opencode_v2_runtime_manual_previous_had_profile:$opencode_v2_runtime_manual_current_had_profile" in
    0:0|0:1|1:0|1:1) ;;
    *) return 1 ;;
  esac
}

opencode_v2_runtime_manual_rollback_begin() {
  opencode_v2_runtime_transaction_recovery_context || return 1
  opencode_v2_runtime_manual_previous="$opencode_v2_runtime_recovery/previous"
  opencode_v2_runtime_manual_dir="$opencode_v2_runtime_recovery/manual"
  opencode_v2_runtime_manual_displaced="$opencode_v2_runtime_recovery/displaced"
  opencode_v2_runtime_manual_bundle_stage="$opencode_v2_runtime_tx_prefix/libexec/.opencode-v2-restore"
  opencode_v2_runtime_manual_wrapper_stage="$opencode_v2_runtime_tx_prefix/bin/.opencode-v2-restore"
  [ -d "$opencode_v2_runtime_manual_previous" ] &&
    [ ! -L "$opencode_v2_runtime_manual_previous" ] || return 1
  [ ! -e "$opencode_v2_runtime_manual_dir" ] && [ ! -L "$opencode_v2_runtime_manual_dir" ] &&
    [ ! -e "$opencode_v2_runtime_manual_displaced" ] && [ ! -L "$opencode_v2_runtime_manual_displaced" ] &&
    [ ! -e "$opencode_v2_runtime_manual_bundle_stage" ] && [ ! -L "$opencode_v2_runtime_manual_bundle_stage" ] &&
    [ ! -e "$opencode_v2_runtime_manual_wrapper_stage" ] && [ ! -L "$opencode_v2_runtime_manual_wrapper_stage" ] || {
      opencode_v2_runtime_error 'Hay un destino de recuperación existente; no se sobrescribirá.'
      return 1
    }
  opencode_v2_runtime_transaction_load_journal "$opencode_v2_runtime_manual_previous/transaction.txt" || return 1
  [ "$opencode_v2_runtime_tx_phase" = committing ] &&
    [ "$opencode_v2_runtime_tx_had_bundle" = 1 ] &&
    [ "$opencode_v2_runtime_tx_had_wrapper" = 1 ] || return 1
  opencode_v2_runtime_manual_previous_tag="$opencode_v2_runtime_tx_old_tag"
  opencode_v2_runtime_manual_previous_contract="$opencode_v2_runtime_tx_old_contract"
  opencode_v2_runtime_manual_previous_bundle_digest="$opencode_v2_runtime_tx_old_bundle_digest"
  opencode_v2_runtime_manual_previous_wrapper_digest="$opencode_v2_runtime_tx_old_wrapper_digest"
  opencode_v2_runtime_manual_previous_profile_digest="$opencode_v2_runtime_tx_profile_digest"
  opencode_v2_runtime_manual_previous_had_profile="$opencode_v2_runtime_tx_had_profile"
  opencode_v2_runtime_manual_current_tag="$opencode_v2_runtime_tx_candidate_tag"
  opencode_v2_runtime_manual_current_contract="$opencode_v2_runtime_tx_candidate_contract"
  opencode_v2_runtime_manual_current_bundle_digest="$opencode_v2_runtime_tx_candidate_bundle_digest"
  opencode_v2_runtime_manual_current_wrapper_digest="$opencode_v2_runtime_tx_candidate_wrapper_digest"

  opencode_v2_runtime_previous_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
    "$opencode_v2_runtime_manual_previous/bundle") || return 1
  [ "$opencode_v2_runtime_previous_bundle_digest" = "$opencode_v2_runtime_manual_previous_bundle_digest" ] || return 1
  opencode_v2_runtime_previous_wrapper_digest=$(sha256sum \
    "$opencode_v2_runtime_manual_previous/bundle/.wrapper" | awk '{ print $1 }') || return 1
  [ "$opencode_v2_runtime_previous_wrapper_digest" = "$opencode_v2_runtime_manual_previous_wrapper_digest" ] || return 1
  opencode_v2_runtime_previous_profile_digest=$(opencode_v2_runtime_transaction_tree_digest \
    "$opencode_v2_runtime_manual_previous/profile") || return 1
  [ "$opencode_v2_runtime_previous_profile_digest" = "$opencode_v2_runtime_manual_previous_profile_digest" ] || return 1
  opencode_v2_runtime_transaction_verify_bundle "$opencode_v2_runtime_tx_libexec" || return 1
  opencode_v2_runtime_current_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
    "$opencode_v2_runtime_tx_libexec") || return 1
  [ "$opencode_v2_runtime_current_bundle_digest" = "$opencode_v2_runtime_manual_current_bundle_digest" ] || return 1
  opencode_v2_runtime_current_wrapper_digest=$(sha256sum "$opencode_v2_runtime_tx_wrapper" |
    awk '{ print $1 }') || return 1
  [ "$opencode_v2_runtime_current_wrapper_digest" = "$opencode_v2_runtime_manual_current_wrapper_digest" ] || return 1

  opencode_v2_runtime_tx_snapshot="$opencode_v2_runtime_manual_dir"
  opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_tx_snapshot/profile"
  opencode_v2_runtime_transaction_profile_snapshot || return 1
  opencode_v2_runtime_manual_current_had_profile="$opencode_v2_runtime_tx_had_profile"
  opencode_v2_runtime_manual_current_profile_digest="$opencode_v2_runtime_tx_profile_digest"
  opencode_v2_runtime_live_profile_digest=$(opencode_v2_runtime_transaction_active_profile_digest) || return 1
  [ "$opencode_v2_runtime_live_profile_digest" = "$opencode_v2_runtime_manual_current_profile_digest" ] || return 1
  opencode_v2_runtime_manual_write_journal manual-prepared || return 1
  opencode_v2_runtime_manual_phase=manual-prepared
  opencode_v2_runtime_manual_rollback_continue
}

opencode_v2_runtime_manual_rollback_continue() {
  opencode_v2_runtime_manual_load_journal || {
    opencode_v2_runtime_error 'El journal de rollback manual no es válido.'
    return 1
  }
  opencode_v2_runtime_manual_dir="$opencode_v2_runtime_recovery/manual"
  opencode_v2_runtime_manual_profile="$opencode_v2_runtime_manual_dir/profile"
  opencode_v2_runtime_manual_displaced="$opencode_v2_runtime_recovery/displaced"
  opencode_v2_runtime_manual_bundle_stage="$opencode_v2_runtime_tx_prefix/libexec/.opencode-v2-restore"
  opencode_v2_runtime_manual_wrapper_stage="$opencode_v2_runtime_tx_prefix/bin/.opencode-v2-restore"
  opencode_v2_runtime_manual_previous="$opencode_v2_runtime_recovery/previous"

  if [ "$opencode_v2_runtime_manual_phase" = manual-prepared ]; then
    [ -d "$opencode_v2_runtime_manual_profile" ] && [ ! -L "$opencode_v2_runtime_manual_profile" ] || return 1
    opencode_v2_runtime_manual_snapshot_digest=$(opencode_v2_runtime_transaction_tree_digest \
      "$opencode_v2_runtime_manual_profile") || return 1
    [ "$opencode_v2_runtime_manual_snapshot_digest" = "$opencode_v2_runtime_manual_current_profile_digest" ] || return 1
    opencode_v2_runtime_manual_live_profile_digest=$(opencode_v2_runtime_transaction_active_profile_digest) || return 1
    [ "$opencode_v2_runtime_manual_live_profile_digest" = "$opencode_v2_runtime_manual_current_profile_digest" ] || return 1
    opencode_v2_runtime_manual_live_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
      "$opencode_v2_runtime_tx_libexec") || return 1
    [ "$opencode_v2_runtime_manual_live_bundle_digest" = "$opencode_v2_runtime_manual_current_bundle_digest" ] || return 1
    opencode_v2_runtime_manual_live_wrapper_digest=$(sha256sum "$opencode_v2_runtime_tx_wrapper" |
      awk '{ print $1 }') || return 1
    [ "$opencode_v2_runtime_manual_live_wrapper_digest" = "$opencode_v2_runtime_manual_current_wrapper_digest" ] || return 1
    opencode_v2_runtime_manual_write_journal manual-restoring || return 1
    opencode_v2_runtime_manual_phase=manual-restoring
  fi

  if [ "$opencode_v2_runtime_manual_phase" = manual-restoring ]; then
    if [ "$opencode_v2_runtime_manual_current_had_profile" = 1 ]; then
      if [ -d "$opencode_v2_runtime_manual_displaced/profile" ]; then
        opencode_v2_runtime_manual_displaced_digest=$(opencode_v2_runtime_transaction_tree_digest \
          "$opencode_v2_runtime_manual_displaced/profile") || return 1
        [ "$opencode_v2_runtime_manual_displaced_digest" = "$opencode_v2_runtime_manual_current_profile_digest" ] || return 1
      else
        [ ! -e "$opencode_v2_runtime_manual_displaced" ] &&
          [ ! -L "$opencode_v2_runtime_manual_displaced" ] || return 1
        opencode_v2_runtime_manual_live_profile_digest=$(opencode_v2_runtime_transaction_active_profile_digest) || return 1
        [ "$opencode_v2_runtime_manual_live_profile_digest" = "$opencode_v2_runtime_manual_current_profile_digest" ] || return 1
        mkdir -m 700 "$opencode_v2_runtime_manual_displaced" || return 1
        mv "$opencode_v2_runtime_manual_profile" "$opencode_v2_runtime_manual_displaced/profile" || return 1
      fi
    fi

    if [ -d "$opencode_v2_runtime_manual_previous/bundle" ]; then
      opencode_v2_runtime_previous_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
        "$opencode_v2_runtime_manual_previous/bundle") || return 1
      [ "$opencode_v2_runtime_previous_bundle_digest" = "$opencode_v2_runtime_manual_previous_bundle_digest" ] || return 1
      opencode_v2_runtime_previous_wrapper_digest=$(sha256sum \
        "$opencode_v2_runtime_manual_previous/bundle/.wrapper" | awk '{ print $1 }') || return 1
      [ "$opencode_v2_runtime_previous_wrapper_digest" = "$opencode_v2_runtime_manual_previous_wrapper_digest" ] || return 1
      opencode_v2_runtime_previous_profile_digest=$(opencode_v2_runtime_transaction_tree_digest \
        "$opencode_v2_runtime_manual_previous/profile") || return 1
      [ "$opencode_v2_runtime_previous_profile_digest" = "$opencode_v2_runtime_manual_previous_profile_digest" ] || return 1

      opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_manual_previous/profile"
      opencode_v2_runtime_tx_profile_digest="$opencode_v2_runtime_manual_previous_profile_digest"
      opencode_v2_runtime_tx_had_profile="$opencode_v2_runtime_manual_previous_had_profile"
      opencode_v2_runtime_transaction_restore_profile || return 1

      if [ -e "$opencode_v2_runtime_manual_bundle_stage" ] || [ -L "$opencode_v2_runtime_manual_bundle_stage" ]; then
        [ ! -L "$opencode_v2_runtime_manual_bundle_stage" ] || return 1
        rm -rf "$opencode_v2_runtime_manual_bundle_stage" || return 1
      fi
      if [ -e "$opencode_v2_runtime_manual_wrapper_stage" ] || [ -L "$opencode_v2_runtime_manual_wrapper_stage" ]; then
        [ ! -L "$opencode_v2_runtime_manual_wrapper_stage" ] || return 1
        rm -f "$opencode_v2_runtime_manual_wrapper_stage" || return 1
      fi
      cp -a "$opencode_v2_runtime_manual_previous/bundle" "$opencode_v2_runtime_manual_bundle_stage" || return 1
      cp -a "$opencode_v2_runtime_manual_previous/bundle/.wrapper" \
        "$opencode_v2_runtime_manual_wrapper_stage" || return 1
      opencode_v2_runtime_staged_wrapper_digest=$(sha256sum \
        "$opencode_v2_runtime_manual_wrapper_stage" | awk '{ print $1 }') || return 1
      [ "$opencode_v2_runtime_staged_wrapper_digest" = "$opencode_v2_runtime_manual_previous_wrapper_digest" ] || return 1
      rm -f "$opencode_v2_runtime_manual_bundle_stage/.wrapper" || return 1
      opencode_v2_runtime_staged_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
        "$opencode_v2_runtime_manual_bundle_stage") || return 1
      [ "$opencode_v2_runtime_staged_bundle_digest" = "$opencode_v2_runtime_manual_previous_bundle_digest" ] || return 1

      if [ -e "$opencode_v2_runtime_tx_libexec" ] || [ -L "$opencode_v2_runtime_tx_libexec" ]; then
        [ ! -L "$opencode_v2_runtime_tx_libexec" ] || return 1
        opencode_v2_runtime_live_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
          "$opencode_v2_runtime_tx_libexec") || return 1
        case "$opencode_v2_runtime_live_bundle_digest" in
          "$opencode_v2_runtime_manual_previous_bundle_digest")
            rm -rf "$opencode_v2_runtime_manual_bundle_stage"
            ;;
          "$opencode_v2_runtime_manual_current_bundle_digest")
            rm -rf "$opencode_v2_runtime_tx_libexec" || return 1
            mv "$opencode_v2_runtime_manual_bundle_stage" "$opencode_v2_runtime_tx_libexec" || return 1
            ;;
          *)
            opencode_v2_runtime_error 'El bundle activo cambió durante el rollback; se conserva para revisión.'
            return 1
            ;;
        esac
      else
        mv "$opencode_v2_runtime_manual_bundle_stage" "$opencode_v2_runtime_tx_libexec" || return 1
      fi

      opencode_v2_runtime_live_wrapper_digest=$(sha256sum "$opencode_v2_runtime_tx_wrapper" 2>/dev/null |
        awk '{ print $1 }' || true)
      if [ "$opencode_v2_runtime_live_wrapper_digest" != "$opencode_v2_runtime_manual_previous_wrapper_digest" ]; then
        if [ -e "$opencode_v2_runtime_tx_wrapper" ] || [ -L "$opencode_v2_runtime_tx_wrapper" ]; then
          [ ! -L "$opencode_v2_runtime_tx_wrapper" ] || return 1
          [ "$opencode_v2_runtime_live_wrapper_digest" = "$opencode_v2_runtime_manual_current_wrapper_digest" ] || return 1
          rm -f "$opencode_v2_runtime_tx_wrapper" || return 1
        fi
        mv "$opencode_v2_runtime_manual_wrapper_stage" "$opencode_v2_runtime_tx_wrapper" || return 1
        chmod 755 "$opencode_v2_runtime_tx_wrapper" || return 1
      else
        rm -f "$opencode_v2_runtime_manual_wrapper_stage"
      fi
    fi

    opencode_v2_runtime_manual_write_journal manual-restored || return 1
    opencode_v2_runtime_manual_phase=manual-restored
  fi

  if [ "$opencode_v2_runtime_manual_phase" = manual-restored ]; then
    opencode_v2_runtime_restored_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
      "$opencode_v2_runtime_tx_libexec") || return 1
    [ "$opencode_v2_runtime_restored_bundle_digest" = "$opencode_v2_runtime_manual_previous_bundle_digest" ] || return 1
    opencode_v2_runtime_restored_wrapper_digest=$(sha256sum "$opencode_v2_runtime_tx_wrapper" |
      awk '{ print $1 }') || return 1
    [ "$opencode_v2_runtime_restored_wrapper_digest" = "$opencode_v2_runtime_manual_previous_wrapper_digest" ] || return 1
    opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_manual_previous/profile"
    opencode_v2_runtime_tx_profile_digest="$opencode_v2_runtime_manual_previous_profile_digest"
    opencode_v2_runtime_tx_had_profile="$opencode_v2_runtime_manual_previous_had_profile"
    opencode_v2_runtime_restored_profile_digest=$(opencode_v2_runtime_transaction_active_profile_digest) || return 1
    [ "$opencode_v2_runtime_restored_profile_digest" = "$opencode_v2_runtime_manual_previous_profile_digest" ] || return 1
    rm -rf "$opencode_v2_runtime_manual_previous" "$opencode_v2_runtime_manual_dir" || return 1
    if [ -d "$opencode_v2_runtime_manual_displaced" ] &&
       [ "$opencode_v2_runtime_manual_current_had_profile" = 0 ]; then
      rm -rf "$opencode_v2_runtime_manual_displaced" || return 1
    fi
    rm -f "$opencode_v2_runtime_journal" || return 1
    opencode_v2_runtime_release_run_lock
    sync
  fi
}

opencode_v2_runtime_rollback() {
  opencode_v2_runtime_transaction_recovery_context || return 1
  if [ -L "$opencode_v2_runtime_journal" ] ||
     { [ -e "$opencode_v2_runtime_journal" ] && [ ! -f "$opencode_v2_runtime_journal" ]; }; then
    opencode_v2_runtime_error 'El journal de recuperación no es un archivo regular; no se sobrescribirá.'
    return 1
  fi
  if [ -f "$opencode_v2_runtime_journal" ] && [ ! -L "$opencode_v2_runtime_journal" ]; then
    opencode_v2_runtime_operation=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_journal" operation)
    opencode_v2_runtime_recovery_acquire_lock || return 1
    if [ "$opencode_v2_runtime_operation" = manual-rollback ]; then
      opencode_v2_runtime_manual_rollback_continue
    else
      opencode_v2_runtime_transaction_rollback
    fi
    return $?
  fi
  for opencode_v2_runtime_incomplete_path in \
    "$opencode_v2_runtime_recovery/current" \
    "$opencode_v2_runtime_recovery/previous.old" \
    "$opencode_v2_runtime_recovery/manual"; do
    if [ -e "$opencode_v2_runtime_incomplete_path" ] || [ -L "$opencode_v2_runtime_incomplete_path" ]; then
      opencode_v2_runtime_error 'Hay un snapshot sin journal; no se puede restaurar automáticamente con certeza.'
      return 1
    fi
  done
  if [ -d "$opencode_v2_runtime_recovery/previous" ]; then
    opencode_v2_runtime_recovery_acquire_lock || return 1
    if opencode_v2_runtime_manual_rollback_begin; then
      return 0
    fi
    if [ ! -e "$opencode_v2_runtime_journal" ]; then
      if [ -d "$opencode_v2_runtime_recovery/manual" ] &&
         [ ! -L "$opencode_v2_runtime_recovery/manual" ]; then
        rm -rf "$opencode_v2_runtime_recovery/manual"
      fi
      opencode_v2_runtime_release_run_lock
    fi
    return 1
  fi
  if [ -d "$opencode_v2_runtime_lock" ]; then
    opencode_v2_runtime_recovery_acquire_lock || return 1
    opencode_v2_runtime_release_run_lock
    return 0
  fi
  opencode_v2_runtime_error 'No hay una transacción pendiente ni un respaldo anterior para restaurar.'
  return 1
}

opencode_v2_runtime_transaction_finish_rollback() {
  if [ "$opencode_v2_runtime_tx_had_bundle" = 1 ]; then
    opencode_v2_runtime_restored_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
      "$opencode_v2_runtime_tx_libexec") || return 1
    [ "$opencode_v2_runtime_restored_bundle_digest" = "$opencode_v2_runtime_tx_old_bundle_digest" ] || return 1
    opencode_v2_runtime_restored_wrapper_digest=$(sha256sum "$opencode_v2_runtime_tx_wrapper" |
      awk '{ print $1 }') || return 1
    [ "$opencode_v2_runtime_restored_wrapper_digest" = "$opencode_v2_runtime_tx_old_wrapper_digest" ] || return 1
  else
    [ ! -e "$opencode_v2_runtime_tx_libexec" ] && [ ! -L "$opencode_v2_runtime_tx_libexec" ] &&
      [ ! -e "$opencode_v2_runtime_tx_wrapper" ] && [ ! -L "$opencode_v2_runtime_tx_wrapper" ] || return 1
  fi
  opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_recovery/current/profile"
  if [ ! -d "$opencode_v2_runtime_tx_profile_snapshot" ] &&
     [ -d "$opencode_v2_runtime_recovery/previous/profile" ]; then
    opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_recovery/previous/profile"
  fi
  opencode_v2_runtime_tx_profile_digest=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" profile_digest)
  opencode_v2_runtime_tx_had_profile=$(opencode_v2_runtime_transaction_value \
    "$opencode_v2_runtime_journal" had_profile)
  opencode_v2_runtime_restored_profile_digest=$(opencode_v2_runtime_transaction_active_profile_digest) || return 1
  if [ "$opencode_v2_runtime_tx_had_profile" = 1 ]; then
    opencode_v2_runtime_snapshot_profile_digest=$(opencode_v2_runtime_transaction_tree_digest \
      "$opencode_v2_runtime_tx_profile_snapshot") || return 1
  else
    opencode_v2_runtime_snapshot_profile_digest=$(printf '' | sha256sum | awk '{ print $1 }')
  fi
  [ "$opencode_v2_runtime_restored_profile_digest" = "$opencode_v2_runtime_snapshot_profile_digest" ] || return 1

  rm -rf "$opencode_v2_runtime_recovery/current" || return 1
  if [ "$opencode_v2_runtime_tx_restore_from_previous" = true ]; then
    rm -rf "$opencode_v2_runtime_recovery/previous" || return 1
  fi
  if [ -d "$opencode_v2_runtime_recovery/previous.old" ]; then
    [ ! -e "$opencode_v2_runtime_recovery/previous" ] || return 1
    mv "$opencode_v2_runtime_recovery/previous.old" "$opencode_v2_runtime_recovery/previous" || return 1
  fi
  rm -f "$opencode_v2_runtime_journal" || return 1
  opencode_v2_runtime_release_run_lock
  sync
}

opencode_v2_runtime_transaction_rollback() {
  opencode_v2_runtime_transaction_recovery_context || return 1
  if [ ! -e "$opencode_v2_runtime_journal" ]; then
    if [ -d "$opencode_v2_runtime_lock" ] && opencode_v2_runtime_transaction_current_owner; then
      opencode_v2_runtime_transaction_prepare_cleanup
    fi
    return 0
  fi
  opencode_v2_runtime_transaction_load_journal || {
    opencode_v2_runtime_error 'Journal inválido; se conserva para recuperación manual.'
    return 1
  }
  opencode_v2_runtime_transaction_current_owner || {
    opencode_v2_runtime_error 'La transacción no conserva el lock de este proceso.'
    return 1
  }
  if [ "$opencode_v2_runtime_tx_phase" = rolled-back ]; then
    opencode_v2_runtime_transaction_finish_rollback
    return $?
  fi

  if [ ! -d "$opencode_v2_runtime_tx_profile_snapshot" ] &&
     { [ "$opencode_v2_runtime_tx_phase" = committing ] ||
       [ "$opencode_v2_runtime_tx_phase" = promoted ]; } &&
     [ -d "$opencode_v2_runtime_recovery/previous/profile" ]; then
    opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_recovery/previous/profile"
  fi
  opencode_v2_runtime_tx_restore_bundle="$opencode_v2_runtime_tx_bundle_backup"
  opencode_v2_runtime_tx_bundle_already_active=false
  opencode_v2_runtime_tx_restore_wrapper_from_backup=false
  if [ "$opencode_v2_runtime_tx_had_bundle" = 1 ]; then
    if [ ! -d "$opencode_v2_runtime_tx_restore_bundle" ] &&
       { [ "$opencode_v2_runtime_tx_phase" = committing ] ||
         [ "$opencode_v2_runtime_tx_phase" = promoted ]; } &&
       [ -d "$opencode_v2_runtime_recovery/previous/bundle" ]; then
      opencode_v2_runtime_tx_restore_bundle="$opencode_v2_runtime_recovery/previous/bundle"
      opencode_v2_runtime_tx_restore_from_previous=true
    fi
    if [ -e "$opencode_v2_runtime_tx_restore_bundle" ] ||
       [ -L "$opencode_v2_runtime_tx_restore_bundle" ]; then
      [ -d "$opencode_v2_runtime_tx_restore_bundle" ] &&
        [ ! -L "$opencode_v2_runtime_tx_restore_bundle" ] || return 1
      opencode_v2_runtime_current_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
        "$opencode_v2_runtime_tx_restore_bundle") || return 1
      if [ "$opencode_v2_runtime_current_bundle_digest" = "$opencode_v2_runtime_tx_old_bundle_digest" ]; then
        opencode_v2_runtime_backup_wrapper="$opencode_v2_runtime_tx_restore_bundle/.wrapper"
        if [ -f "$opencode_v2_runtime_backup_wrapper" ] &&
           [ -x "$opencode_v2_runtime_backup_wrapper" ] &&
           [ ! -L "$opencode_v2_runtime_backup_wrapper" ]; then
          opencode_v2_runtime_backup_wrapper_digest=$(sha256sum \
            "$opencode_v2_runtime_backup_wrapper" | awk '{ print $1 }') || return 1
          if [ "$opencode_v2_runtime_backup_wrapper_digest" = "$opencode_v2_runtime_tx_old_wrapper_digest" ]; then
            opencode_v2_runtime_tx_restore_wrapper_from_backup=true
          fi
        fi
        if [ "$opencode_v2_runtime_tx_restore_wrapper_from_backup" != true ]; then
          [ -f "$opencode_v2_runtime_tx_wrapper" ] &&
            [ -x "$opencode_v2_runtime_tx_wrapper" ] &&
            [ ! -L "$opencode_v2_runtime_tx_wrapper" ] || return 1
          opencode_v2_runtime_current_wrapper_digest=$(sha256sum \
            "$opencode_v2_runtime_tx_wrapper" | awk '{ print $1 }') || return 1
          [ "$opencode_v2_runtime_current_wrapper_digest" = "$opencode_v2_runtime_tx_old_wrapper_digest" ] || return 1
        fi
      elif [ -d "$opencode_v2_runtime_tx_libexec" ] &&
           [ ! -L "$opencode_v2_runtime_tx_libexec" ]; then
        opencode_v2_runtime_current_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
          "$opencode_v2_runtime_tx_libexec") || return 1
        [ "$opencode_v2_runtime_current_bundle_digest" = "$opencode_v2_runtime_tx_old_bundle_digest" ] || return 1
        [ -f "$opencode_v2_runtime_tx_wrapper" ] &&
          [ -x "$opencode_v2_runtime_tx_wrapper" ] &&
          [ ! -L "$opencode_v2_runtime_tx_wrapper" ] || return 1
        opencode_v2_runtime_current_wrapper_digest=$(sha256sum \
          "$opencode_v2_runtime_tx_wrapper" | awk '{ print $1 }') || return 1
        [ "$opencode_v2_runtime_current_wrapper_digest" = "$opencode_v2_runtime_tx_old_wrapper_digest" ] || return 1
        opencode_v2_runtime_tx_bundle_already_active=true
      else
        return 1
      fi
    elif [ -d "$opencode_v2_runtime_tx_libexec" ]; then
      opencode_v2_runtime_current_bundle_digest=$(opencode_v2_runtime_transaction_bundle_digest \
        "$opencode_v2_runtime_tx_libexec") || return 1
      [ "$opencode_v2_runtime_current_bundle_digest" = "$opencode_v2_runtime_tx_old_bundle_digest" ] || return 1
      opencode_v2_runtime_tx_current_wrapper_digest=$(sha256sum \
        "$opencode_v2_runtime_tx_wrapper" | awk '{ print $1 }') || return 1
      [ "$opencode_v2_runtime_tx_current_wrapper_digest" = "$opencode_v2_runtime_tx_old_wrapper_digest" ] || return 1
      opencode_v2_runtime_tx_bundle_already_active=true
    else
      return 1
    fi
  fi
  opencode_v2_runtime_transaction_restore_profile || return 1

  if [ "$opencode_v2_runtime_tx_bundle_already_active" != true ]; then
    if [ -e "$opencode_v2_runtime_tx_libexec" ] || [ -L "$opencode_v2_runtime_tx_libexec" ]; then
      [ ! -L "$opencode_v2_runtime_tx_libexec" ] || return 1
      rm -rf "$opencode_v2_runtime_tx_libexec" || return 1
    fi
  fi
  if [ "$opencode_v2_runtime_tx_had_bundle" = 1 ]; then
    if [ "$opencode_v2_runtime_tx_bundle_already_active" != true ]; then
      mkdir -p "$(dirname "$opencode_v2_runtime_tx_libexec")" || return 1
      mv "$opencode_v2_runtime_tx_restore_bundle" "$opencode_v2_runtime_tx_libexec" || return 1
      if [ "$opencode_v2_runtime_tx_restore_wrapper_from_backup" = true ]; then
        mv "$opencode_v2_runtime_tx_libexec/.wrapper" "$opencode_v2_runtime_tx_wrapper" || return 1
        chmod 755 "$opencode_v2_runtime_tx_wrapper" || return 1
      else
        rm -f "$opencode_v2_runtime_tx_libexec/.wrapper" || return 1
      fi
    fi
  else
    if [ -e "$opencode_v2_runtime_tx_wrapper" ] || [ -L "$opencode_v2_runtime_tx_wrapper" ]; then
      [ ! -L "$opencode_v2_runtime_tx_wrapper" ] || return 1
      rm -f "$opencode_v2_runtime_tx_wrapper" || return 1
    fi
  fi
  opencode_v2_runtime_tx_phase=rolled-back
  opencode_v2_runtime_transaction_write_journal rolled-back || return 1
  opencode_v2_runtime_transaction_finish_rollback
}

opencode_v2_runtime_transaction_commit() {
  opencode_v2_runtime_transaction_load_journal || return 1
  [ "$opencode_v2_runtime_tx_phase" = validated ] || return 1
  opencode_v2_runtime_transaction_current_owner || return 1
  if [ -d "$opencode_v2_runtime_recovery/previous" ]; then
    opencode_v2_runtime_transaction_validate_previous || {
      opencode_v2_runtime_error 'El respaldo anterior cambió antes de rotarse; se conserva la transacción pendiente.'
      return 1
    }
    opencode_v2_runtime_transaction_load_journal || return 1
    [ "$opencode_v2_runtime_tx_phase" = validated ] || return 1
  fi
  opencode_v2_runtime_tx_phase=committing
  opencode_v2_runtime_transaction_write_journal committing || return 1
  cp "$opencode_v2_runtime_journal" "$opencode_v2_runtime_tx_snapshot/transaction.txt" || return 1
  chmod 600 "$opencode_v2_runtime_tx_snapshot/transaction.txt" || return 1
  sync
  if [ -d "$opencode_v2_runtime_recovery/previous" ]; then
    [ ! -e "$opencode_v2_runtime_recovery/previous.old" ] &&
      [ ! -L "$opencode_v2_runtime_recovery/previous.old" ] || return 1
    mv "$opencode_v2_runtime_recovery/previous" "$opencode_v2_runtime_recovery/previous.old" || return 1
  fi
  mv "$opencode_v2_runtime_tx_snapshot" "$opencode_v2_runtime_recovery/previous" || return 1
  opencode_v2_runtime_tx_snapshot="$opencode_v2_runtime_recovery/previous"
  opencode_v2_runtime_tx_profile_snapshot="$opencode_v2_runtime_tx_snapshot/profile"
  opencode_v2_runtime_tx_bundle_backup="$opencode_v2_runtime_tx_snapshot/bundle"
  opencode_v2_runtime_tx_phase=promoted
  opencode_v2_runtime_transaction_write_journal promoted || return 1
  rm -rf "$opencode_v2_runtime_recovery/previous.old"
  rm -f "$opencode_v2_runtime_journal" || return 1
  opencode_v2_runtime_release_run_lock
  sync
}

opencode_v2_runtime_transaction() {
  case "$1" in
    prepare) opencode_v2_runtime_transaction_prepare ;;
    validate) opencode_v2_runtime_transaction_validate ;;
    commit) opencode_v2_runtime_transaction_commit ;;
    rollback) opencode_v2_runtime_transaction_rollback ;;
    *) opencode_v2_runtime_error 'Fase transaccional inválida.'; return 2 ;;
  esac
}

opencode_v2_runtime_status() {
  opencode_v2_runtime_init_paths || return 1
  opencode_v2_runtime_validate_path_ancestors "$opencode_v2_runtime_recovery" || return 1
  if [ -L "$opencode_v2_runtime_journal" ] ||
     { [ -e "$opencode_v2_runtime_journal" ] && [ ! -f "$opencode_v2_runtime_journal" ]; }; then
    opencode_v2_runtime_error 'El journal de recuperación no es un archivo regular.'
    return 1
  fi
  if [ -L "$opencode_v2_runtime_recovery/previous" ]; then
    opencode_v2_runtime_error 'El respaldo anterior es un symlink; no se leerá.'
    return 1
  fi
  if [ -f "$opencode_v2_runtime_journal" ] && [ ! -L "$opencode_v2_runtime_journal" ]; then
    opencode_v2_runtime_status_operation=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_journal" operation)
    if [ "$opencode_v2_runtime_status_operation" = manual-rollback ]; then
      opencode_v2_runtime_manual_load_journal || {
        opencode_v2_runtime_error 'El journal de rollback manual es inválido; v2 permanece bloqueado.'
        return 1
      }
      printf 'pending=%s\nprevious=%s\nprevious_contract=%s\ncurrent=%s\ncurrent_contract=%s\n' \
        "$opencode_v2_runtime_manual_phase" "$opencode_v2_runtime_manual_previous_tag" \
        "$opencode_v2_runtime_manual_previous_contract" "$opencode_v2_runtime_manual_current_tag" \
        "$opencode_v2_runtime_manual_current_contract"
      return 0
    fi
    if ! opencode_v2_runtime_transaction_load_journal; then
      opencode_v2_runtime_error 'La transacción tiene un journal inválido; v2 permanece bloqueado.'
      return 1
    fi
    printf 'pending=%s\nprevious=%s\nprevious_contract=%s\ncandidate=%s\ncandidate_contract=%s\n' \
      "$opencode_v2_runtime_tx_phase" "$opencode_v2_runtime_tx_old_tag" \
      "${opencode_v2_runtime_tx_old_contract:-none}" "$opencode_v2_runtime_tx_candidate_tag" \
      "$opencode_v2_runtime_tx_candidate_contract"
  elif [ -e "$opencode_v2_runtime_recovery/current" ] ||
       [ -L "$opencode_v2_runtime_recovery/current" ] ||
       [ -e "$opencode_v2_runtime_recovery/previous.old" ] ||
       [ -L "$opencode_v2_runtime_recovery/previous.old" ] ||
       [ -e "$opencode_v2_runtime_recovery/manual" ] ||
       [ -L "$opencode_v2_runtime_recovery/manual" ]; then
    opencode_v2_runtime_error 'Hay un snapshot sin journal; v2 permanece bloqueado para revisión.'
    printf 'state=incomplete\n'
    return 1
  elif [ -d "$opencode_v2_runtime_lock" ]; then
    printf 'lock=present\n'
  elif [ -d "$opencode_v2_runtime_recovery/previous" ]; then
    opencode_v2_runtime_previous_tag=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_recovery/previous/bundle/manifest.txt" tag 2>/dev/null || true)
    opencode_v2_runtime_previous_contract=$(opencode_v2_runtime_transaction_value \
      "$opencode_v2_runtime_recovery/previous/bundle/manifest.txt" release_contract 2>/dev/null || true)
    printf 'lock=absent\nprevious=%s\nprevious_contract=%s\n' \
      "${opencode_v2_runtime_previous_tag:-unknown}" "${opencode_v2_runtime_previous_contract:-unknown}"
    if [ -d "$opencode_v2_runtime_recovery/displaced/profile" ]; then
      printf 'displaced_profile=present\n'
    fi
  elif [ -d "$opencode_v2_runtime_recovery/displaced/profile" ]; then
    printf 'state=rolled-back\ndisplaced_profile=present\n'
  else
    printf 'state=clean\n'
  fi
}

opencode_v2_runtime_evaluate_cleanup() {
  opencode_v2_runtime_evaluate_status="$1"
  trap - 0 HUP INT TERM
  if ! rm -rf "${opencode_v2_runtime_evaluate_root:?}"; then
    opencode_v2_runtime_evaluate_status=1
  fi
  exit "$opencode_v2_runtime_evaluate_status"
}

opencode_v2_runtime_guard_command() {
  opencode_v2_runtime_skip_value=false
  for opencode_v2_runtime_command_arg do
    if [ "$opencode_v2_runtime_skip_value" = true ]; then
      opencode_v2_runtime_skip_value=false
      continue
    fi
    case "$opencode_v2_runtime_command_arg" in
      --log-level|-m|--model|-s|--session|-f|--file|--format|--agent|--title|--directory|--prompt)
        opencode_v2_runtime_skip_value=true
        ;;
      --log-level=*|--model=*|--session=*|--file=*|--format=*|--agent=*|--title=*|--directory=*|--prompt=*|--print-logs|--pure|--help|-h|--version|-v|--)
        ;;
      upgrade|update)
        opencode_v2_runtime_error 'El actualizador propio está deshabilitado; las versiones aprobadas se administran desde aicli.'
        return 1
        ;;
      serve|service)
        opencode_v2_runtime_error 'El servidor persistente no está habilitado; el wrapper administra un servidor efímero.'
        return 1
        ;;
      -* ) ;;
      *) return 0 ;;
    esac
  done
}

opencode_v2_runtime_evaluate() (
  set -eu
  [ "$#" -eq 2 ] && [ "$1" = --version ] || {
    opencode_v2_runtime_error 'Uso: evaluate --version <v2.x.y>'
    return 2
  }
  opencode_v2_runtime_evaluate_version=${2#v}
  opencode_v2_runtime_evaluate_tag="v$opencode_v2_runtime_evaluate_version"

  case "$opencode_v2_runtime_evaluate_version" in
    *[!0-9A-Za-z.+-]*|'')
      opencode_v2_runtime_error 'La versión debe ser un tag estable v2.x.y.'
      return 2
      ;;
  esac
  # shellcheck disable=SC1091
  . "${opencode_v2_runtime_project_root:?}/registry/lib/releases.sh"
  if [ "$(release_version_major "$opencode_v2_runtime_evaluate_tag")" != 2 ] ||
    ! release_version_is_stable "$opencode_v2_runtime_evaluate_tag"; then
    opencode_v2_runtime_error 'La evaluación requiere una versión estable de major 2.'
    return 2
  fi
  case "$opencode_v2_runtime_project_root" in
    /*) ;;
    *) opencode_v2_runtime_error 'La raíz del proyecto debe ser absoluta.'; return 1 ;;
  esac

  for opencode_v2_runtime_evaluate_command in curl jq sha256sum tar env; do
    command -v "$opencode_v2_runtime_evaluate_command" >/dev/null 2>&1 || {
      opencode_v2_runtime_error "Falta el comando requerido: $opencode_v2_runtime_evaluate_command."
      return 1
    }
  done

  opencode_v2_runtime_evaluate_prefix=${PREFIX:-/data/data/com.termux/files/usr}
  case "$opencode_v2_runtime_evaluate_prefix" in
    /*) ;;
    *) opencode_v2_runtime_error 'PREFIX debe ser una ruta absoluta.'; return 1 ;;
  esac
  opencode_v2_runtime_evaluate_loader="$opencode_v2_runtime_evaluate_prefix/glibc/lib/ld-linux-aarch64.so.1"
  opencode_v2_runtime_evaluate_library_path="$opencode_v2_runtime_evaluate_prefix/glibc/lib"
  [ -x "$opencode_v2_runtime_evaluate_loader" ] &&
    [ -d "$opencode_v2_runtime_evaluate_library_path" ] || {
      opencode_v2_runtime_error 'No está disponible el loader glibc arm64 existente; no se instalarán dependencias.'
      return 1
    }

  opencode_v2_runtime_evaluate_tmp_base=${TMPDIR:-$opencode_v2_runtime_evaluate_prefix/tmp}
  [ -d "$opencode_v2_runtime_evaluate_tmp_base" ] &&
    [ -w "$opencode_v2_runtime_evaluate_tmp_base" ] || {
      opencode_v2_runtime_error 'TMPDIR o PREFIX/tmp no existe o no permite escritura.'
      return 1
    }
  umask 077
  opencode_v2_runtime_evaluate_root=$(mktemp -d \
    "$opencode_v2_runtime_evaluate_tmp_base/opencode-v2-evaluate.XXXXXX") || return 1
  trap 'opencode_v2_runtime_evaluate_cleanup $?' 0
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  chmod 700 "$opencode_v2_runtime_evaluate_root"
  opencode_v2_runtime_evaluate_api="$opencode_v2_runtime_evaluate_root/release.json"
  opencode_v2_runtime_evaluate_archive="$opencode_v2_runtime_evaluate_root/release.tar.gz"
  opencode_v2_runtime_evaluate_bundle="$opencode_v2_runtime_evaluate_root/bundle"
  opencode_v2_runtime_evaluate_home="$opencode_v2_runtime_evaluate_root/home"
  opencode_v2_runtime_evaluate_project="$opencode_v2_runtime_evaluate_root/project"
  mkdir -m 700 "$opencode_v2_runtime_evaluate_bundle" \
    "$opencode_v2_runtime_evaluate_home" "$opencode_v2_runtime_evaluate_project"
  opencode_v2_runtime_evaluate_config_dir="$opencode_v2_runtime_evaluate_home/.local/share/ai-cli-termux/opencode-v2/config/opencode"
  mkdir -p "$opencode_v2_runtime_evaluate_config_dir"
  chmod 700 "$opencode_v2_runtime_evaluate_config_dir"
  cat > "$opencode_v2_runtime_evaluate_config_dir/opencode.json" <<'EOF'
{"update":"disable","permissions":[{"action":"external_directory","resource":"*","effect":"ask"}]}
EOF
  chmod 600 "$opencode_v2_runtime_evaluate_config_dir/opencode.json"
  printf '{ invalid project config\n' > "$opencode_v2_runtime_evaluate_project/opencode.json"
  printf '{ invalid ancestor config\n' > "$opencode_v2_runtime_evaluate_root/opencode.json"
  opencode_v2_runtime_evaluate_plugin_dir="$opencode_v2_runtime_evaluate_project/.opencode/plugins"
  mkdir -p "$opencode_v2_runtime_evaluate_plugin_dir"
  chmod 700 "$opencode_v2_runtime_evaluate_plugin_dir"
  cat > "$opencode_v2_runtime_evaluate_plugin_dir/trap.ts" <<'EOF'
import { writeFileSync } from "node:fs"

writeFileSync(new URL("./loaded", import.meta.url), "loaded")

export default {
  id: "synthetic-project-plugin-trap",
  setup: async () => {},
}
EOF
  chmod 600 "$opencode_v2_runtime_evaluate_plugin_dir/trap.ts"

  opencode_v2_runtime_evaluate_asset=opencode-linux-arm64.tar.gz
  opencode_v2_runtime_evaluate_expected_url="https://github.com/anomalyco/opencode/releases/download/$opencode_v2_runtime_evaluate_tag/$opencode_v2_runtime_evaluate_asset"
  opencode_v2_runtime_evaluate_api_url="https://api.github.com/repos/anomalyco/opencode/releases/tags/$opencode_v2_runtime_evaluate_tag"
  if ! curl --location --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error \
    --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2 --retry-all-errors \
    -H 'Accept: application/vnd.github+json' -o "$opencode_v2_runtime_evaluate_api" \
    "$opencode_v2_runtime_evaluate_api_url"; then
    opencode_v2_runtime_error 'No se pudo consultar el release exacto en GitHub API.'
    return 1
  fi
  if ! release_validate_object "$(cat "$opencode_v2_runtime_evaluate_api")" \
    "$opencode_v2_runtime_evaluate_asset" 2 stable "$opencode_v2_runtime_evaluate_tag"; then
    opencode_v2_runtime_error 'El release no es estable, no coincide con el tag o no contiene un asset único.'
    return 1
  fi
  if ! opencode_v2_runtime_evaluate_download_url=$(printf '%s' \
    "$(cat "$opencode_v2_runtime_evaluate_api")" | release_asset_url \
      "$opencode_v2_runtime_evaluate_asset" "$opencode_v2_runtime_evaluate_expected_url" 2>/dev/null); then
    opencode_v2_runtime_error 'La URL publicada del asset no coincide con el tag y repositorio esperados.'
    return 1
  fi
  if ! opencode_v2_runtime_evaluate_api_digest=$(printf '%s' \
    "$(cat "$opencode_v2_runtime_evaluate_api")" | release_asset_digest \
      "$opencode_v2_runtime_evaluate_asset" 2>/dev/null); then
    opencode_v2_runtime_error 'El asset no publica un digest SHA256 verificable.'
    return 1
  fi
  case "$opencode_v2_runtime_evaluate_api_digest" in
    sha256:????????????????????????????????????????????????????????????????) ;;
    *) opencode_v2_runtime_error 'El digest publicado para el asset no es SHA256 válido.'; return 1 ;;
  esac
  opencode_v2_runtime_evaluate_sha256=${opencode_v2_runtime_evaluate_api_digest#sha256:}
  printf '%s\n' "$opencode_v2_runtime_evaluate_sha256" | grep -Eq '^[A-Fa-f0-9]{64}$' || {
    opencode_v2_runtime_error 'El digest publicado para el asset no es SHA256 válido.'
    return 1
  }
  opencode_v2_runtime_evaluate_sha256=$(printf '%s' "$opencode_v2_runtime_evaluate_sha256" | tr 'A-F' 'a-f')

  if ! curl --location --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error \
    --connect-timeout 10 --max-time 600 --retry 3 --retry-delay 2 --retry-all-errors \
    -o "$opencode_v2_runtime_evaluate_archive" "$opencode_v2_runtime_evaluate_download_url"; then
    opencode_v2_runtime_error 'No se pudo descargar el asset oficial del candidato.'
    return 1
  fi
  opencode_v2_runtime_evaluate_actual_sha256=$(sha256sum "$opencode_v2_runtime_evaluate_archive" |
    awk 'NR == 1 { print $1 }') || return 1
  [ "$opencode_v2_runtime_evaluate_actual_sha256" = "$opencode_v2_runtime_evaluate_sha256" ] || {
    opencode_v2_runtime_error "El SHA256 descargado no coincide con el digest del release (API: $opencode_v2_runtime_evaluate_sha256; archivo: $opencode_v2_runtime_evaluate_actual_sha256)."
    return 1
  }
  opencode_v2_runtime_evaluate_archive_entries=$(tar -tzf "$opencode_v2_runtime_evaluate_archive") || {
    opencode_v2_runtime_error 'El asset no es un tar.gz legible.'
    return 1
  }
  [ "$opencode_v2_runtime_evaluate_archive_entries" = opencode ] || {
    opencode_v2_runtime_error 'El asset debe contener únicamente el archivo opencode en su raíz.'
    return 1
  }
  tar -xzf "$opencode_v2_runtime_evaluate_archive" -C "$opencode_v2_runtime_evaluate_bundle" || return 1
  opencode_v2_runtime_evaluate_binary="$opencode_v2_runtime_evaluate_bundle/opencode"
  [ -f "$opencode_v2_runtime_evaluate_binary" ] &&
    [ ! -L "$opencode_v2_runtime_evaluate_binary" ] &&
    [ -x "$opencode_v2_runtime_evaluate_binary" ] || {
      opencode_v2_runtime_error 'El asset extraído no contiene un ELF opencode regular y ejecutable.'
      return 1
    }

  printf 'version=%s\n' "$opencode_v2_runtime_evaluate_tag" > \
    "$opencode_v2_runtime_evaluate_bundle/manifest.txt"
  chmod 600 "$opencode_v2_runtime_evaluate_bundle/manifest.txt"
  opencode_v2_runtime_evaluate_runtime="$opencode_v2_runtime_project_root/registry/lib/opencode-v2-runtime.sh"
  (
    cd "$opencode_v2_runtime_evaluate_project"
    env -i PATH="$PATH" HOME="$opencode_v2_runtime_evaluate_home" \
      PREFIX="$opencode_v2_runtime_evaluate_prefix" TMPDIR="$opencode_v2_runtime_evaluate_root" \
      TERM=dumb sh "$opencode_v2_runtime_evaluate_runtime" \
        "$opencode_v2_runtime_evaluate_loader" --library-path \
        "$opencode_v2_runtime_evaluate_library_path" "$opencode_v2_runtime_evaluate_binary" --version
  ) > "$opencode_v2_runtime_evaluate_root/version.out" 2> "$opencode_v2_runtime_evaluate_root/version.err" || {
    opencode_v2_runtime_error 'El candidato no respondió a --version bajo el loader existente.'
    return 1
  }
  opencode_v2_runtime_evaluate_actual_version=$(grep -Eo '[0-9]+[.][0-9]+[.][0-9]+' \
    "$opencode_v2_runtime_evaluate_root/version.out" | head -1)
  opencode_v2_runtime_evaluate_expected_version=${opencode_v2_runtime_evaluate_version%%+*}
  [ "$opencode_v2_runtime_evaluate_actual_version" = "$opencode_v2_runtime_evaluate_expected_version" ] || {
    opencode_v2_runtime_error 'La versión informada por el candidato no coincide con el tag evaluado.'
    return 1
  }

  if ! (
    cd "$opencode_v2_runtime_evaluate_project"
    env -i PATH="$PATH" HOME="$opencode_v2_runtime_evaluate_home" \
      PREFIX="$opencode_v2_runtime_evaluate_prefix" TMPDIR="$opencode_v2_runtime_evaluate_root" \
      OPENCODE_CLI_CONFIG_CONTENT='{"keybinds":{"app.exit":"none"}}' \
      TERM=dumb sh "$opencode_v2_runtime_evaluate_runtime" \
        "$opencode_v2_runtime_evaluate_loader" --library-path \
        "$opencode_v2_runtime_evaluate_library_path" "$opencode_v2_runtime_evaluate_binary" debug paths
  ) > "$opencode_v2_runtime_evaluate_root/paths.out" 2> "$opencode_v2_runtime_evaluate_root/paths.err"; then
    opencode_v2_runtime_error 'El candidato no confirmó sus rutas bajo el perfil sintético.'
    return 1
  fi
  for opencode_v2_runtime_evaluate_path in \
    "$opencode_v2_runtime_evaluate_home/.local/share/ai-cli-termux/opencode-v2/config" \
    "$opencode_v2_runtime_evaluate_home/.local/share/ai-cli-termux/opencode-v2/data" \
    "$opencode_v2_runtime_evaluate_home/.local/share/ai-cli-termux/opencode-v2/data/opencode-v2.db"; do
    grep -Fq "$opencode_v2_runtime_evaluate_path" "$opencode_v2_runtime_evaluate_root/paths.out" || {
      opencode_v2_runtime_error 'El candidato no respetó las rutas declaradas del perfil sintético.'
      return 1
    }
  done

  if ! (
    cd "$opencode_v2_runtime_evaluate_project"
    env -i PATH="$PATH" HOME="$opencode_v2_runtime_evaluate_home" \
      PREFIX="$opencode_v2_runtime_evaluate_prefix" TMPDIR="$opencode_v2_runtime_evaluate_root" \
      OPENCODE_CLI_CONFIG_CONTENT='{"keybinds":{"app.exit":"none"}}' \
      TERM=dumb sh "$opencode_v2_runtime_evaluate_runtime" \
        "$opencode_v2_runtime_evaluate_loader" --library-path \
        "$opencode_v2_runtime_evaluate_library_path" "$opencode_v2_runtime_evaluate_binary" debug config
  ) > "$opencode_v2_runtime_evaluate_root/config.out" \
      2> "$opencode_v2_runtime_evaluate_root/config.err"; then
    opencode_v2_runtime_error 'El candidato no pudo resolver la configuración global sintética sin cargar el proyecto.'
    return 1
  fi
  jq -e 'type == "object" or type == "array"' \
    "$opencode_v2_runtime_evaluate_root/config.out" >/dev/null || {
      opencode_v2_runtime_error 'debug config no devolvió JSON válido.'
      return 1
    }
  jq -e '[.. | objects | select(.update? == "disable")] | length > 0' \
    "$opencode_v2_runtime_evaluate_root/config.out" >/dev/null || {
      opencode_v2_runtime_error 'La configuración efectiva no deshabilitó la actualización propia.'
      return 1
    }
  jq -e '[.. | objects | select(.action? == "external_directory" and .resource? == "*" and .effect? == "ask")] | length > 0' \
    "$opencode_v2_runtime_evaluate_root/config.out" >/dev/null || {
      opencode_v2_runtime_error 'La configuración efectiva no exige ask para rutas externas.'
      return 1
    }
  [ ! -e "$opencode_v2_runtime_evaluate_plugin_dir/loaded" ] || {
    opencode_v2_runtime_error 'El candidato cargó un plugin local del proyecto sintético.'
    return 1
  }

  if ! (
    cd "$opencode_v2_runtime_evaluate_project"
    env -i PATH="$PATH" HOME="$opencode_v2_runtime_evaluate_home" \
      PREFIX="$opencode_v2_runtime_evaluate_prefix" TMPDIR="$opencode_v2_runtime_evaluate_root" \
      OPENCODE_CLI_CONFIG_CONTENT='{"keybinds":{"app.exit":"none"}}' \
      TERM=dumb sh "$opencode_v2_runtime_evaluate_runtime" \
        "$opencode_v2_runtime_evaluate_loader" --library-path \
        "$opencode_v2_runtime_evaluate_library_path" "$opencode_v2_runtime_evaluate_binary" \
        session list --format json
  ) > "$opencode_v2_runtime_evaluate_root/session-list.out" \
      2> "$opencode_v2_runtime_evaluate_root/session-list.err"; then
    opencode_v2_runtime_error 'La operación habitual session list falló bajo el runner aislado.'
    return 1
  fi
  [ ! -e "$opencode_v2_runtime_evaluate_plugin_dir/loaded" ] || {
    opencode_v2_runtime_error 'El candidato cargó un plugin local del proyecto sintético.'
    return 1
  }
  opencode_v2_runtime_evaluate_tui=not-run-no-tty
  opencode_v2_runtime_evaluate_tui_exit=not-run-no-tty
  if [ -t 0 ] && [ -t 1 ]; then
    if (
      cd "$opencode_v2_runtime_evaluate_project"
      env -i PATH="$PATH" HOME="$opencode_v2_runtime_evaluate_home" \
        PREFIX="$opencode_v2_runtime_evaluate_prefix" TMPDIR="$opencode_v2_runtime_evaluate_root" \
        OPENCODE_CLI_CONFIG_CONTENT='{"keybinds":{"app.exit":"none"}}' \
        TERM="${TERM:-xterm-256color}" sh "$opencode_v2_runtime_evaluate_runtime" \
          "$opencode_v2_runtime_evaluate_loader" --library-path \
          "$opencode_v2_runtime_evaluate_library_path" "$opencode_v2_runtime_evaluate_binary"
    ); then
      opencode_v2_runtime_evaluate_tui_exit=0
    else
      opencode_v2_runtime_evaluate_tui_exit=$?
    fi
    case "$opencode_v2_runtime_evaluate_tui_exit" in
      0|130) ;;
      *)
        opencode_v2_runtime_error "La TUI cotidiana cerró con estado inesperado: $opencode_v2_runtime_evaluate_tui_exit."
        return 1
        ;;
    esac
    [ ! -e "$opencode_v2_runtime_evaluate_home/.local/share/ai-cli-termux/recovery/opencode-v2/lock" ] || {
      opencode_v2_runtime_error 'La TUI dejó ocupado el perfil después de cerrar.'
      return 1
    }
    [ ! -e "$opencode_v2_runtime_evaluate_plugin_dir/loaded" ] || {
      opencode_v2_runtime_error 'La TUI cargó un plugin local del proyecto sintético.'
      return 1
    }
    opencode_v2_runtime_evaluate_tui=pass
  fi
  printf 'tag=%s\nasset=%s\nsha256=%s\nresult=runner-profile-config-plugin-session-list-pass\ntui=%s\ntui_exit=%s\n' \
    "$opencode_v2_runtime_evaluate_tag" "$opencode_v2_runtime_evaluate_asset" \
    "$opencode_v2_runtime_evaluate_sha256" "$opencode_v2_runtime_evaluate_tui" \
    "$opencode_v2_runtime_evaluate_tui_exit"
)

opencode_v2_runtime_run() {
  [ "$#" -gt 0 ] || {
    opencode_v2_runtime_error 'Falta el binario para ejecutar.'
    return 2
  }

  opencode_v2_runtime_loader=''
  opencode_v2_runtime_library_path=''
  if [ "$#" -ge 4 ] && [ "$2" = '--library-path' ]; then
    opencode_v2_runtime_loader="$1"
    opencode_v2_runtime_library_path="$3"
    shift 3
  fi
  opencode_v2_runtime_binary="$1"
  shift
  case "$opencode_v2_runtime_binary" in
    /*) ;;
    *) opencode_v2_runtime_error 'La ruta del binario debe ser absoluta.'; return 1 ;;
  esac
  [ -x "$opencode_v2_runtime_binary" ] || {
    opencode_v2_runtime_error 'El binario no existe o no es ejecutable.'
    return 1
  }
  opencode_v2_runtime_bundle=${opencode_v2_runtime_binary%/*}
  if [ -n "$opencode_v2_runtime_loader" ]; then
    case "$opencode_v2_runtime_loader:$opencode_v2_runtime_library_path" in
      /*:/*) ;;
      *) opencode_v2_runtime_error 'El loader y su ruta de bibliotecas deben ser absolutos.'; return 1 ;;
    esac
    [ -x "$opencode_v2_runtime_loader" ] && [ -d "$opencode_v2_runtime_library_path" ] || {
      opencode_v2_runtime_error 'El loader o la ruta de bibliotecas no están disponibles.'
      return 1
    }
  fi

  opencode_v2_runtime_help_requested=false
  for opencode_v2_runtime_arg do
    case "$opencode_v2_runtime_arg" in
      --help|-h) opencode_v2_runtime_help_requested=true ;;
    esac
  done
  if [ "$opencode_v2_runtime_help_requested" = true ]; then
    opencode_v2_runtime_launch "$@"
    return
  fi

  opencode_v2_runtime_guard_command "$@" || return 1

  case "${1:-}" in
    --version|-v|help)
      opencode_v2_runtime_launch "$@"
      return
      ;;
  esac
  for opencode_v2_runtime_arg do
    case "$opencode_v2_runtime_arg" in
      --server|--server=*)
        opencode_v2_runtime_error 'La conexión a servidores externos queda fuera del contrato de este wrapper.'
        return 1
        ;;
    esac
  done

  opencode_v2_runtime_init_paths || return 1
  opencode_v2_runtime_acquire_run_lock || return 1
  trap 'opencode_v2_runtime_cleanup_run' 0
  trap 'opencode_v2_runtime_signal HUP' HUP
  trap 'opencode_v2_runtime_signal INT' INT
  trap 'opencode_v2_runtime_signal TERM' TERM
  opencode_v2_runtime_prepare_profile || return 1

  if { [ "${1:-}" = debug ] && [ "${2:-}" = paths ]; } ||
     { [ "${1:-}" = db ] && [ "${2:-}" = path ]; }; then
    opencode_v2_runtime_launch_client false "$@"
    return
  fi

  opencode_v2_runtime_random_password || {
    opencode_v2_runtime_error 'No se pudo generar la contraseña efímera del servidor.'
    return 1
  }

  opencode_v2_runtime_tmp_base=${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}
  [ -d "$opencode_v2_runtime_tmp_base" ] && [ -w "$opencode_v2_runtime_tmp_base" ] || {
    opencode_v2_runtime_error 'TMPDIR o PREFIX/tmp no existe o no permite escritura.'
    return 1
  }
  opencode_v2_runtime_tmp_root=$(mktemp -d "$opencode_v2_runtime_tmp_base/opencode-v2-runner.XXXXXX") || return 1
  chmod 700 "$opencode_v2_runtime_tmp_root" || return 1
  opencode_v2_runtime_fifo="$opencode_v2_runtime_tmp_root/server-output"
  opencode_v2_runtime_port_file="$opencode_v2_runtime_tmp_root/server-port"
  mkfifo "$opencode_v2_runtime_fifo" || return 1

  (opencode_v2_runtime_server_output) &
  opencode_v2_runtime_reader_pid=$!
  opencode_v2_runtime_reader_start=$(opencode_v2_runtime_proc_start_time "$opencode_v2_runtime_reader_pid")
  case "$opencode_v2_runtime_reader_start" in
    ''|*[!0-9]*) opencode_v2_runtime_error 'No se pudo verificar el proceso lector del servidor.'; return 1 ;;
  esac
  opencode_v2_runtime_write_owner run "$$" "$opencode_v2_runtime_owner_start" '' '' \
    "$opencode_v2_runtime_reader_pid" "$opencode_v2_runtime_reader_start" '' '' || return 1
  if [ -n "$opencode_v2_runtime_loader" ]; then
    OPENCODE_PASSWORD="$opencode_v2_runtime_password" "$opencode_v2_runtime_loader" \
      --library-path "$opencode_v2_runtime_library_path" "$opencode_v2_runtime_binary" \
      serve --hostname 127.0.0.1 --port 0 > "$opencode_v2_runtime_fifo" 2>&1 &
  else
    OPENCODE_PASSWORD="$opencode_v2_runtime_password" "$opencode_v2_runtime_binary" \
      serve --hostname 127.0.0.1 --port 0 > "$opencode_v2_runtime_fifo" 2>&1 &
  fi
  opencode_v2_runtime_server_pid=$!
  opencode_v2_runtime_server_start=$(opencode_v2_runtime_proc_start_time "$opencode_v2_runtime_server_pid")
  case "$opencode_v2_runtime_server_start" in
    ''|*[!0-9]*) opencode_v2_runtime_error 'No se pudo verificar la identidad del servidor privado.'; return 1 ;;
  esac
  opencode_v2_runtime_write_owner run "$$" "$opencode_v2_runtime_owner_start" \
    "$opencode_v2_runtime_server_pid" "$opencode_v2_runtime_server_start" \
    "$opencode_v2_runtime_reader_pid" "$opencode_v2_runtime_reader_start" '' '' || return 1

  opencode_v2_runtime_attempt=0
  while [ "$opencode_v2_runtime_attempt" -lt 20 ] && [ ! -s "$opencode_v2_runtime_port_file" ]; do
    if ! opencode_v2_runtime_process_matches "$opencode_v2_runtime_server_pid" "$opencode_v2_runtime_server_start"; then
      opencode_v2_runtime_error 'El servidor privado terminó antes de informar el puerto.'
      return 1
    fi
    sleep 1
    opencode_v2_runtime_attempt=$((opencode_v2_runtime_attempt + 1))
  done
  [ -s "$opencode_v2_runtime_port_file" ] || {
    opencode_v2_runtime_error 'El servidor privado no informó un puerto dentro del tiempo permitido.'
    return 1
  }
  opencode_v2_runtime_port=$(cat "$opencode_v2_runtime_port_file")
  opencode_v2_runtime_check_health || return 1

  opencode_v2_runtime_launch_client true "$@"
}

opencode_v2_runtime() {
  case "${1:-}" in
    run)
      shift
      opencode_v2_runtime_run "$@"
      ;;
    status)
      [ "$#" -eq 1 ] || { opencode_v2_runtime_error 'status no recibe argumentos.'; return 2; }
      opencode_v2_runtime_status
      ;;
    rollback)
      [ "$#" -eq 1 ] || { opencode_v2_runtime_error 'rollback no recibe argumentos.'; return 2; }
      opencode_v2_runtime_rollback
      ;;
    transaction)
      [ "$#" -eq 2 ] || { opencode_v2_runtime_error 'transaction requiere una fase.'; return 2; }
      shift
      opencode_v2_runtime_transaction "$1"
      ;;
    evaluate)
      shift
      opencode_v2_runtime_evaluate "$@"
      ;;
    *)
      opencode_v2_runtime_run "$@"
      ;;
  esac
}

if [ "${0##*/}" = 'opencode-v2-runtime.sh' ]; then
  set -eu
  opencode_v2_runtime "$@"
fi
