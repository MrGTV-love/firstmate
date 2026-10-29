#!/usr/bin/env bash
# Live driver: real bin/fm-promote.sh against a disposable marked lab home and
# a throwaway governed git project (bare origin + pool copy worktree). The
# project's provisioner is a disposable project-owned script; Firstmate code is
# the real product. Usage: promote-live-driver.sh <worktree-root>
set -u
ROOT=$1
PROMOTE="$ROOT/bin/fm-promote.sh"
eval "$("$ROOT/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
echo "lab FM_HOME=$LAB"
G=(-c user.name=Lab -c user.email=lab@example.invalid)
PASSES=0; FAILS=0
ok() { echo "PASS: $*"; PASSES=$((PASSES+1)); }
bad() { echo "FAIL: $*"; FAILS=$((FAILS+1)); }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

# <name> <provisioner-body-python> -> sets PROJ SLOT ID
setup() {
  local name=$1 body=$2
  ID="live-$name-$$"
  PROJ="$LAB/projects/$name"
  SLOT="$LAB/projects/$name-slot"
  git init -q -b main "$PROJ"
  git -C "$PROJ" "${G[@]}" commit -q --allow-empty -m init
  git init -q --bare "$LAB/projects/$name.origin.git"
  git -C "$PROJ" remote add origin "$LAB/projects/$name.origin.git"
  mkdir -p "$PROJ/scripts/git-stability"
  printf 'import json, os, subprocess, sys\narg = lambda f: sys.argv[sys.argv.index(f) + 1]\n%s\n' "$body" \
    > "$PROJ/scripts/git-stability/provision_existing_slot.py"
  git -C "$PROJ" add scripts
  git -C "$PROJ" "${G[@]}" commit -qm 'governed provisioner'
  git -C "$PROJ" push -q origin main
  git -C "$PROJ" fetch -q origin
  git -C "$PROJ" worktree add -q -b scout-work "$SLOT" main
  mkdir -p "$LAB/data/$ID"
  printf "You are a crewmate.\n\n# Task\n## Captain's intent\nExercise governed promotion.\n\n## Firstmate spec\nVerify promotion rollback.\n\n# Definition of done\n" > "$LAB/data/$ID/brief.md"
  printf 'kind=scout\nproject=%s\nworktree=%s\nwindow=fm-%s\nslot_owned_path=scripts\n' "$PROJ" "$SLOT" "$ID" > "$LAB/state/$ID.meta"
}
promote() { FM_HOME="$LAB" bash "$PROMOTE" "$ID" --mode local-only --yolo off 2>&1; }
refs() { echo "--- refs/HEAD in $SLOT:"; git -C "$SLOT" for-each-ref --format='%(refname) %(objectname:short)' refs/heads; echo "HEAD=$(git -C "$SLOT" rev-parse --short HEAD) symbolic=$(git -C "$SLOT" symbolic-ref -q HEAD || echo DETACHED)"; }

BLOCKED='print(json.dumps({"state": "BLOCKED", "reason": "manifest_live_owner", "blocked_reasons": ["manifest_live_owner"]})); sys.exit(2)'
PASSBODY='rec = dict(worktree_path=os.path.realpath(arg("--worktree-path")), owner_id=arg("--owner-id"), branch=arg("--branch"), base_sha=arg("--base-sha"), owned_paths=[v.rstrip("/") for f, v in zip(sys.argv, sys.argv[1:]) if f == "--owned-path"], lifecycle_state="worktree_active")
m = os.path.join(os.path.dirname(os.path.realpath(arg("--worktree-path"))), os.path.basename(arg("--worktree-path")) + ".manifest.json")
open(m, "w").write(json.dumps(rec, indent=1))
print(json.dumps(dict(state="PASS", manifest_path=m, **rec)))'

echo; echo "===== S1 named scout: refusal -> scout commits -> retry reaches owner"
setup named "$BLOCKED"
orig=$(git -C "$SLOT" rev-parse HEAD)
out=$(promote); rc=$?; echo "$out"; echo "exit=$rc"; refs
check '[ $rc -ne 0 ]' 'S1 first promote refused (nonzero exit)'
check 'grep -q manifest_live_owner <<<"$out"' 'S1 refusal shows project reason'
check '! git -C "$SLOT" rev-parse -q --verify "refs/heads/fm/$ID" >/dev/null' 'S1 own alias fm/<id> removed'
check '[ "$(git -C "$SLOT" symbolic-ref -q HEAD)" = refs/heads/scout-work ] && [ "$(git -C "$SLOT" rev-parse HEAD)" = "$orig" ]' 'S1 scout back on scout-work at original commit'
check 'grep -qx kind=scout "$LAB/state/$ID.meta" && [ ! -e "$LAB/data/$ID/ship-instructions.md" ]' 'S1 meta still scout, no ship instructions'
echo work > "$SLOT/w.txt"; git -C "$SLOT" add w.txt; git -C "$SLOT" "${G[@]}" commit -qm 'scout work'; adv=$(git -C "$SLOT" rev-parse HEAD)
out=$(promote); rc=$?; echo "$out"; echo "exit=$rc"; refs
check '! grep -q "is not at the assigned copy" <<<"$out" && grep -q manifest_live_owner <<<"$out"' 'S1 retry not blocked; reaches project owner'
check '[ "$(git -C "$SLOT" rev-parse refs/heads/scout-work)" = "$adv" ] && [ "$(git -C "$SLOT" rev-parse "$adv^")" = "$orig" ]' 'S1 advanced and original commits kept'

echo; echo "===== S2 detached scout: refusal -> detached commit -> retry"
setup detached "$BLOCKED"
git -C "$SLOT" checkout -q --detach; git -C "$SLOT" branch -D -q scout-work
orig=$(git -C "$SLOT" rev-parse HEAD)
out=$(promote); rc=$?; echo "$out"; echo "exit=$rc"; refs
check '[ $rc -ne 0 ] && ! grep -q "preserving task branch" <<<"$out"' 'S2 refused, no preserve warning (alias proved unused)'
check '! git -C "$SLOT" symbolic-ref -q HEAD >/dev/null && [ "$(git -C "$SLOT" rev-parse HEAD)" = "$orig" ]' 'S2 copy restored detached at exact original commit'
check '! git -C "$SLOT" rev-parse -q --verify "refs/heads/fm/$ID" >/dev/null' 'S2 own alias removed'
echo work > "$SLOT/w.txt"; git -C "$SLOT" add w.txt; git -C "$SLOT" "${G[@]}" commit -qm 'detached work'; adv=$(git -C "$SLOT" rev-parse HEAD)
out=$(promote); rc=$?; echo "$out"; echo "exit=$rc"; refs
check '! grep -q "is not at the assigned copy" <<<"$out" && grep -q manifest_live_owner <<<"$out"' 'S2 retry not blocked; reaches project owner'
check '[ "$(git -C "$SLOT" rev-parse HEAD)" = "$adv" ] && [ "$(git -C "$SLOT" rev-parse "$adv^")" = "$orig" ]' 'S2 detached work and original commit kept'

echo; echo "===== S3 project-declared alias: PASS manifest, scripts/ vs scripts mismatch"
setup declared "$PASSBODY"
printf 'kind=scout\nproject=%s\nworktree=%s\nwindow=fm-%s\nslot_owned_path=scripts/\n' "$PROJ" "$SLOT" "$ID" > "$LAB/state/$ID.meta"
out=$(promote); rc=$?; echo "$out"; echo "exit=$rc"; refs
man="$SLOT.manifest.json"; echo "--- manifest:"; cat "$man"; echo
check '[ $rc -ne 0 ] && grep -q "identity mismatch: owned_paths" <<<"$out"' 'S3 attestation still refuses the mismatch'
check 'grep -q "preserving task branch fm/$ID created by this refused promotion: the project report may declare it" <<<"$out"' 'S3 warns it preserves declared alias'
check 'git -C "$SLOT" rev-parse -q --verify "refs/heads/fm/$ID" >/dev/null' 'S3 declared alias kept'
check 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(d[\"branch\"]!=sys.argv[2])" "$man" "fm/$ID"' 'S3 project manifest untouched, still names fm/<id>'
check 'grep -qx kind=scout "$LAB/state/$ID.meta" && grep -qx slot_owned_path=scripts/ "$LAB/state/$ID.meta"' 'S3 meta scope not normalized/rewritten'

echo; echo "===== S4 adversarial: pre-existing fm/<id> branch survives refusal"
setup existing "$BLOCKED"
git -C "$SLOT" branch "fm/$ID"; h=$(git -C "$SLOT" rev-parse HEAD)
out=$(promote); rc=$?; echo "$out"; echo "exit=$rc"; refs
check '[ $rc -ne 0 ] && [ "$(git -C "$SLOT" rev-parse -q --verify "refs/heads/fm/$ID")" = "$h" ]' 'S4 pre-existing branch kept'

echo; echo "===== S5 adversarial: provisioner commits on the alias, then refuses"
setup moved 'subprocess.run(["git", "-C", arg("--worktree-path"), "-c", "user.name=P", "-c", "user.email=p@example.invalid", "commit", "-q", "--allow-empty", "-m", "owner work"], check=True)
'"$BLOCKED"
h=$(git -C "$SLOT" rev-parse HEAD)
out=$(promote); rc=$?; echo "$out"; echo "exit=$rc"; refs
check 'grep -q "preserving task branch fm/$ID created by this refused promotion: fm/$ID moved from" <<<"$out"' 'S5 warns moved branch preserved'
check 'm=$(git -C "$SLOT" rev-parse -q --verify "refs/heads/fm/$ID") && [ "$(git -C "$SLOT" rev-parse "$m^")" = "$h" ]' 'S5 branch with new work kept'

echo; echo "===== S6 adversarial: BLOCKED report that names a manifest_path"
setup blockedman 'print(json.dumps({"state": "BLOCKED", "reason": "x", "manifest_path": "/nonexistent"})); sys.exit(2)'
out=$(promote); rc=$?; echo "$out"; echo "exit=$rc"; refs
check '[ $rc -ne 0 ] && git -C "$SLOT" rev-parse -q --verify "refs/heads/fm/$ID" >/dev/null && grep -q "may declare it" <<<"$out"' 'S6 alias kept when report names a manifest'

echo; echo "===== S7 adversarial: provisioner prints non-JSON and refuses"
setup garbage 'print("Traceback: boom"); sys.exit(1)'
out=$(promote); rc=$?; echo "$out"; echo "exit=$rc"; refs
check '[ $rc -ne 0 ] && git -C "$SLOT" rev-parse -q --verify "refs/heads/fm/$ID" >/dev/null && grep -q "may declare it" <<<"$out"' 'S7 unreadable report -> alias preserved with warning'

echo; echo "===== S8 happy path: matching PASS attestation promotes and keeps fm/<id>"
setup happy "$PASSBODY"
out=$(promote); rc=$?; echo "$out" | tail -n 15; echo "exit=$rc"; refs
check '[ $rc -eq 0 ] && grep -qx kind=ship "$LAB/state/$ID.meta" && [ -s "$LAB/data/$ID/ship-instructions.md" ]' 'S8 promotion admitted: kind=ship and ship instructions written'
check '[ "$(git -C "$SLOT" symbolic-ref -q HEAD)" = "refs/heads/fm/$ID" ]' 'S8 copy on fm/<id> task branch'

echo; echo "TOTAL pass=$PASSES fail=$FAILS"
"$ROOT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB" && echo "lab torn down: $LAB"
[ "$FAILS" -eq 0 ]
