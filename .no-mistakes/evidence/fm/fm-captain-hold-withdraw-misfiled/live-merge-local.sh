#!/usr/bin/env bash
# Live drive of the local merge gate bin/fm-merge-local.sh against disposable lab homes.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M61RB5A4JCHQV6KG0QYGWHNB
cd "$WT"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
MATE=$FM_HOME
PDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); PARENT=$(bin/fm-lab-home.sh create "$PDIR")
trap 'bin/fm-lab-home.sh teardown "$MATE" >/dev/null 2>&1; rm -rf "$MATE" "$PARENT"; echo "[teardown] removed lab homes"' EXIT
for h in "$MATE" "$PARENT"; do
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$h/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"
done
echo "[setup] mate lab home: $MATE"
CH() { echo; echo "\$ fm-captain-hold.sh $*"; FM_HOME=$MATE bin/fm-captain-hold.sh "$@" 2>&1; echo "  -> exit $?"; }
ML() { echo; echo "\$ fm-merge-local.sh $1"; FM_HOME=$MATE bin/fm-merge-local.sh "$1" 2>&1 | grep -v '^fm-guard'; echo "  -> exit ${PIPESTATUS[0]}"; }
T() { (cd "$MATE" && tasks-axi "$@" --file "$MATE/data/backlog.md"); }
mkmate() { printf 'mini-id\n' > "$MATE/.fm-secondmate-home"; printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$MATE/.fm-secondmate-parent"; }
mkproj() {  # <task-id>
  local p="$MATE/projects/$1"
  git init -q -b main "$p"; git -C "$p" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m base
  git -C "$p" branch "fm/$1"; git -C "$p" checkout -q "fm/$1"
  git -C "$p" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m "ship $1"; git -C "$p" checkout -q main
  printf 'window=fm-task-%s\nproject=%s\nkind=ship\nmode=local-only\nbranch=fm/%s\n' "$1" "$p" "$1" > "$MATE/state/$1.meta"
}

echo; echo "===== M1: legacy misfiled hold classified as Main's blocks the local merge until Main decides ====="
T add ship-290 "Host hook successor watcher race" --kind ship --repo sample --body 'Ship.' >/dev/null
mkproj ship-290
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z FM_HOME=$MATE bin/fm-captain-hold.sh hold ship-290 --reason "Main180/181 reserve ask-user decisions to Main: retry or fix one red CI check" >/dev/null 2>&1
mkmate
ML ship-290
printf 'Hold reason names a Main-reserved decision.\n' > "$MATE/ev.txt"
CH classify ship-290 --owner parent --evidence-file "$MATE/ev.txt" --reason "the call was Main's"
ML ship-290
printf 'Main: one unchanged-head retry.\n' > "$MATE/dec.txt"
CH decide ship-290 --decision-file "$MATE/dec.txt"
ML ship-290

echo; echo "===== M2: a captain-owned hold still blocks the local merge; Main's decide does not open it; withdraw on a captain ruling does ====="
T add ship-cap "Captain-owned work" --kind ship --repo sample --body 'Ship.' >/dev/null
mkproj ship-cap
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z CH hold ship-cap --reason "captain picks A or B for ship-cap" --owner captain
CH decide ship-cap --decision-file "$MATE/dec.txt"
ML ship-cap
CH hold ruling-a --title "Captain ruling A covers ship-cap" --reason "ruling A decides ship-cap" --owner captain --repo sample
printf 'Ruling A: A everywhere.\n' > "$MATE/ra.txt"; CH answer ruling-a --decision-file "$MATE/ra.txt"
CH withdraw ship-cap --evidence-file "$MATE/ev.txt" --ruling ruling-a
ML ship-cap
