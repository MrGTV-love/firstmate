#!/usr/bin/env bash
# Behavior test for bin/fm-branch-ref-dirs-lib.sh, the one helper that restores a
# project clone's ship-branch folders (refs/heads/<prefix> and
# logs/refs/heads/<prefix>) after a firstmate delete of the last loose ref.
#
# The callers' own routes are covered where they run: the fleet-sync prune in
# tests/fm-fleet-sync.test.sh, teardown's pool route in
# tests/fm-teardown-cleanup.test.sh and its Orca-only route in
# tests/fm-backend-orca.test.sh. This file drives the helper directly over the
# prefix shapes and link shapes those routes cannot all reach: several segments,
# a bare (empty) prefix, a prefix with a dot component or a leading slash, a
# prefix that cannot be read, a link at each component, a dangling link, an
# existing plain file, and a concurrent mkdir.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-branch-ref-dirs)
# shellcheck source=bin/fm-branch-ref-dirs-lib.sh
. "$ROOT/bin/fm-branch-ref-dirs-lib.sh"

# new_clone <registry-token-or-empty>: a repository named "proj" whose registered
# prefix is set by the token (for example "branch=team/fm/"), with refs/heads and
# logs/refs/heads present. Sets CLONE and DATA_DIR.
new_clone() {
  local token=$1 base
  base=$(mktemp -d "$TMP_ROOT/case.XXXXXX")
  CLONE="$base/proj"
  DATA_DIR="$base/data"
  mkdir -p "$DATA_DIR"
  git init -q -b main "$CLONE"
  git -C "$CLONE" commit -q --allow-empty -m first
  git -C "$CLONE" branch seed
  mkdir -p "$CLONE/.git/logs/refs/heads"
  printf -- '- proj [no-mistakes %s] - fixture\n' "$token" > "$DATA_DIR/projects.md"
}

restore() { FM_DATA_OVERRIDE="$DATA_DIR" fm_restore_branch_ref_dirs "$CLONE" proj; }

test_several_segment_prefix_is_made_component_by_component() {
  new_clone "branch=team/fm/"
  restore
  [ -d "$CLONE/.git/refs/heads/team/fm" ] || fail "refs/heads/team/fm was not made"
  [ -d "$CLONE/.git/logs/refs/heads/team/fm" ] || fail "logs/refs/heads/team/fm was not made"
  [ ! -e "$CLONE/.git/refs/heads/fm" ] || fail "the default prefix folder was made for a registered team/fm/"
  pass "a several-segment registered prefix is restored under refs and logs, and only that prefix"
}

test_the_default_prefix_is_used_when_nothing_is_registered() {
  new_clone ""
  printf -- '- other [no-mistakes] - another project\n' > "$DATA_DIR/projects.md"
  restore
  [ -d "$CLONE/.git/refs/heads/fm" ] || fail "an unregistered project did not get the default fm folder"
  pass "an unregistered project resolves to the default fm/ prefix"
}

test_an_empty_or_unsafe_prefix_restores_nothing() {
  local token
  for token in "branch=" "branch=../x/" "branch=a/../b/" "branch=/abs/" "branch=./x/" "branch=a//b/" "branch=."; do
    new_clone "$token"
    restore
    assert_equals "main seed" "$(find "$CLONE/.git/refs/heads" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ' | sed 's/ $//')" "prefix '$token' changed refs/heads"
    [ ! -e "$CLONE/.git/refs/heads/x" ] && [ ! -e "$CLONE/.git/refs/x" ] && [ ! -e "$CLONE/.git/refs/heads/b" ] \
      || fail "prefix '$token' made a folder"
    [ ! -e "$CLONE/.git/abs" ] || fail "prefix '$token' made a folder outside refs"
  done
  pass "an empty prefix and a prefix with a dot, dot-dot, empty or absolute component restore nothing"
}

test_an_unreadable_registry_restores_nothing() {
  new_clone "branch=fix/"
  printf -- '- proj [no-mistakes forge=githb branch=fix/] - malformed forge token\n' > "$DATA_DIR/projects.md"
  # fm-project-mode refuses a malformed forge binding in its default form; --branch-prefix still answers,
  # so the registered prefix is used; a registry that cannot be read at all is the lookup failure.
  restore
  [ -d "$CLONE/.git/refs/heads/fix" ] || fail "--branch-prefix did not answer for a project with a malformed forge token"
  new_clone "branch=fix/"
  local out
  out=$(FM_DATA_OVERRIDE="$DATA_DIR" fm_restore_branch_ref_dirs "$CLONE" "" 2>&1)
  assert_equals "" "$out" "the helper printed something for an empty project name"
  [ ! -e "$CLONE/.git/refs/heads/fix" ] || fail "an empty project name made a folder"
  pass "an unreadable project lookup restores nothing and prints nothing"
}

test_links_and_files_at_any_component_are_never_followed_or_replaced() {
  local outside shape
  for shape in first-link second-link dangling-link plain-file logs-link; do
    new_clone "branch=team/fm/"
    outside="$CLONE/../outside-$shape"
    mkdir -p "$outside"
    case "$shape" in
      first-link) ln -s "$outside" "$CLONE/.git/refs/heads/team" ;;
      second-link) mkdir "$CLONE/.git/refs/heads/team"; ln -s "$outside" "$CLONE/.git/refs/heads/team/fm" ;;
      dangling-link) ln -s "$outside/nowhere" "$CLONE/.git/refs/heads/team" ;;
      plain-file) printf 'x\n' > "$CLONE/.git/refs/heads/team" ;;
      logs-link) ln -s "$outside" "$CLONE/.git/logs/refs/heads/team" ;;
    esac
    restore
    assert_equals "" "$(ls -A "$outside")" "$shape: something was made behind the link"
    [ ! -e "$outside/nowhere" ] || fail "$shape: the dangling target was created"
    case "$shape" in
      first-link|dangling-link) [ -L "$CLONE/.git/refs/heads/team" ] || fail "$shape: the link was replaced" ;;
      second-link) [ -L "$CLONE/.git/refs/heads/team/fm" ] || fail "$shape: the inner link was replaced" ;;
      plain-file) [ -f "$CLONE/.git/refs/heads/team" ] || fail "$shape: the file was replaced" ;;
      logs-link) [ -L "$CLONE/.git/logs/refs/heads/team" ] || fail "$shape: the logs link was replaced"
        [ -d "$CLONE/.git/refs/heads/team/fm" ] || fail "$shape: the refs side was not restored although only the logs side was blocked" ;;
    esac
  done
  pass "a link, a dangling link or a file at any component is never followed or replaced"
}

test_a_link_at_refs_heads_itself_is_left_alone() {
  local outside
  new_clone "branch=fm/"
  outside="$CLONE/../outside-heads"
  mkdir -p "$outside"
  mv "$CLONE/.git/refs/heads" "$CLONE/.git/refs/heads.real"
  ln -s "$outside" "$CLONE/.git/refs/heads"
  restore
  assert_equals "" "$(ls -A "$outside")" "the restore followed a link at refs/heads"
  pass "a link at refs/heads itself is never followed"
}

test_existing_folders_and_a_concurrent_mkdir_change_nothing() {
  new_clone "branch=fm/"
  mkdir -p "$CLONE/.git/refs/heads/fm"
  : > "$CLONE/.git/refs/heads/fm/keep"
  restore
  [ -f "$CLONE/.git/refs/heads/fm/keep" ] || fail "an existing folder lost its content"
  # A concurrent actor makes the folder between the helper's test and its mkdir: a mkdir shim does it.
  new_clone "branch=fm/"
  local shim="$TMP_ROOT/racebin"
  mkdir -p "$shim"
  cat > "$shim/mkdir" <<SH
#!/bin/sh
/bin/mkdir "\$@"
/bin/mkdir "\$@" 2>/dev/null
exit 1
SH
  chmod +x "$shim/mkdir"
  PATH="$shim:$PATH" FM_DATA_OVERRIDE="$DATA_DIR" fm_restore_branch_ref_dirs "$CLONE" proj || fail "the helper failed its caller when mkdir lost a race"
  [ -d "$CLONE/.git/refs/heads/fm" ] || fail "the folder is absent after a race the other actor won"
  pass "an existing folder keeps its content, and losing a mkdir race neither fails nor leaves the folder absent"
}

test_a_linked_worktree_restores_in_the_shared_git_dir() {
  local wt
  new_clone "branch=fm/"
  wt="$CLONE/../wt"
  git -C "$CLONE" worktree add -q -b other "$wt"
  FM_DATA_OVERRIDE="$DATA_DIR" fm_restore_branch_ref_dirs "$wt" proj
  [ -d "$CLONE/.git/refs/heads/fm" ] || fail "called from a linked worktree, the shared refs/heads/fm was not restored"
  [ -d "$CLONE/.git/logs/refs/heads/fm" ] || fail "called from a linked worktree, the shared logs folder was not restored"
  [ ! -e "$CLONE/.git/worktrees/wt/refs/heads/fm" ] || fail "a folder was made in the per-worktree git dir"
  pass "called from a linked worktree, the helper restores the shared clone's folders"
}

test_several_segment_prefix_is_made_component_by_component
test_the_default_prefix_is_used_when_nothing_is_registered
test_an_empty_or_unsafe_prefix_restores_nothing
test_an_unreadable_registry_restores_nothing
test_links_and_files_at_any_component_are_never_followed_or_replaced
test_a_link_at_refs_heads_itself_is_left_alone
test_existing_folders_and_a_concurrent_mkdir_change_nothing
test_a_linked_worktree_restores_in_the_shared_git_dir
