#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/check-leader.pid"
trap '' TERM
( trap '' TERM; exec /bin/sleep 300 ) &
printf '%s\n' "$!" > "$FM_HOME/state/check-child.pid"
wait
printf 'must-not-complete\n'
