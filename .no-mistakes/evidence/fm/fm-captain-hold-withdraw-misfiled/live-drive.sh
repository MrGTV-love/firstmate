#!/usr/bin/env bash
# Live drive of bin/fm-captain-hold.sh against disposable lab homes (real tasks-axi).
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
echo "[setup] mate lab home: $MATE"; echo "[setup] parent lab home: $PARENT"
CH() { echo; echo "\$ fm-captain-hold.sh $*"; FM_HOME=$MATE bin/fm-captain-hold.sh "$@" 2>&1; echo "  -> exit $?"; }
T() { (cd "$MATE" && tasks-axi "$@" --file "$MATE/data/backlog.md"); }
SHOW() { echo "--- task $1:"; T show "$1" --full | (. bin/fm-hold-reason-lib.sh; fm_hold_reason_decode_stream) | sed 's/^/    /'; }
mkmate() { printf 'mini-id\n' > "$MATE/.fm-secondmate-home"; printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$MATE/.fm-secondmate-parent"; }
unmate() { rm -f "$MATE/.fm-secondmate-home" "$MATE/.fm-secondmate-parent"; }

echo; echo "===== S1: legacy PR-290 shape — a mate ship task held as a captain call before owners were recorded ====="
T add ship-290 "Host hook successor watcher race" --kind ship --repo sample --body 'Ship PR 290.' >/dev/null
unmate
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z FM_HOME=$MATE bin/fm-captain-hold.sh hold ship-290 --reason "Main180/181 reserve ask-user decisions to Main: retry or fix one red CI check" >/dev/null 2>&1; echo "legacy hold filed (main-shape) exit $?"
mkmate
CH open ship-290 --distinguish-absent
CH open ship-290 --parent-owned --distinguish-absent

echo; echo "===== S2: root cause — a mate home can no longer file a hold without saying whose call it is ====="
T add ship-new "New gated ship work" --kind ship --repo sample --body 'New work.' >/dev/null
CH hold ship-new --reason "retry or fix the red check"
CH hold ship-new --reason "retry the red check once" --owner parent
SHOW ship-new | grep -E 'held|hold_kind'

echo; echo "===== S3: Main cannot speak for the captain on the misfiled hold ====="
printf 'Main decided: retry once at unchanged head.\n' > "$MATE/main-decision.txt"
CH decide ship-290 --decision-file "$MATE/main-decision.txt"

echo; echo "===== S4: classify the legacy hold as Main's, then Main's decision releases it; work stays open ====="
printf 'Hold reason itself says Main180/181 reserve this ask to Main.\n' > "$MATE/classify-evidence.txt"
CH classify ship-290 --owner parent --evidence-file "$MATE/classify-evidence.txt" --reason "the hold reason names a Main-reserved decision"
CH open ship-290 --distinguish-absent
CH open ship-290 --parent-owned --distinguish-absent
CH open ship-290 --any-owner --distinguish-absent
CH answer ship-290 --decision-file "$MATE/main-decision.txt" --release
CH decide ship-290 --decision-file "$MATE/main-decision.txt"
CH open ship-290 --any-owner --distinguish-absent
SHOW ship-290
echo "--- parent channel ($PARENT/state/mini-id.status):"; sed 's/^/    /' "$PARENT/state/mini-id.status"
echo "--- replay decide (same file) is a no-op:"
CH decide ship-290 --decision-file "$MATE/main-decision.txt"
echo "    decided records in body: $(T show ship-290 --full | grep -c 'Resolution mode: decided')"

echo; echo "===== S5: adversarial — classify never reclassifies a recorded captain call; decide never releases it ====="
T add ship-cap "Captain-owned gated work" --kind ship --repo sample --body 'Work.' >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z CH hold ship-cap --reason "captain must pick design A or B for ship-cap" --owner captain
CH classify ship-cap --owner parent --evidence-file "$MATE/classify-evidence.txt" --reason "try to steal it"
CH decide ship-cap --decision-file "$MATE/main-decision.txt"
CH open ship-cap --distinguish-absent

echo; echo "===== S6: adversarial — withdraw refuses with no ruling, an unknown ruling, and an unrelated captain ruling ====="
printf 'Captain ruling A made this moot.\n' > "$MATE/withdraw-evidence.txt"
CH withdraw ship-cap --evidence-file "$MATE/withdraw-evidence.txt"
CH withdraw ship-cap --evidence-file "$MATE/withdraw-evidence.txt" --ruling no-such-ruling
CH hold ruling-other --title "Unrelated captain call" --reason "captain picks a colour" --owner captain --repo sample >/dev/null
printf 'Blue.\n' > "$MATE/blue.txt"; CH answer ruling-other --decision-file "$MATE/blue.txt" >/dev/null
CH withdraw ship-cap --evidence-file "$MATE/withdraw-evidence.txt" --ruling ruling-other
CH open ship-cap --distinguish-absent

echo; echo "===== S7: withdraw releases a moot captain call on a recorded captain ruling that names it; work stays open ====="
CH hold ruling-a --title "Captain ruling A (covers ship-cap)" --reason "ruling A: decides the design question in ship-cap" --owner captain --repo sample
printf 'Ruling A: use design A everywhere; ship-cap question is moot.\n' > "$MATE/ruling-a.txt"
CH answer ruling-a --decision-file "$MATE/ruling-a.txt"
CH withdraw ship-cap --evidence-file "$MATE/withdraw-evidence.txt" --ruling ruling-a
CH open ship-cap --any-owner --distinguish-absent
SHOW ship-cap
echo "--- replay withdraw:"; CH withdraw ship-cap --evidence-file "$MATE/withdraw-evidence.txt" --ruling ruling-a
echo "    withdrawn records in body: $(T show ship-cap --full | grep -c 'Resolution mode: withdrawn')"
echo "--- adversarial: re-held for a NEW captain call, the old ruling cannot release it:"
CH hold ship-cap --reason "new captain call on ship-cap after ruling A" --owner captain
CH withdraw ship-cap --evidence-file "$MATE/withdraw-evidence.txt" --ruling ruling-a
CH open ship-cap --distinguish-absent

echo; echo "===== S8: an expired dated captain hold can still be withdrawn ====="
T add ship-dated "Dated captain-held work" --kind ship --repo sample --body 'Work.' >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z CH hold ship-dated --reason "captain said revisit later" --owner captain --until 2026-02-01
SHOW ship-dated | grep -E '^ +(state|held|hold_kind|hold_until|hold_reason):'
CH open ship-dated --distinguish-absent
CH hold ruling-b --title "Captain ruling B (makes ship-dated moot)" --reason "ruling B covers ship-dated" --owner captain --repo sample >/dev/null
printf 'Ruling B: drop ship-dated question.\n' > "$MATE/ruling-b.txt"; CH answer ruling-b --decision-file "$MATE/ruling-b.txt" >/dev/null
CH withdraw ship-dated --evidence-file "$MATE/withdraw-evidence.txt" --ruling ruling-b
SHOW ship-dated | grep -E '^ +(state|held|hold_kind):'
