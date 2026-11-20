#!/usr/bin/env bash
# Usage: drive.sh <implementation-root> <scenario>
set -u
ROOT=$1 SC=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fmslot-$SC-XXXX"); W=$(cd -P "$W" && pwd -P)
g() { git -c user.name=T -c user.email=t@example.invalid "$@"; }
owner() { # <file> <identity> <exit>
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<PY
import json, os, sys
from pathlib import Path
IDENTITY = "$2"; EXIT_CODE = $3
with open(os.environ['REC'], 'a') as o:
    o.write(json.dumps(dict(identity=IDENTITY, realpath=os.path.realpath(__file__), argv=sys.argv)) + '\n')
if EXIT_CODE:
    print(json.dumps(dict(state='BLOCKED', reason='guard_' + IDENTITY + '_refused'))); sys.exit(EXIT_CODE)
a = lambda f: sys.argv[sys.argv.index(f) + 1]
r = dict(worktree_path=os.path.realpath(a('--worktree-path')), owner_id=a('--owner-id'), branch=a('--branch'),
         base_sha=a('--base-sha'), owned_paths=[v for f, v in zip(sys.argv, sys.argv[1:]) if f == '--owned-path'],
         lifecycle_state='worktree_active')
m = Path(os.environ['MAN']); m.write_text(json.dumps(r))
print(json.dumps(dict(state='PASS', manifest_path=str(m), **r)))
PY
}
P=scripts/git-stability/provision_existing_slot.py
git init -q --bare -b main "$W/origin.git"
git clone -q "$W/origin.git" "$W/seed" 2>/dev/null
echo hi > "$W/seed/README.md"
CLONE_EXIT=0; [ "$SC" = clone-refuses ] && CLONE_EXIT=3
owner "$W/seed/$P" A "$CLONE_EXIT"
g -C "$W/seed" add -A && g -C "$W/seed" commit -qm A && g -C "$W/seed" push -q origin main
git clone -q "$W/origin.git" "$W/project"
git -C "$W/project" worktree add -q -b "fm/t1" "$W/copy with space" origin/main
C="$W/copy with space"
case "$SC" in
  different) owner "$C/$P" B 0 ;;
  stale) owner "$C/$P" B 2 ;;
  clone-refuses) owner "$C/$P" B 0 ;;   # branch edits guard to always pass
  missing-clone) owner "$C/$P" B 0 ;;
  copy-missing) rm "$C/$P" ;;
  lagging-clone) owner "$C/$P" B 0 ;;
esac
if ! git -C "$C" diff --quiet HEAD || [ -n "$(git -C "$C" status --porcelain)" ]; then
  g -C "$C" add -A && g -C "$C" commit -qm 'task branch guard variant'
fi
case "$SC" in
  missing-clone) rm "$W/project/$P" ;;
  lagging-clone) printf '# local edit not on origin\n' >> "$W/project/$P" ;;
esac
export REC="$W/executed.jsonl" MAN="$W/manifest.json"
. "$ROOT/bin/fm-task-copy-lib.sh"; . "$ROOT/bin/fm-slot-provision-lib.sh"
before=$(git -C "$C" rev-parse HEAD; git -C "$C" symbolic-ref -q HEAD; git -C "$C" for-each-ref)
echo "== impl=$ROOT scenario=$SC"
echo "project=$W/project"
echo "copy=$C"
rc=0
fm_slot_provision fm_slot_run_local "$W/project" "$C" t1 fm/t1 "$W/report.json" '' '' README.md scripts 2>"$W/err" || rc=$?
after=$(git -C "$C" rev-parse HEAD; git -C "$C" symbolic-ref -q HEAD; git -C "$C" for-each-ref)
echo "exit=$rc FM_SLOT_PROVISIONED=$FM_SLOT_PROVISIONED"
echo "-- stderr:"; sed 's/^/   /' "$W/err"
echo "-- executed provisioner records:"; if [ -s "$REC" ]; then sed 's/^/   /' "$REC"; else echo "   (none ran)"; fi
echo "-- manifest written: $([ -e "$MAN" ] && echo yes || echo no)"
echo "-- copy HEAD/branch/refs unchanged: $([ "$before" = "$after" ] && echo yes || echo no)"
rm -rf "$W"
