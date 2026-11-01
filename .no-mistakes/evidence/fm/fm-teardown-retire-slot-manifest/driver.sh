#!/usr/bin/env bash
# Lab driver: real bin/fm-teardown.sh + real Vernant retire_slot_manifest.py and
# provision_existing_slot.py (shallow clone of Vernant main) against disposable
# fixture repos. The forge is a stand-in gh-axi (no real PR exists for the
# fixture repo). Usage: driver.sh <src-root> <scenario> <evidence-dir>
set -u
SRC=$1 SC=$2 EV=$3
mkdir -p "$EV"
. "$SRC/tests/fm-teardown-helpers.sh"
CLONE=/tmp/fm-test-vernant-ep/repo
VENV=/tmp/fm-test-vernant-ep/venv
LOG=$EV/$SC.transcript.txt
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }

case "$SC" in
  orca-*)
    case_dir=$(make_case "lab-$SC")
    SLOT=$(cd "$case_dir/wt" && pwd -P)
    mkdir -p "$case_dir/home/state"
    fm_write_meta "$case_dir/state/task-x1.meta" \
      'window=fm-task-x1' 'endpoint_task_id=task-x1' "worktree=$SLOT" \
      "project=$case_dir/project" 'kind=ship' 'mode=no-mistakes' 'backend=orca' \
      'branch=fm/task-x1' 'spawn_gen=teardown-test-task-x1' 'terminal=fixture-terminal' \
      "orca_worktree_id=$case_dir/project::$SLOT"
    printf '#!/usr/bin/env bash\nprintf '\''{"ok":true}\\n'\''\n' > "$case_dir/fakebin/orca"
    chmod +x "$case_dir/fakebin/orca"
    ;;
  *)
    make_nested_slot_case "lab-$SC" slot .claude/worktrees/x
    case_dir=$NESTED_CASE
    SLOT=$NESTED_SLOT
    ;;
esac
P=$case_dir/project
common=$(git -C "$SLOT" rev-parse --path-format=absolute --git-common-dir)
printf '.claude/\n' >> "$common/info/exclude"
# A tracked scope for the provisioner, landed on origin/main.
mkdir -p "$P/owned"; printf 'owned\n' > "$P/owned/keep.txt"
git -C "$P" add owned/keep.txt
git -C "$P" -c user.email=t@t -c user.name=t commit -qm 'owned scope'
git -C "$P" push -q origin main
git -C "$SLOT" fetch -q origin
git -C "$SLOT" reset -q --hard origin/main
# Vernant tooling: project/scripts -> real Vernant scripts, project/.venv -> venv with pydantic.
if [ "$SC" = absent ]; then
  mkdir -p "$P/scripts/git-stability"
  ln -s "$CLONE/scripts/git-stability/provision_existing_slot.py" "$P/scripts/git-stability/provision_existing_slot.py"
else
  ln -s "$CLONE/scripts" "$P/scripts"
fi
ln -s "$VENV" "$P/.venv"
records=$case_dir/lifecycle
mkdir -p "$records" "$case_dir/tmpdir"
export CODEX_HOOK_STATE_DIR=$records WORKTREE_LIFECYCLE_STORE_DIR=$common/vernant-worktree-lifecycle
provision() {  # <owner> [branch]
  "$VENV/bin/python" "$CLONE/scripts/git-stability/provision_existing_slot.py" \
    --repo-root "$P" --worktree-path "$SLOT" --owner-id "$1" --branch "${2:-fm/task-x1}" \
    --base-sha "$(git -C "$SLOT" merge-base origin/main HEAD)" --owned-path owned
}
owner=task-x1
[ "$SC" != owner-mismatch ] || owner=other-owner
say "== provision slot $SLOT for owner $owner (real Vernant provisioner)"
provision "$owner" >> "$LOG" 2>&1; say "provision rc=$?"
digest=$(printf '%s' "$SLOT" | shasum -a 256 | cut -c1-16)
DUR=$WORKTREE_LIFECYCLE_STORE_DIR/$digest.json LEG=$records/worktree-lifecycle/$digest.json
say "records before: durable=$( [ -e "$DUR" ] && echo present || echo absent ) legacy=$( [ -e "$LEG" ] && echo present || echo absent )"
say "== provision again before teardown (expect manifest_exists)"
provision task-next >> "$LOG" 2>&1; say "second provision rc=$?"

head=$(git -C "$SLOT" rev-parse HEAD)
git -C "$P" -c user.email=t@t -c user.name=t commit --allow-empty -qm fixture-merge
merge=$(git -C "$P" rev-parse HEAD)
[ "$SC" = no-pr ] || printf 'pr=https://github.com/test/vernant/pull/42\n' >> "$case_dir/state/task-x1.meta"
cat > "$case_dir/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$case_dir/gh-axi.log'
printf 'branch: fm/task-x1\nhead: $head\nmerge: $merge\nmerged: true\n'
SH
chmod +x "$case_dir/fakebin/gh-axi"
seed_backlog_in_flight "$case_dir"
say "== run real bin/fm-teardown.sh task-x1 ($SRC)"
rc=0
TMPDIR=$case_dir/tmpdir FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/out" 2> "$case_dir/err" || rc=$?
say "teardown rc=$rc"
say "--- teardown stdout (lifecycle lines)"; grep -E 'lifecycle|stayed|entry point|retire|refused|next_step|reason' "$case_dir/out" | tee -a "$LOG"
say "--- teardown stderr (tail)"; tail -n 8 "$case_dir/err" | tee -a "$LOG"
say "records after: durable=$( [ -e "$DUR" ] && echo present || echo absent ) legacy=$( [ -e "$LEG" ] && echo present || echo absent )"
say "retired archive files:"; find "$WORKTREE_LIFECYCLE_STORE_DIR/retired" -type f 2>/dev/null | tee -a "$LOG"
for f in $(find "$WORKTREE_LIFECYCLE_STORE_DIR/retired" -type f 2>/dev/null); do jq -c '.proofs' "$f" | tee -a "$LOG"; done
if git -C "$P" show-ref --verify --quiet refs/heads/fm/task-x1; then say "branch fm/task-x1: still exists"; else say "branch fm/task-x1: deleted"; fi
say "leftover proof files in TMPDIR: $(ls "$case_dir/tmpdir" | grep -c fm-slot-proof || true)"
say "forge calls: $(grep -c '^api ' "$case_dir/gh-axi.log" 2>/dev/null || echo 0)"
say "== next worker provisions the slot on a new branch (real Vernant provisioner)"
git -C "$SLOT" checkout -q -B fm/task-next origin/main >> "$LOG" 2>&1 || say "slot checkout failed"
provision task-next fm/task-next >> "$LOG" 2>&1; say "next-worker provision rc=$?"
