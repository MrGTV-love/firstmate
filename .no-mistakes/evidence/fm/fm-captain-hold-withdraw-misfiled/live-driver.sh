#!/usr/bin/env bash
# Live driver: real bin/fm-captain-hold.sh (head and base) against disposable
# fm-lab-home homes. Usage: live-driver.sh <worktree> <base-tree> <scratch>
set -u
WT=$1 BASE=$2 SCR=$3
CH="$WT/bin/fm-captain-hold.sh"
CH_BASE="$BASE/bin/fm-captain-hold.sh"
REAL_TA=$(command -v tasks-axi)

step() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return 0; }
ta() { local h=$1; shift; (cd "$h" && tasks-axi "$@"); }
field() { ta "$1" show "$2" --full | grep -E "^  ($3):" ; }
body() { ta "$1" show "$2" --full | sed -n '/^  body:/,$p' | (. "$WT/bin/fm-hold-reason-lib.sh"; fm_hold_reason_decode_stream); }
openrc() { local rc=0; FM_HOME=$1 "$CH" open "$2" --distinguish-absent >/dev/null 2>&1 || rc=$?; printf 'open %s --distinguish-absent -> exit %s (0 = still held: fm-pr-merge refuses; 1/3 = merge gate allows)\n' "$2" "$rc"; }

new_home() {  # <dir>; a marked lab home with a markdown backlog
  local d lab
  d=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  lab=$("$WT/bin/fm-lab-home.sh" create "$d") || exit 1
  cat > "$lab/.tasks.toml" <<'T'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
T
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$lab/data/backlog.md"
  mkdir -p "$lab/projects/sample" && git init -q -b main "$lab/projects/sample"
  printf '%s\n' "$lab" >> "$SCR/labs"
  printf '%s\n' "$lab"
}
live_worker() {  # <home> <id>: a runtime record, as a dispatched worker has
  mkdir -p "$1/state"; printf 'id=%s\nkind=ship\nrepo=sample\n' "$2" > "$1/state/$2.meta"
  echo "(runtime record written: state/$2.meta - a worker owns $2)"
}
run_head() { printf '$ %s\n' "$*"; local out rc=0; out=$("$@" 2>&1) || rc=$?; printf '%s\n' "$out" | head -1; printf '[exit %s]\n' "$rc"; }
make_mate() {  # <parent> <mate>
  printf 'fm-mini\n' > "$2/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$1" > "$2/.fm-secondmate-parent"
  mkdir -p "$1/state"
}
unmate() { mv "$1/.fm-secondmate-home" "$SCR/m.home"; mv "$1/.fm-secondmate-parent" "$SCR/m.parent"; }
remate() { mv "$SCR/m.home" "$1/.fm-secondmate-home"; mv "$SCR/m.parent" "$1/.fm-secondmate-parent"; }

PR290_REASON='retry or fix one red CI check on PR 290; Main180/181 reserve ask-user decisions to Main'

step "S1-before (base commit 28bb500b2): a mate home files the PR 290 shape as a captain hold, and no honest close exists"
PB=$(new_home); MB=$(new_home); make_mate "$PB" "$MB"
ta "$MB" add fm-host-hook-successor-watcher-race "Watcher race fix" --kind ship --repo sample --body 'Ship PR 290.' >/dev/null
live_worker "$MB" fm-host-hook-successor-watcher-race
run env FM_HOME="$MB" "$CH_BASE" hold fm-host-hook-successor-watcher-race --reason "$PR290_REASON"
field "$MB" fm-host-hook-successor-watcher-race 'held|hold_kind'
printf 'Main decided one unchanged-head retry; CI 34/34 green.\n' > "$SCR/ev-base.txt"
run env FM_HOME="$MB" "$CH_BASE" reconcile close fm-host-hook-successor-watcher-race --evidence-file "$SCR/ev-base.txt" --verified-outcome moot
run_head env FM_HOME="$MB" "$CH_BASE" withdraw fm-host-hook-successor-watcher-race --evidence-file "$SCR/ev-base.txt" --ruling none
FM_HOME="$MB" CH="$CH_BASE" openrc "$MB" fm-host-hook-successor-watcher-race

step "S1-after (head): the same mate-home filing is refused at the source"
P=$(new_home); M=$(new_home); make_mate "$P" "$M"
ta "$M" add fm-host-hook-successor-watcher-race "Watcher race fix" --kind ship --repo sample --body 'Ship PR 290.' >/dev/null
run env FM_HOME="$M" "$CH" hold fm-host-hook-successor-watcher-race --reason "$PR290_REASON"
run env FM_HOME="$M" "$CH" hold fm-host-hook-successor-watcher-race --reason "$PR290_REASON" --owner parent
run env FM_HOME="$M" "$CH" hold fm-host-hook-successor-watcher-race --reason "$PR290_REASON" --owner main
field "$M" fm-host-hook-successor-watcher-race 'held|hold_kind'
openrc "$M" fm-host-hook-successor-watcher-race
echo "parent channel after refusals:"; cat "$P/state/fm-mini.status" 2>/dev/null || echo "(empty: nothing filed as a captain call)"
run_head env FM_HOME="$M" "$CH" decide fm-host-hook-successor-watcher-race
run_head env FM_HOME="$M" "$CH" classify fm-host-hook-successor-watcher-race --owner parent

step "S1b: the legacy fm-decision-hold.sh shim is refused the same way in a mate home"
run env FM_HOME="$M" "$WT/bin/fm-decision-hold.sh" hold shim-origin k1 --title "Shim call" --reason "retry the check" --repo sample
run env FM_HOME="$M" "$WT/bin/fm-decision-hold.sh" hold shim-origin k2 --title "Shim call" --reason "needs the captain" --repo sample --owner captain
field "$M" shim-origin-decision-k2 'held|hold_kind'

step "S2: a main home cannot name a parent owner, and its ordinary hold still works"
H=$(new_home)
ta "$H" add main-work "Main work" --kind ship --repo sample >/dev/null
run env FM_HOME="$H" "$CH" hold main-work --reason "no parent here" --owner parent
run env FM_HOME="$H" "$CH" hold main-work --reason "captain choice"
openrc "$H" main-work

step "S3: a genuine captain call in a mate home: --owner captain is recorded and published"
ta "$M" add genuine-call "Genuine call" --kind ship --repo sample --body 'Gated work.' >/dev/null
live_worker "$M" genuine-call
run env FM_HOME="$M" "$CH" hold genuine-call --owner captain --reason "land or drop 18 unpublished commits"
body "$M" genuine-call
echo "parent channel:"; cat "$P/state/fm-mini.status"
openrc "$M" genuine-call
printf 'Main decided this was its own call.\n' > "$SCR/ev-main.txt"
run env FM_HOME="$M" "$CH" withdraw genuine-call --evidence-file "$SCR/ev-main.txt"
run env FM_HOME="$M" "$CH" reconcile close genuine-call --evidence-file "$SCR/ev-main.txt" --verified-outcome moot
openrc "$M" genuine-call

step "S4: the real PR 290 shape: a legacy captain hold (filed before owners were recorded) on a mate ship task"
ta "$M" add pr290-task "Watcher race (legacy hold)" --kind ship --repo sample --body 'Ship PR 290.' >/dev/null
live_worker "$M" pr290-task
unmate "$M"
run env FM_HOME="$M" "$CH" hold pr290-task --reason "$PR290_REASON"
remate "$M"
body "$M" pr290-task | head -3
openrc "$M" pr290-task
printf 'Main decided one unchanged-head retry; CI 34 of 34 green; DeepSeek PASS at 17154e984b.\n' > "$SCR/ev290.txt"
echo "-- adversarial: no ruling, absent ruling, open work as ruling, a ruling that does not name the task, a ruling made before the hold"
run env FM_HOME="$M" "$CH" withdraw pr290-task --evidence-file "$SCR/ev290.txt"
run env FM_HOME="$M" "$CH" withdraw pr290-task --evidence-file "$SCR/ev290.txt" --ruling no-such-ruling
run env FM_HOME="$M" "$CH" withdraw pr290-task --evidence-file "$SCR/ev290.txt" --ruling genuine-call
run env FM_HOME="$M" "$CH" withdraw pr290-task --evidence-file "$SCR/ev290.txt" --ruling pr290-task
run env FM_HOME="$M" "$CH" hold other-ruling --owner captain --title "Unrelated ruling" --reason "pick a colour" --repo sample
printf 'Blue.\n' > "$SCR/blue.txt"
run env FM_HOME="$M" "$CH" answer other-ruling --decision-file "$SCR/blue.txt"
run env FM_HOME="$M" "$CH" withdraw pr290-task --evidence-file "$SCR/ev290.txt" --ruling other-ruling
echo "-- the evidence file naming the task does not make an unrelated ruling count"
printf 'pr290-task is moot under other-ruling.\n' > "$SCR/ev-names.txt"
run env FM_HOME="$M" "$CH" withdraw pr290-task --evidence-file "$SCR/ev-names.txt" --ruling other-ruling
run env FM_HOME="$M" "$CH" reconcile close pr290-task --evidence-file "$SCR/ev290.txt" --verified-outcome moot
field "$M" pr290-task 'held|state'
openrc "$M" pr290-task
echo "-- a ruling recorded BEFORE a hold cannot release it"
ta "$M" add later-held "Later held" --kind ship --repo sample >/dev/null
run env FM_HOME="$M" "$CH" hold early-ruling --owner captain --title "Early ruling on later-held" --reason "is later-held needed" --repo sample
printf 'later-held is moot.\n' > "$SCR/early.txt"
run env FM_HOME="$M" "$CH" answer early-ruling --decision-file "$SCR/early.txt"
sleep 2
run env FM_HOME="$M" "$CH" hold later-held --owner captain --reason "pick an approach"
run env FM_HOME="$M" "$CH" withdraw later-held --evidence-file "$SCR/ev-main.txt" --ruling early-ruling
openrc "$M" later-held
echo "-- the captain rules (his own recorded words naming the task); withdraw then releases it honestly"
sleep 1
run env FM_HOME="$M" "$CH" hold ruling-290 --owner captain --title "Retry rule for red checks" --reason "who decides CI retries" --repo sample
printf 'CI retries are not my call; pr290-task should just have been done.\n' > "$SCR/ruling290.txt"
run env FM_HOME="$M" "$CH" answer ruling-290 --decision-file "$SCR/ruling290.txt"
run env FM_HOME="$M" "$CH" withdraw pr290-task --evidence-file "$SCR/ev290.txt" --ruling ruling-290
field "$M" pr290-task 'state|held|hold_kind'
body "$M" pr290-task
openrc "$M" pr290-task
echo "tasks-axi ready:"; ta "$M" ready
echo "parent channel:"; cat "$P/state/fm-mini.status"
echo "-- replay is idempotent"
run env FM_HOME="$M" "$CH" withdraw pr290-task --evidence-file "$SCR/ev290.txt" --ruling ruling-290
printf 'withdrawn records on pr290-task: %s\n' "$(ta "$M" show pr290-task --full | grep -c 'Resolution mode: withdrawn')"
echo "-- divergence guard and open no longer see it"
run env FM_HOME="$M" "$CH" diverged

step "S5: a moot question-shaped captain row is closed by withdraw, not left as dispatchable work"
run env FM_HOME="$M" "$CH" hold demand-map-bound --owner captain --title "Which error bound for the demand map" --reason "pick the bound" --repo sample
sleep 1
run env FM_HOME="$M" "$CH" hold ruling-a --owner captain --title "Ruling A" --reason "choose the approach" --repo sample
printf 'Ruling A: use the demand map; demand-map-bound is moot.\n' > "$SCR/ra.txt"
run env FM_HOME="$M" "$CH" answer ruling-a --decision-file "$SCR/ra.txt"
run env FM_HOME="$M" "$CH" withdraw demand-map-bound --evidence-file "$SCR/ev-main.txt" --ruling ruling-a
field "$M" demand-map-bound 'state|held'
echo "tasks-axi ready:"; ta "$M" ready

step "S6: a withdraw whose release fails is retried with edited evidence and another ruling: one record, the original key, the recorded ruling"
FB="$SCR/fakebin"; mkdir -p "$FB"
cat > "$FB/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = unhold ] && [ -e "$SCR/fail-unhold" ]; then rm -f "$SCR/fail-unhold"; echo "injected unhold failure" >&2; exit 1; fi
exec "$REAL_TA" "\$@"
SH
chmod +x "$FB/tasks-axi"
ta "$M" add retry-work "Retry work" --kind ship --repo sample >/dev/null
run env FM_HOME="$M" "$CH" hold retry-work --owner captain --reason "pick one"
sleep 1
for r in ruling-one ruling-two; do
  run env FM_HOME="$M" "$CH" hold "$r" --owner captain --title "Ruling $r" --reason "choose" --repo sample
  printf 'retry-work is moot.\n' > "$SCR/r.txt"
  run env FM_HOME="$M" "$CH" answer "$r" --decision-file "$SCR/r.txt"
done
printf 'Moot under the ruling.\n' > "$SCR/ev-r.txt"
: > "$SCR/fail-unhold"
run env PATH="$FB:$PATH" FM_HOME="$M" "$CH" withdraw retry-work --evidence-file "$SCR/ev-r.txt" --ruling ruling-one
field "$M" retry-work 'held'
printf 'Moot under the ruling; edited evidence.\n' > "$SCR/ev-r.txt"
run env PATH="$FB:$PATH" FM_HOME="$M" "$CH" withdraw retry-work --evidence-file "$SCR/ev-r.txt" --ruling ruling-two
field "$M" retry-work 'held|state'
printf 'withdrawn records on retry-work: %s\n' "$(ta "$M" show retry-work --full | grep -c 'Resolution mode: withdrawn')"
ta "$M" show retry-work --full | grep 'Withdrawn by' 
echo "parent channel lines for retry-work:"; grep 'retry-work' "$P/state/fm-mini.status"
