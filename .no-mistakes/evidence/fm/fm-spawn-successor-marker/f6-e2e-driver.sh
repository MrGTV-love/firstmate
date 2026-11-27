#!/usr/bin/env bash
# F6 end-to-end driver (test-phase evidence, not part of the repository).
# Real bin/fm-spawn.sh (through the suite's own spawn runner: stub tmux backend, stub agent launch),
# REAL Vernant scripts/git-stability/provision_existing_slot.py and REAL R-13 hook code from a pinned
# Vernant commit, in a throwaway clone whose objects borrow (read-only, via alternates) from the
# operator's local Vernant clone. All Vernant state (CODEX_HOOK_STATE_DIR, WORKTREE_LIFECYCLE_STORE_DIR)
# is in the temp case dir.
# Harness change (labelled): R-13 is called through its main() with CANONICAL_ORIGIN_URLS pointed at
# the temp origin URL, exactly as Vernant's own _successor_decision test does; the bypass env is unset.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8E1JY2FQN2WG2YPZJQ5DDJ4
VERNANT=/Users/charlesabrooker/firstmate/projects/vernant
VSHA=${VSHA:?pin a Vernant commit}
VENV=$VERNANT/.venv

defs=$(mktemp "${TMPDIR:-/tmp}/f6-defs.XXXXXX")
sed -n '1,3436p' "$WT/tests/fm-spawn-pool-base-freshen.test.sh" |
  sed "s|^\. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/fixtures.sh\"|. \"$WT/tests/fixtures.sh\"|" > "$defs"
# shellcheck disable=SC1090
. "$defs"
rm -f "$defs"

step() { printf '\n=== %s\n' "$*"; }

CASE_DIR="$TMP_ROOT/f6"
HOME_DIR="$CASE_DIR/home"
PROJECT_DIR="$CASE_DIR/vernant"
ORIGIN="$CASE_DIR/origin.git"
HOOKSTATE="$CASE_DIR/hookstate"
DURABLE="$CASE_DIR/durable"
mkdir -p "$HOME_DIR/projects" "$HOME_DIR/state" "$HOME_DIR/config" "$HOOKSTATE" "$DURABLE"
chmod 700 "$HOOKSTATE"
printf 'codex\n' > "$HOME_DIR/config/crew-harness"
touch "$HOME_DIR/state/.last-watcher-beat"
export CODEX_HOOK_STATE_DIR="$HOOKSTATE" WORKTREE_LIFECYCLE_STORE_DIR="$DURABLE"
unset CLAUDE_ALLOW_STALE_BASE; export PYTHONDONTWRITEBYTECODE=1

step "temp origin + project from pinned Vernant $VSHA (objects borrowed read-only)"
git init -q --bare "$ORIGIN"
printf '%s\n' "$VERNANT/.git/objects" > "$ORIGIN/objects/info/alternates"
git -C "$ORIGIN" update-ref refs/heads/main "$VSHA"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git clone -q --shared "$ORIGIN" "$PROJECT_DIR"
git -C "$PROJECT_DIR" remote set-url origin "file://$ORIGIN"
git -C "$PROJECT_DIR" fetch -q origin
git -C "$PROJECT_DIR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$PROJECT_DIR" config user.name Tests; git -C "$PROJECT_DIR" config user.email tests@example.invalid
printf '.venv\n' >> "$PROJECT_DIR/.git/info/exclude"
ln -s "$VENV" "$PROJECT_DIR/.venv"
echo "project HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD) status=[$(git -C "$PROJECT_DIR" status --porcelain | head -3)]"

step "advertise probe by hand (stderr visible), same form as fm_slot_advertises_supersedes"
(cd "$PROJECT_DIR" && PATH="$PROJECT_DIR/.venv/bin:$PATH" PYTHONDONTWRITEBYTECODE=1 python3 scripts/git-stability/provision_existing_slot.py --help) | grep -n -- '--supersedes' || echo 'PROBE: no --supersedes'

FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
fm_test_fake_no_mistakes "$FAKEBIN_DIR"; fm_test_fake_gh "$FAKEBIN_DIR"; fm_test_fake_gh_axi "$FAKEBIN_DIR"
LAUNCH_LOG="$CASE_DIR/launch.log"; : > "$LAUNCH_LOG"

step "live predecessor task copy with two commits, pushed"
PRED="f6pred-$$"
PRED_DIR="$CASE_DIR/pred-copy"
git -C "$PROJECT_DIR" worktree add -q -b "fm/$PRED" "$PRED_DIR" main
for i in 0 1; do printf 'predecessor %s\n' "$i" >> "$PRED_DIR/README.md"; git -C "$PRED_DIR" commit -qam "predecessor $i"; done
git -C "$PRED_DIR" push -q -u origin "fm/$PRED"
{ echo "window=fm-$PRED"; echo "endpoint_task_id=$PRED"; echo "worktree=$PRED_DIR"; echo "project=$PROJECT_DIR"
  echo kind=ship; echo "branch=fm/$PRED"; echo mode=local-only; echo yolo=off; } > "$HOME_DIR/state/$PRED.meta"
CARRIED=$(git -C "$PROJECT_DIR" rev-list "$VSHA..fm/$PRED")
echo "predecessor commits to carry:"; echo "$CARRIED"

spawn_task() { # <id> <pool> [extra args]
  local id=$1 pool=$2; shift 2
  mkdir -p "$HOME_DIR/data/$id"; fm_test_spawn_brief "$HOME_DIR" "$id"
  git -C "$PROJECT_DIR" worktree add -q --detach "$pool" main
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" fm_test_run_spawn "$HOME_DIR" "$pool" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --mode local-only --yolo off --owned-path README.md "$@"
}

r13_after_carry() { # <pool>: carry the predecessor's own commits (ff merge, same shas), add one commit, run R-13
  local pool=$1 branch tip
  git -C "$pool" merge -q --ff-only "fm/$PRED"
  printf 'successor work\n' >> "$pool/README.md"; git -C "$pool" commit -qam 'successor work'
  branch=$(git -C "$pool" symbolic-ref --short HEAD); tip=$(git -C "$pool" rev-parse HEAD)
  echo "pushing branch=$branch tip=$tip"
  (cd "$pool" && "$VENV/bin/python" - "$pool" "file://$ORIGIN" "$branch" "$tip" <<'PY'
import os, sys
pool, url, branch, tip = sys.argv[1:]
sys.path.insert(0, pool)
from scripts.hooks import pre_push_base_ref_staleness as r13
r13.CANONICAL_ORIGIN_URLS = frozenset({url})  # harness change, as in Vernant's own test
os.environ.pop(r13.BYPASS_ENV, None)
foreign = r13.local_foreign_commits(__import__('pathlib').Path(pool), budget_seconds=30)
print("R-13 foreign commits:", foreign)
rc = r13.main([], f"refs/heads/{branch} {tip} refs/heads/{branch} {'0'*40}\n")
print("R-13 exit:", rc, "(1 = push blocked, 0 = push accepted)")
PY
  )
}

step "CONTROL: spawn WITHOUT --successor-of"
CTRL="f6ctrl-$$"; CTRL_POOL="$CASE_DIR/pool-ctrl"
spawn_task "$CTRL" "$CTRL_POOL"; echo "spawn exit=$?"
echo "--- control meta:"; cat "$HOME_DIR/state/$CTRL.meta" 2>/dev/null | grep -E '^(branch|successor_of|slot_manifest|worktree)=' || true
echo "--- markers after control spawn:"; ls "$HOOKSTATE/worktree-supersedence" 2>/dev/null || echo '(none)'
r13_after_carry "$CTRL_POOL"

step "drop the control lane (its branch also holds the predecessor commits, which R-13 rightly treats as a foreign holder)"
git -C "$PROJECT_DIR" worktree remove --force "$CTRL_POOL" && git -C "$PROJECT_DIR" branch -D "fm/$CTRL"

step "SUCCESSOR: spawn WITH --successor-of $PRED"
SUCC="f6succ-$$"; SUCC_POOL="$CASE_DIR/pool-succ"
spawn_task "$SUCC" "$SUCC_POOL" --successor-of "$PRED"; echo "spawn exit=$?"
echo "--- successor meta:"; grep -E '^(branch|successor_of|slot_manifest|worktree|recovery)=' "$HOME_DIR/state/$SUCC.meta" || true
echo "--- provisioner report(s):"; for r in "$HOME_DIR/data/$SUCC"/slot-provision-*.json; do [ -f "$r" ] && { echo "$r"; python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k:d.get(k) for k in ("state","reason","manifest_path","supersedence_marker","marker_path")})' "$r"; }; done
echo "--- markers (Vernant writer):"; ls -la "$HOOKSTATE/worktree-supersedence" 2>/dev/null || echo '(none)'
for m in "$HOOKSTATE"/worktree-supersedence/*.json; do [ -f "$m" ] && python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k:d.get(k) for k in ("schema_version","carry_status","predecessor_branch","superseded_by_branch","predecessor_unmerged_count")})' "$m"; done
r13_after_carry "$SUCC_POOL"

step "where did Vernant write state? (must be under the temp case dir)"
find "$HOOKSTATE" "$DURABLE" -maxdepth 3 -type f | sed "s|$CASE_DIR|<case>|"
echo "agent launches logged by the stub backend: $(grep -c '^exec \|exec /usr/bin/env' "$LAUNCH_LOG" || true)"
