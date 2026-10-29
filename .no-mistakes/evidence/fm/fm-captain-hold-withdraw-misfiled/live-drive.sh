#!/usr/bin/env bash
# Live drive of the decision-owner change against the real scripts and the real
# tasks-axi, inside disposable lab homes minted by bin/fm-lab-home.sh.
# Usage: live-drive.sh <worktree-root>
set -u
ROOT=$1
CH="$ROOT/bin/fm-captain-hold.sh"
LAB_BASE=${TMPDIR:-/tmp}; LAB_BASE=${LAB_BASE%/}
P=$(mktemp -d "$LAB_BASE/fm-lab.XXXXXX")
M=$(mktemp -d "$LAB_BASE/fm-lab.XXXXXX")
R=$(mktemp -d "$LAB_BASE/fm-lab.XXXXXX")
P=$("$ROOT/bin/fm-lab-home.sh" create "$P") || exit 1
M=$("$ROOT/bin/fm-lab-home.sh" create "$M") || exit 1
R=$("$ROOT/bin/fm-lab-home.sh" create "$R") || exit 1
cleanup() { rm -rf "$P" "$M" "$R"; }
trap cleanup EXIT
echo "parent lab home: $P"; echo "mate lab home:   $M"; echo "remote mate lab: $R"

for h in "$P" "$M" "$R"; do
  mkdir -p "$h/data" "$h/state" "$h/config" "$h/projects"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$h/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$h/data/backlog.md"
done

# Plain FM_HOME only; strip inherited fleet overrides.
fmenv() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$1" "${@:2}"; }
step() { printf '\n### %s\n' "$*"; }
run() { local h=$1; shift; printf '$ FM_HOME=<%s> %s\n' "$(basename "$h")" "$*"; fmenv "$h" "$@" 2>&1; printf '[exit %s]\n' "$?"; }
ch() { local h=$1; shift; run "$h" "$CH" "$@"; }
tx() { local h=$1; shift; printf '$ tasks-axi %s\n' "$*"; (cd "$h" && tasks-axi "$@" --file data/backlog.md) 2>&1; printf '[exit %s]\n' "$?"; }
row() { (cd "$1" && tasks-axi show "$2" --full --file data/backlog.md) 2>&1 | grep -E '^(  )?(state|held|hold_kind|kind):' ; }
body() { (cd "$1" && tasks-axi show "$2" --full --file data/backlog.md) 2>&1 | (. "$ROOT/bin/fm-hold-reason-lib.sh"; fm_hold_reason_decode_stream) | grep -E "$3"; }
mate_id=fm-mini-lab
make_mate() { printf '%s\n' "$mate_id" > "$1/.fm-secondmate-home"; }

step "SETUP: work items and legacy holds filed while the home had no owner rule (before this change)"
(cd "$M" && tasks-axi add pr290-ship "Ship the successor watcher race fix" --kind ship --repo sample --body 'Gated ship work.' --file data/backlog.md >/dev/null)
(cd "$M" && tasks-axi add pr290-shape "PR 290 shape: Main-reserved call" --kind ship --repo sample --body 'Gated ship work.' --file data/backlog.md >/dev/null)
(cd "$M" && tasks-axi add d5-mechanism "vernant-d5 demand-map mechanism" --kind ship --repo sample --body 'Gated work.' --file data/backlog.md >/dev/null)
# The parent relays a request to the mate; the parent's own library records it.
CORR=$(. "$ROOT/bin/fm-pending-reply-lib.sh"; fm_pending_reply_create "$P" "$P/state" "$mate_id" "retry or fix one red CI check")
echo "parent pending-reply record: corr=$CORR at $P/state/pending-replies/$CORR"
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$M" "$CH" hold pr290-ship --reason "retry or fix one red CI check; Main180/181 reserve ask-user decisions to Main, relayed corr=$CORR" >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$M" "$CH" hold pr290-shape --reason "Main180/181 reserve ask-user decisions to Main" >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$M" "$CH" hold d5-mechanism --reason "which demand-map mechanism?" >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$M" "$CH" hold d5-error-bound --title "vernant-d5 error-bound call" --reason "which error bound?" --repo sample >/dev/null
# Now the home takes the secondmate shape, as fm-mini did.
make_mate "$M"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$M/.fm-secondmate-parent"
for t in pr290-ship pr290-shape d5-mechanism d5-error-bound; do echo "-- $t"; row "$M" "$t"; done

step "S1 ROOT CAUSE: a mate home cannot file a hold without saying whose call it is, and never holds Main's call"
(cd "$M" && tasks-axi add new-work "New gated work" --kind ship --repo sample --file data/backlog.md >/dev/null)
ch "$M" hold new-work --reason "retry or fix one red CI check"
ch "$M" hold new-work --reason "retry or fix one red CI check" --owner parent
row "$M" new-work

step "S2 PR 290 path: merge gate refuses the misfiled captain hold (local merge entry point)"
git init -q -b main "$M/projects/sample"
git -C "$M/projects/sample" -c user.email=lab@x -c user.name=lab commit -q --allow-empty -m base
git -C "$M/projects/sample" branch fm/pr290-ship
git -C "$M/projects/sample" checkout -q fm/pr290-ship
git -C "$M/projects/sample" -c user.email=lab@x -c user.name=lab commit -q --allow-empty -m "the fix"
git -C "$M/projects/sample" checkout -q main
printf 'project=%s\nmode=local-only\nbranch=fm/pr290-ship\n' "$M/projects/sample" > "$M/state/pr290-ship.meta"
run "$M" "$ROOT/bin/fm-merge-local.sh" pr290-ship

step "S2 answer would forge the captain's words: show the honest paths instead"
printf 'Main decided: one unchanged-head retry.\nCI went green; DeepSeek PASS recorded.\n' > "$M/classify-evidence.txt"
ch "$M" classify pr290-ship --owner parent --evidence-file "$M/classify-evidence.txt" --reason "the retry-or-fix question was Main's"
row "$M" pr290-ship
body "$M" pr290-ship 'Decision owner|Classification provenance|Not a captain answer|Classified by'
ch "$M" open pr290-ship --distinguish-absent
ch "$M" open pr290-ship --distinguish-absent --parent-owned

step "S2 merge gate now names the parent's decision, not the captain's"
run "$M" "$ROOT/bin/fm-merge-local.sh" pr290-ship

step "S2 ADVERSARIAL: the captain's answer path refuses a parent decision"
printf 'the captain never said this\n' > "$M/fake-captain.txt"
ch "$M" answer pr290-ship --decision-file "$M/fake-captain.txt" --release
row "$M" pr290-ship

step "S2 Main records its decision; work item stays open; merge proceeds"
printf 'Retry the failing check once on the unchanged head. Done; 34/34 green.\n' > "$M/parent-decision.txt"
ch "$M" decide pr290-ship --decision-file "$M/parent-decision.txt"
row "$M" pr290-ship
body "$M" pr290-ship 'Parent decision|Not a captain answer'
echo "-- parent channel ($P/state/$mate_id.status):"; sed -E 's/ \[at=[0-9]+\]//' "$P/state/$mate_id.status" 2>&1
run "$M" "$ROOT/bin/fm-merge-local.sh" pr290-ship
git -C "$M/projects/sample" log --oneline main

step "S3 ADVERSARIAL: the real PR 290 hold reason (no corr token) cannot be classified; it stays the captain's"
ch "$M" classify pr290-shape --owner parent --evidence-file "$M/classify-evidence.txt" --reason "the question was Main's"
row "$M" pr290-shape
printf 'Main decides\n' > "$M/d.txt"
ch "$M" decide pr290-shape --decision-file "$M/d.txt"
row "$M" pr290-shape
ch "$M" open pr290-shape --distinguish-absent

step "S3b ADVERSARIAL: a forged corr token with no parent record is refused"
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$M" "$CH" hold forged --title "forged corr" --reason "relayed corr=deadbeefdeadbeef" --repo sample --owner captain >/dev/null 2>&1
# Filed with an owner, so build a true legacy one in premate shape instead:
mv "$M/.fm-secondmate-home" "$M/.mh"; mv "$M/.fm-secondmate-parent" "$M/.mp"
(cd "$M" && tasks-axi add forged-work "Forged corr work" --kind ship --repo sample --file data/backlog.md >/dev/null)
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$M" "$CH" hold forged-work --reason "relayed corr=deadbeefdeadbeef" >/dev/null
mv "$M/.mh" "$M/.fm-secondmate-home"; mv "$M/.mp" "$M/.fm-secondmate-parent"
ch "$M" classify forged-work --owner parent --evidence-file "$M/classify-evidence.txt" --reason "the question was Main's"
row "$M" forged-work

step "S4 ADVERSARIAL: withdraw with no ruling, a non-captain ruling, or an unrelated ruling is refused"
printf 'moot under ruling A\n' > "$M/withdraw-evidence.txt"
ch "$M" withdraw d5-mechanism --evidence-file "$M/withdraw-evidence.txt"
ch "$M" withdraw d5-mechanism --evidence-file "$M/withdraw-evidence.txt" --ruling pr290-ship
ch "$M" hold ruling-unrelated --title "Unrelated captain ruling" --reason "pick a color" --repo sample --owner captain >/dev/null 2>&1
printf 'Blue.\n' > "$M/a1.txt"
fmenv "$M" "$CH" answer ruling-unrelated --decision-file "$M/a1.txt" >/dev/null 2>&1
ch "$M" withdraw d5-mechanism --evidence-file "$M/withdraw-evidence.txt" --ruling ruling-unrelated
row "$M" d5-mechanism

step "S5 vernant-d5: the captain's ruling A makes d5-mechanism and d5-error-bound moot; withdraw releases honestly"
ch "$M" hold ruling-a --title "Captain ruling A" --reason "Choose approach A or B for vernant-d5" --repo sample --owner captain
printf 'Approach A. That makes d5-mechanism and d5-error-bound moot.\n' > "$M/captain-ruling-a.txt"
ch "$M" answer ruling-a --decision-file "$M/captain-ruling-a.txt"
ch "$M" withdraw d5-mechanism --evidence-file "$M/withdraw-evidence.txt" --ruling ruling-a
row "$M" d5-mechanism
body "$M" d5-mechanism 'Withdrawn|Not a captain answer|Ruling|ruling'
ch "$M" withdraw d5-error-bound --evidence-file "$M/withdraw-evidence.txt" --ruling ruling-a
row "$M" d5-error-bound
echo "-- tasks-axi ready (a withdrawn question must not be dispatchable work):"
tx "$M" ready

step "S6 a genuine captain call is not released by Main's decision and still blocks the merge"
(cd "$M" && tasks-axi add cap-work "Genuine captain call work" --kind ship --repo sample --file data/backlog.md >/dev/null)
ch "$M" hold cap-work --reason "captain: ship the risky migration now?" --owner captain
ch "$M" decide cap-work --decision-file "$M/parent-decision.txt"
ch "$M" classify cap-work --owner parent --evidence-file "$M/classify-evidence.txt" --reason "try to steal it"
row "$M" cap-work
git -C "$M/projects/sample" branch fm/cap-work main
git -C "$M/projects/sample" checkout -q fm/cap-work
git -C "$M/projects/sample" -c user.email=lab@x -c user.name=lab commit -q --allow-empty -m "risky"
git -C "$M/projects/sample" checkout -q main
printf 'project=%s\nmode=local-only\nbranch=fm/cap-work\n' "$M/projects/sample" > "$M/state/cap-work.meta"
run "$M" "$ROOT/bin/fm-merge-local.sh" cap-work

step "S7 remote mate: classify matches the relayed request in this home's own steering inbox"
printf '%s\n' "$mate_id" > "$R/.fm-secondmate-home"
(cd "$R" && tasks-axi add relayed-work "Relayed work" --kind ship --repo sample --file data/backlog.md >/dev/null)
(cd "$R" && tasks-axi add unrelayed-work "Unrelayed work" --kind ship --repo sample --file data/backlog.md >/dev/null)
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$R" "$CH" hold relayed-work --reason "retry or fix one red CI check, relayed corr=00112233445566ff" >/dev/null 2>&1 || true
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$R" "$CH" hold unrelayed-work --reason "retry or fix one red CI check, relayed corr=aabbccddeeff0011" >/dev/null 2>&1 || true
rm -f "$R/.fm-secondmate-home"
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$R" "$CH" hold relayed-work --reason "retry or fix one red CI check, relayed corr=00112233445566ff" >/dev/null
FM_CAPTAIN_HOLD_NOW=2026-01-01T00:00:00Z fmenv "$R" "$CH" hold unrelayed-work --reason "retry or fix one red CI check, relayed corr=aabbccddeeff0011" >/dev/null
printf '%s\n' "$mate_id" > "$R/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$R/.fm-secondmate-parent"
( export FM_HOME=$R; . "$ROOT/bin/fm-task-inbox-lib.sh"; . "$ROOT/bin/fm-operational-input.sh"
  fm_task_inbox_write "$R/state/parent-route" "$mate_id" "${FM_FROMFIRST_MARK}corr=00112233445566ff retry the red check once or fix it" >/dev/null ) \
  && echo "relayed request written to the remote inbox through bin/fm-task-inbox-lib.sh"
ch "$R" classify unrelayed-work --owner parent --evidence-file "$M/classify-evidence.txt" --reason "the question was Main's"
ch "$R" classify relayed-work --owner parent --evidence-file "$M/classify-evidence.txt" --reason "the question was Main's"
row "$R" relayed-work
body "$R" relayed-work 'Decision owner|Classification provenance'
row "$R" unrelayed-work

step "TEARDOWN"
for h in "$P" "$M" "$R"; do "$ROOT/bin/fm-lab-home.sh" teardown "$h" >/dev/null 2>&1; done
echo "lab homes removed on exit"
