#!/usr/bin/env bash
# Live lab driver for fm-teardown-retire-slot-manifest.
# Real: bin/fm-teardown.sh, bin/fm-slot-manifest-retire.py, Vernant's own
# provision_existing_slot.py and retire_slot_manifest.py (from a disposable
# shared clone of the operator Vernant clone's origin/main), real gh-axi forge
# reads of a real merged Vernant PR (#3537), real git, real tmux on a private
# socket dir, real tasks-axi on the lab backlog.
# Stubbed: treehouse (the external pool manager; logs and succeeds) and
# no-mistakes (empty status so teardown never touches the real daemon).
# Usage: live-lab.sh <scenario> ; must run with FM_HOME/TMUX_TMPDIR from
# bin/fm-lab-home.sh env exported, and LAB_ROOT pointing at a disposable dir.
set -u
export GIT_LFS_SKIP_SMUDGE=1
PY=/Users/charlesabrooker/.pyenv/versions/3.13.6/bin/python3   # pyenv picks a pydantic-less Python inside the Vernant tree
WT_SRC=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6C0WGNFXK2DZK9NKWQY60WM
V=/Users/charlesabrooker/firstmate/projects/vernant
PR_URL=https://github.com/MrGTV-love/vernant/pull/3537
PR_BRANCH=fm/guard-audit-current
STALE=741533fba~1   # Vernant main just before PR 3592 added retire_slot_manifest.py
: "${FM_HOME:?}" "${TMUX_TMPDIR:?}" "${LAB_ROOT:?}"

say() { printf '\n$ %s\n' "$*"; }

origin_once() {
  [ -d "$LAB_ROOT/origin.git" ] && return 0
  git clone -q --bare --shared "$V" "$LAB_ROOT/origin.git"
  git -C "$LAB_ROOT/origin.git" fetch -q "$V" "+refs/remotes/origin/main:refs/heads/main"
  git -C "$LAB_ROOT/origin.git" symbolic-ref HEAD refs/heads/main
  mkdir -p "$LAB_ROOT/stub"
  cat > "$LAB_ROOT/stub/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in pool-dir|status) exit 0 ;; esac
printf 'treehouse %s\n' "\$*" >> "$LAB_ROOT/treehouse.log"
exit 0
SH
  cat > "$LAB_ROOT/stub/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$LAB_ROOT/stub/treehouse" "$LAB_ROOT/stub/no-mistakes"
}

# make_case <name> <task-id> <project-rev> <slot-rev> <record-owner> <record-branch> <with-pr:0|1>
make_case() {
  local name=$1 id=$2 prev=$3 srev=$4 owner=$5 rbranch=$6 withpr=$7 c
  c="$LAB_ROOT/$name"
  CASE=$c; TASK=$id
  git clone -q --shared "$LAB_ROOT/origin.git" "$c/project"
  git -C "$c/project" checkout -q --detach "$prev"
  mkdir -p "$c/pool/1" "$c/hooks"
  git -C "$c/project" worktree add -q -b "$PR_BRANCH" "$c/pool/1/project" "$srev"
  SLOT=$(cd "$c/pool/1/project" && pwd -P)
  COMMON=$(git -C "$c/project" rev-parse --path-format=absolute --git-common-dir)
  export CODEX_HOOK_STATE_DIR="$c/hooks" WORKTREE_LIFECYCLE_STORE_DIR="$COMMON/vernant-worktree-lifecycle"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"%s"}]}\n' "$SLOT" "$id" > "$c/pool/treehouse-state.json"
  printf 'task=%s\nhome=%s\n' "$id" "$FM_HOME" > "$c/pool/1/.fm-slot-owner"
  # A real Vernant provisioner writes the slot record (needs the slot's own copy).
  say "Vernant provision_existing_slot.py (slot copy) for owner=$owner branch=$rbranch"
  (cd "$SLOT" && "$PY" scripts/git-stability/provision_existing_slot.py --repo-root "$SLOT" \
     --worktree-path "$SLOT" --owner-id "$owner" --branch "$rbranch" \
     --base-sha "$(git -C "$SLOT" merge-base origin/main HEAD)" --owned-path scripts)
  DIGEST=$(printf '%s' "$SLOT" | shasum -a 256 | cut -c1-16)
  DURABLE="$WORKTREE_LIFECYCLE_STORE_DIR/$DIGEST.json"; LEGACY="$c/hooks/worktree-lifecycle/$DIGEST.json"
  mkdir -p "$FM_HOME/state" "$FM_HOME/data"
  touch "$FM_HOME/state/.last-watcher-beat"
  {
    printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$SLOT" \
      "branch=$PR_BRANCH" "project=$c/project" "kind=ship" "mode=no-mistakes" "spawn_gen=lab-$id"
    [ "$withpr" = 0 ] || printf 'pr=%s\n' "$PR_URL"
  } > "$FM_HOME/state/$id.meta"
  printf 'lab task\n' > "$FM_HOME/state/$id.status"
  [ -f "$FM_HOME/data/backlog.md" ] || printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$FM_HOME/data/backlog.md"
  tasks-axi add "$id" "lab task $id" --kind ship --file "$FM_HOME/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$FM_HOME/data/backlog.md" >/dev/null
  tmux has-session -t firstmate 2>/dev/null || tmux new-session -d -s firstmate -n keep 'sleep 3600'
  tmux new-window -d -t firstmate -n "fm-$id" 'sleep 3600'
}

records() {
  local p
  for p in "$DURABLE" "$LEGACY"; do
    if [ -e "$p" ]; then echo "PRESENT $p"; else echo "ABSENT  $p"; fi
  done
}

branch_state() {
  if git -C "$CASE/project" show-ref --verify --quiet "refs/heads/$PR_BRANCH"; then
    echo "branch $PR_BRANCH: EXISTS"
  else
    echo "branch $PR_BRANCH: DELETED"
  fi
}

teardown() {
  say "bin/fm-teardown.sh $TASK   (FM_HOME=lab)"
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u TMUX \
    NM_HOME="$CASE/nm" PATH="$LAB_ROOT/stub:$PATH" \
    "$WT_SRC/bin/fm-teardown.sh" "$TASK" 2>&1
  echo "teardown exit=$?"
}

events() {
  local n
  n=$(grep -c '"teardown-unlanded"' "$FM_HOME/state/guard-events.jsonl" 2>/dev/null || true)
  echo "teardown-unlanded events in lab guard log: ${n:-0}"
}

reprovision() {
  # Note: live-landed.txt was captured before this fix; there the next worker reused the
  # deleted task branch (branch_mismatch). live-landed-next-worker.txt is the real proof.
  say "next worker: Vernant provision_existing_slot.py into the same slot (owner=next-worker)"
  git -C "$SLOT" checkout -q -B fm/next-worker 2>/dev/null
  (cd "$SLOT" && "$PY" scripts/git-stability/provision_existing_slot.py --repo-root "$SLOT" \
     --worktree-path "$SLOT" --owner-id next-worker --branch fm/next-worker \
     --base-sha "$(git -C "$SLOT" merge-base origin/main HEAD)" --owned-path scripts)
  echo "provision exit=$?"
}

origin_once
case "${1:?scenario}" in
  landed)
    make_case landed lab-landed main main lab-landed "$PR_BRANCH" 1
    say "before: records"; records; reprovision
    teardown; say "after: records"; records; branch_state
    say "Vernant retired archive"; find "$(dirname "$DURABLE")/retired" -name '*.json' 2>/dev/null | head
    events; reprovision; say "after re-provision"; records ;;
  refused)
    make_case refused lab-refused main main someone-else "$PR_BRANCH" 1
    teardown; say "after: records"; records; branch_state; events ;;
  no-pr)
    make_case no-pr lab-nopr main main lab-nopr "$PR_BRANCH" 0
    teardown; say "after: records"; records; branch_state; events ;;
  slot-copy)
    make_case slot-copy lab-slotcopy "$STALE" main lab-slotcopy "$PR_BRANCH" 1
    say "project checkout entry point"; ls "$CASE/project/scripts/git-stability/retire_slot_manifest.py" 2>&1
    say "slot copy entry point"; ls "$SLOT/scripts/git-stability/retire_slot_manifest.py"
    teardown; say "after: records"; records; branch_state ;;
  absent)
    make_case absent lab-absent "$STALE" "$STALE" lab-absent "$PR_BRANCH" 1
    say "entry point in project / slot"; ls "$CASE/project/scripts/git-stability/retire_slot_manifest.py" "$SLOT/scripts/git-stability/retire_slot_manifest.py" 2>&1
    teardown; say "after: records"; records; branch_state ;;
  *) echo "unknown scenario" >&2; exit 2 ;;
esac
