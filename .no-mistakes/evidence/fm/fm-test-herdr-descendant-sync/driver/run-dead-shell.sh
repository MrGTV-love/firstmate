#!/usr/bin/env bash
# The agent binary is missing, so the shell exits at once and no `pi` child ever appears.
# The wait must end with the named failure, not spin forever.
EV=$(cd "$(dirname "$0")" && pwd)
. "$EV/new.defs.sh"
fm_agent_standin() { printf '%s\n' "$TMP_ROOT/no-such-standin"; }
for t in test_registered_agent_with_an_agent_descendant_outside_the_foreground_stays_alive test_agent_descendant_under_a_spaced_install_path_stays_alive; do
  start=$(date +%s)
  ( "$t" ); rc=$?
  echo "  ($t exit=$rc after $(( $(date +%s) - start ))s)"
done
