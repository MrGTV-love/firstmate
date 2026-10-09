# Restore injection after protected /usr/bin/env strips DYLD variables.
# Re-exec is the same process, not another process start.
if [ -z "${DYLD_INSERT_LIBRARIES:-}" ]; then
  export DYLD_INSERT_LIBRARIES="$FM_START_LIB"
  if [ "${BASH_EXECUTION_STRING+x}" = x ]; then
    exec "$FM_START_BASH" -c "$BASH_EXECUTION_STRING" "$0" "$@"
  else
    case "${0##*/}" in
      bash|observed-bash) exec "$FM_START_BASH" -s "$@" ;;
      *) exec "$FM_START_BASH" "$0" "$@" ;;
    esac
  fi
fi
