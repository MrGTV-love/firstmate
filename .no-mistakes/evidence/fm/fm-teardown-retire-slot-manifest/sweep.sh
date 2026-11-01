#!/usr/bin/env bash
# Live sweep lab: real bin/fm-slot-manifest-retire.py, real gh-axi against
# github.com/MrGTV-love/vernant PR 3592, real tasks-axi backlog in a disposable
# home, real Vernant provisioner and entry point in a disposable Vernant clone.
set -u
W=$1 EV=$2
mkdir -p "$EV"
R=/tmp/fm-test-vernant-ep/repo VENV=/tmp/fm-test-vernant-ep/venv L=/tmp/fm-sweep-lab
rm -rf "$L"; mkdir -p "$L/home/data" "$L/home/state" "$L/home/config" "$L/hooks" "$L/slots"
LOG=$EV/sweep.transcript.txt; : > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
common=$(git -C "$R" rev-parse --path-format=absolute --git-common-dir)
export CODEX_HOOK_STATE_DIR=$L/hooks WORKTREE_LIFECYCLE_STORE_DIR=$common/vernant-worktree-lifecycle
export FM_HOME=$L/home FM_DATA_OVERRIDE=$L/home/data FM_CONFIG_OVERRIDE=$L/home/config FM_STATE_OVERRIDE=$L/home/state
[ -e "$R/.venv" ] || ln -s "$VENV" "$R/.venv"
mkslot() {  # <name> <branch> <owner>
  local slot=$L/slots/$1
  git -C "$R" worktree add -q --no-checkout -b "$2" "$slot" origin/main
  git -C "$slot" sparse-checkout set --no-cone /scripts/git-stability/provision_existing_slot.py >/dev/null
  git -C "$slot" checkout -q "$2"
  say "slot $slot branch $2 status='$(git -C "$slot" status --porcelain)'"
  "$VENV/bin/python" "$R/scripts/git-stability/provision_existing_slot.py" --repo-root "$R" \
    --worktree-path "$slot" --owner-id "$3" --branch "$2" \
    --base-sha "$(git -C "$slot" merge-base origin/main HEAD)" \
    --owned-path scripts/git-stability/provision_existing_slot.py --state-dir "$L/hooks" >> "$LOG" 2>&1
  say "provision $3 rc=$?"
}
mkslot proven fm/vernant-lifecycle-manifest-retire-entrypoint vernant-lifecycle-manifest-retire-entrypoint
mkslot unproven fm/lab-unproven-owner lab-unproven-owner
# Backlog: the proven owner's Done entry records PR 3592, as teardown's Done close does.
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$L/home/data/backlog.md"
"$W/bin/fm-tasks-axi.sh" add vernant-lifecycle-manifest-retire-entrypoint "entry point" --kind ship >/dev/null
"$W/bin/fm-tasks-axi.sh" start vernant-lifecycle-manifest-retire-entrypoint >/dev/null
"$W/bin/fm-tasks-axi.sh" done vernant-lifecycle-manifest-retire-entrypoint --pr https://github.com/MrGTV-love/vernant/pull/3592 >/dev/null
say "--- backlog Done entry (tasks-axi show)"; "$W/bin/fm-tasks-axi.sh" show vernant-lifecycle-manifest-retire-entrypoint | tee -a "$LOG"
say "--- active record files before"; ls "$WORKTREE_LIFECYCLE_STORE_DIR"/*.json "$L/hooks/worktree-lifecycle"/*.json | tee -a "$LOG"
snap() { for f in "$WORKTREE_LIFECYCLE_STORE_DIR"/*.json "$L/hooks/worktree-lifecycle"/*.json; do [ -e "$f" ] && shasum -a 256 "$f"; done; }
snap > "$L/before.sha"
SWEEP=(python3 "$W/bin/fm-slot-manifest-retire.py" --project "$R" --firstmate-state "$L/home/state" --state-dir "$L/hooks")
say "=== report mode (no --apply)"
"${SWEEP[@]}" 2>&1 | tee -a "$LOG"; say "report rc=${PIPESTATUS[0]}"
snap > "$L/after-report.sha"
cmp -s "$L/before.sha" "$L/after-report.sha" && say "report mode: record bytes unchanged" || say "report mode: RECORD BYTES CHANGED"
say "=== --apply"
"${SWEEP[@]}" --apply 2>&1 | tee -a "$LOG"; say "apply rc=${PIPESTATUS[0]}"
say "--- active record files after"; ls "$WORKTREE_LIFECYCLE_STORE_DIR"/*.json "$L/hooks/worktree-lifecycle"/*.json 2>&1 | tee -a "$LOG"
say "--- retired archives"; find "$WORKTREE_LIFECYCLE_STORE_DIR/retired" -type f | tee -a "$LOG"
for f in $(find "$WORKTREE_LIFECYCLE_STORE_DIR/retired" -type f); do jq -c '{owner: .previous_manifest.owner_id, proofs}' "$f" | tee -a "$LOG"; done
say "=== --apply again (idempotent rerun)"
"${SWEEP[@]}" --apply 2>&1 | tee -a "$LOG"; say "rerun rc=${PIPESTATUS[0]}"
say "=== live owner: write state/<owner>.meta for the unproven owner and a Done entry for it, then --apply"
"$W/bin/fm-tasks-axi.sh" add lab-unproven-owner "x" --kind ship >/dev/null
"$W/bin/fm-tasks-axi.sh" start lab-unproven-owner >/dev/null
"$W/bin/fm-tasks-axi.sh" done lab-unproven-owner --pr https://github.com/MrGTV-love/vernant/pull/3592 >/dev/null
printf 'kind=ship\n' > "$L/home/state/lab-unproven-owner.meta"
"${SWEEP[@]}" --apply 2>&1 | tee -a "$LOG"; say "live-owner rc=${PIPESTATUS[0]}"
rm "$L/home/state/lab-unproven-owner.meta"
say "=== same owner, meta gone, Done entry PR 3592 but record branch fm/lab-unproven-owner differs from PR head"
"${SWEEP[@]}" --apply 2>&1 | tee -a "$LOG"; say "branch-differs rc=${PIPESTATUS[0]}"
say "--- active record files at end"; ls "$WORKTREE_LIFECYCLE_STORE_DIR"/*.json "$L/hooks/worktree-lifecycle"/*.json 2>&1 | tee -a "$LOG"
