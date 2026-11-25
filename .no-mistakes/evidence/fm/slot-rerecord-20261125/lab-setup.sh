#!/usr/bin/env bash
# Build a disposable governed ship task "rrt" inside the lab home $FM_HOME (fixture F shape).
set -eu
W=$1   # worktree root (firstmate checkout)
L=$FM_HOME/projects
id=rrt
mkdir -p "$L"
git init -q --bare -b main "$L/origin.git"
git init -q -b main "$L/proj"
P=$L/proj
g() { git -C "$1" -c user.name=Lab -c user.email=lab@example.invalid "${@:2}"; }
mkdir -p "$P/src" "$P/scripts/git-stability"
printf 'owned\n' > "$P/src/owned.txt"; printf 'docs\n' > "$P/docs.txt"
# the project's own provisioner (fixture provisioner from tests/fm-control-relaunch-slot-helpers.sh)
. "$W/tests/fm-control-relaunch-slot-helpers.sh"
write_fixture_provisioner "$P"
g "$P" add -A; g "$P" commit -qm 'M0 project with provisioner'
g "$P" remote add origin "$L/origin.git"; g "$P" push -q origin HEAD:main; g "$P" fetch -q origin
g "$P" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
M0=$(g "$P" rev-parse HEAD)
g "$P" worktree add -q -b "fm/$id" "$L/wt" "$M0"
WT=$L/wt
mkdir -p "$L/manifests"; MAN=$L/manifests/manifest.json; SENT=$L/provisioner.called; : > "$SENT"
FM_TEST_PROVISION_CALLED=$SENT FM_TEST_SLOT_RECORD=$MAN python3 "$WT/scripts/git-stability/provision_existing_slot.py" \
  --repo-root "$P" --worktree-path "$WT" --owner-id "$id" --branch "fm/$id" --base-sha "$M0" --owned-path src >/dev/null
mkdir -p "$FM_HOME/data/$id"
printf '# Task\n## Captain'"'"'s intent\nLab task for rerecord-slot.\n\n## Firstmate spec\nKeep the copy.\n' > "$FM_HOME/data/$id/brief.md"
cat > "$FM_HOME/state/$id.meta" <<META
window=fmlab:fm-$id
endpoint_task_id=$id
worktree=$WT
project=$P
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$id
model=default
effort=default
branch=fm/$id
slot_manifest=$MAN
slot_base_sha=$M0
slot_owned_path=src
META
# main moves forward (M1)
mkdir -p "$P/lib" "$P/tools/sub"
printf 'docs-at-m1\n' > "$P/docs.txt"; printf 'a\n' > "$P/lib/a.py"; printf 'x\n' > "$P/tools/x.sh"
printf 'y\n' > "$P/tools/y.sh"; printf 'z\n' > "$P/tools/sub/z.sh"; printf 'other\n' > "$P/src/other.txt"
g "$P" add -A; g "$P" commit -qm 'main M1'; g "$P" push -q origin HEAD:main; g "$P" fetch -q origin
M1=$(g "$P" rev-parse HEAD)
# the branch: own change, merge main, new lib file and tools change
printf 'owned-by-k\n' > "$WT/src/owned.txt"; g "$WT" add -A; g "$WT" commit -qm 'own change K'
g "$WT" merge -q --no-edit refs/remotes/origin/main
printf 'new\n' > "$WT/lib/new.py"; printf 'x-changed\n' > "$WT/tools/x.sh"; g "$WT" add -A; g "$WT" commit -qm 'new lib file and tools change'
H=$(g "$WT" rev-parse HEAD)
printf 'M0=%s\nM1=%s\nH=%s\nP=%s\nWT=%s\nMAN=%s\nSENT=%s\n' "$M0" "$M1" "$H" "$P" "$WT" "$MAN" "$SENT" > "$L/ids.env"
cat "$L/ids.env"
