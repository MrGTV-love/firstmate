# shellcheck shell=bash
# BASH_ENV file for the spawn cases that must see every call of the slot-owner claim and release (tests/fm-spawn-pool-base-freshen.test.sh).
# With FM_TEST_CLAIM_TRACE=<file>, each call of fm_treehouse_slot_owner_claim or fm_treehouse_slot_owner_release is appended to
# that file as one tab-separated line: the function, then its arguments as the call expanded them. Nothing in the spawn is
# changed. The trace names what the spawn asked those two functions to do, whatever the functions then do to the marker.
__fm_claim_trace() {
  case "$BASH_COMMAND" in
    fm_treehouse_slot_owner_claim\ * | fm_treehouse_slot_owner_release\ *)
      [ -z "${FM_TEST_CLAIM_TRACE:-}" ] || (eval "set -- $BASH_COMMAND"; printf '%s\t' "$@"; echo) >> "$FM_TEST_CLAIM_TRACE" 2>/dev/null
      ;;
  esac
  return 0
}
if [ -n "${FM_TEST_CLAIM_TRACE:-}" ]; then
  set -T
  trap '__fm_claim_trace' DEBUG
fi
