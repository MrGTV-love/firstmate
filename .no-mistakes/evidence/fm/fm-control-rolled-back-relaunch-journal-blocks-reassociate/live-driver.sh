#!/usr/bin/env bash
# Live driver: runs the REAL bin/fm-control.sh reassociate (from CODE root) against
# a disposable marked lab home (bin/fm-lab-home.sh env), a real git project, a real
# tmux server on the lab's private socket, and - for live-agent cases - a real
# `claude` process in the task's recorded tmux window.
# The session lock is acquired with the real bin/fm-lock.sh, so the lock owner is
# this shell's real Claude Code ancestor (no fake ps).
# Usage: live-driver.sh <code-root> <tag> <scenario...>
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M7MPJSRYMH2DNEGFVNKTR2WD
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M7MPJSRYMH2DNEGFVNKTR2WD
CODE=${1:?code root}; TAG=${2:?tag}; shift 2
OUT=$EV/$TAG
mkdir -p "$OUT"
LOG=$OUT/transcript.log
: > "$LOG"
cd "$WT" || exit 1
unset TMUX TMUX_PANE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TASK_ID FM_SUPERVISION_ACTOR FM_GATE_REFUSE_BYPASS
eval "$(bin/fm-lab-home.sh env 2>"$OUT/lab-env.stderr")" || { cat "$OUT/lab-env.stderr"; exit 1; }
LAB=$FM_HOME
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$OUT/lab-env.stderr")
WORK=$(mktemp -d "${TMPDIR%/}/fm-lab-work.XXXXXX"); WORK=$(cd "$WORK" && pwd -P)
CLAUDE_BIN=/Users/charlesabrooker/.local/bin/claude
export GIT_AUTHOR_NAME=fmlab GIT_AUTHOR_EMAIL=fmlab@example.invalid GIT_COMMITTER_NAME=fmlab GIT_COMMITTER_EMAIL=fmlab@example.invalid
PASS=0; FAILN=0

cleanup() {
  tmux kill-server 2>/dev/null
  chmod -R u+rwx "$LAB" "$WORK" 2>/dev/null
  rm -rf "$WORK"
  log "teardown: $TEARDOWN"
  eval "$TEARDOWN" >>"$LOG" 2>&1 && log "lab removed: $( [ -e "$LAB" ] && echo NO || echo yes )"
  log "RESULT tag=$TAG pass=$PASS fail=$FAILN"
}
trap cleanup EXIT

log() { printf '%s\n' "$*" | tee -a "$LOG"; }
ok() { PASS=$((PASS+1)); log "  PASS: $*"; }
bad() { FAILN=$((FAILN+1)); log "  FAIL: $*"; }

log "== tag=$TAG code=$CODE ($(git -C "$CODE" rev-parse --short HEAD 2>/dev/null || cat "$CODE/.base-sha" 2>/dev/null))"
log "lab FM_HOME=$LAB TMUX_TMPDIR=$TMUX_TMPDIR work=$WORK"

# real session lock, owned by this shell's real Claude Code ancestor
FM_HOME=$LAB "$WT/bin/fm-lock.sh" >>"$LOG" 2>&1 || { log "lock acquire failed"; exit 1; }
log "lock: $(FM_HOME=$LAB "$WT/bin/fm-lock.sh" status)"

# real project with origin
git init -q -b main "$WORK/proj"; printf '# proj\n' > "$WORK/proj/README.md"
git -C "$WORK/proj" add README.md; git -C "$WORK/proj" commit -qm initial
git clone -q --bare "$WORK/proj" "$WORK/proj.origin.git"
git -C "$WORK/proj" remote add origin "file://$WORK/proj.origin.git"

# real tmux server on the lab's private socket
tmux new-session -d -s fmlab -n placeholder -c "$WORK"
sleep 3; log "tmux: $(tmux list-windows -a -F '#{session_name}:#{window_name} #{pane_current_command}' | tr '\n' ';')"

mk_task() {  # <id>
  local id=$1
  git -C "$WORK/proj" worktree add -q -b "fm/$id" "$WORK/$id-old"
  printf 'committed work\n' > "$WORK/$id-old/work.txt"
  git -C "$WORK/$id-old" add work.txt; git -C "$WORK/$id-old" commit -qm "old copy work"
  git -C "$WORK/proj" worktree add -q -b "fm/$id-v2" "$WORK/$id-new"
  mkdir -p "$LAB/data/$id"
  printf '# Task\n## Captain'"'"'s intent\nLive lab reassociation for %s.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\nShip branch: fm/%s\n' "$id" "$id" > "$LAB/data/$id/brief.md"
  printf '%s\n' "window=fmlab:fm-$id" "endpoint_task_id=$id" "worktree=$WORK/$id-old" "project=$WORK/proj" \
    harness=claude kind=ship mode=no-mistakes yolo=off "branch=fm/$id" "tasktmp=/tmp/fm-$id" model=default effort=default spawn_gen=s1.1.1 \
    > "$LAB/state/$id.meta"
}
journal() {  # <id> <phase> [rollback|-] [task]
  local f="$LAB/state/$1.control-relaunch"
  printf 'v1\ntask=%s\nphase=%s\nts=2026-01-01T00:00:00Z\nbackend=tmux\nendpoint=fmlab:fm-%s\nworktree=%s\nkind=ship\n' \
    "${4-$1}" "$2" "$1" "$WORK/$1-old" > "$f"
  [ "${3:--}" = - ] || printf 'rollback=%s\n' "$3" >> "$f"
}
snap() {  # state+data inventory: type, mode, sha256 (lock telemetry .lock.holds and gate telemetry guard-events.jsonl excluded; the latter is shown per run)
  (cd "$LAB" && find state data \( -name '*.lock.holds' -o -path state/guard-events.jsonl \) -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
    if [ -L "$p" ]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
    elif [ -d "$p" ]; then printf 'D %s %s\n' "$p" "$(stat -f %Lp "$p")"
    else printf 'F %s %s %s\n' "$p" "$(stat -f %Lp "$p")" "$(shasum -a 256 < "$p" 2>/dev/null | cut -c1-16 || echo UNREADABLE)"; fi
  done)
}
windows() { tmux list-windows -a -F '#{session_name}:#{window_name} #{pane_current_command}' 2>&1; }
run() {  # <id> <args...> -> sets RC, OUTTXT
  local id=$1; shift
  local ge0; ge0=$(wc -l < "$LAB/state/guard-events.jsonl" 2>/dev/null || echo 0)
  OUTTXT=$(FM_HOME="$LAB" "$CODE/bin/fm-control.sh" "$id" "$@" 2>&1); RC=$?
  GE_NEW=$(tail -n +$((ge0 + 1)) "$LAB/state/guard-events.jsonl" 2>/dev/null | python3 -c 'import sys,json
for l in sys.stdin:
  d=json.loads(l); print("guard-event:", d.get("guard"), d.get("decision"), d.get("rule"), d.get("task"))' 2>&1)
  log "  \$ fm-control.sh $id $* -> exit $RC"
  printf '%s\n' "$OUTTXT" | sed 's/^/    | /' | tee -a "$LOG" >/dev/null
  printf '%s\n' "$OUTTXT" | tail -3 | sed 's/^/    | /'
}
agent_state() {  # <id>: the backend's own verdict for the recorded window
  ( FM_HOME=$LAB; . "$WT/bin/fm-backend.sh" >/dev/null 2>&1; fm_backend_agent_state tmux "fmlab:fm-$1" )
}
meta_wt() { grep '^worktree=' "$LAB/state/$1.meta" | tail -1 | cut -d= -f2-; }
archives() { ls -1 "$LAB/state/$1.control-relaunch".archived-* 2>/dev/null; }
sha() { shasum -a 256 < "$1" | cut -d' ' -f1; }
start_claude() {  # <id>: a real claude harness process in the recorded window
  tmux new-window -d -t fmlab -n "fm-$1" -c "$WORK/$1-old" "$CLAUDE_BIN"
  local i; for i in $(seq 1 40); do [ "$(agent_state "$1")" = alive ] && break; sleep 0.5; done
}

expect_archived() {  # <id> <journal-before-file> <label>
  local id=$1 before=$2 a n
  n=$(archives "$id" | wc -l | tr -d ' ')
  a=$(archives "$id" | tail -1)
  [ "$RC" = 0 ] && ok "$3: exit 0" || bad "$3: exit $RC"
  [ "$(meta_wt "$id")" = "$WORK/$id-new" ] && ok "$3: worktree= now $(meta_wt "$id")" || bad "$3: worktree= is $(meta_wt "$id")"
  [ ! -e "$LAB/state/$id.control-relaunch" ] && ok "$3: active journal path retired" || bad "$3: active journal still present"
  case "${a##*/}" in
    "$id.control-relaunch.archived-"????-??-??T??????Z.[0-9]*) ok "$3: archive name ${a##*/} (UTC stamp + counter)" ;;
    *) bad "$3: archive name '${a##*/}'" ;;
  esac
  [ -n "$a" ] && [ "$(sha "$before")" = "$(sha "$a")" ] && ok "$3: archive sha256 $(sha "$a") == journal-before sha256" || bad "$3: archive bytes differ"
}

expect_refused_unchanged() {  # <id> <fragment> <label> <before-snap> <before-windows>
  [ "$RC" != 0 ] && ok "$3: refused (exit $RC)" || bad "$3: did not refuse"
  printf '%s' "$OUTTXT" | grep -Fq -- "$2" && ok "$3: reason contains '$2'" || bad "$3: wrong reason"
  snap > "$OUT/$1.after.snap"
  if diff "$4" "$OUT/$1.after.snap" > "$OUT/$1.diff"; then ok "$3: state+data byte-identical (excluding *.lock.holds, guard-events.jsonl); no archive"; else bad "$3: state changed: $(cat "$OUT/$1.diff")"; fi
  log "  only telemetry appended: $(printf '%s' "$GE_NEW" | tr '\n' ';')"
  [ "$(windows)" = "$5" ] && ok "$3: tmux endpoints unchanged ($(windows | tr '\n' ';'))" || bad "$3: endpoints changed: before [$5] after [$(windows)]"
}

refusal_case() {  # <id> <setup-kind> <fragment>
  local id=$1 kind=$2 frag=$3 f
  log "-- refusal: $kind ($id)"
  mk_task "$id"; f="$LAB/state/$id.control-relaunch"
  case "$kind" in
    none-new-agent-confirmed|none-new-record-kept) journal "$id" failed:launching "$kind" ;;
    no-rollback) journal "$id" failed:launching - ;;
    mode000) journal "$id" failed:launching prior-record-kept ;;
    directory) mkdir "$f"; printf 'phase=failed:launching\nrollback=prior-record-kept\n' > "$f/entry" ;;
    symlink) journal "$id" failed:launching prior-record-kept; mv "$f" "$WORK/$id.journal-target"; ln -s "$WORK/$id.journal-target" "$f" ;;
    foreign-task) journal "$id" failed:launching prior-record-kept someone-else ;;
    empty-task) journal "$id" failed:launching prior-record-kept "" ;;
    malformed-prior) journal "$id" failed:launching prior-record-keptX ;;
    malformed-instructions) journal "$id" failed:launching instructions-restored-garbage ;;
    phase-launching) journal "$id" launching prior-record-kept ;;
    bad-state-suffix) journal "$id" failed:launching 'instructions-restored-agent-state-unknown!' ;;
  esac
  [ "$kind" != mode000 ] || chmod 000 "$f"
  snap > "$OUT/$id.before.snap"; local w; w=$(windows)
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab refusal $kind"
  expect_refused_unchanged "$id" "$frag" "$kind" "$OUT/$id.before.snap" "$w"
  [ "$kind" != mode000 ] || chmod 644 "$f"
}

for sc in "$@"; do case "$sc" in
vernant)
  id=lab-vernant; log "-- vernant shape: phase=failed:launching rollback=prior-record-kept, no agent window ($id)"
  mk_task "$id"; journal "$id" failed:launching prior-record-kept; cp "$LAB/state/$id.control-relaunch" "$OUT/$id.journal-before"
  log "  agent_state=$(agent_state "$id")"
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab: work moved to v2"
  expect_archived "$id" "$OUT/$id.journal-before" vernant
  grep -q "lab: work moved to v2" "$LAB/data/$id/brief.md" && ok "vernant: note written into brief" || bad "vernant: note missing"
  a1=$(archives "$id"); s1=$(sha "$a1")
  log "-- vernant: reassociate back to the old copy (archive must not block)"
  run "$id" reassociate --worktree "$WORK/$id-old" --note "lab: move back"
  [ "$RC" = 0 ] && ok "vernant-again: exit 0" || bad "vernant-again: exit $RC"
  [ "$(archives "$id")" = "$a1" ] && [ "$(sha "$a1")" = "$s1" ] && ok "vernant-again: archive kept, unchanged, no new archive" || bad "vernant-again: archive set changed"
  ;;
vernant-base)
  id=lab-vernant; log "-- vernant shape on BASE ($id)"
  mk_task "$id"; journal "$id" failed:launching prior-record-kept
  snap > "$OUT/$id.before.snap"; w=$(windows)
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab: work moved to v2"
  expect_refused_unchanged "$id" "unfinished relaunch transaction" "vernant-on-base" "$OUT/$id.before.snap" "$w"
  ;;
complete)
  id=lab-complete; log "-- phase=complete journal ($id)"
  mk_task "$id"; journal "$id" complete -; cp "$LAB/state/$id.control-relaunch" "$OUT/$id.journal-before"
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab complete"
  [ "$RC" = 0 ] && ok "complete: exit 0" || bad "complete: exit $RC"
  cmp -s "$OUT/$id.journal-before" "$LAB/state/$id.control-relaunch" && ok "complete: journal untouched in place" || bad "complete: journal changed"
  [ -z "$(archives "$id")" ] && ok "complete: no archive made" || bad "complete: archive made"
  ;;
counter)
  id=lab-counter; log "-- archive counter: earlier archives already hold the .0 name for the next seconds ($id)"
  mk_task "$id"; journal "$id" failed:launching prior-record-kept-agent-dead; cp "$LAB/state/$id.control-relaunch" "$OUT/$id.journal-before"
  now=$(date -u +%s)
  for d in $(seq 0 20); do
    st=$(date -u -r $((now + d)) +%Y-%m-%dT%H%M%SZ)
    printf 'earlier archive %s\n' "$st" > "$LAB/state/$id.control-relaunch.archived-$st.0"
  done
  ls -1 "$LAB/state/$id.control-relaunch".archived-* | while read -r p; do printf '%s %s\n' "$p" "$(sha "$p")"; done > "$OUT/$id.preexisting"
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab counter"
  [ "$RC" = 0 ] && ok "counter: exit 0" || bad "counter: exit $RC"
  new=$(ls -1 "$LAB/state/$id.control-relaunch".archived-* | grep -v '\.0$')
  log "  new archive: ${new##*/}"
  case "$new" in *.1) ok "counter: new archive took counter .1 (no collision)" ;; *) bad "counter: new archive '$new'" ;; esac
  [ -n "$new" ] && [ "$(sha "$new")" = "$(sha "$OUT/$id.journal-before")" ] && ok "counter: new archive is byte-exact" || bad "counter: new archive bytes"
  while read -r p s; do [ "$(sha "$p")" = "$s" ] || bad "counter: preexisting $p overwritten"; done < "$OUT/$id.preexisting"
  ok "counter: all $(wc -l < "$OUT/$id.preexisting" | tr -d ' ') pre-existing archives byte-unchanged"
  ;;
refusals)
  refusal_case lab-r1 none-new-agent-confirmed "unfinished relaunch transaction"
  refusal_case lab-r2 none-new-record-kept "unfinished relaunch transaction"
  refusal_case lab-r3 no-rollback "unfinished relaunch transaction"
  refusal_case lab-r4 mode000 "unfinished relaunch transaction"
  refusal_case lab-r5 directory "unfinished relaunch transaction"
  refusal_case lab-r6 symlink "unfinished relaunch transaction"
  refusal_case lab-r7 foreign-task "unfinished relaunch transaction"
  refusal_case lab-r8 empty-task "unfinished relaunch transaction"
  refusal_case lab-r9 malformed-prior "unfinished relaunch transaction"
  refusal_case lab-r10 malformed-instructions "unfinished relaunch transaction"
  refusal_case lab-r11 phase-launching "unfinished relaunch transaction"
  refusal_case lab-r12 bad-state-suffix "unfinished relaunch transaction"
  ;;
gated-alive)
  id=lab-gated; log "-- instructions-restored-agent-alive with a REAL claude in fmlab:fm-$id ($id)"
  mk_task "$id"; journal "$id" failed:launching instructions-restored-agent-alive; cp "$LAB/state/$id.control-relaunch" "$OUT/$id.journal-before"
  start_claude "$id"
  log "  agent_state=$(agent_state "$id"); windows: $(windows | tr '\n' ';')"
  snap > "$OUT/$id.before.snap"; w=$(windows)
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab gated"
  expect_refused_unchanged "$id" "agent is not proven stopped" "gated-alive(live claude)" "$OUT/$id.before.snap" "$w"
  log "  stopping the real claude: window keeps an idle shell"
  tmux respawn-pane -k -t "fmlab:fm-$id" /bin/zsh; sleep 1
  log "  agent_state=$(agent_state "$id")"
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab gated after stop"
  expect_archived "$id" "$OUT/$id.journal-before" "gated-alive(agent dead)"
  ;;
gated-state)
  id=lab-gstate; log "-- instructions-restored-agent-state-unknown with an ambiguous foreground (sleep) ($id)"
  mk_task "$id"; journal "$id" failed:checkpoint instructions-restored-agent-state-unknown; cp "$LAB/state/$id.control-relaunch" "$OUT/$id.journal-before"
  tmux new-window -d -t fmlab -n "fm-$id" -c "$WORK" "sleep 900"; sleep 1
  log "  agent_state=$(agent_state "$id")"
  snap > "$OUT/$id.before.snap"; w=$(windows)
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab gstate"
  expect_refused_unchanged "$id" "agent is not proven stopped" "gated-state(ambiguous)" "$OUT/$id.before.snap" "$w"
  tmux kill-window -t "fmlab:fm-$id"
  log "  window removed; agent_state=$(agent_state "$id")"
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab gstate missing"
  expect_archived "$id" "$OUT/$id.journal-before" "gated-state(missing)"
  ;;
ungated-live)
  id=lab-ungated; log "-- instructions-restored (not gated) with a REAL live claude in fmlab:fm-$id ($id)"
  mk_task "$id"; journal "$id" failed:checkpoint instructions-restored; cp "$LAB/state/$id.control-relaunch" "$OUT/$id.journal-before"
  start_claude "$id"
  log "  agent_state=$(agent_state "$id")"
  w=$(windows)
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab ungated live"
  expect_archived "$id" "$OUT/$id.journal-before" "ungated-live"
  [ "$(windows)" = "$w" ] && [ "$(agent_state "$id")" = alive ] && ok "ungated-live: live worker untouched (still alive)" || bad "ungated-live: endpoint changed"
  ;;
ungated-live-base)
  id=lab-ungated; log "-- instructions-restored with live claude on BASE ($id)"
  mk_task "$id"; journal "$id" failed:checkpoint instructions-restored
  start_claude "$id"; log "  agent_state=$(agent_state "$id")"
  snap > "$OUT/$id.before.snap"; w=$(windows)
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab ungated live"
  expect_refused_unchanged "$id" "unfinished relaunch transaction" "ungated-on-base" "$OUT/$id.before.snap" "$w"
  ;;
failure)
  id=lab-fail; log "-- staging failure after the archive copy: data/$id made read-only ($id)"
  mk_task "$id"; journal "$id" failed:launching prior-record-kept; cp "$LAB/state/$id.control-relaunch" "$OUT/$id.journal-before"
  cp "$LAB/state/$id.meta" "$OUT/$id.meta-before"; cp "$LAB/data/$id/brief.md" "$OUT/$id.brief-before"
  chmod 555 "$LAB/data/$id"
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab fail"
  chmod 755 "$LAB/data/$id"
  [ "$RC" != 0 ] && ok "failure: refused (exit $RC)" || bad "failure: did not fail"
  cmp -s "$OUT/$id.journal-before" "$LAB/state/$id.control-relaunch" && ok "failure: active journal still in place, byte-exact" || bad "failure: active journal changed/missing"
  cmp -s "$OUT/$id.meta-before" "$LAB/state/$id.meta" && cmp -s "$OUT/$id.brief-before" "$LAB/data/$id/brief.md" && ok "failure: task record and brief unchanged" || bad "failure: record/brief changed"
  log "  archives after failed attempt: $(archives "$id" | sed 's#.*/##' | tr '\n' ' ')"
  for a in $(archives "$id"); do [ "$(sha "$a")" = "$(sha "$OUT/$id.journal-before")" ] || bad "failure: retained archive $a not byte-exact"; done
  log "-- re-run after fixing the cause"
  run "$id" reassociate --worktree "$WORK/$id-new" --note "lab fail rerun"
  expect_archived "$id" "$OUT/$id.journal-before" "failure-rerun"
  log "  archives now: $(archives "$id" | sed 's#.*/##' | tr '\n' ' ')"
  ;;
esac; done
snap > "$OUT/final.snap"
