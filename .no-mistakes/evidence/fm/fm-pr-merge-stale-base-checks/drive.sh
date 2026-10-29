#!/usr/bin/env bash
# Drive bin/fm-pr-merge.sh from TREE against a disposable local "forge": a real
# git repository whose main branch moves as PRs land. A gh stand-in answers the
# compare API from that real git history and performs the real squash merge
# into it, so the landed tree can be checked afterwards.
# Usage: drive.sh <tree> <label> <scenario>
set -u
TREE=$1 LABEL=$2 SCENARIO=$3
. "$TREE/tests/fm-pr-merge-helpers.sh"
set +e

FORGE="$TMP_ROOT/forge"
CHECK_LIMIT=2
# The whole-tree check: the suite may hold at most CHECK_LIMIT shard files,
# like the portable serial shard packing target that #188 + #287 crossed.
whole_tree_check() {  # <git-dir> <commit>
  local n
  n=$(git --git-dir="$1" ls-tree --name-only "$2" shard/ | wc -l | tr -d ' ')
  if [ "$n" -le "$CHECK_LIMIT" ]; then echo "SUCCESS ($n/$CHECK_LIMIT shard files)"; else echo "FAILURE ($n/$CHECK_LIMIT shard files)"; fi
}

say() { printf '%s\n' "$*"; }

build_forge() {
  rm -rf "$FORGE" "$FORGE.wt"
  git init -q --bare -b main "$FORGE"
  git clone -q "$FORGE" "$FORGE.wt" 2>/dev/null
  cd "$FORGE.wt" || exit 1
  mkdir shard && echo one > shard/t1 && git add . && git commit -qm 'T0: one shard file' && git push -q origin main
  T0=$(git rev-parse HEAD)
  git checkout -qb pr-287 "$T0" && echo two > shard/t287 && git add . && git commit -qm '#287 adds a shard file' && git push -q origin pr-287
  git checkout -qb pr-188 "$T0" && echo three > shard/t188 && git add . && git commit -qm '#188 adds a shard file' && git push -q origin pr-188
  # #287 lands first: main moves to T1.
  git checkout -q main && git merge -q --squash pr-287 && git commit -qm '#287 (squash)' && git push -q origin main
  T1=$(git rev-parse HEAD)
  HEAD188=$(git rev-parse pr-188)
  cd - >/dev/null || exit 1
}

# Wrap the shared gh stand-in: the compare API and the merge itself go to the
# real git forge; every other read keeps the stand-in's answers.
wrap_gh() {  # <case_dir>
  local case_dir=$1
  mv "$case_dir/fakebin/gh" "$case_dir/fakebin/gh.inner"
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
FORGE='$FORGE'
CASE='$case_dir'
SH
  cat >> "$case_dir/fakebin/gh" <<'SH'
case " $* " in
  *" repos/"*"/compare/"*)
    printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
    n=$(( $(cat "$CASE/real-compare-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CASE/real-compare-calls"
    [ ! -e "$CASE/compare-5xx" ] || { echo 'gh: HTTP 502: Bad Gateway' >&2; exit 1; }
    all="$*"; spec=${all#*compare/}; spec=${spec%%\?*}; base=${spec%%...*}; head=${spec#*...}
    tip=$(git --git-dir="$FORGE" rev-parse "refs/heads/$base") || exit 1
    mb=$(git --git-dir="$FORGE" merge-base "$tip" "$head") || exit 1
    behind=$(git --git-dir="$FORGE" rev-list --count "$head..$tip")
    ahead=$(git --git-dir="$FORGE" rev-list --count "$tip..$head")
    printf '{"status":"x","ahead_by":%s,"behind_by":%s,"base_commit":{"sha":"%s"},"merge_base_commit":{"sha":"%s"}}\n' "$ahead" "$behind" "$tip" "$mb"
    # Another PR lands on main right after the verify read, when asked.
    if [ "$n" = 1 ] && [ -e "$CASE/move-main-after-verify" ]; then
      wt=$(mktemp -d); git clone -q "$FORGE" "$wt" 2>/dev/null
      (cd "$wt" && echo late > late && git add . && git commit -qm 'another PR lands' && git push -q origin main) >/dev/null 2>&1
      rm -rf "$wt"
    fi
    exit 0 ;;
  *"/rules/branches/"*merge_queue*)
    n=$(( $(cat "$CASE/real-rules-calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$CASE/real-rules-calls"
    if [ "$n" = 1 ] && [ -e "$CASE/rules-5xx-once" ]; then
      printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
      echo 'gh: HTTP 503: Service Unavailable' >&2; exit 1
    fi ;;
esac
case "${1:-} ${2:-}" in
  "pr merge")
    case " $* " in *" --disable-auto "*|*" --auto "*) exec "$(dirname "$0")/gh.inner" "$@" ;; esac
    "$(dirname "$0")/gh.inner" "$@" || exit $?
    head=$(cat "$FM_TEST_GH_HEAD")
    wt=$(mktemp -d); git clone -q "$FORGE" "$wt" 2>/dev/null
    (cd "$wt" && git fetch -q origin "$head" && git merge -q --squash "$head" && git commit -qm "squash-merge $head" && git push -q origin main) >/dev/null 2>&1
    rm -rf "$wt"
    exit 0 ;;
esac
exec "$(dirname "$0")/gh.inner" "$@"
SH
  chmod +x "$case_dir/fakebin/gh"
}

prepare_case() {  # <name> <head>; sets CASE
  CASE=$(make_case "$1")
  add_gh_mocks "$CASE" "$2"
  printf '%s\n' "$T0" > "$CASE/github-base"   # GitHub's baseRefOid: base of the last head push
  local ci; ci=$(whole_tree_check "$FORGE" "$2")
  case "$ci" in
    SUCCESS*) write_github_live_json "$CASE" "$2" ;;
    *) write_github_red_json "$CASE" "$2" ci ;;
  esac
  say "head check 'ci' on the PR head's own tree: $ci"
  wrap_gh "$CASE"
}

run_merge() {  # <args...>
  say "\$ fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/188 $*"
  RC=0
  FM_GUARD_EVENT_LOG="$CASE/guard-events.jsonl" \
    run_pr_merge "$CASE" task-x1 https://github.com/example/repo/pull/188 "$@" \
    > "$CASE/stdout" 2> "$CASE/stderr" || RC=$?
  say "--- stdout"; cat "$CASE/stdout"
  say "--- stderr"; cat "$CASE/stderr"
  say "--- exit: $RC"
  say "--- gh calls: compare=$(grep -c '/compare/' "$CASE/gh.log") pr-merge=$(grep -c '^pr merge' "$CASE/gh.log")"
  [ ! -s "$CASE/guard-events.jsonl" ] || { say "--- guard events"; jq -c '{guard,decision,source_ok:(.source_ok // .sourceOk // null)}' "$CASE/guard-events.jsonl" 2>/dev/null || cat "$CASE/guard-events.jsonl"; }
  local tip; tip=$(git --git-dir="$FORGE" rev-parse main)
  say "--- forge main after: $tip  whole-tree check on main: $(whole_tree_check "$FORGE" "$tip")"
}

build_forge
say "=== [$LABEL] scenario: $SCENARIO"
say "forge: T0=$T0  main(T1, after #287)=$T1  #188 head=$HEAD188 (built on T0)"
say "whole-tree check: T1=$(whole_tree_check "$FORGE" "$T1")"

case "$SCENARIO" in
  stale-head)
    prepare_case stale "$HEAD188"; run_merge ;;
  stale-head-waivers)
    prepare_case stale-w "$HEAD188"; run_merge --allow-red ci
    prepare_case stale-w2 "$HEAD188"; run_merge --allow-missing ci
    prepare_case stale-w3 "$HEAD188"; run_merge --attended-override -- --admin --squash ;;
  fresh-head)
    # #188 rebased onto T1 and trimmed to stay under the limit: CI ran on that tree.
    wt=$(mktemp -d); git clone -q "$FORGE" "$wt" 2>/dev/null
    (cd "$wt" && git checkout -q -b pr-188 origin/main && git rm -q shard/t1 && echo three > shard/t188 && git add . && git commit -qm '#188 rebased onto main' && git push -qf origin pr-188) >/dev/null 2>&1
    NEW=$(git --git-dir="$FORGE" rev-parse pr-188); rm -rf "$wt"
    say "#188 rebased head=$NEW"
    prepare_case fresh "$NEW"; run_merge ;;
  tip-moves)
    wt=$(mktemp -d); git clone -q "$FORGE" "$wt" 2>/dev/null
    (cd "$wt" && git checkout -q -b pr-188 origin/main && git rm -q shard/t1 && echo three > shard/t188 && git add . && git commit -qm '#188 rebased onto main' && git push -qf origin pr-188) >/dev/null 2>&1
    NEW=$(git --git-dir="$FORGE" rev-parse pr-188); rm -rf "$wt"
    prepare_case moves "$NEW"; touch "$CASE/move-main-after-verify"; run_merge ;;
  compare-5xx)
    prepare_case c5 "$HEAD188"; touch "$CASE/compare-5xx"; run_merge ;;
  queue)
    prepare_case q "$HEAD188"; write_github_required "$CASE" classic:ci
    printf 'merge_method=SQUASH\n' > "$CASE/github-rules"; write_github_outcome "$CASE" OPEN false true main
    run_merge --attended-override -- --auto --squash ;;
  queue-no-required)
    prepare_case qn "$HEAD188"
    printf 'merge_method=SQUASH\n' > "$CASE/github-rules"; write_github_outcome "$CASE" OPEN false true main
    run_merge --attended-override -- --auto --squash ;;
  queue-rules-5xx-once)
    prepare_case q5 "$HEAD188"; write_github_required "$CASE" classic:ci
    printf 'merge_method=SQUASH\n' > "$CASE/github-rules"; write_github_outcome "$CASE" OPEN false true main
    touch "$CASE/rules-5xx-once"
    run_merge --attended-override -- --auto --squash
    say "--- rules reads: $(cat "$CASE/real-rules-calls" 2>/dev/null)" ;;
esac
