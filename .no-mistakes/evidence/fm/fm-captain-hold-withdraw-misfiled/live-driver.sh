#!/usr/bin/env bash
# Live driver: runs the real bin/fm-captain-hold.sh (and real tasks-axi 0.2.6)
# against disposable fm-lab-home.sh homes. No FM_*_OVERRIDE is used: the script
# resolves every path from plain FM_HOME, as an operator runs it.
# Usage: live-driver.sh <worktree>
set -u
WT=$1
CH="$WT/bin/fm-captain-hold.sh"
export -n FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE 2>/dev/null
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

step() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return $rc; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS+1)); }
FAILS=0

LABS=()
mint() {  # prints a fresh lab home path
  local out lab
  out=$("$WT/bin/fm-lab-home.sh" env 2>/dev/null) || return 1
  lab=$(printf '%s\n' "$out" | sed -n "s/^export FM_HOME=//p")
  lab=$(eval "printf '%s' $lab")
  cat > "$lab/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$lab/data/backlog.md"
  mkdir -p "$lab/projects/sample" && git init -q -b main "$lab/projects/sample"
  printf '%s' "$lab"
}
teardown_all() {
  local lab
  for lab in "${LABS[@]}"; do
    "$WT/bin/fm-lab-home.sh" teardown "$lab" && rm -rf "$lab"
  done
}
trap teardown_all EXIT

ta() { local h=$1; shift; (cd "$h" && tasks-axi "$@" --file data/backlog.md); }
ch() { local h=$1; shift; FM_HOME="$h" "$CH" "$@"; }
mate_shape() {  # <mate> <parent> <route>
  printf '%s\n' "fm-lab-mate" > "$1/.fm-secondmate-home"
  if [ "$3" = local ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$2" > "$1/.fm-secondmate-parent"
  else
    printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$1/.fm-secondmate-parent"
  fi
}
premate() { mv "$1/.fm-secondmate-home" "$1/.premate-home"; mv "$1/.fm-secondmate-parent" "$1/.premate-parent"; }
postmate() { mv "$1/.premate-home" "$1/.fm-secondmate-home"; mv "$1/.premate-parent" "$1/.fm-secondmate-parent"; }

PARENT=$(mint); LABS+=("$PARENT")
MATE=$(mint); LABS+=("$MATE")
mate_shape "$MATE" "$PARENT" local
echo "parent lab home: $PARENT"
echo "mate lab home:   $MATE"

# ---------------------------------------------------------------------------
step "S1 root cause: a mate home never holds Main's call; it must name the owner"
ta "$MATE" add pr290-ship "Successor watcher race (PR 290 shape)" --kind ship --repo sample >/dev/null
out=$(run ch "$MATE" hold pr290-ship --reason "retry or fix one red CI check" 2>&1); echo "$out"
case "$out" in *"--owner is required in a secondmate home"*) ok "ownerless mate hold refused" ;; *) bad "ownerless mate hold not refused" ;; esac
out=$(run ch "$MATE" hold pr290-ship --reason "retry or fix one red CI check" --owner parent 2>&1); echo "$out"
case "$out" in *"never held: route it to Main as a needs-decision status line"*) ok "parent-owned hold refused with routing" ;; *) bad "parent hold not refused" ;; esac
ta "$MATE" show pr290-ship --full | grep -E '^ *held:' ; ta "$MATE" show pr290-ship --full | grep -q 'held: no' && ok "task stayed unheld" || bad "task got held"

# ---------------------------------------------------------------------------
step "S2 PR 290 replay: legacy captain-kind hold on a ship task, Main relayed the question"
. "$WT/bin/fm-pending-reply-lib.sh"
CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" fm-lab-mate "retry the red check once or fix it")
echo "parent pending-reply record: $PARENT/state/pending-replies/$CORR"
premate "$MATE"
run ch "$MATE" hold pr290-ship --reason "Main180/181 reserve ask-user decisions to Main; retry or fix one red CI check corr=$CORR" >/dev/null
postmate "$MATE"
ta "$MATE" show pr290-ship --full | grep -E 'hold_kind|held:'
out=$(ch "$MATE" open pr290-ship --distinguish-absent >/dev/null 2>&1; echo $?); echo "open (captain predicate) exit=$out"
[ "$out" = 0 ] && ok "legacy hold reads as an open captain call (the stuck state)" || bad "legacy hold not open"

step "S2a captain answer path cannot be used for Main's call after classify; classify with provenance"
printf 'Main decided one unchanged-head retry; this was Main'"'"'s call.\n' > "$MATE/classify-evidence.txt"
run ch "$MATE" classify pr290-ship --owner parent --evidence-file "$MATE/classify-evidence.txt" --reason "the retry call was Main's" \
  && ok "classify accepted the hold with matching parent provenance" || bad "classify refused provenance-backed hold"
ta "$MATE" show pr290-ship --full | grep -E 'hold_kind|held:|Decision owner|Classification provenance|Not a captain'
[ "$(ch "$MATE" open pr290-ship --distinguish-absent >/dev/null 2>&1; echo $?)" = 1 ] && ok "no longer a captain call" || bad "still captain call"
[ "$(ch "$MATE" open pr290-ship --distinguish-absent --parent-owned >/dev/null 2>&1; echo $?)" = 0 ] && ok "open parent decision (merge gate still blocks)" || bad "parent predicate missed"
printf 'Captain words nobody gave.\n' > "$MATE/fake-captain.txt"
out=$(run ch "$MATE" answer pr290-ship --decision-file "$MATE/fake-captain.txt" --release 2>&1); echo "$out"
ta "$MATE" show pr290-ship --full | grep -q 'held: yes' && ok "answer (captain words) refused for Main's call" || bad "answer released Main's call"

step "S2b Main records its decision with decide"
printf 'Retry the failing check once on the unchanged head.\n' > "$MATE/parent-decision.txt"
run ch "$MATE" decide pr290-ship --decision-file "$MATE/parent-decision.txt"
SHOW=$(ta "$MATE" show pr290-ship --full); echo "$SHOW" | sed -n '1,40p'
echo "$SHOW" | grep -q 'held: no' && ok "hold lifted" || bad "still held"
echo "$SHOW" | grep -q 'state: done' && bad "decide completed unfinished work" || ok "work item left open"
echo "$SHOW" | grep -q 'Not a captain answer.' && ok "record says not a captain answer" || bad "missing not-captain line"
echo "$SHOW" | grep -q 'Captain decision:' && bad "captain words written" || ok "no captain words written"
[ "$(ch "$MATE" open pr290-ship --distinguish-absent --parent-owned >/dev/null 2>&1; echo $?)" = 1 ] && ok "merge gate predicates both clear" || bad "parent decision still open"
echo "--- parent channel $PARENT/state/fm-lab-mate.status"; cat "$PARENT/state/fm-lab-mate.status" 2>/dev/null

# ---------------------------------------------------------------------------
step "S3 adversarial: classify refuses a legacy hold without provenance; decide refuses a captain call"
ta "$MATE" add genuine-call "Genuine captain call" --kind ship --repo sample >/dev/null
ta "$MATE" add stray-corr "Corr with no record" --kind ship --repo sample >/dev/null
premate "$MATE"
ch "$MATE" hold genuine-call --reason "which landing order do you want" >/dev/null
ch "$MATE" hold stray-corr --reason "pick one corr=aabbccddeeff0011" >/dev/null
postmate "$MATE"
out=$(run ch "$MATE" classify genuine-call --owner parent --evidence-file "$MATE/classify-evidence.txt" --reason "say it was Main's" 2>&1); echo "$out"
case "$out" in *"names no corr=<id> token"*) ok "no-token refusal names the missing fact" ;; *) bad "no-token refusal wrong" ;; esac
ta "$MATE" show genuine-call --full | grep -q 'hold_kind: captain' && ok "genuine call stays captain-kind" || bad "genuine call changed"
out=$(run ch "$MATE" classify stray-corr --owner parent --evidence-file "$MATE/classify-evidence.txt" --reason "say it was Main's" 2>&1); echo "$out"
case "$out" in *"names corr=aabbccddeeff0011, but the parent home holds no pending-reply record"*) ok "unmatched-corr refusal names the missing record" ;; *) bad "unmatched-corr refusal wrong" ;; esac
out=$(run ch "$MATE" decide genuine-call --decision-file "$MATE/parent-decision.txt" 2>&1); echo "$out"
ta "$MATE" show genuine-call --full | grep -q 'held: yes' && ok "decide cannot release the captain's call" || bad "decide released the captain call"
ta "$MATE" add owned-call "Owned captain call" --kind ship --repo sample >/dev/null
ch "$MATE" hold owned-call --owner captain --reason "captain's own taste call" >/dev/null
out=$(run ch "$MATE" classify owned-call --owner parent --evidence-file "$MATE/classify-evidence.txt" --reason "x" 2>&1); echo "$out"
ta "$MATE" show owned-call --full | grep -q 'hold_kind: captain' && ok "recorded captain owner never reclassified" || bad "owned call reclassified"

# ---------------------------------------------------------------------------
step "S4 withdraw: moot-by-ruling (vernant-d5 shape) in a main home"
MAIN=$(mint); LABS+=("$MAIN")
ta "$MAIN" add d5-mechanism "Demand-map mechanism" --kind scout --repo sample >/dev/null
ch "$MAIN" hold d5-mechanism --reason "which mechanism for the demand map" >/dev/null
ch "$MAIN" hold d5-error-bound --title "Which error bound" --reason "pick the error bound" --repo sample >/dev/null
sleep 1
ch "$MAIN" hold ruling-a --title "Ruling A" --reason "choose the approach" --repo sample >/dev/null
printf 'Ruling A: demand map. d5-mechanism and d5-error-bound are moot.\n' > "$MAIN/ruling.txt"
run ch "$MAIN" answer ruling-a --decision-file "$MAIN/ruling.txt"
printf 'Moot under ruling A.\n' > "$MAIN/evidence.txt"
out=$(run ch "$MAIN" withdraw d5-mechanism --evidence-file "$MAIN/evidence.txt" 2>&1); echo "$out"
ta "$MAIN" show d5-mechanism --full | grep -q 'held: yes' && ok "withdraw with no ruling refused" || bad "withdraw without ruling released"
ta "$MAIN" add unrelated-ruling "Unrelated" --kind captain --repo sample >/dev/null
out=$(run ch "$MAIN" withdraw d5-mechanism --evidence-file "$MAIN/evidence.txt" --ruling unrelated-ruling 2>&1); echo "$out"
ta "$MAIN" show d5-mechanism --full | grep -q 'held: yes' && ok "withdraw on an open non-ruling refused" || bad "withdraw on bogus ruling released"
run ch "$MAIN" withdraw d5-mechanism --evidence-file "$MAIN/evidence.txt" --ruling ruling-a
SHOW=$(ta "$MAIN" show d5-mechanism --full)
echo "$SHOW" | grep -E 'state:|held:|Resolution mode|Withdrawn by|Not a captain'
echo "$SHOW" | grep -q 'held: no' && ! echo "$SHOW" | grep -q 'state: done' && ok "scout work item queued and unheld" || bad "work item state wrong"
echo "$SHOW" | grep -q 'Answered by:' && bad "withdrawal labelled as answer" || ok "no captain answer label"
run ch "$MAIN" withdraw d5-error-bound --evidence-file "$MAIN/evidence.txt" --ruling ruling-a
ta "$MAIN" show d5-error-bound --full | grep -E 'state:|Resolution mode'
ta "$MAIN" show d5-error-bound --full | grep -q 'state: done' && ok "moot question row closed" || bad "question row left open"
READY=$(ta "$MAIN" ready); echo "--- tasks-axi ready:"; echo "$READY"
echo "$READY" | grep -q d5-error-bound && bad "moot question is dispatchable" || ok "moot question absent from ready"
echo "$READY" | grep -q d5-mechanism && ok "work item is dispatchable again" || bad "work item not in ready"

# ---------------------------------------------------------------------------
step "S5 remote mate: provenance from the relayed request in the parent-route steering inbox"
REMOTE=$(mint); LABS+=("$REMOTE")
mate_shape "$REMOTE" "" remote
(
  export FM_HOME=$REMOTE
  . "$WT/bin/fm-task-inbox-lib.sh"; . "$WT/bin/fm-operational-input.sh"
  fm_task_inbox_write "$REMOTE/state/parent-route" fm-lab-mate "${FM_FROMFIRST_MARK}corr=00112233445566ff retry the red check once or fix it" >/dev/null
)
ta "$REMOTE" add relayed "Relayed" --kind ship --repo sample >/dev/null
ta "$REMOTE" add unrelayed "Unrelayed" --kind ship --repo sample >/dev/null
premate "$REMOTE"
ch "$REMOTE" hold relayed --reason "retry or fix, corr=00112233445566ff" >/dev/null
ch "$REMOTE" hold unrelayed --reason "retry or fix, corr=aabbccddeeff0011" >/dev/null
postmate "$REMOTE"
out=$(run ch "$REMOTE" classify unrelayed --owner parent --evidence-file "$MATE/classify-evidence.txt" --reason "Main's" 2>&1); echo "$out"
case "$out" in *"steering inbox holds no relayed request with that correlation"*) ok "remote unmatched refusal accurate" ;; *) bad "remote refusal wrong" ;; esac
run ch "$REMOTE" classify relayed --owner parent --evidence-file "$MATE/classify-evidence.txt" --reason "Main's" \
  && ok "remote classify matched inbox record" || bad "remote classify refused"
run ch "$REMOTE" decide relayed --decision-file "$MATE/parent-decision.txt"
ta "$REMOTE" show relayed --full | grep -q 'held: no' && ok "remote parent decision released the work" || bad "remote decide failed"

step "SUMMARY"
echo "failures: $FAILS"
exit "$FAILS"
