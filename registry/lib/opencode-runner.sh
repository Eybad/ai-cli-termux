#!/bin/sh
# shellcheck shell=sh disable=SC2329
set -eu

TMPDIR="${TMPDIR:-${PREFIX:-/data/data/com.termux/files/usr}/tmp}"
export TMPDIR
if [ ! -d "$TMPDIR" ] || [ ! -w "$TMPDIR" ]; then
  printf 'ERROR: TMPDIR is not a writable directory: %s\n' "$TMPDIR" >&2
  exit 1
fi
export MALLOC_ARENA_MAX="${MALLOC_ARENA_MAX:-2}"

loader=""
rpath=""
binary=""

if [ $# -ge 4 ] && [ "$2" = "--library-path" ]; then
  loader="$1"
  rpath="$3"
  binary="$4"
  shift 4
elif [ $# -ge 1 ]; then
  binary="$1"
  shift 1
else
  printf 'ERROR: Insufficient arguments for opencode-runner.sh\n' >&2
  exit 1
fi

case "$binary" in
  /*) ;;
  *)
    printf 'ERROR: Binary path must be absolute: %s\n' "$binary" >&2
    exit 1
    ;;
esac

if [ ! -f "$binary" ] || [ ! -x "$binary" ]; then
  printf 'ERROR: Binary does not exist or is not executable: %s\n' "$binary" >&2
  exit 1
fi

if [ -n "$loader" ]; then
  case "$loader" in
    /*) ;;
    *)
      printf 'ERROR: Loader path must be absolute: %s\n' "$loader" >&2
      exit 1
      ;;
  esac
  if [ ! -f "$loader" ] || [ ! -x "$loader" ]; then
    printf 'ERROR: Loader does not exist or is not executable: %s\n' "$loader" >&2
    exit 1
  fi
fi

in_options=1
skip_next=0
first_positional=""
second_positional=""
is_exec_direct=0

for arg in "$@"; do
  if [ "$in_options" -eq 1 ]; then
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    if [ "$arg" = "--" ]; then
      in_options=0
      continue
    fi
    case "$arg" in
      --server=*|--completions=*)
        is_exec_direct=1
        continue
        ;;
      --server|--completions)
        is_exec_direct=1
        skip_next=1
        continue
        ;;
      -s|--session|--prompt|--log-level|-m|--model|--agent|--format|-f|--file|--title|-d|--data|-H|--header|--param|--hostname|--port|--cors)
        skip_next=1
        continue
        ;;
      --session=*|--prompt=*|--log-level=*|--model=*|--agent=*|--format=*|--file=*|--title=*|--data=*|--header=*|--param=*|--hostname=*|--port=*|--cors=*)
        continue
        ;;
      -h|--help|-v|--version)
        is_exec_direct=1
        continue
        ;;
      --standalone)
        continue
        ;;
      -*)
        continue
        ;;
      *)
        if [ -z "$first_positional" ]; then
          first_positional="$arg"
        elif [ -z "$second_positional" ]; then
          second_positional="$arg"
        fi
        ;;
    esac
  fi
done

if [ "$first_positional" = "help" ] || [ "$first_positional" = "serve" ]; then
  is_exec_direct=1
elif [ "$first_positional" = "debug" ] && [ "$second_positional" = "paths" ]; then
  is_exec_direct=1
elif [ "$first_positional" = "mcp" ] && [ "$second_positional" = "add" ]; then
  is_exec_direct=1
fi

case "$first_positional" in
  upgrade|update)
    printf 'ERROR: Internal updater is disabled on Termux. Use: aicli update opencode\n' >&2
    exit 1
    ;;
  uninstall)
    printf 'ERROR: Uninstallation on Termux is managed with aicli. Use: aicli remove opencode\n' >&2
    exit 1
    ;;
  service)
    printf "ERROR: Background daemon ('opencode service') is not supported by Termux glibc loader. Run 'opencode' directly or use 'opencode serve' with 'opencode --server <url>'.\n" >&2
    exit 1
    ;;
esac

if [ -n "$loader" ]; then
  exec_binary() {
    exec "$loader" --library-path "$rpath" "$binary" "$@"
  }
else
  exec_binary() {
    exec "$binary" "$@"
  }
fi

if [ "$is_exec_direct" -eq 1 ]; then
  exec_binary "$@"
fi

get_proc_stat() {
  [ -r "/proc/$1/stat" ] || return 1
  { IFS= read -r _stat_line < "/proc/$1/stat"; } 2>/dev/null || return 1
  case "$_stat_line" in
    *") "*) _stat_rest="${_stat_line##*) }" ;;
    *) return 1 ;;
  esac
  _old_ifs="$IFS"
  IFS=' '
  case "$-" in
    *f*) _had_noglob=1 ;;
    *) _had_noglob=0; set -f ;;
  esac
  # Word splitting is intentional for space-delimited /proc/<pid>/stat fields.
  # shellcheck disable=SC2086
  set -- $_stat_rest
  [ "$_had_noglob" -eq 0 ] && set +f
  IFS="$_old_ifs"
  [ $# -ge 20 ] || return 1
  _stat_state="$1"
  _stat_ppid="$2"
  shift 19
  printf '%s %s %s\n' "$_stat_state" "$_stat_ppid" "$1"
}

get_proc_starttime() {
  _stat_out=$(get_proc_stat "$1") || return 1
  printf '%s\n' "${_stat_out##* }"
}

proc_alive_matching() {
  p="$1"
  exp_start="$2"
  [ -n "$p" ] && [ -n "$exp_start" ] || return 1
  act_start=$(get_proc_starttime "$p" || echo "")
  [ "$act_start" = "$exp_start" ]
}

reap_stale_runners() {
  [ -r "/proc/$$/stat" ] || return 0

  for d in "$TMPDIR"/opencode-runner.*; do
    [ -d "$d" ] || continue
    owner_file="$d/owner.env"
    [ -f "$owner_file" ] && [ ! -L "$owner_file" ] || continue

    o_runner_pid=""
    o_runner_start=""
    o_server_pid=""
    o_server_start=""

    while IFS='=' read -r key val || [ -n "$key" ]; do
      case "$key" in
        runner_pid) o_runner_pid="$val" ;;
        runner_start) o_runner_start="$val" ;;
        server_pid) o_server_pid="$val" ;;
        server_start) o_server_start="$val" ;;
      esac
    done < "$owner_file"

    case "$o_runner_pid" in ''|*[!0-9]*) continue ;; esac
    case "$o_runner_start" in ''|*[!0-9]*) continue ;; esac
    case "$o_server_pid" in ''|*[!0-9]*) continue ;; esac
    case "$o_server_start" in ''|*[!0-9]*) continue ;; esac

    [ "$o_runner_pid" -ne "$$" ] || continue

    runner_dead=0
    if ! kill -0 "$o_runner_pid" 2>/dev/null && [ ! -d "/proc/$o_runner_pid" ]; then
      runner_dead=1
    elif [ -r "/proc/$o_runner_pid/stat" ]; then
      cur_runner_start=$(get_proc_starttime "$o_runner_pid" || echo "")
      if [ -n "$cur_runner_start" ] && [ "$cur_runner_start" != "$o_runner_start" ]; then
        runner_dead=1
      fi
    fi
    [ "$runner_dead" -eq 1 ] || continue

    if ! kill -0 "$o_server_pid" 2>/dev/null && [ ! -d "/proc/$o_server_pid" ]; then
      rm -rf "$d"
      continue
    fi

    s_stat=$(get_proc_stat "$o_server_pid" || echo "")
    if [ -z "$s_stat" ]; then
      if ! kill -0 "$o_server_pid" 2>/dev/null && [ ! -d "/proc/$o_server_pid" ]; then
        rm -rf "$d"
      fi
      continue
    fi

    s_state="${s_stat%% *}"
    _s_tail="${s_stat#* }"
    s_ppid="${_s_tail%% *}"
    s_start="${_s_tail#* }"

    [ "$s_ppid" != "$o_runner_pid" ] || continue
    [ "$s_start" = "$o_server_start" ] || continue
    [ "$s_state" != "Z" ] && [ "$s_state" != "X" ] || continue

    [ -r "/proc/$o_server_pid/cmdline" ] || continue
    cmd_text=$(tr '\0' ' ' < "/proc/$o_server_pid/cmdline" 2>/dev/null || echo "")
    case "$cmd_text" in
      *"$binary"*"serve"*"--hostname"*"127.0.0.1"*"--port"*"0"*) ;;
      *) continue ;;
    esac

    kill -TERM "$o_server_pid" 2>/dev/null || true

    i=0
    server_stopped=0
    while [ "$i" -lt 10 ]; do
      if ! kill -0 "$o_server_pid" 2>/dev/null && [ ! -d "/proc/$o_server_pid" ]; then
        server_stopped=1
        break
      fi
      sleep 0.1 2>/dev/null || sleep 1
      i=$((i + 1))
    done

    if [ "$server_stopped" -eq 1 ]; then
      rm -rf "$d"
    else
      printf 'WARN: Failed to terminate orphaned server (PID %s) after SIGTERM in %s\n' "$o_server_pid" "$d" >&2
    fi
  done
}

reap_stale_runners

num_args=$#
seen_dash=0
while [ "$num_args" -gt 0 ]; do
  arg="$1"
  shift
  num_args=$((num_args - 1))
  if [ "$seen_dash" -eq 0 ]; then
    if [ "$arg" = "--" ]; then
      seen_dash=1
      set -- "$@" "$arg"
    elif [ "$arg" = "--standalone" ]; then
      :
    else
      set -- "$@" "$arg"
    fi
  else
    set -- "$@" "$arg"
  fi
done

runner_tmp=""
server_pid=""
server_start=""
client_pid=""
client_start=""
exit_code=0

cleanup() {
  trap '' EXIT HUP INT TERM
  if [ -n "$server_pid" ] && [ -n "$server_start" ]; then
    if proc_alive_matching "$server_pid" "$server_start"; then
      kill -TERM "$server_pid" 2>/dev/null || true
      i=0
      while [ "$i" -lt 10 ]; do
        if ! kill -0 "$server_pid" 2>/dev/null && [ ! -d "/proc/$server_pid" ]; then
          break
        fi
        sleep 0.1 2>/dev/null || sleep 1
        i=$((i + 1))
      done
      if kill -0 "$server_pid" 2>/dev/null; then
        kill -KILL "$server_pid" 2>/dev/null || true
      fi
      wait "$server_pid" 2>/dev/null || true
    fi
  fi

  if [ -n "$client_pid" ] && [ -n "$client_start" ]; then
    if proc_alive_matching "$client_pid" "$client_start"; then
      kill -TERM "$client_pid" 2>/dev/null || true
      if kill -0 "$client_pid" 2>/dev/null; then
        kill -KILL "$client_pid" 2>/dev/null || true
      fi
      wait "$client_pid" 2>/dev/null || true
    fi
  fi

  if [ -n "$runner_tmp" ] && [ -d "$runner_tmp" ]; then
    rm -rf "$runner_tmp"
  fi

  exit "$exit_code"
}

on_signal() {
  case "$1" in
    HUP) exit_code=129 ;;
    INT) exit_code=130 ;;
    TERM) exit_code=143 ;;
    *) exit_code=1 ;;
  esac
  cleanup
}

old_umask=$(umask)
umask 077
runner_tmp=$(mktemp -d "$TMPDIR/opencode-runner.XXXXXX")
umask "$old_umask"

trap 'cleanup' EXIT
trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

if [ -n "$loader" ]; then
  env -u OPENCODE_PASSWORD -u OPENCODE_SERVER_PASSWORD \
    "$loader" --library-path "$rpath" "$binary" serve --hostname 127.0.0.1 --port 0 >"$runner_tmp/server.log" 2>&1 </dev/null &
else
  env -u OPENCODE_PASSWORD -u OPENCODE_SERVER_PASSWORD \
    "$binary" serve --hostname 127.0.0.1 --port 0 >"$runner_tmp/server.log" 2>&1 </dev/null &
fi
server_pid=$!
server_start=$(get_proc_starttime "$server_pid" || echo "")

runner_pid=$$
runner_start=$(get_proc_starttime "$$" || echo "")

cat > "$runner_tmp/owner.env.tmp" <<EOF
runner_pid=$runner_pid
runner_start=$runner_start
server_pid=$server_pid
server_start=$server_start
EOF
mv "$runner_tmp/owner.env.tmp" "$runner_tmp/owner.env"

port=""
pw=""
poll_count=0
while [ "$poll_count" -lt 150 ]; do
  if ! kill -0 "$server_pid" 2>/dev/null && [ ! -d "/proc/$server_pid" ]; then
    printf 'ERROR: OpenCode server exited prematurely:\n' >&2
    if [ -f "$runner_tmp/server.log" ]; then
      grep -v '^server password ' "$runner_tmp/server.log" | tail -n 20 >&2 || true
    fi
    exit_code=1
    exit 1
  fi

  if [ -s "$runner_tmp/server.log" ]; then
    port=""
    pw=""
    while IFS= read -r _log_line || [ -n "$_log_line" ]; do
      case "$_log_line" in
        'server listening on http://127.0.0.1:'*)
          _cand_port="${_log_line#'server listening on http://127.0.0.1:'}"
          case "$_cand_port" in
            ''|*[!0-9]*) ;;
            *) port="$_cand_port" ;;
          esac
          ;;
        'server password '*)
          pw="${_log_line#'server password '}"
          ;;
      esac
    done < "$runner_tmp/server.log"
    if [ -n "$port" ] && [ -n "$pw" ]; then
      break
    fi
  fi

  sleep 0.1 2>/dev/null || sleep 1
  poll_count=$((poll_count + 1))
done

if [ -z "$port" ] || [ -z "$pw" ]; then
  printf 'ERROR: Timeout waiting for OpenCode server startup:\n' >&2
  if [ -f "$runner_tmp/server.log" ]; then
    grep -v '^server password ' "$runner_tmp/server.log" | tail -n 20 >&2 || true
  fi
  exit_code=1
  exit 1
fi

expected_version=""
manifest_file="${binary%/*}/manifest.txt"
if [ -f "$manifest_file" ]; then
  while IFS='=' read -r _mkey _mval || [ -n "$_mkey" ]; do
    if [ "$_mkey" = "version" ]; then
      while [ "${_mval#v}" != "$_mval" ]; do
        _mval="${_mval#v}"
      done
      expected_version="${_mval%%[!0-9.]*}"
      break
    fi
  done < "$manifest_file"
fi

info_json=$(printf 'user = "opencode:%s"\n' "$pw" | curl -sS -f --config - "http://127.0.0.1:$port/api/info") || {
  printf 'ERROR: HTTP validation of /api/info failed on OpenCode server.\n' >&2
  exit_code=1
  exit 1
}

printf '%s' "$info_json" | jq -e --arg v "$expected_version" --argjson p "$server_pid" '($v == "" or .version == $v) and .pid == $p' >/dev/null || {
  printf 'ERROR: /api/info does not match server version or PID.\n' >&2
  exit_code=1
  exit 1
}

rm -f "$runner_tmp/server.log"

exec 3<&0
if [ -n "$loader" ]; then
  OPENCODE_PASSWORD="$pw" env -u OPENCODE_SERVER_PASSWORD \
    "$loader" --library-path "$rpath" "$binary" --server "http://127.0.0.1:$port" "$@" 0<&3 3<&- &
else
  OPENCODE_PASSWORD="$pw" env -u OPENCODE_SERVER_PASSWORD \
    "$binary" --server "http://127.0.0.1:$port" "$@" 0<&3 3<&- &
fi
client_pid=$!
client_start=$(get_proc_starttime "$client_pid" || echo "")
exec 3<&-

if [ -t 0 ] && [ -t 1 ]; then
  trap '' INT
fi

set +e
wait "$client_pid"
client_exit=$?
set -e
exit_code=$client_exit
exit "$exit_code"
