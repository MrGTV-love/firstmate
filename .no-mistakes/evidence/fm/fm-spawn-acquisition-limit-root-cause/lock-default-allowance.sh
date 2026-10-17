#!/usr/bin/env bash
# Drive the real fm_project_lock_acquire with its DEFAULT stall allowance (no FM_PROJECT_LOCK_SERVICE_SECS).
# The holder's stall clock starts at the mtime of <lock>/role, so backdating that file puts the holder
# at a chosen age without waiting: 400s old is inside 490s but past the old 370s; 500s is past both.
set -u
ROOT=${1:?worktree}
CASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lock-allow.XXXXXX")
trap 'touch "$CASE/release"; sleep 0.5; kill "$HOLDER" 2>/dev/null; rm -rf "$CASE"' EXIT
export FM_HOME="$CASE/home" FM_STATE_OVERRIDE=''
mkdir -p "$FM_HOME"
env -u FM_PROJECT_LOCK_SERVICE_SECS bash -c '
  . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-project-lock-lib.sh"
  fm_project_lock_acquire "$2/p.lock" holder-op || exit 1
  : > "$2/held"
  while [ ! -e "$2/release" ]; do sleep 0.1; done
  fm_project_lock_release "$2/p.lock"
' _ "$ROOT" "$CASE" &
HOLDER=$!
for _ in $(seq 1 100); do [ -e "$CASE/held" ] && break; sleep 0.1; done
[ -e "$CASE/held" ] || { echo "holder did not start"; exit 2; }
for age in 400 500; do
  stamp=$(date -v-"${age}"S +%Y%m%d%H%M.%S)
  touch -t "$stamp" "$CASE/p.lock/role"
  echo "=== holder aged ${age}s; waiter uses the default allowance"
  out=$(env -u FM_PROJECT_LOCK_SERVICE_SECS timeout 6 bash -c '
    . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-project-lock-lib.sh"
    fm_project_lock_acquire "$2/p.lock" waiter-op; echo "waiter rc=$?"
  ' _ "$ROOT" "$CASE" 2>&1)
  rc=$?
  printf '%s\n' "$out" | sed "s#$CASE#<case>#g"
  echo "(timeout rc=$rc; 124 means the waiter was still waiting when killed)"
done
