# BASH_ENV shim for measurement only: log every non-interactive bash start,
# then load the fixture wrapper under test (if any).
printf '%s %s %s\n' "$$" "$PPID" "${0##*/} $*" >> "$FM_TALLY_LOG"
if test -n "${FM_TALLY_WRAP:-}"; then . "$FM_TALLY_WRAP"; fi
