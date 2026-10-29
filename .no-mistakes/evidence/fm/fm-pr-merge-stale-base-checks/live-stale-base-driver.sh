#!/usr/bin/env bash
# Live driver for the stale-base merge guard in bin/fm-pr-merge.sh.
# It runs the real script (and, for the before-fix contrast, the script at the
# base commit) against a disposable "GitHub": a real local bare git repository
# whose main branch really moves. The compare API answer is computed from that
# real repository with git, and `gh pr merge` really squash-merges the head into
# its main, so the landed tree can be inspected. Every other gh read (PR view,
# check rollup, required set) comes from the repository's own gh fixture
# (tests/fm-pr-merge-helpers.sh add_gh_mocks). No network, no real PR.
# Usage: live-stale-base-driver.sh <worktree> <base-commit>
set -u
WT=$1 BASE_COMMIT=$2
# shellcheck source=/dev/null
. "$WT/tests/fm-pr-merge-helpers.sh"
NEW_ROOT=$ROOT
OLD_ROOT="$TMP_ROOT/base-root"
mkdir -p "$OLD_ROOT"
git -C "$WT" archive "$BASE_COMMIT" | tar -x -C "$OLD_ROOT"

ORIGIN="$TMP_ROOT/origin.git"
SCRATCH="$TMP_ROOT/scratch"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$SCRATCH" 2>/dev/null
git -C "$SCRATCH" checkout -q -b main
printf 'shard budget: 10\n' > "$SCRATCH/budget.txt"
git -C "$SCRATCH" add budget.txt
git -C "$SCRATCH" commit -q -m 'T0: main'
git -C "$SCRATCH" push -q origin main
T0=$(git -C "$ORIGIN" rev-parse main)
mkbranch() {  # name file
  git -C "$SCRATCH" checkout -q -B "$1" "$T0"
  printf '%s\n' "$1" > "$SCRATCH/$2"
  git -C "$SCRATCH" add "$2"
  git -C "$SCRATCH" commit -q -m "$1"
  git -C "$SCRATCH" push -q -f origin "$1"
  git -C "$ORIGIN" rev-parse "$1"
}
H287=$(mkbranch pr287 shard-a.txt)
H188=$(mkbranch pr188 shard-b.txt)

# Wrap the fixture gh: answer compare and merge from the real repository.
wrap_gh() {  # case_dir
  local case_dir=$1
  mv "$case_dir/fakebin/gh" "$case_dir/fakebin/gh.fixture"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
ORIGIN='$ORIGIN' SCRATCH='$SCRATCH' CASE='$case_dir'
SH
  cat >> "$case_dir/fakebin/gh" <<'SH'
case " $* " in
  *" repos/"*"/compare/main..."*)
    exec 2>>"$CASE/wrapper.err"
    printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
    for a in "$@"; do case "$a" in *"/compare/"*) head=${a##*...}; head=${head%%\?*} ;; esac; done
    tip=$(git -C "$ORIGIN" rev-parse main) || exit 1
    mb=$(git -C "$ORIGIN" merge-base main "$head") || exit 1
    behind=$(git -C "$ORIGIN" rev-list --count "$head..main") || exit 1
    ahead=$(git -C "$ORIGIN" rev-list --count "main..$head") || exit 1
    n=$(( $(cat "$CASE/real-compare-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CASE/real-compare-calls"
    printf 'real-compare #%s: main=%s merge_base=%s behind_by=%s\n' "$n" "$tip" "$mb" "$behind" >> "$CASE/real-forge.log"
    printf '{"status":"x","ahead_by":%s,"behind_by":%s,"base_commit":{"sha":"%s"},"merge_base_commit":{"sha":"%s"}}\n' "$ahead" "$behind" "$tip" "$mb"
    # A race: another PR lands on main right after the verify read.
    if [ "$n" = 1 ] && [ -f "$CASE/race-after-first-compare" ]; then
      git -C "$SCRATCH" fetch -q origin && git -C "$SCRATCH" checkout -q -B main origin/main
      printf 'race\n' > "$SCRATCH/race.txt"; git -C "$SCRATCH" add race.txt
      git -C "$SCRATCH" commit -q -m 'race: another PR landed'; git -C "$SCRATCH" push -q origin main
      printf 'race: main moved to %s after the verify read\n' "$(git -C "$ORIGIN" rev-parse main)" >> "$CASE/real-forge.log"
    fi
    exit 0
    ;;
  *" pr merge "*" --match-head-commit "*)
    exec 3>&2 2>>"$CASE/wrapper.err"
    case " $* " in *" --disable-auto "*) exec "$(dirname "$0")/gh.fixture" "$@" ;; esac
    if [ -f "$CASE/queue" ]; then
      printf 'real-queue: enqueued (main untouched; the queue would test head+tip itself)\n' >> "$CASE/real-forge.log"
      exec "$(dirname "$0")/gh.fixture" "$@"
    fi
    prev=; for a in "$@"; do [ "$prev" != --match-head-commit ] || head=$a; prev=$a; done
    git -C "$SCRATCH" fetch -q origin && git -C "$SCRATCH" checkout -q -B main origin/main
    git -C "$SCRATCH" merge -q --squash "$head" >/dev/null 2>&1 || { echo 'squash failed' >&2; exit 1; }
    git -C "$SCRATCH" commit -q -m "squash of $head" || { echo "nothing to squash" >&2; exit 1; }
    git -C "$SCRATCH" push -q origin main
    printf 'real-merge: squashed %s; main now %s\n' "$head" "$(git -C "$ORIGIN" rev-parse main)" >> "$CASE/real-forge.log"
    exec "$(dirname "$0")/gh.fixture" "$@"
    ;;
esac
exec "$(dirname "$0")/gh.fixture" "$@"
SH
  chmod +x "$case_dir/fakebin/gh"
}

# One merge attempt. Args: label root head base_as_view_reports [extra args...]
attempt() {
  local label=$1 root=$2 head=$3 view_base=$4 rc=0 case_dir; shift 4
  case_dir=$(make_case "$label")
  printf '%s\n' "$view_base" > "$case_dir/github-base"
  add_gh_mocks "$case_dir" "$head"
  if [ "${EMPTY_REQUIRED:-}" = 1 ]; then write_github_required "$case_dir"; else write_github_required "$case_dir" classic:ci; fi
  if [ "${QUEUE:-}" = 1 ]; then
    printf 'merge_method=SQUASH\n' > "$case_dir/github-rules"
    write_github_outcome "$case_dir" OPEN false true main
    : > "$case_dir/queue"
  fi
  [ -z "${MSTATE:-}" ] || sed -i '' "s/\"mergeStateStatus\":\"CLEAN\"/\"mergeStateStatus\":\"$MSTATE\"/" "$case_dir/github-view.json"
  wrap_gh "$case_dir"
  case "$label" in race-*) : > "$case_dir/race-after-first-compare" ;; esac
  local main_before; main_before=$(git -C "$ORIGIN" rev-parse main)
  ( ROOT=$root PR_MERGE="$root/bin/fm-pr-merge.sh"
    FM_GUARD_EVENT_LOG="$case_dir/guard-events.jsonl" \
      run_pr_merge "$case_dir" task-x1 "https://github.com/example/repo/pull/${label##*-}" "$@" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" ) || rc=$?
  echo "=================== $label ==================="
  echo "script: $root/bin/fm-pr-merge.sh"
  echo "args: task-x1 https://github.com/example/repo/pull/${label##*-} $*"
  echo "head=$head  main before=$main_before"
  echo "exit code: $rc"
  echo "--- real forge log ---"; cat "$case_dir/real-forge.log" 2>/dev/null || echo '(no compare or merge)'
  echo "--- wrapper stderr ---"; tail -5 "$case_dir/wrapper.err" 2>/dev/null
  echo "--- gh pr merge calls ---"; grep '^pr merge' "$case_dir/gh.log" || echo '(none)'
  echo "--- guard events ---"; cat "$case_dir/guard-events.jsonl" 2>/dev/null | jq -c '{guard,decision,source_ok}' 2>/dev/null || echo '(none)'
  echo "--- stdout ---"; cat "$case_dir/stdout"
  echo "--- stderr ---"; cat "$case_dir/stderr"
  echo "main after=$(git -C "$ORIGIN" rev-parse main)"
  echo
}

echo "T0 (main)=$T0  PR287 head=$H287  PR188 head=$H188 (both built on T0)"
echo
case "${SCENARIO:-all}" in
  before|all)
    # Before the fix: base-commit script, #287 then #188, both merge.
    attempt before-287 "$OLD_ROOT" "$H287" "$T0"
    attempt before-188 "$OLD_ROOT" "$H188" "$T0"
    echo "landed tree after the old script (main=$(git -C "$ORIGIN" rev-parse main)):"
    git -C "$ORIGIN" ls-tree --name-only main
    echo "was the landed tree ever a PR head tree a check ran on? $(
      t=$(git -C "$ORIGIN" rev-parse 'main^{tree}')
      [ "$t" = "$(git -C "$ORIGIN" rev-parse "$H287^{tree}")" ] || [ "$t" = "$(git -C "$ORIGIN" rev-parse "$H188^{tree}")" ] && echo yes || echo NO)"
    ;;
esac
case "${SCENARIO:-all}" in
  after|all)
    git -C "$ORIGIN" update-ref refs/heads/main "$T0"
    echo; echo "##### main reset to T0 for the fixed script #####"; echo
    attempt after-287 "$NEW_ROOT" "$H287" "$T0"
    T1=$(git -C "$ORIGIN" rev-parse main)
    # GitHub leaves baseRefOid at the base of the last head push (T0).
    attempt after-188 "$NEW_ROOT" "$H188" "$T0"
    attempt waiver-188 "$NEW_ROOT" "$H188" "$T0" --attended-override --allow-red ci --allow-missing ci
    # Update the branch: rebase pr188 onto T1 and push; CI re-runs green.
    git -C "$SCRATCH" fetch -q origin && git -C "$SCRATCH" checkout -q pr188 && git -C "$SCRATCH" rebase -q "$T1" && git -C "$SCRATCH" push -q -f origin pr188
    H188B=$(git -C "$ORIGIN" rev-parse pr188)
    echo "pr188 rebased onto T1=$T1 -> new head $H188B"; echo
    attempt race-188 "$NEW_ROOT" "$H188B" "$T1"
    git -C "$SCRATCH" fetch -q origin && git -C "$SCRATCH" checkout -q pr188 && git -C "$SCRATCH" rebase -q origin/main && git -C "$SCRATCH" push -q -f origin pr188
    H188C=$(git -C "$ORIGIN" rev-parse pr188)
    echo "pr188 rebased onto main=$(git -C "$ORIGIN" rev-parse main) -> new head $H188C"; echo
    attempt updated-188 "$NEW_ROOT" "$H188C" "$(git -C "$ORIGIN" rev-parse main)"
    echo "landed tree after the fixed script equals the checked head tree? $(
      [ "$(git -C "$ORIGIN" rev-parse 'main^{tree}')" = "$(git -C "$ORIGIN" rev-parse "$H188C^{tree}")" ] && echo yes || echo NO)"
    ;;
esac
case "${SCENARIO:-all}" in
  queue)
    # #287 lands first so #188's head (built on T0) is behind main.
    attempt queuesetup-287 "$NEW_ROOT" "$H287" "$T0"
    QUEUE=1 attempt queue-188 "$NEW_ROOT" "$H188" "$T0" --attended-override -- --auto --squash
    QUEUE=1 EMPTY_REQUIRED=1 attempt queuenochecks-188 "$NEW_ROOT" "$H188" "$T0" --attended-override -- --auto --squash
    QUEUE=1 attempt queuedirect-188 "$NEW_ROOT" "$H188" "$T0" --attended-override -- --squash
    # Off-queue --auto on a BLOCKED PR whose head contains the tip: refused, since GitHub would arm auto-merge.
    git -C "$SCRATCH" fetch -q origin && git -C "$SCRATCH" checkout -q pr188 && git -C "$SCRATCH" rebase -q origin/main && git -C "$SCRATCH" push -q -f origin pr188
    H188B=$(git -C "$ORIGIN" rev-parse pr188)
    MSTATE=BLOCKED attempt autoblocked-188 "$NEW_ROOT" "$H188B" "$(git -C "$ORIGIN" rev-parse main)" --attended-override -- --auto --squash
    ;;
esac
