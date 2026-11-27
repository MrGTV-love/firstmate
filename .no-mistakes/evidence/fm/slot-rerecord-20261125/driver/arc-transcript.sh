#!/usr/bin/env bash
# Live transcript of bin/fm-control.sh <id> rerecord-slot on one disposable fixture home (fixture F of
# tests/fm-control-rerecord-slot.test.sh). The verb, relaunch and adoption run unmodified from the worktree's bin/.
# The tmux endpoint here is the suite's stub (server-dead = agent stopped); arc-real-tmux.sh uses a real tmux server.
. "$(dirname "${BASH_SOURCE[0]}")/rr-lib.sh"

say() { printf '\n===== %s =====\n' "$*"; }
show_state() {
  echo "--- task record slot lines (state/$RR_ID.meta):"; rr_slot_lines
  echo "--- durable manifest base_sha / owned_paths:"
  python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("base_sha="+r["base_sha"]); print("owned_paths="+",".join(r["owned_paths"]))' "$RR_MANIFEST"
  echo "--- data/$RR_ID/slot-rerecord/:"; ls -1 "$(rr_audit_dir)" 2>/dev/null || echo '(absent)'
}

rr_make_f arc
echo "fixture: M0=$RR_M0 M1=$RR_M1 branch HEAD=$RR_H"
echo "merge-base origin/main HEAD = $(git -C "$RR_DIR/wt" merge-base refs/remotes/origin/main HEAD)"
show_state

say "1. relaunch before rerecord-slot (record is stale)"
out=$(rr_relaunch); rc=$?; printf '%s\n' "$out" | tail -n 6; echo "exit=$rc"
echo "--- journal after the refused relaunch:"; cat "$RR_DIR/home/state/$RR_ID.control-relaunch" 2>/dev/null || echo '(no journal)'

say "2. rerecord-slot with no note and no --manifest-sha"
rr_run; echo "exit=$?"

say "3. rerecord-slot --check"
before=$(rec_inventory)
rr_run --check; echo "exit=$?"
[ "$before" = "$(rec_inventory)" ] && echo "CHECK-WROTE-NOTHING: record, archives, audits and temporaries unchanged" || echo "CHECK-CHANGED-STATE"

say "4. write with a wrong --manifest-sha"
rr_run --manifest-sha 0000000000000000000000000000000000000000000000000000000000000000 --note "$RR_NOTE"; echo "exit=$?"
[ "$before" = "$(rec_inventory)" ] && echo "REFUSAL-WROTE-NOTHING" || echo "REFUSAL-CHANGED-STATE"

prior_sha=$(rr_sha "$RR_META")
say "5. write with the reviewed --manifest-sha $(rr_msha)"
rr_write; echo "exit=$?"
show_state
echo "--- audit record:"; cat $(rr_audits)
echo "--- archive sha equals prior record sha: $( [ "$(rr_sha $(rr_archives))" = "$prior_sha" ] && echo yes || echo NO)"
echo "--- non-slot lines of the record unchanged vs archive: $( [ "$(rr_other_lines "$RR_META")" = "$(rr_other_lines $(rr_archives))" ] && echo yes || echo NO)"

say "6. second write run (expect no-op)"
before2=$(rec_inventory)
rr_write; echo "exit=$?"
[ "$before2" = "$(rec_inventory)" ] && echo "SECOND-RUN-RECORD-UNCHANGED" || echo "SECOND-RUN-CHANGED-RECORD (inventory differs; see audit dir)"
ls -1 "$(rr_audit_dir)"

say "7. relaunch after rerecord-slot (expect adoption)"
out=$(rr_relaunch); rc=$?; printf '%s\n' "$out" | tail -n 8; echo "exit=$rc"
grep -E '^(phase|rollback)=' "$RR_DIR/home/state/$RR_ID.control-relaunch" 2>/dev/null
echo "provisioner sentinel size: $(wc -c < "$ADOPT_SENTINEL" | tr -d ' ') (0 = adopted, provisioner not run)"
echo "(the server-dead tmux endpoint is replaced only on Herdr; suite case E1 stages the relaunch on a dead pane instead)"

say "8. relaunch after rerecord-slot on a dead pane (as suite case E1)"
rr_dead_pane
out=$(rr_relaunch); rc=$?; printf '%s\n' "$out" | tail -n 8; echo "exit=$rc"
grep -E '^(phase|rollback)=' "$RR_DIR/home/state/$RR_ID.control-relaunch" 2>/dev/null
echo "pane command now: $(cat "$RR_DIR/fake/command")"
echo "provisioner sentinel size: $(wc -c < "$ADOPT_SENTINEL" | tr -d ' ') (0 = adopted, provisioner not run)"
echo "--- record slot lines after relaunch:"; rr_slot_lines
