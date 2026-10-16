#!/usr/bin/env bash
# Live driver: runs the REAL bin/fm-captain-hold.sh and bin/fm-teardown.sh (head and
# base copies) against REAL tasks-axi, inside disposable lab homes made with
# bin/fm-lab-home.sh. Nothing here touches the operator fleet, tmux, or herdr:
# tmux/treehouse/no-mistakes/gh/docker are exit-0 stubs on a private PATH dir.
#
# usage: live-driver.sh <worktree> <base-tree> <scratch-dir>
set -u
WT=$1 BASE=$2 SCRATCH=$3
HEAD_BIN=$WT/bin
BASE_BIN=$BASE/bin
TASKS_AXI=$(command -v tasks-axi)
FAKEBIN=$SCRATCH/fakebin
mkdir -p "$FAKEBIN"
for t in tmux treehouse no-mistakes gh gh-axi docker; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKEBIN/$t"
  chmod +x "$FAKEBIN/$t"
done

PASS=0 FAIL=0
say() { printf '\n=== %s\n' "$*"; }
verdict() {  # <ok|bad> <label>
  if [ "$1" = ok ]; then PASS=$((PASS + 1)); printf 'RESULT PASS: %s\n' "$2"
  else FAIL=$((FAIL + 1)); printf 'RESULT FAIL: %s\n' "$2"; fi
}

new_lab() {  # prints lab dir; one disposable home per call
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$WT/bin/fm-lab-home.sh" create "$lab" >/dev/null || { echo "lab create failed" >&2; return 1; }
  mkdir -p "$lab/projects"
  git init -q -b main "$lab/projects/sample"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$lab/data/backlog.md"
  printf '%s\n' "$lab" >> "$SCRATCH/labs.list"
  printf '%s\n' "$lab"
}
toml() {  # <lab> <archive-line-or-empty>  (retention keeps one closed row)
  { printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"'
    [ -z "$2" ] || printf '%s\n' "$2"
    printf '%s\n' 'done_keep = 1'; } > "$1/.tasks.toml"
}
tx() { local lab=$1; shift; (cd "$lab" && tasks-axi "$@"); }
cap() {  # <bin-dir> <lab> args...   (plain FM_HOME, as the runbook says)
  local bin=$1 lab=$2; shift 2
  PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI" FM_HOME="$lab" "$bin/fm-captain-hold.sh" "$@"
}
filler() { tx "$1" add "$2" "Filler closed row" --kind captain --repo sample >/dev/null && tx "$1" done "$2" >/dev/null; }
meta() {  # <lab> <scout> <keys> [extra meta lines...]
  local lab=$1 scout=$2 keys=$3
  mkdir -p "$lab/data/$scout" "$lab/state"
  { printf 'window=firstmate:fm-%s\nworktree=%s/projects/missing-%s\nproject=%s/projects/sample\n' "$scout" "$lab" "$scout" "$lab"
    printf 'harness=codex\nkind=scout\nmode=scout\nspawn_gen=fixture-%s\ndecisions_reviewed=1\ndecision_keys=%s\n' "$scout" "$keys"; } > "$lab/state/$scout.meta"
  printf 'done: report complete\n' > "$lab/state/$scout.status"
  printf '# Report\n\nThe investigation finished.\n' > "$lab/data/$scout/report.md"
}
answered_archived() {  # <lab> <id> <origin> [decision-text]
  local lab=$1 id=$2 origin=$3 text=${4-Go with the recorded option.}
  cap "$HEAD_BIN" "$lab" hold "$id" --title "Captain call $id" --reason "captain must decide $id" --repo sample --origin "$origin" >/dev/null || return 1
  printf '%s\n' "$text" > "$lab/answer-$id.txt"
  cap "$HEAD_BIN" "$lab" answer "$id" --decision-file "$lab/answer-$id.txt" >/dev/null || return 1
  filler "$lab" "fill-$id"
}
body_archived() {  # <lab> <id> <body-file>
  tx "$1" add "$2" "Done row $2" --kind captain --repo sample --body-file "$3" >/dev/null && tx "$1" done "$2" >/dev/null && filler "$1" "fill-$2"
}
expect() {  # <label> <want-rc: 0|nz> <want-substring or ''> <rc> <output>
  local label=$1 want=$2 sub=$3 rc=$4 out=$5 ok=ok
  if [ "$want" = 0 ] && [ "$rc" -ne 0 ]; then ok=bad; fi
  if [ "$want" = nz ] && [ "$rc" -eq 0 ]; then ok=bad; fi
  if [ -n "$sub" ] && ! printf '%s' "$out" | grep -qF -- "$sub"; then ok=bad; fi
  verdict "$ok" "$label (rc=$rc)"
}
both() {  # <label> <lab> <scout> <want-rc> <substr>  -> head verify + complete
  local label=$1 lab=$2 scout=$3 want=$4 sub=$5 out rc=0
  out=$(cap "$HEAD_BIN" "$lab" verify "$scout" 2>&1) || rc=$?
  printf '$ fm-captain-hold.sh verify %s\n%s\n' "$scout" "$out"
  expect "$label: verify" "$want" "$sub" "$rc" "$out"
  rc=0
  out=$(cap "$HEAD_BIN" "$lab" complete "$scout" --none 2>&1) || rc=$?
  printf '$ fm-captain-hold.sh complete %s --none\n%s\n' "$scout" "$out"
  expect "$label: complete --none" "$want" "$sub" "$rc" "$out"
}

# ---------------------------------------------------------------- S1 bug repro: base vs head
say "S1  answered call archived by real retention: base refuses, head passes"
L=$(new_lab); toml "$L" 'archive = "data/done-archive.md"'
answered_archived "$L" d7-archived-call vernant-scout
grep -c 'd7-archived-call' "$L/data/backlog.md" | sed 's/^/backlog.md mentions of the id: /'
grep -n 'd7-archived-call' "$L/data/done-archive.md" | head -2
meta "$L" vernant-scout d7-archived-call
out=$(cap "$BASE_BIN" "$L" complete vernant-scout --none 2>&1); rc=$?
printf '$ BASE complete vernant-scout --none\n%s\n' "$out"
expect "S1 base refuses the archived answered call (the reported bug)" nz "" "$rc" "$out"
out=$(cap "$HEAD_BIN" "$L" complete vernant-scout --none 2>&1); rc=$?
printf '$ HEAD complete vernant-scout --none\n%s\n' "$out"
expect "S1 head retires it, naming the archive" 0 "[answered and archived: d7-archived-call]" "$rc" "$out"
grep -n 'decision_keys\|decisions_reviewed' "$L/state/vernant-scout.meta"

# ---------------------------------------------------------------- S2 scout teardown gate
say "S2  scout teardown completion gate follows the archived answer (base blocks, head passes)"
L=$(new_lab); toml "$L" 'archive = "data/done-archive.md"'
answered_archived "$L" teardown-answered td-scout
meta "$L" td-scout teardown-answered
tx "$L" add td-scout "Investigate the archived calls" --kind scout --repo sample --start >/dev/null
td() { PATH="$FAKEBIN:$PATH" REAL_TASKS_AXI="$TASKS_AXI" FM_HOME="$L" "$1/fm-teardown.sh" td-scout; }
out=$(td "$BASE_BIN" 2>&1); rc=$?
printf '$ BASE fm-teardown.sh td-scout\n%s\n' "$out"
expect "S2 base teardown blocked by the completion gate" nz "has not passed the captain-call completion gate" "$rc" "$out"
[ -f "$L/state/td-scout.meta" ] && verdict ok "S2 blocked teardown left the scout record" || verdict bad "S2 blocked teardown left the scout record"
out=$(td "$HEAD_BIN" 2>&1); rc=$?
printf '$ HEAD fm-teardown.sh td-scout\n%s\n' "$out"
expect "S2 head teardown passes the gate" 0 "" "$rc" "$out"
[ ! -f "$L/state/td-scout.meta" ] && verdict ok "S2 passing teardown removed the scout record" || verdict bad "S2 passing teardown removed the scout record"

# ---------------------------------------------------------------- S3 unanswered archived call
say "S3  adversarial: archived call closed with NO recorded answer"
L=$(new_lab); toml "$L" 'archive = "data/done-archive.md"'
tx "$L" add plain-closed "Closed with no answer" --kind captain --repo sample >/dev/null; tx "$L" done plain-closed >/dev/null; filler "$L" fill-plain
meta "$L" s3-scout plain-closed
both "S3 unanswered archived call refuses" "$L" s3-scout nz "archived without a recorded captain answer"

# ---------------------------------------------------------------- S4 evidence-only close
say "S4  adversarial: call closed only by reconcile evidence, then archived"
L=$(new_lab); toml "$L" 'archive = "data/done-archive.md"'
tx "$L" add s4-scout "The investigation" --kind scout --repo sample >/dev/null
cap "$HEAD_BIN" "$L" hold moot-call --title "Moot call" --reason "captain must decide" --repo sample --origin s4-scout >/dev/null
cap "$HEAD_BIN" "$L" bind src-4 >/dev/null
printf 'moot-call\n' | cap "$HEAD_BIN" "$L" reconcile-requests --source-id src-4 --source "captured board result" >/dev/null
printf 'Nothing is pending. No captain answer was given.\n' > "$L/ev.txt"
cap "$HEAD_BIN" "$L" reconcile close moot-call --evidence-file "$L/ev.txt" --verified-outcome moot >/dev/null
filler "$L" fill-s4
grep -c 'Reconciliation evidence:' "$L/data/done-archive.md" | sed 's/^/archive evidence records: /'
meta "$L" s4-scout moot-call
both "S4 reconcile-evidence-only archived call stays refused" "$L" s4-scout nz "only reconciliation evidence, not a recorded captain answer"

# ---------------------------------------------------------------- S5 wrong origin
say "S5  adversarial: archived answered call held for a DIFFERENT scout"
L=$(new_lab); toml "$L" 'archive = "data/done-archive.md"'
answered_archived "$L" other-origin-call somebody-elses-scout
meta "$L" s5-scout other-origin-call
both "S5 archived call held for another origin refuses" "$L" s5-scout nz "held for"

# ---------------------------------------------------------------- S6 absent
say "S6  adversarial: key present in neither backlog nor archive"
L=$(new_lab); toml "$L" 'archive = "data/done-archive.md"'
answered_archived "$L" some-other-call s6-scout
meta "$L" s6-scout never-existed-call
both "S6 key absent everywhere keeps its refusal" "$L" s6-scout nz "no captain-held task never-existed-call"

# ---------------------------------------------------------------- S7 hash in quoted path
say "S7  quoted archive path with a '#': whole file is read; truncated stale file cannot stand in"
L=$(new_lab); toml "$L" 'archive = "data/closed#later.md"'
answered_archived "$L" hash-call s7-scout
ls "$L/data" | sed 's/^/data\/: /'
meta "$L" s7-scout hash-call
both "S7 answered call archived at data/closed#later.md resolves" "$L" s7-scout 0 ""
# adversarial: stale answered row in the truncated 'data/closed'; real file holds an unanswered re-close
L=$(new_lab); toml "$L" 'archive = "data/closed"'
answered_archived "$L" hash-stale s7b-scout
toml "$L" 'archive = "data/closed#later.md"'
tx "$L" add hash-stale "Closed again with no answer" --kind captain --repo sample >/dev/null; tx "$L" done hash-stale >/dev/null; filler "$L" fill-hash-2
ls "$L/data" | sed 's/^/data\/: /'
meta "$L" s7b-scout hash-stale
both "S7b stale answer in truncated 'data/closed' does not stand in" "$L" s7b-scout nz "archived without a recorded captain answer"
# single-quoted + trailing comment
L=$(new_lab); printf '%s\n' 'backend = "markdown"' '' '[markdown] # md' 'path = "data/backlog.md"' "archive = 'data/single#quote.md'   # closed calls" 'done_keep = 1' > "$L/.tasks.toml"
answered_archived "$L" single-call s7c-scout
meta "$L" s7c-scout single-call
both "S7c single-quoted '#' path with trailing comment resolves" "$L" s7c-scout 0 ""

# ---------------------------------------------------------------- S8 unreadable settings
say "S8  adversarial: archive settings the gate cannot read exactly are refused with a reason"
for c in backslash backslash-literal unterminated unquoted trailing-text empty; do
  reason=
  case $c in
    backslash) line='archive = "data\\syntax.md"'; reason="uses syntax the gate cannot read exactly" ;;
    backslash-literal) line="archive = 'data\\syntax.md'"; reason="uses syntax the gate cannot read exactly" ;;
    unterminated) line='archive = "data/syntax.md' ;;
    unquoted) line='archive = data/syntax.md' ;;
    trailing-text) line='archive = "data/syntax.md" extra' ;;
    empty) line='archive = ""' ;;
  esac
  L=$(new_lab); toml "$L" 'archive = "data/syntax.md"'
  answered_archived "$L" syn-call s8-scout
  meta "$L" s8-scout syn-call
  toml "$L" "$line"
  printf '[%s] .tasks.toml archive line: %s\n' "$c" "$line"
  both "S8[$c] refused" "$L" s8-scout nz "$reason"
done

# ---------------------------------------------------------------- S9 user-level only
say "S9  adversarial: archive path set only in ~/.tasks-axi/config.toml stays refused"
L=$(new_lab); UH=$SCRATCH/userhome; mkdir -p "$UH/.tasks-axi"
toml "$L" ''
printf '[markdown]\narchive = "%s"\n' "$L/data/user-archive.md" > "$UH/.tasks-axi/config.toml"
export HOME_SAVED=$HOME
HOME=$UH answered_archived "$L" ul-call s9-scout
ls "$L/data" | sed 's/^/data\/: /'
meta "$L" s9-scout ul-call
out=$(HOME=$UH cap "$HEAD_BIN" "$L" complete s9-scout --none 2>&1); rc=$?
printf '$ HEAD (HOME=userhome) complete s9-scout --none\n%s\n' "$out"
expect "S9 user-level-only archive path refused with a reason" nz "set outside this home's .tasks.toml" "$rc" "$out"

# ---------------------------------------------------------------- S10 retired decision-hold shapes
say "S10 retired fm-decision-hold records in the archive"
L=$(new_lab); toml "$L" 'archive = "data/done-archive.md"'
dg=$(printf '%064d' 5 | tr 0 c)
retired() {  # <file> <routed> <mode> <answer>
  { printf 'Resolution recorded by fm-decision-hold.\nDecision digest: %s\n' "$dg"
    [ -z "$2" ] || printf '%s\n' "$2"; [ -z "$3" ] || printf '%s\n' "$3"
    printf '\nCaptain decision:\n%s\n\nRouted work:\n(none)\n' "$4"; } > "$1"
}
retired "$L/r-declined" 'Routed identities: (none)' 'Resolution mode: declined' 'Dropped by the captain.'
retired "$L/r-modeless" 'Routed identities: (none)' '' 'Go with option B.'
retired "$L/r-reconciled" 'Routed identities: (none)' 'Resolution mode: reconciled' 'Ignored.'
retired "$L/r-empty" 'Routed identities: (none)' 'Resolution mode: answered' ''
retired "$L/r-norouted" '' 'Resolution mode: answered' 'Go.'
for n in declined modeless reconciled empty norouted; do body_archived "$L" "ret-$n" "$L/r-$n"; done
filler "$L" fill-ret-last
for n in declined modeless; do
  meta "$L" "s10-$n" "ret-$n"; both "S10 retired $n record resolves" "$L" "s10-$n" 0 ""
done
for n in reconciled empty norouted; do
  meta "$L" "s10-$n" "ret-$n"; both "S10 retired $n record refuses" "$L" "s10-$n" nz ""
done

# ---------------------------------------------------------------- S11 blank-led answers
say "S11 answer text that starts with blank lines resolves; label followed only by blank lines refuses"
L=$(new_lab); toml "$L" 'archive = "data/done-archive.md"'
cap "$HEAD_BIN" "$L" hold blank-lead --title "Blank lead" --reason "captain must decide" --repo sample --origin s11-scout >/dev/null
printf '\n\nUse option B.\n' > "$L/bl.txt"
cap "$HEAD_BIN" "$L" answer blank-lead --decision-file "$L/bl.txt" >/dev/null
filler "$L" fill-bl-1
sed -n '/blank-lead/,/^## /p' "$L/data/done-archive.md" | head -14
meta "$L" s11-scout blank-lead
both "S11 blank-led answer resolves" "$L" s11-scout 0 ""
printf 'Resolution recorded by fm-captain-hold.\nDecision digest: %s\nResolution mode: answered\n\nCaptain decision:\n\n\n\n' "$(printf '%064d' 9 | tr 0 d)" > "$L/bo.txt"
body_archived "$L" blank-only "$L/bo.txt"; filler "$L" fill-bo-last
meta "$L" s11b-scout blank-only
both "S11b label followed only by blank lines refuses" "$L" s11b-scout nz "archived without a recorded captain answer"

# ---------------------------------------------------------------- S12 live row unchanged
say "S12 live (unarchived) closed answered call still resolves exactly as before"
L=$(new_lab); toml "$L" 'archive = "data/done-archive.md"'
cap "$HEAD_BIN" "$L" hold live-call --title "Live" --reason "captain must decide" --repo sample --origin s12-scout >/dev/null
printf 'Go.\n' > "$L/lv.txt"; cap "$HEAD_BIN" "$L" answer live-call --decision-file "$L/lv.txt" >/dev/null
grep -c live-call "$L/data/backlog.md" | sed 's/^/backlog.md mentions: /'
meta "$L" s12-scout live-call
out=$(cap "$BASE_BIN" "$L" verify s12-scout 2>&1); rc=$?; expect "S12 base verify on live row" 0 "" "$rc" "$out"
out=$(cap "$HEAD_BIN" "$L" complete s12-scout --none 2>&1); rc=$?; printf '%s\n' "$out"
expect "S12 head complete on live row, no archive disclosure" 0 "" "$rc" "$out"
printf '%s' "$out" | grep -q 'answered and archived' && verdict bad "S12 no archive disclosure for a live row" || verdict ok "S12 no archive disclosure for a live row"

printf '\n=== SUMMARY: %d pass, %d fail\n' "$PASS" "$FAIL"
[ ! -f "$SCRATCH/labs.list" ] || while IFS= read -r lab; do rm -rf "$lab"; done < "$SCRATCH/labs.list"
rm -rf "$SCRATCH/userhome"
[ "$FAIL" -eq 0 ]
