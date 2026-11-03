#!/usr/bin/env bash
# Live drive of captain holds and repeated-timeout filing through the new intake.
set -u
WT=$1; W="$WT/bin/fm-tasks-axi.sh"; H="$WT/bin/fm-captain-hold.sh"
PASS=0; FAIL=0
say() { printf '\n=== %s\n' "$*"; }
run() { local want=$1; shift; printf '\n$ %s\n' "$(printf '%q ' "$@" | sed "s#$WT/##g; s#$FM_HOME#\$FM_HOME#g")"; OUT=$("$@" 2>&1); RC=$?; printf '%s\n' "$OUT" | sed "s#$WT/##g; s#$FM_HOME#\$FM_HOME#g"; printf '[exit %s]\n' "$RC"; if [ "$RC" = "$want" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); printf 'CHECK-FAIL: wanted exit %s got %s\n' "$want" "$RC"; fi; }
ok() { local label=$1; shift; if "$@" >/dev/null 2>&1; then PASS=$((PASS+1)); printf 'check ok: %s\n' "$label"; else FAIL=$((FAIL+1)); printf 'CHECK-FAIL: %s\n' "$label"; fi; }
no() { local label=$1; shift; if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); printf 'CHECK-FAIL: %s\n' "$label"; else PASS=$((PASS+1)); printf 'check ok: %s\n' "$label"; fi; }
hasout() { printf '%s' "$OUT" | grep -qF -- "$1"; }
B="$FM_HOME/data/backlog.md"; T="$FM_HOME/data/backlog-review.tsv"
inb() { grep -q -- "$1" "$B"; }
cp "$WT/.tasks.toml" "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$B"
: > "$FM_HOME/config/fleet-ledger"

say "S13 a new captain hold files through intake and records its objective"
T1="Land or drop the bundle-preserved commits of alpha-one"
T2="Land or drop the bundle-preserved commits of beta-two"
run 0 "$H" hold alpha-one --title "$T1" --reason "Land or drop alpha-one?"
ok "row exists and held" sh -c "'$W' show alpha-one --full | grep -q 'hold_kind: captain'"
grep alpha-one "$T" | cat -t
ok "objective none with reason" sh -c "grep -q 'alpha-one		none	captain hold record' '$T'"
L=$(find "$FM_HOME/state" -name '*ledger*' -type f | head -1)
printf 'task.filed records for alpha-one: %s\n' "$(grep -c 'task.filed.*alpha-one\|alpha-one.*task.filed' "$L")"
ok "one task.filed" test "$(grep -c 'task.filed.*alpha-one\|alpha-one.*task.filed' "$L")" = 1

say "S14 a templated second hold is refused with hold-correct guidance"
run 1 "$H" hold beta-two --title "$T2" --reason "Land or drop beta-two?"
ok "guidance forbids --dup-of" hasout "Do not run the --dup-of command above"
ok "guidance names due waiver" hasout "prefixed with BD_DUE_REQUIRED=false"
ok "guidance says re-run hold" hasout "then run this same hold command again"
ok "wrapper refusal shows neighbour" hasout "alpha-one (Queued"
no "nothing filed" inb beta-two
NOTDUP=$(printf '%s\n' "$OUT" | grep -- '--not-dup' | grep -v 'fm-captain-hold' | tail -1 | sed 's/^ *//')
printf 'printed --not-dup: %s\n' "${NOTDUP#$WT/}"
say "S15 following the guidance verbatim files and holds the call"
printf '$ BD_DUE_REQUIRED=false <printed --not-dup command>\n'
OUT=$(eval "BD_DUE_REQUIRED=false $NOTDUP" 2>&1); RC=$?; printf '%s\n[exit %s]\n' "$OUT" "$RC" | head -8
ok "printed not-dup ran" test "$RC" = 0
run 0 "$H" hold beta-two --title "$T2" --reason "Land or drop beta-two?"
ok "held" sh -c "'$W' show beta-two --full | grep -q 'hold_kind: captain'"
run 0 "$H" open beta-two
printf 'the owner says land it\n' > "$FM_HOME/w.txt"
run 0 "$H" answer beta-two --decision-file "$FM_HOME/w.txt"
ok "answer closes the call" sh -c "'$W' show beta-two --full | grep -q 'state: done'"

say "S16 a hold on an existing work item never meets the duplicate check"
"$W" add wk-1 "Land the signed commits of gamma-three" --objective O7 --not-dup alpha-one >/dev/null 2>&1 || "$W" add wk-1 "Saffron turbine gasket" --objective O7 >/dev/null
run 0 "$H" hold wk-1 --reason "Which gamma-three first?"
ok "existing row held" sh -c "'$W' show wk-1 --full | grep -q 'hold_kind: captain'"

say "S17 the retired decision-hold shim reaches the same behaviour"
run 0 "$WT/bin/fm-decision-hold.sh" hold orig1 keyone --title "Pick the umbrella vendor" --reason "Which vendor?"
run 1 "$WT/bin/fm-decision-hold.sh" hold orig1 keytwo --title "Pick the umbrella colour" --reason "Which colour?"
ok "shim gets guidance" hasout "Do not run the --dup-of command above"

say "S18 repeated timeouts file with O7 and only self-clear for timeout neighbours"
REPO=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-repo.XXXXXX"); git -C "$REPO" init -q; git -C "$REPO" remote add origin https://example.invalid/lab/driver.git
dur() { (cd "$REPO" && env -u FM_DATA_OVERRIDE FM_DURATION_FILE= FM_HOME="$FM_HOME" python3 "$WT/bin/fm-duration.py" timeout "$@"); }
dur worker.lintkey 1200000 --event-id a1; dur worker.lintkey 1200000 --event-id a2; echo "rc=$?"
grep -n 'fm-timeout-' "$B" | head; A1=$(grep -o 'fm-timeout-[0-9a-f]*' "$B" | head -1)
ok "first key filed" test -n "$A1"
ok "objective O7 row" sh -c "grep -q '^$A1		O7	' '$T'"
dur worker.fmtkey 1200000 --event-id b1; dur worker.fmtkey 1200000 --event-id b2; echo "rc=$?"
printf 'fm-timeout rows after a second key (the title overlaps the first): %s\n' "$(grep -c '^- \[ \] fm-timeout-' "$B")"
ok "second key self-clears through --not-dup" test "$(grep -c '^- \[ \] fm-timeout-' "$B")" = 2
"$W" add hand-1 "Measure and repair repeated timeout: driver worker.typekey by hand" --objective O7 --not-dup "$A1" >/dev/null
printf 'hand-filed same-work item added\n'
OUT=$(dur worker.typekey 1200000 --event-id c1 2>&1; dur worker.typekey 1200000 --event-id c2 2>&1); RC=$?; printf '%s\n[exit %s]\n' "$OUT" "$RC" | sed "s#$WT/##g; s#$FM_HOME#\$FM_HOME#g" | cut -c1-400
ok "operator sees refusal naming hand item" hasout "hand-1"
ok "not filed over a hand item" test "$(grep -c '^- \[ \] fm-timeout-' "$B")" = 2
rm -rf "$REPO"
printf '\nTOTAL checks ok=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
