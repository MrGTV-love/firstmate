#!/usr/bin/env bash
# Drives the real bin/fm-control.sh adopt/interrupt with real ps, lsof, and
# python env reading against real OS processes. Only the Herdr server is a stub.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5R0YCVPWMW73Z7K2X2R8HM3
. "$WT/tests/fm-control-relaunch-helpers.sh"
set +e
OUT=$1   # transcript file
exec 3>>"$OUT"
log() { printf '%s\n' "$*" >&3; }
REAL_PIDS=()
start_real() { # <argv0> <cwd> [ENV=VAL...] -> REAL_PID
  local name=$1 cwd=$2; shift 2
  ( cd "$cwd" && exec env -i PATH=/usr/bin:/bin HOME="$SCRHOME" "$@" /bin/bash -c "exec -a $name /opt/homebrew/bin/node -e 'setTimeout(()=>{},900000)'" ) &
  REAL_PID=$!
  REAL_PIDS+=("$REAL_PID")
  local t=0
  until [ "$(ps -p "$REAL_PID" -o args= 2>/dev/null | cut -d' ' -f1)" = "$name" ]; do
    t=$((t+1)); [ $t -le 100 ] || { log "could not start $name"; return 1; }; sleep 0.05
  done
}
cleanup_real() { for p in "${REAL_PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'cleanup_real; fm_test_cleanup' EXIT

# run fm-control directly (no command substitution) so the real ancestry walk
# finds this omp-named driver as the lock owner.
ctl() { # <case-dir> <args...>; sets RC and CTL_OUT
  local dir=$1; shift
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    -u FM_TASK_ID -u FM_SUPERVISION_ACTOR -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID -u PI_CODING_AGENT \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" HOME="$dir/user-home" \
    CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 \
    FM_CONTROL_SETTLE_WAIT=.05 ${EXTRA_ENV:-} "$CONTROL" "$@" > "$dir/ctl.out" 2>&1
  RC=$?
  CTL_OUT=$(cat "$dir/ctl.out")
  log "\$ FM_HOME=<lab> bin/fm-control.sh $*   ${EXTRA_ENV:+[$EXTRA_ENV]}"
  log "$CTL_OUT"
  log "(exit $RC)"
}

build_case() { # <name> -> CASE, ID; real omp-named agent in wt/subdirectory, unpinned
  recovery_case_or_skip "drive-$1" "drive-$1" || return 1
  CASE=$HERDR_CASE_DIR ID=$HERDR_CASE_ID
  local meta="$CASE/home/state/$ID.meta"
  sed -i '' 's/^harness=claude$/harness=omp/' "$meta"
  printf 'spawn_gen=old\nlaunch_proof=env-v1\n' >> "$meta"
  rm -f "$CASE/fake/herdr-stopped"
  printf '%s' "$ID" > "$CASE/fake/recovery-case-id"
  : > "$CASE/fake/herdr-agent-live"
  : > "$CASE/fake/recovery-spawn-gen"
  printf '%s' "$CASE/wt/recorded-session.jsonl" > "$CASE/fake/recovery-session-ref"
  mkdir -p "$CASE/wt/subdirectory" "$CASE/user-home"
  write_recovery_native_launch "$CASE" "$CASE/home" "$ID" ship
  # Real tools only: drop the fake ps, python3 env reader, and lsof.
  rm -f "$CASE/fakebin/ps" "$CASE/fakebin/python3" "$CASE/fakebin/lsof"
  # The stuck shape: a dead recorded pid and an empty current_session_file.
  jq -nc --arg task "$CASE/wt/recorded-session.jsonl" \
    '{version:1,spawn_gen:"old",pid:2000000001,task_session_file:$task,current_session_file:""}' \
    > "$CASE/home/state/$ID.omp-session.json"
  printf '%s\n' "$$" > "$CASE/home/state/.lock"
  SCRHOME="$CASE/user-home"
  start_real omp "$CASE/wt/subdirectory" || return 1
  printf '%s' "$REAL_PID" > "$CASE/fake/recovery-pid"
  log ""
  log "=== case $1: task $ID; real agent pid $REAL_PID ($(ps -p $REAL_PID -o args=)); real cwd $(lsof -a -p $REAL_PID -d cwd -Fn | sed -n 's/^n//p')"
}
record() { log "record: $(cat "$CASE/home/state/$ID.omp-session.json")"; }
sends() { grep -c 'send-' "$CASE/fake/herdr-log" 2>/dev/null || true; }
RESULT=()
verdict() { RESULT+=("$1: $2"); log ">>> $1: $2"; }
h() { shasum -a 256 "$CASE/home/state/$ID.omp-session.json" "$CASE/home/state/$ID.meta" | cut -c1-16 | tr '\n' ' '; }
refusal() { # <scenario> <expected-substring> <args...>
  local s=$1 want=$2 before after; shift 2
  before=$(h); local s0; s0=$(sends)
  ctl "$CASE" "$ID" "$@"
  after=$(h)
  if [ "$RC" -ne 0 ] && [[ "$CTL_OUT" == *"$want"* ]] && [ "$before" = "$after" ] && [ "$(sends)" = "$s0" ] && [[ "$CTL_OUT" != *adopted:* ]]; then
    verdict "$s" PASS
  else
    verdict "$s" "FAIL (rc=$RC unchanged=$([ "$before" = "$after" ] && echo y || echo n))"
  fi
}

# S1 happy path + interrupt before/after + rerun
build_case happy || exit 1
ctl "$CASE" "$ID" interrupt; pre_rc=$RC; pre_out=$CTL_OUT
s0=$(sends)
ctl "$CASE" "$ID" adopt; adopt_rc=$RC; adopt_out=$CTL_OUT
record
want=$(jq -nc --arg t "$CASE/wt/recorded-session.jsonl" --argjson p "$REAL_PID" '{version:1,spawn_gen:"old",pid:$p,task_session_file:$t,current_session_file:$t}')
got=$(jq -c . "$CASE/home/state/$ID.omp-session.json")
adopt_sends=$(( $(sends) - s0 ))
ctl "$CASE" "$ID" interrupt; post_rc=$RC; post_out=$CTL_OUT
log "herdr calls during the whole case:"; sed 's/^/  herdr /' "$CASE/fake/herdr-log" >&3
if [ $pre_rc -ne 0 ] && [ $adopt_rc -eq 0 ] && [[ "$adopt_out" == "adopted: $ID" ]] && [ "$got" = "$want" ] && [ $adopt_sends -eq 0 ] \
   && [ $post_rc -eq 0 ] && [[ "$post_out" == *"interrupt-delivered $ID"* ]]; then verdict S1-happy-adopt-then-interrupt PASS
else verdict S1-happy-adopt-then-interrupt "FAIL pre=$pre_rc adopt=$adopt_rc sends=$adopt_sends post=$post_rc"; fi
refusal S4-rerun-adopt-same-pid "the record already names $REAL_PID, so it was not changed" adopt
# S12 workspace ownership lost after adoption: lifecycle recheck refuses
printf 'worktree=%s\n' "$CASE/wt/subdirectory" > "$CASE/home/state/new-owner.meta"
refusal S12-recheck-after-workspace-lost "" interrupt
rm -f "$CASE/home/state/new-owner.meta"
# S11 caller gates
EXTRA_ENV="FM_TASK_ID=$ID" refusal S11a-worker-refused 'workers cannot adopt a session record' adopt
EXTRA_ENV="FM_SUPERVISION_ACTOR=branch" refusal S11b-branch-refused 'the supervision branch never performs this action' adopt

# S2 reused recorded pid by a real claude-named process, and by a non-agent
for shape in claude non-agent; do
  build_case "reused-$shape" || exit 1
  agent=$REAL_PID
  if [ $shape = claude ]; then start_real claude "$CASE" || exit 1; other=$REAL_PID; else start_real worker "$CASE" || exit 1; other=$REAL_PID; fi
  jq --argjson p "$other" '.pid=$p' "$CASE/home/state/$ID.omp-session.json" > "$CASE/r" && mv "$CASE/r" "$CASE/home/state/$ID.omp-session.json"
  log "recorded pid now $other ($(ps -p $other -o args= | cut -c1-40))"
  ctl "$CASE" "$ID" adopt; record
  if [ $RC -eq 0 ] && [ "$(jq .pid "$CASE/home/state/$ID.omp-session.json")" = "$agent" ]; then verdict "S2-reused-pid-$shape-does-not-block" PASS; else verdict "S2-reused-pid-$shape-does-not-block" FAIL; fi
done

# S3 recorded pid is another live real omp-named process
build_case other-live-omp || exit 1
start_real omp "$CASE" || exit 1
jq --argjson p "$REAL_PID" '.pid=$p' "$CASE/home/state/$ID.omp-session.json" > "$CASE/r" && mv "$CASE/r" "$CASE/home/state/$ID.omp-session.json"
refusal S3-recorded-pid-live-omp "$REAL_PID is a live omp process, so the omp extension owns this record" adopt

# S5/S6 real environment pins
build_case pin-other || exit 1
kill $REAL_PID; start_real omp "$CASE/wt/subdirectory" FM_SPAWN_GEN=other || exit 1; printf '%s' "$REAL_PID" > "$CASE/fake/recovery-pid"
refusal S5-real-env-pinned-other-generation 'generation proof needs the live process not to be pinned to another launch generation' adopt
refusal S5b-interrupt-still-refused '' interrupt
build_case pin-same || exit 1
kill $REAL_PID; start_real omp "$CASE/wt/subdirectory" FM_SPAWN_GEN=old || exit 1; printf '%s' "$REAL_PID" > "$CASE/fake/recovery-pid"
refusal S6-real-env-pinned-same-generation 'launch-pin proof needs a positively readable environment without a usable launch pin' adopt

# S7 foreground is a real claude-named process (stale omp registration)
build_case fg-claude || exit 1
kill $REAL_PID; start_real claude "$CASE/wt/subdirectory" || exit 1; printf '%s' "$REAL_PID" > "$CASE/fake/recovery-pid"
refusal S7-foreground-not-omp 'process proof needs the resolved foreground process to be a readable omp process' adopt

# S8 real cwd outside the worktree; real cwd inside another task's deeper worktree
build_case cwd-outside || exit 1
kill $REAL_PID; start_real omp "$CASE" || exit 1; printf '%s' "$REAL_PID" > "$CASE/fake/recovery-pid"
refusal S8a-cwd-outside-worktree "foreground cwd inside this task's recorded worktree" adopt
build_case cwd-foreign || exit 1
printf 'worktree=%s\n' "$CASE/wt/subdirectory" > "$CASE/home/state/foreign.meta"
refusal S8b-cwd-in-other-task-deeper-worktree 'unique deepest match; cwd belongs to foreign' adopt

# S9 another meta claims the same pane
build_case dup-pane || exit 1
printf 'window=fmlab:%%7\nworktree=%s\nremote_host=\n' "$CASE" > "$CASE/home/state/duplicate.meta"
refusal S9-two-metas-claim-pane 'unique-claim proof' adopt

# S10 generation mismatch
build_case gen-mismatch || exit 1
jq '.spawn_gen="different"' "$CASE/home/state/$ID.omp-session.json" > "$CASE/r" && mv "$CASE/r" "$CASE/home/state/$ID.omp-session.json"
refusal S10-record-generation-mismatch 'existing record spawn_gen to equal metadata spawn_gen' adopt

# S13 ambiguous foreground: two real omp processes listed, no group id
build_case ambiguous || exit 1
first=$REAL_PID; start_real omp "$CASE/wt/subdirectory" || exit 1; second=$REAL_PID
mv "$CASE/fakebin/herdr" "$CASE/fakebin/herdr-stub"
cat > "$CASE/fakebin/herdr" <<SH
#!/usr/bin/env bash
if [ "\${1:-} \${2:-}" = 'pane process-info' ]; then
  printf '%s\n' "\$*" >> "\$FM_FAKE_DIR/herdr-log"
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%%7","foreground_processes":[{"pid":$first,"name":"omp"},{"pid":$second,"name":"omp"}]}}}\n'
  exit 0
fi
exec "\${0%/*}/herdr-stub" "\$@"
SH
chmod +x "$CASE/fakebin/herdr"
refusal S13-ambiguous-foreground 'foreground proof needs one uniquely resolved live process' adopt

# S14 lock not owned by this session
build_case non-owner || exit 1
printf '1\n' > "$CASE/home/state/.lock"
refusal S14-non-lock-owner 'session record adoption requires the actual lock-owning main Firstmate' adopt

log ""; log "=== SUMMARY"; printf '%s\n' "${RESULT[@]}" >&3
printf '%s\n' "${RESULT[@]}"
