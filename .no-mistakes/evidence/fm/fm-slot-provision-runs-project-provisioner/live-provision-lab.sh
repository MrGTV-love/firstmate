#!/usr/bin/env bash
# Independent live driver for fm_slot_provision (head vs base). It builds a disposable
# governed project inside a marked fm lab home: a bare origin, the registered clone at
# $FM_HOME/projects/demo, and one task copy (git worktree) per case. It sources the real
# library from the head worktree or from a scratch export of the base commit, and calls
# fm_slot_provision with promotion's runner fm_slot_run_local. The provisioner files are
# written here, independent of the repository's test fixtures: each appends one JSON line
# (identity, argv, realpath) to a record file, then passes or refuses.
# Usage: live-provision-lab.sh <head-root> <base-root>
set -u
HEAD_ROOT=$1
BASE_ROOT=$2
eval "$("$HEAD_ROOT/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
echo "lab FM_HOME=$LAB"
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
REC_DIR=$LAB/data/records
mkdir -p "$REC_DIR"

write_guard() { # <file> <identity> <exit-code>
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<PY
IDENTITY = "$2"
EXIT_CODE = $3
import json, os, sys
argv = sys.argv
with open(os.environ['LAB_EXEC_RECORD'], 'a') as out:
    out.write(json.dumps(dict(identity=IDENTITY, argv=argv, realpath=os.path.realpath(__file__))) + '\n')
if EXIT_CODE:
    print(json.dumps(dict(state='BLOCKED', reason='guard_' + IDENTITY + '_refused')))
    sys.exit(EXIT_CODE)
a = lambda f: argv[argv.index(f) + 1]
rec = dict(worktree_path=os.path.realpath(a('--worktree-path')), owner_id=a('--owner-id'), branch=a('--branch'),
           base_sha=a('--base-sha'), owned_paths=[v for f, v in zip(argv, argv[1:]) if f == '--owned-path'],
           lifecycle_state='worktree_active')
with open(os.environ['LAB_MANIFEST'], 'w') as m:
    json.dump(rec, m)
print(json.dumps(dict(state='PASS', manifest_path=os.environ['LAB_MANIFEST'], **rec)))
PY
}

# <case> <clone-guard: A-pass|A-refuse|missing|edited> <copy-guard: B-pass|B-stale|none>
setup_case() {
  local c=$1 cg=$2 kg=$3 d=$LAB/projects/$1
  mkdir -p "$d"
  git init -q --bare -b main "$d/origin.git"
  git clone -q "$d/origin.git" "$d/clone" 2>/dev/null
  echo readme >"$d/clone/README.md"
  case "$cg" in
    A-refuse) write_guard "$d/clone/scripts/git-stability/provision_existing_slot.py" A 2 ;;
    *) write_guard "$d/clone/scripts/git-stability/provision_existing_slot.py" A 0 ;;
  esac
  git -C "$d/clone" add -A && git -C "$d/clone" commit -qm 'guard A on main' && git -C "$d/clone" push -q origin main
  git -C "$d/clone" fetch -q origin && git -C "$d/clone" remote set-head origin main >/dev/null
  git -C "$d/clone" worktree add -q -b "fm/$c" "$d/copy $c" main
  case "$kg" in
    B-pass) write_guard "$d/copy $c/scripts/git-stability/provision_existing_slot.py" B 0 ;;
    B-stale) write_guard "$d/copy $c/scripts/git-stability/provision_existing_slot.py" B 2 ;;
    none) git -C "$d/copy $c" rm -q scripts/git-stability/provision_existing_slot.py ;;
  esac
  git -C "$d/copy $c" add -A && git -C "$d/copy $c" commit -qm "task branch guard $kg"
  case "$cg" in
    missing) rm "$d/clone/scripts/git-stability/provision_existing_slot.py" ;;
    edited) write_guard "$d/clone/scripts/git-stability/provision_existing_slot.py" A-edited 0 ;;
  esac
}

run_case() { # <root-label> <root> <case>
  local label=$1 root=$2 c=$3 d=$LAB/projects/$3 rc=0 before after
  export LAB_EXEC_RECORD=$REC_DIR/$c.$label.exec.jsonl LAB_MANIFEST=$REC_DIR/$c.$label.manifest.json
  rm -f "$LAB_EXEC_RECORD" "$LAB_MANIFEST"
  before=$(git -C "$d/copy $c" rev-parse HEAD; git -C "$d/copy $c" symbolic-ref -q HEAD; git -C "$d/copy $c" for-each-ref | md5)
  out=$(
    # shellcheck disable=SC1091
    . "$root/bin/fm-task-copy-lib.sh"; . "$root/bin/fm-slot-provision-lib.sh"
    fm_slot_provision fm_slot_run_local "$d/clone" "$d/copy $c" "$c" "fm/$c${LAB_BRANCH_SUFFIX:-}" "$REC_DIR/$c.$label.report" '' '' README.md scripts 2>&1
  ) || rc=$?
  after=$(git -C "$d/copy $c" rev-parse HEAD; git -C "$d/copy $c" symbolic-ref -q HEAD; git -C "$d/copy $c" for-each-ref | md5)
  echo "---- [$label] case=$c target_branch=fm/$c${LAB_BRANCH_SUFFIX:-} rc=$rc copy_now_on=$(git -C "$d/copy $c" branch --show-current) refs_unchanged=$([ "$before" = "$after" ] && echo yes || echo NO)"
  echo "$out" | sed 's/^/    stderr: /'
  if [ -s "$LAB_EXEC_RECORD" ]; then sed 's/^/    executed: /' "$LAB_EXEC_RECORD"; else echo "    executed: (nothing ran)"; fi
  [ -s "$LAB_MANIFEST" ] && echo "    manifest written: yes" || echo "    manifest written: no"
}

CASES=(
  "stale-copy-guard A-pass B-stale"
  "branch-edits-guard A-refuse B-pass"
  "clone-missing missing B-pass"
  "clone-edited-not-origin edited B-pass"
  "copy-missing A-pass none"
)
for spec in "${CASES[@]}"; do
  # shellcheck disable=SC2086
  set -- $spec
  echo "==== case $1: clone guard=$2, task-copy guard=$3"
  setup_case "$1" "$2" "$3"
  run_case head "$HEAD_ROOT" "$1"
  # Fresh copy state for the base run: reset the copy back onto its task branch head.
  run_case base "$BASE_ROOT" "$1"
done
echo "teardown: $HEAD_ROOT/bin/fm-lab-home.sh teardown $LAB && rm -rf $LAB"
"$HEAD_ROOT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB" && echo "lab removed"
