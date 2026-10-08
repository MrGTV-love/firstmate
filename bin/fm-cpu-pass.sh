#!/usr/bin/env bash
# fm-cpu-pass.sh - Host-wide CPU pass pool for CPU-heavy test bursts; see engine --help.
# docs/cpu-pass-pool.md owns the cross-repository contract.
# The engine header owns command behavior, including the no-Python run path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1 && [ "${1:-}" = run ]; then
  shift
  log_fd=2
  passes=1
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    case "$1" in
      --passes|--label|--log-fd)
        if [ "$#" -lt 2 ]; then
          echo "fm-cpu-pass: $1 needs a value" >&2
          exit 125
        fi
        case "$1" in
          --passes) passes=$2 ;;
          --log-fd) log_fd=$2 ;;
        esac
        shift ;;
      --passes=*) passes=${1#--passes=} ;;
      --label=*) ;;
      --log-fd=*) log_fd=${1#--log-fd=} ;;
      --*) exit 125 ;;
      *) break ;;
    esac
    shift
  done
  case "$log_fd" in ''|*[!0-9]*) log_fd=2 ;; esac
  if ! [[ "$passes" =~ ^[0-9]+$ ]]; then
    echo "fm-cpu-pass: --passes must be a positive integer" >&2
    exit 125
  fi
  while [ "${passes#0}" != "$passes" ]; do passes=${passes#0}; done
  if [ -z "$passes" ]; then
    echo "fm-cpu-pass: --passes must be positive" >&2
    exit 125
  fi
  size=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || true)
  if [[ "$size" =~ ^[1-9][0-9]*$ ]] && {
    [ "${#passes}" -gt "${#size}" ] ||
      { [ "${#passes}" -eq "${#size}" ] && (( 10#$passes > size )); }
  }; then
    echo "fm-cpu-pass: --passes must not exceed the pool size ($size)" >&2
    exit 125
  fi
  if [ "${1:-}" = -- ]; then shift; fi
  if [ "$#" -eq 0 ]; then
    echo "fm-cpu-pass: run needs a command after --" >&2
    exit 125
  fi
  if [ -n "${FM_CPU_PASS_HELD+x}" ]; then
    held=$FM_CPU_PASS_HELD
    case "$held" in
      ''|*[!0-9]*)
        echo "fm-cpu-pass: FM_CPU_PASS_HELD must be a nonnegative decimal integer" >&2
        exit 125 ;;
    esac
    while [ "${held#0}" != "$held" ]; do held=${held#0}; done
    if [ -n "$held" ] && {
      [ "${#passes}" -gt "${#held}" ] ||
        { [ "${#passes}" -eq "${#held}" ] && [[ "x$passes" > "x$held" ]]; }
    }; then
      echo "fm-cpu-pass: --passes must not exceed FM_CPU_PASS_HELD ($held)" >&2
      exit 125
    fi
    exec "$@"
  fi
  { echo "fm-cpu-pass: running $1 without a CPU pass: python3 not found"; } >&"$log_fd" 2>/dev/null || true
  export FM_CPU_PASS_HELD=0
  exec "$@"
fi

exec python3 "$SCRIPT_DIR/fm-cpu-pass.py" "$@"
