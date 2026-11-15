#!/usr/bin/env bash
# Helper-level tests for the landing helpers in bin/fm-task-copy-lib.sh that
# bin/fm-teardown.sh calls (Main 1820 F2, F3, F4(a); admitted by Main 1828; Main
# 1871 P-A, P-B and the renamed-default rule): fm_task_copy_refresh_default,
# fm_task_copy_live_default, fm_task_copy_content_in_default (the blob proof),
# fm_task_copy_pr_list_read and fm_task_copy_archive_carried. Only that library is sourced; the fixtures are
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
  # No readable origin is unknown, never a local branch (Main 1871 P-A).
  G -C "$w/seed" remote remove origin 2>/dev/null || true
  if fm_task_copy_refresh_default "$w/seed" main; then
    fail "a copy without origin was refreshed from its local branch ($FM_TASK_COPY_DEFAULT_REF)"
  fi
  case "$FM_TASK_COPY_UNASKED" in *"no readable origin"*) ;; *) fail "no origin did not say why: $FM_TASK_COPY_UNASKED" ;; esac
  if fm_task_copy_content_in_default "$w/seed" "$w/seed" main HEAD; then
    fail "the content check proved landing from a local branch with no origin"
  fi
  [ -n "$FM_TASK_COPY_UNASKED" ] || fail "the content check without origin was an answer, not unknown"
  pass "refresh reads origin's current default branch and refuses when it cannot be fetched or no origin exists"
}

# The content proof compares blobs, never a merge (Main 1871 P-B). The copy edits a
# line that the default branch later edited differently; a repository merge driver
# that keeps "ours" makes git merge-tree return the default's own tree, so a merge
# would call the copy landed. The blob proof refuses. Controls: a squash of the
# copy's change on the default lands; a change the default made further on the same
# path is unproved; a deletion lands only when the default lacks the path too.
test_content_proof_is_by_blobs_not_by_merge() {
  local w copy default_tree merged
  w=$(new_world blobs)
  copy="$w/clone"
  printf 'one\n' > "$copy/base.txt"; G -C "$copy" commit -q -am "copy edits base"
  printf 'two\n' > "$w/seed/base.txt"; G -C "$w/seed" commit -q -am "default edits base"
  G -C "$w/seed" push -q "$w/origin.git" HEAD:main
  printf '* merge=keep-default\n' > "$copy/.git/info/attributes"
  G -C "$copy" config merge.keep-default.driver true
  G -C "$copy" fetch -q origin
  default_tree=$(G -C "$copy" rev-parse 'refs/remotes/origin/main^{tree}')
  merged=$(G -C "$copy" merge-tree --write-tree refs/remotes/origin/main HEAD 2>/dev/null | head -1)
  [ "$merged" = "$default_tree" ] || fail "fixture: the merge driver did not make merge-tree return the default's tree"
  if fm_task_copy_content_in_default "$copy" "$copy" main HEAD; then
    fail "a copy whose line the default changed differently was called landed (the merge driver decided it)"
  fi
  [ -z "$FM_TASK_COPY_UNASKED" ] || fail "a differing blob was unknown, not an answer: $FM_TASK_COPY_UNASKED"
  # Control: the default lands the copy's change by a squash.
  w=$(new_world blobs-squash)
  copy="$w/clone"
  printf 'feature\n' > "$copy/feature.txt"; G -C "$copy" add feature.txt; G -C "$copy" commit -q -m "copy adds feature"
  G -C "$copy" rm -q base.txt; G -C "$copy" commit -q -m "copy deletes base"
  printf 'feature\n' > "$w/seed/feature.txt"; G -C "$w/seed" add feature.txt; G -C "$w/seed" rm -q base.txt
  G -C "$w/seed" commit -q -m "squash"; G -C "$w/seed" push -q "$w/origin.git" HEAD:main
  fm_task_copy_content_in_default "$copy" "$copy" main HEAD || fail "control: a squash of the copy's change was not proved: $FM_TASK_COPY_UNASKED"
  # A change made further on the default to the same path is unproved.
  printf 'feature, edited later\n' > "$w/seed/feature.txt"; G -C "$w/seed" commit -q -am "later edit"
  G -C "$w/seed" push -q "$w/origin.git" HEAD:main
  if fm_task_copy_content_in_default "$copy" "$copy" main HEAD; then
    fail "a path the default changed further was proved"
  fi
  # A deletion is proved only when the default lacks the path.
  printf 'restored\n' > "$w/seed/base.txt"; G -C "$w/seed" add base.txt
  printf 'feature\n' > "$w/seed/feature.txt"; G -C "$w/seed" commit -q -am "restore base, undo the later edit"
  G -C "$w/seed" push -q "$w/origin.git" HEAD:main
  if fm_task_copy_content_in_default "$copy" "$copy" main HEAD; then
    fail "a deletion was proved although the default holds the path"
  fi
  pass "the content proof compares blobs: a merge driver cannot land a differing line; a squash lands; a further change or a kept path is unproved"
}

# A renamed remote default is refused rather than read (Main 1871): origin's live
# HEAD names trunk, while the project's recorded origin/HEAD still names main, whose
# old branch is still fetchable. Control: when both name trunk, it is read.
test_renamed_remote_default_is_refused() {
  local w
  w=$(new_world renamed)
  G -C "$w/clone" remote set-head origin main >/dev/null
  G -C "$w/seed" push -q "$w/origin.git" HEAD:trunk
  G --git-dir="$w/origin.git" symbolic-ref HEAD refs/heads/trunk
  if fm_task_copy_live_default "$w/clone" "$w/clone"; then
    fail "origin/HEAD naming main while origin's default is trunk was read as $FM_TASK_COPY_DEFAULT_NAME"
  fi
  case "$FM_TASK_COPY_UNASKED" in *"origin/HEAD names main but origin's default branch is trunk"*) ;; *) fail "the refusal did not name both: $FM_TASK_COPY_UNASKED" ;; esac
  if fm_task_copy_content_in_default "$w/clone" "$w/clone" "" HEAD; then
    fail "the content check proved landing against a renamed default"
  fi
  G -C "$w/clone" fetch -q origin
  G -C "$w/clone" remote set-head origin trunk >/dev/null
  fm_task_copy_live_default "$w/clone" "$w/clone" || fail "control: a matching live default was refused: $FM_TASK_COPY_UNASKED"
  [ "$FM_TASK_COPY_DEFAULT_NAME" = trunk ] || fail "control: the live default was $FM_TASK_COPY_DEFAULT_NAME"
  pass "a renamed remote default whose recorded origin/HEAD differs is refused; a matching one is read live"
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
test_content_proof_is_by_blobs_not_by_merge
test_renamed_remote_default_is_refused
test_pr_list_is_complete_only_within_its_bound
test_archive_tip_goes_only_when_the_default_branch_holds_it
exit "$FAILED"
