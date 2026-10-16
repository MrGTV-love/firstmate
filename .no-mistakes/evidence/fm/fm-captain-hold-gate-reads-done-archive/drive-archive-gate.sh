#!/usr/bin/env bash
# Live driver for the archived-call completion gate.
# Usage: drive-archive-gate.sh <firstmate-tree-to-run> <label>
# It builds disposable homes, closes real calls through the real answer path,
# lets real tasks-axi retention archive them, then runs the real gate.
set -u
GATE_TREE=$1
LABEL=$2
HEAD_TREE=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M52NPG4NM4041AN2CEDP37NA
# shellcheck disable=SC1091
. "$HEAD_TREE/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot drive-archive)
TASKS_AXI_BIN=$(command -v tasks-axi)
RESULTS=0
FAILS=0

make_home() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  git init -q -b main "$home/projects/sample"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    'archive = "data/done-archive.md"' 'done_keep = 1' > "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  fm_fake_docker "$fakebin"
  printf '%s\n' "$home"
}
tasks_in() { local home=$1; shift; (cd "$home" && tasks-axi "$@"); }
run_captain() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$GATE_TREE/bin/fm-captain-hold.sh" "$@"
}
run_teardown() {
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$GATE_TREE" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$GATE_TREE/bin/fm-teardown.sh" "$id"
}
filler() { # <home> <n>
  tasks_in "$1" add "filler-$2" "Filler closed row" --kind captain --repo sample >/dev/null
  tasks_in "$1" "done" "filler-$2" >/dev/null
}
hold() { # <home> <id> <origin>
  run_captain "$1" hold "$2" --title "Captain call $2" --reason "captain must decide $2" \
    --repo sample --origin "$3" >/dev/null
}
answer() { # <home> <id> <text>
  printf '%b' "$3" > "$1/answer-$2.txt"
  run_captain "$1" answer "$2" --decision-file "$1/answer-$2.txt" >/dev/null
}
scout_meta() { # <home> <scout> <keys>
  mkdir -p "$1/data/$2"
  fm_write_meta "$1/state/$2.meta" "window=firstmate:fm-$2" "worktree=$1/projects/missing-$2" \
    "project=$1/projects/sample" "harness=codex" "kind=scout" "spawn_gen=fixture-$2" \
    "decisions_reviewed=1" "decision_keys=$3"
  printf 'done: report complete\n' > "$1/state/$2.status"
  printf '# Report\n\nDone.\n' > "$1/data/$2/report.md"
}
expect() { # <name> <want-rc: 0|nz> <rc> <out> [must-contain]
  local name=$1 want=$2 rc=$3 out=$4 needle=${5:-} ok=1
  RESULTS=$((RESULTS+1))
  if [ "$want" = 0 ] && [ "$rc" -ne 0 ]; then ok=0; fi
  if [ "$want" = nz ] && [ "$rc" -eq 0 ]; then ok=0; fi
  if [ -n "$needle" ] && ! printf '%s' "$out" | grep -qF -- "$needle"; then ok=0; fi
  if [ "$ok" = 1 ]; then printf 'PASS [%s] %s (rc=%s)\n' "$LABEL" "$name" "$rc"
  else FAILS=$((FAILS+1)); printf 'FAIL [%s] %s (rc=%s)\n' "$LABEL" "$name" "$rc"; fi
  printf '    output: %s\n' "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-400)"
}

echo "=== driving gate tree: $GATE_TREE ($LABEL) ==="

# S1: answered call archived by retention -> verify + complete --none
home=$(make_home s1); scout=sample-s1-scout; id=sample-s1-call
hold "$home" "$id" "$scout"; answer "$home" "$id" 'Go with option B.\n'; filler "$home" 1
grep -q "$id" "$home/data/backlog.md" && echo "SETUP PROBLEM: $id still in backlog"
grep -q "$id" "$home/data/done-archive.md" || echo "SETUP PROBLEM: $id not in archive"
scout_meta "$home" "$scout" "$id"
out=$(run_captain "$home" verify "$scout" 2>&1); rc=$?
expect "S1a verify passes for an answered call that retention archived" 0 $rc "$out"
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S1b complete --none passes and names the archive" 0 $rc "$out" "[answered and archived: $id]"
grep "decision_keys=" "$home/state/$scout.meta" | sed 's/^/    meta: /'

# S2: archived call closed bare (no captain answer) -> refuse
home=$(make_home s2); scout=sample-s2-scout; id=sample-s2-call
tasks_in "$home" add "$id" "Closed bare $id" --kind captain --repo sample >/dev/null
tasks_in "$home" "done" "$id" >/dev/null; filler "$home" 1
scout_meta "$home" "$scout" "$id"
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S2 archived call with no recorded answer is refused" nz $rc "$out"

# S3: archived answered call held for another origin -> refuse
home=$(make_home s3); scout=sample-s3-scout; id=sample-s3-call
tasks_in "$home" add sample-s3-other "Other scout" --kind scout --repo sample >/dev/null
tasks_in "$home" add "$scout" "This scout" --kind scout --repo sample >/dev/null
hold "$home" "$id" sample-s3-other; answer "$home" "$id" 'Go.\n'; filler "$home" 1
scout_meta "$home" "$scout" "$id"
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S3 archived call held for another origin is refused" nz $rc "$out" "was held for origin sample-s3-other"

# S4: call in neither backlog nor archive -> refuse
home=$(make_home s4); scout=sample-s4-scout
hold "$home" sample-s4-other "$scout"; answer "$home" sample-s4-other 'Go.\n'; filler "$home" 1
scout_meta "$home" "$scout" sample-s4-never-existed
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S4 call absent from backlog and archive keeps its refusal" nz $rc "$out"

# S5: id-prefix collision: archive holds sample-s5-call-extra (answered), inventory names sample-s5-call
home=$(make_home s5); scout=sample-s5-scout
hold "$home" sample-s5-call-extra "$scout"; answer "$home" sample-s5-call-extra 'Go.\n'; filler "$home" 1
scout_meta "$home" "$scout" sample-s5-call
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S5 an archived id that only shares a prefix does not stand in" nz $rc "$out"

# S6: answer text that starts with blank lines, through the real answer path
home=$(make_home s6); scout=sample-s6-scout; id=sample-s6-call
hold "$home" "$id" "$scout"; answer "$home" "$id" '\n\nUse option B.\n'; filler "$home" 1
scout_meta "$home" "$scout" "$id"
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S6 archived answer whose text starts with blank lines passes" 0 $rc "$out" "[answered and archived: $id]"

# S7: archive path named in .tasks.toml (non-default location)
home=$(make_home s7); scout=sample-s7-scout; id=sample-s7-call
mkdir -p "$home/data/closed"
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
  'archive = "data/closed/answered.md"' 'done_keep = 1' > "$home/.tasks.toml"
hold "$home" "$id" "$scout"; answer "$home" "$id" 'Go.\n'; filler "$home" 1
[ -e "$home/data/done-archive.md" ] && echo "SETUP PROBLEM: default archive exists"
scout_meta "$home" "$scout" "$id"
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S7 gate reads the archive path named in .tasks.toml" 0 $rc "$out" "[answered and archived: $id]"

# S8: archive path only in ~/.tasks-axi/config.toml (the home's .tasks.toml names none) -> refuse, no stale fallback
home=$(make_home s8); scout=sample-s8-scout; id=sample-s8-call
mkdir -p "$home/userhome/.tasks-axi" "$home/data/elsewhere"
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' 'done_keep = 1' > "$home/.tasks.toml"
printf '%s\n' '[markdown]' 'archive = "data/elsewhere/user.md"' > "$home/userhome/.tasks-axi/config.toml"
hold "$home" "$id" "$scout"; answer "$home" "$id" 'Go.\n'; filler "$home" 1
scout_meta "$home" "$scout" "$id"
out=$(HOME="$home/userhome" run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S8 archive path only in the user-level config is refused (not read)" nz $rc "$out"

# S9: live rows unchanged (held + answered-in-retention)
home=$(make_home s9); scout=sample-s9-scout
hold "$home" sample-s9-held "$scout"; hold "$home" sample-s9-answered "$scout"
answer "$home" sample-s9-answered 'Go.\n'
scout_meta "$home" "$scout" "sample-s9-answered,sample-s9-held"
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S9 live held and live answered rows still pass, no archive note" 0 $rc "$out"
printf '%s' "$out" | grep -q 'answered and archived' && { FAILS=$((FAILS+1)); echo "FAIL S9 live row reported as archive evidence"; }

# S10: scout teardown gate: unanswered archived blocks, answered archived passes
home=$(make_home s10); scout=sample-s10-scout; ans=sample-s10-answered; una=sample-s10-unanswered
hold "$home" "$ans" "$scout"; answer "$home" "$ans" 'Go.\n'; filler "$home" 1
tasks_in "$home" add "$una" "Closed bare" --kind captain --repo sample >/dev/null
tasks_in "$home" "done" "$una" >/dev/null; filler "$home" 2
mkdir -p "$home/data/$scout" "$home/projects/$scout"
tasks_in "$home" add "$scout" "Investigate" --kind scout --repo sample --start >/dev/null
fm_write_meta "$home/state/$scout.meta" "window=firstmate:fm-$scout" "worktree=$home/projects/$scout" \
  "project=$home/projects/sample" "harness=codex" "kind=scout" "mode=scout" \
  "spawn_gen=fixture-$scout" "decisions_reviewed=1" "decision_keys=$una"
printf 'done: report complete\n' > "$home/state/$scout.status"
printf '# Report\n\nDone.\n' > "$home/data/$scout/report.md"
out=$(run_teardown "$home" "$scout" 2>&1); rc=$?
expect "S10a scout teardown blocks an archived call with no recorded answer" nz $rc "$out" "has not passed the captain-call completion gate"
[ -f "$home/state/$scout.meta" ] || { FAILS=$((FAILS+1)); echo "FAIL S10a refused teardown removed meta"; }
printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$ans" >> "$home/state/$scout.meta"
out=$(run_teardown "$home" "$scout" 2>&1); rc=$?
expect "S10b scout teardown passes an archived answered call" 0 $rc "$out"
[ -f "$home/state/$scout.meta" ] && { FAILS=$((FAILS+1)); echo "FAIL S10b passing teardown left meta behind"; }


request_reconciles() { # <home> <source> <id>...
  local home=$1 source_id=$2 id; shift 2
  run_captain "$home" bind "$source_id" >/dev/null || return 1
  for id in "$@"; do printf '%s\n' "$id"; done | run_captain "$home" reconcile-requests --source-id "$source_id" --source "captured board result" >/dev/null
}
reconcile_close() { # <home> <id> <source>
  request_reconciles "$1" "$3" "$2" || return 1
  printf 'Nothing pending. No captain answer was given.\n' > "$1/evidence-$2.txt"
  run_captain "$1" reconcile close "$2" --evidence-file "$1/evidence-$2.txt" --verified-outcome moot >/dev/null
}

# S11: call closed only by reconcile evidence, then archived -> refuse
home=$(make_home s11); scout=sample-s11-scout; id=sample-s11-call
tasks_in "$home" add "$scout" "The investigation" --kind scout --repo sample >/dev/null
hold "$home" "$id" "$scout"
reconcile_close "$home" "$id" s11-source || echo "SETUP PROBLEM: reconcile close failed"
filler "$home" 1
grep -q "Reconciliation evidence:" "$home/data/done-archive.md" || echo "SETUP PROBLEM: evidence record not archived"
scout_meta "$home" "$scout" "$id"
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S11 archived call closed only by reconcile evidence is refused" nz $rc "$out"

# S12: hand-forged archive row that only quotes the record markers -> refuse
home=$(make_home s12); scout=sample-s12-scout; id=sample-s12-call
tasks_in "$home" add "$id" "Closed with a quote $id" --kind captain --repo sample >/dev/null
tasks_in "$home" "done" "$id" >/dev/null
filler "$home" 1
# rewrite the archived row body to a prose line quoting both markers (as an operator note would)
perl -0pi -e 's/(- \[x\] '"$id"' [^\n]*\n)/$1  Notes: the "Resolution recorded by fm-captain-hold." line and a "Captain decision:" line.\n/' "$home/data/done-archive.md"
grep -q 'Notes: the "Resolution recorded' "$home/data/done-archive.md" || echo "SETUP PROBLEM: quote not injected"
scout_meta "$home" "$scout" "$id"
out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
expect "S12 archived row that merely quotes the record markers is refused" nz $rc "$out"


# S13: two real stacked records. Answered first, then reopened and closed on evidence only.
# The newest record (evidence) decides, so the archived call must be refused.
home=$(make_home s13); scout=sample-s13-scout; id=sample-s13-call
tasks_in "$home" add "$scout" "The investigation" --kind scout --repo sample >/dev/null
hold "$home" "$id" "$scout"; answer "$home" "$id" 'Go.\n'
if hold "$home" "$id" "$scout" 2>/dev/null && reconcile_close "$home" "$id" s13-source 2>/dev/null; then
  filler "$home" 1
  echo "    stacked records in archive: $(grep -c 'Resolution recorded by fm-captain-hold' "$home/data/done-archive.md")"
  scout_meta "$home" "$scout" "$id"
  out=$(run_captain "$home" complete "$scout" --none 2>&1); rc=$?
  expect "S13 stacked answer-then-evidence record: newest (evidence) decides, refused" nz $rc "$out"
else
  echo "NOTE S13: a closed call cannot be reopened through hold here; stacked flow not reachable live"
fi

echo "=== [$LABEL] $RESULTS checks, $FAILS failed ==="
exit 0
