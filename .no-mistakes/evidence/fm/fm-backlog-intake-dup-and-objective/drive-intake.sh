#!/usr/bin/env bash
# Drives bin/fm-tasks-axi.sh (real wrapper, real tasks-axi) against two disposable lab homes.
# Args: <worktree>
set -u
WT=$1; W="$WT/bin/fm-tasks-axi.sh"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"; A=$FM_HOME; AT=$TMUX_TMPDIR
B=$(FM_HOME= ; eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"; echo "$FM_HOME")
export FM_HOME=$A
printf '## In flight\n\n## Queued\n\n## Done\n' > "$A/data/backlog.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$B/data/backlog.md"
: > "$A/config/fleet-ledger"
cd "$WT"
PASS=0; FAILS=0
hdr() { printf '\n==== %s ====\n' "$*"; }
# run <expected-rc|nz> <grep-required or ''> -- cmd...
ck() { local want=$1 needle=$2; shift 3; local out rc; out=$("$@" 2>&1); rc=$?
  printf '$ %s\n' "$(printf '%q ' "${@##$WT/}" | sed "s#$A#\$LAB_A#g; s#$B#\$LAB_B#g")"; printf '%s\n' "$out" | sed "s#$A#\$LAB_A#g; s#$B#\$LAB_B#g" | sed 's/^/  | /' | cut -c1-260; echo "  rc=$rc"
  local ok=1; if [ "$want" = nz ]; then [ "$rc" != 0 ] || ok=0; else [ "$rc" = "$want" ] || ok=0; fi
  if [ -n "$needle" ]; then case "$out" in *"$needle"*) ;; *) ok=0 ;; esac; fi
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); echo "  CHECK ok"; else FAILS=$((FAILS+1)); echo "  CHECK FAILED (wanted rc=$want needle='$needle')"; fi; }
fact() { local d=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  FACT ok: $d"; else FAILS=$((FAILS+1)); echo "  FACT FAILED: $d"; fi; }
nofact() { local d=$1; shift; if "$@" >/dev/null 2>&1; then FAILS=$((FAILS+1)); echo "  FACT FAILED: $d"; else PASS=$((PASS+1)); echo "  FACT ok: $d"; fi; }
inlog() { grep -q -- "$2" "$1"; }
BL=$A/data/backlog.md; TSV=$A/data/backlog-review.tsv

hdr "1 objective required"
ck 2 "objective" -- "$W" add obj-a "Alpha zebra quokka widget"
nofact "refused add filed nothing" inlog "$BL" obj-a
ck 2 "O9" -- "$W" add obj-a "Alpha zebra quokka widget" --objective O9
ck 2 "reason" -- "$W" add obj-a "Alpha zebra quokka widget" --objective none
nofact "unknown id and none-without-reason filed nothing" inlog "$BL" obj-a
ck 0 "" -- "$W" add obj-a "Alpha zebra quokka widget" --objective O3 --kind ship --repo notes
ck 0 "" -- "$W" add obj-b "Lantern parsley orbit gadget" --objective none --objective-reason "fixture with no objective"
ck 0 "" -- "$W" create obj-c "Violet harbor cactus sprocket" --objective=O7
ck 0 "" -- "$W" task add obj-d --title "Marble tundra pepper flange" --objective O1
ck 0 "" -- "$W" add --mint "Saffron beacon walnut gasket" --objective O6
echo "--- data/backlog-review.tsv"; cut -f1-4 "$TSV" | sed 's/^/  | /'
fact "O3 row lands in tsv" grep -qE '^obj-a	[^	]*	O3' "$TSV"
fact "none row keeps its reason" grep -qE '^obj-b	[^	]*	none	fixture with no objective' "$TSV"
fact "create alias row" grep -qE '^obj-c	[^	]*	O7' "$TSV"
fact "task add --title row" grep -qE '^obj-d	[^	]*	O1' "$TSV"
fact "mint row names O6" grep -qE '	O6' "$TSV"

hdr "1b answer shows no token"
ck 0 "" -- "$W" add tok-a "Quartz meadow ribbon piston" --objective O7 --json
out=$("$W" add tok-b "Cobalt ferret anchor spindle" --objective O7 --body hello --json 2>&1); printf '%s\n' "$out" | sed 's/^/  | /'
case "$out" in *fm-add*) FAILS=$((FAILS+1)); echo "  FACT FAILED: token leaked in the answer";; *'"body": "hello"'*|*'"body":"hello"'*) PASS=$((PASS+1)); echo "  FACT ok: --body hello answers hello";; *) FAILS=$((FAILS+1)); echo "  FACT FAILED: body not hello";; esac

hdr "2 duplicate check at intake"
ck 0 "" -- "$W" add dup-kept "Repair nightly storage cleanup job" --objective O7 --kind ship --repo notes --body "kept body line"
BEFORE=$(cksum < "$BL")
ck 2 "--not-dup" -- "$W" add dup-new "Repair nightly storage cleanup script" --objective O7 --kind ship --repo notes
fact "refusal names the kept neighbour" sh -c "'$W' add dup-new 'Repair nightly storage cleanup script' --objective O7 --kind ship --repo notes 2>&1 | grep -q dup-kept"
fact "refusal prints --dup-of override" sh -c "'$W' add dup-new 'Repair nightly storage cleanup script' --objective O7 --kind ship --repo notes 2>&1 | grep -q -- '--dup-of'"
[ "$BEFORE" = "$(cksum < "$BL")" ] && { PASS=$((PASS+1)); echo "  FACT ok: refused adds left backlog.md unchanged"; } || { FAILS=$((FAILS+1)); echo "  FACT FAILED: backlog changed"; }
ck 2 "" -- "$W" add dup-new "Repair nightly storage cleanup script" --objective O7 --not-dup obj-a
ck 2 "" -- "$W" add dup-new "Repair nightly storage cleanup script" --objective O7 --not-dup dup-kept --dup-of dup-kept
ck 0 "" -- "$W" add dup-new "Repair nightly storage cleanup script" --objective O7 --kind ship --repo notes --body "extra occurrence detail" --dup-of dup-kept
nofact "--dup-of files nothing" inlog "$BL" dup-new-row-marker
nofact "--dup-of leaves no new row" sh -c "grep -qE '^- \[.\] .*dup-new' '$BL'"
"$W" show dup-kept --full 2>&1 | sed 's/^/  | /'
fact "kept item got the new title" sh -c "'$W' show dup-kept --full | grep -q 'cleanup script'"
fact "kept item got the new body" sh -c "'$W' show dup-kept --full | grep -q 'extra occurrence detail'"
ck 0 "" -- "$W" add dup-not "Repair nightly storage cleanup rotation" --objective O7 --kind ship --repo notes --not-dup dup-kept
fact "--not-dup files the item" sh -c "'$W' show dup-not"
fact "--not-dup row in tsv" grep -qE '^dup-not	' "$TSV"
ck 0 "" -- "$W" add dup-free "Emerald kiosk trombone valve" --objective O7
fact "unrelated title is filed with no prompt" sh -c "'$W' show dup-free"

hdr "3 no bypass of add checks"
for f in --force --yes --no-check --skip-intake --no-objective; do
  ck nz "" -- "$W" add byp-x "Repair nightly storage cleanup script" $f
done
ck 2 "" -- env FM_GATE_REFUSE_BYPASS=1 FM_TASKS_AXI_NO_INTAKE=1 FM_INTAKE_BYPASS=1 FM_SKIP_INTAKE=1 "$W" add byp-y "Repair nightly storage cleanup script"
ck 2 "" -- env FM_GATE_REFUSE_BYPASS=1 FM_INTAKE_BYPASS=1 "$W" add byp-y "Repair nightly storage cleanup script" --objective O7
nofact "no bypass spelling filed a row" sh -c "grep -qE 'byp-[xy]' '$BL'"

hdr "4 last 50 Done window, active and archive"
"$W" add win-oldest "Aardvark juniper cobbler ratchet" --objective O7 >/dev/null 2>&1
"$W" "done" win-oldest >/dev/null 2>&1
for i in $(seq 1 50); do
  w=$(printf 'zz%03daaa zz%03dbbb zz%03dccc' "$i" "$i" "$i"); "$W" add "win-$i" "$w" --objective O7 >/dev/null 2>&1; "$W" "done" "win-$i" >/dev/null 2>&1
done
ls -la "$A/data" | sed 's/^/  | /'
grep -c 'win-' "$BL" | sed 's/^/  active rows win-: /'; grep -c 'win-' "$A/data/done-archive.md" 2>/dev/null | sed 's/^/  archived rows win-: /'
"$W" add win-keep "Hazel dynamo plover winch" --objective O7 >/dev/null 2>&1; "$W" "done" win-keep --keep 0 >/dev/null 2>&1
grep -c 'win-keep' "$BL" | sed 's/^/  win-keep in active: /'
ck 2 "win-keep" -- "$W" add win-new "Hazel dynamo plover winch refit" --objective O7
ck 2 "not-dup" -- "$W" add win-dupof "Hazel dynamo plover winch refit" --objective O7 --dup-of win-keep
ck 0 "" -- "$W" add win-free "Aardvark juniper cobbler ratchet refit" --objective O7
fact "a Done row older than 50 no longer stops an add" sh -c "'$W' show win-free"

hdr "5 --duplicate-of closes on proof"
"$W" add k1 "Topaz gondola fennel axle" --objective O7 --kind ship --repo notes --body "kept one" >/dev/null 2>&1
"$W" add d1 "Crimson walrus tulip bushing" --objective O7 --kind ship --repo notes --body "dup body words" >/dev/null 2>&1
ck 0 "" -- "$W" "done" d1 --duplicate-of k1
fact "row closed with the proof note" sh -c "grep -E '^- \[x\].*d1' '$BL' | grep -q 'duplicate of k1'"
"$W" show k1 --full 2>&1 | sed 's/^/  | /'
fact "kept item got duplicate title" sh -c "'$W' show k1 --full | grep -q 'Crimson walrus'"
fact "kept item got duplicate body" sh -c "'$W' show k1 --full | grep -q 'dup body words'"
fact "ledger records the close" sh -c "grep -h task.closed '$A'/state/*ledger* '$A'/data/*ledger* 2>/dev/null | grep -q d1"

hdr "5b --duplicate-of refusals"
"$W" add o1 "Amber lizard pumice coupler" --objective O7 --kind ship --repo notes --body "Captain 2027-01-06 asked for this." >/dev/null 2>&1
"$W" add o2 "Indigo ostrich clover bracket" --objective O7 --kind ship --repo notes --body "Owner: please do this." >/dev/null 2>&1
"$W" add o3 "Captain's words about a sienna otter hinge" --objective O7 --kind ship --repo notes >/dev/null 2>&1
"$W" add o-neg "Teal badger gravel lock owner: decision on owner 2026" --objective O7 --kind ship --repo notes --body "the lock owner decision" >/dev/null 2>&1
ck 2 "owner" -- "$W" "done" o1 --duplicate-of k1
ck 2 "owner" -- "$W" "done" o2 --duplicate-of k1
ck 2 "owner" -- "$W" "done" o3 --duplicate-of k1
fact "owner items stay open" sh -c "grep -qE '^- \[ \].*o1' '$BL' && grep -qE '^- \[ \].*o2' '$BL' && grep -qE '^- \[ \].*o3' '$BL'"
ck 0 "" -- "$W" "done" o-neg --duplicate-of k1
"$W" add h1 "Olive cougar marigold shim" --objective O7 --kind ship --repo notes >/dev/null 2>&1
env -u FM_ROOT_OVERRIDE "$WT/bin/fm-captain-hold.sh" hold h1 --question "Lab fixture: should this hold stay open?" --context "fixture" 2>&1 | sed 's/^/  hold| /' | cut -c1-200
ck 2 "owner call" -- "$W" "done" h1 --duplicate-of k1
"$W" add l1 "Pewter gibbon saffron rivet" --objective O7 --kind ship --repo notes >/dev/null 2>&1
printf 'kind=ship\n' > "$A/state/l1.meta"
ck 2 "live task" -- "$W" "done" l1 --duplicate-of k1
"$W" add c1 "Bronze ibis nutmeg clevis" --objective O7 --kind ship --repo notes >/dev/null 2>&1
"$W" add c2 "Ivory marmot basil gimbal" --objective O7 >/dev/null 2>&1; "$W" "done" c2 >/dev/null 2>&1
ck 2 "not Queued" -- "$W" "done" c1 --duplicate-of c2
ck 2 "does not exist" -- "$W" "done" c1 --duplicate-of nope-missing
ck 2 "itself" -- "$W" "done" c1 --duplicate-of c1
"$W" add dep1 "Slate puffin thyme yoke" --objective O7 --kind ship --repo notes >/dev/null 2>&1
"$W" add dep2 "Coral magpie sorrel tappet" --objective O7 --kind ship --repo notes --blocked-by dep1 >/dev/null 2>&1 || "$W" block dep2 --by dep1 >/dev/null 2>&1
ck 2 "still blocks" -- "$W" "done" dep1 --duplicate-of k1
ck nz "not combine" -- "$W" "done" c1 --duplicate-of k1 --note "x"
ck nz "not combine" -- "$W" "done" c1 --duplicate-of k1 --pr https://github.com/MrGTV-love/firstmate/pull/367
ck 0 "" -- "$W" "done" c1 --duplicate-of k1
ck nz "" -- "$W" "done" c1 --duplicate-of k1

hdr "6 --moved-to closes on proof (local home)"
FM_HOME=$B "$W" add dest-open "Mustard jackal chervil pawl" --objective O7 >/dev/null 2>&1
FM_HOME=$B "$W" add dest-done "Plum tapir lovage cam" --objective O7 >/dev/null 2>&1; FM_HOME=$B "$W" "done" dest-done >/dev/null 2>&1
ln -s "$A" "$A.link"
{ printf -- '- sm-b - A lab peer home (home: %s; scope: lab; projects: p; added 2026-11-01)\n' "$B"
  printf -- '- sm-self - This home (home: %s; scope: lab; projects: p; added 2026-11-01)\n' "$A"
  printf -- '- sm-link - Symlink to this home (home: %s.link; scope: lab; projects: p; added 2026-11-01)\n' "$A"
  printf -- '- sm-twice - One (home: %s; scope: lab; projects: p; added 2026-11-01)\n' "$B"
  printf -- '- sm-twice - Two (home: %s; scope: lab; projects: p; added 2026-11-01)\n' "$B"
  printf -- '- sm-unreach - Unreachable real ssh host (host: fm-lab-no-such-host.invalid; root: %s; home: /tmp/none; scope: lab; projects: p; added 2026-11-01)\n' "$WT"
} > "$A/data/secondmates.md"
"$W" add m1 "Saddle heron dill sprag" --objective O7 --kind ship --repo notes >/dev/null 2>&1
ck 2 "not one registered home" -- "$W" "done" m1 --moved-to sm-none dest-open
ck 2 "not one registered home" -- "$W" "done" m1 --moved-to sm-twice dest-open
ck 2 "has no item" -- "$W" "done" m1 --moved-to sm-b dest-absent
ck 2 "not open" -- "$W" "done" m1 --moved-to sm-b dest-done
ck 2 "itself" -- "$W" "done" m1 --moved-to sm-self m1
ck 2 "itself" -- "$W" "done" m1 --moved-to sm-link m1
ck nz "" -- timeout 60 "$W" "done" m1 --moved-to sm-unreach dest-open
fact "m1 still open after every refusal" sh -c "grep -qE '^- \[ \].*m1' '$BL'"
ck nz "two values" -- "$W" "done" m1 --moved-to=sm-b dest-open
ck nz "not both" -- "$W" "done" m1 --moved-to sm-b dest-open --duplicate-of k1
ck 2 "owner" -- "$W" "done" o1 --moved-to sm-b dest-open
ck 2 "owner call" -- "$W" "done" h1 --moved-to sm-b dest-open
ck 2 "live task" -- "$W" "done" l1 --moved-to sm-b dest-open
ck 0 "" -- "$W" "done" m1 --moved-to sm-b dest-open
fact "closed row records the proof" sh -c "grep -E '^- \[x\].*m1' '$BL' | grep -q 'moved to sm-b as dest-open'"
fact "peer item untouched and open" sh -c "grep -qE '^- \[ \].*dest-open' '$B/data/backlog.md'"

hdr "7 existing proofs unchanged"
"$W" add p1 "Russet hyena caraway detent" --objective O7 --kind ship --repo notes >/dev/null 2>&1
"$W" add p2 "Umber lemur tarragon collet" --objective O7 --kind scout --repo notes >/dev/null 2>&1
"$W" add p3 "Sable bison anise tenon" --objective O7 --kind ship --repo notes >/dev/null 2>&1
ck nz "" -- "$W" "done" p1
ck nz "" -- "$W" "done" p1 --pr https://github.com/MrGTV-love/firstmate/pull/375
fact "open PR did not close p1" sh -c "grep -qE '^- \[ \].*p1' '$BL'"
ck 0 "" -- "$W" "done" p1 --pr https://github.com/MrGTV-love/firstmate/pull/367
ck nz "" -- "$W" "done" p2
ck nz "" -- "$W" "done" p2 --report data/p2/missing-report.md
mkdir -p "$A/data/p2"; printf 'lab report\n' > "$A/data/p2/report.md"
ck 0 "" -- "$W" "done" p2 --report data/p2/report.md
printf 'Drop this one, the lab says so.\n' > "$A/words.txt"
ck nz "" -- "$W" "done" p3 --drop-file "$A/words.txt" --pr https://github.com/MrGTV-love/firstmate/pull/367
ck 0 "" -- "$W" "done" p3 --drop-file "$A/words.txt"
fact "owner words retained" grep -q 'lab says so' "$A/data/p3/captain-drop.md"
fact "row records fixed note" sh -c "grep -E '^- \[x\].*p3' '$BL' | grep -q dropped"

hdr "8 captain-hold caller"
ck 0 "" -- env -u FM_ROOT_OVERRIDE "$WT/bin/fm-captain-hold.sh" hold hold-new --title "Vermilion wombat fenugreek gusset" --question "Lab fixture question?" --context fixture --repo notes
fact "hold row in tsv as none" grep -qE '^hold-new	[^	]*	none	captain hold record' "$TSV"
ck nz "Do not run the --dup-of" -- env -u FM_ROOT_OVERRIDE "$WT/bin/fm-captain-hold.sh" hold hold-dup --title "Vermilion wombat fenugreek gusset review" --question "Lab fixture question two?" --context fixture --repo notes
nofact "hold-dup was not filed" sh -c "grep -q hold-dup '$BL'"

hdr "9 ledger"
find "$A" -name '*ledger*' -type f | sed "s#$A#\$LAB_A#g; s/^/  | /"
for f in $(find "$A" -name '*ledger*.jsonl' -type f); do tail -4 "$f" | cut -c1-220 | sed 's/^/  | /'; done

hdr "tail of the source backlog"
grep -vE 'win-|zz0' "$BL" | cut -c1-140 | sed 's/^/  | /' | tail -50

printf '\nRESULT checks_ok=%s checks_failed=%s\n' "$PASS" "$FAILS"
rm -f "$A.link"
"$WT/bin/fm-lab-home.sh" teardown "$A" && rm -rf "$A"
"$WT/bin/fm-lab-home.sh" teardown "$B" && rm -rf "$B"
[ ! -d "$A" ] && [ ! -d "$B" ] && echo "labs removed"
