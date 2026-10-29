#!/usr/bin/env bash
# End-to-end replay of the #287/#188 stale-base merge, driven through the real
# bin/fm-pr-merge.sh. GitHub is replaced by a disposable local "forge": a real
# git repository (origin) plus a gh wrapper that answers the compare API from
# that repository's real history and performs a real squash merge onto origin's
# main when `gh pr merge` runs. Every other gh read goes to the repository's own
# gh test double (tests/fm-pr-merge-helpers.sh), which supplies the PR view,
# rules, and outcome. The "CI" is a real whole-tree check run on each tree:
# the files under tests/shard1/ must hold at most 10 cases in total (a packing
# target). Each PR adds its own file, so git sees no conflict between them.
# Usage: stale-base-e2e.sh <worktree-root> <base-commit>
set -euo pipefail
WT=$1 BASE_COMMIT=$2
cd "$WT"
# shellcheck source=/dev/null
. "$WT/tests/fm-pr-merge-helpers.sh"
NEW_ROOT=$ROOT NEW_PR_MERGE=$PR_MERGE
OLD_ROOT="$TMP_ROOT/old-tree"
mkdir -p "$OLD_ROOT"
git -C "$WT" archive "$BASE_COMMIT" | tar -x -C "$OLD_ROOT"

ORIGIN="$TMP_ROOT/origin"
git init -q -b main "$ORIGIN"
g() { git -C "$ORIGIN" "$@"; }
LIMIT=10
whole_tree_check() {  # <rev> -> prints SUCCESS/FAILURE and the count
  local n
  n=$(g ls-tree --name-only "$1" tests/shard1/ | while read -r f; do g show "$1:$f"; done | grep -c .)
  if [ "$n" -le "$LIMIT" ]; then echo "SUCCESS $n"; else echo "FAILURE $n"; fi
}
mkdir -p "$ORIGIN/tests/shard1"
for i in 1 2 3 4 5 6 7; do echo "case-$i"; done > "$ORIGIN/tests/shard1/base.list"
g add -A; g commit -q -m 'T0: main with 7 serial cases'
T0=$(g rev-parse main)
g checkout -q -b pr-287 "$T0"; printf 'case-287a\ncase-287b\n' > "$ORIGIN/tests/shard1/287.list"; g add -A; g commit -qm '#287 adds 2 cases'
g checkout -q -b pr-188 "$T0"; printf 'case-188a\ncase-188b\n' > "$ORIGIN/tests/shard1/188.list"; g add -A; g commit -qm '#188 adds 2 cases'
g checkout -q main
H287=$(g rev-parse pr-287) H188=$(g rev-parse pr-188)

say() { printf '\n===== %s =====\n' "$*"; }
# Run the real fm-pr-merge.sh for one PR head against the local forge.
# Args: label root head pr_number [merge args...]; sets RC, CASE.
drive() {
  local label=$1 root=$2 head=$3 number=$4 ci
  shift 4
  CASE=$(make_case "$label")
  g merge-base main "$head" > "$CASE/github-base"
  add_gh_mocks "$CASE" "$head"
  read -r ci _ < <(whole_tree_check "$head")
  write_github_rollup_json "$CASE" "$head" "$(check_run ci COMPLETED "$ci")"
  write_github_required "$CASE" classic:ci
  mv "$CASE/fakebin/gh" "$CASE/fakebin/gh.stub"
  cat > "$CASE/fakebin/gh" <<SH
#!/usr/bin/env bash
ORIGIN='$ORIGIN'
STUB="\$(dirname "\$0")/gh.stub"
case "\$*" in
  "api repos/"*"/compare/"*)
    printf '%s\n' "\$*" >> "\$FM_TEST_GH_LOG"
    calls=\$(( \$(cat "\$FM_TEST_GH_COMPARE_CALLS" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "\$calls" > "\$FM_TEST_GH_COMPARE_CALLS"
    # Optional: another PR lands on main right after the Nth compare read.
    if [ -f "\$(dirname "\$0")/land-after-compare" ] && [ "\$calls" -eq "\$(cat "\$(dirname "\$0")/land-after-compare")" ]; then
      land_late=1
    fi
    spec=\${2#*compare/}; spec=\${spec%%\\?*}; base=\${spec%%...*}; head=\${spec#*...}
    tip=\$(git -C "\$ORIGIN" rev-parse "refs/heads/\$base") || exit 1
    mb=\$(git -C "\$ORIGIN" merge-base "\$tip" "\$head") || exit 1
    behind=\$(git -C "\$ORIGIN" rev-list --count "\$head..\$tip")
    printf '{"status":"x","ahead_by":1,"behind_by":%s,"base_commit":{"sha":"%s"},"merge_base_commit":{"sha":"%s"}}\n' "\$behind" "\$tip" "\$mb"
    if [ -n "\${land_late:-}" ]; then
      ( cd "\$ORIGIN" && echo late-change > late.txt && git add late.txt && git commit -qm 'another PR lands mid-run' )
    fi
    exit 0
    ;;
  "pr merge "*)
    case " \$* " in *" --disable-auto "*|*" --auto "*) ;; *)
      head=\$(cat "\$FM_TEST_GH_HEAD")
      ( cd "\$ORIGIN" && git merge -q --squash "\$head" >/dev/null && git commit -qm "squash-merge \$head" ) || exit 1
    ;; esac
    ;;
esac
exec "\$STUB" "\$@"
SH
  chmod +x "$CASE/fakebin/gh"
  [ -z "${LAND_AFTER:-}" ] || printf '%s\n' "$LAND_AFTER" > "$CASE/fakebin/land-after-compare"
  [ -z "${QUEUE_METHOD:-}" ] || { printf 'merge_method=%s\n' "$QUEUE_METHOD" > "$CASE/github-rules"; write_github_outcome "$CASE" OPEN false true main; }
  echo "head=$head  head-check(ci)=$(whole_tree_check "$head")  main=$(g rev-parse main)"
  set +e
  ROOT=$root PR_MERGE=$root/bin/fm-pr-merge.sh \
    run_pr_merge "$CASE" task-x1 "https://github.com/example/repo/pull/$number" "$@" > "$CASE/stdout" 2> "$CASE/stderr"
  RC=$?
  set -e
  echo "--- fm-pr-merge.sh exit code: $RC"
  echo "--- stderr:"; sed 's/^/  | /' "$CASE/stderr"
  echo "--- stdout:"; sed 's/^/  | /' "$CASE/stdout"
  echo "--- gh pr merge calls: $(grep -c '^pr merge' "$CASE/gh.log" || true); compare reads: $(grep -c '/compare/' "$CASE/gh.log" || true)"
  echo "--- origin main now $(g rev-parse main); whole-tree check on main: $(whole_tree_check main)"
}

say "Setup"
echo "T0=$T0 (7 cases)  #287 head=$H287  #188 head=$H188  limit=$LIMIT"
echo "#287 alone: $(whole_tree_check "$H287")   #188 alone: $(whole_tree_check "$H188")"

say "S1 (fixed script) #287 head contains the live tip T0 -> merges with no extra step"
drive s1-287 "$NEW_ROOT" "$H287" 287
T1=$(g rev-parse main)

say "S0 BEFORE THE FIX (base commit $BASE_COMMIT script): #188, built on T0, merges onto T1"
drive s0-188-old "$OLD_ROOT" "$H188" 188
echo "RESULT: combined tree landed with whole-tree check $(whole_tree_check main) - no check ran on it before it landed"
g reset -q --hard "$T1"
echo "(reset origin main back to T1=$T1 for the fixed-script runs)"

say "S2 (fixed script) same #188 head, same green check, main at T1 -> refused, naming both bases"
drive s2-188-new "$NEW_ROOT" "$H188" 188
[ "$(g rev-parse main)" = "$T1" ] && echo "RESULT: main unchanged at T1; the untested combined tree did not land"

say "S3 (fixed script, adversarial) attended waivers on the stale head: --attended-override --allow-red ci --allow-missing ci"
drive s3-188-waiver "$NEW_ROOT" "$H188" 188 --attended-override --allow-red ci --allow-missing ci

say "S4 (fixed script) author updates #188 by merging main: CI now runs on the combined tree"
g checkout -q pr-188; g merge -q --no-edit main; g checkout -q main
H188b=$(g rev-parse pr-188)
drive s4-188-updated-red "$NEW_ROOT" "$H188b" 188

say "S5 (fixed script) author rebalances so the combined tree fits; check green on the combined tree -> merges"
g checkout -q pr-188
( cd "$ORIGIN" && mkdir -p tests/shard2 && echo case-188b > tests/shard2/188.list && echo case-188a > tests/shard1/188.list && git add -A && git commit -qm '#188 moves one case to shard 2' )
g checkout -q main
H188c=$(g rev-parse pr-188)
drive s5-188-fixed-green "$NEW_ROOT" "$H188c" 188
T2=$(g rev-parse main)

say "S6 (fixed script, adversarial) a head that contains the tip, but another PR lands right after the verify read"
g checkout -q -b pr-300 "$T2"; echo x > "$ORIGIN/feature300.txt"; g add feature300.txt; g commit -qm '#300'; g checkout -q main
H300=$(g rev-parse pr-300)
LAND_AFTER=1 drive s6-300-tip-moves "$NEW_ROOT" "$H300" 300

say "S7 (fixed script) --auto into a base with a proven merge queue and required check ci: containment skipped, queue checks the combined tree"
QUEUE_METHOD=SQUASH drive s7-300-queue "$NEW_ROOT" "$H300" 300 --attended-override -- --auto --squash
