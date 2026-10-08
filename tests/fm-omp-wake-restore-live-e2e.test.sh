#!/usr/bin/env bash
# tests/fm-omp-wake-restore-live-e2e.test.sh - the live omp injected-text guard
# (live-harness-optin family; task fm-omp-lane-wake-unsubmitted).
#
# Firstmate-injected text sat unsubmitted in an omp lane's box composer.
# These vendor behaviors are modeled by portable suites; the guard drives the
# INSTALLED omp in an isolated Herdr lab:
#   1. omp puts a queued user follow-up back into the composer when the run is
#      interrupted (Esc, as bin/fm-control.sh interrupt sends). A watcher wake
#      queued behind a running turn then sat in the composer, consumed by no
#      turn. The omp watch extension must submit it again on its own and leave
#      an operator draft exactly as typed.
#   2. While a turn runs, omp's box top border carries a spinner and the elapsed
#      time instead of its identity glyph. The shared classifier read that screen
#      as `unknown`, so a doorbell typed into a working lane (fm-send, the
#      restart persistence request) could never be seen as unsubmitted. A busy
#      composer must read empty or pending through the production Herdr adapter,
#      and the adapter's own submit must land the line.
#   3. A descendant omp (an `omp -p` child a turn runs) loads the same extensions
#      from the same directory. It used to overwrite state/.omp-turnend-extension-
#      loaded with its own, soon dead, pid; both markers must keep naming the
#      session that holds the lock.
# Every step submits model prompts, so the guard is opt-in; it fails naming omp
# and `omp --version`. Refresh docs/verification/runtime-backends.md
# ("omp injected text") from its output after any omp upgrade.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u
unset FM_HOME FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
unset FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_OMP_WAKE_RESTORE_LIVE herdr jq omp

[ -x "$LAB_HELPER" ] || fail "FM_OMP_WAKE_RESTORE_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name omp-wake-restore)
LAB=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-omp-wake-restore.XXXXXX")
PROJECT="$LAB/project"
FAKEBIN="$LAB/fakebin"
PARENT="$LAB/parent"
REAL_OMP=$(PATH="$ORIGINAL_PATH" command -v omp)
MODEL=${FM_OMP_WAKE_RESTORE_LIVE_MODEL:-openai-codex/gpt-6-astra}
mkdir -p "$FAKEBIN"

# Every process the lab started (omp, its session-start supervisor, the watcher
# and its arm child) names the lab path on its command line.
reap_lab() {
  local pid
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" -v me="$$" 'index($0, lab) && $1 != me { print $1 }'); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  sleep 1
  for pid in $(ps -axo pid=,command= | awk -v lab="$LAB" -v me="$$" 'index($0, lab) && $1 != me { print $1 }'); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

cleanup() {
  local rc=$?
  trap - EXIT
  reap_lab
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
elif [ "\$n" -ne 2 ] || [ "\${args[0]}" != status ] || [ "\${args[1]}" != --json ]; then
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# The adapter does not provide the metadata dispatcher used by start_omp.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"
set +e

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
VERSION=$(env PATH="$ORIGINAL_PATH" FM_HOME="$PROJECT" FM_ROOT_OVERRIDE="$PROJECT" FM_STATE_OVERRIDE="$PROJECT/state" FM_CONFIG_OVERRIDE="$PROJECT/config" FM_DATA_OVERRIDE="$PROJECT/data" omp --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
SUBJECT="omp ($VERSION) on $HERDR_VER"

# The tracked tree plus this working tree's pending edits, so the guard exercises
# the extensions and scripts under review rather than the last commit.
git clone -q "$ROOT" "$PROJECT" || fail "could not clone the repository into the lab"
while IFS= read -r path; do
  [ -n "$path" ] && [ -f "$ROOT/$path" ] || continue
  mkdir -p "$PROJECT/$(dirname "$path")"
  cp "$ROOT/$path" "$PROJECT/$path"
done <<EOF
$(git -C "$ROOT" ls-files --modified --others --exclude-standard)
EOF
mkdir -p "$PROJECT/state" "$PROJECT/config" "$PROJECT/data"

# The session overlay with the composer shape every lane that lost its pin shows.
BOX_OVERLAY="$LAB/box-overlay.yml"
sed 's/^  shape: borderless$/  shape: box/' "$ROOT/.omp/fm-session-overlay.yml" > "$BOX_OVERLAY"
cp "$BOX_OVERLAY" "$PROJECT/.omp/fm-session-overlay.yml"
mkdir -p "$PARENT/state" "$PARENT/config" "$PARENT/data" "$PARENT/projects"
printf 'Live wake recovery lab: arm watcher when asked, perform only requested checks, and otherwise stay idle.\n' > "$PROJECT/data/charter.md"

PANE=
TARGET=
WAKE_PROBE=0
WAKE_TASK=

screen() { lab pane read "$PANE" --source visible 2>/dev/null || true; }
send_text() { fm_backend_herdr_send_literal "$TARGET" "$1" >/dev/null; }
send_key() { fm_backend_herdr_send_key "$TARGET" "$1" >/dev/null || fail "$SUBJECT: could not send $1"; }
composer() { fm_backend_herdr_composer_state "$TARGET"; }
queue_rows() { grep -c . "$PROJECT/state/.wake-queue" 2>/dev/null || true; }

wait_for() {  # <seconds> <command...>
  local limit=$1 i=0
  shift
  while [ "$i" -lt "$limit" ]; do
    "$@" && return 0
    sleep 1
    i=$((i + 1))
  done
  return 1
}

live_busy_class() {
  [ "$1" = "$TARGET" ] || { printf unknown; return; }
  [ "$(fm_backend_herdr_agent_state "$TARGET")" = alive ] || { printf unknown; return; }
  # A box spinner is not a standalone rendered busy footer; use Herdr's
  # process-validated native state so a running sleep remains positively busy.
  fm_backend_herdr_busy_state "$TARGET"
}
is_idle() { [ "$(live_busy_class "$TARGET")" = idle ]; }
is_busy() { [ "$(live_busy_class "$TARGET")" = busy ]; }
queue_drained() { [ "$(queue_rows)" -eq 0 ]; }
composer_is() { [ "$(composer)" = "$1" ]; }

busy_composer_is() {
  is_busy || fail "$SUBJECT: the lane was not busy before the $1 composer probe"
  composer_is "$1" || return 1
  is_busy || fail "$SUBJECT: the lane was not busy after the $1 composer probe"
}

# start_omp <label>
start_omp() {
  local label=$1
  rm -f "$PROJECT/state/.wake-queue" "$PROJECT/state/.watch-cycle-exits.log" "$PROJECT/state"/wakelab*.status "$PROJECT/state"/wakelab*.meta "$PARENT/state/wakemate.meta"
  printf 'wakemate\n' > "$PROJECT/.fm-secondmate-home"
  printf '#!/usr/bin/env bash\nexec env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 %q "$@"\n' "$REAL_OMP" > "$FAKEBIN/omp"
  chmod +x "$FAKEBIN/omp"
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_SYNC=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$PROJECT" FM_STATE_OVERRIDE="$PARENT/state" \
    FM_CONFIG_OVERRIDE="$PARENT/config" FM_DATA_OVERRIDE="$PARENT/data" \
    HERDR_SESSION="$SESSION" "$PROJECT/bin/fm-spawn.sh" wakemate "$PROJECT" omp --secondmate \
    --backend herdr --model "$MODEL" --effort low > "$LAB/spawn-$label.out" 2>&1 \
    || fail "could not launch the ordinary omp secondmate for $label: $(cat "$LAB/spawn-$label.out")"
  TARGET=$(fm_backend_target_of_meta "$PARENT/state/wakemate.meta")
  PANE=${TARGET#*:}
  wait_for 120 is_idle || { screen >&2; fail "$SUBJECT never published settled task evidence for $label"; }
  sleep 2
  send_text 'Call the fm_watch_arm_omp tool exactly once now, then reply with only the word ARMED.'
  sleep 1
  send_key Enter
  wait_for 120 test -f "$PROJECT/state/.watch.lock/pid" || { screen >&2; fail "$SUBJECT never armed the watcher for $label"; }
  wait_for 120 is_idle || fail "$SUBJECT did not return to idle after arming for $label"
}

# busy_turn: start a long tool call so the lane is mid-turn.
busy_turn() {
  wait_for 120 is_idle || fail "the lane was not idle before a busy turn"
  # shellcheck disable=SC2016 # The backticks are literal prompt text for the model.
  send_text 'Run the bash command `sleep 90` and when it finishes reply DONE.'
  sleep 1
  send_key Enter
  wait_for 60 is_busy || { screen >&2; fail "the lane never showed a running turn"; }
  sleep 5
  is_busy || fail "$SUBJECT: the lane stopped running before the busy turn was ready"
}

# queue_wake: write a status line so the watcher wakes main while the turn runs,
# and wait until omp has queued the wake behind it.
queue_wake() {
  rm -f "$PROJECT/state/.watch-cycle-exits.log" "$PROJECT/state"/wakelab*.status "$PROJECT/state"/wakelab*.meta
  WAKE_PROBE=$((WAKE_PROBE + 1))
  WAKE_TASK="wakelab$WAKE_PROBE"
  : > "$PROJECT/state/$WAKE_TASK.meta"
  printf 'done: wake lab signal %s\n' "$WAKE_TASK" > "$PROJECT/state/$WAKE_TASK.status"
  wait_for 60 wake_is_queued \
    || { screen >&2; fail "$SUBJECT: $WAKE_TASK was not submitted into the running turn's follow-up queue (queue rows: $(queue_rows))"; }
}

wake_is_queued() {
  local capture queued
  is_busy || return 1
  awk -F '\t' -v key="$WAKE_TASK.status" \
    '$3 == "signal" && $4 == key { found = 1 } END { exit !found }' \
    "$PROJECT/state/.wake-queue" 2>/dev/null || return 1
  capture=$(screen)
  queued=$(printf '%s\n' "$capture" | awk '
    /After yield.*[1-9][0-9]*/ { in_queue = 1; next }
    in_queue && /to edit/ { printf "%s", rows; exit }
    in_queue { rows = rows $0 }
  ' | tr -d '[:space:]')
  case "$queued" in
    *"FIRSTMATEWATCHERWAKE:"*"$WAKE_TASK.status"*) ;;
    *) return 1 ;;
  esac
  is_busy && \
    awk -F '\t' -v key="$WAKE_TASK.status" \
      '$3 == "signal" && $4 == key { found = 1 } END { exit !found }' \
      "$PROJECT/state/.wake-queue" 2>/dev/null
}

wake_is_restored() {
  local content
  composer_is pending || return 1
  content=$(fm_backend_herdr_composer_content "$TARGET" '') || return 1
  content=$(printf '%s' "$content" | tr -d '[:space:]')
  case "$content" in
    *"FIRSTMATEWATCHERWAKE:"*"$WAKE_TASK.status"*) return 0 ;;
    *) return 1 ;;
  esac
}

interrupt_queued_wake() {
  local draft=${1:-} attempt poll content
  for attempt in 1 2 3; do
    busy_turn
    if [ -n "$draft" ]; then
      send_text "$draft"
      sleep 1
    fi
    queue_wake
    send_key Escape
    for ((poll = 0; poll < 50; poll++)); do
      wake_is_restored && return 0
      sleep 0.1
    done
    [ "$attempt" -lt 3 ] || break
    wait_for 90 queue_drained \
      || { screen >&2; fail "$SUBJECT: unobserved $WAKE_TASK did not drain before a fresh restoration attempt"; }
    wait_for 120 is_idle || fail "$SUBJECT: the lane did not settle before a fresh restoration attempt"
    content=$(fm_backend_herdr_composer_content "$TARGET" '') \
      || fail "$SUBJECT: could not read the composer before a fresh restoration attempt"
    [ "$content" = "$draft" ] \
      || fail "$SUBJECT: unexpected composer text before a fresh restoration attempt: '$content'"
    if [ -n "$draft" ]; then
      send_key C-u
    fi
    wait_for 20 composer_is empty || fail "$SUBJECT: the composer was not empty before a fresh restoration attempt"
  done
  screen >&2
  fail "$SUBJECT: no fresh wake was observed restored into a pending composer after Escape in 3 attempts"
}

# ---------------------------------------------------------------------------
# Session A: the extension recovers a restored wake by itself.
# ---------------------------------------------------------------------------
start_omp wake-ext

interrupt_queued_wake
wait_for 90 queue_drained \
  || { screen >&2; fail "$SUBJECT: a wake restored to the composer by Esc was never submitted again (queue rows: $(queue_rows))"; }
wait_for 60 composer_is empty \
  || fail "$SUBJECT: the composer still holds text after the wake was submitted again: $(composer)"
pass "live omp wake restore: $SUBJECT re-submitted a wake that Esc restored to the composer, and the lane handled it"

# An operator draft typed while the wake was queued survives the recovery.
wait_for 120 is_idle || fail "the lane did not settle after handling the wake"
interrupt_queued_wake 'operator draft kept'
wait_for 90 queue_drained \
  || { screen >&2; fail "$SUBJECT: the wake restored next to an operator draft was never submitted again"; }
draft=$(fm_backend_herdr_composer_content "$TARGET" '')
[ "$draft" = 'operator draft kept' ] \
  || fail "$SUBJECT: the operator draft was changed by the recovery, composer now holds: '$draft'"
pass "live omp wake restore: $SUBJECT left the operator's draft exactly as typed while it re-submitted the wake"
send_key C-u
wait_for 20 composer_is empty || fail "$SUBJECT: could not clear the draft"

# The descendant omp child must not take over the markers.
wait_for 120 is_idle || fail "the lane did not settle before the child probe"
rm -f "$LAB/child-omp.ok" "$LAB/child-omp.out"
send_text "Run this exact bash command and then reply CHILD_DONE: env FM_HOME='$PROJECT' FM_ROOT_OVERRIDE='$PROJECT' FM_STATE_OVERRIDE='$PROJECT/state' FM_CONFIG_OVERRIDE='$PROJECT/config' FM_DATA_OVERRIDE='$PROJECT/data' omp --print 'reply with the word hi' --no-session --thinking low --model $MODEL > '$LAB/child-omp.out' 2>&1 && read -r lock_pid < '$PROJECT/state/.lock' && [ \"\$(sed -n 2p '$PROJECT/state/.omp-turnend-extension-loaded')\" = \"\$lock_pid\" ] && [ \"\$(sed -n 2p '$PROJECT/state/.omp-watch-extension-loaded')\" = \"\$lock_pid\" ] && printf 'child-omp-pre-parent-repair-owner-ok\n' > '$LAB/child-omp.ok'"
sleep 1
send_key Enter
wait_for 60 is_busy || fail "the lane never showed a running turn for the child probe"
wait_for 180 is_idle || fail "the lane did not settle after the child probe"
[ "$(cat "$LAB/child-omp.ok" 2>/dev/null)" = child-omp-pre-parent-repair-owner-ok ] \
  || { cat "$LAB/child-omp.out" >&2 2>/dev/null; fail "$SUBJECT: the descendant omp did not prove both loaded marker PIDs matched the session lock PID before parent repair"; }
lock_pid=$(sed -n 1p "$PROJECT/state/.lock")
for marker in .omp-turnend-extension-loaded .omp-watch-extension-loaded; do
  [ "$(sed -n 2p "$PROJECT/state/$marker")" = "$lock_pid" ] \
    || fail "$SUBJECT: a descendant omp left $marker naming '$(sed -n 2p "$PROJECT/state/$marker")' instead of the session pid $lock_pid"
done
pass "live omp markers: $SUBJECT kept both loaded markers on the session pid $lock_pid before parent repair and after the parent resumed"

# ---------------------------------------------------------------------------
# A working lane's composer is readable, so injected text is detected and lands.
# ---------------------------------------------------------------------------
wait_for 120 is_idle || fail "the lane did not settle before the busy composer checks"
busy_turn
busy_composer_is empty || fail "$SUBJECT: a working lane's empty box composer read '$(composer)', not empty"
send_text 'unsent line typed while busy'
sleep 1
busy_composer_is pending || { screen >&2; fail "$SUBJECT: a line typed into a working lane's composer read '$(composer)', not pending"; }
send_key C-u
wait_for 20 busy_composer_is empty || fail "$SUBJECT: could not clear the busy draft"
pass "live omp busy composer: $SUBJECT reads empty and pending while a turn runs"

doorbell=": Firstmate operational input waiting: read '$LAB/none.msg' and handle its contents as Firstmate operational input."
is_busy || fail "$SUBJECT: the lane was not busy immediately before the adapter submission"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$doorbell" 3 0.4 0.3)
case "$verdict" in
  empty|unknown) ;;
  *) fail "$SUBJECT: the adapter's submit into a working lane reported '$verdict'" ;;
esac
wait_for 20 busy_composer_is empty \
  || { screen >&2; fail "$SUBJECT: an injected doorbell stayed in a working lane's composer (read '$(composer)')"; }
pass "live omp busy composer: $SUBJECT took an injected doorbell mid-turn and left the composer empty"
