#!/usr/bin/env bash
# Live driver part 2: captain's words release, "not a ruling" rows, remote-route
# mate home, generated secondmate charter. Usage: live-driver-2.sh <worktree> <scratch>
set -u
WT=$1 SCR=$2
CH="$WT/bin/fm-captain-hold.sh"
step() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return 0; }
ta() { local h=$1; shift; (cd "$h" && tasks-axi "$@"); }
field() { ta "$1" show "$2" --full | grep -E "^  ($3):" ; }
openrc() { local rc=0; FM_HOME=$1 "$CH" open "$2" --distinguish-absent >/dev/null 2>&1 || rc=$?; printf 'open %s --distinguish-absent -> exit %s (0 = held: fm-pr-merge refuses)\n' "$2" "$rc"; }
new_home() {
  local d lab
  d=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  lab=$("$WT/bin/fm-lab-home.sh" create "$d") || exit 1
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n' > "$lab/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$lab/data/backlog.md"
  mkdir -p "$lab/projects/sample" && git init -q -b main "$lab/projects/sample"
  printf '%s\n' "$lab" >> "$SCR/labs"; printf '%s\n' "$lab"
}
live_worker() { mkdir -p "$1/state"; printf 'id=%s\nkind=ship\nrepo=sample\n' "$2" > "$1/state/$2.meta"; echo "(runtime record: state/$2.meta)"; }

P=$(new_home); M=$(new_home)
printf 'fm-mini\n' > "$M/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$M/.fm-secondmate-parent"
mkdir -p "$P/state"

step "S7: the captain's own words still release a genuine mate captain call"
ta "$M" add genuine-call "Genuine call" --kind ship --repo sample --body 'Gated work.' >/dev/null
live_worker "$M" genuine-call
run env FM_HOME="$M" "$CH" hold genuine-call --owner captain --reason "land or drop 18 unpublished commits"
openrc "$M" genuine-call
printf 'Land them.\n' > "$SCR/words.txt"
run env FM_HOME="$M" "$CH" answer genuine-call --decision-file "$SCR/words.txt" --release
field "$M" genuine-call 'state|held'
ta "$M" show genuine-call --full | grep -o 'Captain decision:[^"]*Land them\.' | head -1
openrc "$M" genuine-call
grep 'genuine-call' "$P/state/fm-mini.status"

step "S8: rows that are not captain rulings are refused as --ruling (released, withdrawn, reconciled)"
ta "$M" add target "Target work" --kind ship --repo sample >/dev/null
live_worker "$M" target
run env FM_HOME="$M" "$CH" hold target --owner captain --reason "pick one"
sleep 1
# a withdrawn row: a question withdrawn under a real ruling that names it
run env FM_HOME="$M" "$CH" hold q-withdrawn --owner captain --title "Question about target" --reason "is target needed" --repo sample
sleep 1
run env FM_HOME="$M" "$CH" hold ruling-q --owner captain --title "Ruling Q" --reason "choose" --repo sample
printf 'q-withdrawn is moot.\n' > "$SCR/rq.txt"
run env FM_HOME="$M" "$CH" answer ruling-q --decision-file "$SCR/rq.txt"
printf 'Moot under ruling-q.\n' > "$SCR/ev.txt"
run env FM_HOME="$M" "$CH" withdraw q-withdrawn --evidence-file "$SCR/ev.txt" --ruling ruling-q
# a reconcile-closed row that names target in its title
run env FM_HOME="$M" "$CH" hold q-reconciled --owner captain --title "Reconciled question about target" --reason "target choice" --repo sample
run env FM_HOME="$M" "$CH" reconcile close q-reconciled --evidence-file "$SCR/ev.txt" --verified-outcome moot
field "$M" q-reconciled 'state'
echo "-- released row (genuine-call, released with --release), withdrawn row, reconciled row as --ruling for target:"
printf 'target is moot.\n' > "$SCR/ev2.txt"
run env FM_HOME="$M" "$CH" withdraw target --evidence-file "$SCR/ev2.txt" --ruling genuine-call
run env FM_HOME="$M" "$CH" withdraw target --evidence-file "$SCR/ev2.txt" --ruling q-withdrawn
run env FM_HOME="$M" "$CH" withdraw target --evidence-file "$SCR/ev2.txt" --ruling q-reconciled
field "$M" target 'held'
openrc "$M" target

step "S9: a remote-route mate home (no local parent home): ownerless hold refused, captain hold published to state/parent-replies.status, withdraw on a ruling"
R=$(new_home)
printf 'fm-mini\n' > "$R/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$R/.fm-secondmate-parent"
ta "$R" add remote-work "Remote ship task" --kind ship --repo sample >/dev/null
live_worker "$R" remote-work
run env FM_HOME="$R" "$CH" hold remote-work --reason "retry or fix one red CI check; Main180/181 reserve ask-user decisions to Main"
run env FM_HOME="$R" "$CH" hold remote-work --reason "retry one red check" --owner parent
field "$R" remote-work 'held'
run env FM_HOME="$R" "$CH" hold remote-work --owner captain --reason "land or drop"
ta "$R" show remote-work --full | grep -o 'Decision owner: captain'
openrc "$R" remote-work
sleep 1
run env FM_HOME="$R" "$CH" hold ruling-remote --owner captain --title "Ruling for remote-work" --reason "who decides" --repo sample
printf 'remote-work should just have been done.\n' > "$SCR/rr.txt"
run env FM_HOME="$R" "$CH" answer ruling-remote --decision-file "$SCR/rr.txt"
run env FM_HOME="$R" "$CH" withdraw remote-work --evidence-file "$SCR/ev.txt" --ruling ruling-remote
field "$R" remote-work 'state|held'
openrc "$R" remote-work
echo "remote parent channel (state/parent-replies.status):"; cat "$R/state/parent-replies.status"

step "S10: a generated secondmate charter tells the mate a Main call is never held and hold needs --owner captain"
B=$(new_home)
run env FM_HOME="$B" FM_SECONDMATE_CHARTER='firstmate self-development' FM_SECONDMATE_SCOPE='firstmate repo work' "$WT/bin/fm-brief.sh" fdev --secondmate --no-projects
grep -n 'never held\|--owner captain' "$B/data/fdev/brief.md"
