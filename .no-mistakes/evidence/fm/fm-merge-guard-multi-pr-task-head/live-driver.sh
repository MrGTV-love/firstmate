#!/usr/bin/env bash
# Live scenario driver for the multi-PR merge guard fix.
# Usage: drive.sh <root-with-bin> <scenario>
# Builds a disposable lab FM_HOME (bin/fm-lab-home.sh), a real git project with
# a bare origin, a worker copy that pushed real PR branches, and a local forge
# stand-in (gh) that reports each named PR's head as the sha of its branch on
# origin. Then runs the real <root>/bin/fm-pr-merge.sh (or fm-pr-check.sh).
set -u
ROOT=$1 SCEN=$2
GATE_ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4MDD1MCZPQGJMC1GFZR05HK
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/forge-stub.sh"
fail() { echo "STUB-FAIL: $*" >&2; exit 99; }
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$GATE_ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
trap 'rm -rf "$LAB"' EXIT
C="$LAB/case"; mkdir -p "$C/fakebin" "$C/user-home"
cp "$ROOT/.tasks.toml" "$LAB/.tasks.toml"
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main' > "$C/github-outcome"
: > "$C/github-rules"; : > "$C/gh.log"; : > "$C/gh-axi.log"
write_github_required "$C"

# Real repo: project with a bare origin, and the worker copy as a git worktree.
ORIGIN="$LAB/origin.git"; PROJ="$LAB/projects/vernant"; WT="$LAB/wt"
git init -q --bare -b main "$ORIGIN"
git init -q -b main "$PROJ"; echo base > "$PROJ/README.md"
git -C "$PROJ" add README.md; git -C "$PROJ" commit -qm initial
git -C "$PROJ" remote add origin "file://$ORIGIN"; git -C "$PROJ" push -q origin main
git -C "$PROJ" fetch -q origin
git -C "$PROJ" worktree add -q -b fm/task-x1 "$WT" origin/main
# The worker stacks one commit per PR and pushes each PR branch.
stack_prs() { # <first> <last>
  local n
  for n in $(seq "$1" "$2"); do
    echo "pr $n" > "$WT/pr-$n.txt"; git -C "$WT" add "pr-$n.txt"; git -C "$WT" commit -qm "PR $n"
    git -C "$WT" push -q origin "HEAD:refs/heads/pr-$n"
  done
  git -C "$WT" fetch -q origin
}
head_of() { git --git-dir="$ORIGIN" rev-parse "refs/heads/pr-$1"; }
url_of() { printf 'https://github.com/example/vernant/pull/%s' "$1"; }
ready() { local n; for n in "$@"; do printf 'done [at=1791600000]: PR %s checks green\n' "$(url_of "$n")" >> "$LAB/state/task-x1.status"; done; }
meta() { printf '%s\n' window=fm-task-x1 "worktree=$WT" "project=$PROJ" kind=ship mode=direct-PR "$@" > "$LAB/state/task-x1.meta"; }

run() { # <script> <args...>
  local s=$1; shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" \
  FM_TEST_GH_AXI_LOG="$C/gh-axi.log" FM_TEST_GH_LOG="$C/gh.log" \
  FM_TEST_GH_OUTCOME="$C/github-outcome" FM_TEST_GH_RULES="$C/github-rules" \
  FM_TEST_GH_VIEW_JSON="$C/github-view.json" FM_TEST_GH_MERGEABLE_CALLS="$C/mc" \
  FM_TEST_GH_HEAD="$C/github-head" FM_TEST_GH_RUNS="$C/github-runs.json" \
  FM_TEST_GH_MERGE_RC_FILE="$C/github-merge-rc" FM_TEST_GH_GRAPHQL_FAIL="$C/none" \
  FM_TEST_GH_RULES_FAIL="$C/none" FM_TEST_GH_RULES_FAIL_BODY="$C/none" \
  FM_TEST_GH_BRANCH="$C/github-branch.json" FM_TEST_GH_BRANCH_FAIL="$C/none" \
  FM_TEST_GH_REQUIRED_RULES="$C/github-required-rules.json" FM_TEST_GH_REQUIRED_RULES_FAIL="$C/none" \
  HOME="$C/user-home" PATH="$C/fakebin:$PATH" \
    "$ROOT/bin/$s" "$@"
}
merge() { # <n>
  local n=$1 rc
  echo "\$ fm-pr-merge.sh task-x1 $(url_of "$n")   # forge head of PR $n = $(cat "$C/github-head")"
  run fm-pr-merge.sh task-x1 "$(url_of "$n")" > "$C/out" 2>&1; rc=$?
  sed 's/^/    /' "$C/out"; echo "    exit=$rc"
  echo "    gh merge calls: $(grep '^pr merge' "$C/gh.log" | tail -1 || true)"
  return $rc
}
show_copy() { echo "copy HEAD=$(git -C "$WT" rev-parse HEAD); on any origin ref: $(git --git-dir="$ORIGIN" branch --contains "$(git -C "$WT" rev-parse HEAD)" 2>/dev/null | tr -d ' \n' || true)"; }

echo "=== scenario: $SCEN   (bin from $ROOT)"
case "$SCEN" in
  local-tip-all-8)
    # Incident 1: 8 PRs 3196-3203 pushed; the copy then gains a local unpushed tip.
    meta; stack_prs 3196 3203; ready $(seq 3196 3203)
    echo local-follow-up > "$WT/local.txt"; git -C "$WT" add local.txt; git -C "$WT" commit -qm 'local tip, never pushed'
    show_copy
    ok=0; bad=0
    for n in $(seq 3196 3203); do
      add_gh_mocks "$C" "$(head_of "$n")"
      if merge "$n"; then ok=$((ok+1)); else bad=$((bad+1)); fi
      echo "    meta pr=$(grep '^pr=' "$LAB/state/task-x1.meta" | tail -1) $(grep '^pr_head=' "$LAB/state/task-x1.meta" | tail -1)"
    done
    echo "RESULT merged=$ok refused=$bad"
    ;;
  merged-sibling-gone)
    # Incident 2: copy rests on PR 3202's head; 3202 merged; its branch deleted.
    stack_prs 3196 3202
    meta "pr=$(url_of 3202)"
    printf '%s\n' fm-pr-poll-merge-notified-v1 github github.com example/vernant 3202 > "$LAB/state/task-x1.pr-poll-merge-notified"
    chmod 600 "$LAB/state/task-x1.pr-poll-merge-notified"
    # Recreate PR 3197 on its own branch from main so 3202's tip is not on it,
    # then delete pr-3202 and all other stacked branches, as GitHub does on merge.
    git --git-dir="$ORIGIN" update-ref -d refs/heads/pr-3202
    git -C "$PROJ" fetch -q origin
    git -C "$PROJ" checkout -q -b solo origin/main; echo solo > "$PROJ/pr-3197.txt"; git -C "$PROJ" add pr-3197.txt; git -C "$PROJ" commit -qm 'PR 3197 solo'
    git -C "$PROJ" push -q -f origin HEAD:refs/heads/pr-3197
    for n in 3196 3198 3199 3200 3201; do git --git-dir="$ORIGIN" update-ref -d "refs/heads/pr-$n"; done
    git -C "$WT" fetch -q --prune origin; git -C "$WT" remote prune origin >/dev/null 2>&1
    show_copy
    add_gh_mocks "$C" "$(head_of 3197)"
    merge 3197; echo "RESULT exit=$?"
    ;;
  single-pr-local-tip)
    meta; stack_prs 3197 3197; ready 3197
    echo x > "$WT/local.txt"; git -C "$WT" add local.txt; git -C "$WT" commit -qm 'local tip'
    show_copy
    add_gh_mocks "$C" "$(head_of 3197)"
    merge 3197; echo "RESULT exit=$?"
    ;;
  multi-pr-no-forge-head)
    meta; stack_prs 3196 3197; ready 3196 3197
    echo x > "$WT/local.txt"; git -C "$WT" add local.txt; git -C "$WT" commit -qm 'local tip'
    show_copy
    add_gh_mocks "$C" "$(head_of 3197)"; rm -f "$C/github-head"; : > "$C/github-head"
    merge 3197; echo "RESULT exit=$?"
    ;;
  multi-pr-red-head)
    meta; stack_prs 3196 3197; ready 3196 3197
    echo x > "$WT/local.txt"; git -C "$WT" add local.txt; git -C "$WT" commit -qm 'local tip'
    show_copy
    add_gh_mocks "$C" "$(head_of 3197)"; write_github_red_json "$C" "$(head_of 3197)" lint
    merge 3197; echo "RESULT exit=$?"
    ;;
  decoy-records)
    # Only mentions, another project's PR, and a non-ready line: not several PRs.
    meta; stack_prs 3197 3197; ready 3197
    {
      printf 'working [at=2]: PR %s is the sibling to rebase on\n' "$(url_of 3198)"
      printf 'done [at=3]: PR https://github.com/example/other/pull/3198 checks green\n'
      printf 'done [at=4]: see %s for context\n' "$(url_of 3198)"
    } >> "$LAB/state/task-x1.status"
    echo x > "$WT/local.txt"; git -C "$WT" add local.txt; git -C "$WT" commit -qm 'local tip'
    show_copy
    add_gh_mocks "$C" "$(head_of 3197)"
    merge 3197; echo "RESULT exit=$?"
    ;;
  registration-local-tip)
    # A plain registration (no merge) of a multi-PR task still judges the copy's HEAD.
    meta; stack_prs 3196 3197; ready 3196 3197
    echo x > "$WT/local.txt"; git -C "$WT" add local.txt; git -C "$WT" commit -qm 'local tip'
    show_copy
    add_gh_mocks "$C" "$(head_of 3197)"
    echo "\$ fm-pr-check.sh task-x1 $(url_of 3197)   # registration, no merge"
    run fm-pr-check.sh task-x1 "$(url_of 3197)" > "$C/out" 2>&1; rc=$?
    sed 's/^/    /' "$C/out"; echo "    exit=$rc"
    echo "    poll armed: $([ -e "$LAB/state/task-x1.check.sh" ] && echo yes || echo no)"
    echo "RESULT exit=$rc"
    ;;
esac
