# shellcheck shell=bash
# The one owner of the rule that a scenario does not run a fixture home's registered check file (state/slack.check.sh)
# where it could reach a REAL registered Slack check file or check script outside its own fixture (Main 2180, 2191).
# Sourced by tests/fm-slack-watch.test.sh and tests/fm-slack-deadline.test.sh; tested in tests/fm_slack_watch_test.py
# (RegisteredGateTest) with a stub in place of the file.
#
# The harm it judges: a real Slack check run from a host that holds a real registered file. It looks for such a file
# once, when this file is sourced (before a scenario overrides FM_HOME or FM_STATE_OVERRIDE), at the places a scenario
# could reach it: the state directory and the home that this process inherited (FM_STATE_OVERRIDE, FM_HOME), and the
# state directory of the home that this checkout belongs to (the primary working tree of its repository).
#   - FM_SLACK_GRADER_RUN set and not empty (Main or the grader, under a host-level network denial): the run is allowed.
#   - Otherwise, a real registered file found: the run is skipped with a line that names the file.
#   - Otherwise (a CI runner or a clean clone holds none): the run is allowed.
# fm_slack_registered_allowed <label>: succeeds, printing nothing, when the run is allowed; otherwise prints one skip
# line naming the label and the file, and fails, and the caller must not run the registered file.
fm_slack_find_real_registered() {
  local here root common primary candidate
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd) || return 0
  root=$(cd "$here/../../.." && pwd) || return 0
  primary=''
  if common=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null); then
    case $common in /*) ;; *) common=$root/$common ;; esac
    primary=$(cd "$common/.." 2>/dev/null && pwd) || primary=''
  fi
  for candidate in "${FM_STATE_OVERRIDE:-}" "${FM_HOME:+$FM_HOME/state}" "$root/state" "${primary:+$primary/state}"; do
    if [ -n "$candidate" ] && [ -e "$candidate/slack.check.sh" ]; then
      printf '%s\n' "$candidate/slack.check.sh"
      return 0
    fi
  done
}
FM_SLACK_REAL_REGISTERED=$(fm_slack_find_real_registered)

fm_slack_registered_allowed() {
  if [ -n "${FM_SLACK_GRADER_RUN:-}" ] || [ -z "$FM_SLACK_REAL_REGISTERED" ]; then
    return 0
  fi
  printf 'skip - %s (a real registered Slack check file exists at %s; Main or the grader runs this under a host-level network denial and sets FM_SLACK_GRADER_RUN)\n' \
    "$1" "$FM_SLACK_REAL_REGISTERED"
  return 1
}
