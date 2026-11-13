#!/usr/bin/env bash
# Command-line entry to bin/fm-copy-env-lib.sh, the one owner of the interpreter
# environment for a script that lives in a task copy or a clone. The library
# header owns the rule, the usable-environment test and the exact environment.
#
# Usage:
#   fm-copy-env.sh check <tree>
#       Exit 0 when <tree> has a usable environment of its own. Otherwise exit 1
#       with the named reason on stderr. Nothing is changed, installed or created.
#   fm-copy-env.sh run <tree> [--python <abs-path>] -- <arg>...
#       Exec <tree>/.venv/bin/python (or the explicit interpreter) with <arg>...
#       in the library's environment. The working directory is unchanged. The
#       process keeps its pid, so a caller that recorded it still owns it. Exit
#       127 with a reason when the interpreter is not executable.
set -u
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-copy-env-lib.sh
. "$SCRIPT_DIR/fm-copy-env-lib.sh"

usage() {
  sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit 2
}

cmd=${1:-}
case "$cmd" in
  check)
    [ "$#" -eq 2 ] || usage
    fm_copy_env_check "$2" || { printf 'error: %s\n' "$FM_COPY_ENV_REASON" >&2; exit 1; }
    ;;
  run)
    [ "$#" -ge 3 ] || usage
    tree=$2
    shift 2
    python=
    if [ "${1:-}" = --python ]; then
      [ "$#" -ge 2 ] || usage
      python=$2
      shift 2
    fi
    [ "${1:-}" = -- ] || usage
    shift
    fm_copy_env_build "$tree" "$python"
    py=${FM_COPY_ENV_CMD[${#FM_COPY_ENV_CMD[@]}-1]}
    if [ ! -x "$py" ]; then
      printf 'error: copy_environment_missing: %s is not an executable file; nothing was changed, installed or created\n' "$py" >&2
      exit 127
    fi
    exec "${FM_COPY_ENV_CMD[@]}" "$@"
    ;;
  *) usage ;;
esac
