#!/usr/bin/env bash
( trap '' TERM; exec /bin/sleep 120 ) &
printf '%s\n' "$!" > "$FM_HOME/state/check-descendant.pid"
printf 'leader-finished-leaving-descendant\n'
