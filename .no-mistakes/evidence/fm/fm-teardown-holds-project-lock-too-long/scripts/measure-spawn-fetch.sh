#!/usr/bin/env bash
# Fixture helpers are the repo test fixtures (tests/lib.sh and the fixture head of tests/fm-project-capacity.test.sh).
# Behavior tests for project capacity admission: a project that declares how
# many workers it admits at once on this machine never gets a fresh worker
# launched beyond that number (bin/fm-project-capacity-lib.sh owns the
# contract; bin/fm-spawn.sh runs the check).
#
# Every case drives the real bin/fm-spawn.sh against a real project clone with
# an origin, fake tmux and treehouse binaries that log every call, and a real
# markdown backlog when tasks-axi is installed. A deferred spawn is judged by
# what it left behind - no task record, no rendered launch brief, no endpoint,
# no worktree allocation, and a backlog item still queued - never by wording
# alone.
set -u

# shellcheck source=tests/lib.sh
. "/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M50Z5BM4BGYDHKQ31BMVK6ZB/tests/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-capacity)
DEFER_EXIT=75
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the project's heavy suite for $2.

## Firstmate spec
Exercise project capacity admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

# A Firstmate home with its own backlog (when tasks-axi is installed) and a
# brief for every named task.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

# A case: one home, a project clone with an origin, and fake tmux/treehouse
# that record every call so a deferral can be proved to have created nothing.
make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*)
    # A spawn that is told to hold waits here, after its capacity check and
    # while it still holds the project lock, until the test releases it.
    if [ -n "${FM_FAKE_HOLD:-}" ]; then
      : > "$FM_FAKE_HOLD.reached"
      i=0
      while [ ! -f "$FM_FAKE_HOLD.release" ]; do
        i=$((i + 1))
        [ "$i" -lt 400 ] || exit 1
        sleep 0.05
      done
    fi
    if [ -n "${FM_FAKE_CHECK_HOLDS:-}" ] \
       && ! grep -q '^start=.* operation=teardown retire$' "$FM_FAKE_CHECK_HOLDS" 2>/dev/null; then
      echo "later spawn overtook the earlier queued teardown" >&2
      exit 1
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = lease ] && [ "${2:-}" = --help ]; then
  # Capability query only: an installed Treehouse that predates the lease
  # command rejects it as an unknown command.
  if [ -n "${FM_FAKE_NO_LEASE:-}" ]; then
    echo 'Error: unknown command "lease" for "treehouse"' >&2
    exit 1
  fi
  printf 'Usage:\n  treehouse lease <name> [flags]\n\nFlags:\n      --lease-holder string   Optional label recorded as the lease holder\n'
  exit 0
fi
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "${1:-}" in
  lease)
    if [ -n "${FM_FAKE_NO_LEASE:-}" ]; then
      echo 'Error: unknown command "lease" for "treehouse"' >&2
      exit 1
    fi
    # The installed CLI resolves the pool from the working directory's
    # repository; model that through the repository's registered worktrees.
    [ "$#" -eq 4 ] && [ "$3" = --lease-holder ] && [ -n "$4" ] || exit 2
    state=
    while IFS= read -r line; do
      case "$line" in "worktree "*) wt=${line#worktree } ;; *) continue ;; esac
      [ -f "${wt%/*/*}/treehouse-state.json" ] || continue
      jq -e --arg name "$2" 'any(.worktrees[]; .name == $name)' "${wt%/*/*}/treehouse-state.json" >/dev/null || continue
      state="${wt%/*/*}/treehouse-state.json"
      break
    done < <(git worktree list --porcelain 2>/dev/null)
    [ -n "$state" ] || { echo "Error: no worktree named \"$2\" in pool" >&2; exit 1; }
    jq --arg name "$2" --arg holder "$4" \
      '(.worktrees[] | select(.name == $name)) |= (.leased = true | .lease_holder = $holder)' \
      "$state" > "$state.next" && mv "$state.next" "$state" || exit 1
    ;;
  return)
    [ -z "${FM_FAKE_RETURN_FAILS:-}" ] || { echo "error: provider refused the return" >&2; exit 1; }
    slot=${@: -1}
    state="${slot%/*/*}/treehouse-state.json"
    if [ -f "$state" ]; then
      jq --arg slot "$slot" '(.worktrees[] | select(.path == $slot)).leased = false' \
        "$state" > "$state.next" && mv "$state.next" "$state" || exit 1
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  fm_git_init_commit "$case_dir/other-project"
  fm_git_add_origin "$case_dir/other-project" "$case_dir/other-project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

declare_capacity() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/project-capacity"
}

# A live worker already on a project: the record shape bin/fm-spawn.sh
# publishes, with its backlog item In flight so cleanup can close it.
write_live() {  # <home> <id> <project-dir> [extra-line...]
  local home=$1 id=$2 project=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/absent-worktree-$id" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-$id" \
    "$@"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    add_item "$home" "$id"
    tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  fi
}

# One isolated worktree per spawn, so every admitted launch has its own copy.
new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <case-dir> <id> [pane-path]
  local case_dir=$1 id=$2 pane=${3:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

# Everything a deferred spawn must not have created for <id>; <worktrees-before>
# is worktree_list taken before the spawn.
assert_nothing_created() {  # <case-dir> <home> <id> <calls-before> <worktrees-before>
  local case_dir=$1 home=$2 id=$3 before=$4 worktrees=$5 after
  assert_absent "$home/state/$id.meta" "a deferred spawn published a task record for $id"
  assert_absent "$home/data/$id/launch-brief.md" "a deferred spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a deferred spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a deferred spawn left a git worktree for $id"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" "$id")" = queued ] ||
      fail "a deferred spawn moved $id's backlog item: $(row_state "$home" "$id")"
  fi
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }

# --- cases ------------------------------------------------------------------
# measure-spawn-fetch.sh <code-root> <label> [secs]
# A fresh spawn whose remote fetch is slow (secs), and a second allocator that queues for the same project lock
# one second after the spawn starts. Reports the spawn's project-lock hold and how long the second allocator waited.
UNDER=${1:?code root}; LABEL=${2:?label}; SECS=${3:-8}
SPAWN="$UNDER/bin/fm-spawn.sh"
export FM_PROJECT_LOCK_POLL_SECS=0.1
now() { python3 -c 'import time;print("%.3f" % time.time())'; }
elapsed() { python3 -c "print('%.1f' % ($2 - $1))"; }
case_dir=$(make_case "sf-$LABEL" task-new)
home="$case_dir/home"
next=$(new_worktree "$case_dir" task-new)
cat > "$case_dir/fakebin/git" <<SH
#!/usr/bin/env bash
if [ -n "\${FM_SLOW_SECS:-}" ]; then
  case "\$*" in *fetch*|*ls-remote*) mkdir "$case_dir/delay-owned" 2>/dev/null && { python3 -c 'import time;print("%.3f" % time.time())' > "$case_dir/reached"; sleep "\$FM_SLOW_SECS"; } ;; esac
fi
exec "$(command -v git)" "\$@"
SH
chmod +x "$case_dir/fakebin/git"
t0=$(now)
FM_SLOW_SECS=$SECS FM_FAKE_CALL_LOG="$case_dir/calls.log" spawn_ship "$case_dir" task-new "$next" > "$case_dir/spawn.out" 2>&1 &
sp=$!
i=0; while [ ! -f "$case_dir/reached" ]; do i=$((i+1)); [ "$i" -lt 600 ] || { echo "spawn never reached its fetch"; wait; exit 1; }; sleep 0.05; done
sleep 1
(
  export FM_HOME="$home"; unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
  . "$UNDER/bin/fm-wake-lib.sh"; . "$UNDER/bin/fm-project-lock-lib.sh"
  lock=$(fm_treehouse_project_lock_path "$case_dir/project") || exit 3
  t_q=$(now); fm_project_lock_acquire "$lock" "second-allocator" >/dev/null 2>&1 || exit 4; t_g=$(now)
  fm_project_lock_release "$lock"; printf '%s %s\n' "$t_q" "$t_g" > "$case_dir/second.out"
) &
wp=$!
wait "$wp"; read -r t_q t_g < "$case_dir/second.out"
wait "$sp"; src=$?
holds=$(cat "$home"/state/.treehouse-project-*.lock.holds 2>/dev/null)
sh=$(printf '%s\n' "$holds" | sed -n 's/^.*seconds=\([0-9]*\) .*operation=spawn task-new$/\1/p' | head -1)
printf '%s\tslow_remote_fetch=%ss\tspawn_rc=%s\tspawn_lock_hold=%ss\tsecond_allocator_lock_wait=%ss\n' "$LABEL" "$SECS" "$src" "${sh:-?}" "$(elapsed "$t_q" "$t_g")"
printf '%s\n' "$holds" | sed 's/^/    holds: /'
tail -2 "$case_dir/spawn.out" | sed 's/^/    spawn: /'
