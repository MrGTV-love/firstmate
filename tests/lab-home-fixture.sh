#!/usr/bin/env bash
# tests/lab-home-fixture.sh - the shared marked lab-home fixture.
#
# Source it, then call fm_test_lab_home <dir> where a fixture home is created,
# before anything is written into it:
#   # shellcheck source=tests/lab-home-fixture.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lab-home-fixture.sh"
#
# The suite runs the real gate-lifecycle check (bin/fm-gate-refuse-lib.sh) with
# no bypass. Outside a no-mistakes gate that check finds no gate signal; inside
# one it admits a fleet call only against a marked lab home whose overrides stay
# inside it. This fixture marks an absent or empty <dir> through the gate
# library's own fm_gate_lab_mark, which refuses a populated directory, and adds
# the stock state/config/data/projects layout. Callers must pass FM_HOME as the
# directory's physical path, because the check compares it with pwd -P.
# It records no owner on purpose: the test's own temp root owns the directory,
# so bin/fm-test-reap-orphans.sh must not reap it as a separate lab.
# tests/lib.sh sources this for every suite that uses it; a suite that sources
# neither tests/lib.sh nor tests/herdr-test-safety.sh sources it directly.

fm_test_lab_home() {  # <dir>
  local lab_home=$1 lab_root
  lab_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || return 1
  mkdir -p "$lab_home" || return 1
  (
    # shellcheck source=bin/fm-gate-refuse-lib.sh
    . "$lab_root/bin/fm-gate-refuse-lib.sh"
    fm_gate_lab_mark "$lab_home"
  ) || return 1
  mkdir -p "$lab_home/state" "$lab_home/config" "$lab_home/data" "$lab_home/projects"
}
