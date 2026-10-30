#!/usr/bin/env bash
# Run the real bin/fm-teardown.sh from <code-root> on fixture <F>, and print a
# transcript: both pool folders' lease state before/after (real Treehouse state
# files), every treehouse call, exit code, stderr, and whether the record left.
# Usage: live-run.sh <F> <code-root> <label> [teardown args...]
set -u
F=$1 CODE=$2 LABEL=$3; shift 3
. "$F/env"; . "$F/paths"
leases() { for d in "$POOL_A" "$POOL_B"; do printf '  %s: ' "${d##*/}"; jq -c '[.worktrees[] | "\(.name)=\(if .leased == true then "leased:" + .lease_holder else "free" end)"]' "$d/treehouse-state.json"; done; }
echo "################ $LABEL"
echo "code root: $CODE"
echo "record copy: $REC"
echo "treehouse pool-dir (current pool): $(cd "$P" && "$(command -v treehouse)" pool-dir 2>/dev/null)"
: > "$F/treehouse.log"
echo "-- lease state BEFORE"; leases
shasum -a 256 "$POOL_A/treehouse-state.json" "$POOL_B/treehouse-state.json" | sed 's/^/  sha256 /'
(cd "$REC" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256; git rev-parse HEAD; git symbolic-ref -q HEAD; git status --porcelain=v1 -uall) 2>/dev/null | shasum -a 256 | sed 's/^/  sha256 record copy snapshot: /'
jq -c '.worktrees[] | select(.name=="1" or .name=="3")' "$POOL_B/treehouse-state.json" > "$F/b13.before"
rc=0
(cd "$F" && "$CODE/bin/fm-teardown.sh" task-live "$@") > "$F/out.$LABEL" 2> "$F/err.$LABEL" || rc=$?
echo "-- exit code: $rc"
echo "-- treehouse calls made by teardown:"; sed 's/^/  treehouse /' "$F/treehouse.log"
echo "-- lease state AFTER"; leases
shasum -a 256 "$POOL_A/treehouse-state.json" "$POOL_B/treehouse-state.json" | sed 's/^/  sha256 /'
(cd "$REC" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256; git rev-parse HEAD; git symbolic-ref -q HEAD; git status --porcelain=v1 -uall) 2>/dev/null | shasum -a 256 | sed 's/^/  sha256 record copy snapshot: /'
if jq -c '.worktrees[] | select(.name=="1" or .name=="3")' "$POOL_B/treehouse-state.json" | cmp -s "$F/b13.before" -; then
  echo "  current-pool slots 1 (other-task) and 3 (this task, other name): byte-identical"
else
  echo "  current-pool slots 1 / 3: CHANGED"
fi
echo "-- task record: $([ -e "$FM_HOME/state/task-live.meta" ] && echo present || echo removed)"
echo "-- record copy dir: $([ -d "$REC" ] && echo "present ($(git -C "$REC" status --porcelain | wc -l | tr -d ' ') dirty entries, HEAD $(git -C "$REC" rev-parse --short HEAD 2>/dev/null))" || echo absent)"
echo "-- teardown stderr (key lines):"; grep -E 'REFUSED|warning|teardown:|Error|leased|refus' "$F/err.$LABEL" | head -25 | sed 's/^/  /'
echo
