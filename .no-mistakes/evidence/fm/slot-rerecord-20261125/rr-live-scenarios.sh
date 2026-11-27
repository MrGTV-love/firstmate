#!/usr/bin/env bash
# Runs the live rerecord-slot scenarios in one bash shell against the lab home named by FM_HOME/TMUX_TMPDIR.
# Usage: bash rr-live-scenarios.sh <scenario>...
E=$(cd "$(dirname "$0")" && pwd)
. "$E/rr-live-lib.sh"
cd "$WT_ROOT" || exit 1

unchanged() { # <before> <label>
  local after; after=$(inventory)
  if [ "$1" = "$after" ]; then echo "$2_WROTE_NOTHING=yes"; else echo "$2_WROTE_NOTHING=no"; diff <(echo "$1") <(echo "$after"); fi
}

s_write() {
  fixture; renew
  say "S2 write preconditions refuse and write nothing"
  local b; b=$(inventory); echo "$b"
  rr --manifest-sha "$(msha)"
  unchanged "$b" NO_NOTE
  rr --manifest-sha 0000000000000000000000000000000000000000000000000000000000000000 --note "$NOTE"
  unchanged "$b" WRONG_SHA
  say "S3 write with the reviewed digest and a note"
  cp "$META" "$FX/prior.meta"
  grep -vE '^(slot_base_sha|slot_owned_path)=' "$META" > "$FX/prior.other"
  rr --manifest-sha "$(msha)" --note "$NOTE"
  echo "--- slot lines after:"; slot_lines
  grep -vE '^(slot_base_sha|slot_owned_path)=' "$META" > "$FX/after.other"
  cmp -s "$FX/prior.other" "$FX/after.other" && echo "OTHER_RECORD_LINES_UNCHANGED=yes" || { echo "OTHER_RECORD_LINES_UNCHANGED=no"; diff "$FX/prior.other" "$FX/after.other"; }
  echo "--- audit dir:"; ls -l "$(audit_dir)"; stat -f '%Lp %N' "$(audit_dir)"
  local a; for a in "$(audit_dir)"/*.record; do echo "--- $a"; cat "$a"; done
  for a in "$(audit_dir)"/prior-meta.*; do cmp -s "$a" "$FX/prior.meta" && echo "ARCHIVE_EQUALS_PRIOR_RECORD=yes ($a)" || echo "ARCHIVE_EQUALS_PRIOR_RECORD=no"; done
  echo "manifest_unchanged=$( [ "$(msha)" = "$(sed -n 's/^manifest_sha256=//p' "$(audit_dir)"/*.record | head -1)" ] && echo yes || echo see-audit)"
  say "S4 a second write finds it already recorded and writes nothing"
  b=$(inventory)
  rr --manifest-sha "$(msha)" --note "$NOTE"
  unchanged "$b" REPEAT
  say "S4b --check after the write"
  rr --check
  cleanup_fixture
}

s_refusals() {
  local b
  say "H1 manifest owner is another task -> refuses"
  fixture; renew --owner other-task; b=$(inventory); rr --check; rr --manifest-sha "$(msha)" --note "$NOTE"; unchanged "$b" H1; cleanup_fixture

  say "H2 manifest base is the branch HEAD, not merge-base(origin/main, HEAD) -> refuses"
  fixture; renew --base "$H" src lib tools/x.sh; b=$(inventory); rr --manifest-sha "$(msha)" --note "$NOTE"; unchanged "$b" H2; cleanup_fixture

  say "H3 renewed scope drops a changed path (tools/x.sh) -> refuses naming it"
  fixture; renew src lib; b=$(inventory); rr --manifest-sha "$(msha)" --note "$NOTE"; unchanged "$b" H3; cleanup_fixture

  say "H4 renewed scope grabs a path the branch never changed (docs.txt) -> refuses"
  fixture; renew src lib tools/x.sh docs.txt; b=$(inventory); rr --manifest-sha "$(msha)" --note "$NOTE"; unchanged "$b" H4; cleanup_fixture

  say "H5 renewed scope grabs a whole tracked dir wider than the change (tools) -> refuses"
  fixture; renew src lib tools; b=$(inventory); rr --manifest-sha "$(msha)" --note "$NOTE"; unchanged "$b" H5; cleanup_fixture

  say "H6 manifest names another copy path -> refuses"
  fixture; renew
  python3 - "$MANIFEST" "$FX/elsewhere" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); r["worktree_path"] = sys.argv[2]; open(sys.argv[1], "w").write(json.dumps(r, sort_keys=True))
PY
  b=$(inventory); rr --manifest-sha "$(msha)" --note "$NOTE"; unchanged "$b" H6; cleanup_fixture

  say "H7 manifest names another branch -> refuses"
  fixture; renew
  python3 - "$MANIFEST" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); r["branch"] = "fm/other"; open(sys.argv[1], "w").write(json.dumps(r, sort_keys=True))
PY
  b=$(inventory); rr --manifest-sha "$(msha)" --note "$NOTE"; unchanged "$b" H7; cleanup_fixture

  # H8 (stale --manifest-sha) is driven in s_refusals2.

  say "H9 a worker (FM_TASK_ID set) -> refuses actor_not_main"
  fixture; renew; b=$(inventory)
  ( export FM_TASK_ID=rrt; "$CONTROL" "$RR_ID" rerecord-slot --manifest-sha "$(msha)" --note "$NOTE" 2>&1 | grep -v '^fm-gate-refuse'; echo "exit=${PIPESTATUS[0]}" )
  unchanged "$b" H9

  say "H10 the supervision branch (FM_SUPERVISION_ACTOR=branch) -> refuses actor_not_main"
  ( export FM_SUPERVISION_ACTOR=branch; unset FM_TASK_ID; "$CONTROL" "$RR_ID" rerecord-slot --manifest-sha "$(msha)" --note "$NOTE" 2>&1 | grep -v '^fm-gate-refuse'; echo "exit=${PIPESTATUS[0]}" )
  unchanged "$b" H10

  say "H11 the home's session lock is held by another live process -> refuses session_lock_not_owned"
  cp "$FM_HOME/state/.lock" "$FX/lock.saved"; cp "$FM_HOME/state/.lock-session" "$FX/lock-session.saved" 2>/dev/null
  sleep 300 & local other=$!
  printf '%s\n' "$other" > "$FM_HOME/state/.lock"; rm -f "$FM_HOME/state/.lock-session"
  rr --manifest-sha "$(msha)" --note "$NOTE"
  kill "$other"; wait "$other" 2>/dev/null
  cp "$FX/lock.saved" "$FM_HOME/state/.lock"; [ -f "$FX/lock-session.saved" ] && cp "$FX/lock-session.saved" "$FM_HOME/state/.lock-session"
  unchanged "$b" H11

  say "H12 a live launch owner holds the task's spawn lock -> --check reports it, write refuses launch_in_progress"
  bash -c '. "$1/bin/fm-wake-lib.sh" || exit 2; fm_lock_try_acquire "$2" || exit 3; : > "$3"; exec /bin/sleep 300' \
    _ "$WT_ROOT" "$FM_HOME/state/.spawn-$RR_ID.lock" "$FX/holder-ready" >/dev/null 2>&1 &
  local holder=$! i=0
  while [ ! -e "$FX/holder-ready" ] && [ $i -lt 300 ]; do sleep 0.01; i=$((i+1)); done
  rr --check | grep -E 'launch_proof|write_would|exit='
  rr --manifest-sha "$(msha)" --note "$NOTE"
  kill "$holder"; wait "$holder" 2>/dev/null
  unchanged "$b" H12
  cleanup_fixture
}

# Endpoint states on the lab's private tmux server (TMUX_TMPDIR): a live pane refuses, a dead pane passes.
s_endpoint() {
  local b
  say "E0 tmux server for this lab is $TMUX_TMPDIR (private); no server running -> endpoint missing, absence proven"
  fixture; renew
  tmux ls 2>&1 | head -2
  rr --check | grep -E 'stopped_proof|write_would|exit='

  say "H13 the task window holds a live process -> refuses agent_not_proven_stopped"
  tmux new-session -d -s fmses -n "fm-$RR_ID" -c "$COPY" 'exec sleep 600'
  tmux list-panes -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command} dead=#{pane_dead}'
  b=$(inventory)
  rr --check | grep -E 'stopped_proof|write_would|exit='
  rr --manifest-sha "$(msha)" --note "$NOTE"
  unchanged "$b" H13

  say "E1 the agent exited and the task window holds only its idle shell (reads dead) -> stopped proof passes and the write publishes"
  tmux kill-server
  tmux new-session -d -s fmses -n "fm-$RR_ID" -c "$COPY" 'exec /bin/zsh -f -i'
  sleep 1
  tmux list-panes -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command} dead=#{pane_dead}'
  bash -c '. "$1/bin/fm-backend.sh"; printf "backend agent state: %s\n" "$(fm_backend_agent_state tmux "$2")"' _ "$WT_ROOT" "fmses:fm-$RR_ID"
  rr --check | grep -E 'stopped_proof|write_would|exit='
  rr --manifest-sha "$(msha)" --note "$NOTE"
  slot_lines
  echo "audit result: $(sed -n 's/^result=//p' "$(audit_dir)"/*.record)"
  tmux list-panes -a -F 'after: #{session_name}:#{window_name} cmd=#{pane_current_command} dead=#{pane_dead}'
  echo "keys typed into the pane by the verb (pane history):"; tmux capture-pane -p -t "fmses:fm-$RR_ID" | sed '/^$/d'
  tmux kill-server 2>/dev/null
  cleanup_fixture
}


s_refusals2() {
  local b reviewed
  say "H8 manifest bytes change after the operator reviewed --check (project renews again, same scope, new bytes) -> refuses manifest_sha_mismatch"
  fixture; renew; rr --check | grep -E '^manifest_sha256|write_would'; reviewed=$(msha)
  sleep 1; renew   # same base and scope; created_at differs, so the bytes differ
  echo "reviewed=$reviewed now=$(msha)"
  b=$(inventory); rr --manifest-sha "$reviewed" --note "$NOTE"; unchanged "$b" H8; cleanup_fixture

  say "H2b manifest base is still the old recorded base M0 while scope grew -> refuses (base not the merge-base)"
  fixture; renew --base "$M0" src lib tools/x.sh; b=$(inventory); rr --manifest-sha "$(msha)" --note "$NOTE"; unchanged "$b" H2b; cleanup_fixture

  say "H2c manifest base points backward to an ancestor of the recorded base -> refuses"
  fixture
  # re-provision the starting record at M1's parent chain: make the recorded base M1 and the manifest base M0
  python3 - "$META" "$M1" <<'PY'
import sys
p, b = sys.argv[1:]
lines = open(p).read().splitlines(True)
open(p, "w").write("".join(("slot_base_sha=%s\n" % b) if l.startswith("slot_base_sha=") else l for l in lines))
PY
  renew --base "$M0" src lib tools/x.sh; b=$(inventory); rr --manifest-sha "$(msha)" --note "$NOTE"; unchanged "$b" H2c; cleanup_fixture
}

s_check() {
  fixture
  say "S0 fixture: M0=$M0 M1=$M1 HEAD=$H"; slot_lines
  say "S0 before renewal: the project has not renewed the durable record; a check refuses"
  rr --check
  renew
  say "S0 durable record renewed by the project"; cat "$MANIFEST"; echo
  say "S1 --check reports what the write would do and writes nothing"
  local b; b=$(inventory); echo "$b"
  rr --check
  unchanged "$b" CHECK
  cleanup_fixture
}

for s in "$@"; do "s_$s"; done
