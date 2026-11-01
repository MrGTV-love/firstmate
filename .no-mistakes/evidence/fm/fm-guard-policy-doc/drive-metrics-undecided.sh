#!/usr/bin/env bash
# Live driver: runs the real bin/fm-guard-metrics.sh --undecided against
# throwaway event logs and registries, and prints each scenario's outcome.
set -u
WT=${1:?worktree}
M="$WT/bin/fm-guard-metrics.sh"
W="$WT/bin/fm-guard-event.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-metrics-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
reg() {  # <out> <harm> [decision]
  if [ -n "${3:-}" ]; then
    jq -n --arg h "$2" --arg d "$3" '{guards:[{id:"gx",harm:$h,retirement_decision:$d}]}' >"$1"
  else
    jq -n --arg h "$2" '{guards:[{id:"gx",harm:$h}]}' >"$1"
  fi
}
rows() {  # <log> <day> <count> [decision] [override] [hh]
  local n=0
  while [ "$n" -lt "$3" ]; do
    printf '{"ts":"%sT%s:%02d:%02dZ","guard":"gx","session":"s-%s-%s-%s","decision":"%s","override":%s}\n' \
      "$2" "${6:-12}" "$((n/60))" "$((n%60))" "$2" "${4:-allow}" "$n" "${4:-allow}" "${5:-false}" >>"$1"
    n=$((n+1))
  done
}
run() {  # <name> <expect: NOMINATED|SILENT> <log> <registry>
  local got; got=$("$M" --log "$3" --registry "$4" --min-opportunities 30 --undecided)
  local seen=SILENT; [ "$got" = gx ] && seen=NOMINATED
  local verdict=FAIL; [ "$seen" = "$2" ] && verdict=PASS
  printf '%-4s | %-72s | expect=%-9s got=%-9s out=%q\n' "$verdict" "$1" "$2" "$seen" "$got"
}

# S1 baseline: undecided reversible zero-fire guard is nominated
L="$T/s1.jsonl"; : >"$L"; rows "$L" 2026-01-10 30
reg "$T/none.json" reversible
run "S1 undecided zero-fire reversible guard" NOMINATED "$L" "$T/none.json"

# S2 dated keep over quiet window; 30 and then 60 more quiet events after it
reg "$T/keep0201.json" reversible "keep 2026-02-01: judged quiet January"
reg "$T/red0201.json" reversible "redesign 2026-02-01: judged quiet January"
reg "$T/cut0201.json" reversible "cut 2026-02-01: removal PR pending"
rows "$L" 2026-03-10 30
run "S2a keep: 30 unchanged quiet events after date" SILENT "$L" "$T/keep0201.json"
run "S2b redesign: 30 unchanged quiet events after date" SILENT "$L" "$T/red0201.json"
run "S2c cut: 30 unchanged quiet events after date" SILENT "$L" "$T/cut0201.json"
rows "$L" 2026-04-10 30
run "S2d keep: 60 unchanged quiet events after date" SILENT "$L" "$T/keep0201.json"

# Base for S3/S4: an old recurrence (2025-12-01) keeps the whole-log verdict at
# `cut` even after a new fire, so --undecided is asked the real question. Without
# it, one new deny on a zero-fire guard ends the cut verdict itself (see S10).
recur_base() {  # <log>
  : >"$1"
  for k in deny allow deny allow; do printf '{"ts":"2025-12-01T12:00:00Z","guard":"gx","session":"old-recur","decision":"%s","override":false}\n' "$k" >>"$1"; done
  rows "$1" 2026-01-10 30; rows "$1" 2026-03-10 30
}
recur_base "$T/s3base.jsonl"
run "S3-control recurrence older than judged window, keep, 30 quiet after" SILENT "$T/s3base.jsonl" "$T/keep0201.json"
cp "$T/s3base.jsonl" "$T/s3.jsonl"; "$W" gx deny --session live-writer --log "$T/s3.jsonl"
tail -n 1 "$T/s3.jsonl" | sed 's/^/     writer row: /'
run "S3a keep 2026-02-01 then writer-made deny today" NOMINATED "$T/s3.jsonl" "$T/keep0201.json"
cp "$T/s3base.jsonl" "$T/s3b.jsonl"; "$W" gx allow --override --session live-writer --log "$T/s3b.jsonl"
run "S3b keep then writer-made allow with --override today" NOMINATED "$T/s3b.jsonl" "$T/keep0201.json"
cp "$T/s3base.jsonl" "$T/s3c.jsonl"; "$W" gx warn --session live-writer --log "$T/s3c.jsonl"
run "S3c keep then writer-made warn today" NOMINATED "$T/s3c.jsonl" "$T/keep0201.json"
cp "$T/s3base.jsonl" "$T/s3d.jsonl"; rows "$T/s3d.jsonl" 2026-05-01 1 bypass
run "S3d keep then a bypass row on a later date" NOMINATED "$T/s3d.jsonl" "$T/keep0201.json"
cp "$T/s3base.jsonl" "$T/s3e.jsonl"; "$W" gx error --session live-writer --log "$T/s3e.jsonl"
run "S3e keep then writer-made error today (non-allow is new evidence)" NOMINATED "$T/s3e.jsonl" "$T/keep0201.json"

# S4 date-only boundary: same-date deny (late in the day) vs later-date deny
recur_base "$T/s4.jsonl"
rows "$T/s4.jsonl" 2026-06-11 1 deny false 23
reg "$T/keep0611.json" reversible "keep 2026-06-11: judged that day"
run "S4a deny at 23:00 on the SAME date as keep 2026-06-11" SILENT "$T/s4.jsonl" "$T/keep0611.json"
rows "$T/s4.jsonl" 2026-06-12 1 deny false 00
run "S4b deny at 00:00 on the NEXT date after keep 2026-06-11" NOMINATED "$T/s4.jsonl" "$T/keep0611.json"

# S5 judged window held a fire, then a quiet window after: rate changed to zero
L5="$T/s5.jsonl"; : >"$L5"
for k in deny allow deny allow; do printf '{"ts":"2026-01-09T12:00:00Z","guard":"gx","session":"r","decision":"%s","override":false}\n' "$k" >>"$L5"; done
rows "$L5" 2026-01-10 26
rows "$L5" 2026-03-10 30
run "S5a deny in judged window, 30 quiet after keep (rate -> 0)" NOMINATED "$L5" "$T/keep0201.json"
L5w="$T/s5w.jsonl"; : >"$L5w"
for k in deny allow deny allow; do printf '{"ts":"2025-12-01T12:00:00Z","guard":"gx","session":"old-recur","decision":"%s","override":false}\n' "$k" >>"$L5w"; done
rows "$L5w" 2026-01-10 29; rows "$L5w" 2026-01-11 1 warn; rows "$L5w" 2026-03-10 30
run "S5b warn in judged window, 30 quiet after keep (rate -> 0)" NOMINATED "$L5w" "$T/keep0201.json"
rows "$L5w" 2026-03-11 10
reg "$T/keep0320.json" reversible "keep 2026-03-20: process fixed, quiet backstop"
run "S5c re-judged keep 2026-03-20, then quiet" SILENT "$L5w" "$T/keep0320.json"
rows "$L5" 2026-04-10 30
run "S5d historical deny + re-judged keep + 30 more quiet" SILENT "$L5" "$T/keep0320.json"
rows "$L5" 2026-05-10 60
run "S5e historical deny + re-judged keep + 90 more quiet" SILENT "$L5" "$T/keep0320.json"

# S6 judged window held only an error (not a fire), quiet after: no re-nomination
L6="$T/s6.jsonl"; : >"$L6"
for k in deny allow deny allow; do printf '{"ts":"2026-01-09T12:00:00Z","guard":"gx","session":"r","decision":"%s","override":false}\n' "$k" >>"$L6"; done
rows "$L6" 2026-01-10 29; rows "$L6" 2026-01-10 1 error; rows "$L6" 2026-03-10 30
run "S6 error-only judged window, 30 quiet after keep" SILENT "$L6" "$T/keep0201.json"

# S7 malformed decisions judge nothing
for d in "keep: no date" "Keep 2026-02-01: wrong case" "keep 2026-2-1: short date" "retain 2026-02-01: unknown outcome" " keep 2026-02-01: leading space"; do
  reg "$T/bad.json" reversible "$d"
  run "S7 malformed decision '$d'" NOMINATED "$T/s1.jsonl" "$T/bad.json"
done

# S8 below threshold after a keep: fewer than 30 quiet events never re-nominates
L8="$T/s8.jsonl"; : >"$L8"; rows "$L8" 2026-01-10 30; rows "$L8" 2026-03-10 29
run "S8 keep + 29 quiet events with fired judged window? (quiet judged)" SILENT "$L8" "$T/keep0201.json"

# S9 irreversible guard: quiet never cut, so never nominated with or without decision
reg "$T/irr.json" irreversible
run "S9 irreversible zero-fire guard, no decision" SILENT "$T/s1.jsonl" "$T/irr.json"

# S10 one new fire on a zero-fire guard ends the cut verdict itself
L10="$T/s10.jsonl"; : >"$L10"; rows "$L10" 2026-01-10 60; "$W" gx deny --session live-writer --log "$L10"
printf '     %s\n' "$("$M" --log "$L10" --registry "$T/keep0201.json" --min-opportunities 30 | head -n 1)"
run "S10 zero-fire guard + one new deny: verdict keep, not a nomination" SILENT "$L10" "$T/keep0201.json"

# S11 --help prints the decision-judging contract from the header
"$M" --help | sed -n '1,4p;36,47p' | sed 's/^/     help: /'
