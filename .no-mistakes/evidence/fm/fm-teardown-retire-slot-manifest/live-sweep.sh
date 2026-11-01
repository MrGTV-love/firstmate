#!/usr/bin/env bash
# Live sweep scenario: bin/fm-slot-manifest-retire.py report and --apply
# against real Vernant records in the lab's no-pr case project, with real
# tasks-axi Done entries in the lab home and the real gh-axi forge.
set -u
export GIT_LFS_SKIP_SMUDGE=1
PY=/Users/charlesabrooker/.pyenv/versions/3.13.6/bin/python3
WT_SRC=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6C0WGNFXK2DZK9NKWQY60WM
PR_URL=https://github.com/MrGTV-love/vernant/pull/3537
: "${FM_HOME:?}" "${LAB_ROOT:?}"
C=$LAB_ROOT/no-pr
P=$C/project
COMMON=$(git -C "$P" rev-parse --path-format=absolute --git-common-dir)
export CODEX_HOOK_STATE_DIR="$C/hooks" WORKTREE_LIFECYCLE_STORE_DIR="$COMMON/vernant-worktree-lifecycle"
B=$FM_HOME/data/backlog.md
say() { printf '\n$ %s\n' "$*"; }

slot() {  # <n> <owner> <branch>
  local s
  git -C "$P" worktree add -q -b "$3" "$C/pool/$1/project" main
  s=$(cd "$C/pool/$1/project" && pwd -P)
  (cd "$s" && "$PY" scripts/git-stability/provision_existing_slot.py --repo-root "$s" --worktree-path "$s" \
     --owner-id "$2" --branch "$3" --base-sha "$(git -C "$s" merge-base origin/main HEAD)" --owned-path scripts) \
     | grep -E '"(state|owner_id|reason)"' >&2
  printf '%s' "$s" | shasum -a 256 | cut -c1-16
}

say "setup: real Vernant records for three more owners in project $P"
D_DONE=$(slot 2 lab-sweep-done fm/guard-audit-current | tail -1)
D_UNKNOWN=$(slot 3 lab-sweep-unknown fm/lab-sweep-unknown | tail -1)
for t in lab-sweep-done lab-sweep-disagree; do
  tasks-axi add "$t" "lab sweep owner $t" --kind ship --file "$B" >/dev/null
  tasks-axi start "$t" --file "$B" >/dev/null
  tasks-axi done "$t" --pr "$PR_URL" --file "$B" >/dev/null
done
say "bin/fm-tasks-axi.sh show lab-sweep-done (lab backlog Done entry)"
"$WT_SRC/bin/fm-tasks-axi.sh" show lab-sweep-done

snapshot() { (cd "$WORKTREE_LIFECYCLE_STORE_DIR" && shasum *.json; cd "$C/hooks/worktree-lifecycle" && shasum *.json) 2>/dev/null; }

say "store snapshot before report"
snapshot | tee "$C/snap-before"
say "python3 bin/fm-slot-manifest-retire.py --project <P> --firstmate-state \$FM_HOME/state   (report only)"
"$PY" "$WT_SRC/bin/fm-slot-manifest-retire.py" --project "$P" --firstmate-state "$FM_HOME/state"
echo "report exit=$?"
snapshot > "$C/snap-after-report"
if cmp -s "$C/snap-before" "$C/snap-after-report"; then echo "report changed nothing: store bytes identical"; else echo "REPORT CHANGED STORES"; fi

say "python3 bin/fm-slot-manifest-retire.py --project <P> --firstmate-state \$FM_HOME/state --apply"
"$PY" "$WT_SRC/bin/fm-slot-manifest-retire.py" --project "$P" --firstmate-state "$FM_HOME/state" --apply
echo "apply exit=$?"
say "store snapshot after apply"
snapshot
for d in "$D_DONE" "$D_UNKNOWN"; do
  for f in "$WORKTREE_LIFECYCLE_STORE_DIR/$d.json" "$C/hooks/worktree-lifecycle/$d.json"; do
    if [ -e "$f" ]; then echo "PRESENT $f"; else echo "ABSENT  $f"; fi
  done
done

say "adversarial: owner lab-sweep-disagree is Done with merged PR, but its two copies disagree"
say "slot 2 handed back: detach and delete its branch, as teardown does"
git -C "$C/pool/2/project" checkout -q --detach && git -C "$P" branch -D fm/guard-audit-current
D_DIS=$(slot 4 lab-sweep-disagree fm/guard-audit-current | tail -1)
"$PY" - "$C/hooks/worktree-lifecycle/$D_DIS.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p)); d["owned_paths"] = ["docs"]; json.dump(d, open(p, "w"))
PY
before=$(grep -c '"teardown-unlanded"' "$FM_HOME/state/guard-events.jsonl" 2>/dev/null || echo 0)
"$PY" "$WT_SRC/bin/fm-slot-manifest-retire.py" --project "$P" --firstmate-state "$FM_HOME/state" --apply
echo "apply exit=$?"
after=$(grep -c '"teardown-unlanded"' "$FM_HOME/state/guard-events.jsonl" 2>/dev/null || echo 0)
echo "teardown-unlanded events: before=$before after=$after"
for f in "$WORKTREE_LIFECYCLE_STORE_DIR/$D_DIS.json" "$C/hooks/worktree-lifecycle/$D_DIS.json"; do
  if [ -e "$f" ]; then echo "PRESENT $f"; else echo "ABSENT  $f"; fi
done

say "sweep on the refused case project: owner lab-refused still has a live .meta"
C2=$LAB_ROOT/refused
COMMON2=$(git -C "$C2/project" rev-parse --path-format=absolute --git-common-dir)
CODEX_HOOK_STATE_DIR="$C2/hooks" WORKTREE_LIFECYCLE_STORE_DIR="$COMMON2/vernant-worktree-lifecycle" \
  "$PY" "$WT_SRC/bin/fm-slot-manifest-retire.py" --project "$C2/project" --firstmate-state "$FM_HOME/state" --apply
echo "apply exit=$?"
