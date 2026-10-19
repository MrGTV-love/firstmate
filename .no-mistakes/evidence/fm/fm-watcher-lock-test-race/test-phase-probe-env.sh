kill() {
  if [ "${1:-}" = -CONT ] && [ -n "${state:-}" ] \
    && [ -s "$state/beacon-writer-stopped" ] \
    && [ "${2:-}" = "$(cat "$state/beacon-writer-stopped")" ] \
    && [ ! -e "$state/probe-resume-observed" ]; then
    printf '%s\n' observed > "$state/probe-resume-observed"
    builtin kill "$@" || return "$?"
    "$FM_PROBE_BIN/wait-resumed" "$state" "$2"
    return "$?"
  fi
  builtin kill "$@"
}
