#!/usr/bin/env bash
# Live drive, part 4 (HEAD 5ca7a50): help-flag and global-flag bypass attempts,
# captain-hold create through intake (with the fleet ledger on), threshold and
# 50-Done window boundaries, concurrent --dup-of appends, remote --moved-to
# paths that need no remote worker, and more closing-proof edges.
# Disposable marked lab home (bin/fm-lab-home.sh env); real tasks-axi.
# Usage: drive-gaps-5ca7a50.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 1
for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE FM_DURATION_FILE FM_DURATION_HOME; do unset "$v"; done
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
trap 'bin/fm-lab-home.sh teardown "$FM_HOME" >/dev/null 2>&1; rm -rf "$FM_HOME"' EXIT
W="$WT/bin/fm-tasks-axi.sh"
B="$FM_HOME/data/backlog.md"
T="$FM_HOME/data/backlog-review.tsv"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$B"
raw() { (cd "$FM_HOME" && TASKS_AXI_FILE="$B" tasks-axi "$@"); }
echo "lab FM_HOME=$FM_HOME (marked lab home); tasks-axi $(tasks-axi --version)"
n=0
run() {  # <label> <expect ok|refused> <args...>
  local label=$1 expect=$2 out rc
  shift 2
  n=$((n+1))
  echo; echo "=== [$n] $label"; echo "\$ fm-tasks-axi.sh $*"
  out=$("$W" "$@" 2>&1); rc=$?
  printf '%s\n' "$out" | sed -n '1,14p' | sed 's/^/    /'
  echo "    -> exit $rc"
  if [ "$expect" = ok ] && [ "$rc" -ne 0 ]; then echo "    !! UNEXPECTED: expected success"; fi
  if [ "$expect" = refused ] && [ "$rc" -eq 0 ]; then echo "    !! UNEXPECTED: expected refusal"; fi
}
rows() { grep -cE "^- \[.\] ($1) " "$B" || true; }

"$W" add lock-a "Lock holder crash" --objective O7 >/dev/null 2>&1

echo; echo "##### help flags cannot file an item past the checks #####"
run "add with an overlapping title and --help" any add hx "Lock holder crash recovery" --objective O7 --help
run "add with no objective and -h" any add hy "Unrelated walrus" -h
echo "    rows hx|hy in backlog.md: $(rows 'hx|hy'); tsv lines: $(grep -cE '^(hx|hy)	' "$T" 2>/dev/null || echo 0)"

echo; echo "##### a global flag before the command cannot skip the checks #####"
run "--backend markdown before add, overlapping title" refused --backend markdown add gx "Lock holder crash recovery" --objective O7
run "--json before add, no objective" refused --json add gy "Granite sloth"
run "-- then add, no objective" refused -- add gz "Granite sloth"
echo "    rows gx|gy|gz in backlog.md: $(rows 'gx|gy|gz')"

echo; echo "##### more add-grammar edges #####"
run "--objective none with a whitespace-only reason" refused add ws-a "Whitespace reason ocelot" --objective none --objective-reason "   "
run "--objective= with an empty value" refused add ws-b "Empty objective ocelot" --objective=
run "--dup-of with an option-like value" refused add ws-c "Option value ocelot" --objective O7 --dup-of --kind
run "--start on add is refused" refused add ws-d "Started ocelot" --objective O7 --start
run "caller --file is refused" refused add ws-e "File ocelot" --objective O7 --file "$B"
run "--body text that holds '--objective O7' is not an objective" refused add ws-f "Body trick ocelot" --body "--objective O7"
run "--dup-of and --not-dup together" refused add ws-g "Lock holder crash recovery" --objective O7 --dup-of lock-a --not-dup lock-a
run "--dup-of this add's own id" refused add lock-a2 "Lock holder crash again" --objective O7 --dup-of lock-a2
run "--not-dup given twice" refused add ws-h "Lock holder crash recovery" --objective O7 --not-dup lock-a --not-dup lock-a
run "a title with no searchable word is filed with no prompt" ok add ws-i "a to of" --objective O7
echo "    rows ws-a..ws-h in backlog.md: $(rows 'ws-[a-h]'); ws-i: $(rows ws-i)"

echo; echo "##### threshold boundary (THRESHOLD 0.25) #####"
"$W" add th-a "alpha bravo" --objective O7 >/dev/null 2>&1
run "1 shared of 4 distinct words = exactly 0.25 is refused" refused add th-b "alpha charlie delta" --objective O7
run "1 shared of 5 distinct words = 0.20 is filed with no prompt" ok add th-c "alpha echo foxtrot golf" --objective O7

echo; echo "##### the newest 50 Done items, and not the 51st #####"
raw add old-z "Zeppelin mooring audit" >/dev/null
raw done old-z --keep 0 >/dev/null
for i in $(seq -w 1 49); do raw add "fill-$i" "Filler task number$i" >/dev/null; raw done "fill-$i" --keep 0 >/dev/null; done
echo "    archive rows: $(grep -c '^- \[x\]' "$FM_HOME/data/done-archive.md")"
run "overlap with the 50th newest Done item is refused" refused add old-y "Zeppelin mooring audit rerun" --objective O7
raw add fill-50 "Filler task number50" >/dev/null; raw done fill-50 --keep 0 >/dev/null
echo "    archive rows: $(grep -c '^- \[x\]' "$FM_HOME/data/done-archive.md")"
run "overlap with the 51st newest Done item is filed with no prompt" ok add old-y "Zeppelin mooring audit rerun" --objective O7
raw add new-z "Quokka mooring census" >/dev/null
raw done new-z --keep 0 >/dev/null
run "overlap with the newest Done item is refused" refused add new-y "Quokka mooring census rerun" --objective O7

echo; echo "##### eight concurrent --dup-of adds onto one kept item #####"
"$W" add kept-c "Concurrent heron ledger" --objective O7 >/dev/null 2>&1
for i in 1 2 3 4 5 6 7 8; do
  ( "$W" add "cc-$i" "Concurrent heron ledger copy$i" --objective O7 --body "marker-cc-$i" --dup-of kept-c >"$FM_HOME/cc-$i.out" 2>&1; echo $? >"$FM_HOME/cc-$i.rc" ) &
done
wait
for i in 1 2 3 4 5 6 7 8; do printf '    cc-%s: exit %s: %s\n' "$i" "$(cat "$FM_HOME/cc-$i.rc")" "$(sed -n '1p' "$FM_HOME/cc-$i.out")"; done
body=$("$W" show kept-c --full 2>&1)
found=0; for i in 1 2 3 4 5 6 7 8; do if printf '%s' "$body" | grep -q "marker-cc-$i"; then found=$((found+1)); fi; done
ok=0; for i in 1 2 3 4 5 6 7 8; do [ "$(cat "$FM_HOME/cc-$i.rc")" = 0 ] && ok=$((ok+1)); done
echo "    first pass: $ok exited 0; $found markers landed (each exit 0 must have a marker; no write is lost)"
echo "    the refused ones run again, one at a time, as their message says:"
for i in 1 2 3 4 5 6 7 8; do [ "$(cat "$FM_HOME/cc-$i.rc")" = 0 ] || "$W" add "cc-$i" "Concurrent heron ledger copy$i" --objective O7 --body "marker-cc-$i" --dup-of kept-c 2>&1 | sed -n '1p' | sed "s/^/    cc-$i: /"; done
body=$("$W" show kept-c --full 2>&1)
found=0; for i in 1 2 3 4 5 6 7 8; do printf '%s' "$body" | grep -q "marker-cc-$i" && found=$((found+1)); done
echo "    markers in kept-c body: $found of 8; rows cc-1..8 filed: $(rows 'cc-[1-8]')"

echo; echo "##### captain-hold create goes through intake #####"
touch "$FM_HOME/config/fleet-ledger"
echo "\$ fm-captain-hold.sh hold cap-new --reason 'pick a vendor' --title 'Choose the tapir vendor' --repo firstmate"
"$WT/bin/fm-captain-hold.sh" hold cap-new --reason "pick a vendor" --title "Choose the tapir vendor" --repo firstmate 2>&1 | sed -n '1,8p' | sed 's/^/    /'
echo "    -> exit ${PIPESTATUS[0]}"
grep -n 'cap-new' "$B" | sed 's/^/    backlog: /'
grep -n '^cap-new	' "$T" | sed 's/^/    tsv: /'
led=$(ls "$FM_HOME"/state/fleet-ledger* "$FM_HOME"/data/fleet-ledger* 2>/dev/null | head -1)
echo "    ledger file: ${led:-none}; filed records for cap-new: $(grep -h 'cap-new' "$FM_HOME"/state/fleet-ledger* "$FM_HOME"/data/fleet-ledger* 2>/dev/null | grep -c '"filed"\|filed' || true)"
grep -h 'cap-new' "$FM_HOME"/state/fleet-ledger* "$FM_HOME"/data/fleet-ledger* 2>/dev/null | sed 's/^/    ledger: /'
echo "\$ fm-captain-hold.sh hold cap-dup --reason 'which lock?' --title 'Lock holder crash decision' --repo firstmate"
"$WT/bin/fm-captain-hold.sh" hold cap-dup --reason "which lock?" --title "Lock holder crash decision" --repo firstmate 2>&1 | sed 's/^/    /'
echo "    -> exit ${PIPESTATUS[0]}"
echo "    rows cap-dup: $(rows cap-dup); tsv: $(grep -c '^cap-dup	' "$T" || true); lock-a hold: $("$W" show lock-a 2>&1 | grep -E 'hold' | tr '\n' ' ')"

echo; echo "##### closing-proof edges #####"
"$W" add k1 "Kept marmot item" --objective O7 >/dev/null 2>&1
"$W" add d1 "Spare narwhal item" --objective O7 >/dev/null 2>&1
raw start k1 >/dev/null
run "--duplicate-of an In flight kept item closes" ok done d1 --duplicate-of k1
grep -n '^- \[x\] d1 ' "$B" | sed 's/^/    /'
"$W" show d1 --full 2>&1 | grep -E 'note|duplicate' | sed 's/^/    /'
"$W" show k1 --full 2>&1 | grep -E 'body' | sed 's/^/    /'
grep -h '"task":"d1"' "$FM_HOME"/state/fleet-ledger* 2>/dev/null | sed 's/^/    ledger: /'
run "--duplicate-of on an already closed item" refused done d1 --duplicate-of k1
run "--duplicate-of itself" refused done k1 --duplicate-of k1
run "--duplicate-of an item that does not exist" refused done no-such --duplicate-of k1
"$W" add d2 "Pelican quarry drain" --objective O7 >/dev/null 2>&1
run "--duplicate-of and --moved-to together" refused done d2 --duplicate-of k1 --moved-to sm-x k1
run "--moved-to with one value" refused done d2 --moved-to sm-x
run "--duplicate-of with --note" refused done d2 --duplicate-of k1 --note hi
"$W" add own-c "Owner list probe yak" --objective O7 --body "Owner 2026-11-01: keep this one" >/dev/null 2>&1
"$W" add own-d "Owner colon probe yak" --objective O7 --body "Captain: hold it" --not-dup own-c >/dev/null 2>&1
run "owner item (Owner <date>:) refuses --duplicate-of" refused done own-c --duplicate-of k1
run "owner item (Captain:) refuses --duplicate-of" refused done own-d --duplicate-of k1
printf 'Drop it.\n' > "$FM_HOME/w.txt"
"$W" add own-e "Gecko release vault" --objective O7 --kind ship --repo firstmate --body "Captain: hold it" >/dev/null 2>&1
run "kind ship owner item refuses the proof" refused done own-e --duplicate-of k1
run "kind ship owner item closes with the words the refusal names (--drop-file)" ok done own-e --drop-file "$FM_HOME/w.txt"
ls -l "$FM_HOME/data/own-e/captain-drop.md" | sed 's/^/    /'
echo "    default kind of own-d: $("$W" show own-d 2>&1 | grep '  kind:')"
run "default-kind owner item: the words route the refusal names (--drop-file)" ok done own-d --drop-file "$FM_HOME/w.txt"
run "default-kind owner item: plain done with a note, no words (closes as before this change?)" any done own-d --note "plain close"

echo; echo "##### remote --moved-to paths that need no remote worker #####"
cat > "$FM_HOME/data/secondmates.md" <<EOF
- sm-loop - Remote alias of this home (host: localhost; root: $WT; home: $FM_HOME; scope: alias; projects: p; added 2026-11-03)
- sm-gone - Remote home on a host that does not resolve (host: fm-lab-nohost.invalid; root: /opt/fm; home: /opt/fm-home; scope: gone; projects: q; added 2026-11-03)
EOF
"$W" add mv-r "Remote move albatross" --objective O7 >/dev/null 2>&1
run "--moved-to a remote alias of this same backlog (real ssh -G, no connection)" refused done mv-r --moved-to sm-loop k1
run "--moved-to a remote home that cannot be reached" refused done mv-r --moved-to sm-gone some-item
grep -n 'mv-r' "$B" | sed 's/^/    /'

echo; echo "--- final backlog-review.tsv:"; sed 's/^/    /' "$T"
echo "--- guard events (guard, decision, rule):"
jq -rc '[.guard, .decision, (.rule // "")] | @tsv' "$FM_HOME/state/guard-events.jsonl" 2>/dev/null | sort | uniq -c | sed 's/^/    /'
