#!/usr/bin/env bash
# Round 2 live lab driver: one fresh fm-lab-home.sh lab per scenario, torn down after.
# Usage: live-lab-driver.sh <fix-root> <base-root>
set -u
E=$(cd "$(dirname "$0")" && pwd) FIX=$1 BASE=$2
lab() {  # <label> <root> <delay> [hang]
  eval "$("$FIX/bin/fm-lab-home.sh" env 2>/dev/null)"
  echo "=== $1 (lab FM_HOME=$FM_HOME) ==="
  bash "$E/live-lab-scenario.sh" "$2" "$3" ${4:-}
  "$FIX/bin/fm-lab-home.sh" teardown "$FM_HOME" && rm -rf "$FM_HOME" && echo "lab torn down"
}
lab "FIX: sources 3s slow (silent, no output, no CPU), default settings, CPU-burn neighbours" "$FIX" 3
lab "BASE: sources 3s slow (silent, no output, no CPU), default settings, CPU-burn neighbours" "$BASE" 3
lab "FIX: sources 15s slow (silent), default settings, CPU-burn neighbours" "$FIX" 15
lab "FIX: terminal capture hangs silently, inactivity bound set to 3s" "$FIX" 0 3
