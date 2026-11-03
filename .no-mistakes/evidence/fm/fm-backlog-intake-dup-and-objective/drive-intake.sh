#!/usr/bin/env bash
# Live drive of bin/fm-tasks-axi.sh intake and closing proofs in a marked lab home.
# Usage: drive-intake.sh <worktree> (run with FM_HOME set to a fm-lab-home.sh lab).
set -u
WT=$1; W="$WT/bin/fm-tasks-axi.sh"
PASS=0; FAIL=0
say() { printf '\n=== %s\n' "$*"; }
# run <expected-exit> <cmd...>: echo the command, its output, and its exit.
run() { local want=$1; shift; printf '\n$ %s\n' "$(printf '%q ' "$@" | sed "s#$WT/##g; s#$FM_HOME#\$FM_HOME#g")"; OUT=$("$@" 2>&1); RC=$?; printf '%s\n' "$OUT" | sed "s#$WT/##g; s#$FM_HOME#\$FM_HOME#g" | grep -vE '^(guard|rule|missing|why|bypass|mode|surface|subject|revision)\b' ; printf '[exit %s]\n' "$RC"; if [ "$RC" = "$want" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'CHECK-FAIL: wanted exit %s got %s\n' "$want" "$RC"; fi; }
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); printf 'check ok: %s\n' "$label"; else FAIL=$((FAIL+1)); printf 'CHECK-FAIL: %s\n' "$label"; fi; }
no() { local label=$1; shift; if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); printf 'CHECK-FAIL: %s\n' "$label"; else PASS=$((PASS+1)); printf 'check ok: %s\n' "$label"; fi; }
hasout() { printf '%s' "$OUT" | grep -qF -- "$1"; }
B="$FM_HOME/data/backlog.md"; T="$FM_HOME/data/backlog-review.tsv"; A="$FM_HOME/data/done-archive.md"
inb() { grep -q -- "$1" "$B"; }
intsv() { grep -q "^$1	" "$T"; }
ax() { (cd "$FM_HOME" && TASKS_AXI_FILE="$B" tasks-axi "$@"); }

cp "$WT/.tasks.toml" "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$B"

say "S1 objective is required at intake"
run 2 "$W" add obj-a "Alpha beta gamma"
ok "refusal names objective flag" hasout "--objective"; no "not filed" inb obj-a
run 2 "$W" add obj-a "Alpha beta gamma" --objective O9
ok "unknown id refused" hasout "unknown objective"; no "not filed" inb obj-a
run 2 "$W" add obj-a "Alpha beta gamma" --objective none
run 2 "$W" add obj-a "Alpha beta gamma" --objective none --objective-reason "   "
run 2 "$W" add obj-a "Alpha beta gamma" --objective=
run 2 "$W" add obj-a "Alpha beta gamma" --objective --not-dup
no "still not filed" inb obj-a
run 0 "$W" add obj-a "Alpha beta gamma" --objective O7
ok "filed" inb obj-a; ok "sidecar row" intsv obj-a
run 0 "$W" add obj-b "Delta epsilon zeta" --objective none --objective-reason "one-off cleanup	with tab"
ok "reason row" intsv obj-b
run 0 "$W" create obj-c "Eta theta iota" --objective=O1
run 0 "$W" task add obj-d "Kappa lambda sigma" --objective O2 --json
run 0 "$W" add --mint "Omega upsilon chi" --objective O3
run 0 "$W" add --title "Psi rho tau" obj-e --objective O4
printf '\nsidecar %s (id, review-by, objective, reason):\n' data/backlog-review.tsv; cat -t "$T"
ok "json add recorded" intsv obj-d
ok "minted id recorded" grep -qE '^[^	]+		O3	' "$T"
ok "alias create recorded" intsv obj-c
ok "--title form recorded" intsv obj-e
run 0 "$W" add obj-a "Alpha beta gamma" --objective O7
printf 'sidecar rows for obj-a: %s\n' "$(grep -c '^obj-a	' "$T")"

say "S2 duplicate check, documented worked pairs"
run 0 "$W" add lock-1 "Lock holder crash" --objective O7
run 2 "$W" add lock-2 "Lock holder crash recovery" --objective O7
ok "0.75 shown" hasout "overlap 0.75"; no "not filed" inb lock-2; NOTDUP=$(printf '%s\n' "$OUT" | grep -- '--not-dup' | tail -1 | sed 's/^ *//'); DUPOF=$(printf '%s\n' "$OUT" | grep -- '--dup-of' | tail -1 | sed 's/^ *//')
printf 'printed --not-dup: %s\nprinted --dup-of: %s\n' "${NOTDUP#$WT/}" "${DUPOF#$WT/}"
run 2 "$W" add lock-3 "Lock timeout" --objective O7
ok "0.25 refused at threshold" hasout "overlap 0.25"
run 0 "$W" add lock-4 "Lock timeout retry loop" --objective O7
ok "0.17 filed" inb lock-4
say "S3 the printed overrides work when run verbatim"
printf '$ <printed --dup-of command>\n'; OUT=$(eval "$DUPOF" 2>&1); RC=$?; printf '%s\n[exit %s]\n' "$OUT" "$RC"
ok "dup-of exit 0" test "$RC" = 0; no "dup-of files nothing" inb lock-2; ok "body got merge note" sh -c "'$W' show lock-1 --full | grep -q 'Merged from a duplicate filing: Lock holder crash recovery'"
printf '$ <printed --not-dup command>\n'; OUT=$(eval "$NOTDUP" 2>&1); RC=$?; printf '%s\n[exit %s]\n' "$OUT" "$RC"
ok "not-dup exit 0" test "$RC" = 0; ok "not-dup files" inb lock-2; ok "not-dup sidecar" intsv lock-2

say "S4 override flags resist misuse"
run 2 "$W" add x1 "Lock holder crash again" --objective O7 --not-dup obj-a
ok "non-neighbour refused" hasout "does not overlap"; no "not filed" inb x1
run 2 "$W" add x1 "Lock holder crash again" --objective O7 --not-dup nosuch
ok "missing refused" hasout "names no item"
run 2 "$W" add x1 "Lock holder crash again" --objective O7 --not-dup lock-1 --not-dup lock-2
run 2 "$W" add x1 "Lock holder crash again" --objective O7 --not-dup lock-1 --dup-of lock-1
run 2 "$W" add x1 "Lock holder crash again" --not-dup lock-1
run 2 "$W" add x1 "Lock holder crash again" --dup-of lock-1
run 2 "$W" add x1 "Lock holder crash again" --objective O7 --dup-of x1
run 2 "$W" add x1 "Lock holder crash again" --objective O7 --dup-of nosuch
run 2 "$W" add x1 "Lock holder crash again" --objective O7 --dup-of=
no "nothing filed through misuse" inb x1

say "S5 Done rows, the done archive, and the 50-newest window"
run 0 "$W" add dn-1 "Rotate signing material" --objective O5
run 0 "$W" done dn-1 --note finished
run 2 "$W" add dn-2 "Rotate signing material quarterly" --objective O5
ok "kept Done row is a neighbour" hasout "Done, overlap"
run 0 "$W" add old-0 "Zebra quokka ostrich" --objective O7
ax done old-0 --note x --keep 0 >/dev/null
for i in $(seq 1 49); do "$W" add "fill-$i" "fillerword${i}a fillerword${i}b fillerword${i}c" --objective O7 >/dev/null 2>&1 || echo "seed add failed $i"; ax done "fill-$i" --note x --keep 0 >/dev/null; done
run 0 "$W" add edge-1 "Marmot walrus bison" --objective O7
ax done edge-1 --note x --keep 0 >/dev/null
printf 'archive rows: %s  blocks: %s  kept Done rows: %s\n' "$(grep -c '^- \[x\]' "$A")" "$(grep -c '^## ' "$A")" "$(sed -n '/^## Done/,$p' "$B" | grep -c '^- \[x\]')"
run 2 "$W" add edge-2 "Marmot walrus" --objective O7
ok "archived neighbour labelled" hasout "archived"
run 2 "$W" add edge-3 "Marmot walrus" --objective O7 --dup-of edge-1
ok "archived kept refused with pointer" hasout "--not-dup edge-1"; no "not filed" inb edge-3
run 0 "$W" add edge-4 "Marmot walrus" --objective O7 --not-dup edge-1
run 0 "$W" add past-window "Zebra quokka" --objective O7
ok "row past the 50 newest is not compared" inb past-window
"$W" done past-window --note x >/dev/null 2>&1

say "S6 archive tails tasks-axi really writes are stripped; real title words stay"
run 0 "$W" add pc-1 "Fix boiler crash (process cleanup)" --objective O7
ax done pc-1 --note x --keep 0 >/dev/null; grep -n 'pc-1' "$A"
run 2 "$W" add pc-2 "Process cleanup" --objective O7
ok "(process cleanup) kept, 0.40" hasout "overlap 0.40"
run 0 "$W" add hu-1 "Sandbox escape audit" --objective O7
ax hold hu-1 --reason wait --until 2027-12-01 >/dev/null
ax done hu-1 --note x --keep 0 >/dev/null; grep -n 'hu-1' "$A"
run 2 "$W" add hu-2 "Sandbox probe" --objective O7
ok "hold-until tail stripped, 0.25" hasout "overlap 0.25"
run 0 "$W" add pr-1 "Quantum ledger migration" --objective O7 --repo firstmate --kind task
ax done pr-1 --pr https://github.com/x/y/pull/1 --keep 0 >/dev/null; grep -n 'pr-1' "$A"
run 2 "$W" add pr-2 "Quantum ledger" --objective O7
ok "pr tail stripped, 0.67" hasout "overlap 0.67"

say "S7 unreadable archive stops the add"
cp "$A" "$A.bak"; printf -- '- [x]bad row\n' >> "$A"
run 2 "$W" add ar-1 "Novel unrelated words" --objective O7
ok "stop names the archive" hasout "done archive"; no "not filed" inb ar-1
mv "$A.bak" "$A"

say "S8 done --duplicate-of closes on checked proof, with no owner words"
"$W" add kept-1 "Harbor crane schedule" --objective O7 --body "Kept body text." >/dev/null
"$W" add dupe-1 "Harbor crane calendar" --objective O7 --not-dup kept-1 --body "Dupe body text." >/dev/null
run 0 "$W" done dupe-1 --duplicate-of kept-1
sed -n '/^## Done/,$p' "$B" | grep 'dupe-1'
ok "closing note records proof" sh -c "'$W' show dupe-1 --full | grep -q 'duplicate of kept-1'"
"$W" show kept-1 --full | sed -n '/body/,$p' | head -12
ok "kept keeps own body" sh -c "'$W' show kept-1 --full | grep -q 'Kept body text'"
ok "kept took dupe title" sh -c "'$W' show kept-1 --full | grep -q 'Merged from duplicate dupe-1: Harbor crane calendar'"
ok "kept took dupe body" sh -c "'$W' show kept-1 --full | grep -q 'Dupe body text'"
run 2 "$W" done dupe-1 --duplicate-of kept-1
ok "second close refused" hasout "already closed"

say "S9 --duplicate-of guards, adversarial"
"$W" add k2 "Pelican tower mapping" --objective O7 --body "k2 body" >/dev/null
d() { "$W" add "$1" "$2" --objective O7 --body "$3" ${4:+--not-dup "$4"} >/dev/null; }
d g-self "Finch basket sorter" "plain"
run 2 "$W" done g-self --duplicate-of g-self
run 2 "$W" done g-self --duplicate-of nosuch
"$W" add kd-1 "Albatross hatch mooring" --objective O7 >/dev/null; "$W" done kd-1 --note x >/dev/null
run 2 "$W" done g-self --duplicate-of kd-1
ok "kept must be open" hasout "not Queued or In flight"
run 2 "$W" done g-self --duplicate-of k2 --note hi
run 2 "$W" done g-self --duplicate-of k2 --pr https://github.com/x/y/pull/1
run 2 "$W" done g-self --duplicate-of k2 --moved-to h i
run 2 "$W" done g-self --duplicate-of
run 2 "$W" done nosuch --duplicate-of k2
ok "missing item refused" hasout "no item nosuch"
inb "g-self" ; ok "g-self still open" sh -c "sed -n '/^## Queued/,/^## Done/p' '$B' | grep -q g-self"
i=0
while IFS= read -r body; do i=$((i+1)); d "own-$i" "Sparrow$i quill$i anvil$i" "$body"
  run 2 "$W" done "own-$i" --duplicate-of k2
  ok "owner item refused: $body" hasout "owner"
  ok "own-$i still open" sh -c "sed -n '/^## Queued/,/^## Done/p' '$B' | grep -q own-$i"
done <<'BODIES'
Owner 2026-11-01: keep this forever
Captain's words, 2026-10-20 (via /kun): do it
Captain's ask 2026-09-22 on /bearings lavish: show board
Captain chose this on the Lavish page
Captain direction 2026-10-22, verbatim in the notes
Captain: yes on both
Owner: please
Captain decision on routing
Captain 2026 note here
BODIES
"$W" add own-t "Captain ask about walnut barrels" --objective O7 >/dev/null
run 2 "$W" done own-t --duplicate-of k2
ok "owner marker in title refused" hasout "owner"
ok "k2 untouched by refused closes" sh -c "! '$W' show k2 --full | grep -q 'Merged from'"
i=0
while IFS= read -r body; do i=$((i+1)); d "nown-$i" "Heron$i mallet$i spindle$i" "$body"; run 0 "$W" done "nown-$i" --duplicate-of k2
done <<'BODIES'
the lock owner: process 12 holds it
Owner's idea, not a quote
BODIES
d g-meta "Beetle cartwheel drum" "plain"; : > "$FM_HOME/state/g-meta.meta"
run 2 "$W" done g-meta --duplicate-of k2
ok "live task refused" hasout "live task record"; rm -f "$FM_HOME/state/g-meta.meta"
d g-hold "Ferret anchor lantern" "plain"
FM_DATA_OVERRIDE="" "$WT/bin/fm-captain-hold.sh" hold g-hold --reason "Which lantern ships first?" >/dev/null 2>&1; echo "hold rc=$?"
run 2 "$W" done g-hold --duplicate-of k2
ok "open owner call refused" hasout "open owner call"
d g-blocker "Mussel pylon rudder" "plain"; "$W" add g-dep "Otter gantry rivet" --objective O7 --blocked-by g-blocker >/dev/null
run 2 "$W" done g-blocker --duplicate-of k2
ok "dependent named" hasout "g-dep"; ok "advice names block and unblock" hasout "unblock <dependent> --by g-blocker"
run 0 "$W" block g-dep --by k2
run 0 "$W" unblock g-dep --by g-blocker
run 0 "$W" done g-blocker --duplicate-of k2

say "S10 done --moved-to, local registered home"
H2=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-h2.XXXXXX"); "$WT/bin/fm-lab-home.sh" create "$H2" >/dev/null; cp "$WT/.tasks.toml" "$H2/.tasks.toml"; printf '## In flight\n\n## Queued\n\n## Done\n' > "$H2/data/backlog.md"
FM_HOME="$H2" "$W" add dest-open "Gannet pier winch" --objective O7 >/dev/null
FM_HOME="$H2" "$W" add dest-done "Gannet pier closed" --objective O7 --not-dup dest-open >/dev/null; FM_HOME="$H2" "$W" done dest-done --note x >/dev/null
printf -- '- sm-h2 - lab mate (home: %s; scope: lab; projects: none; added 2026-11-02)\n' "$H2" > "$FM_HOME/data/secondmates.md"
sed -n 1,30p "$WT/bin/fm-secondmate-registry-lib.sh" | grep -n '^# - ' || true
"$W" add mv-1 "Gull derrick oakum" --objective O7 >/dev/null
run 2 "$W" done mv-1 --moved-to nope dest-open
ok "unregistered refused" hasout "not one registered home"
run 2 "$W" done mv-1 --moved-to sm-h2 nosuch
ok "missing item refused" hasout "has no item"
run 2 "$W" done mv-1 --moved-to sm-h2 dest-done
ok "closed dest refused" hasout "not open"
run 2 "$W" done mv-1 --moved-to sm-h2
run 2 "$W" done mv-1 --moved-to=sm-h2
run 2 "$W" done mv-1 --moved-to sm-h2 dest-open --report data/x.md
ok "mv-1 still open" sh -c "sed -n '/^## Queued/,/^## Done/p' '$B' | grep -q mv-1"
run 0 "$W" done mv-1 --moved-to sm-h2 dest-open
grep mv-1 "$B"
ok "note records move" sh -c "'$W' show mv-1 --full | grep -q 'moved to sm-h2 as dest-open'"
ok "dest still open" sh -c "sed -n '/^## Queued/,/^## Done/p' '$H2/data/backlog.md' | grep -q dest-open"
"$W" add mv-own "Cormorant keel tiller" --objective O7 --body "Captain: stay here" >/dev/null
run 2 "$W" done mv-own --moved-to sm-h2 dest-open
ok "owner item stops moved-to too" hasout "owner"
printf -- '- sm-self - this home (home: %s; scope: lab; projects: none; added 2026-11-02)\n' "$FM_HOME" >> "$FM_HOME/data/secondmates.md"
"$W" add mv-2 "Puffin ballast hawser" --objective O7 >/dev/null
run 2 "$W" done mv-2 --moved-to sm-self mv-2
ok "same backlog refused" hasout "this backlog itself"
printf -- '- sm-h2 - lab mate twice (home: %s; scope: lab; projects: none; added 2026-11-02)\n' "$H2" >> "$FM_HOME/data/secondmates.md"
run 2 "$W" done mv-2 --moved-to sm-h2 dest-open
ok "twice registered refused" hasout "not one registered home"
rm -rf "$H2"
printf -- '- sm-h2 - lab mate (home: %s; scope: lab; projects: none; added 2026-11-02)\n' "$H2" > "$FM_HOME/data/secondmates.md"
run 2 "$W" done mv-2 --moved-to sm-h2 dest-open
ok "vanished home closes nothing" sh -c "sed -n '/^## Queued/,/^## Done/p' '$B' | grep -q mv-2"
rm -f "$FM_HOME/data/secondmates.md"

say "S11 old proofs still behave"
"$W" add sh-1 "Tern bollard capstan" --kind ship --repo r --objective O7 >/dev/null
run 2 "$W" done sh-1
ok "ship needs proof" hasout "needs proof"
printf 'the owner words here\n' > "$FM_HOME/words.txt"
run 0 "$W" done sh-1 --drop-file "$FM_HOME/words.txt"
ok "drop words kept" test -s "$FM_HOME/data/sh-1/captain-drop.md"

say "S12 telemetry and ledger"
: > "$FM_HOME/config/fleet-ledger"
"$W" add lg-1 "Lobster jetty sextant" --objective O7 >/dev/null; "$W" add lg-kept "Mackerel quay astrolabe" --objective O7 >/dev/null
"$W" done lg-1 --duplicate-of lg-kept >/dev/null
find "$FM_HOME/state" -maxdepth 2 -type f | sed "s#$FM_HOME/##" | sort | head -40
L=$(find "$FM_HOME/state" -name '*ledger*' -type f | head -1)
grep -h lg- "$L" 2>/dev/null
ok "ledger task.filed" grep -q '"task.filed".*lg-1\|lg-1.*task.filed' "$L"
ok "ledger task.closed evidence none" sh -c "grep lg-1 '$L' | grep 'task.closed' | grep -q '\"evidence\":\"none\"'"
G="$FM_HOME/state/guard-events.jsonl"
python3 -I - "$G" <<'PY'
import json,sys,collections
c=collections.Counter()
for l in open(sys.argv[1]):
    r=json.loads(l); c[(r.get('guard'),r.get('decision') or r.get('action'),r.get('override'),r.get('cleared_by'),r.get('source_ok'))]+=1
for k,v in sorted(c.items(),key=str): print(v,k)
PY
ok "not-dup override recorded" sh -c "grep backlog-intake-duplicate '$G' | grep -q '\"override\":true'"
ok "dup-of cleared_by recorded" sh -c "grep backlog-intake-duplicate '$G' | grep -q '\"cleared_by\":\"dup-of\"'"
F="$FM_HOME/state/friction.jsonl"; ok "friction refusals recorded" test -s "$F"; wc -l "$F" | sed "s#$FM_HOME/##"

printf '\nTOTAL checks ok=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
