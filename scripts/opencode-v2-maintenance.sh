#!/bin/sh

set -eu

usage() {
  printf '%s\n' \
    'Uso: sh scripts/opencode-v2-maintenance.sh evaluate --version <v2.x.y>' \
    '     sh scripts/opencode-v2-maintenance.sh status' \
    '     sh scripts/opencode-v2-maintenance.sh rollback' >&2
}

script_dir=$(CDPATH='' cd -P -- "$(dirname -- "$0")" && pwd)
project_root=${script_dir%/scripts}
. "$project_root/registry/lib/opencode-v2-runtime.sh"
opencode_v2_runtime_project_root=$project_root

case "${1:-}" in
  evaluate)
    [ "$#" -eq 3 ] && [ "$2" = --version ] || { usage; exit 2; }
    ;;
  status|rollback)
    [ "$#" -eq 1 ] || { usage; exit 2; }
    ;;
  *)
    usage
    exit 2
    ;;
esac

opencode_v2_runtime "$@"
