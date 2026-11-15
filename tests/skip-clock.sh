# BASH_ENV file for the spawn cases that need a controlled clock (tests/fm-spawn-pool-base-freshen.test.sh).
# It is a static file so a helper-level case can load the same seam and prove it fires (tests/fm-spawn-slot-move.test.sh).
# Variables: FM_TEST_TICK_SECONDS, FM_TEST_MKDIR_JUMP(_PATH), FM_TEST_JUMP_AT_ACCEPT, FM_TEST_JUMP_AT_SCAN, and
# FM_TEST_JUMP_MARK (a file created whenever a jump fires, so a case can assert the seam ran).
sleep() {
  if [ "${1:-}" = 1 ] && [ -n "${FM_TEST_TICK_SECONDS:-}" ]; then
    SECONDS=$((SECONDS + FM_TEST_TICK_SECONDS))
  fi
  command sleep "$@"
}
# The spawn creates its task data folder while it records a skipped copy, between two gets. A jump there spends the
# bound after one copy was accepted and before the next get is typed.
mkdir() {
  if [ -n "${FM_TEST_MKDIR_JUMP_PATH:-}" ] && [ "${2:-}" = "$FM_TEST_MKDIR_JUMP_PATH" ]; then
    SECONDS=$((SECONDS + ${FM_TEST_MKDIR_JUMP:-0}))
  fi
  command mkdir "$@"
}
# A clock jump at the moment a copy is about to be accepted: the spawn's own DEBUG hook sets SECONDS to
# <spawn start> + FM_TEST_JUMP_AT_ACCEPT on the second pass over the line that reads the accepted copy's real path
# (the pass that would accept it). Nothing in the spawn is changed to make this possible.
__fm_accept_seen=0
__fm_clock_jump() {
  case "$BASH_COMMAND" in
    'p_real=$(real_path_or_raw "$p")')
      __fm_accept_seen=$((__fm_accept_seen + 1))
      if [ -n "${FM_TEST_JUMP_AT_ACCEPT:-}" ] && [ "$__fm_accept_seen" = 2 ] && [ -n "${SPAWN_ACQUIRE_T0:-}" ]; then
        SECONDS=$((SPAWN_ACQUIRE_T0 + FM_TEST_JUMP_AT_ACCEPT))
        : > "${FM_TEST_JUMP_MARK:-/dev/null}"
      fi ;;
    # The custody scan that runs before every get: a jump here is time spent in the scan, between the two bound reads.
    # BASH_COMMAND holds the simple command being run, never the "cmd || exit 1" list around it, so the pattern is the
    # command alone. The DEBUG trap runs before the command: this is the custody scan between the two bound reads.
    'fm_task_copy_pool_slots_hold_no_current_copy "$PROJ_ABS" "$STATE"')
      if [ -n "${FM_TEST_JUMP_AT_SCAN:-}" ] && [ -n "${SPAWN_ACQUIRE_T0:-}" ]; then
        SECONDS=$((SPAWN_ACQUIRE_T0 + FM_TEST_JUMP_AT_SCAN))
        : > "${FM_TEST_JUMP_MARK:-/dev/null}"
      fi ;;
  esac
  return 0
}
if [ -n "${FM_TEST_JUMP_AT_ACCEPT:-}" ] || [ -n "${FM_TEST_JUMP_AT_SCAN:-}" ]; then
  set -T
  trap '__fm_clock_jump' DEBUG
fi