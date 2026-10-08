#!/usr/bin/env bash
# bin/fm-secondmate-restart.sh: persist-then-restart, and the honest fallback.
#
# What these pin, all through the real commands (real fm-send, real durable
# steering inbox, real parent-owned reply expectation, real fm-control
# transaction) against a lifecycle-modelling session-provider stub:
#
#   1. The persist request is a GATE. Nothing is stopped until that mate's own
#      correlated answer lands on the parent channel and its turn has ended, and
#      both are events, not a clock: an unanswered mate keeps its agent and a
#      durable restart request that supervision finishes once both happen.
#   2. The order is persist THEN restart, observable in what reaches the pane.
#   3. The persist request is the task-subset of /stow: it asks for open records
#      and task status, and explicitly not for the memory, learnings, or
#      captain-preference sweeps.
#   4. Every unsafe case says what is known: pre-restart capability and persist
#      failures use the nudge path, while a failed relaunch is reported as an
#      unknown outcome; none is reported as a clean reload.
#   6. End to end with bin/fm-update.sh: a live mate whose home needed no
#      fast-forward is still named for restart and genuinely restarted, and one
#      whose runtime cannot prove a restart keeps the honest re-read path with
#      its agent left running.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

RESTART="$ROOT/bin/fm-secondmate-restart.sh"

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-restart)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'chmod -R u+w "$TMP_ROOT"; rm -rf -- "$TMP_ROOT"' EXIT

# A session-provider stub that models the two things this pass depends on: the
# harness exit command stops the agent, a launch brief starts the replacement,
# and - when armed - the live mate ANSWERS a doorbell by doing what the persist
# request asks and reporting it on the parent channel with the correlation token
# the request carried. That answer is a real status append read by the real
# pending-reply machinery, not a stubbed verdict.
make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    target=
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) target=$2; shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'")
          staged=${payload#". '"}
          staged=${staged%"'"}
          [ ! -f "$staged" ] || payload=$(cat "$staged")
          ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          [ ! -x "$D/on-exit" ] || "$D/on-exit" "$target"
          if [ ! -e "$D/remote-relaunch-end" ]; then
            : > "$D/local-relaunch-before-remote-end"
          fi
          : > "$D/local-relaunch-seen"
          printf 'zsh' > "$D/command.$target"
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) cat "$D/becomes" > "$D/command.$target" ;;
        ': Firstmate instruction waiting: list '*)
          printf 'doorbell\n' >> "$D/rings"
          if [ -x "$D/on-doorbell" ]; then
            "$D/on-doorbell" "$payload"
          fi
          if [ -f "$D/answer-inbox" ]; then
            # Model the mate: read the newest instruction it was handed and
            # report back on the parent channel, carrying the correlation token
            # the request itself embedded.
            inbox=$(cat "$D/answer-inbox")
            corr=$(cat "$inbox"/*.msg 2>/dev/null \
              | grep -oE 'corr=[0-9a-f]{16}' | head -1)
            if [ -n "$corr" ]; then
              printf 'done [%s]: open records written down\n' "$corr" \
                >> "$(cat "$D/answer-status")"
            fi
          fi
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    target=
    prev=
    for a in "$@"; do
      if [ "$prev" = -t ]; then target=$a; fi
      case "$a" in
        *cursor_y*)
          [ ! -x "$D/on-composer" ] || "$D/on-composer"
          printf '1\n'; exit 0 ;;
        *pane_current_command*)
          if [ -f "$D/command.$target" ]; then cat "$D/command.$target"; else cat "$D/command"; fi
          printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
      prev=$a
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ''|*[!0-9]*) ;;
  *) /bin/sleep 0.01 ;;
esac
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> -> a parent home with a stub session provider.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fake"
  mkdir -p "$dir/code"
  cp -R "$ROOT/bin" "$dir/code/bin"
  git init -q "$dir/code"
  git -C "$dir/code" add bin
  ln -s "$ROOT/.omp" "$dir/code/.omp"
  ln -s "$ROOT/.agents" "$dir/code/.agents"
  printf 'claude\n' > "$dir/home/config/secondmate-harness"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/rings"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_stub "$dir"
  printf '%s\n' "$dir"
}

# add_local_mate <case-dir> <id> [harness] [backend-line]
# A live LOCAL second mate: a real git worktree for its home, plus the durable
# record this home keeps for it.
add_local_mate() {
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-} evidence=${5:-armed}
  local home="$dir/home" smhome="$dir/$id-home"
  fm_git_worktree "$dir/$id-repo" "$smhome" "sm-$id"
  mkdir -p "$smhome/state" "$smhome/data" "$smhome/bin" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# agents\n' > "$smhome/AGENTS.md"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  if [ "$evidence" = armed ]; then
    "$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id" \
      --state idle --source claude-hook --event stop >/dev/null \
      || fail "could not arm the local mate's idle evidence"
  fi
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}

# add_repo_backed_mate <case-dir> <id> [harness] [backend-line]
# Like add_local_mate, but the world is the one /updatefirstmate actually runs
# against: a bare origin, a firstmate repo clone on its default branch, and the
# mate's home as a DETACHED worktree of that repo already sitting on origin's tip.
# That "already current" home is the shape the old classifier skipped entirely.
add_repo_backed_mate() {  # <case-dir> <id> [harness] [backend]
  local dir=$1 id=$2 harness=${3:-claude} backend=${4:-} evidence=${5:-armed}
  local home="$dir/home" repo="$dir/fmrepo" smhome="$dir/$id-home"
  if [ ! -d "$repo" ]; then
    git init -q --bare "$dir/origin.git"
    git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$dir/origin.git" "$dir/seed" 2>/dev/null
    mkdir -p "$dir/seed/bin" "$dir/seed/.agents/skills"
    printf '# agents\n' > "$dir/seed/AGENTS.md"
    printf 'echo a\n' > "$dir/seed/bin/tool.sh"
    printf 's1\n' > "$dir/seed/.agents/skills/note.md"
    # The operational dirs a live home carries are gitignored in a real firstmate
    # checkout; without that the home would read as dirty and be skipped.
    printf '/data/\n/state/\n/config/\n/projects/\n/.no-mistakes/\n.fm-secondmate-home\n' \
      > "$dir/seed/.gitignore"
    git -C "$dir/seed" add -A
    git -C "$dir/seed" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm c1
    git -C "$dir/seed" push -q origin main
    git clone -q "$dir/origin.git" "$repo"
    git -C "$repo" remote set-head origin main >/dev/null 2>&1 || true
    touch "$home/state/.last-watcher-beat"
  fi
  git -C "$repo" worktree add -q --detach "$smhome" main
  mkdir -p "$smhome/state" "$smhome/data" "$home/data/$id"
  printf '%s\n' "$id" > "$smhome/.fm-secondmate-home"
  printf '# charter\n' > "$home/data/$id/brief.md"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=$harness"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$smhome"
    [ -z "$backend" ] || echo "backend=$backend"
  } > "$home/state/$id.meta"
  if [ "$evidence" = armed ]; then
    "$ROOT/bin/fm-busy-event.sh" arm "$home/state" "$id" \
      --state idle --source claude-hook --event stop >/dev/null \
      || fail "could not arm the local mate's idle evidence"
  fi
  printf '%s\n' "fm-$id" >> "$dir/fake/windows"
  printf '%s' "$smhome" > "$dir/fake/cwd"
}

# run_update_in_case <case-dir>: the real /updatefirstmate mechanics over that world.
run_update_in_case() {
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" \
    FM_ROOT_OVERRIDE="$dir/fmrepo" FM_HOME="$dir/home" \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$ROOT/bin/fm-update.sh" 2>/dev/null
}

# arm_answer <case-dir> <id>: make the modelled mate answer the persist request.
arm_answer() {
  local dir=$1 id=$2
  printf '%s' "$dir/home/state/$id.inbox" > "$dir/fake/answer-inbox"
  printf '%s' "$dir/home/state/$id.status" > "$dir/fake/answer-status"
}

run_restart() {  # <case-dir> <args...>
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_ROOT_OVERRIDE="$dir/code" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_SECONDMATE_PERSIST_POLL=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$RESTART" "$@" 2>&1
}


# assert_line / assert_no_line <line> <file> <msg>: a whole line is (not) present.
assert_line() {
  grep -qxF -- "$1" "$2" 2>/dev/null || fail "$3"
}
assert_no_line() {
  ! grep -qxF -- "$1" "$2" 2>/dev/null || fail "$3"
}

# process_requests <case-dir>: the supervision half the watcher runs detached.
process_requests() {
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_ROOT_OVERRIDE="$dir/code" \
    FM_CONFIG_OVERRIDE="$dir/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_SECONDMATE_PERSIST_POLL=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_SSH_BIN="${FM_TEST_SSH_BIN:-ssh}" \
    "$RESTART" --process-requests 2>&1
}

# answer_now <case-dir> <id>: the modelled mate answers its recorded request.
answer_now() {
  local dir=$1 id=$2 corr
  corr=$(sed -n 's/^corr=//p' "$dir/home/state/.secondmate-restart-$id.request")
  [ -n "$corr" ] || fail "no restart request is recorded for $id"
  printf 'done [corr=%s]: open records written down\n' "$corr" >> "$dir/home/state/$id.status"
}

# --- T1: the persist request is the task subset of /stow, and it gates --------
test_persist_gates_and_asks_only_for_open_records() {
  local dir out rc request
  dir=$(new_case gate)
  add_local_mate "$dir" sm1
  # No answer armed: the mate never confirms its open work is written down.
  out=$(run_restart "$dir" fm-sm1); rc=$?

  expect_code 0 "$rc" "an unconfirmed persist is queued, not a failure"$'\n'"$out"
  assert_contains "$out" "queued: sm1:" "an unconfirmed persist must leave the restart queued"
  assert_contains "$out" "its open work is written down" "the queued line must name the missing confirmation"
  assert_not_contains "$out" "nudged: sm1" "a queued restart must not be downgraded to the re-read message"
  assert_not_contains "$out" "restarted: sm1" "a mate that never confirmed must not be restarted"
  assert_contains "$out" "summary: 0 of 1 restarted, 1 queued, 0 nudged, 0 unreached" "the summary must not claim a reload"
  grep -q '^corr=[0-9a-f]\{16\}$' "$dir/home/state/.secondmate-restart-sm1.request" \
    || fail "the queued restart was not recorded durably with its correlation"
  # The agent is untouched: nothing exited, nothing relaunched.
  assert_no_line '/exit' "$dir/fake/literal" "the agent was stopped without a confirmed persist"
  assert_absent "$dir/home/state/sm1.control-relaunch" \
    "a restart transaction was opened without a confirmed persist"
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=awaiting_report$' \
    || fail "the unanswered persist expectation was closed instead of left to recovery"

  # The request the mate actually received is the open-record half of /stow only.
  request=$(cat "$dir/home/state/sm1.inbox"/*.msg)
  assert_contains "$request" "Open-record persistence" "the request must reuse stow's open-record contract"
  assert_contains "$request" "file a task for each open record" "the request must ask for the unfiled open records"
  assert_contains "$request" "correct any task whose status" "the request must ask for stale task status"
  assert_contains "$request" "captain call you had formed but never registered" \
    "the request must flush an unregistered captain call"
  assert_contains "$request" "Do NOT run the memory, learnings, or captain-preference sweeps" \
    "the request must exclude the memory curation half of stow"

  # Supervision's later pass changes nothing while the answer is still missing.
  out=$(process_requests "$dir") || fail "the supervision pass failed: $out"
  assert_no_line '/exit' "$dir/fake/literal" "a supervision pass stopped a mate that never confirmed"
  assert_present "$dir/home/state/.secondmate-restart-sm1.request" "an unanswered request was dropped"
  pass "T1 persist is a gate, and asks for open records and task status only"
}

# --- T2: persist THEN restart, in that order --------------------------------
test_persist_precedes_restart() {
  local dir out rc doorbell_line exit_line
  dir=$(new_case order)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a confirmed persist should restart the mate"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" "the mate should be restarted on its pinned runtime"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 queued, 0 nudged, 0 unreached" "the summary should report the reload"
  # The pane transcript orders the two phases: the instruction doorbell first,
  # the harness exit command only after it.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the mate"
  [ -n "$exit_line" ] || fail "the mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # The reply expectation is settled rather than left open behind the restart.
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=resolved$' \
    || fail "the persist answer did not settle its durable expectation"
  pass "T2 the mate persists before anything is stopped"
}

# --- T2b: an answer delivered with the request restarts in the same pass -----
test_arrived_answer_precedes_deadline_check() {
  local dir out rc
  dir=$(new_case arrived-at-bound)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an answer delivered with the request must restart at once"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the arrived persist answer was ignored"
  assert_absent "$dir/home/state/.secondmate-restart-sm1.outcome" \
    "an outcome the command reported itself was left for supervision to report again"
  pass "T2b an arrived persist answer restarts the mate in the same pass"
}

# --- T2c: an answer arriving after the command's try is finished later -------
test_answer_between_resolution_and_timeout_wins() {
  local dir out rc
  dir=$(new_case answer-at-timeout-decision)
  add_local_mate "$dir" sm1

  # Delay the modelled answer until the first resolution attempt has completed
  # its unsuccessful status scan. The real pending-reply machinery publishes
  # that scan signature with mv; this wrapper appends the correlated answer only
  # after that publication, reproducing the boundary race deterministically.
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
/bin/mv "$@" || exit $?
target=${!#}
case "$target" in
  "${FM_FAKE_DIR%/fake}"/home/state/pending-replies/*)
    if [ ! -e "$FM_FAKE_DIR/answer-after-scan" ] \
      && grep -q '^parent_status_scan_signature=.' "$target"; then
      : > "$FM_FAKE_DIR/answer-after-scan"
      corr=${target##*/}
      status=$(sed -n 's/^parent_status=//p' "$target")
      printf 'done [corr=%s]: open records written down\n' "$corr" >> "$status"
    fi
    ;;
esac
SH
  chmod +x "$dir/fakebin/mv"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an answer landing after the command's try must leave the restart queued"$'\n'"$out"
  assert_contains "$out" "queued: sm1" "the late answer was neither restarted nor queued"
  assert_not_contains "$out" "nudged: sm1" "a mate that confirmed late must not take a fallback"
  out=$(process_requests "$dir") || fail "the supervision pass failed: $out"
  assert_grep 'restarted: sm1' "$dir/home/state/.secondmate-restart-sm1.outcome" \
    "supervision did not finish the restart once the late answer landed"
  assert_absent "$dir/home/state/.secondmate-restart-sm1.request" "a finished restart left its request behind"
  assert_line '/exit' "$dir/fake/literal" "the late-confirmed mate was never stopped"
  pass "T2c a reply landing after the command's try is restarted by the next supervision pass"
}

# --- T3: a runtime that cannot prove a restart never gets one ----------------
test_unprovable_runtime_falls_back() {
  local dir out rc
  dir=$(new_case unprovable)
  # zellij has no recovery-grade agent-state classifier, so "the old agent
  # stopped and the replacement came up" can never be established there.
  add_local_mate "$dir" sm1 claude zellij

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable runtime must not report a reload"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "an unprovable runtime must fall back to the re-read message"
  assert_contains "$out" "cannot prove an agent stopped" "the fallback must name the runtime limit"
  assert_not_contains "$out" "restarted: sm1" "an unprovable runtime must not be reported as restarted"
  # It is never even asked to spend a turn persisting, because it could not be
  # restarted afterwards either way; the only thing it was handed is the nudge.
  assert_no_grep 'Open-record persistence' "$dir/home/state/sm1.inbox/001.msg" \
    "a mate that cannot be restarted should not be asked to persist first"
  assert_grep 're-read your AGENTS.md' "$dir/home/state/sm1.inbox/001.msg" \
    "the fallback should hand the mate the ordinary re-read message"
  pass "T3 a runtime that cannot prove a restart falls back to the re-read message"
}

# --- T4: a mate with no durable record in this home --------------------------
test_unknown_mate_is_accounted_for() {
  local dir out rc
  dir=$(new_case unknown)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1

  out=$(run_restart "$dir" sm1 ghost); rc=$?

  expect_code 3 "$rc" "an unknown mate must not pass silently"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "the known mate should still be restarted"
  assert_contains "$out" "ghost:" "the unknown mate must be accounted for by name"
  assert_contains "$out" "no durable record" "the unknown mate's reason must be concrete"
  assert_contains "$out" "summary: 1 of 2 restarted, 0 queued, 0 nudged, 1 unreached" "the summary must count both mates"
  pass "T4 every named mate is accounted for, including one this home does not know"
}

# --- T5: a refused restart leaves the mate running and says so ---------------
test_refused_restart_falls_back_without_claiming_a_reload() {
  local dir out rc before
  dir=$(new_case refused)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  # muse is a crewmate-only adapter, so the control plane refuses a secondmate
  # relaunch onto it BEFORE stopping anything.
  printf 'muse\n' > "$dir/home/config/secondmate-harness"
  before=$(cat "$dir/fake/command")

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a refused restart must not be reported as a reload"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "a failed restart must be reported as unknown"
  assert_contains "$out" "restart outcome is unknown" "the report must not attribute an ambiguous failure"
  assert_not_contains "$out" "nudged: sm1" "a failed restart must not claim the old agent was nudged"
  assert_not_contains "$out" "restarted: sm1" "a refused restart must not be reported as restarted"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "a refusal before the stop should leave the running agent exactly as it was"
  assert_no_line '/exit' "$dir/fake/literal" "a pre-stop refusal must not have stopped the agent"
  pass "T5 a refused restart leaves the mate running and reports an unknown outcome"
}

setup_remote_case() {  # <case-dir> <id> <ssh-mode>
  local dir=$1 id=$2 mode=$3
  local fb="$dir/fakebin"
  mkdir -p "$dir/$id-home"
  {
    echo "window=remote:$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/$id-home"
    echo "project=$dir/$id-home"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/$id-home"
    echo "remote_host=remote-mac"
    echo "remote_backend=herdr"
    echo "remote_target=fm-remote:2ndmate-$id"
  } > "$dir/home/state/$id.meta"
  printf -- '- %s - remote domain (host: remote-mac; root: /srv/fm; home: /srv/%s; scope: things; projects: p; added 2026-09-03)\n' \
    "$id" "$id" > "$dir/home/data/secondmates.md"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
cat > /dev/null
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2  # host, fm-remote-entrypoint.sh
argv_b64=$4
decode() { printf '%s' "$1" | base64 --decode 2>/dev/null || printf '%s' "$1" | base64 -D; }
rargs=()
while IFS= read -r -d '' a; do rargs+=("$a"); done < <(decode "$argv_b64")
printf '%s\n' "${rargs[*]}" >> "$FM_FAKE_SSH_LOG"
case "${FM_FAKE_SSH_MODE:-ok}" in
  unreachable) exit 255 ;;
esac
exit 0
SH
  chmod +x "$fb/fake-ssh"
  : > "$dir/ssh.log"
  export FM_FAKE_SSH_LOG="$dir/ssh.log"
  export FM_FAKE_SSH_MODE="$mode"
  export FM_TEST_SSH_BIN="$fb/fake-ssh"
}

# --- T7: an unreachable host is unknown, never a claimed reload --------------
test_unreachable_host_is_reported_unknown() {
  local dir out rc
  dir=$(new_case unreachable)
  setup_remote_case "$dir" sm3 unreachable

  out=$(run_restart "$dir" sm3); rc=$?

  expect_code 3 "$rc" "an unreachable host must not be reported as a reload"$'\n'"$out"
  assert_not_contains "$out" "restarted: sm3" "an unreachable host must not be claimed as restarted"
  assert_contains "$out" "sm3:" "the unreachable mate must still be named"
  assert_contains "$out" "re-read message could not be delivered" "an unreachable host must be reported as undelivered, not as reloaded"
  pass "T7 an unreachable host is reported honestly instead of claimed as reloaded"
}

# --- T8: a local restart lands on this home's durable pin, and says which -----
test_local_restart_uses_the_home_pin_and_reports_what_ran() {
  local dir out rc
  dir=$(new_case pin)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'codex\n' > "$dir/home/config/secondmate-harness"
  printf 'codex' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a pinned local restart should succeed"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (codex)" \
    "the restart should land on this home's pin and report the runtime that actually came up"
  [ "$(grep '^harness=' "$dir/home/state/sm1.meta" | tail -1)" = "harness=codex" ] \
    || fail "the durable record did not follow the replacement onto the pinned runtime"
  pass "T8 a local restart re-resolves this home's pin and reports the runtime that came up"
}

test_native_ultra_restart_keeps_local_profile() {
  local dir out rc
  dir=$(new_case native-local)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'pi codex-native/gpt-6-astra ultra\n' > "$dir/home/config/secondmate-harness"
  printf 'pi' > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" "native local restart failed: $out"
  assert_contains "$out" "restarted: sm1 (pi)" "native local restart did not complete"
  assert_contains "$(cat "$dir/home/state/sm1.meta")" "effort=ultra" "local restart dropped native effort"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "local restart dropped native launch flag"

  pass "native Ultra survives local restart"
}

# --- T9: an unrelated concurrent reply cannot release the persist gate -------
test_concurrent_reply_cannot_release_persist_gate() {
  local dir out rc state corr rec
  dir=$(new_case correlation)
  add_local_mate "$dir" sm1
  state="$dir/home/state"
  corr=ffffffffffffffff
  rec="$state/pending-replies/$corr"
  cat > "$dir/fake/on-doorbell" <<SH
#!/usr/bin/env bash
[ ! -e "$dir/fake/concurrent-created" ] || exit 0
: > "$dir/fake/concurrent-created"
mkdir -p "$state/pending-replies"
cat > "$rec" <<EOF
phase=awaiting_report
task_id=sm1
parent_status=$state/sm1.status
parent_status_scan_signature=
delivered_epoch=1
resolved_epoch=
resolved_via=
EOF
printf 'done [corr=$corr]: unrelated request answered\n' >> "$state/sm1.status"
SH
  chmod +x "$dir/fake/on-doorbell"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "an unrelated concurrent answer must leave the restart queued"$'\n'"$out"
  assert_contains "$out" "queued: sm1" "an unrelated answer must not finish the queued restart"
  assert_not_contains "$out" "restarted: sm1" "the unrelated answer authorized a restart"
  assert_no_line '/exit' "$dir/fake/literal" "the unrelated answer stopped the mate"
  pass "T9 the persist gate retains its explicitly allocated correlation"
}

# --- T10: one unanswered mate does not hold a confirmed mate behind it -------
test_persist_waits_are_polled_together() {
  local dir out rc exit_line nudge_line
  dir=$(new_case concurrent-waits)
  add_local_mate "$dir" sm1
  add_local_mate "$dir" sm2
  arm_answer "$dir" sm2

  out=$(run_restart "$dir" sm1 sm2); rc=$?

  expect_code 0 "$rc" "one unanswered mate must not hold the confirmed mate behind it"$'\n'"$out"
  assert_contains "$out" "restarted: sm2" "the confirmed mate was held behind the unanswered one"
  assert_contains "$out" "queued: sm1" "the unanswered mate was not left queued"
  assert_contains "$out" "summary: 1 of 2 restarted, 1 queued, 0 nudged, 0 unreached" "both mates must be accounted for"
  pass "T10 one unanswered mate never holds a confirmed mate behind it"
}

# --- T11: a failed post-stop relaunch is not described as a nudge ------------
test_post_stop_failure_is_reported_unreached() {
  local dir out rc
  dir=$(new_case post-stop)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'zsh' > "$dir/fake/becomes"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "a post-stop relaunch failure must remain accounted for"$'\n'"$out"
  assert_contains "$out" "unreached: sm1:" "a stopped mate must be reported as unreached"
  assert_contains "$out" "restart outcome is unknown" "the report must not attribute the failed lifecycle operation"
  assert_not_contains "$out" "nudged: sm1" "a durable enqueue must not masquerade as a running mate's nudge"
  assert_contains "$out" "summary: 0 of 1 restarted, 0 queued, 0 nudged, 1 unreached" \
    "the summary must not claim that a stopped mate remains on older instructions with a message"
  pass "T11 post-stop restart failure is never misreported as a nudge"
}

# --- T12: relaunch work does not stop polling other persist answers ----------
test_relaunches_do_not_block_persist_polling() {
  local dir out rc
  dir=$(new_case relaunch-polling)
  setup_remote_case "$dir" sm1 ok
  add_local_mate "$dir" sm2
  printf -- '- sm2 - local domain (home: %s; scope: things; projects: p; added 2026-09-03)\n' \
    "$dir/sm2-home" >> "$dir/home/data/secondmates.md"
  arm_answer "$dir" sm2

  out=$(run_restart "$dir" sm1 sm2); rc=$?

  expect_code 3 "$rc" "the unsupported remote mate must be accounted for"$'\n'"$out"
  assert_contains "$out" "summary: 1 of 2 restarted, 0 queued, 1 nudged, 0 unreached" \
    "the remote nudge blocked the independently idle local mate"
  assert_absent "$dir/home/state/.secondmate-restart-sm1.request" "the remote mate was queued"
  assert_no_grep 'fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" \
    "the remote nudge bypassed the turn-end gate"
  pass "T12 a remote nudge does not block an independently idle local mate"
}

# --- T13: a worker that cannot publish its result cannot hang the pass -------
test_unpublished_worker_result_is_accounted_for() {
  local dir out rc_file driver i result_dir
  dir=$(new_case worker-result)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  cat > "$dir/fake/on-exit" <<'SH'
#!/usr/bin/env bash
: > "$FM_FAKE_DIR/local-relaunch-start"
/bin/sleep 2
SH
  chmod +x "$dir/fake/on-exit"
  out="$dir/restart.out"
  rc_file="$dir/restart.rc"

  ( run_restart "$dir" sm1 > "$out" 2>&1; printf '%s\n' "$?" > "$rc_file" ) &
  driver=$!
  result_dir=
  i=0
  while [ "$i" -lt 200 ]; do
    result_dir=$(find "$dir/home/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    [ -e "$dir/fake/local-relaunch-start" ] && [ -n "$result_dir" ] && break
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -n "$result_dir" ] || { kill "$driver" 2>/dev/null || true; fail "restart result directory never appeared"; }
  rm -rf -- "$result_dir"
  i=0
  while kill -0 "$driver" 2>/dev/null && [ "$i" -lt 400 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  if kill -0 "$driver" 2>/dev/null; then
    kill "$driver" 2>/dev/null || true
    wait "$driver" 2>/dev/null || true
    fail "a terminated restart worker left the parent hung"
  fi
  wait "$driver" 2>/dev/null || true
  unset FM_FAKE_ANSWER_STATUS

  [ "$(cat "$rc_file")" = 3 ] || fail "an unpublished worker result did not fail as accounted"
  assert_contains "$(cat "$out")" "restart worker exited before publishing an outcome" \
    "the missing worker result was not reported"
  assert_contains "$(cat "$out")" "summary: 0 of 1 restarted, 0 queued, 0 nudged, 1 unreached" \
    "the missing worker result was not included in the summary"
  pass "T13 a dead restart worker cannot hang the parent"
}

# --- T14: result publication after the first probe remains authoritative -----
test_result_published_while_reaping_is_honored() {
  local dir out rc
  dir=$(new_case result-race)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  cat > "$dir/fake/on-exit" <<'SH'
#!/usr/bin/env bash
: > "$FM_FAKE_DIR/local-relaunch-start"
/bin/sleep 2
SH
  chmod +x "$dir/fake/on-exit"
  cat > "$dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ -e "$FM_FAKE_DIR/local-relaunch-start" ] && [ ! -e "$FM_FAKE_DIR/result-race-injected" ]; then
  result=$(find "$FM_HOME/state" -maxdepth 2 -name '0.result' -print -quit)
  if [ -z "$result" ]; then
    result_dir=$(find "$FM_HOME/state" -maxdepth 1 -type d -name '.secondmate-restart.*' -print -quit)
    if [ -n "$result_dir" ]; then
      printf 'restarted: sm1 (claude)\n' > "$result_dir/0.result"
      : > "$FM_FAKE_DIR/result-race-injected"
      printf 'Z\n'
      exit 0
    fi
  fi
fi
exec /bin/ps "$@"
SH
  chmod +x "$dir/fakebin/ps"

  out=$(run_restart "$dir" sm1); rc=$?
  unset FM_FAKE_ANSWER_STATUS

  expect_code 0 "$rc" "a result published while the worker is reaped must remain authoritative"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" \
    "the result published during the reap window was replaced with a worker failure"
  assert_not_contains "$out" "exited before publishing" \
    "the parent failed to recheck the worker result after wait"
  pass "T14 a result published during reaping is honored"
}

# --- T15: an already-current mate still restarts, end to end -----------------
# The SSHHIP regression, driven through BOTH real commands rather than either
# one's own idea of the other. The mate's home needs no fast-forward at all, so
# the old instruction-diff classifier left it out of every action set and its
# agent kept running the launch-time wiring it started with. The update pass must
# now name it, and the restart pass must then persist its open records and only
# afterwards replace the agent.
test_already_current_mate_restarts_end_to_end() {
  local dir out restart_line ids rc head_before head_after doorbell_line exit_line
  dir=$(new_case already-current)
  add_repo_backed_mate "$dir" sm1
  arm_answer "$dir" sm1
  head_before=$(git -C "$dir/sm1-home" rev-parse HEAD)

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  assert_contains "$restart_line" "fm-sm1" \
    "an already-current live second mate must still be named for restart"
  assert_contains "$out" "nudge-secondmates: none" \
    "a mate named for restart must not also be steered"

  ids=${restart_line#restart-secondmates: }
  # shellcheck disable=SC2086
  out=$(run_restart "$dir" $ids); rc=$?

  expect_code 0 "$rc" "the mate named by the update pass did not restart"$'\n'"$out"
  assert_contains "$out" "restarted: sm1" "an already-current mate must actually be replaced"
  assert_contains "$out" "summary: 1 of 1 restarted, 0 queued, 0 nudged, 0 unreached" \
    "the pass must report the reload it performed"
  # Persist strictly before replace, read off the pane transcript.
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the already-current mate"
  [ -n "$exit_line" ] || fail "the already-current mate was never stopped, so it was not restarted"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  # Nothing about the home's git state was touched to buy that restart.
  head_after=$(git -C "$dir/sm1-home" rev-parse HEAD)
  [ "$head_after" = "$head_before" ] || fail "the already-current home's checkout moved"
  [ -z "$(git -C "$dir/sm1-home" status --porcelain)" ] \
    || fail "the restart left the mate's home dirty"
  pass "T15 an already-current live mate is named by the update pass and genuinely restarted"
}

# --- T16: an already-current mate that cannot prove a restart stays honest ----
# Same already-current home, a runtime with no recovery-grade state classifier.
# Unconditional restart must not become an unconditional CLAIM of one: the update
# pass routes it to the re-read steer, and the restart pass reports a nudge with
# the agent still running.
test_already_current_unprovable_mate_stays_on_the_nudge_path() {
  local dir out rc restart_line nudge_line before
  dir=$(new_case already-current-unprovable)
  # zellij can never establish "the old agent stopped and the replacement came up".
  add_repo_backed_mate "$dir" sm1 claude zellij
  arm_answer "$dir" sm1
  before=$(cat "$dir/fake/command")

  out=$(run_update_in_case "$dir")

  assert_contains "$out" "secondmate sm1: already current" \
    "the fixture must model a home that needs no advance"
  restart_line=$(printf '%s\n' "$out" | grep '^restart-secondmates:')
  nudge_line=$(printf '%s\n' "$out" | grep '^nudge-secondmates:')
  assert_not_contains "$restart_line" "sm1" \
    "a mate whose restart cannot be proven must stay out of the restart set"
  assert_contains "$nudge_line" "fm-sm1" \
    "a live mate that cannot be restarted must keep the honest re-read steer"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 3 "$rc" "an unprovable restart must not report success"$'\n'"$out"
  assert_contains "$out" "nudged: sm1:" "the fallback must be reported as a nudge"
  assert_not_contains "$out" "restarted: sm1" "an unprovable mate must never be reported as reloaded"
  [ "$(cat "$dir/fake/command")" = "$before" ] \
    || fail "the unprovable mate's agent was stopped anyway"
  assert_no_line '/exit' "$dir/fake/literal" "nothing may be stopped on the nudge path"
  pass "T16 an already-current mate with an unprovable runtime keeps the honest nudge path"
}

# --- T12: a TeamClaude home restarts its Claude mate through TeamClaude ----
test_teamclaude_restart_reaches_claude_through_the_proxy() {
  local dir out rc
  dir=$(new_case teamclaude)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  printf 'teamclaude\n' > "$dir/home/config/claude-launcher"
  fm_test_fake_teamclaude "$dir/fakebin"

  out=$(run_restart "$dir" sm1); rc=$?

  expect_code 0 "$rc" "a TeamClaude restart should succeed"$'\n'"$out"
  assert_contains "$out" "restarted: sm1 (claude)" "the mate should be restarted on claude"
  fm_test_assert_teamclaude_launch "$dir/fakebin" \
    "$(grep -F 'Firstmate operational input waiting: read' "$dir/fake/literal" | tail -1)" \
    "secondmate restart"
  pass "T12 a TeamClaude home restarts its Claude mate through the TeamClaude proxy"
}

# --- T17: an answered mate still inside its turn is not stopped mid-turn -----
# The answer is one event; the end of the turn that wrote it is the other. A
# semantic busy record proves the turn is still running, so supervision keeps
# the request until the record says the turn ended.
test_answered_mate_mid_turn_waits_for_turn_end() {
  local dir out rc state now
  dir=$(new_case mid-turn)
  add_local_mate "$dir" sm1
  state="$dir/home/state"
  printf 'g1\n' > "$state/sm1.busy-gen"
  now=$(date +%s)
  printf 'v1 gen=g1 seq=1 state=busy source=claude-hook event=prompt ts=%s\n' "$now" > "$state/sm1.busy-state"

  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" "a queued restart is not a failure"$'\n'"$out"
  answer_now "$dir" sm1
  out=$(process_requests "$dir") || fail "the supervision pass failed: $out"
  assert_no_line '/exit' "$dir/fake/literal" "a mate was stopped while its busy record proved a running turn"
  assert_present "$state/.secondmate-restart-sm1.request" "the request was dropped while the turn was still running"
  grep -q '^answered_at=[0-9]' "$state/.secondmate-restart-sm1.request" \
    || fail "the seen answer was not recorded on the request"

  printf 'v1 gen=g1 seq=2 state=idle source=claude-hook event=stop ts=%s\n' "$now" > "$state/sm1.busy-state"
  out=$(process_requests "$dir") || fail "the supervision pass failed: $out"
  assert_line '/exit' "$dir/fake/literal" "the mate was not restarted after its turn ended"
  assert_grep 'restarted: sm1' "$state/.secondmate-restart-sm1.outcome" "the finished restart left no outcome"
  pass "T17 an answered mate is restarted only after the turn that answered ends"
}

test_new_turn_during_checkpoint_keeps_restart_queued() {
  local dir out rc state verdict real_git
  real_git=$(command -v git)
  for verdict in busy unknown composer; do
    dir=$(new_case "checkpoint-$verdict")
    add_local_mate "$dir" sm1
    state="$dir/home/state"
    arm_answer "$dir" sm1
    printf '%s\n' "$real_git" > "$dir/fake/real-git"
    printf '%s\n' "$verdict" > "$dir/fake/new-turn"
    cat > "$dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${3:-}" = status ] && [ "${4:-}" = --porcelain ] && [ -f "$FM_FAKE_DIR/new-turn" ]; then
  verdict=$(cat "$FM_FAKE_DIR/new-turn")
  rm -f "$FM_FAKE_DIR/new-turn"
  if [ "$verdict" = composer ]; then
    cat > "$FM_FAKE_DIR/on-composer" <<'HOOK'
#!/usr/bin/env bash
rm -f "$FM_FAKE_DIR/on-composer"
"$FM_ROOT_OVERRIDE/bin/fm-busy-event.sh" apply "$FM_HOME/state" sm1 busy \
  --current-gen --source claude-hook --event prompt >/dev/null || exit 1
: > "$FM_FAKE_DIR/turn-started-at-composer"
HOOK
    chmod +x "$FM_FAKE_DIR/on-composer"
  else
    "$FM_ROOT_OVERRIDE/bin/fm-busy-event.sh" apply "$FM_HOME/state" sm1 "$verdict" \
      --current-gen --source claude-hook --event prompt >/dev/null || exit 1
  fi
  : > "$FM_FAKE_DIR/turn-started-during-checkpoint"
fi
exec "$(cat "$FM_FAKE_DIR/real-git")" "$@"
SH
    chmod +x "$dir/fakebin/git"
    out=$(run_restart "$dir" sm1); rc=$?
    expect_code 0 "$rc" "a new $verdict turn must defer the restart: $out"
    assert_present "$dir/fake/turn-started-during-checkpoint" "the turn transition never reached checkpointing"
    if [ "$verdict" = composer ]; then
      assert_present "$dir/fake/turn-started-at-composer" "the turn transition never reached the final composer boundary"
    fi
    assert_contains "$out" "queued: sm1" "the stop boundary did not retain the restart"
    assert_present "$state/.secondmate-restart-sm1.request" "the stop boundary discarded intent"
    assert_absent "$state/.secondmate-restart-sm1.outcome" "the stop boundary recorded completion"
    assert_no_line '/exit' "$dir/fake/literal" "the new turn received an exit command"
    assert_no_line 'C-c' "$dir/fake/keys" "the new turn was interrupted"
    "$ROOT/bin/fm-busy-event.sh" apply "$state" sm1 idle --current-gen \
      --source claude-hook --event stop >/dev/null || fail "could not end the new turn"
    out=$(process_requests "$dir") || fail "the next turn end did not release the restart: $out"
    assert_line '/exit' "$dir/fake/literal" "the idle retry did not stop the mate"
    assert_grep 'restarted: sm1' "$state/.secondmate-restart-sm1.outcome" "the idle retry did not complete"
  done
  pass "a new turn during checkpointing defers stop without consuming restart intent"
}

# --- T18: a restart and the automatic relaunch never contend -----------------
# Both hold the same per-mate lock: a liveness relaunch in progress defers the
# restart, and a restart in progress holds the lock across its own stop and
# relaunch, so the watcher's probe cannot read the gap as a dead endpoint.
test_restart_and_auto_relaunch_share_one_lock() {
  local dir out state holder driver i
  dir=$(new_case shared-lock)
  add_local_mate "$dir" sm1
  arm_answer "$dir" sm1
  state="$dir/home/state"
  mkdir -p "$dir/bin"
  cat > "$dir/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_FAKE_DIR/auto-relaunch-start"
for ((i = 0; i < 500; i++)); do
  [ ! -e "$FM_FAKE_DIR/auto-relaunch-release" ] || exit 0
  /bin/sleep 0.01
done
exit 1
SH
  chmod +x "$dir/bin/fm-spawn.sh"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" STATE="$state" \
    bash -c '
      . "$1/bin/fm-secondmate-liveness-lib.sh"
      FM_ROOT=$2
      fm_secondmate_liveness_lock sm1 || exit 1
      FM_SM_LIVE_STATE=missing FM_SM_LIVE_KILL=0
      fm_secondmate_liveness_relaunch "$STATE/sm1.meta" sm1
      rc=$?
      fm_secondmate_liveness_unlock sm1
      exit "$rc"
    ' _ "$ROOT" "$dir" &
  holder=$!
  i=0
  while [ ! -e "$dir/fake/auto-relaunch-start" ] && [ "$i" -lt 500 ]; do /bin/sleep 0.01; i=$((i + 1)); done
  [ -e "$dir/fake/auto-relaunch-start" ] || { kill "$holder" 2>/dev/null; fail "the automatic relaunch never started"; }
  ( run_restart "$dir" sm1 > "$dir/restart.out"; printf '%s\n' "$?" > "$dir/restart.rc" ) &
  driver=$!
  i=0
  while ! grep -q 'waiting to record its restart request' "$dir/restart.out" 2>/dev/null && [ "$i" -lt 500 ]; do /bin/sleep 0.01; i=$((i + 1)); done
  assert_contains "$(cat "$dir/restart.out")" "waiting to record its restart request" "busy admission was not reported"
  assert_absent "$state/.secondmate-restart-sm1.request" "admission published during automatic relaunch"
  assert_absent "$state/pending-replies" "admission created a correlation during automatic relaunch"
  assert_absent "$state/sm1.inbox" "admission delivered a request during automatic relaunch"
  assert_no_line '/exit' "$dir/fake/literal" "the restart stopped a mate being automatically relaunched"
  cat > "$dir/fake/on-doorbell" <<'SH'
#!/usr/bin/env bash
[ -L "$FM_HOME/state/.secondmate-liveness-sm1.lock" ] || exit 1
: > "$FM_FAKE_DIR/lock-held-at-delivery"
SH
  cat > "$dir/fake/on-exit" <<'SH'
#!/usr/bin/env bash
[ -L "$FM_HOME/state/.secondmate-liveness-sm1.lock" ] || exit 1
: > "$FM_FAKE_DIR/lock-held-at-exit"
SH
  chmod +x "$dir/fake/on-doorbell" "$dir/fake/on-exit"
  : > "$dir/fake/auto-relaunch-release"
  wait "$holder" || fail "the automatic relaunch failed"
  wait "$driver" || fail "the restart driver failed"
  out=$(cat "$dir/restart.out")
  expect_code 0 "$(cat "$dir/restart.rc")" "admission lost the restart intent: $out"
  assert_contains "$out" "restarted: sm1" "the deferred admission did not restart the idle replacement"
  assert_not_contains "$out" "nudged: sm1" "busy admission fell back to a nudge"
  assert_present "$dir/fake/lock-held-at-delivery" "delivery did not hold the shared lock"
  assert_present "$dir/fake/lock-held-at-exit" "the restart did not hold the shared lock"
  assert_absent "$state/.secondmate-liveness-sm1.lock" "the restart left the shared lock held"
  pass "T18 admission and restart serialize with the automatic relaunch without losing intent"
}

# --- T19: a second pass reuses the recorded request instead of re-asking -----
test_second_pass_reuses_the_recorded_request() {
  local dir out rc first second
  dir=$(new_case reuse)
  add_local_mate "$dir" sm1
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" "the first pass should queue"$'\n'"$out"
  first=$(find "$dir/home/state/sm1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 0 "$rc" "the second pass should still be queued"$'\n'"$out"
  assert_contains "$out" "queued: sm1" "the second pass did not report the recorded restart"
  second=$(find "$dir/home/state/sm1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$first" = "$second" ] || fail "a second pass sent another persist request ($first then $second messages)"
  pass "T19 a repeated pass tries the recorded restart instead of asking the mate again"
}

run_restart_watcher_tick() {  # <case-dir>
  local dir=$1
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    bash -c '
      . "$1/bin/fm-watch.sh"
      wake() { printf "%s\n" "$1" >> "$FM_FAKE_DIR/wakes"; }
      touch "$STATE/.secondmate-restart-tick"
      secondmate_restart_tick
    ' _ "$ROOT" 2>&1
}

test_inconclusive_turn_evidence_stays_queued() {
  local dir state out rc kind
  for kind in missing unknown malformed generation missing-meta no-target; do
    dir=$(new_case "turn-$kind")
    add_local_mate "$dir" sm1
    state="$dir/home/state"
    cp "$state/sm1.meta" "$dir/meta"
    out=$(run_restart "$dir" sm1) || fail "could not record the restart: $out"
    answer_now "$dir" sm1
    case "$kind" in
      missing) rm -f "$state/sm1.busy-state" ;;
      unknown) "$ROOT/bin/fm-busy-event.sh" apply "$state" sm1 unknown --current-gen --source claude-hook --event error || fail "could not record unknown" ;;
      malformed) printf 'invalid\n' > "$state/sm1.busy-state" ;;
      generation) printf 'stale-generation\n' > "$state/sm1.busy-gen" ;;
      missing-meta) rm -f "$state/sm1.meta" ;;
      no-target) printf 'kind=secondmate\nharness=claude\n' > "$state/sm1.meta" ;;
    esac
    out=$(process_requests "$dir"); rc=$?
    expect_code 0 "$rc" "inconclusive $kind must wait: $out"
    assert_present "$state/.secondmate-restart-sm1.request" "$kind evidence retired the request"
    assert_absent "$state/.secondmate-restart-sm1.outcome" "$kind evidence published completion"
    assert_no_line '/exit' "$dir/fake/literal" "$kind evidence authorized a restart"
    cp "$dir/meta" "$state/sm1.meta"
    "$ROOT/bin/fm-busy-event.sh" arm "$state" sm1 --state idle --source claude-hook --event stop >/dev/null \
      || fail "could not restore affirmative idle"
    out=$(process_requests "$dir") || fail "affirmative idle did not release $kind: $out"
    assert_grep 'restarted: sm1' "$state/.secondmate-restart-sm1.outcome" "$kind never restarted after affirmative idle"
  done
  dir=$(new_case classifier-error)
  add_local_mate "$dir" sm1
  out=$(run_restart "$dir" sm1) || fail "could not record the restart: $out"
  answer_now "$dir" sm1
  out=$(FM_HOME="$dir/home" STATE="$dir/home/state" bash -c '
    . "$1/bin/fm-secondmate-restart-lib.sh"
    . "$1/bin/fm-pending-reply-lib.sh"
    . "$1/bin/fm-secondmate-liveness-lib.sh"
    fm_busy_classify_meta() { return 1; }
    fm_secondmate_restart_service "$STATE" sm1
  ' _ "$ROOT"); rc=$?
  expect_code 1 "$rc" "classifier failure released the restart: $out"
  assert_contains "$out" "affirmative turn-end evidence" "classifier failure did not explain its wait"
  assert_present "$dir/home/state/.secondmate-restart-sm1.request" "classifier failure discarded intent"
  assert_no_line '/exit' "$dir/fake/literal" "classifier failure authorized a restart"
  pass "inconclusive and failed turn classifiers retain the restart until affirmative idle"
}

test_unwired_launches_are_nudged_without_queueing() {
  local dir out rc harness evidence
  for harness in claude pi pi-signed omp; do
    for evidence in missing malformed generation source; do
      dir=$(new_case "unwired-$harness-$evidence")
      add_local_mate "$dir" sm1 "$harness" '' unarmed
      case "$evidence" in
        malformed) printf 'invalid\n' > "$dir/home/state/sm1.busy-state" ;;
        generation)
          "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" sm1 >/dev/null || fail "could not arm busy"
          printf 'other-launch\n' > "$dir/home/state/sm1.busy-gen"
          ;;
        source)
          "$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" sm1 --source alien >/dev/null || fail "could not arm source mismatch"
          ;;
      esac
      out=$(run_restart "$dir" sm1); rc=$?
      expect_code 3 "$rc" "unwired $harness/$evidence must be nudged: $out"
      assert_contains "$out" "nudged: sm1:" "unwired launch was not nudged"
      assert_contains "$out" "its current launch" "the nudge did not identify the missing launch wiring"
      assert_absent "$dir/home/state/.secondmate-restart-sm1.request" "unwired launch queued a restart"
      assert_absent "$dir/home/state/.secondmate-restart-sm1.outcome" "unwired launch reported a restart completion"
      assert_no_grep 'Open-record persistence' "$dir/home/state/sm1.inbox/001.msg" "unwired launch asked for a persist answer"
      assert_grep 're-read your AGENTS.md' "$dir/home/state/sm1.inbox/001.msg" "unwired launch did not receive the re-read steer"
      assert_no_line '/exit' "$dir/fake/literal" "unwired launch was stopped"
    done
  done
  pass "unwired current launches receive only a nudge and never queue a restart"
}

test_unverified_adapters_are_nudged_without_queueing() {
  local dir out rc harness
  for harness in codex kimi grok; do
    dir=$(new_case "unverified-$harness")
    add_local_mate "$dir" sm1 "$harness" '' unarmed
    out=$(run_restart "$dir" sm1); rc=$?
    expect_code 3 "$rc" "unverified $harness must be nudged: $out"
    assert_contains "$out" "nudged: sm1:" "unverified adapter was not nudged"
    assert_contains "$out" "'$harness' has no verified affirmative turn-end producer" "the nudge omitted its adapter limit"
    assert_absent "$dir/home/state/.secondmate-restart-sm1.request" "unverified adapter queued a restart"
    assert_no_grep 'Open-record persistence' "$dir/home/state/sm1.inbox/001.msg" "unverified adapter asked for a persist answer"
    assert_grep 're-read your AGENTS.md' "$dir/home/state/sm1.inbox/001.msg" "unverified adapter did not receive the re-read steer"
    assert_no_line '/exit' "$dir/fake/literal" "unverified adapter was stopped"
  done
  pass "Codex, Kimi and Grok receive only a nudge and never queue a restart"
}

test_remote_mates_are_nudged_without_queueing() {
  local dir out rc
  dir=$(new_case remote-nudge)
  setup_remote_case "$dir" sm1 ok
  out=$(run_restart "$dir" sm1); rc=$?
  expect_code 3 "$rc" "remote placement must be nudged: $out"
  assert_contains "$out" "nudged: sm1:" "remote mate was not nudged"
  assert_contains "$out" "remote placement has no reachable affirmative turn-end producer" "the nudge omitted the remote limit"
  assert_absent "$dir/home/state/.secondmate-restart-sm1.request" "remote mate queued a restart"
  assert_absent "$dir/home/state/.secondmate-restart-sm1.outcome" "remote mate reported restart completion"
  assert_no_grep 'Open-record persistence' "$dir/ssh.log" "remote mate asked for a persist answer"
  assert_grep 'fm-remote-secondmate-control.sh send sm1 ' "$dir/ssh.log" "remote mate did not receive the re-read steer"
  assert_grep 're-read your AGENTS.md' "$dir/ssh.log" "remote steer did not carry the re-read message"
  assert_no_grep 'fm-remote-secondmate-control.sh relaunch' "$dir/ssh.log" "remote nudge restarted the mate"
  pass "remote mates receive only a nudge and never queue a restart"
}

test_updater_routes_unwired_mates_to_nudges() {
  local dir out harness
  for harness in claude pi omp codex kimi grok; do
    dir=$(new_case "update-unwired-$harness")
    add_repo_backed_mate "$dir" sm1 "$harness" '' unarmed
    out=$(run_update_in_case "$dir") || fail "updater failed: $out"
    assert_contains "$out" "restart-secondmates: none" "updater admitted an unwired launch"
    assert_contains "$out" "nudge-secondmates: fm-sm1" "updater omitted the fallback steer"
    assert_absent "$dir/home/state/.secondmate-restart-sm1.request" "updater queued an unwired launch"
  done
  pass "updater routes unwired and unverified mates to the re-read list"
}

test_completed_outcome_is_replayed_without_relaunch() {
  local dir out state request
  dir=$(new_case outcome-replay)
  add_local_mate "$dir" sm1
  state="$dir/home/state"
  out=$(run_restart "$dir" sm1) || fail "could not queue the restart: $out"
  request="$state/.secondmate-restart-sm1.request"
  cp "$request" "$dir/request"
  answer_now "$dir" sm1
  out=$(process_requests "$dir") || fail "initial restart failed: $out"
  cp "$dir/request" "$request"
  : > "$dir/fake/literal"
  out=$(process_requests "$dir") || fail "outcome replay failed: $out"
  assert_no_line '/exit' "$dir/fake/literal" "outcome replay repeated the completed restart"
  assert_absent "$request" "outcome replay did not retire the leftover request"
  assert_grep 'restarted: sm1' "$state/.secondmate-restart-sm1.outcome" "replay lost the completion marker"
  cp "$dir/request" "$request"
  out=$(run_restart "$dir" sm1) || fail "CLI outcome consumption failed: $out"
  assert_contains "$out" "restarted: sm1" "the CLI did not preserve the completed outcome"
  assert_absent "$request" "the CLI left a completed request behind"
  assert_absent "$state/.secondmate-restart-sm1.outcome" "the CLI left its consumed outcome behind"
  assert_no_line '/exit' "$dir/fake/literal" "the CLI repeated the completed restart"
  pass "service and CLI replay completion markers without repeating relaunch"
}

test_outcome_consumers_hold_lock_and_preserve_failed_retirement() {
  local dir out rc state consumer
  for consumer in process cli watcher; do
    dir=$(new_case "outcome-$consumer")
    add_local_mate "$dir" sm1
    state="$dir/home/state"
    out=$(run_restart "$dir" sm1) || fail "could not record request: $out"
    printf 'restarted: sm1 (completed)\ncorr=%s\n' \
      "$(sed -n 's/^corr=//p' "$state/.secondmate-restart-sm1.request")" \
      > "$state/.secondmate-restart-sm1.outcome"
    cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    "$FM_HOME/state"/.secondmate-restart-sm1.request|"$FM_HOME/state"/.secondmate-restart-sm1.outcome)
      [ -L "$FM_HOME/state/.secondmate-liveness-sm1.lock" ] || {
        : > "$FM_FAKE_DIR/unlocked-consumption"
        exit 1
      }
      : > "$FM_FAKE_DIR/locked-consumption"
      case "$arg" in *.request) [ ! -e "$FM_FAKE_DIR/refuse-retirement" ] || exit 1 ;; esac
      ;;
  esac
done
exec /bin/rm "$@"
SH
    chmod +x "$dir/fakebin/rm"
    : > "$dir/fake/refuse-retirement"
    case "$consumer" in
      process) out=$(process_requests "$dir"); rc=$?; expect_code 3 "$rc" "service suppressed retirement failure: $out" ;;
      cli) out=$(run_restart "$dir" sm1); rc=$?; expect_code 3 "$rc" "CLI suppressed retirement failure: $out" ;;
      watcher) out=$(run_restart_watcher_tick "$dir"); rc=$?; expect_code 1 "$rc" "watcher suppressed retirement failure: $out" ;;
    esac
    assert_contains "$out" "could not be retired" "$consumer lost the concrete retirement failure"
    assert_present "$state/.secondmate-restart-sm1.request" "$consumer discarded the request despite failed retirement"
    assert_present "$state/.secondmate-restart-sm1.outcome" "$consumer discarded the completion marker"
    rm -f "$dir/fake/refuse-retirement"
    case "$consumer" in
      process) out=$(process_requests "$dir") || fail "service replay failed: $out"; out=$(run_restart_watcher_tick "$dir") || fail "watcher consumption failed: $out" ;;
      cli) out=$(run_restart "$dir" sm1) || fail "CLI replay failed: $out" ;;
      watcher) out=$(run_restart_watcher_tick "$dir") || fail "watcher replay failed: $out" ;;
    esac
    assert_present "$dir/fake/locked-consumption" "$consumer never used the per-mate lock"
    assert_absent "$dir/fake/unlocked-consumption" "$consumer consumed completion without its lock"
    assert_absent "$state/.secondmate-restart-sm1.request" "$consumer left the retired request"
    assert_absent "$state/.secondmate-restart-sm1.outcome" "$consumer left the consumed marker"
    assert_no_line '/exit' "$dir/fake/literal" "$consumer repeated the completed restart"
  done
  pass "outcome retirement and consumption hold the lock and retain completion on retirement failure"
}

test_completion_publication_failures_are_visible() {
  local dir out rc caller state
  for caller in process cli automatic; do
    dir=$(new_case "completion-$caller")
    add_local_mate "$dir" sm1
    state="$dir/home/state"
    out=$(run_restart "$dir" sm1) || fail "could not record request: $out"
    answer_now "$dir" sm1
    cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "${!#}" in "$FM_HOME/state"/.secondmate-restart-sm1.outcome) exit 1 ;; esac
exec /bin/mv "$@"
SH
    chmod +x "$dir/fakebin/mv"
    case "$caller" in
      process) out=$(process_requests "$dir"); rc=$?; expect_code 3 "$rc" "processing suppressed completion failure: $out" ;;
      cli) out=$(run_restart "$dir" sm1); rc=$?; expect_code 3 "$rc" "CLI suppressed completion failure: $out" ;;
      automatic)
        mkdir -p "$dir/bin"
        printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/fm-spawn.sh"
        chmod +x "$dir/bin/fm-spawn.sh"
        out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" STATE="$state" bash -c '
          . "$1/bin/fm-secondmate-liveness-lib.sh"
          FM_ROOT=$2
          fm_secondmate_liveness_lock sm1 || exit 1
          FM_SM_LIVE_STATE=missing FM_SM_LIVE_KILL=0
          fm_secondmate_liveness_relaunch "$STATE/sm1.meta" sm1
          rc=$?
          printf "%s|%s|%s\n" "$rc" "$FM_SM_LIVE_RC" "$FM_SM_LIVE_STATUS"
          printf "%s\n" "$FM_SM_LIVE_REASON"
          fm_secondmate_liveness_unlock sm1
          exit "$rc"
        ' _ "$ROOT" "$dir"); rc=$?
        expect_code 1 "$rc" "automatic relaunch suppressed completion failure: $out"
        assert_contains "$out" "1|1|skipped" "automatic caller still reported successful relaunch"
        ;;
    esac
    assert_contains "$out" "completion could not be recorded" "$caller lost the concrete completion failure"
    assert_present "$state/.secondmate-restart-sm1.request" "$caller lost intent on failed completion write"
    assert_absent "$state/.secondmate-restart-sm1.outcome" "$caller published a false completion marker"
    assert_absent "$state/.secondmate-liveness-sm1.lock" "$caller retained the liveness lock"
  done
  pass "CLI, supervision, and automatic relaunch expose completion publication failures"
}

test_concurrent_admission_creates_one_request() {
  local dir state first second i out count
  dir=$(new_case concurrent-admission)
  add_local_mate "$dir" sm1
  add_local_mate "$dir" sm2
  state="$dir/home/state"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ "${!#}" = "$FM_HOME/state/.secondmate-restart-sm1.request" ]; then
  [ -L "$FM_HOME/state/.secondmate-liveness-sm1.lock" ] || exit 1
  : > "$FM_FAKE_DIR/admission-publishing"
  for ((i = 0; i < 500; i++)); do
    [ ! -e "$FM_FAKE_DIR/admission-release" ] || break
    /bin/sleep 0.01
  done
fi
exec /bin/mv "$@"
SH
  chmod +x "$dir/fakebin/mv"
  ( run_restart "$dir" sm1 sm2 > "$dir/first.out"; printf '%s\n' "$?" > "$dir/first.rc" ) &
  first=$!
  i=0
  while [ ! -e "$dir/fake/admission-publishing" ] && [ "$i" -lt 500 ]; do /bin/sleep 0.01; i=$((i + 1)); done
  [ -e "$dir/fake/admission-publishing" ] || { kill "$first" 2>/dev/null; fail "the first admission never reached publication"; }
  ( run_restart "$dir" sm2 sm1 > "$dir/second.out"; printf '%s\n' "$?" > "$dir/second.rc" ) &
  second=$!
  i=0
  while ! grep -q 'waiting to record its restart request' "$dir/second.out" 2>/dev/null && [ "$i" -lt 500 ]; do /bin/sleep 0.01; i=$((i + 1)); done
  assert_contains "$(cat "$dir/second.out")" "waiting to record its restart request" "the second admission did not wait for the first"
  count=$(find "$state/pending-replies" -maxdepth 1 -type f | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "concurrent admission created $count correlations"
  count=$(find "$state/sm1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "concurrent admission delivered $count persist requests"
  : > "$dir/fake/admission-release"
  i=0
  while { kill -0 "$first" 2>/dev/null || kill -0 "$second" 2>/dev/null; } && [ "$i" -lt 500 ]; do /bin/sleep 0.01; i=$((i+1)); done
  if kill -0 "$first" 2>/dev/null || kill -0 "$second" 2>/dev/null; then
    kill "$first" "$second" 2>/dev/null || true
    fail "overlapping fleet admissions deadlocked on reversed mate order"
  fi
  wait "$first" || fail "the first admission driver failed"
  wait "$second" || fail "the second admission driver failed"
  expect_code 0 "$(cat "$dir/first.rc")" "the first request was not retained"
  expect_code 0 "$(cat "$dir/second.rc")" "the second request intent was lost"
  out="$(cat "$dir/first.out")
$(cat "$dir/second.out")"
  assert_contains "$out" "queued: sm1" "concurrent admission did not retain the restart"
  assert_not_contains "$out" "nudged: sm1" "concurrent admission fell back to a nudge"
  count=$(find "$state/pending-replies" -maxdepth 1 -type f | wc -l | tr -d ' ')
  [ "$count" = 2 ] || fail "overlapping fleet admissions did not preserve one correlation per mate"
  count=$(find "$state/sm1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "the second admission resent the persist request"
  assert_present "$state/.secondmate-restart-sm1.request" "concurrent admission lost the request"
  assert_present "$state/.secondmate-restart-sm2.request" "concurrent fleet admission lost the sibling request"
  pass "overlapping fleet admissions serialize each mate without reversed-order deadlock"
}

test_watcher_propagates_failed_request_worker() {
  local dir out rc
  dir=$(new_case failed-request-worker)
  add_local_mate "$dir" sm1
  out=$(run_restart "$dir" sm1) || fail "could not queue request: $out"
  out=$(FM_HOME="$dir/home" bash -c '
    . "$1/bin/fm-watch.sh"
    SECONDMATE_LIVENESS_SECS=0
    ( exit 3 ) &
    SECONDMATE_RESTART_PID=$!
    for ((i = 0; i < 100; i++)); do
      kill -0 "$SECONDMATE_RESTART_PID" 2>/dev/null || break
      /bin/sleep 0.01
    done
    secondmate_restart_tick
  ' _ "$ROOT" 2>&1); rc=$?
  expect_code 1 "$rc" "the watcher suppressed the failed request worker: $out"
  assert_contains "$out" "recorded secondmate restart processing failed" "the watcher did not report the failed worker"
  assert_present "$dir/home/state/.secondmate-restart-sm1.request" "the watcher discarded the failed worker's request"
  assert_no_line '/exit' "$dir/fake/literal" "the failed worker triggered an unconfirmed restart"
  pass "the watcher propagates a failed request-processing worker"
}

test_cli_owns_completion_from_admission_through_service() {
  local dir state out kind
  for kind in existing-outcome existing-request new-request; do
    dir=$(new_case "handoff-$kind")
    add_local_mate "$dir" sm1
    state="$dir/home/state"
    if [ "$kind" != new-request ]; then
      out=$(run_restart "$dir" sm1) || fail "could not queue request: $out"
      answer_now "$dir" sm1
      if [ "$kind" = existing-outcome ]; then
        out=$(process_requests "$dir") || fail "could not complete request: $out"
      fi
    else
      arm_answer "$dir" sm1
    fi
    cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
handoff=0
for arg in "$@"; do
  [ "$arg" != "$FM_HOME/state/.secondmate-liveness-sm1.lock" ] || handoff=1
done
/bin/rm "$@" || exit $?
if [ "$handoff" = 1 ] && [ ! -e "$FM_FAKE_DIR/handoff-seen" ]; then
  : > "$FM_FAKE_DIR/handoff-seen"
  bash -c '
    . "$FM_TEST_ROOT/bin/fm-watch.sh"
    wake() { :; }
    touch "$STATE/.secondmate-restart-tick"
    fm_secondmate_restart_service "$STATE" sm1 >/dev/null
    secondmate_restart_tick
  ' > "$FM_FAKE_DIR/handoff.out" 2>&1
fi
SH
    chmod +x "$dir/fakebin/rm"
    out=$(FM_TEST_ROOT="$ROOT" run_restart "$dir" sm1) || fail "$kind lost completion ownership: $out"
    assert_contains "$out" "restarted: sm1" "$kind did not report the completed restart"
    assert_not_contains "$out" "unreached:" "$kind falsely reported a failed restart"
    assert_present "$dir/fake/handoff-seen" "$kind did not exercise a competing consumer"
    assert_absent "$state/.secondmate-restart-sm1.request" "$kind left the request behind"
    assert_absent "$state/.secondmate-restart-sm1.outcome" "$kind left the outcome behind"
    [ "$(grep -cx '/exit' "$dir/fake/literal")" = 1 ] || fail "$kind repeated the restart"
    [ ! -s "$state/.wake-queue" ] || fail "$kind was reported by both CLI and watcher"
  done
  pass "CLI admission retains completion ownership across competing watcher servicing"
}

test_completion_notification_replays_one_identity_under_queue_lock() {
  local dir state out corr count holder ack i generation sequence second_corr
  dir=$(new_case notification-replay)
  add_local_mate "$dir" sm1
  state="$dir/home/state"
  out=$(run_restart "$dir" sm1) || fail "could not queue request: $out"
  corr=$(sed -n 's/^corr=//p' "$state/.secondmate-restart-sm1.request")
  answer_now "$dir" sm1
  out=$(process_requests "$dir") || fail "could not complete request: $out"
  cat > "$dir/fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ] && [ -f "$FM_FAKE_DIR/tick-time" ]; then
  cat "$FM_FAKE_DIR/tick-time"
else
  exec /bin/date "$@"
fi
SH
  cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "$FM_HOME/state/.secondmate-restart-sm1.outcome" ]; then
    [ -L "$FM_HOME/state/.wake-queue.lock" ] || {
      : > "$FM_FAKE_DIR/unlocked-handoff"
      exit 1
    }
    if [ -e "$FM_FAKE_DIR/refuse-consumption" ]; then exit 1; fi
    if [ -e "$FM_FAKE_DIR/pause-consumption" ]; then
      : > "$FM_FAKE_DIR/consumption-paused"
      for ((i = 0; i < 500; i++)); do
        [ ! -e "$FM_FAKE_DIR/pause-consumption" ] || { /bin/sleep 0.01; continue; }
        break
      done
    fi
  fi
done
exec /bin/rm "$@"
SH
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_ACK:-0}" = 1 ] && [ "${1:-}" = 0.1 ]; then
  : > "$FM_FAKE_DIR/ack-blocked"
fi
exec /bin/sleep 0.01
SH
  chmod +x "$dir/fakebin/date" "$dir/fakebin/rm" "$dir/fakebin/sleep"
  printf '%s\n' "$(date +%s)" > "$dir/fake/tick-time"
  : > "$dir/fake/refuse-consumption"
  out=$(run_restart_watcher_tick "$dir")
  expect_code 1 "$?" "failed outcome consumption was suppressed: $out"
  assert_contains "$out" "could not be consumed" "the handoff did not reach outcome consumption"
  assert_absent "$dir/fake/unlocked-handoff" "outcome retirement did not hold the queue lock"
  assert_present "$state/.secondmate-restart-sm1.outcome" "failed handoff lost its completion marker"
  count=$(awk -F '\t' -v key="secondmate-restart-sm1-$corr" '$4 == key { n++ } END { print n+0 }' "$state/.wake-queue")
  [ "$count" = 1 ] || fail "the first handoff did not publish exactly one completion identity"
  generation=$(cat "$state/.watcher-down")
  generation=${generation##*:}
  sequence=$(awk -F '\t' 'END { print $2 }' "$state/.wake-queue")
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" activate "$$" restart-handoff || fail "could not activate branch"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" publish restart-handoff "$sequence" || fail "could not grant completion row"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_SUPERVISION_ACTOR=branch FM_FAKE_DIR="$dir/fake" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" 2>&1)
  expect_code 1 "$?" "branch acknowledgement consumed an interrupted handoff: $out"
  assert_contains "$out" "handoff is not retired" "branch acknowledgement bypassed the shared handoff invariant"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-grant.sh" deactivate "$$" restart-handoff || fail "could not release branch"
  out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_FAKE_DIR="$dir/fake" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation" 2>&1)
  expect_code 1 "$?" "acknowledgement consumed an interrupted handoff: $out"
  assert_contains "$out" "handoff is not retired" "acknowledgement did not explain the pending handoff"
  [ -s "$state/.wake-queue" ] || fail "acknowledgement removed the replay deduplication row"
  rm -f "$dir/fake/refuse-consumption"
  printf '%s\n' "$(( $(cat "$dir/fake/tick-time") + 10 ))" > "$dir/fake/tick-time"
  : > "$dir/fake/pause-consumption"
  run_restart_watcher_tick "$dir" > "$dir/tick.out" &
  holder=$!
  i=0
  while [ ! -e "$dir/fake/consumption-paused" ] && [ "$i" -lt 500 ]; do /bin/sleep 0.01; i=$((i+1)); done
  assert_present "$dir/fake/consumption-paused" "replayed handoff never reached retirement"
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" \
    FM_FAKE_DIR="$dir/fake" FM_FAKE_ACK=1 \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" \
    > "$dir/ack.out" 2>&1 &
  ack=$!
  i=0
  while [ ! -e "$dir/fake/ack-blocked" ] && [ "$i" -lt 500 ]; do /bin/sleep 0.01; i=$((i+1)); done
  assert_present "$dir/fake/ack-blocked" "acknowledgement did not wait for completion retirement"
  count=$(awk -F '\t' '$3 == "check" { n++ } END { print n+0 }' "$state/.wake-queue")
  [ "$count" = 1 ] || fail "the replay queued a duplicate at a different tick time"
  rm -f "$dir/fake/pause-consumption"
  wait "$holder" || fail "replayed handoff failed: $(cat "$dir/tick.out")"
  wait "$ack" || fail "acknowledgement failed: $(cat "$dir/ack.out")"
  assert_absent "$state/.secondmate-restart-sm1.outcome" "successful handoff left its outcome"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement left the completion queued"
  out=$(run_restart_watcher_tick "$dir") || fail "post-ack tick failed: $out"
  [ ! -s "$state/.wake-queue" ] || fail "post-ack tick repeated the completion"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" sm1 --state busy --source claude-hook --event prompt >/dev/null || fail "could not arm replacement turn"
  out=$(run_restart "$dir" sm1) || fail "could not queue a subsequent restart: $out"
  second_corr=$(sed -n 's/^corr=//p' "$state/.secondmate-restart-sm1.request")
  [ "$corr" != "$second_corr" ] || fail "subsequent restart reused the first completion identity"
  answer_now "$dir" sm1
  "$ROOT/bin/fm-busy-event.sh" apply "$state" sm1 idle --current-gen --source claude-hook --event stop >/dev/null || fail "could not close replacement turn"
  out=$(process_requests "$dir") || fail "subsequent restart failed: $out"
  out=$(run_restart_watcher_tick "$dir") || fail "subsequent completion handoff failed: $out"
  count=$(awk -F '\t' -v key="secondmate-restart-sm1-$second_corr" '$4 == key { n++ } END { print n+0 }' "$state/.wake-queue")
  [ "$count" = 1 ] || fail "a fixed per-mate notification key suppressed the subsequent completion"
  pass "completion replay uses stable per-outcome identity and excludes acknowledgement during retirement"
}

test_cancellation_reaps_lifecycle_tree_before_unlocking() {
  local dir state mode signal mates id pid rc attempt process_state descendant monitor_was_on=0
  local -a args=()
  case $- in *m*) monitor_was_on=1 ;; esac
  for mode in new recorded process fleet; do
    for signal in INT TERM; do
      dir=$(new_case "cancel-$mode-$signal")
      add_local_mate "$dir" sm1
      state="$dir/home/state"
      mates="sm1"
      if [ "$mode" = fleet ]; then
        add_local_mate "$dir" sm2
        mates="sm1 sm2"
      fi
      if [ "$mode" != new ]; then
        run_restart "$dir" $mates > "$dir/queued.out" || fail "could not queue cancellation fixture"
        for id in $mates; do answer_now "$dir" "$id"; done
      else
        arm_answer "$dir" sm1
      fi
      cat > "$dir/fake/on-exit" <<'SH'
#!/usr/bin/env bash
set -u
id=${1##*fm-}
trap '' INT TERM
printf '%s\n' "$$" > "$FM_FAKE_DIR/lifecycle-pid.$id"
printf 'zsh' > "$FM_FAKE_DIR/command.$1"
set -m
bash -c '
  trap "" INT TERM
  printf "%s\n" "$$" > "$FM_FAKE_DIR/descendant-pid.$1"
  while [ ! -e "$FM_FAKE_DIR/release.$1" ]; do /bin/sleep 0.01; done
  : > "$FM_FAKE_DIR/escaped.$1"
' _ "$id" &
wait "$!"
SH
      chmod +x "$dir/fake/on-exit"
      cat > "$dir/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    "$FM_HOME/state"/.secondmate-liveness-*.lock)
      for record in "$FM_FAKE_DIR"/lifecycle-pid.* "$FM_FAKE_DIR"/descendant-pid.*; do
        [ -f "$record" ] || continue
        state=$(ps -p "$(cat "$record")" -o stat= 2>/dev/null || true)
        case "$state" in ''|Z*) ;; *) : > "$FM_FAKE_DIR/unsafe-unlock" ;; esac
      done
      ;;
  esac
done
exec /bin/rm "$@"
SH
      chmod +x "$dir/fakebin/rm"
      args=($mates)
      [ "$mode" != process ] || args=(--process-requests)
      set -m
      env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
        FM_ROOT_OVERRIDE="$dir/code" FM_CONFIG_OVERRIDE="$dir/home/config" \
        FM_SPAWN_NO_GUARD=1 FM_SECONDMATE_PERSIST_POLL=1 \
        FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
        "$RESTART" "${args[@]}" \
        > "$dir/restart.out" 2>&1 &
      pid=$!
      [ "$monitor_was_on" -eq 1 ] || set +m
      for id in $mates; do
        attempt=0
        while [ ! -s "$dir/fake/descendant-pid.$id" ] && [ "$attempt" -lt 500 ]; do
          /bin/sleep 0.01
          attempt=$((attempt + 1))
        done
        [ -s "$dir/fake/descendant-pid.$id" ] || {
          kill -TERM "$pid" 2>/dev/null || true
          wait "$pid" 2>/dev/null || true
          fail "$mode $signal never reached the in-flight lifecycle: $(cat "$dir/restart.out")"
        }
        env FM_HOME="$dir/home" STATE="$state" bash -c '
          . "$1/bin/fm-secondmate-liveness-lib.sh"
          if fm_secondmate_liveness_lock "$2"; then
            fm_secondmate_liveness_unlock "$2"
            exit 1
          fi
        ' _ "$ROOT" "$id" || fail "automatic relaunch could acquire an in-flight restart lock"
      done
      kill "-$signal" "$pid" || fail "could not cancel restart with $signal"
      attempt=0
      while kill -0 "$pid" 2>/dev/null && [ "$attempt" -lt 500 ]; do
        /bin/sleep 0.01
        attempt=$((attempt + 1))
      done
      if kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        fail "$mode restart did not exit after $signal"
      fi
      wait "$pid"; rc=$?
      case "$signal" in
        INT) expect_code 130 "$rc" "SIGINT did not report cancellation" ;;
        TERM) expect_code 143 "$rc" "SIGTERM did not report cancellation" ;;
      esac
      assert_absent "$dir/fake/unsafe-unlock" "cancellation unlocked while lifecycle descendants were still alive"
      for id in $mates; do
        for descendant in "$dir/fake/lifecycle-pid.$id" "$dir/fake/descendant-pid.$id"; do
          descendant=$(cat "$descendant")
          process_state=$(ps -p "$descendant" -o stat= 2>/dev/null || true)
          case "$process_state" in
            ''|Z*) ;;
            *) kill -KILL "$descendant" 2>/dev/null || true; fail "$mode $signal left lifecycle descendant $descendant alive" ;;
          esac
        done
        : > "$dir/fake/release.$id"
        assert_absent "$dir/fake/escaped.$id" "a cancelled descendant resumed lifecycle work"
        assert_absent "$state/.secondmate-liveness-$id.lock" "cancellation left the lifecycle lock held"
        env FM_HOME="$dir/home" STATE="$state" bash -c '
          . "$1/bin/fm-secondmate-liveness-lib.sh"
          fm_secondmate_liveness_lock "$2" || exit 1
          fm_secondmate_liveness_unlock "$2"
        ' _ "$ROOT" "$id" || fail "automatic relaunch could not acquire the lock after cancellation"
      done
    done
  done
  pass "SIGINT and SIGTERM reap fresh, recorded, supervised, and fleet restart descendants before unlock"
}

test_persist_gates_and_asks_only_for_open_records
test_persist_precedes_restart
test_arrived_answer_precedes_deadline_check
test_answer_between_resolution_and_timeout_wins
test_unprovable_runtime_falls_back
test_unknown_mate_is_accounted_for
test_refused_restart_falls_back_without_claiming_a_reload
test_local_restart_uses_the_home_pin_and_reports_what_ran
test_native_ultra_restart_keeps_local_profile
test_unreachable_host_is_reported_unknown
test_concurrent_reply_cannot_release_persist_gate
test_persist_waits_are_polled_together
test_post_stop_failure_is_reported_unreached
test_relaunches_do_not_block_persist_polling
test_unpublished_worker_result_is_accounted_for
test_result_published_while_reaping_is_honored
test_already_current_mate_restarts_end_to_end
test_already_current_unprovable_mate_stays_on_the_nudge_path
test_teamclaude_restart_reaches_claude_through_the_proxy

test_answered_mate_mid_turn_waits_for_turn_end
test_new_turn_during_checkpoint_keeps_restart_queued
test_restart_and_auto_relaunch_share_one_lock
test_second_pass_reuses_the_recorded_request
test_inconclusive_turn_evidence_stays_queued
test_unwired_launches_are_nudged_without_queueing
test_unverified_adapters_are_nudged_without_queueing
test_remote_mates_are_nudged_without_queueing
test_updater_routes_unwired_mates_to_nudges
test_completed_outcome_is_replayed_without_relaunch
test_outcome_consumers_hold_lock_and_preserve_failed_retirement
test_completion_publication_failures_are_visible
test_concurrent_admission_creates_one_request
test_watcher_propagates_failed_request_worker
test_cli_owns_completion_from_admission_through_service
test_completion_notification_replays_one_identity_under_queue_lock
test_cancellation_reaps_lifecycle_tree_before_unlocking
echo "# all fm-secondmate-restart tests passed"
