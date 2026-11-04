#!/usr/bin/env bash
# Behavioral coverage for home-owned writes after a persistent directory change.
# Real entry points write into a temporary operational home, never the caller's
# project-like directory. Backend/agent/forge processes alone are simulated.
# The negative control preserves the original bare cwd-relative write incident.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-home-writes)
# An invoking supervisor may export directory overrides; this suite deliberately
# supplies ONLY FM_HOME so an override cannot mask an incorrect default root.
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE \
  FM_PROJECTS_OVERRIDE FM_CONFIG_OVERRIDE FM_GUARD_EVENT_LOG FM_BACKEND \
  FM_FRICTION_EVENT_ID FM_FRICTION_ATTEMPT_ID FM_FRICTION_OPERATION_ID
export FM_FRICTION_EXECUTION_KIND=test
fm_git_identity fmtest fmtest@example.invalid
command -v tasks-axi >/dev/null || fail "tasks-axi is required for home write coverage"

home="$TMP_ROOT/home"
foreign="$TMP_ROOT/project-clone"
mkdir -p "$home" "$foreign/data" "$foreign/state" "$TMP_ROOT/user"
home=$(cd "$home" && pwd -P)
foreign=$(cd "$foreign" && pwd -P)
export HOME="$TMP_ROOT/user" CLAUDE_CONFIG_DIR=''
fm_test_spawn_home "$home" claude
fm_test_tasks_toml "$home/.tasks.toml"
fm_test_tasks_toml "$foreign/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
cp "$home/data/backlog.md" "$foreign/data/backlog.md"

# Negative control: the same home-target assertion used below MUST fail for a
# bare relative append after cd. No cd restriction can fix relative addressing.
(
  cd "$home"
  cd "$foreign"
  printf -- '- [ ] cwd-leak: wrong destination\n' >> data/backlog.md
)
if grep -q cwd-leak "$home/data/backlog.md"; then
  fail "negative control unexpectedly wrote the home backlog"
fi
assert_grep cwd-leak "$foreign/data/backlog.md" "original cwd-relative leak did not reproduce"
pass "negative control: home-target assertion rejects a bare relative write after cd"
# Keep a complete content/tree snapshot, including that deliberately leaked row,
# so every production call below must leave the foreign directory unchanged.
cp -R "$foreign" "$TMP_ROOT/foreign-before"

# All calls below share a shell that has really left the home. No per-directory
# overrides, cd-back wrappers, or output redirections into the target directories
# can accidentally provide the addressing guarantee being tested.
cd "$foreign"
export FM_HOME="$home"
run_home() { bash "$ROOT/bin/$1" "${@:2}"; }

for id in archive-1 archive-2; do
  run_home fm-tasks-axi.sh add "$id" "home-owned backlog row" >/dev/null
  run_home fm-tasks-axi.sh start "$id" >/dev/null
  run_home fm-tasks-axi.sh 'done' "$id" >/dev/null
done
run_home fm-tasks-axi.sh add pending-1 "waiting for an answer" >/dev/null
run_home fm-tasks-axi.sh hold pending-1 --reason 'home write proof' --kind captain >/dev/null
run_home fm-tasks-axi.sh unhold pending-1 >/dev/null
run_home fm-tasks-axi.sh prune --keep 1 >/dev/null
assert_grep pending-1 "$home/data/backlog.md" "wrapper backlog mutation missed the home"
assert_grep archive-1 "$home/data/done-archive.md" "wrapper archive mutation missed the home"
diff -r "$TMP_ROOT/foreign-before" "$foreign" || fail "backlog mutation changed the caller's project"
pass "backlog add/start/done/hold/unhold/prune write only the configured home"

run_home fm-brief.sh cwd-task sample --scout >/dev/null
assert_present "$home/data/cwd-task/brief.md" "brief did not land in the home"
run_home fm-inbox.sh note --request-id cwd-proof --json 'home-owned note' > "$TMP_ROOT/note.json"
note_id=$(jq -r '.id' "$TMP_ROOT/note.json")
[ -n "$note_id" ] && [ "$note_id" != null ] || fail "inbox note returned no id"
run_home fm-inbox.sh reply "$note_id" 'home-owned answer' >/dev/null
run_home fm-inbox.sh drain --ack "$note_id" >/dev/null
run_home fm-inbox.sh receipts --all-handled --all-replies > "$TMP_ROOT/receipts.json"
assert_grep 'home-owned answer' "$TMP_ROOT/receipts.json" "inbox reply was not retained"
assert_present "$home/state/.wake-queue" "inbox wake did not land in home state"

printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/cwd-check.check.sh"
chmod 700 "$home/state/cwd-check.check.sh"
run_home fm-check-register.sh cwd-check >/dev/null
assert_present "$home/state/cwd-check.check-trust" "check registration missed home state"
run_home fm-check-unregister.sh cwd-check >/dev/null
assert_absent "$home/state/cwd-check.check-trust" "check unregister did not retire home state"
run_home fm-guard-event.sh home-write-proof allow
assert_grep 'home-write-proof' "$home/state/guard-events.jsonl" "guard event missed home state"
diff -r "$TMP_ROOT/foreign-before" "$foreign" || fail "data/state entry point changed the caller's project"
pass "brief, inbox note/reply/ack, custom-check registration/retirement, and guard events use home data/state"

# With no configured home, a copied entry point derives its own code root,
# not this shell's foreign cwd. Never exercise the fallback against this repo.
mkdir -p "$TMP_ROOT/code/bin" "$TMP_ROOT/code/state"
cp "$ROOT/bin/fm-guard-event.sh" "$TMP_ROOT/code/bin/"
env -u FM_HOME -u FM_ROOT -u FM_ROOT_OVERRIDE \
  bash "$TMP_ROOT/code/bin/fm-guard-event.sh" script-location-proof allow
assert_grep script-location-proof "$TMP_ROOT/code/state/guard-events.jsonl" \
  "unset-home fallback did not resolve the script location"
diff -r "$TMP_ROOT/foreign-before" "$foreign" || fail "script-location fallback wrote into the caller's project"
pass "an unset home falls back to the script's own root, not the caller's directory"

# An isolated fixture repository and a simulated tmux agent exercise real
# spawn/send/control/teardown writes without starting an agent or a shared tool.
project="$TMP_ROOT/sample"
copy="$TMP_ROOT/task-copy"
fm_git_worktree "$project" "$copy" task-copy
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/tools" claude)
fm_test_fake_no_mistakes "$fakebin"
fm_test_fake_gh "$fakebin"
fm_test_fake_gh_axi "$fakebin"
fm_fake_docker "$fakebin"
export FM_HOME_WRITE_COPY="$copy" FM_HOME_WRITE_PROCESS="$TMP_ROOT/foreground" \
  FM_HOME_WRITE_WINDOW="$TMP_ROOT/window"
printf 'claude\n' > "$FM_HOME_WRITE_PROCESS"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *cursor_y*) printf '1\n'; exit 0 ;;
  *'#{pane_current_path}'*) printf '%s\n' "$FM_HOME_WRITE_COPY"; exit 0 ;;
  *'#{pane_current_command}'*) cat "$FM_HOME_WRITE_PROCESS"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -e "$FM_HOME_WRITE_WINDOW" ] || printf 'fm-cwd-task\n' ;;
  new-window) touch "$FM_HOME_WRITE_WINDOW" ;;
  kill-window) rm -f "$FM_HOME_WRITE_WINDOW" ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  send-keys)
    for arg in "$@"; do
      case "$arg" in /exit|/quit) printf 'zsh\n' > "$FM_HOME_WRITE_PROCESS" ;; esac
    done ;;
esac
exit 0
SH
chmod +x "$fakebin/tmux"
export PATH="$fakebin:$PATH" TMUX='fixture,1,0' FM_SPAWN_NO_GUARD=1
# Minimal filled task content, following fixtures.sh's spawn brief convention.
fm_test_spawn_brief "$home" cwd-task 'Investigate home-owned writes.'
run_home fm-tasks-axi.sh add cwd-task 'Investigate home-owned writes' >/dev/null
run_home fm-spawn.sh cwd-task "$project" --scout > "$TMP_ROOT/spawn.out" 2>&1 \
  || fail "foreign-directory spawn failed: $(cat "$TMP_ROOT/spawn.out")"
assert_grep "worktree=$copy" "$home/state/cwd-task.meta" "spawn metadata missed the home"
# Status is worker-created; the real send path below must append its answer
# to this home-owned worker event, not create a second log in the caller.
printf 'blocked [key=cwd-answer]: choose a destination\n' >> "$home/state/cwd-task.status"
run_home fm-send.sh cwd-task --resolve-key cwd-answer 'Use the configured home.' > "$TMP_ROOT/send.out" 2>&1 \
  || fail "foreign-directory send failed: $(cat "$TMP_ROOT/send.out")"
grep -Eq '^resolved .*\[key=cwd-answer\]' "$home/state/cwd-task.status" \
  || fail "send did not resolve the home status: $(cat "$home/state/cwd-task.status")"
assert_present "$home/state/cwd-task.inbox/001.msg" "send did not persist the home steering record"
run_home fm-control.sh cwd-task exit > "$TMP_ROOT/control.out" 2>&1 \
  || fail "foreign-directory control failed: $(cat "$TMP_ROOT/control.out")"
assert_present "$home/state/cwd-task.control-exit" "control exit marker missed the home"
printf 'Home write investigation completed.\n' > "$home/data/cwd-task/report.md"
printf 'done: investigation complete\n' >> "$home/state/cwd-task.status"
run_home fm-captain-hold.sh complete cwd-task --none >/dev/null
run_home fm-teardown.sh cwd-task > "$TMP_ROOT/teardown.out" 2>&1 \
  || fail "foreign-directory teardown failed: $(cat "$TMP_ROOT/teardown.out")"
assert_absent "$home/state/cwd-task.meta" "teardown did not retire home metadata"
assert_present "$home/data/cwd-task/report.md" "teardown lost the durable home report"
assert_grep 'cwd-task/report.md' "$home/data/backlog.md" "teardown completion missed the home backlog"
diff -r "$TMP_ROOT/foreign-before" "$foreign" || fail "lifecycle mutation changed the caller's project"
pass "spawn/send/status-resolution/control-exit/teardown keep durable writes in the configured home"

# Promotion mutates the contract in both data and state without launching or
# touching a repository. A second scout record isolates it from teardown's proof.
fm_test_spawn_brief "$home" cwd-promote 'Implement the investigated change.'
fm_write_meta "$home/state/cwd-promote.meta" 'kind=scout' \
  'window=firstmate:fm-cwd-promote' 'endpoint_task_id=cwd-promote' "worktree=$copy"
run_home fm-promote.sh cwd-promote --mode no-mistakes --yolo off > "$TMP_ROOT/promote.out" 2>&1 \
  || fail "foreign-directory promotion failed: $(cat "$TMP_ROOT/promote.out")"
assert_grep 'kind=ship' "$home/state/cwd-promote.meta" "promotion did not change the home task contract"
assert_grep 'mode=no-mistakes' "$home/data/cwd-promote/ship-instructions.md" \
  "promotion did not publish home ship instructions"

run_home fm-captain-hold.sh hold cwd-call --title 'Choose a home-owned option' \
  --reason 'home write proof' > "$TMP_ROOT/hold.out" 2>&1 \
  || fail "foreign-directory hold failed: $(cat "$TMP_ROOT/hold.out")"
printf 'Use the investigated option.\n' > "$TMP_ROOT/answer.txt"
run_home fm-captain-hold.sh answer cwd-call --decision-file "$TMP_ROOT/answer.txt" \
  > "$TMP_ROOT/answer.out" 2>&1 \
  || fail "foreign-directory answer failed: $(cat "$TMP_ROOT/answer.out")"
assert_grep 'Use the investigated option.' "$home/data/backlog.md" \
  "the answer was not retained in the home backlog"
diff -r "$TMP_ROOT/foreign-before" "$foreign" || fail "contract mutation changed the caller's project"
pass "promotion and captain-hold/answer persist their contracts and decisions in the home"
