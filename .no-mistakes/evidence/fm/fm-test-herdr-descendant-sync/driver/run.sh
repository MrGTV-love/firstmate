#!/usr/bin/env bash
# run.sh <old|new> [sh-start-delay-seconds]: run only the two changed cases from that version of the file.
EV=$(cd "$(dirname "$0")" && pwd)
v=$1; delay=${2:-0}
. "$EV/$v.defs.sh"
[ "$delay" = 0 ] || { export FM_SLOW_SH_DELAY=$delay; PATH="$EV/slowsh:$PATH"; }
rc=0
for t in test_registered_agent_with_an_agent_descendant_outside_the_foreground_stays_alive test_agent_descendant_under_a_spaced_install_path_stays_alive; do
  start=$(date +%s)
  ( "$t" ) || rc=1
  echo "  ($t took $(( $(date +%s) - start ))s)"
done
exit $rc
