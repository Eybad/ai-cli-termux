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

opencode_v2_runtime_proc_start_time() {
  awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null
}

opencode_v2_runtime_process_matches() {
  [ -n "$1" ] && [ -n "$2" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  [ "$(opencode_v2_runtime_proc_start_time "$1")" = "$2" ]
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
  if [ -L "$1" ]; then
    opencode_v2_runtime_error "La ruta privada es un symlink: $1"
    return 1
  fi
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

  unset OPENCODE_CONFIG OPENCODE_CONFIG_DIR OPENCODE_CONFIG_CONTENT OPENCODE_TUI_CONFIG
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
  if [ -n "${opencode_v2_runtime_client_pid:-}" ] &&
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

  case "${1:-}" in
    --version|-v|help)
      opencode_v2_runtime_launch "$@"
      return
      ;;
    serve|service)
      opencode_v2_runtime_error 'El servidor persistente no está habilitado; el wrapper administra un servidor efímero.'
      return 1
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
    status|rollback|evaluate|transaction)
      opencode_v2_runtime_error "La operación '$1' todavía no está disponible."
      return 2
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
