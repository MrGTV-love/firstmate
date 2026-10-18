#!/usr/bin/env bash
# Drives the real bin/fm-brief.sh, bin/fm-spawn.sh and
# bin/fm-supervision-instructions.sh from the run worktree against a
# disposable marked lab home. Nothing here touches the fleet home.
# Usage: drive-scenarios.sh <lab-home> <worktree>
set -u
LAB=$1
WT=$2
BRIEF=$WT/bin/fm-brief.sh
SPAWN=$WT/bin/fm-spawn.sh
SUP=$WT/bin/fm-supervision-instructions.sh
PROJ=$LAB/projects/proj

# env -u keeps fleet-path overrides out; fake tmux (exit 1) stops any spawn
# that clears the Definition of Done gate before a window or worktree exists.
spawn() {  # <id> <args...>
  local id=$1
  shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
    PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB" "$SPAWN" "$id" "$PROJ" "$@" 2>&1
  echo "[exit=$?]"
}
brief() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" "$BRIEF" "$@" 2>&1
}
fill() {  # <file> <token> <text>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, tok, txt = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace(tok, txt, 1))
PY
}
fill_task() {
  fill "$1" '{TASK}' "$2"
  fill "$1" '{FIRSTMATE_SPEC}' "$3"
}
fill_dod_all() {
  fill "$1" '{DOD_CAPABILITY}' "Counting notes works."
  fill "$1" '{DOD_MANDATORY_ITEMS}' "M1. Source: the intent. Expected: count_notes() returns the count. Verify: unit test. Edge/negative: empty store returns 0. Evidence place: tests/test_notes.py. Authority: grader."
  fill "$1" '{DOD_SUPPORTING_ITEMS}' "None."
  fill "$1" '{DOD_HARD_GATES}' "No push to main."
  fill "$1" '{DOD_HONESTY_RULE}' "Report an unrun test as unrun."
}
hdr() { printf '\n======== %s ========\n' "$*"; }

hdr "S1: ship brief ends with task DoD + How You're Graded (headings, then secondmate charter has none)"
rm -rf "$LAB/data/s1-ship" "$LAB/data/s1-scout" "$LAB/data/s1-second"
brief s1-ship proj --mode direct-PR
brief s1-scout proj --scout
grep -nE '^(## Definition Of Done \(task\)|## How You.re Graded|# Definition of done)$' "$LAB/data/s1-ship/brief.md" "$LAB/data/s1-scout/brief.md"
brief s1-second --secondmate --no-projects
echo "secondmate charter matches for task DoD sections: $(grep -c 'Definition Of Done (task)\|How You.re Graded' "$LAB/data/s1-second/brief.md")"

hdr "S2: fresh spawn of an UNFILLED scaffold is refused, names section + placeholder, creates no metadata"
rm -rf "$LAB/data/s2" "$LAB/state/s2.meta"
brief s2 proj --mode direct-PR >/dev/null
fill_task "$LAB/data/s2/brief.md" "Add count_notes." "Keep it small."
spawn s2 --mode direct-PR --yolo off
echo "meta exists: $([ -e "$LAB/state/s2.meta" ] && echo YES || echo no)"
echo "launch-brief.md rendered after refusal: $([ -e "$LAB/data/s2/launch-brief.md" ] && echo YES || echo no)"

hdr "S3: half-filled brief is refused at the NEXT placeholder; fully filled brief passes the DoD gate"
fill "$LAB/data/s2/brief.md" '{DOD_CAPABILITY}' "Counting notes works."
spawn s2 --mode direct-PR --yolo off
fill_dod_all "$LAB/data/s2/brief.md"
spawn s2 --mode direct-PR --yolo off | grep -v '^$'
echo "launch-brief.md rendered past the gate: $([ -e "$LAB/data/s2/launch-brief.md" ] && echo YES || echo no)"

hdr "S4: scout brief unfilled refused, filled passes"
rm -rf "$LAB/data/s4"
brief s4 proj --scout >/dev/null
fill_task "$LAB/data/s4/brief.md" "Find the cause." "Report only."
spawn s4 --scout
fill_dod_all "$LAB/data/s4/brief.md"
spawn s4 --scout | grep -v '^$'
echo "launch-brief.md rendered past the gate: $([ -e "$LAB/data/s4/launch-brief.md" ] && echo YES || echo no)"

hdr "S5 (adversarial): a '## M1' heading inside Mandatory items must NOT hide later placeholders"
rm -rf "$LAB/data/s5"
brief s5 proj --mode direct-PR >/dev/null
fill_task "$LAB/data/s5/brief.md" "Fix it." "Small."
fill "$LAB/data/s5/brief.md" '{DOD_CAPABILITY}' "It works."
fill "$LAB/data/s5/brief.md" '{DOD_MANDATORY_ITEMS}' $'## M1 It works\nSource: intent.\n\n## M2 It stays working\nSource: intent.'
spawn s5 --mode direct-PR --yolo off

hdr "S6 (adversarial): a finished section that QUOTES a token inside a sentence is accepted"
rm -rf "$LAB/data/s6"
brief s6 proj --mode direct-PR >/dev/null
fill_task "$LAB/data/s6/brief.md" "Fix it." "Small."
fill_dod_all "$LAB/data/s6/brief.md"
fill "$LAB/data/s6/brief.md" 'M1. Source' 'M1. Edge/negative: a brief that still holds {DOD_HARD_GATES} is refused. Source'
spawn s6 --mode direct-PR --yolo off | grep -v '^$'
echo "launch-brief.md rendered past the gate: $([ -e "$LAB/data/s6/launch-brief.md" ] && echo YES || echo no)"

hdr "S7: DoD file escape - missing / empty / unfinished file refused; finished file accepted"
rm -rf "$LAB/data/s7"
brief s7 proj --mode direct-PR >/dev/null
fill_task "$LAB/data/s7/brief.md" "Fix it." "Small."
CR=$LAB/data/s7/criteria.md
awk -v line="DoD file: $CR" '{ print } $0 == "## Definition Of Done (task)" { print line }' "$LAB/data/s7/brief.md" > "$LAB/data/s7/b.new" && mv "$LAB/data/s7/b.new" "$LAB/data/s7/brief.md"
echo "-- file missing"; spawn s7 --mode direct-PR --yolo off
: > "$CR"
echo "-- file empty"; spawn s7 --mode direct-PR --yolo off
printf 'Criteria.\n\n{DOD_HARD_GATES}\n' > "$CR"
echo "-- file with placeholder"; spawn s7 --mode direct-PR --yolo off
printf 'Mandatory: the thing works.\n' > "$CR"
echo "-- finished file"; spawn s7 --mode direct-PR --yolo off | grep -v '^$'
echo "launch-brief.md rendered past the gate: $([ -e "$LAB/data/s7/launch-brief.md" ] && echo YES || echo no)"

hdr "S8 (adversarial): 'DoD file:' lines OUTSIDE the task section (intent, fenced text, after grading) are ignored"
rm -rf "$LAB/data/s8"
brief s8 proj --mode direct-PR >/dev/null
CR8=$LAB/data/s8/criteria.md
printf 'Mandatory: the thing works.\n' > "$CR8"
fill_task "$LAB/data/s8/brief.md" $'Fix it.\nDoD file: '"$CR8" $'Small.\n```\n## Definition Of Done (task)\nDoD file: '"$CR8"$'\n```'
printf '\nDoD file: %s\n' "$CR8" >> "$LAB/data/s8/brief.md"
spawn s8 --mode direct-PR --yolo off

hdr "S9: brief with NO task DoD section: one warning naming section + task, spawn carries on"
rm -rf "$LAB/data/s9"
mkdir -p "$LAB/data/s9"
printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nExercise it.\n\n## Firstmate spec\nVerify it.\n\n# Definition of done\nDelivery contract: mode=direct-PR\n' > "$LAB/data/s9/brief.md"
OUT=$(spawn s9 --mode direct-PR --yolo off)
printf '%s\n' "$OUT" | grep -v '^$'
echo "warning line count: $(printf '%s\n' "$OUT" | grep -c 'has no ## Definition Of Done (task) section')"
echo "launch-brief.md rendered past the gate: $([ -e "$LAB/data/s9/launch-brief.md" ] && echo YES || echo no)"

hdr "S10: supervision-instruction output names the grading sections and the DoD-file rule (per harness)"
for h in claude codex cursor opencode grok omp; do
  out=$(env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" "$SUP" --harness "$h" 2>&1)
  printf '%s: rc-lines=%s completion-line=%s dodfile-rule=%s\n' "$h" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" \
    "$(printf '%s\n' "$out" | grep -c '^- Completion check:')" \
    "$(printf '%s\n' "$out" | grep -c 'DoD file: <absolute path>')"
done
echo "-- the rendered line (claude):"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" "$SUP" --harness claude 2>&1 | grep '^- Completion check:'
echo "-- repair-line mode and read-only mode still render without error:"
for flag in "--repair-line" "--read-only 1"; do
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" "$SUP" --harness claude $flag >/dev/null 2>&1; echo "$flag rc=$?"
done
