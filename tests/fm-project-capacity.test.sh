#!/usr/bin/env bash
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
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "${1:-}" in
  lease)
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

# The reported incident's shape before any declaration: the project is already
# busy, and nothing caps a further launch. Absent a declaration that stays true.
test_undeclared_capacity_keeps_dispatch_uncapped() {
  local case_dir home out rc=0
  case_dir=$(make_case undeclared task-c)
  home="$case_dir/home"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "an undeclared project refused a spawn: $out"
  assert_contains "$out" "spawned task-c" "an undeclared project did not launch the worker"
  assert_present "$home/state/task-c.meta" "an undeclared project's spawn published no record"
  pass "a project with no declared capacity keeps today's uncapped dispatch"
}

test_available_capacity_admits_the_worker() {
  local case_dir home out rc=0
  case_dir=$(make_case available task-c)
  home="$case_dir/home"
  declare_capacity "$home" "# heavy suite serves two workers" "project 2" "other-project 1"
  write_live "$home" live-a "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a spawn with a free place was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn with a free place did not launch"
  assert_not_contains "$out" "deferred:" "a spawn with a free place reported a deferral"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" task-c)" = in_flight ] || fail "an admitted spawn did not move its item In flight"
  fi
  pass "a spawn is admitted while its project still has a free place"
}

test_exhausted_capacity_defers_without_leaving_anything_behind() {
  local case_dir home out rc=0 before worktrees
  case_dir=$(make_case exhausted task-c)
  home="$case_dir/home"
  declare_capacity "$home" "project 2"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a spawn beyond capacity was not deferred: $out"
  assert_contains "$out" "deferred: project project admits 2 worker(s) at once on this machine ($home/config/project-capacity) and 2 already hold a place (live-a, live-b)" \
    "the deferral did not name the capacity and its holders"
  assert_contains "$out" "task task-c was not launched and its backlog item stays queued" \
    "the deferral did not say the task stays queued"
  assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  pass "a spawn beyond capacity is deferred before any record, brief, endpoint, worktree, or backlog move exists"
}

# The capacity is the last field, so a project whose clone directory name holds
# spaces can be declared. An indented '#' line is still a comment.
test_spaced_project_name_is_declared() {
  local case_dir home spaced out rc=0
  case_dir=$(make_case spaced task-c)
  home="$case_dir/home"
  spaced="$case_dir/my  heavy project"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$spaced"
  declare_capacity "$home" "   # my  heavy project 9" "my  heavy project 1" "project 5"
  write_live "$home" live-a "$spaced"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-c "$spaced" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a project whose name holds spaces was not capped by its declaration: $out"
  assert_contains "$out" "deferred: project my  heavy project admits 1 worker(s) at once" \
    "the deferral did not use the spaced project's declared capacity"
  assert_absent "$home/state/task-c.meta" "the deferred spaced-name spawn published a record"
  pass "a project name with spaces is declared by taking the capacity from the last field"
}

# A clone directory may be named with a leading '#'. That name is declared when
# the '#' is written against the rest of the name and the line ends with the
# capacity. A '#' followed by whitespace stays a comment even when the line
# ends with a number, and a '#' note that is not a capacity stays a comment.
test_hash_prefixed_project_name_is_declared() {
  local case_dir home hashed spaced out rc=0 wt
  case_dir=$(make_case hash-name task-c task-d)
  home="$case_dir/home"
  hashed="$case_dir/#hash-project"
  spaced="$case_dir/# serves"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$hashed"
  git clone -q "$(git -C "$case_dir/other-project" remote get-url origin)" "$spaced"
  declare_capacity "$home" "# serves 2" "#not-a-capacity" "#hash-project 1"
  write_live "$home" live-a "$hashed"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-c "$hashed" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a project whose name begins with # was not capped by its declaration: $out"
  assert_contains "$out" "deferred: project #hash-project admits 1 worker(s) at once" \
    "the deferral did not use the hash-prefixed project's declared capacity"
  assert_absent "$home/state/task-c.meta" "the deferred hash-prefixed spawn published a record"

  write_live "$home" live-b "$spaced"
  write_live "$home" live-c "$spaced"
  git -C "$spaced" worktree add --quiet -b wt-d "$case_dir/wt-d"
  wt="$case_dir/wt-d"
  rc=0
  out=$(run_spawn "$case_dir" "$home" "$wt" task-d "$spaced" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a '#' comment that ends with a number was read as a capacity: $out"
  assert_contains "$out" "spawned task-d" "a project whose declaration line is a comment did not stay uncapped"
  pass "a project name beginning with # is declared, and a # comment stays a comment"
}

# A home reached through a symlink is still one home: its workers hold one
# place each, not one per spelling of its state directory.
test_symlinked_home_counts_each_worker_once() {
  local case_dir home out rc=0
  case_dir=$(make_case symlinked-home task-c)
  home="$case_dir/home"
  ln -s "$home" "$case_dir/home-link"
  declare_capacity "$home" "project 2"
  write_live "$home" live-a "$case_dir/project"
  out=$(run_spawn "$case_dir" "$case_dir/home-link" "$(new_worktree "$case_dir" task-c)" \
    task-c "$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a spawn through a symlinked home counted its own worker twice: $out"
  assert_contains "$out" "spawned task-c" "a spawn through a symlinked home did not launch"
  pass "a home reached through a symlink counts each of its workers once"
}

# A fresh spawn that restarts an existing task id replaces that task's own
# record, so the record does not hold a place against it. Any other task on the
# project still sees that record as a holder.
test_restart_does_not_count_its_own_record() {
  local case_dir home out rc=0
  case_dir=$(make_case restart task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  fm_write_meta "$home/state/task-c.meta" \
    "window=firstmate:fm-task-c" \
    "project=$case_dir/project" \
    "kind=ship"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  assert_not_contains "$out" "deferred:" "a restart was deferred by its own record"
  [ "$rc" -ne "$DEFER_EXIT" ] || fail "a restart exited with the deferral code: $out"
  rc=0
  out=$(spawn_ship "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "another task ignored the restarted task's place: $out"
  assert_contains "$out" "1 already hold a place (task-c)" "another task did not count the restarted task"
  pass "a restart of a task id does not count that task's own record"
}

# A place frees when a worker records its ready PR and when a task is cleaned
# up; each release admits exactly one more worker.
test_release_frees_a_place() {
  local case_dir home out rc=0
  case_dir=$(make_case release task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" "project 2"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the full project admitted a worker: $out"

  # PR handoff: the line bin/fm-pr-check.sh records for a ready PR.
  printf 'pr=%s\n' "https://github.com/o/r/pull/7" >> "$home/state/live-a.meta"
  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a recorded PR handoff did not free a place: $out"
  rc=0
  out=$(spawn_ship "$case_dir" task-d "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "one freed place admitted two workers: $out"
  assert_contains "$out" "2 already hold a place (live-b, task-c)" "the new worker did not take the freed place"

  # Cleanup of unfinished work needs retained captain discard words; it must
  # not record a PR handoff, which would free the place before teardown.
  rc=0
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" live-b --force --drop-file "$(fm_test_drop_file)" 2>&1) || rc=$?
  expect_code 0 "$rc" "cleanup of a live worker failed: $out"
  assert_absent "$home/state/live-b.meta" "cleanup left the worker's record"
  rc=0
  out=$(spawn_ship "$case_dir" task-d) || rc=$?
  expect_code 0 "$rc" "cleanup did not free a place: $out"
  pass "a recorded PR handoff or a cleanup each frees exactly one place"
}

# Only workers on the same project identity hold places: a secondmate record, a
# record for another project, and a scout on another project are ignored, while
# a scout and a legacy record without kind= on this project count.
test_occupancy_counts_only_this_projects_workers() {
  local case_dir home out rc=0
  case_dir=$(make_case occupancy task-c)
  home="$case_dir/home"
  declare_capacity "$home" "project 3"
  write_live "$home" scout-a "$case_dir/project"
  sed -i.bak 's/^kind=ship$/kind=scout/' "$home/state/scout-a.meta" && rm -f "$home/state/scout-a.meta.bak"
  fm_write_meta "$home/state/legacy-b.meta" "window=firstmate:fm-legacy-b" "project=$case_dir/project"
  write_live "$home" other-c "$case_dir/other-project"
  fm_write_meta "$home/state/mate-d.meta" "window=remote:mate-d" "project=$case_dir/project" "kind=secondmate"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "records outside this project's workers took a place: $out"
  rc=0
  write_brief "$home" task-e
  add_item "$home" task-e
  out=$(spawn_ship "$case_dir" task-e "$case_dir/unused") || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "the third worker on the project was not counted: $out"
  assert_contains "$out" "3 already hold a place (legacy-b, scout-a, task-c)" \
    "occupancy counted the wrong records"
  pass "only this project's ship and scout records hold places"
}

# Capacity belongs to the machine: a local secondmate home's workers on a
# separate clone of the same origin count, the declaration comes from the root
# home even when the secondmate spawns, and a remote home's workers never count.
test_capacity_is_shared_by_every_local_home() {
  local case_dir root mate out rc=0 mate_project
  case_dir=$(make_case machine)
  root="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate" task-m
  mate_project="$mate/projects/project"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$mate_project"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$root/data/secondmates.md"
  printf -- '- far - a remote mate (host: far.example; root: /srv/fm; home: %s/remote-home; scope: other; projects: project; added 2026-09-01)\n' "$case_dir" \
    >> "$root/data/secondmates.md"
  mkdir -p "$case_dir/remote-home/state"
  fm_write_meta "$case_dir/remote-home/state/far-x.meta" "window=w" "project=$case_dir/project" "kind=ship"
  declare_capacity "$root" "project 1"
  write_live "$root" live-a "$case_dir/project"
  git -C "$mate_project" worktree add --quiet -b wt-m "$case_dir/wt-m"
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a local secondmate launched past the machine's capacity: $out"
  assert_contains "$out" "admits 1 worker(s) at once on this machine ($root/config/project-capacity) and 1 already hold a place (live-a in $root)" \
    "the secondmate did not count the root home's worker against the root's declaration"
  assert_absent "$mate/state/task-m.meta" "the deferred secondmate spawn published a record"
  printf 'pr=%s\n' "https://github.com/o/r/pull/8" >> "$root/state/live-a.meta"
  rc=0
  out=$(run_spawn "$case_dir" "$mate" "$case_dir/wt-m" task-m "$mate_project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "the remote home's worker, or a handed-off one, took the machine's place: $out"
  pass "every local home shares one declared capacity per project origin, and remote homes do not count"
}

# A local home's state directory or task record that cannot be read could hide a
# holder, so admission refuses instead of counting without it.
test_unreadable_holders_refuse_admission() {
  local case_dir root mate out rc=0
  if [ "$(id -u)" = 0 ]; then
    printf 'ok - skipped the unreadable-holder case (root reads files regardless of mode)\n'
    return 0
  fi
  case_dir=$(make_case unreadable-holders task-c)
  root="$case_dir/home"
  mate="$case_dir/mate"
  make_home "$mate"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root" > "$mate/.fm-secondmate-parent"
  printf -- '- mate - a local mate (home: %s; scope: project work; projects: project; added 2026-09-01)\n' "$mate" \
    > "$root/data/secondmates.md"
  declare_capacity "$root" "project 2"

  write_live "$root" live-a "$case_dir/project"
  chmod 000 "$root/state/live-a.meta"
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  chmod 600 "$root/state/live-a.meta"
  expect_code 1 "$rc" "an unreadable task record did not refuse admission: $out"
  assert_contains "$out" "task record $root/state/live-a.meta cannot be read" \
    "the refusal did not name the unreadable task record"
  assert_absent "$root/state/task-c.meta" "a spawn published past an unreadable task record"

  chmod 000 "$mate/state"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  chmod 755 "$mate/state"
  expect_code 1 "$rc" "an unreadable local state directory did not refuse admission: $out"
  assert_contains "$out" "local Firstmate state directory $mate/state cannot be read" \
    "the refusal did not name the unreadable state directory"
  assert_absent "$root/state/task-c.meta" "a spawn published past an unreadable state directory"

  printf '# No mates\n' > "$mate/data/secondmates.md"
  chmod 000 "$mate/data/secondmates.md"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  chmod 600 "$mate/data/secondmates.md"
  expect_code 1 "$rc" "an unreadable registry did not refuse admission: $out"
  assert_contains "$out" "local Firstmate registry cannot be read at $mate/data/secondmates.md" \
    "capacity admission did not propagate the registry refusal"
  assert_absent "$root/state/task-c.meta" "a spawn published past an unreadable registry"

  rc=0
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a readable machine did not admit the worker: $out"
  pass "an unreadable state directory or task record refuses admission rather than undercounting"
}

# Two spawns racing for the last place: the one holding the project lock
# publishes, the other cannot publish while it waits and is deferred afterwards.
test_concurrent_spawns_cannot_both_take_the_last_place() {
  local case_dir home out rc=0 hold i wt
  case_dir=$(make_case concurrent task-a task-b)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  hold="$case_dir/hold"
  wt=$(new_worktree "$case_dir" task-a)
  FM_FAKE_HOLD="$hold" spawn_ship "$case_dir" task-a "$wt" > "$case_dir/a.out" 2>&1 &
  i=0
  while [ ! -f "$hold.reached" ]; do
    i=$((i + 1))
    [ "$i" -lt 400 ] || fail "the first spawn never reached its launch: $(cat "$case_dir/a.out")"
    sleep 0.05
  done
  spawn_ship "$case_dir" task-b "$case_dir/unused" > "$case_dir/b.out" 2>&1 &
  local waiter=$!
  i=0
  while ! grep -q 'fm-project-lock: waiting' "$case_dir/b.out"; do
    i=$((i + 1))
    [ "$i" -lt 400 ] || fail "the second spawn never queued: $(cat "$case_dir/b.out")"
    sleep 0.05
  done
  assert_absent "$home/state/task-b.meta" "a concurrent spawn published past the last place"
  : > "$hold.release"
  wait "$waiter" || rc=$?
  wait || true
  assert_contains "$(cat "$case_dir/a.out")" "spawned task-a" "the lock-holding spawn did not finish"
  out=$(cat "$case_dir/b.out")
  expect_code "$DEFER_EXIT" "$rc" "the waiting spawn was not deferred once the place was taken: $out"
  assert_absent "$home/state/task-b.meta" "the waiting spawn published past capacity"
  pass "concurrent spawns can never both take the last place"
}

# A spawn that fails after admission removes nothing it did not create and
# leaves no record, so it holds no place afterwards.
test_failed_spawn_after_admission_holds_no_place() {
  local case_dir home out rc=0
  case_dir=$(make_case failed task-a task-b)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  printf '%s\n' '# Task' "## Captain's intent" '{TASK}' '' '## Firstmate spec' 'x' > "$home/data/task-a/brief.md"
  out=$(spawn_ship "$case_dir" task-a "$case_dir/unused") || rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne "$DEFER_EXIT" ] || fail "an invalid brief did not fail after admission (exit $rc): $out"
  assert_contains "$out" "still contains {TASK}" "the spawn did not fail where expected"
  assert_absent "$home/state/task-a.meta" "the failed spawn left a record"
  rc=0
  out=$(spawn_ship "$case_dir" task-b) || rc=$?
  expect_code 0 "$rc" "a failed spawn kept holding the only place: $out"
  pass "a spawn that fails after admission leaves no record and holds no place"
}

test_unreadable_declaration_refuses_every_spawn() {
  local case_dir home out rc label body before worktrees
  case_dir=$(make_case unreadable task-c)
  home="$case_dir/home"
  while IFS='|' read -r label body; do
    [ -n "$label" ] || continue
    printf '%b' "$body" > "$home/config/project-capacity"
    before=$(call_count "$case_dir")
    worktrees=$(worktree_list "$case_dir")
    rc=0
    out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
    expect_code 1 "$rc" "$label: an unreadable declaration did not refuse: $out"
    assert_contains "$out" "the project capacity declaration is unreadable" "$label: the refusal did not name the declaration"
    assert_nothing_created "$case_dir" "$home" task-c "$before" "$worktrees"
  done <<'ROWS'
missing capacity|project\n
zero capacity|project 0\n
non-numeric capacity|other-project two\n
trailing text|project 2 # suite\n
named twice|project 2\nproject 3\n
ROWS
  rm -f "$home/config/project-capacity"
  mkdir "$home/config/project-capacity"
  rc=0
  out=$(spawn_ship "$case_dir" task-c "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a declaration that is not a file did not refuse: $out"
  pass "an unreadable declaration refuses every fresh spawn rather than guessing the limit"
}

test_batch_reports_a_deferred_pair() {
  local case_dir home out rc=0
  case_dir=$(make_case batch task-c)
  home="$case_dir/home"
  declare_capacity "$home" "project 1"
  write_live "$home" live-a "$case_dir/project"
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" "task-c=$case_dir/project" --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "a batch whose only pair was deferred did not exit with the deferral status: $out"
  assert_contains "$out" "batch: DEFERRED task-c ($case_dir/project) - its project is at capacity, so it stays queued" \
    "the batch did not report the deferral"
  assert_not_contains "$out" "batch: FAILED" "the batch reported a deferral as a failure"
  pass "a batch reports a capacity deferral as deferred, not failed"
}

# Orca owns its own worktrees and never takes the Treehouse allocation lock, so
# a declared capacity is what makes an Orca spawn take the shared project lock,
# even from an uncapped clone of a capped origin whose worker would still hold a
# place: it refuses while another holder has it, and defers at capacity before
# asking Orca for anything but its runtime status.
test_orca_spawn_is_admitted_under_the_shared_project_lock() {
  local case_dir home out rc=0 holder i lock clone waiter
  command -v node >/dev/null 2>&1 || {
    printf 'ok - skipped the Orca capacity case (node, which the Orca status check needs, is not installed)\n'
    return 0
  }
  case_dir=$(make_case orca task-o)
  home="$case_dir/home"
  cat > "$case_dir/fakebin/orca" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = status ]; then
  printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
  exit 0
fi
printf 'orca %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 1
SH
  chmod +x "$case_dir/fakebin/orca"
  git clone -q "$(git -C "$case_dir/project" remote get-url origin)" "$case_dir/project-2"
  declare_capacity "$home" "project 1"

  # shellcheck disable=SC2016 # expanded by the holder's own shell
  FM_HOME="$home" FM_STATE_OVERRIDE='' bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_treehouse_project_lock_path "$2") || exit 1
    fm_lock_try_acquire "$lock" || exit 1
    printf "%s\n" "$lock" > "$3.held"
    while [ ! -f "$3.release" ]; do sleep 0.05; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$case_dir/project" "$case_dir/holder" &
  holder=$!
  i=0
  while [ ! -s "$case_dir/holder.held" ]; do
    i=$((i + 1))
    [ "$i" -lt 200 ] || fail "the lock holder never took the project lock"
    sleep 0.05
  done
  lock=$(cat "$case_dir/holder.held")
  # The capped clone and an uncapped same-origin clone both queue on the one
  # project lock, stay queued behind the live holder, and refuse at its stall.
  for clone in project project-2; do
    FM_PROJECT_LOCK_SERVICE_SECS=3 run_spawn "$case_dir" "$home" "$case_dir/unused" task-o "$case_dir/$clone" \
      --backend orca --mode no-mistakes --yolo off > "$case_dir/$clone.out" 2>&1 &
    waiter=$!
    wait_actor_output "$case_dir/$clone.out" 'fm-project-lock: waiting'
    assert_equals 1 "$(queued_tickets "$lock")" "the Orca spawn from $clone did not register on the shared project queue"
    assert_absent "$home/state/task-o.meta" "the queued Orca spawn from $clone published a record before admission"
    rc=0
    wait "$waiter" || rc=$?
    out=$(cat "$case_dir/$clone.out")
    expect_code 1 "$rc" "an Orca spawn from $clone ignored a held project lock: $out"
    assert_contains "$out" "fm-project-lock: stall limit reached" "the Orca spawn from $clone did not refuse at the project lock's stall limit"
    assert_contains "$out" "(PID $holder)" "the Orca spawn from $clone did not name the live holder"
    assert_equals "$holder" "$(cat "$lock/pid" 2>/dev/null)" "the stall refusal removed or replaced the live Orca capacity holder"
    assert_equals 0 "$(queued_tickets "$lock")" "the refused Orca spawn from $clone left its queue ticket"
  done
  kill -0 "$holder" || fail "bounded contention removed the live Orca capacity holder"
  : > "$case_dir/holder.release"
  wait "$holder" || true
  assert_absent "$home/state/task-o.meta" "the uncapped clone's Orca spawn published a record while the lock was held"
  assert_no_grep "orca " "$case_dir/calls.log" "the Orca spawn asked Orca for more than its runtime status"

  write_live "$home" live-a "$case_dir/project"
  rc=0
  out=$(run_spawn "$case_dir" "$home" "$case_dir/unused" task-o "$case_dir/project" \
    --backend orca --mode no-mistakes --yolo off) || rc=$?
  expect_code "$DEFER_EXIT" "$rc" "an Orca spawn beyond capacity was not deferred: $out"
  assert_absent "$home/state/task-o.meta" "the deferred Orca spawn published a record"
  assert_no_grep "orca " "$case_dir/calls.log" "the deferred Orca spawn created an Orca worktree"
  pass "an Orca spawn takes the shared project lock whenever a same-origin clone is capped and defers before creating anything"
}

project_queue_actor() {  # <case-dir> <operation> [release-marker] [hold-secs] [acquire|try]
  FM_HOME="$1/home" FM_STATE_OVERRIDE='' bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-project-lock-lib.sh"
    if [ "$6" = try ]; then
      fm_project_lock_try "$2/actor.lock" "$3" || exit 1
    else
      fm_project_lock_acquire "$2/actor.lock" "$3" || exit 1
    fi
    printf "%s\n" "$3" >> "$2/order"
    : > "$2/$3.acquired"
    if [ -n "$4" ]; then
      i=0
      while [ ! -e "$4" ]; do
        i=$((i + 1)); [ "$i" -lt 4000 ] || exit 1
        sleep 0.05
      done
    fi
    [ -z "$5" ] || sleep "$5"
    fm_project_lock_release "$2/actor.lock"
  ' _ "$ROOT" "$1" "$2" "${3:-}" "${4:-}" "${5:-acquire}"
}

queued_tickets() {  # <project-lock>
  local ticket count=0
  for ticket in "$1.queue"/ticket-*; do
    [ ! -L "$ticket" ] || count=$((count + 1))
  done
  printf '%s\n' "$count"
}

wait_actor_output() {  # <file> <literal>
  local i=0
  while ! grep -Fq "$2" "$1" 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 1000 ] || fail "actor did not report $2: $(cat "$1" 2>/dev/null)"
    sleep 0.05
  done
}

test_project_queue_recovers_dead_waiter_and_holder() {
  local case_dir holder dead survivor rc=0
  case_dir=$(make_case queue-deaths)
  project_queue_actor "$case_dir" holder "$case_dir/release" > "$case_dir/holder.out" 2>&1 &
  holder=$!
  wait_actor_output "$case_dir/order" holder
  project_queue_actor "$case_dir" dead > "$case_dir/dead.out" 2>&1 &
  dead=$!
  wait_actor_output "$case_dir/dead.out" 'fm-project-lock: waiting'
  project_queue_actor "$case_dir" survivor > "$case_dir/survivor.out" 2>&1 &
  survivor=$!
  wait_actor_output "$case_dir/survivor.out" 'fm-project-lock: waiting'
  # These are the private actor shells, not a worker runtime or shared service.
  # Their child shell owns the lock, so terminate the recorded owner explicitly.
  local dead_pid holder_pid
  dead_pid=
  # Find the queued dead actor by its immutable operation label, not PID order.
  local ticket
  for ticket in "$case_dir/actor.lock.queue"/ticket-*; do
    [ "$(cat "$ticket/role" 2>/dev/null)" != dead ] || dead_pid=$(cat "$ticket/pid")
  done
  kill -KILL "$dead_pid"
  wait "$dead" 2>/dev/null || true
  assert_equals holder "$(cat "$case_dir/order")" "a dead waiter made a survivor bypass the live holder"
  holder_pid=$(cat "$case_dir/actor.lock/pid")
  kill -KILL "$holder_pid"
  wait "$holder" 2>/dev/null || true
  wait "$survivor" || rc=$?
  expect_code 0 "$rc" "a dead waiter or holder stranded the survivor: $(cat "$case_dir/survivor.out")"
  assert_equals "$(printf 'holder\nsurvivor')" "$(cat "$case_dir/order")" "dead actor recovery changed FIFO or admitted the dead waiter"
  assert_absent "$case_dir/actor.lock" "the survivor did not release the recovered lock"
  pass "dead queued waiters are skipped and dead project holders are reclaimed without bypassing a live holder"
}

test_project_queue_timeout_preserves_live_holder() {
  local case_dir holder holder_pid waiter rc=0
  case_dir=$(make_case queue-timeout)
  project_queue_actor "$case_dir" holder "$case_dir/release" > "$case_dir/holder.out" 2>&1 &
  holder=$!
  wait_actor_output "$case_dir/order" holder
  holder_pid=$(cat "$case_dir/actor.lock/pid")
  FM_PROJECT_LOCK_SERVICE_SECS=10 project_queue_actor "$case_dir" timeout > "$case_dir/waiter.out" 2>&1 &
  waiter=$!
  wait "$waiter" || rc=$?
  expect_code 1 "$rc" "a timed-out waiter was admitted past a live holder"
  assert_contains "$(cat "$case_dir/waiter.out")" 'fm-project-lock: stall limit reached' "the waiter did not refuse at the holder's stall limit"
  assert_equals "$holder_pid" "$(cat "$case_dir/actor.lock/pid")" "timeout removed or replaced the live holder"
  kill -0 "$holder_pid" || fail "timeout killed the live holder"
  assert_equals holder "$(cat "$case_dir/order")" "the timed-out operation ran"
  assert_contains "$(cat "$case_dir/waiter.out")" 'current holder holder (PID' "progress did not identify the holder"
  : > "$case_dir/release"
  wait "$holder" || fail "the live holder could not release after timeout"
  project_queue_actor "$case_dir" after > "$case_dir/after.out" 2>&1 || fail "a timed-out ticket blocked the next waiter"
  assert_equals "$(printf 'holder\nafter')" "$(cat "$case_dir/order")" "timeout did not remove only its own ticket"
  pass "bounded waiting identifies and preserves the live holder and removes its own expired ticket"
}

# The reviewed slow-holder sequence: one holder outlasts the allowance while W1
# and then W2 queue behind it. A deadline counted from each waiter's arrival
# and widened by its queue position refused W1 at its own limit and then
# admitted the later W2 once the holder left. The stall clock follows the
# holder instead, so both refuse together and W2 never goes ahead of W1.
test_project_queue_slow_holder_never_admits_a_later_waiter_first() {
  local case_dir holder w1 w2 i rc1=0 rc2=0
  case_dir=$(make_case queue-slow-holder)
  project_queue_actor "$case_dir" holder "$case_dir/release" > "$case_dir/holder.out" 2>&1 &
  holder=$!
  wait_actor_output "$case_dir/order" holder
  FM_PROJECT_LOCK_SERVICE_SECS=8 FM_PROJECT_LOCK_POLL_SECS=0.1 \
    project_queue_actor "$case_dir" w1 > "$case_dir/w1.out" 2>&1 &
  w1=$!
  wait_actor_output "$case_dir/w1.out" 'fm-project-lock: waiting'
  FM_PROJECT_LOCK_SERVICE_SECS=8 FM_PROJECT_LOCK_POLL_SECS=0.1 \
    project_queue_actor "$case_dir" w2 > "$case_dir/w2.out" 2>&1 &
  w2=$!
  wait_actor_output "$case_dir/w2.out" 'fm-project-lock: waiting'
  wait "$w1" || rc1=$?
  i=0
  while kill -0 "$w2" 2>/dev/null && [ "$i" -lt 60 ]; do
    i=$((i + 1))
    sleep 0.1
  done
  : > "$case_dir/release"
  wait "$holder" || fail "the slow holder could not release: $(cat "$case_dir/holder.out")"
  wait "$w2" || rc2=$?
  expect_code 1 "$rc1" "the earliest waiter was admitted past a stalled holder: $(cat "$case_dir/w1.out")"
  expect_code 1 "$rc2" "a later waiter was admitted after the earliest one refused: $(cat "$case_dir/w2.out")"
  assert_contains "$(cat "$case_dir/w1.out")" 'fm-project-lock: stall limit reached' "the earliest waiter did not refuse at the holder's stall"
  assert_contains "$(cat "$case_dir/w2.out")" 'fm-project-lock: stall limit reached' "the later waiter did not refuse at the same holder's stall"
  assert_equals holder "$(cat "$case_dir/order")" "a later waiter went ahead of a refused earlier one"
  pass "a stalled holder refuses its waiters together, so a later waiter never goes ahead of an earlier one"
}

# Each 6-second hold is well inside a 20-second allowance, but the last waiter
# queues behind four of them: earlier tickets' progress never refuses it.
test_project_queue_progress_never_reaches_the_stall_limit() {
  local case_dir name rc pid
  local -a names=(w1 w2 w3 w4 w5) pids=()
  case_dir=$(make_case queue-progress)
  FM_PROJECT_LOCK_SERVICE_SECS=20 project_queue_actor "$case_dir" holder "$case_dir/release" > "$case_dir/holder.out" 2>&1 &
  pids+=("$!")
  wait_actor_output "$case_dir/order" holder
  for name in "${names[@]}"; do
    FM_PROJECT_LOCK_SERVICE_SECS=20 project_queue_actor "$case_dir" "$name" "" 6 > "$case_dir/$name.out" 2>&1 &
    pids+=("$!")
    wait_actor_output "$case_dir/$name.out" 'fm-project-lock: waiting'
  done
  : > "$case_dir/release"
  for pid in "${pids[@]}"; do
    rc=0
    wait "$pid" || rc=$?
    expect_code 0 "$rc" "a progressing queue refused a waiter: $(cat "$case_dir"/*.out)"
  done
  assert_equals "$(printf 'holder\nw1\nw2\nw3\nw4\nw5')" "$(cat "$case_dir/order")" "a progressing queue lost FIFO order"
  assert_equals "$(printf 'holder\nw1\nw2\nw3\nw4\nw5')" "$(sed -n 's/.* operation=//p' "$case_dir/actor.lock.holds")" \
    "the hold record did not log every hold in order"
  assert_absent "$case_dir/actor.lock" "the progressing queue left the project lock held"
  pass "a queue that keeps progressing admits every waiter in order and records each hold"
}

# A fresh spawn waiting its turn for one project holds only its own task's
# locks, so a fresh spawn of the same home for another project is admitted and
# launched meanwhile; the waiting spawn is then admitted once its project frees.
test_same_home_spawn_for_another_project_is_not_refused_while_one_waits() {
  local case_dir home holder lock waiter wt other rc=0 out
  case_dir=$(make_case same-home task-a task-b)
  home="$case_dir/home"
  # shellcheck disable=SC2016 # expanded by the holder's own shell
  FM_HOME="$home" FM_STATE_OVERRIDE='' bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock=$(fm_treehouse_project_lock_path "$2") || exit 1
    fm_lock_try_acquire "$lock" || exit 1
    printf "%s\n" "$lock" > "$3.held"
    while [ ! -f "$3.release" ]; do sleep 0.05; done
    fm_lock_release "$lock"
  ' _ "$ROOT" "$case_dir/project" "$case_dir/holder" &
  holder=$!
  wait_actor_output "$case_dir/holder.held" /
  lock=$(cat "$case_dir/holder.held")
  wt=$(new_worktree "$case_dir" task-a)
  spawn_ship "$case_dir" task-a "$wt" > "$case_dir/a.out" 2>&1 &
  waiter=$!
  wait_actor_output "$case_dir/a.out" 'fm-project-lock: waiting'
  assert_equals 1 "$(queued_tickets "$lock")" "the first spawn did not register on its project queue"
  git -C "$case_dir/other-project" worktree add --quiet -b wt-task-b "$case_dir/wt-task-b"
  other="$case_dir/wt-task-b"
  out=$(run_spawn "$case_dir" "$home" "$other" task-b "$case_dir/other-project" --mode no-mistakes --yolo off) || rc=$?
  expect_code 0 "$rc" "a same-home spawn for another project was refused while the first waited: $out"
  assert_present "$home/state/task-b.meta" "the same-home spawn for another project did not publish"
  assert_absent "$home/state/task-a.meta" "the waiting spawn published before its project was free"
  kill -0 "$waiter" 2>/dev/null || fail "the waiting spawn did not keep waiting: $(cat "$case_dir/a.out")"
  assert_equals 1 "$(queued_tickets "$lock")" "the other project's spawn disturbed the waiting ticket"
  : > "$case_dir/holder.release"
  wait "$holder" || fail "the project holder could not release"
  rc=0
  wait "$waiter" || rc=$?
  expect_code 0 "$rc" "the waiting spawn was not admitted once its project freed: $(cat "$case_dir/a.out")"
  assert_present "$home/state/task-a.meta" "the waiting spawn did not publish after admission"
  assert_absent "$lock" "the admitted spawn left the project lock held"
  pass "a same-home spawn for another project launches while one spawn waits for its project"
}

# Callers already holding other locks make one attempt; it refuses while an
# older waiter is queued even when the lock itself is momentarily free.
test_nonwaiting_admission_never_jumps_a_queued_waiter() {
  local case_dir holder queued rc=0
  case_dir=$(make_case queue-nonwaiting)
  project_queue_actor "$case_dir" holder "$case_dir/release" > "$case_dir/holder.out" 2>&1 &
  holder=$!
  wait_actor_output "$case_dir/order" holder
  project_queue_actor "$case_dir" busy "" "" try > "$case_dir/busy.out" 2>&1 || rc=$?
  expect_code 1 "$rc" "nonwaiting admission took a held project lock"
  FM_PROJECT_LOCK_POLL_SECS=5 project_queue_actor "$case_dir" queued > "$case_dir/queued.out" 2>&1 &
  queued=$!
  wait_actor_output "$case_dir/queued.out" 'fm-project-lock: waiting'
  : > "$case_dir/release"
  wait "$holder" || fail "the holder could not release"
  rc=0
  project_queue_actor "$case_dir" jumper "" "" try > "$case_dir/jumper.out" 2>&1 || rc=$?
  expect_code 1 "$rc" "nonwaiting admission jumped a queued waiter"
  wait "$queued" || fail "the queued waiter was not admitted: $(cat "$case_dir/queued.out")"
  project_queue_actor "$case_dir" after "" "" try > "$case_dir/after.out" 2>&1 \
    || fail "nonwaiting admission refused an idle project lock: $(cat "$case_dir/after.out")"
  assert_equals "$(printf 'holder\nqueued\nafter')" "$(cat "$case_dir/order")" "nonwaiting admission changed FIFO order"
  assert_absent "$case_dir/actor.lock" "nonwaiting admission left the project lock held"
  pass "nonwaiting admission refuses while the lock is held or an older waiter is queued"
}

# One attempt reports contention (FM_PROJECT_LOCK_BUSY_EXIT) only for a live
# holder. A lock it cannot create with nobody holding it, here because its
# parent directory is missing, is an acquisition error, not contention.
test_nonwaiting_admission_separates_contention_from_acquisition_errors() {
  local case_dir holder rc out
  case_dir=$(make_case queue-try-classes)
  rc=0
  out=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-project-lock-lib.sh"
    fm_project_lock_try "$2" probe
  ' _ "$ROOT" "$case_dir/absent/actor.lock" 2>&1) || rc=$?
  expect_code 1 "$rc" "a lock with no holder that cannot be created was reported as contention: $out"
  assert_contains "$out" "fm-project-lock: filesystem error" "the acquisition error was not named as a filesystem error"
  assert_absent "$case_dir/absent" "the failed attempt created the missing parent"
  project_queue_actor "$case_dir" holder "$case_dir/release" > "$case_dir/holder.out" 2>&1 &
  holder=$!
  wait_actor_output "$case_dir/order" holder
  rc=0
  out=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-project-lock-lib.sh"
    fm_project_lock_try "$2" probe
  ' _ "$ROOT" "$case_dir/actor.lock" 2>&1) || rc=$?
  expect_code 75 "$rc" "a live holder was not reported as contention: $out"
  assert_contains "$out" "current holder holder (PID" "the contention did not name the live holder"
  : > "$case_dir/release"
  wait "$holder" || fail "the holder could not release"
  assert_equals holder "$(cat "$case_dir/order")" "the nonwaiting attempt ran its operation"
  pass "nonwaiting admission returns the busy status only for a live holder, and an error for a lock nobody holds"
}

test_project_queue_retires_a_reused_waiter_pid() {
  local case_dir unrelated ticket rc=0
  case_dir=$(make_case queue-pid-reuse)
  sleep 120 &
  unrelated=$!
  ticket=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-project-lock-lib.sh"
    fm_project_lock_register "$2" 20 retired-waiter || exit 1
    printf "%s\n" "$FM_PROJECT_LOCK_TICKET"
  ' _ "$ROOT" "$case_dir/actor.lock") || fail "could not register the old waiter"
  # Retain the departed waiter's identity but reuse its numeric PID for an
  # unrelated real live process, as the kernel can do during a long queue.
  printf '%s\n' "$unrelated" > "$ticket/pid"
  project_queue_actor "$case_dir" replacement "" "" try > "$case_dir/probe.out" 2>&1 || rc=$?
  kill "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  expect_code 0 "$rc" "a reused waiter PID stranded admission: $(cat "$case_dir/probe.out")"
  assert_equals replacement "$(cat "$case_dir/order")" "the unrelated process was admitted as the departed waiter"
  assert_absent "$ticket" "the identity-mismatched ticket was not retired"
  assert_absent "$case_dir/actor.lock" "the replacement did not release its lock"
  pass "a departed waiter's reused PID does not reserve the queue for an unrelated live process"
}

test_nonwaiting_admission_preserves_steal_race_contention() {
  local case_dir race rc out
  case_dir=$(make_case queue-steal-race)
  for race in disappeared renamed; do
    rc=0
    out=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE='' bash -c '
      . "$1/bin/fm-wake-lib.sh"
      . "$1/bin/fm-project-lock-lib.sh"
      lock=$2 race=$3
      owner=$(fm_lock_owner_dir "$lock") || exit 1
      fixture_steal_owner=$(fm_lock_owner_dir "$lock.steal") || exit 1
      printf "2147483647\n" > "$owner/pid"
      printf "2147483647\n" > "$fixture_steal_owner/pid"
      ln -s "$owner" "$lock" || exit 1
      ln -s "$fixture_steal_owner" "$lock.steal" || exit 1
      eval "_real_$(declare -f fm_lock_reap_dead_link)"
      fm_lock_reap_dead_link() {
        if [ "$1" = "$lock.steal" ]; then
          if [ "$race" = disappeared ]; then
            fm_lock_remove_path "$1" || exit 1
          else
            # Elect the competing reaper at the actual tombstone rename.
            mv() {
              if [ "${2:-}" = "$fixture_steal_owner" ]; then
                command mv -- "$fixture_steal_owner" "$fixture_steal_owner.reaped.competitor" || exit 1
              fi
              command mv "$@"
            }
          fi
        fi
        _real_fm_lock_reap_dead_link "$1"
      }
      fm_project_lock_try "$lock" race-probe
    ' _ "$ROOT" "$case_dir/$race.lock" "$race" 2>&1) || rc=$?
    expect_code 75 "$rc" "the $race steal owner race became a permanent acquisition error: $out"
    assert_absent "$case_dir/$race.lock/role" "the losing reclaimer was admitted"
  done
  pass "an observed steal-mutex contention remains transient when another reclaimer releases or renames its owner"
}

test_project_queue_classifies_refusals_before_queueing() {
  local case_dir value rc out
  case_dir=$(make_case queue-input)
  for value in abc -1 0 0.00 1.2.3; do
    rc=0
    out=$(FM_PROJECT_LOCK_POLL_SECS=$value project_queue_actor "$case_dir" "poll-$value" 2>&1) || rc=$?
    expect_code 1 "$rc" "poll override '$value' was accepted"
    assert_contains "$out" "fm-project-lock: invalid input" "poll override '$value' was not reported as invalid input"
    assert_equals 0 "$(queued_tickets "$case_dir/actor.lock")" "poll override '$value' registered a ticket"
  done
  rc=0
  out=$(FM_PROJECT_LOCK_SERVICE_SECS=abc project_queue_actor "$case_dir" service-abc 2>&1) || rc=$?
  expect_code 1 "$rc" "an invalid service allowance was accepted"
  assert_contains "$out" "fm-project-lock: invalid input" "an invalid service allowance was not reported as invalid input"
  mkdir -p "$case_dir/actor.lock.queue"
  printf 'garbage\n' > "$case_dir/actor.lock.queue/sequence"
  rc=0
  out=$(project_queue_actor "$case_dir" bad-sequence 2>&1) || rc=$?
  expect_code 1 "$rc" "a waiter queued past an unreadable sequence"
  assert_contains "$out" "fm-project-lock: registration failure" "an unreadable sequence was not reported as a registration failure"
  assert_equals 0 "$(queued_tickets "$case_dir/actor.lock")" "a failed registration left a ticket"
  assert_absent "$case_dir/actor.lock" "a refused waiter took the project lock"
  assert_absent "$case_dir/order" "a refused waiter ran its operation"
  pass "invalid overrides and registration failures refuse before queueing, each with its own class"
}

test_recursive_cleanup_orders_projects_across_local_homes() {
  local case_dir lane sub project other slot lock_a lock_b small large holder
  local i n child child_project root_home rc=0
  case_dir=$(make_case recursive-order)
  root_home="$case_dir/home"
  project="$case_dir/project"
  other="$case_dir/other-project"
  for n in 1 2; do
    lane="$case_dir/lane-$n"
    sub="$case_dir/sub-$n"
    make_home "$lane"
    make_home "$sub"
    printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$root_home" > "$lane/.fm-secondmate-parent"
    printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$lane" > "$sub/.fm-secondmate-parent"
    printf '%s\n' "domain-$n" > "$sub/.fm-secondmate-home"
    printf -- '- lane-%s - local lane (home: %s; scope: fixtures; projects: project; added 2026-10-12)\n' "$n" "$lane" >> "$root_home/data/secondmates.md"
    printf -- '- domain-%s - child domain (home: %s; scope: fixtures; projects: project; added 2026-10-12)\n' "$n" "$sub" > "$lane/data/secondmates.md"
    fm_write_secondmate_meta "$lane/state/domain-$n.meta" "$sub" "firstmate:fm-domain-$n"
    for i in 1 2; do
      child="child-$n-$i"
      # Child enumeration is reversed across homes, but project identity is shared.
      if [ "$n" = "$i" ]; then child_project=$project; else child_project=$other; fi
      slot="$case_dir/pool-$i-$n/$n/project"
      mkdir -p "${slot%/*}"
      git -C "$child_project" worktree add --quiet --detach "$slot"
      printf '{"worktrees":[{"name":"%s","path":"%s","leased":false}]}\n' "$n" "$slot" \
        > "$case_dir/pool-$i-$n/treehouse-state.json"
      write_live "$sub" "$child" "$child_project"
      fm_write_meta "$sub/state/$child.meta" "window=firstmate:fm-$child" "endpoint_task_id=$child" \
        "worktree=$slot" "project=$child_project" "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off"
    done
  done
  lock_a=$(FM_HOME="$root_home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$project")
  lock_b=$(FM_HOME="$root_home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' _ "$ROOT" "$other")
  local LC_ALL=C
  if [[ "$lock_a" < "$lock_b" ]]; then small=$lock_a; large=$lock_b; else small=$lock_b; large=$lock_a; fi
  # Only the globally first project is held. Each cleanup already holds its
  # descendants' lifecycle locks, so it makes one nonwaiting attempt per
  # project in global order and refuses there, before touching the later one.
  FM_HOME="$root_home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2" || exit 1
    : > "$2.held"
    while [ ! -e "$3" ]; do sleep 0.05; done
    fm_lock_release "$2"
  ' _ "$ROOT" "$small" "$case_dir/release" &
  holder=$!
  i=0
  while [ ! -e "$small.held" ]; do
    i=$((i + 1)); [ "$i" -lt 400 ] || fail "the project blocker never acquired the first project"
    sleep 0.05
  done
  run_domain_cleanups "$case_dir"
  for n in 1 2; do
    [ "${CLEANUP_RC[$n]}" -ne 0 ] || fail "cleanup $n ran past a held descendant project lock"
    assert_contains "$(cat "$case_dir/lane-$n.out")" "(PID $holder)" "cleanup $n did not refuse on the held project lock"
    assert_present "$case_dir/lane-$n/state/domain-$n.meta" "refused cleanup $n removed its domain record"
    for i in 1 2; do
      assert_present "$case_dir/sub-$n/state/child-$n-$i.meta" "refused cleanup $n removed child $n-$i"
    done
  done
  assert_equals "$holder" "$(cat "$small/pid" 2>/dev/null)" "a refused cleanup removed or replaced the live project holder"
  assert_absent "$large" "a refused cleanup left the later project locked"
  assert_absent "$large.holds" "a cleanup took the later project before the globally first one"
  assert_equals 0 "$(queued_tickets "$small")" "a nonwaiting cleanup queued on the first project"
  assert_equals 0 "$(queued_tickets "$large")" "a nonwaiting cleanup queued on the later project"
  : > "$case_dir/release"
  wait "$holder" || fail "the project blocker could not release"

  # Released: run both together. Global order means at least one proceeds; one
  # that meets the other on the shared project refuses having changed nothing.
  run_domain_cleanups "$case_dir"
  for n in 1 2; do
    if [ "${CLEANUP_RC[$n]}" -ne 0 ]; then
      assert_present "$case_dir/lane-$n/state/domain-$n.meta" "contended cleanup $n refused after changing its record"
      rc=0
      FM_HOME="$case_dir/lane-$n" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
        FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
        "$TEARDOWN" "domain-$n" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/lane-$n.out" 2>&1 || rc=$?
      expect_code 0 "$rc" "cleanup $n failed once the other finished: $(cat "$case_dir/lane-$n.out")"
    fi
  done
  [ "${CLEANUP_RC[1]}" -eq 0 ] || [ "${CLEANUP_RC[2]}" -eq 0 ] \
    || fail "reverse-order cleanups refused each other: $(cat "$case_dir/lane-1.out" "$case_dir/lane-2.out")"
  assert_absent "$case_dir/lane-1/state/domain-1.meta" "first cleanup did not complete"
  assert_absent "$case_dir/lane-2/state/domain-2.meta" "second cleanup did not complete"
  assert_absent "$small" "recursive cleanup left the first project locked"
  assert_absent "$large" "recursive cleanup left the second project locked"
  pass "concurrent recursive cleanup with reversed child project order tries globally sorted project locks once and completes both homes"
}

run_domain_cleanups() {  # <case-dir>; sets CLEANUP_RC[1] and CLEANUP_RC[2]
  local case_dir=$1 n pid_1 pid_2
  for n in 1 2; do
    FM_HOME="$case_dir/lane-$n" FM_ROOT_OVERRIDE='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
      FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
      "$TEARDOWN" "domain-$n" --force --drop-file "$(fm_test_drop_file)" > "$case_dir/lane-$n.out" 2>&1 &
    if [ "$n" = 1 ]; then pid_1=$!; else pid_2=$!; fi
  done
  CLEANUP_RC=(x 0 0)
  wait "$pid_1" || CLEANUP_RC[1]=$?
  wait "$pid_2" || CLEANUP_RC[2]=$?
}

# The actual spawn and teardown entry points share a queue. Teardown polls
# slowly, while the later spawn polls aggressively: the queued teardown's
# ownership admission must be recorded in the lock's hold record before the
# later spawn reaches its post-admission pane read.
test_mixed_operations_keep_fifo_even_with_a_slow_waiter() {
  local case_dir home hold first slow fast wt next fm_meta_fixture lock i rc=0
  case_dir=$(make_case mixed-fifo task-a task-c)
  home="$case_dir/home"
  hold="$case_dir/hold"
  mkdir -p "$case_dir/pool/1"
  git -C "$case_dir/project" worktree add --quiet --detach "$case_dir/pool/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' \
    "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
  write_live "$home" retire "$case_dir/project"
  fm_meta_fixture="$home/state/retire.meta"
  # Keep the established backlog proof and publish an unambiguous pool record.
  fm_write_meta "$fm_meta_fixture" \
    "window=firstmate:fm-retire" "endpoint_task_id=retire" \
    "worktree=$case_dir/pool/1/project" "project=$case_dir/project" \
    "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" "spawn_gen=s-retire"
  wt=$(new_worktree "$case_dir" task-a)
  next=$(new_worktree "$case_dir" task-c)
  FM_FAKE_HOLD="$hold" spawn_ship "$case_dir" task-a "$wt" > "$case_dir/a.out" 2>&1 &
  first=$!
  i=0
  while [ ! -f "$hold.reached" ]; do
    i=$((i + 1)); [ "$i" -lt 400 ] || fail "first spawn never acquired: $(cat "$case_dir/a.out")"
    sleep 0.05
  done
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_PROJECT_LOCK_POLL_SECS=1 FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" retire --force --drop-file "$(fm_test_drop_file)" > "$case_dir/slow.out" 2>&1 &
  slow=$!
  i=0
  while ! grep -q 'fm-project-lock: waiting' "$case_dir/slow.out"; do
    i=$((i + 1)); [ "$i" -lt 400 ] || fail "teardown never queued: $(cat "$case_dir/slow.out")"
    sleep 0.05
  done
  lock=$(FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' \
    _ "$ROOT" "$case_dir/project")
  FM_PROJECT_LOCK_POLL_SECS=0.05 FM_FAKE_CHECK_HOLDS="$lock.holds" \
    spawn_ship "$case_dir" task-c "$next" > "$case_dir/fast.out" 2>&1 &
  fast=$!
  i=0
  while ! grep -q 'fm-project-lock: waiting' "$case_dir/fast.out"; do
    i=$((i + 1)); [ "$i" -lt 400 ] || fail "later spawn never queued: $(cat "$case_dir/fast.out")"
    sleep 0.05
  done
  assert_present "$fm_meta_fixture" "the queued teardown ran before the initial holder released"
  assert_absent "$home/state/task-c.meta" "the later spawn bypassed a queued teardown"
  : > "$hold.release"
  wait "$first" || fail "first spawn failed: $(cat "$case_dir/a.out")"
  wait "$slow" || fail "slow teardown failed: $(cat "$case_dir/slow.out")"
  wait "$fast" || rc=$?
  expect_code 0 "$rc" "later spawn ran ahead of the slow teardown or failed: $(cat "$case_dir/fast.out")"
  assert_absent "$fm_meta_fixture" "the slow teardown starved"
  assert_present "$home/state/task-c.meta" "the later spawn did not eventually acquire"
  assert_contains "$(cat "$case_dir/calls.log")" 'treehouse return' "the slow teardown did not return its slot"
  pass "spawn and teardown remain FIFO and a slow poller cannot starve behind a faster later spawn"
}

# Keep each slow callback open until a different worker is published. The
# retiring slot must stay leased throughout that overlap; neither the global
# pool lock nor the completed record may delay the new worker's allocation.
test_spawn_progresses_during_non_pool_teardown_phases() {
  local phase case_dir home slot next actor spawn_actor i rc retired retire_meta child_home
  for phase in reap recursive sync backlog; do
    case_dir=$(make_case "slow-teardown-$phase" task-new)
    home="$case_dir/home"
    slot="$case_dir/pool/1/project"
    mkdir -p "${slot%/*}"
    git -C "$case_dir/project" worktree add --quiet --detach "$slot"
    printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$slot" \
      > "$case_dir/pool/treehouse-state.json"
    write_live "$home" retire "$case_dir/project"
    fm_write_meta "$home/state/retire.meta" \
      "window=firstmate:fm-retire" "endpoint_task_id=retire" \
      "worktree=$slot" "project=$case_dir/project" \
      "harness=codex" "kind=ship" "mode=no-mistakes" "yolo=off" "spawn_gen=s-retire"
    printf 'task=retire\nhome=%s\n' "$home" > "${slot%/*}/.fm-slot-owner"
    retire_meta="$home/state/retire.meta"
    if [ "$phase" = recursive ]; then
      child_home="$case_dir/retired-home"
      make_home "$child_home"
      printf '%s\n' retire > "$child_home/.fm-secondmate-home"
      printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$home" \
        > "$child_home/.fm-secondmate-parent"
      printf -- '- retire - local domain (home: %s; scope: fixtures; projects: project; added 2026-10-12)\n' \
        "$child_home" > "$home/data/secondmates.md"
      fm_write_secondmate_meta "$home/state/retire.meta" "$child_home"
      write_live "$child_home" child "$case_dir/project"
      fm_write_meta "$child_home/state/child.meta" \
        "window=firstmate:fm-child" "endpoint_task_id=child" \
        "worktree=$slot" "project=$case_dir/project" "kind=scout" "harness=codex"
      printf 'task=child\nhome=%s\n' "$child_home" > "${slot%/*}/.fm-slot-owner"
      retire_meta="$child_home/state/child.meta"
    fi
    next=$(new_worktree "$case_dir" task-new)
    fm_fake_docker "$case_dir/fakebin"
    # This is an allocation decision, not an echoed launch expectation: the
    # fake terminal's get refuses if the retiring slot is available while its
    # record still names it. The spare isolated copy is then adopted normally.
    cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *'treehouse get'*)
    if [ -f "$FM_SLOW_META" ]; then
      jq -e '.worktrees[0].leased == true' "$FM_SLOW_CASE/pool/treehouse-state.json" >/dev/null || exit 1
    fi
    ;;
  *'#{pane_current_path}'*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}" ;;
esac
exit 0
SH
    cat > "$case_dir/fakebin/delay" <<'SH'
#!/usr/bin/env bash
mkdir "$FM_SLOW_CASE/delay-owned" 2>/dev/null || exit 0
: > "$FM_SLOW_CASE/reached"
i=0
while [ ! -f "$FM_SLOW_CASE/release" ]; do
  i=$((i + 1)); [ "$i" -lt 4000 ] || exit 1
  sleep 0.05
 done
SH
    case "$phase" in
      reap)
        cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
[ ! -f "$FM_SLOW_META" ] || delay || exit 1
# The cwd inventory succeeded and contains no task processes.
case " $* " in *' -d cwd '*) exit 0 ;; esac
exit 1
SH
        ;;
      recursive)
        mv "$case_dir/fakebin/docker" "$case_dir/fakebin/docker-fixture"
        cat > "$case_dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
delay || exit 1
exec docker-fixture "$@"
SH
        ;;
      sync)
        cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'fetch'*)
    [ -f "$FM_SLOW_META" ] || delay || exit 1
    ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
        ;;
      backlog)
        [ "$HAVE_TASKS_AXI" = 1 ] || { pass 'slow backlog overlap skipped (tasks-axi unavailable)'; continue; }
        cat > "$case_dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in done) delay || exit 1 ;; esac
exec "$FM_REAL_TASKS_AXI" "$@"
SH
        ;;
    esac
    chmod +x "$case_dir/fakebin/"*
    FM_SLOW_CASE="$case_dir" FM_SLOW_META="$retire_meta" FM_REAL_GIT="$(command -v git)" FM_REAL_TASKS_AXI="$(command -v tasks-axi || true)" \
      FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
      FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
      "$TEARDOWN" retire --force --drop-file "$(fm_test_drop_file)" > "$case_dir/retire.out" 2>&1 &
    actor=$!
    i=0
    while [ ! -f "$case_dir/reached" ]; do
      i=$((i + 1)); [ "$i" -lt 1000 ] || {
        : > "$case_dir/release"; wait "$actor" || true
        fail "$phase: teardown never reached its slow callback: $(cat "$case_dir/retire.out")"
      }
      sleep 0.05
    done
    retired=0
    [ -f "$retire_meta" ] || retired=1
    if [ "$phase" = reap ] || [ "$phase" = recursive ]; then
      [ "$retired" = 0 ] || fail 'process cleanup retired its record too soon'
      jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
        || fail 'the retiring slot became allocatable before process cleanup finished'
    else
      [ "$retired" = 1 ] || fail "$phase: slow post-cleanup work still names the returned slot"
    fi
    FM_SLOW_CASE="$case_dir" FM_SLOW_META="$retire_meta" FM_REAL_GIT="$(command -v git)" FM_REAL_TASKS_AXI="$(command -v tasks-axi || true)" \
      spawn_ship "$case_dir" task-new "$next" > "$case_dir/spawn.out" 2>&1 &
    spawn_actor=$!
    i=0
    while [ ! -f "$home/state/task-new.meta" ]; do
      i=$((i + 1)); [ "$i" -lt 1000 ] || {
        : > "$case_dir/release"; wait "$actor" || true; wait "$spawn_actor" || true
        fail "$phase: spawn waited for non-pool teardown work: $(cat "$case_dir/spawn.out")"
      }
      sleep 0.05
    done
    # Independent progress is observed before releasing the delayed callback.
    assert_absent "$case_dir/release" "$phase: overlap was vacuous"
    : > "$case_dir/release"
    rc=0; wait "$actor" || rc=$?
    expect_code 0 "$rc" "$phase: teardown failed after the callback released: $(cat "$case_dir/retire.out")"
    rc=0; wait "$spawn_actor" || rc=$?
    expect_code 0 "$rc" "$phase: overlapping spawn failed: $(cat "$case_dir/spawn.out")"
    assert_absent "$home/state/retire.meta" "$phase: teardown kept the retired record"
    assert_present "$home/state/task-new.meta" "$phase: the new worker did not remain published"
    jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
      || fail "$phase: successful teardown left its reserved slot leased"
  done
  pass 'spawn proceeds during slow process cleanup, clone sync and backlog completion while the retiring slot stays reserved until return'
}

# A forced child return runs after that child's endpoint and Docker objects
# are already gone, so it waits in the FIFO queue rather than exiting busy and
# stranding the closed child's reserved slot.
test_forced_child_return_waits_for_project_custody() {
  local case_dir home child_home slot lock actor holder i queued ticket rc
  case_dir=$(make_case child-return-wait)
  home="$case_dir/home"
  slot="$case_dir/pool/1/project"
  mkdir -p "${slot%/*}"
  git -C "$case_dir/project" worktree add --quiet --detach "$slot"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":false}]}\n' "$slot" \
    > "$case_dir/pool/treehouse-state.json"
  child_home="$case_dir/retired-home"
  make_home "$child_home"
  printf '%s\n' retire > "$child_home/.fm-secondmate-home"
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$home" \
    > "$child_home/.fm-secondmate-parent"
  printf -- '- retire - local domain (home: %s; scope: fixtures; projects: project; added 2026-10-12)\n' \
    "$child_home" > "$home/data/secondmates.md"
  fm_write_secondmate_meta "$home/state/retire.meta" "$child_home"
  write_live "$child_home" child "$case_dir/project"
  fm_write_meta "$child_home/state/child.meta" \
    "window=firstmate:fm-child" "endpoint_task_id=child" \
    "worktree=$slot" "project=$case_dir/project" "kind=scout" "harness=codex"
  printf 'task=child\nhome=%s\n' "$child_home" > "${slot%/*}/.fm-slot-owner"
  fm_fake_docker "$case_dir/fakebin"
  mv "$case_dir/fakebin/docker" "$case_dir/fakebin/docker-fixture"
  cat > "$case_dir/fakebin/docker" <<'SH'
#!/usr/bin/env bash
if mkdir "$FM_SLOW_CASE/delay-owned" 2>/dev/null; then
  : > "$FM_SLOW_CASE/reached"
  i=0
  while [ ! -f "$FM_SLOW_CASE/project-held" ]; do
    i=$((i + 1)); [ "$i" -lt 4000 ] || exit 1
    sleep 0.05
  done
fi
exec docker-fixture "$@"
SH
  chmod +x "$case_dir/fakebin/docker"
  lock=$(FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_project_lock_path "$2"' \
    _ "$ROOT" "$case_dir/project")
  FM_SLOW_CASE="$case_dir" FM_PROJECT_LOCK_POLL_SECS=0.05 \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_FAKE_CALL_LOG="$case_dir/calls.log" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" retire --force --drop-file "$(fm_test_drop_file)" > "$case_dir/retire.out" 2>&1 &
  actor=$!
  i=0
  while [ ! -f "$case_dir/reached" ]; do
    i=$((i + 1)); [ "$i" -lt 1000 ] || {
      kill "$actor" 2>/dev/null || true
      fail "forced teardown never reached child Docker cleanup: $(cat "$case_dir/retire.out")"
    }
    sleep 0.05
  done
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$2" || exit 1
    trap '\''fm_lock_release "$2"'\'' EXIT
    : > "$3/project-held"
    while [ ! -f "$3/release" ]; do sleep 0.05; done
  ' _ "$ROOT" "$lock" "$case_dir" &
  holder=$!
  i=0
  while :; do
    queued=0
    for ticket in "$lock.queue"/ticket-*; do
      [ ! -L "$ticket" ] || queued=1
    done
    [ "$queued" = 0 ] || break
    if ! kill -0 "$actor" 2>/dev/null; then
      : > "$case_dir/release"; wait "$holder" || true
      rc=0; wait "$actor" || rc=$?
      fail "forced teardown exited ($rc) instead of queueing for its child return: $(cat "$case_dir/retire.out")"
    fi
    i=$((i + 1)); [ "$i" -lt 1000 ] || {
      : > "$case_dir/release"; wait "$holder" || true; wait "$actor" || true
      fail "forced teardown never queued for its child return: $(cat "$case_dir/retire.out")"
    }
    sleep 0.05
  done
  assert_present "$child_home/state/child.meta" 'the queued child return retired its record early'
  jq -e '.worktrees[0].leased == true' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the closed child lost its reservation while its return queued'
  : > "$case_dir/release"
  wait "$holder" || fail 'the project holder could not release'
  rc=0; wait "$actor" || rc=$?
  expect_code 0 "$rc" "the queued child return must finish: $(cat "$case_dir/retire.out")"
  assert_absent "$home/state/retire.meta" 'forced teardown kept the parent record'
  assert_absent "$child_home" 'forced teardown kept the child home'
  jq -e '.worktrees[0].leased == false' "$case_dir/pool/treehouse-state.json" >/dev/null \
    || fail 'the child return left its slot leased'
  pass 'a forced child return queues for project custody after closure and returns the reserved slot'
}

test_undeclared_capacity_keeps_dispatch_uncapped
test_available_capacity_admits_the_worker
test_exhausted_capacity_defers_without_leaving_anything_behind
test_spaced_project_name_is_declared
test_hash_prefixed_project_name_is_declared
test_symlinked_home_counts_each_worker_once
test_release_frees_a_place
test_restart_does_not_count_its_own_record
test_occupancy_counts_only_this_projects_workers
test_capacity_is_shared_by_every_local_home
test_unreadable_holders_refuse_admission
test_concurrent_spawns_cannot_both_take_the_last_place
test_spawn_progresses_during_non_pool_teardown_phases
test_forced_child_return_waits_for_project_custody
test_mixed_operations_keep_fifo_even_with_a_slow_waiter
test_same_home_spawn_for_another_project_is_not_refused_while_one_waits
test_project_queue_recovers_dead_waiter_and_holder
test_project_queue_timeout_preserves_live_holder
test_project_queue_slow_holder_never_admits_a_later_waiter_first
test_project_queue_progress_never_reaches_the_stall_limit
test_nonwaiting_admission_never_jumps_a_queued_waiter
test_nonwaiting_admission_separates_contention_from_acquisition_errors
test_project_queue_retires_a_reused_waiter_pid
test_nonwaiting_admission_preserves_steal_race_contention
test_project_queue_classifies_refusals_before_queueing
test_recursive_cleanup_orders_projects_across_local_homes
test_failed_spawn_after_admission_holds_no_place
test_unreadable_declaration_refuses_every_spawn
test_batch_reports_a_deferred_pair
test_orca_spawn_is_admitted_under_the_shared_project_lock
