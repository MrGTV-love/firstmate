#!/usr/bin/env bash
# Manual drive of `bin/fm-control.sh <task> rerecord-slot` against a disposable fixture home.
# It reuses the repository's own fixture builders (tests/fm-control-relaunch-*.sh and fixture F from
# tests/fm-control-rerecord-slot.test.sh) to build a governed ship task whose project main moved forward,
# whose branch merged main and grew its scope, and whose durable slot record was renewed. Then it runs the
# real verb step by step and prints each command, its output, its exit code, and the record's slot lines.
# Usage: bash drive-rerecord-slot.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 1
# shellcheck source=/dev/null
. tests/fm-control-relaunch-helpers.sh
# shellcheck source=/dev/null
. tests/fm-control-relaunch-slot-helpers.sh
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# Fixture F builders only (no test cases).
# shellcheck source=/dev/null
eval "$(sed -n '/^FM_REAL_MV=/,/^# --- runs/p' tests/fm-control-rerecord-slot.test.sh)"
rr_msha() { shasum -a 256 "$RR_MANIFEST" | awk '{print $1}'; }

step() { # <title> <args...>
  local title=$1 out rc
  shift
  printf '\n### %s\n$ fm-control.sh %s rerecord-slot %s\n' "$title" "$RR_ID" "$*"
  out=$(unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
        run_control "$RR_DIR" "$RR_ID" rerecord-slot "$@"); rc=$?
  printf '%s\n[exit %s]\n' "$out" "$rc"
  printf -- '--- record slot lines now:\n'; grep -E '^(slot_base_sha|slot_owned_path)=' "$RR_META"
  printf -- '--- audit records: %s; archives: %s\n' \
    "$(ls "$RR_DIR/home/data/$RR_ID/slot-rerecord/"*.record 2>/dev/null | wc -l | tr -d ' ')" \
    "$(ls "$RR_DIR/home/data/$RR_ID/slot-rerecord/"prior-meta.* 2>/dev/null | wc -l | tr -d ' ')"
}

scenario_main() {
  rr_make_f live
  printf '# Fixture: M0=%s M1=%s HEAD=%s\n' "$RR_M0" "$RR_M1" "$RR_H"
  printf '# merge-base origin/main HEAD = %s\n' "$(git -C "$RR_DIR/wt" merge-base refs/remotes/origin/main HEAD)"
  printf '# renewed manifest: %s\n' "$(python3 -c 'import json,sys;r=json.load(open(sys.argv[1]));print({k:r[k] for k in sorted(r) if k in ("base_sha","owned_paths","owner_id","branch","worktree_path")})' "$RR_MANIFEST")"
  printf '# record before:\n'; grep -E '^(slot_base_sha|slot_owned_path)=' "$RR_META"
  local before_sha; before_sha=$(shasum -a 256 "$RR_META" | awk '{print $1}')

  printf '\n### Relaunch before rerecord (admission must still refuse)\n'
  ( unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    FM_TEST_PROVISION_CALLED=$ADOPT_SENTINEL FM_TEST_SLOT_RECORD=$RR_MANIFEST \
      run_control "$RR_DIR" "$RR_ID" relaunch --note 'resume after the slot renewal' ) | tail -3
  printf '[exit %s]\n' "${PIPESTATUS[0]}"

  step 'Check mode reports and writes nothing' --check
  printf -- '--- record sha unchanged by --check: %s\n' "$([ "$(shasum -a 256 "$RR_META" | awk '{print $1}')" = "$before_sha" ] && echo yes || echo NO)"
  step 'Write with no note is refused' --manifest-sha "$(rr_msha)"
  step 'Write with a wrong manifest sha is refused' --manifest-sha "$(printf '0%.0s' {1..64})" --note 'Main ruling: test'
  rr_alive
  step 'Write while the agent is alive is refused' --manifest-sha "$(rr_msha)" --note 'Main ruling: test'
  rm -f "$RR_DIR/fake/command"; printf 'claude' > "$RR_DIR/fake/command"; : > "$RR_DIR/fake/server-dead"
  step 'Write with the correct sha and a note publishes' --manifest-sha "$(rr_msha)" --note 'Main ruling: re-record the renewed slot'
  local a; a=$(ls "$RR_DIR/home/data/$RR_ID/slot-rerecord/"*.record | head -1)
  printf -- '--- audit record %s:\n' "${a##*/}"; cat "$a"
  local arch; arch=$(ls "$RR_DIR/home/data/$RR_ID/slot-rerecord/"prior-meta.* | head -1)
  printf -- '--- archive equals the prior record bytes: %s\n' "$([ "$(shasum -a 256 "$arch" | awk '{print $1}')" = "$before_sha" ] && echo yes || echo NO)"
  step 'A second write is a no-op' --manifest-sha "$(rr_msha)" --note 'Main ruling: re-record the renewed slot'

  printf '\n### Relaunch after rerecord (adoption must admit the record)\n'
  ( unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    FM_TEST_PROVISION_CALLED=$ADOPT_SENTINEL FM_TEST_SLOT_RECORD=$RR_MANIFEST \
      run_control "$RR_DIR" "$RR_ID" relaunch --note 'resume after the slot renewal' ) | tail -4
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
  printf -- '--- provisioner sentinel empty (adopted, not reprovisioned): %s\n' "$([ -s "$ADOPT_SENTINEL" ] && echo NO || echo yes)"

  # A proven-gone tmux server is only replaced on Herdr, so stage the stopped agent as a dead pane (as test E1 does).
  rr_dead_pane
  printf '\n### Relaunch after rerecord on a dead pane (adoption admits, new agent launches)\n'
  ( unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    FM_TEST_PROVISION_CALLED=$ADOPT_SENTINEL FM_TEST_SLOT_RECORD=$RR_MANIFEST \
      run_control "$RR_DIR" "$RR_ID" relaunch --note 'resume after the slot renewal' ) | grep -E 'adopt|error|relaunch' | tail -6
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
  printf -- '--- journal phase: %s; agent command now: %s; provisioner sentinel empty: %s\n' \
    "$(sed -n 's/^phase=//p' "$RR_DIR/home/state/$RR_ID.control-relaunch" | tail -1)" "$(cat "$RR_DIR/fake/command")" \
    "$([ -s "$ADOPT_SENTINEL" ] && echo NO || echo yes)"
}

scenario_adversarial() {
  local name=$1
  shift
  rr_make_f "adv-$name" --no-renew
  "$@"
  local before; before=$(shasum -a 256 "$RR_META" | awk '{print $1}')
  step "Adversarial: $name (check)" --check
  step "Adversarial: $name (write)" --manifest-sha "$(rr_msha)" --note 'Main ruling: test'
  printf -- '--- record bytes unchanged: %s\n' "$([ "$(shasum -a 256 "$RR_META" | awk '{print $1}')" = "$before" ] && echo yes || echo NO)"
}

adv_other_owner() { rr_renew --owner-id someone-else; }
adv_backward_base() { rr_renew --base-sha "$RR_M0"; }
adv_unrelated_scope() { rr_renew --owned-path src --owned-path lib --owned-path tools/x.sh --owned-path docs.txt; }
adv_uncovered_change() { rr_renew --owned-path src --owned-path lib; }
adv_root_added_file() {
  rr_branch_commit 'add a root file' NEWS.md=news
  rr_renew --owned-path src --owned-path lib --owned-path tools/x.sh --owned-path NEWS.md
}

case "${2:-main}" in
  main) scenario_main ;;
  adv) scenario_adversarial other-owner adv_other_owner
       scenario_adversarial base-not-merge-base adv_backward_base
       scenario_adversarial scope-entry-not-own-work adv_unrelated_scope
       scenario_adversarial scope-uncovered-change adv_uncovered_change
       scenario_adversarial root-added-file-residual adv_root_added_file ;;
esac

# Scope-only growth: the record already names base M1, so only the scope grew.
scenario_scope_only() {
  rr_make_f scope-only --no-renew
  rr_record_slots "$RR_M1" src
  rr_renew
  rr_dead_pane
  printf '# record before:\n'; grep -E '^(slot_base_sha|slot_owned_path)=' "$RR_META"
  printf '# renewed manifest base=%s owned_paths=%s\n' "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["base_sha"])' "$RR_MANIFEST")" "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["owned_paths"])' "$RR_MANIFEST")"
  printf '\n### Relaunch before rerecord (scope-only)\n'
  ( unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    FM_TEST_PROVISION_CALLED=$ADOPT_SENTINEL FM_TEST_SLOT_RECORD=$RR_MANIFEST \
      run_control "$RR_DIR" "$RR_ID" relaunch --note 'resume after the slot renewal' ) | grep -E '^error' | head -2
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
  step 'Scope-only check' --check
  step 'Scope-only write' --manifest-sha "$(rr_msha)" --note 'Main ruling: re-record the grown scope'
  printf '\n### Relaunch after rerecord (scope-only)\n'
  ( unset FM_TASK_ID FM_SUPERVISION_ACTOR PI_CODING_AGENT CLAUDE_PID CLAUDE_CODE_SESSION_ID
    FM_TEST_PROVISION_CALLED=$ADOPT_SENTINEL FM_TEST_SLOT_RECORD=$RR_MANIFEST \
      run_control "$RR_DIR" "$RR_ID" relaunch --note 'resume after the slot renewal' ) | grep -E 'adoption|^error|^relaunched' | tail -4
  printf '[exit %s]\n' "${PIPESTATUS[0]}"
  printf -- '--- journal phase: %s; provisioner sentinel empty: %s\n' \
    "$(sed -n 's/^phase=//p' "$RR_DIR/home/state/$RR_ID.control-relaunch" | tail -1)" "$([ -s "$ADOPT_SENTINEL" ] && echo NO || echo yes)"
}
[ "${2:-}" != scope ] || scenario_scope_only
