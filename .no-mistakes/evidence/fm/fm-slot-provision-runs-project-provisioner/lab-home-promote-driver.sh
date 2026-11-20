#!/usr/bin/env bash
# Usage: promote-lab.sh <impl-root> <scenario: different|missing-clone>
# Requires FM_HOME to be a marked lab home from bin/fm-lab-home.sh.
set -u
ROOT=$1 SC=$2 ID=lab-$2-$$
X=$(mktemp -d "${TMPDIR:-/tmp}/fmslot-promote-XXXX"); X=$(cd -P "$X" && pwd -P)
g() { git -c user.name=T -c user.email=t@example.invalid "$@"; }
owner() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<PY
import json, os, sys
from pathlib import Path
IDENTITY = "$2"
with open(os.environ['REC'], 'a') as o:
    o.write(json.dumps(dict(identity=IDENTITY, realpath=os.path.realpath(__file__), argv=sys.argv)) + '\n')
a = lambda f: sys.argv[sys.argv.index(f) + 1]
r = dict(worktree_path=os.path.realpath(a('--worktree-path')), owner_id=a('--owner-id'), branch=a('--branch'),
         base_sha=a('--base-sha'), owned_paths=[v for f, v in zip(sys.argv, sys.argv[1:]) if f == '--owned-path'],
         lifecycle_state='worktree_active')
m = Path(os.environ['MAN']); m.write_text(json.dumps(r))
print(json.dumps(dict(state='PASS', manifest_path=str(m), **r)))
PY
}
P=scripts/git-stability/provision_existing_slot.py
git init -q --bare -b main "$X/origin.git"
git clone -q "$X/origin.git" "$X/seed" 2>/dev/null
echo hi > "$X/seed/README.md"; owner "$X/seed/$P" A
g -C "$X/seed" add -A && g -C "$X/seed" commit -qm A && g -C "$X/seed" push -q origin main
PROJ="$FM_HOME/projects/demo-$ID"
git clone -q "$X/origin.git" "$PROJ"
git -C "$PROJ" remote set-head origin -a >/dev/null 2>&1
COPY="$X/copy $ID"
git -C "$PROJ" worktree add -q -b "fm/$ID" "$COPY" origin/main
owner "$COPY/$P" B; g -C "$COPY" add -A; g -C "$COPY" commit -qm 'task branch carries guard B'
[ "$SC" = missing-clone ] && rm "$PROJ/$P"
mkdir -p "$FM_HOME/data/$ID"
printf "# Task\n\n## Captain's intent\nProve slot guard source.\n\n## Firstmate spec\nLab promotion fixture.\n" > "$FM_HOME/data/$ID/brief.md"
printf 'kind=scout\nproject=%s\nworktree=%s\nwindow=firstmate:fm-%s\nbranch=fm/%s\nharness=codex\nmode=scout\nyolo=off\n' "$PROJ" "$COPY" "$ID" "$ID" > "$FM_HOME/state/$ID.meta"
export REC="$X/executed.jsonl" MAN="$X/manifest.json"
echo "== impl=$ROOT scenario=$SC task=$ID"
echo "project clone=$PROJ"; echo "task copy=$COPY"
rc=0
(cd "$ROOT" && env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  bash bin/fm-promote.sh "$ID" --mode local-only --yolo off --owned-path README.md --owned-path scripts) > "$X/out" 2>&1 || rc=$?
echo "fm-promote.sh exit=$rc"
echo "-- output:"; sed 's/^/   /' "$X/out" | cut -c1-400
echo "-- executed provisioner records:"; if [ -s "$REC" ]; then sed 's/^/   /' "$REC"; else echo "   (none ran)"; fi
echo "-- meta kind now: $(grep '^kind=' "$FM_HOME/state/$ID.meta")"
echo "-- meta slot lines: $(grep '^slot_' "$FM_HOME/state/$ID.meta" | tr '\n' ' ')"
rm -rf "$X"
