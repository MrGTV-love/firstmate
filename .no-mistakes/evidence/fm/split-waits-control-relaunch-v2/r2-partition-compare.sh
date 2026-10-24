#!/usr/bin/env bash
# Usage: r2-partition-compare.sh <repo-worktree> <base-ref> <evidence-dir>
# Extracts base and HEAD into temp copies, runs case-dryrun.sh on each suite,
# and compares the set (and multiset) of dispatched case names.
set -u
REPO=$1 BASE=$2 EV=$3
W=$(mktemp -d) B=$(mktemp -d) O=$(mktemp -d)
trap 'rm -rf "$W" "$B" "$O"' EXIT
git -C "$REPO" archive HEAD | tar -x -C "$W"; git -C "$W" init -q
git -C "$REPO" archive "$BASE" | tar -x -C "$B"; git -C "$B" init -q
# The tracer also logs the suite's final top-level call a second time from its
# own '. "$suite"' frame (location case-dryrun.sh:<n>); drop that echo.
dr() { rm -f "$2.log"; ( cd "$1" && CASE_LOG="$2.log" bash "$EV/case-dryrun.sh" "$3" >/dev/null 2>&1 ); awk -F'\t' '$2 !~ /^case-dryrun\.sh:/ {print $1}' "$2.log" | sort > "$2"; }
echo "# Dispatch dry-run (tracer: case-dryrun.sh). base=$(git -C "$REPO" rev-parse --short "$BASE") new=$(git -C "$REPO" rev-parse --short HEAD)"
cmp_family() {
  local orig=$1; shift
  dr "$B" "$O/base" "tests/$orig.test.sh"; cp "$O/base.log" "$O/base-$orig.raw"
  echo "base $orig: $(wc -l <"$O/base" | tr -d ' ') dispatches, $(sort -u "$O/base" | wc -l | tr -d ' ') unique; repeated: [$(uniq -d "$O/base" | tr '\n' ' ')]"
  : >"$O/union"
  for g in "$@"; do
    dr "$W" "$O/new-$g" "tests/$g.test.sh"
    echo "  new $g: $(wc -l <"$O/new-$g" | tr -d ' ') dispatches; repeated: [$(uniq -d "$O/new-$g" | tr '\n' ' ')]"
    cat "$O/new-$g" >>"$O/union"
  done
  sort -o "$O/union" "$O/union"
  echo "  union: $(wc -l <"$O/union" | tr -d ' ') dispatches, $(sort -u "$O/union" | wc -l | tr -d ' ') unique; in more than one dispatch: [$(uniq -d "$O/union" | tr '\n' ' ')]"
  echo "  unique names lost by split: [$(comm -23 <(sort -u "$O/base") <(sort -u "$O/union") | tr '\n' ' ')]"
  echo "  unique names new in groups: [$(comm -13 <(sort -u "$O/base") <(sort -u "$O/union") | tr '\n' ' ')]"
  echo
}
cmp_family fm-control-relaunch fm-control-relaunch fm-control-relaunch-recovery fm-control-relaunch-backends
cmp_family fm-watch-triage-waits fm-watch-triage-waits fm-watch-triage-waits-declared fm-watch-triage-waits-pauses fm-watch-triage-waits-away
