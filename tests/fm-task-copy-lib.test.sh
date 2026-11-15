#!/usr/bin/env bash
# Helper-level tests for the landing helpers in bin/fm-task-copy-lib.sh that
# bin/fm-teardown.sh calls (Main 1820 F2, F3, F4(a); admitted by Main 1828):
# fm_task_copy_refresh_default, fm_task_copy_pr_list_read and
# fm_task_copy_archive_carried. Only that library is sourced; the fixtures are
# real git repositories and literal PR-list text. No teardown, no task process
# and no timed or killed process runs here.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-task-copy-lib.sh
. "$ROOT/bin/fm-task-copy-lib.sh"

FAILED=0
CASE_FAILED=0
fail() { printf 'not ok - %s\n' "$*"; FAILED=1; CASE_FAILED=1; }
# pass prints the case's ok line only when none of its checks failed.
pass() { [ "$CASE_FAILED" = 1 ] || printf 'ok - %s\n' "$*"; CASE_FAILED=0; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-task-copy-lib.XXXXXX") || exit 1
trap 'rm -rf -- "${WORK:?}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
G() { git -c user.email=t@t -c user.name=t -c init.defaultBranch=main "$@"; }

# new_world <name>: an origin repository with one commit on main, and a clone of it.
new_world() {
  local w="$WORK/$1"
  mkdir -p "$w"
  G init -q --bare "$w/origin.git"
  G init -q "$w/seed"
  printf 'base\n' > "$w/seed/base.txt"
  G -C "$w/seed" add base.txt
  G -C "$w/seed" commit -q -m base
  G -C "$w/seed" push -q "$w/origin.git" HEAD:main
  G clone -q "$w/origin.git" "$w/clone"
  printf '%s\n' "$w"
}

# commit_in <repo> <file> <content> <message>: commit one file, print the commit.
commit_in() {
  printf '%s\n' "$3" > "$1/$2"
  G -C "$1" add -- "$2"
  G -C "$1" commit -q -m "$4"
  G -C "$1" rev-parse HEAD
}

test_refresh_reads_the_current_default_branch() {
  local w old head
  w=$(new_world refresh)
  old=$(G -C "$w/clone" rev-parse HEAD)
  head=$(commit_in "$w/seed" feature.txt hello "add feature")
  G -C "$w/seed" push -q "$w/origin.git" HEAD:main
  G -C "$w/clone" fetch -q origin
  [ "$(G -C "$w/clone" rev-parse refs/remotes/origin/main)" = "$head" ] || fail "fixture: the cache does not hold the head"
  # The real default branch is rewritten without the head; the cache still has it.
  G -C "$w/seed" push -q -f "$w/origin.git" "$old:main"
  if fm_task_copy_refresh_default "$w/clone" main; then
    [ "$FM_TASK_COPY_DEFAULT_REF" = refs/remotes/origin/main ] || fail "refresh named $FM_TASK_COPY_DEFAULT_REF"
    [ "$(G -C "$w/clone" rev-parse "$FM_TASK_COPY_DEFAULT_REF")" = "$old" ] \
      || fail "refresh left the cached default branch that holds a head the real one lacks"
  else
    fail "refresh of a reachable origin failed: $FM_TASK_COPY_UNASKED"
  fi
  mv "$w/origin.git" "$w/origin.git.gone"
  if fm_task_copy_refresh_default "$w/clone" main; then
    fail "an unreachable origin was taken as refreshed ($FM_TASK_COPY_DEFAULT_REF)"
  fi
  [ -z "$FM_TASK_COPY_DEFAULT_REF" ] || fail "a failed refresh still named a ref"
  case "$FM_TASK_COPY_UNASKED" in *"origin/main could not be refreshed"*) ;; *) fail "a failed refresh did not say why: $FM_TASK_COPY_UNASKED" ;; esac
  G -C "$w/seed" remote remove origin 2>/dev/null || true
  fm_task_copy_refresh_default "$w/seed" main || fail "a copy without origin did not read its local branch"
  [ "$FM_TASK_COPY_DEFAULT_REF" = refs/heads/main ] || fail "without origin the ref was $FM_TASK_COPY_DEFAULT_REF"
  pass "refresh reads origin's current default branch, refuses when it cannot be fetched, and reads the local branch without origin"
}

# list_text <count-line> <n> [merged]: a gh-axi list with <n> rows, PR numbers n..1.
list_text() {
  local line=$1 n=$2 i
  printf '%s\n' "$line" "pull_requests[$n]{number,state}:"
  i=$n
  while [ "$i" -gt 0 ]; do printf '  %s,open\n' "$i"; i=$((i - 1)); done
}

test_pr_list_is_complete_only_within_its_bound() {
  local rc text
  text=$(list_text "count: 1000" 1000)
  rc=0; fm_task_copy_pr_list_read 1000 "$text" || rc=$?
  [ "$rc" = 0 ] || fail "a complete list of exactly the bound (1000) was refused: rc=$rc $FM_TASK_COPY_UNASKED"
  [ "$(printf '%s\n' "$FM_TASK_COPY_PR_NUMBERS" | grep -c .)" = 1000 ] || fail "a complete list did not give every number"
  [ "$(printf '%s\n' "$FM_TASK_COPY_PR_NUMBERS" | sed -n '1000p')" = 1 ] || fail "the oldest PR was not read"
  text=$(list_text "count: 1001" 1001)
  rc=0; fm_task_copy_pr_list_read 1000 "$text" || rc=$?
  [ "$rc" = 2 ] || fail "a full page of bound+1 rows was not incomplete: rc=$rc"
  [ -z "$FM_TASK_COPY_PR_NUMBERS" ] || fail "a full page still gave numbers"
  case "$FM_TASK_COPY_UNASKED" in *"not shown complete"*) ;; *) fail "a full page did not say why: $FM_TASK_COPY_UNASKED" ;; esac
  text=$(list_text "count: 20 of 21 total" 20)
  rc=0; fm_task_copy_pr_list_read 1000 "$text" || rc=$?
  [ "$rc" = 2 ] || fail "a cut list was not incomplete: rc=$rc"
  text=$(list_text "count: 3" 2)
  rc=0; fm_task_copy_pr_list_read 1000 "$text" || rc=$?
  [ "$rc" = 2 ] || fail "a list whose rows differ from its count was not incomplete: rc=$rc"
  text=$(list_text "pull requests: 2" 2)
  rc=0; fm_task_copy_pr_list_read 1000 "$text" || rc=$?
  [ "$rc" = 2 ] || fail "an unknown count line was not incomplete: rc=$rc"
  rc=0; fm_task_copy_pr_list_read 1000 "$(printf '%s\n' 'count: 0' 'pull_requests: []')" || rc=$?
  [ "$rc" = 1 ] || fail "an empty complete list was not 'no PR': rc=$rc"
  [ -z "$FM_TASK_COPY_UNASKED" ] || fail "'no PR' carried an unasked reason"
  text=$(list_text "count: 21 of 21 total" 21)
  rc=0; fm_task_copy_pr_list_read 1000 "$text" || rc=$?
  [ "$rc" = 0 ] || fail "'count: N of N total' was refused: rc=$rc"
  pass "a PR list is complete only within its bound; a full page, a cut list or a mismatch is incomplete, never 'no PR'"
}

test_archive_tip_goes_only_when_the_default_branch_holds_it() {
  local w base archived replay final reaped mainline
  w=$(new_world archive)
  base=$(G -C "$w/clone" rev-parse HEAD)
  # The PR replays the archived feature, reverts it, then adds other work.
  replay=$(commit_in "$w/clone" feature.txt alpha "replay the feature")
  archived=$(printf 'submitted feature\n' | G -C "$w/clone" commit-tree "$replay^{tree}" -p "$base")
  G -C "$w/clone" rm -q feature.txt
  G -C "$w/clone" commit -q -m "revert the feature"
  final=$(commit_in "$w/clone" other.txt beta "other work")
  [ "$(G -C "$w/clone" cherry "$final" "$archived" | cut -c1)" = - ] || fail "fixture: git cherry does not match the archived patch"
  # The PR is squash-merged into the default branch.
  G -C "$w/seed" fetch -q "$w/clone" "$final"
  G -C "$w/seed" reset -q --hard "$base" 2>/dev/null || G -C "$w/seed" checkout -q "$base"
  G -C "$w/seed" merge -q --squash FETCH_HEAD >/dev/null
  G -C "$w/seed" commit -q -m "squash PR"
  G -C "$w/seed" push -q -f "$w/origin.git" HEAD:main
  fm_task_copy_refresh_default "$w/clone" main || fail "refresh failed: $FM_TASK_COPY_UNASKED"
  mainline=$FM_TASK_COPY_DEFAULT_REF
  G -C "$w/clone" show "$mainline:feature.txt" >/dev/null 2>&1 && fail "fixture: the default branch holds the reverted feature"
  if fm_task_copy_archive_carried "$w/clone" "$mainline" "$archived"; then
    fail "an archive whose change was replayed then reverted was judged carried"
  fi
  fm_task_copy_archive_carried "$w/clone" "$mainline" "$final" \
    || fail "control: the archive of the squash-merged head was not judged carried"
  reaped=$(G -C "$w/clone" rev-parse "$mainline")
  fm_task_copy_archive_carried "$w/clone" "$mainline" "$base" || fail "control: an ancestor of the default branch was not judged carried"
  fm_task_copy_archive_carried "$w/clone" "" "$final" && fail "an empty default ref was judged carried"
  fm_task_copy_archive_carried "$w/clone" "$mainline" "0000000000000000000000000000000000000000" && fail "an unknown tip was judged carried"
  [ "$(G -C "$w/clone" rev-parse "$mainline")" = "$reaped" ] || fail "the decision moved the default ref"
  pass "an archive tip goes only when the refreshed default branch holds it by history or content; a replayed-then-reverted change stays"
}

test_refresh_reads_the_current_default_branch
test_pr_list_is_complete_only_within_its_bound
test_archive_tip_goes_only_when_the_default_branch_holds_it
exit "$FAILED"
