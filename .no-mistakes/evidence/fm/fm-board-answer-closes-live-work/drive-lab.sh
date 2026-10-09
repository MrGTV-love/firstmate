#!/usr/bin/env bash
# Live driver: runs the real fm-captain-hold.sh / fm-teardown.sh / fm-procevent.sh
# from a given checkout root against a disposable marked lab home.
# usage: drive-lab.sh <root-with-bin> <lab-home> <scenario>
set -u
ROOT=$1; LAB=$2; SCN=$3
export PATH="$LAB/fakebin:$PATH"
# Plain FM_HOME only; no FM_*_OVERRIDE (lab contract). External tools stubbed.
cap() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" "$ROOT/bin/fm-captain-hold.sh" "$@"; }
td()  { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" "$ROOT/bin/fm-teardown.sh" "$@"; }
pe()  { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" "$ROOT/bin/fm-procevent.sh" "$@"; }
t()   { (cd "$LAB" && tasks-axi "$@"); }
meta() { printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\nharness=codex\nkind=%s\nmode=%s\nspawn_gen=lab-%s\n' \
  "$1" "$LAB" "$1" "$LAB" "$2" "$2" "$1" > "$LAB/state/$1.meta"; }
say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
show() { printf -- '--- task %s ---\n' "$1"; t show "$1" --full 2>&1 | grep -E '^  (state|held|kind):|Resolution mode|Resolves hold set|Answer:|Label:|Source:|Deliverable' ; t show "$1" --full 2>&1 | sed -n 's/^  body: //p' | jq -r . 2>/dev/null | grep -E 'Resolution mode|Resolves hold set|^Answer|Captain|Deliverable' | sed 's/^/  body| /'; ls "$LAB/state/$1.meta" >/dev/null 2>&1 && echo "  worker record: PRESENT" || echo "  worker record: absent"; }

case "$SCN" in
setup)
  cp "$ROOT/.tasks.toml" "$LAB/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
  git init -q -b main "$LAB/projects/sample"
  mkdir -p "$LAB/fakebin" "$LAB/tmux"
  for b in tmux treehouse no-mistakes gh gh-axi herdr; do printf '#!/bin/sh\nexit 0\n' > "$LAB/fakebin/$b"; chmod +x "$LAB/fakebin/$b"; done
  echo "lab ready: $LAB (root $ROOT)"
  ;;
s1)
  say "S1 setup: four captain-held items (in-flight scout with worker, spawned ship with worker, in-flight row only, plain question)"
  t add lab-live-scout "Review the live sample" --kind scout --repo sample --start >/dev/null; meta lab-live-scout scout
  t add lab-live-ship "Ship the live sample" --kind ship --repo sample >/dev/null; meta lab-live-ship ship
  t add lab-row-only "Ship the row-only sample" --kind ship --repo sample --start >/dev/null
  run cap hold lab-live-scout --reason "captain design pick needed"
  run cap hold lab-live-ship --reason "captain design pick needed"
  run cap hold lab-row-only --reason "captain design pick needed"
  run cap hold lab-plain-question --title "Captain call: plain" --reason "captain choice pending" --repo sample
  for i in lab-live-scout lab-live-ship lab-row-only lab-plain-question; do show $i; done
  say "S1 act: one keyed board batch answers all four (default, done, done, default)"
  printf 'lab-live-scout\tgo-b\tOption B\nlab-live-ship\tgo-b\tOption B\tdone\nlab-row-only\tgo-b\tOption B\tdone\nlab-plain-question\tyes\tYes\n' > "$LAB/batch.tsv"
  printf '$ fm-captain-hold.sh answers --source "lab board batch" < batch.tsv\n'; cat -A "$LAB/batch.tsv" 2>/dev/null || cat -vet "$LAB/batch.tsv"
  cap answers --source "lab board batch" < "$LAB/batch.tsv"; printf '[exit %s]\n' "$?"
  say "S1 result"
  for i in lab-live-scout lab-live-ship lab-row-only lab-plain-question; do show $i; done
  printf -- '--- backlog.md ---\n'; cat "$LAB/data/backlog.md" | cut -c1-160
  ;;
s2)
  say "S2: the worker of lab-live-scout finishes; cleanup (teardown) runs; then the same board answer arrives again"
  mkdir -p "$LAB/data/lab-live-scout"; printf '# Live sample report\n' > "$LAB/data/lab-live-scout/report.md"
  printf 'done: report complete\n' > "$LAB/state/lab-live-scout.status"
  say "replay while the worker still runs"
  printf 'lab-live-scout\tgo-b\tOption B\n' | cap answers --source "lab board batch"; printf '[exit %s]\n' "$?"
  show lab-live-scout
  run cap complete lab-live-scout --none
  run td lab-live-scout
  show lab-live-scout
  say "replay after cleanup completed the work"
  printf 'lab-live-scout\tgo-b\tOption B\n' | cap answers --source "lab board batch"; printf '[exit %s]\n' "$?"
  show lab-live-scout
  ;;
s3)
  say "S3 (adversarial): work is finished and cleaned up while still held; the answer arrives late. It must close, not reopen."
  t add lab-late-answer "Investigate the late answer" --kind scout --repo sample --start >/dev/null; meta lab-late-answer scout
  mkdir -p "$LAB/data/lab-late-answer"; printf '# Late answer report\n' > "$LAB/data/lab-late-answer/report.md"
  printf 'done: report complete\n' > "$LAB/state/lab-late-answer.status"
  run cap hold lab-late-answer --reason "captain report choice pending"
  cap hold lab-late-answer-call --title "Sibling call" --reason "sibling" --repo sample --origin lab-late-answer >/dev/null
  run cap complete lab-late-answer lab-late-answer-call
  run td lab-late-answer
  show lab-late-answer
  printf 'lab-late-answer\tgo\tProceed\n' | cap answers --source "lab late board"; printf '[exit %s]\n' "$?"
  show lab-late-answer
  ;;
s4)
  say "S4 (adversarial): release, re-hold in the same pinned second, re-hold later, same answer again"
  t add lab-rehold "Investigate repeated answers" --kind scout --repo sample --start >/dev/null; meta lab-rehold scout
  echo "(pinned FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z)"; FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run cap hold lab-rehold --reason "first question"
  printf 'lab-rehold\tgo\tProceed\n' | cap answers --source "lab rehold board"; printf '[exit %s]\n' "$?"
  show lab-rehold
  t show lab-rehold --full | sed -n 's/^  body: //p' | jq -r . > "$LAB/rehold-record1.txt"
  say "same-second re-hold with pinned time must refuse"
  echo "(pinned FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z)"; FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:00Z run cap hold lab-rehold --reason "second question"
  show lab-rehold
  say "later re-hold, then the identical answer"
  echo "(pinned FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:01Z)"; FM_CAPTAIN_HOLD_NOW=2026-07-14T12:00:01Z run cap hold lab-rehold --reason "second question"
  show lab-rehold
  printf 'lab-rehold\tgo\tProceed\n' | cap answers --source "lab rehold board"; printf '[exit %s]\n' "$?"
  show lab-rehold
  printf 'resolution records now: %s\n' "$(t show lab-rehold --full | sed -n 's/^  body: //p' | jq -r . | grep -c '^Resolution recorded by fm-captain-hold')"
  t show lab-rehold --full | sed -n 's/^  body: //p' | jq -r . > "$LAB/rehold-after.txt"
  if grep -qF "$(cat "$LAB/rehold-record1.txt")" "$LAB/rehold-after.txt" 2>/dev/null || python3 -c 'import sys;a=open(sys.argv[1]).read().strip();b=open(sys.argv[2]).read();sys.exit(0 if a in b else 1)' "$LAB/rehold-record1.txt" "$LAB/rehold-after.txt"; then echo "record 1 text: UNCHANGED inside the new body"; else echo "record 1 text: CHANGED"; fi
  ;;
s5)
  say "S5: a real board result (Lavish poll shape) flows through fm-procevent into the intake, for a live work item"
  t add lab-board-work "Ship the board-gated sample" --kind ship --repo sample --start >/dev/null; meta lab-board-work ship
  run cap hold lab-board-work --reason "captain board route choice pending"
  cat > "$LAB/board-source.sh" <<'SH'
#!/usr/bin/env bash
cat <<'OUT'
session:
  status: feedback
  session_ended: false
prompts[1]{tag,text,prompt}:
  "choice","Take the north route","Context data: {\"schema\":\"fm-bearings-answer.v1\",\"question\":\"lab-board-work\",\"selection\":\"north\",\"note\":\"\"}"
OUT
SH
  chmod +x "$LAB/board-source.sh"
  sid=lavish-b0a4d0000000f1e2
  run pe register lavish "$sid" -- "$LAB/board-source.sh"
  run cap bind "$sid"
  run pe start "$sid"
  show lab-board-work
  ;;
s6)
  say "S6 (boundary): explicit release mode, unknown mode, reserved reconcile value, direct answer without --release"
  for i in lab-m-release lab-m-bogus lab-m-reconcile lab-m-direct; do t add $i "Mode sample $i" --kind ship --repo sample --start >/dev/null; meta $i ship; cap hold $i --reason "captain pick" >/dev/null; done
  printf 'lab-m-release\tgo\tGo\trelease\nlab-m-bogus\tgo\tGo\tbogus\nlab-m-reconcile\treconcile\tReconcile\n' | cap answers --source "lab modes"; printf '[exit %s]\n' "$?"
  for i in lab-m-release lab-m-bogus lab-m-reconcile; do show $i; done
  say "direct 'answer' without --release keeps its documented explicit close (not changed by this fix)"
  printf 'The captain said close it.\n' > "$LAB/direct.txt"
  run cap answer lab-m-direct --decision-file "$LAB/direct.txt"
  show lab-m-direct
  ;;
esac
