#!/usr/bin/env bash
# Independent live driver: calls the real fm_slot_provision (bin/fm-slot-provision-lib.sh) with the real
# fm_slot_run_local runner against disposable repos under a private TMPDIR. Usage: <repo-root> <scenario>
# Scenarios: differ | missing-clone | lagging-clone | copy-missing | recovery-copy-missing | stale-copy
set -u
ROOT=$1 SCEN=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-slot-drive.XXXXXX")
trap 'chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"' EXIT
export FM_REC=$LAB/executed.jsonl FM_MANIFEST=$LAB/manifest.json
g() { git -c user.name=T -c user.email=t@example.invalid "$@"; }

owner() { # <dir> <identity> [<exit>]
  mkdir -p "$1/scripts/git-stability"
  cat >"$1/scripts/git-stability/provision_existing_slot.py" <<PY
IDENTITY = "$2"
EXIT_CODE = ${3:-0}
PY
  cat >>"$1/scripts/git-stability/provision_existing_slot.py" <<'PY'
import json, os, sys
a = lambda f: sys.argv[sys.argv.index(f) + 1]
open(os.environ['FM_REC'], 'a').write(json.dumps(dict(identity=IDENTITY, argv=sys.argv)) + '\n')
if EXIT_CODE:
    print(json.dumps(dict(state='BLOCKED', reason='stale_copy_guard'))); sys.exit(EXIT_CODE)
rec = dict(worktree_path=os.path.realpath(a('--worktree-path')), owner_id=a('--owner-id'), branch=a('--branch'),
           base_sha=a('--base-sha'), owned_paths=[v for f, v in zip(sys.argv, sys.argv[1:]) if f == '--owned-path'],
           lifecycle_state='worktree_active')
open(os.environ['FM_MANIFEST'], 'w').write(json.dumps(rec))
print(json.dumps(dict(state='PASS', manifest_path=os.environ['FM_MANIFEST'], **rec)))
PY
}

git init -q --bare -b main "$LAB/origin.git"
g clone -q "$LAB/origin.git" "$LAB/project" 2>/dev/null
P=$LAB/project
echo hello >"$P/README.md"; owner "$P" A
g -C "$P" add -A; g -C "$P" commit -qm 'guard A'; g -C "$P" push -q origin main
g -C "$P" remote set-head origin main >/dev/null 2>&1 || g -C "$P" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
C="$LAB/task copy"
g -C "$P" worktree add -q -b "fm/task-1" "$C" origin/main
case "$SCEN" in
  differ|missing-clone|lagging-clone) owner "$C" B; g -C "$C" commit -qam 'task branch edits its own guard B' ;;
  stale-copy) owner "$C" B 2; g -C "$C" commit -qam 'stale rejecting guard B' ;;
  copy-missing|recovery-copy-missing) g -C "$C" rm -q scripts/git-stability/provision_existing_slot.py; g -C "$C" commit -qm 'copy lacks guard' ;;
esac
case "$SCEN" in
  missing-clone) rm "$P/scripts/git-stability/provision_existing_slot.py" ;;
  lagging-clone) owner "$P" A-local-unpushed; g -C "$P" commit -qam 'clone guard not on origin' ;;
esac
. "$ROOT/bin/fm-task-copy-lib.sh"
. "$ROOT/bin/fm-slot-provision-lib.sh"
# Set after sourcing, as bin/fm-spawn.sh does (the library resets it to 0 when sourced).
[ "$SCEN" = recovery-copy-missing ] && FM_SLOT_RECOVERY_COPY_CHECK=1
before=$(g -C "$C" rev-parse HEAD; g -C "$C" symbolic-ref -q HEAD; g -C "$C" for-each-ref)
echo "scenario=$SCEN"
echo "clone=$P"
echo "copy=$C"
rc=0
fm_slot_provision fm_slot_run_local "$P" "$C" task-1 fm/task-1 "$LAB/report" '' '' README.md scripts >"$LAB/out" 2>&1 || rc=$?
after=$(g -C "$C" rev-parse HEAD; g -C "$C" symbolic-ref -q HEAD; g -C "$C" for-each-ref)
echo "fm_slot_provision rc=$rc"
echo "--- stderr/stdout of fm_slot_provision"; sed "s#$LAB#\$LAB#g" "$LAB/out"
echo "--- execution record (which provisioner ran, with argv)"
if [ -s "$FM_REC" ]; then sed "s#$LAB#\$LAB#g" "$FM_REC"; else echo '(none ran)'; fi
echo "--- manifest written: $([ -e "$FM_MANIFEST" ] && echo yes || echo no)"
echo "--- copy HEAD/branch/refs unchanged: $([ "$before" = "$after" ] && echo yes || echo no)"
echo "--- FM_SLOT_PROVISIONED=$FM_SLOT_PROVISIONED"
