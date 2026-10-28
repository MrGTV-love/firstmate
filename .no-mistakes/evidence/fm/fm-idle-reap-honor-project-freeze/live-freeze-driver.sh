#!/usr/bin/env bash
# Live driver: real bin/fm-idle-session-reap.sh, real bin/fm-captain-hold.sh,
# real tasks-axi, and the real bin/fm-teardown.sh (no stub), against disposable
# marked lab homes. Usage: live-freeze-driver.sh <worktree> <base-bin-dir>
set -u
WT=$1
BASE_BIN=$2
H="$WT/bin/fm-captain-hold.sh"
REAP="$WT/bin/fm-idle-session-reap.sh"
NOW=$(date +%s)
OLD=$((NOW - 7200))
PR=https://github.com/acme/widget/pull/41

say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }

touch_old() { TZ=UTC0 touch -t "$(TZ=UTC0 date -r "$OLD" +%Y%m%d%H%M.%S)" "$@"; }

prep_home() {  # <home>
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$1/.tasks.toml"
}

mk_task() {  # <home> <id> <project-name> [kind]
  local home=$1 id=$2 proj=$3 kind=${4:-ship}
  mkdir -p "$home/projects/$proj"
  [ -d "$home/projects/$proj/.git" ] || git -C "$home/projects/$proj" init -q
  {
    printf 'window=fmlab:%s\nkind=%s\nharness=claude\nbackend=tmux\n' "$id" "$kind"
    [ "$kind" = scout ] || printf 'pr=%s\n' "$PR"
    printf 'project=%s/projects/%s\n' "$home" "$proj"
  } > "$home/state/$id.meta"
  printf 'done [at=%s]: PR %s checks green\n' "$OLD" "$PR" > "$home/state/$id.status"
  printf 'g1.1.1\n' > "$home/state/$id.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$home/state/$id.busy-state"
  if [ "$kind" = scout ]; then
    mkdir -p "$home/data/$id"; printf '# report\nfindings\n' > "$home/data/$id/report.md"; touch_old "$home/data/$id/report.md"
  else
    printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n41\n' > "$home/state/$id.pr-poll-merge-notified"
    chmod 0600 "$home/state/$id.pr-poll-merge-notified"; touch_old "$home/state/$id.pr-poll-merge-notified"
  fi
}

scan() { FM_HOME="$1" "${2:-$REAP}" scan 2>&1; }
hold() { FM_HOME="$1" "$H" "${@:2}" 2>&1; }

# ---------------------------------------------------------------- main home
MAIN=$FM_HOME
prep_home "$MAIN"
mk_task "$MAIN" vernant-b10-u4-register vernant
mk_task "$MAIN" graft-stop-coalesce vernant
mk_task "$MAIN" vernant-sibling sample
mk_task "$MAIN" vernant-probe-scout vernant scout
printf 'Captain releases the Vernant freeze.\n' > "$MAIN/release.txt"

say "S0 baseline: no hold -> reaper selects the Vernant task"
run scan "$MAIN"

say "S1 captain files the freeze hold (plain hold, no declaration yet)"
run hold "$MAIN" hold vernant-freeze-20261023 --title "Vernant freeze" \
  --reason "captain froze the Vernant lanes: nothing dispatches until main is green" --repo vernant
say "S1 plain hold of the vernant repo declares no project -> still reap (scope is declared, not inferred)"
run scan "$MAIN"

say "S2 captain declares the freeze"
run hold "$MAIN" freeze vernant-freeze-20261023 --project vernant
(cd "$MAIN" && tasks-axi show vernant-freeze-20261023 --full 2>&1 | sed -n 1,40p)
say "S2 frozen predicate"
for t in vernant-b10-u4-register graft-stop-coalesce vernant-sibling; do run hold "$MAIN" frozen "$t"; done
say "S2 scan with open freeze"
run scan "$MAIN"

say "S3 base (main @7b9e555) reaper, same home, same open freeze hold"
run scan "$MAIN" "$BASE_BIN/fm-idle-session-reap.sh"

say "S4 real reap sweep with the freeze open (real fm-teardown.sh)"
FM_HOME="$MAIN" "$REAP" reap 2>&1; echo "[exit $?]"
echo "--- state/idle-sessions.report"; cat "$MAIN/state/idle-sessions.report"
echo "--- remaining metas"; ls "$MAIN/state" | grep '\.meta$'
echo "--- refusal memos"; ls "$MAIN/state/.idle-reap" 2>/dev/null

say "S5 automatic teardown admission refuses the frozen task"
FM_HOME="$MAIN" FM_IDLE_REAP_ADMISSION=1 "$WT/bin/fm-teardown.sh" vernant-b10-u4-register 2>&1 | tail -5; echo "[exit ${PIPESTATUS[0]}]"

say "S6 adversarial: --until revisit date passes, freeze still holds"
FM_HOME="$MAIN" "$H" hold vernant-freeze-20261023 --title "Vernant freeze" \
  --reason "captain froze the Vernant lanes" --repo vernant --until 2020-01-01 2>&1; echo "[exit $?]"
(cd "$MAIN" && tasks-axi list --state held 2>&1)
run hold "$MAIN" frozen vernant-b10-u4-register
run scan "$MAIN"

say "S7 captain releases the hold"
run hold "$MAIN" answer vernant-freeze-20261023 --decision-file "$MAIN/release.txt" --release
run hold "$MAIN" frozen vernant-b10-u4-register
run scan "$MAIN"
rm -f "$MAIN/state/.idle-reap/"*.refused 2>/dev/null
say "S7 real reap sweep after release: teardown is attempted again"
FM_HOME="$MAIN" "$REAP" reap 2>&1; echo "[exit $?]"
echo "--- state/idle-sessions.report"; cat "$MAIN/state/idle-sessions.report"

# --------------------------------------------------------- secondmate chain
ROOT_H=$FREEZE_ROOT_HOME; MID=$FREEZE_MID_HOME; GRAND=$FREEZE_GRAND_HOME
for h in "$ROOT_H" "$MID" "$GRAND"; do prep_home "$h"; done
printf 'mid\n' > "$MID/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOT_H" > "$MID/.fm-secondmate-parent"
printf 'grand\n' > "$GRAND/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$MID" > "$GRAND/.fm-secondmate-parent"
mk_task "$MID" vernant-provision-adopt-existing-branch vernant
mk_task "$MID" sample-mate-merged sample
mk_task "$GRAND" vernant-claude-guard-policy-probe-scope vernant
printf 'Captain releases.\n' > "$ROOT_H/release.txt"

say "S8 secondmate + grandchild before any freeze"
run scan "$MID"; run scan "$GRAND"
say "S8 captain freezes vernant once, in the root home only"
run hold "$ROOT_H" hold vernant-freeze-20261023 --title "Vernant freeze" --reason "captain froze the Vernant lanes" --repo vernant
run hold "$ROOT_H" freeze vernant-freeze-20261023 --project vernant
say "S8 secondmate (mid) and grandchild scans"
run scan "$MID"; run scan "$GRAND"
say "S8 base reaper in the secondmate home"
run scan "$MID" "$BASE_BIN/fm-idle-session-reap.sh"

say "S9 adversarial: parent backlog unreadable"
mv "$ROOT_H/data" "$ROOT_H/data.off"; run scan "$MID"; mv "$ROOT_H/data.off" "$ROOT_H/data"
say "S9 adversarial: middle binding missing (marker kept)"
mv "$MID/.fm-secondmate-parent" "$MID/.fm-secondmate-parent.off"; run scan "$GRAND"
say "S9 adversarial: binding loops back"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$GRAND" > "$MID/.fm-secondmate-parent"; run scan "$GRAND"
mv "$MID/.fm-secondmate-parent.off" "$MID/.fm-secondmate-parent"

say "S10 root releases: mate and grandchild eligible again"
run hold "$ROOT_H" answer vernant-freeze-20261023 --decision-file "$ROOT_H/release.txt" --release
run scan "$MID"; run scan "$GRAND"
