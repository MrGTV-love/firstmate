#!/usr/bin/env bash
# Behavior test for the key that stops git's automatic ref packing from deleting
# a registered clone's branch-ref folder (bin/fm-fleet-sync.sh is the one writer
# of maintenance.pack-refs.enabled=false).
#
# Git's own automatic maintenance, started after a commit, an amend, a fetch, an
# advancing merge --ff-only or a rebase once 16 or more loose refs exist, runs
# `git pack-refs --all --prune --auto` and removes the then-empty
# refs/heads/fm folder. A confined worker has no grant to create it again.
#
# Every case runs git the way a worker does: from a LINKED worktree of a clone
# that holds 20 loose refs/heads/fm/* plus main (21 loose refs). The key reaches
# the keyed fixture only by running this checkout's bin/fm-fleet-sync.sh on it,
# never by test setup. Each trigger runs twice: on a keyless control, where
# GIT_TRACE2_EVENT must show the `git pack-refs` child and the folder must be
# gone, so no case passes because maintenance never started, and on the keyed
# clone, where the folder must survive with every loose ref and trace2 must show
# no pack-refs child. maintenance.autoDetach=false makes the runs deterministic;
# one case keeps the default detached run and waits for it by polling trace2
# against a deadline. A control with about 600 loose objects proves object
# garbage collection still runs with the key set.
#
# The fixtures use an empty HOME and XDG_CONFIG_HOME, GIT_CONFIG_GLOBAL=/dev/null
# and GIT_CONFIG_NOSYSTEM=1, so no key can come from global config. Setup runs with
# maintenance.auto=false in the environment so it cannot pack the refs under test;
# the cases themselves run without it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pack-refs-key)
EMPTY_HOME="$TMP_ROOT/empty-home"
mkdir -p "$EMPTY_HOME"
export HOME="$EMPTY_HOME" XDG_CONFIG_HOME="$EMPTY_HOME" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS GIT_TRACE2_EVENT
fm_git_identity fmtest fmtest@example.invalid
printf 'note: %s\n' "$(git --version)"

# setup_quiet <command...>: run a setup command with automatic maintenance off.
setup_quiet() {
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=maintenance.auto GIT_CONFIG_VALUE_0=false "$@"
}

# build_fixture <keyed|keyless>: prints "<home> <clone> <worktree> <origin> <pusher>".
# The clone is projects/proj of an isolated firstmate home.
build_fixture() {
  local mode=$1 home base clone wt origin pusher i
  base=$(mktemp -d "$TMP_ROOT/fx.XXXXXX")
  home="$base/home"
  clone="$home/projects/proj"
  wt="$base/wt"
  origin="$base/origin.git"
  pusher="$base/pusher"
  mkdir -p "$home/projects"
  (
    set -e
    git init -q -b main "$pusher"
    git -C "$pusher" commit -q --allow-empty -m first
    git init -q --bare -b main "$origin"
    git -C "$pusher" remote add origin "$origin"
    git -C "$pusher" push -q origin main
    git clone -q "$origin" "$clone"
    git -C "$clone" config maintenance.autoDetach false
    git -C "$clone" worktree add -q -b fm/task "$wt"
    i=1
    while [ "$i" -le 19 ]; do
      git -C "$clone" branch "fm/o$i"
      i=$((i + 1))
    done
  ) >/dev/null 2>&1 || fail "$mode fixture could not be built"
  if [ "$mode" = keyed ]; then
    # The key arrives through the real writer and nothing else.
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" setup_quiet "$ROOT/bin/fm-fleet-sync.sh" proj >/dev/null 2>&1 \
      || fail "fleet-sync failed on the keyed fixture"
  fi
  printf '%s %s %s %s %s\n' "$home" "$clone" "$wt" "$origin" "$pusher"
}

loose_fm_refs() { find "$1/.git/refs/heads/fm" -type f 2>/dev/null | wc -l | tr -d ' '; }
folder_state() { if [ -d "$1/.git/refs/heads/fm" ]; then echo present; else echo ABSENT; fi; }
trace_children() {  # <trace-file> <argv prefix as JSON fragment>
  grep -F '"event":"child_start"' "$1" 2>/dev/null | grep -qF "$2"
}
has_pack_refs_child() { trace_children "$1" '"argv":["git","pack-refs"'; }
has_maintenance_child() { trace_children "$1" '"argv":["git","maintenance","run"'; }

# prepare_trigger <name> <clone> <wt> <origin> <pusher>: bring the fixture to the
# state where exactly one command is left to run, with maintenance off for setup.
prepare_trigger() {
  local name=$1 clone=$2 wt=$3 pusher=$5
  case "$name" in
    commit) printf 'a\n' > "$wt/f"; git -C "$wt" add f ;;
    amend)
      printf 'a\n' > "$wt/f"; git -C "$wt" add f
      setup_quiet git -C "$wt" commit -q -m setup
      ;;
    fetch)
      git -C "$pusher" commit -q --allow-empty -m advanced
      git -C "$pusher" push -q origin main
      ;;
    merge)
      git -C "$pusher" commit -q --allow-empty -m advanced
      git -C "$pusher" push -q origin main
      setup_quiet git -C "$clone" fetch -q origin
      ;;
    rebase)
      git -C "$pusher" commit -q --allow-empty -m advanced
      git -C "$pusher" push -q origin main
      setup_quiet git -C "$clone" fetch -q origin
      ;;
  esac
}

run_trigger() {  # <name> <clone> <wt> <trace>
  local name=$1 clone=$2 wt=$3 trace=$4
  : > "$trace"
  case "$name" in
    commit) GIT_TRACE2_EVENT="$trace" git -C "$wt" commit -q -m second ;;
    amend) GIT_TRACE2_EVENT="$trace" git -C "$wt" commit -q --amend --no-edit --allow-empty ;;
    fetch) GIT_TRACE2_EVENT="$trace" git -C "$clone" fetch -q origin ;;
    merge) GIT_TRACE2_EVENT="$trace" git -C "$wt" merge -q --ff-only origin/main ;;
    # The producer measurement's rebase shape: a commit, then the rebase. On this git
    # the rebase alone starts no maintenance run (the commit before it does), and the
    # rebase then rewrites its own branch ref, which recreates its own one-file folder,
    # so this trigger is told apart by the pack-refs child and by the loose refs left.
    rebase) GIT_TRACE2_EVENT="$trace" sh -c 'git -C "$1" commit -q --allow-empty -m e && git -C "$1" rebase -q origin/main' sh "$wt" ;;
  esac
}

# assert_local_key <clone>: the key is in the clone's own .git/config, set false,
# and nothing broader was switched off.
local_key_problem() {
  local clone=$1 value origin_file
  value=$(git -C "$clone" config --local --get maintenance.pack-refs.enabled 2>/dev/null) || { echo "key absent from the clone's own config"; return 1; }
  [ "$value" = false ] || { echo "key is '$value', not false"; return 1; }
  origin_file=$(git -C "$clone" config --show-origin --local --get maintenance.pack-refs.enabled | cut -f1)
  origin_file=${origin_file#file:}
  case "$origin_file" in /*) ;; *) origin_file=$(cd "$clone" && cd "$(dirname "$origin_file")" && pwd -P)/$(basename "$origin_file") ;; esac
  [ "$origin_file" = "$(cd "$clone" && pwd -P)/.git/config" ] \
    || { echo "key comes from '$origin_file'"; return 1; }
  if git -C "$clone" config --get maintenance.auto >/dev/null 2>&1; then echo "maintenance.auto is set"; return 1; fi
  return 0
}

test_control_trigger_packs_refs_and_removes_the_folder() {
  local name fx home clone wt origin pusher trace
  for name in commit amend fetch merge rebase; do
    fx=$(build_fixture keyless) || exit 1
    read -r home clone wt origin pusher <<EOF
$fx
EOF
    [ "$(loose_fm_refs "$clone")" -ge 20 ] || fail "control $name: fixture holds fewer than 20 loose fm refs"
    prepare_trigger "$name" "$clone" "$wt" "$origin" "$pusher"
    [ "$(folder_state "$clone")" = present ] || fail "control $name: folder already absent before the trigger"
    trace="$TMP_ROOT/trace-control-$name"
    run_trigger "$name" "$clone" "$wt" "$trace" || fail "control $name: the trigger command failed"
    has_maintenance_child "$trace" || fail "control $name: git started no maintenance run, so the case would pass vacuously"
    has_pack_refs_child "$trace" || fail "control $name: trace2 shows no git pack-refs child without the key"
    [ "$(loose_fm_refs "$clone")" -lt 20 ] || fail "control $name: the loose fm refs were not packed away without the key"
    [ "$name" = rebase ] || assert_equals ABSENT "$(folder_state "$clone")" "control $name: the folder survived without the key"
  done
  pass "without the key each of commit, amend, fetch, merge --ff-only and rebase starts git pack-refs and removes refs/heads/fm (control)"
}

test_keyed_clone_keeps_the_folder_under_every_trigger() {
  local name fx home clone wt origin pusher trace problem
  for name in commit amend fetch merge rebase; do
    fx=$(build_fixture keyed) || exit 1
    read -r home clone wt origin pusher <<EOF
$fx
EOF
    problem=$(local_key_problem "$clone") || fail "keyed $name: $problem"
    [ "$(loose_fm_refs "$clone")" -ge 20 ] || fail "keyed $name: fixture holds fewer than 20 loose fm refs"
    prepare_trigger "$name" "$clone" "$wt" "$origin" "$pusher"
    [ "$(folder_state "$clone")" = present ] || fail "keyed $name: folder absent before the trigger"
    trace="$TMP_ROOT/trace-keyed-$name"
    run_trigger "$name" "$clone" "$wt" "$trace" || fail "keyed $name: the trigger command failed"
    has_maintenance_child "$trace" || fail "keyed $name: git started no maintenance run, so the case proves nothing"
    ! has_pack_refs_child "$trace" || fail "keyed $name: a git pack-refs child still ran"
    assert_equals present "$(folder_state "$clone")" "keyed $name: the folder is gone"
    [ "$(loose_fm_refs "$clone")" -ge 20 ] || fail "keyed $name: loose fm refs were packed away"
  done
  pass "with the key written by fleet-sync, every trigger run from a linked worktree leaves refs/heads/fm and its loose refs"
}

test_the_key_must_be_in_the_clones_own_config() {
  local fx home clone wt origin pusher problem global
  fx=$(build_fixture keyless) || exit 1
  read -r home clone wt origin pusher <<EOF
$fx
EOF
  # Not accepted: the key only in a global file, only in the per-worktree config, or maintenance.auto=false.
  global="$TMP_ROOT/global-config"
  printf '[maintenance "pack-refs"]\n\tenabled = false\n' > "$global"
  if problem=$(GIT_CONFIG_GLOBAL="$global" local_key_problem "$clone"); then
    fail "a key that only a global config carries was accepted as the clone's own key"
  fi
  assert_contains "$problem" "absent from the clone's own config" "global-only key: wrong reason"
  git -C "$clone" config extensions.worktreeConfig true
  git -C "$wt" config --worktree maintenance.pack-refs.enabled false
  if problem=$(local_key_problem "$clone"); then fail "a key written only in a per-worktree config was accepted"; fi
  git -C "$clone" config --unset extensions.worktreeConfig
  git -C "$clone" config maintenance.auto false
  git -C "$clone" config maintenance.pack-refs.enabled false
  if problem=$(local_key_problem "$clone"); then fail "maintenance.auto=false was accepted"; fi
  assert_contains "$problem" "maintenance.auto is set" "maintenance.auto=false: wrong reason"
  pass "the key check rejects a global-only key, a per-worktree-only key and maintenance.auto=false"
}

count_loose_objects() { git -C "$1" count-objects -v | sed -n 's/^count: //p'; }

test_object_gc_stays_available_with_the_key() {
  local fx home clone wt origin pusher i before after
  fx=$(build_fixture keyed) || exit 1
  read -r home clone wt origin pusher <<EOF
$fx
EOF
  # Lower the loose-object trigger of both object tasks git's default automatic
  # maintenance may run: gc, and geometric-repack, whose default rose from 100 to
  # 6700 in git 2.56.
  git -C "$clone" config gc.auto 100
  git -C "$clone" config maintenance.geometric-repack.auto 100
  i=1
  while { [ "$i" -le 600 ] || [ ! -d "$clone/.git/objects/17" ]; } && [ "$i" -lt 4000 ]; do
    printf 'obj %s\n' "$i" | git -C "$clone" hash-object -w --stdin >/dev/null
    i=$((i + 1))
  done
  before=$(count_loose_objects "$clone")
  [ "$before" -ge 500 ] || fail "gc control: fixture holds only $before loose objects"
  git -C "$clone" maintenance run --auto >/dev/null 2>&1 || fail "gc control: maintenance run --auto failed"
  after=$(count_loose_objects "$clone")
  [ "$after" -lt "$before" ] || fail "gc control: the loose object count did not fall ($before -> $after) with the key set"
  assert_equals false "$(git -C "$clone" config --local --get maintenance.pack-refs.enabled)" "gc control: key lost"
  pass "object garbage collection still runs with the key set (loose objects $before -> $after)"
}

# wait_for_maintenance <trace> <seconds>: poll the trace until a maintenance
# process has both started and exited, or the deadline passes. Prints how it ended.
wait_for_maintenance() {
  python3 -I - "$1" "$2" <<'PY'
import json, sys, time
path, seconds = sys.argv[1], float(sys.argv[2])
deadline = time.monotonic() + seconds
while True:
    sids = {}
    try:
        with open(path) as handle:
            for line in handle:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                sid = event.get("sid", "")
                if event.get("event") == "cmd_name" and event.get("name") == "maintenance":
                    sids[sid] = False
                if event.get("event") == "exit" and sid in sids:
                    sids[sid] = True
    except OSError:
        pass
    if sids and all(sids.values()):
        print("finished")
        break
    if time.monotonic() > deadline:
        print("deadline")
        break
    time.sleep(0.1)
PY
}

test_default_detached_maintenance_is_covered_too() {
  local fx home clone wt origin pusher trace state
  for mode in keyless keyed; do
    fx=$(build_fixture "$mode") || exit 1
    read -r home clone wt origin pusher <<EOF
$fx
EOF
    git -C "$clone" config --unset maintenance.autoDetach
    printf 'a\n' > "$wt/f"; git -C "$wt" add f
    trace="$TMP_ROOT/trace-detached-$mode"
    : > "$trace"
    GIT_TRACE2_EVENT="$trace" git -C "$wt" commit -q -m second
    state=$(wait_for_maintenance "$trace" 30)
    assert_equals finished "$state" "detached $mode: the detached maintenance run did not finish within its deadline"
    if [ "$mode" = keyless ]; then
      has_pack_refs_child "$trace" || fail "detached control: no git pack-refs child"
      assert_equals ABSENT "$(folder_state "$clone")" "detached control: the folder survived"
    else
      ! has_pack_refs_child "$trace" || fail "detached keyed: a git pack-refs child ran"
      assert_equals present "$(folder_state "$clone")" "detached keyed: the folder is gone"
    fi
  done
  pass "the default detached maintenance run packs without the key and leaves the folder with it"
}

test_control_trigger_packs_refs_and_removes_the_folder
test_keyed_clone_keeps_the_folder_under_every_trigger
test_the_key_must_be_in_the_clones_own_config
test_object_gc_stays_available_with_the_key
test_default_detached_maintenance_is_covered_too
