#!/usr/bin/env bash
# Second live driver: the scenarios the first driver did not reach.
# Real bin/fm-tasks-axi.sh, real tasks-axi, real fm-captain-hold.sh and fm-duration.py,
# in disposable lab homes from bin/fm-lab-home.sh. Args: <worktree> <part: window|close|rest>
# Fixture seeding of the 51-row Done window calls tasks-axi directly (the wrapper takes
# about 15 s per call on this host); every checked command goes through the wrapper.
set -u
WT=$1; PART=$2; W="$WT/bin/fm-tasks-axi.sh"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_DURATION_HOME FM_DURATION_FILE
eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"; A=$FM_HOME
B=$(FM_HOME= ; eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"; echo "$FM_HOME")
export FM_HOME=$A
printf '## In flight\n\n## Queued\n\n## Done\n' > "$A/data/backlog.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$B/data/backlog.md"
cd "$WT"
PASS=0; FAILS=0
hdr() { printf '\n==== %s ====\n' "$*"; }
red() { sed "s#$A#\$LAB_A#g; s#$B#\$LAB_B#g; s#$WT/##g"; }
ck() { local want=$1 needle=$2; shift 3; local out rc; out=$("$@" 2>&1); rc=$?
  printf '$ %s\n' "$(printf '%q ' "$@" | red)"; printf '%s\n' "$out" | red | sed 's/^/  | /' | cut -c1-260; echo "  rc=$rc"
  local ok=1; if [ "$want" = nz ]; then [ "$rc" != 0 ] || ok=0; else [ "$rc" = "$want" ] || ok=0; fi
  if [ -n "$needle" ]; then case "$out" in *"$needle"*) ;; *) ok=0 ;; esac; fi
  if [ "$ok" = 1 ]; then PASS=$((PASS+1)); echo "  CHECK ok"; else FAILS=$((FAILS+1)); echo "  CHECK FAILED (wanted rc=$want needle='$needle')"; fi; }
fact() { local d=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "  FACT ok: $d"; else FAILS=$((FAILS+1)); echo "  FACT FAILED: $d"; fi; }
nofact() { local d=$1; shift; if "$@" >/dev/null 2>&1; then FAILS=$((FAILS+1)); echo "  FACT FAILED: $d"; else PASS=$((PASS+1)); echo "  FACT ok: $d"; fi; }
quiet() { "$@" >/dev/null 2>&1 || { echo "  SETUP FAILED: $(printf '%q ' "$@" | red)"; FAILS=$((FAILS+1)); }; }
BL=$A/data/backlog.md; TSV=$A/data/backlog-review.tsv; ARC=$A/data/done-archive.md
open_row() { grep -qE "^- \[ \] $2 " "$1"; }
done_row() { grep -qE "^- \[x\] $2 " "$1"; }

case $PART in
window)
hdr "4 last 50 Done window, active and archive"
( cd "$A" && tasks-axi add win-oldest "Aardvark juniper cobbler ratchet" --file data/backlog.md >/dev/null && tasks-axi done win-oldest --file data/backlog.md >/dev/null
  for i in $(seq 1 50); do w=$(printf 'zz%03daaa zz%03dbbb zz%03dccc' "$i" "$i" "$i")
    tasks-axi add "win-$i" "$w" --file data/backlog.md >/dev/null && tasks-axi done "win-$i" --file data/backlog.md >/dev/null; done )
echo "  seeded through tasks-axi: active Done rows=$(grep -cE '^- \[x\] win-' "$BL") archived rows=$(grep -cE 'win-' "$ARC")"
fact "win-oldest is in the archive, not the active list" sh -c "grep -q win-oldest '$ARC' && ! grep -q win-oldest '$BL'"
# A pruned Done row inside the newest 50: wrapper add then wrapper done --keep 0 archives it.
ck 0 "" -- "$W" add win-keep "Hazel dynamo plover winch" --objective O7
ck 0 "" -- "$W" "done" win-keep --keep 0
nofact "win-keep is not in the active list" grep -q win-keep "$BL"
fact "win-keep is in the archive" grep -q win-keep "$ARC"
echo "  now: win-oldest is Done row 52 counted from the newest (win-keep, win-50 .. win-1, win-oldest)"
B4=$(cksum < "$BL")
ck 2 "win-keep (Done, archived" -- "$W" add win-new "Hazel dynamo plover winch refit" --objective O7
fact "refused add left backlog.md unchanged" test "$B4" = "$(cksum < "$BL")"
ck 2 "archived" -- "$W" add win-new "Hazel dynamo plover winch refit" --objective O7 --dup-of win-keep
ck 0 "" -- "$W" add win-new "Hazel dynamo plover winch refit" --objective O7 --not-dup win-keep
fact "--not-dup on an archived neighbour files it" open_row "$BL" win-new
# A Done row still in the active list overlaps: refused.
ck 0 "" -- "$W" add win-act "Copper narwhal sage lathe" --objective O7
ck 0 "" -- "$W" "done" win-act
fact "win-act is Done in the active list" done_row "$BL" win-act
ck 2 "win-act (Done" -- "$W" add win-act2 "Copper narwhal sage lathe rebuild" --objective O7
ck 0 "" -- "$W" add win-act2 "Copper narwhal sage lathe rebuild" --objective O7 --dup-of win-act
"$W" show win-act --full 2>&1 | red | sed 's/^/  | /'
# Older than 50: no stop.
ck 0 "" -- "$W" add win-free "Aardvark juniper cobbler ratchet refit" --objective O7
fact "a Done row older than the newest 50 does not stop the add" open_row "$BL" win-free
;;

close)
hdr "5 --duplicate-of closes on proof"
quiet "$W" add k1 "Topaz gondola fennel axle" --objective O7 --kind ship --repo notes --body "kept one"
quiet "$W" add d1 "Crimson walrus tulip bushing" --objective O7 --kind ship --repo notes --body "dup body words"
ck 0 "" -- "$W" "done" d1 --duplicate-of k1
grep -E 'd1|k1' "$BL" | sed 's/^/  backlog| /'
fact "row closed with the proof note" sh -c "grep -E '^- \[x\] d1 ' '$BL' | grep -q 'duplicate of k1'"
"$W" show k1 --full 2>&1 | sed 's/^/  | /'
fact "kept item got duplicate title" sh -c "'$W' show k1 --full | grep -q 'Crimson walrus'"
fact "kept item got duplicate body" sh -c "'$W' show k1 --full | grep -q 'dup body words'"
nofact "kept item holds no fm-add token" sh -c "'$W' show k1 --full | grep -q 'fm-add:'"
fact "k1 still open" open_row "$BL" k1

hdr "5b --duplicate-of refusals"
quiet "$W" add o1 "Amber lizard pumice coupler" --objective O7 --kind ship --repo notes --body "Captain 2027-01-06 asked for this item."
quiet "$W" add o2 "Indigo ostrich clover bracket" --objective O7 --kind ship --repo notes --body "Owner 2026-10-08: please do this."
quiet "$W" add o-neg "Teal badger gravel lock" --objective O7 --kind ship --repo notes --body "the lock decision"
ck 2 "owner" -- "$W" "done" o1 --duplicate-of k1
ck 2 "owner" -- "$W" "done" o2 --duplicate-of k1
fact "owner items stay open" sh -c "grep -qE '^- \[ \] o1 ' '$BL' && grep -qE '^- \[ \] o2 ' '$BL'"
ck 0 "" -- "$W" "done" o-neg --duplicate-of k1
quiet "$W" add h1 "Olive cougar marigold shim" --objective O7 --kind ship --repo notes
ck 0 "" -- "$WT/bin/fm-captain-hold.sh" hold h1 --reason "Lab fixture: should this stay open?"
ck 2 "owner" -- "$W" "done" h1 --duplicate-of k1
quiet "$W" add l1 "Pewter gibbon saffron rivet" --objective O7 --kind ship --repo notes
printf 'kind=ship\n' > "$A/state/l1.meta"
ck 2 "live task" -- "$W" "done" l1 --duplicate-of k1
quiet "$W" add c1 "Bronze ibis nutmeg clevis" --objective O7 --kind ship --repo notes
quiet "$W" add c2 "Ivory marmot basil gimbal" --objective O7
quiet "$W" "done" c2
ck 2 "" -- "$W" "done" c1 --duplicate-of c2
ck 2 "" -- "$W" "done" c1 --duplicate-of nope-missing
ck 2 "" -- "$W" "done" c1 --duplicate-of c1
quiet "$W" add dep1 "Slate puffin thyme yoke" --objective O7 --kind ship --repo notes
quiet "$W" add dep2 "Coral magpie sorrel tappet" --objective O7 --kind ship --repo notes
quiet "$W" block dep2 --by dep1
ck 2 "" -- "$W" "done" dep1 --duplicate-of k1
fact "c1 and dep1 stay open after every refusal" sh -c "grep -qE '^- \[ \] c1 ' '$BL' && grep -qE '^- \[ \] dep1 ' '$BL'"
ck nz "" -- "$W" "done" c1 --duplicate-of k1 --pr https://github.com/MrGTV-love/firstmate/pull/367
ck 0 "" -- "$W" "done" c1 --duplicate-of k1
ck nz "" -- "$W" "done" c1 --duplicate-of k1

hdr "6 --moved-to closes on proof (local home)"
quiet env FM_HOME="$B" "$W" add dest-open "Mustard jackal chervil pawl" --objective O7
quiet env FM_HOME="$B" "$W" add dest-done "Plum tapir lovage cam" --objective O7
quiet env FM_HOME="$B" "$W" "done" dest-done
ln -s "$A" "$A.link"
{ printf -- '- sm-b - A lab peer home (home: %s; scope: lab; projects: p; added 2026-11-01)\n' "$B"
  printf -- '- sm-self - This home (home: %s; scope: lab; projects: p; added 2026-11-01)\n' "$A"
  printf -- '- sm-link - Symlink to this home (home: %s.link; scope: lab; projects: p; added 2026-11-01)\n' "$A"
  printf -- '- sm-twice - One (home: %s; scope: lab; projects: p; added 2026-11-01)\n' "$B"
  printf -- '- sm-twice - Two (home: %s; scope: lab; projects: p; added 2026-11-01)\n' "$B"
  printf -- '- sm-unreach - Unreachable real ssh host (host: fm-lab-no-such-host.invalid; root: %s; home: /tmp/none; scope: lab; projects: p; added 2026-11-01)\n' "$WT"
} > "$A/data/secondmates.md"
quiet "$W" add m1 "Saddle heron dill sprag" --objective O7 --kind ship --repo notes
ck 2 "" -- "$W" "done" m1 --moved-to sm-none dest-open
ck 2 "" -- "$W" "done" m1 --moved-to sm-twice dest-open
ck 2 "" -- "$W" "done" m1 --moved-to sm-b dest-absent
ck 2 "" -- "$W" "done" m1 --moved-to sm-b dest-done
ck 2 "" -- "$W" "done" m1 --moved-to sm-self m1
ck 2 "" -- "$W" "done" m1 --moved-to sm-link m1
ck nz "" -- timeout 120 "$W" "done" m1 --moved-to sm-unreach dest-open
fact "m1 still open after every refusal" open_row "$BL" m1
ck 2 "" -- "$W" "done" o1 --moved-to sm-b dest-open
ck 2 "" -- "$W" "done" h1 --moved-to sm-b dest-open
ck 2 "" -- "$W" "done" l1 --moved-to sm-b dest-open
fact "o1 h1 l1 stay open" sh -c "grep -qE '^- \[ \] o1 ' '$BL' && grep -qE '^- \[.\] h1 ' '$BL' && grep -qE '^- \[ \] l1 ' '$BL'"
B6=$(cksum < "$B/data/backlog.md")
ck 0 "" -- "$W" "done" m1 --moved-to sm-b dest-open
grep -E ' m1 ' "$BL" | sed 's/^/  backlog| /'
fact "closed row records the proof" sh -c "grep -E '^- \[x\] m1 ' '$BL' | grep -q 'moved to sm-b as dest-open'"
fact "peer item still open" open_row "$B/data/backlog.md" dest-open
fact "peer backlog unchanged by the move" test "$B6" = "$(cksum < "$B/data/backlog.md")"
rm -f "$A.link"
;;

rest)
hdr "7 existing proofs unchanged"
quiet "$W" add p1 "Russet hyena caraway detent" --objective O7 --kind ship --repo notes
quiet "$W" add p2 "Umber lemur tarragon collet" --objective O7 --kind scout --repo notes
quiet "$W" add p3 "Sable bison anise tenon" --objective O7 --kind ship --repo notes
ck nz "" -- "$W" "done" p1
ck nz "" -- "$W" "done" p1 --pr https://github.com/MrGTV-love/firstmate/pull/376
fact "open PR did not close p1" open_row "$BL" p1
ck 0 "" -- "$W" "done" p1 --pr https://github.com/MrGTV-love/firstmate/pull/367
ck nz "" -- "$W" "done" p2
ck nz "" -- "$W" "done" p2 --report data/p2/missing-report.md
mkdir -p "$A/data/p2"; printf 'lab report\n' > "$A/data/p2/report.md"
ck 0 "" -- "$W" "done" p2 --report data/p2/report.md
printf 'Drop this one, the lab says so.\n' > "$A/words.txt"
ck nz "" -- "$W" "done" p3 --drop-file "$A/words.txt" --pr https://github.com/MrGTV-love/firstmate/pull/367
ck 0 "" -- "$W" "done" p3 --drop-file "$A/words.txt"
grep -E ' p[123] ' "$BL" | sed 's/^/  backlog| /'
fact "owner words retained" sh -c "grep -rq 'lab says so' '$A/data/p3'"

hdr "8 captain-hold caller"
ck 0 "" -- "$WT/bin/fm-captain-hold.sh" hold hold-new --reason "Lab fixture question?" --title "Vermilion wombat fenugreek gusset" --repo notes
grep -E '^hold-new	' "$TSV" | sed 's/^/  tsv| /'
fact "hold row in tsv with objective none" grep -qE '^hold-new	[^	]*	none	' "$TSV"
ck nz "Do not run the --dup-of" -- "$WT/bin/fm-captain-hold.sh" hold hold-dup --reason "Lab fixture question two?" --title "Vermilion wombat fenugreek gusset review" --repo notes
nofact "hold-dup was not filed" grep -q hold-dup "$BL"

hdr "9 fm-duration.py repeated timeout filing"
D="$WT/bin/fm-duration.py"
# 9a: second timeout for a key files one item naming O7; a third adds no new item.
ck 0 "" -- python3 "$D" record lab.ka 5 124 --timed-out
nofact "one timeout files nothing" grep -q 'fm-timeout-' "$BL"
ck 0 "timeout_work" -- python3 "$D" record lab.ka 6 124 --timed-out
grep -E 'fm-timeout-' "$BL" | sed 's/^/  backlog| /'
TA=$(grep -oE 'fm-timeout-[0-9a-f]{16}' "$BL" | head -1)
fact "item filed with objective O7" grep -qE "^$TA	[^	]*	O7" "$TSV"
ck 0 "" -- python3 "$D" record lab.ka 7 124 --timed-out
fact "third timeout filed no second item" test "$(grep -cE '^- \[.\] fm-timeout-' "$BL")" = 1
# 9b: an open fm-timeout- item another host filed under this exact title gets the occurrence appended.
REPO=$(python3 -c 'import sys,importlib.util as u; s=u.spec_from_file_location("d",sys.argv[1]); m=u.module_from_spec(s); s.loader.exec_module(m); print(m.repo())' "$D" 2>/dev/null)
echo "  repo() = $REPO"
ck 0 "" -- "$W" add fm-timeout-0therh0st0000kb "Measure and repair repeated timeout: $REPO lab.kb" --kind ship --repo firstmate --objective O7 --body "Filed by other-host." --not-dup "$TA"
ck 0 "" -- python3 "$D" record lab.kb 5 124 --timed-out
ck 0 "fm-timeout-0therh0st0000kb" -- python3 "$D" record lab.kb 9 124 --timed-out
"$W" show fm-timeout-0therh0st0000kb --full 2>&1 | sed 's/^/  | /' | cut -c1-260
fact "occurrence appended names this host" sh -c "'$W' show fm-timeout-0therh0st0000kb --full | grep -q 'on host $(python3 -c 'import platform;print(platform.node())')'"
fact "occurrence appended carries the bounds" sh -c "'$W' show fm-timeout-0therh0st0000kb --full | grep -q '5, 9'"
fact "no new item for lab.kb" test "$(grep -cE '^- \[.\] fm-timeout-' "$BL")" = 2
# 9c: a hand-filed open neighbour is raised to the operator, nothing filed.
ck 0 "" -- "$W" add hand-1 "Repair repeated timeout lab.kc limit" --objective O7 --not-dup "$TA"
ck 0 "" -- python3 "$D" record lab.kc 5 124 --timed-out
ck nz "hand-1 may be the same work filed by hand" -- python3 "$D" record lab.kc 6 124 --timed-out
fact "nothing filed for lab.kc" test "$(grep -cE '^- \[.\] fm-timeout-' "$BL")" = 2
# 9d: the same neighbour closed and pruned into the done archive is still raised.
ck 0 "" -- "$W" "done" hand-1 --keep 0
fact "hand-1 is in the archive only" sh -c "grep -q hand-1 '$ARC' && ! grep -q hand-1 '$BL'"
ck nz "hand-1 may be the same work filed by hand" -- python3 "$D" record lab.kc 7 124 --timed-out
fact "still nothing filed for lab.kc" test "$(grep -cE '^- \[.\] fm-timeout-' "$BL")" = 2
# 9e: only fm-timeout- neighbours: the filer overrides with --not-dup and files.
ck 0 "timeout_work" -- sh -c "python3 '$D' record lab.kd 5 124 --timed-out && python3 '$D' record lab.kd 6 124 --timed-out"
fact "lab.kd filed a third item" test "$(grep -cE '^- \[.\] fm-timeout-' "$BL")" = 3

hdr "10 ledger"
find "$A" -name '*.jsonl' -type f | red | sed 's/^/  | /'
for f in $(find "$A" -name '*.jsonl' -type f); do tail -6 "$f" | cut -c1-220 | red | sed 's/^/  | /'; done
;;
esac

hdr "final source backlog ($PART)"
grep -vE 'zz0' "$BL" | cut -c1-160 | red | sed 's/^/  | /'
printf '\nRESULT part=%s checks_ok=%s checks_failed=%s\n' "$PART" "$PASS" "$FAILS"
"$WT/bin/fm-lab-home.sh" teardown "$A" >/dev/null 2>&1; rm -rf "$A"
"$WT/bin/fm-lab-home.sh" teardown "$B" >/dev/null 2>&1; rm -rf "$B"
[ ! -d "$A" ] && [ ! -d "$B" ] && echo "labs removed"
