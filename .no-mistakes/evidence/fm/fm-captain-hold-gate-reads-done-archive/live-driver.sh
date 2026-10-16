#!/usr/bin/env bash
# Disposable live driver for the done-archive completion gate.
# Drives the real bin/fm-captain-hold.sh, bin/fm-teardown.sh and real tasks-axi
# against throwaway homes. Nothing here touches the operator's real homes.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M537BD1AGE6RA36HWYSSP4K5
LAB=/Users/charlesabrooker/tmp/fm-lab.Y7VXkS
HEADCAP="$WT/bin/fm-captain-hold.sh"
BASECAP="$LAB/base/bin/fm-captain-hold.sh"
# shellcheck disable=SC1091
. "$WT/tests/lib.sh"
TASKS_AXI_BIN=$(command -v tasks-axi)
USERHOME="$LAB/userhome"
GOOD=0
BAD=0
CAP=$HEADCAP

say() { printf '%s\n' "$*"; }
verdict() {  # <ok|bad> <text>
  if [ "$1" = ok ]; then GOOD=$((GOOD + 1)); say "  RESULT: as expected - $2"; else BAD=$((BAD + 1)); say "  RESULT: UNEXPECTED - $2"; fi
}

make_home() {  # <name>
  local home="$LAB/homes/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  git init -q -b main "$home/projects/sample" || return 1
  fm_test_tasks_toml "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  fm_fake_docker "$fakebin"
  printf '%s\n' "$home"
}

tx() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && HOME="$USERHOME" tasks-axi "$@")
}

cap() {  # <home> <args...>
  local home=$1
  shift
  HOME="$USERHOME" PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$CAP" "$@"
}

teardown() {  # <home> <id>
  local home=$1
  HOME="$USERHOME" PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$WT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$WT/bin/fm-teardown.sh" "$2"
}

set_retention() {  # <home> <archive-path>
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' \
    "archive = \"$2\"" 'done_keep = 1' > "$1/.tasks.toml"
}

filler() {  # <home> <id>
  tx "$1" add "$2" "Filler closed row" --kind captain --repo sample >/dev/null || return 1
  tx "$1" "done" "$2" >/dev/null || return 1
}

answered_call() {  # <home> <id> <origin>
  local home=$1 id=$2 origin=$3
  cap "$home" hold "$id" --title "Captain call $id" --reason "captain must decide $id" \
    --repo sample --origin "$origin" >/dev/null || return 1
  printf 'Go with the recorded option for %s.\n' "$id" > "$home/answer-$id.txt"
  cap "$home" answer "$id" --decision-file "$home/answer-$id.txt" >/dev/null || return 1
  filler "$home" "filler-$(printf '%s' "$id$RANDOM" | cksum | cut -d' ' -f1)"
}

unanswered_call() {  # <home> <id>
  tx "$1" add "$2" "Closed with no answer $2" --kind captain --repo sample >/dev/null || return 1
  tx "$1" "done" "$2" >/dev/null || return 1
  filler "$1" "filler-$(printf '%s' "$2$RANDOM" | cksum | cut -d' ' -f1)"
}

scout_meta() {  # <home> <scout> <keys>
  local home=$1 scout=$2 keys=$3
  mkdir -p "$home/data/$scout"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" "harness=codex" "kind=scout" \
    "spawn_gen=fixture-$scout" "decisions_reviewed=1" "decision_keys=$keys"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"
}

# run <label> <expect:pass|refuse> <needle-or-empty> <home> <args...>
run() {
  local label=$1 expect=$2 needle=$3 home=$4 out rc=0
  shift 4
  out=$(cap "$home" "$@" 2>&1) || rc=$?
  say "  \$ fm-captain-hold.sh $* -> exit $rc"
  printf '%s\n' "$out" | head -8 | sed 's/^/      | /'
  case $expect in
    pass)
      if [ "$rc" -eq 0 ] && { [ -z "$needle" ] || printf '%s' "$out" | grep -qF -- "$needle"; }; then verdict ok "$label"; else verdict bad "$label (wanted exit 0 containing '$needle')"; fi ;;
    refuse)
      if [ "$rc" -ne 0 ] && { [ -z "$needle" ] || printf '%s' "$out" | grep -qF -- "$needle"; }; then verdict ok "$label"; else verdict bad "$label (wanted nonzero exit containing '$needle')"; fi ;;
  esac
}

head_h() { say; say "=== $* ==="; }

mkdir -p "$LAB/homes"

# ---------------------------------------------------------------------------
head_h "S1 BEFORE the fix (base commit fac61f9b): archived answered call is refused"
CAP=$BASECAP
h=$(make_home s1-base); set_retention "$h" data/done-archive.md
answered_call "$h" sample-archived-call sample-scout || say "setup failed"
say "  archive holds the call: $(grep -c 'sample-archived-call' "$h/data/done-archive.md") line(s); backlog holds it: $(grep -c 'sample-archived-call' "$h/data/backlog.md")"
scout_meta "$h" sample-scout sample-archived-call
run "base refuses the archived answered call (the reported bug)" refuse "" "$h" verify sample-scout
run "base complete --none refuses too" refuse "" "$h" complete sample-scout --none

head_h "S2 AFTER the fix (target commit): same fixture, gate resolves the archived answer"
CAP=$HEADCAP
run "verify resolves the archived answered call" pass "" "$h" verify sample-scout
run "complete --none passes and discloses the archive" pass "[answered and archived: sample-archived-call]" "$h" complete sample-scout --none
say "  meta: $(grep decision_keys "$h/state/sample-scout.meta")"

# ---------------------------------------------------------------------------
head_h "S3 scout teardown gate follows the archived answer"
h=$(make_home s3-teardown); set_retention "$h" data/done-archive.md
answered_call "$h" t-answered t-scout; unanswered_call "$h" t-unanswered
mkdir -p "$h/data/t-scout" "$h/projects/t-scout"
tx "$h" add t-scout "Investigate" --kind scout --repo sample --start >/dev/null
fm_write_meta "$h/state/t-scout.meta" "window=firstmate:fm-t-scout" "worktree=$h/projects/t-scout" \
  "project=$h/projects/sample" "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-t" \
  "decisions_reviewed=1" "decision_keys=t-unanswered"
printf 'done: report complete\n' > "$h/state/t-scout.status"
printf '# Report\n\nDone.\n' > "$h/data/t-scout/report.md"
rc=0; out=$(teardown "$h" t-scout 2>&1) || rc=$?
say "  \$ fm-teardown.sh t-scout (key = archived UNANSWERED call) -> exit $rc"
printf '%s\n' "$out" | grep -E 'completion gate|archived|captain' | head -4 | sed 's/^/      | /'
if [ "$rc" -ne 0 ] && [ -f "$h/state/t-scout.meta" ] && printf '%s' "$out" | grep -q 'has not passed the captain-call completion gate'; then verdict ok "teardown blocked, scout record kept"; else verdict bad "teardown should block"; fi
printf 'decisions_reviewed=1\ndecision_keys=t-answered\n' >> "$h/state/t-scout.meta"
rc=0; out=$(teardown "$h" t-scout 2>&1) || rc=$?
say "  \$ fm-teardown.sh t-scout (key = archived ANSWERED call) -> exit $rc"
printf '%s\n' "$out" | head -5 | sed 's/^/      | /'
if [ "$rc" -eq 0 ] && [ ! -f "$h/state/t-scout.meta" ]; then verdict ok "teardown retired the scout"; else verdict bad "teardown should pass"; fi

# ---------------------------------------------------------------------------
head_h "S4 adversarial: archived call closed with no captain answer is refused"
h=$(make_home s4); set_retention "$h" data/done-archive.md
unanswered_call "$h" sample-no-answer; scout_meta "$h" s4-scout sample-no-answer
run "refused: archived without a recorded captain answer" refuse "archived without a recorded captain answer" "$h" complete s4-scout --none

head_h "S5 adversarial: call closed only by reconcile evidence stays refused"
h=$(make_home s5); set_retention "$h" data/done-archive.md
tx "$h" add s5-scout "Investigation" --kind scout --repo sample >/dev/null
cap "$h" hold sample-moot --title "Captain call" --reason "decide" --repo sample --origin s5-scout >/dev/null
cap "$h" bind archive-src >/dev/null 2>&1
printf 'sample-moot\n' | cap "$h" reconcile-requests --source-id archive-src >/dev/null 2>&1
printf 'Nothing pending; no captain answer was given.\n' > "$h/ev.txt"
cap "$h" reconcile close sample-moot --evidence-file "$h/ev.txt" --verified-outcome moot >/dev/null 2>&1 || say "  (reconcile close setup rc=$?)"
filler "$h" filler-ev
say "  archive has Reconciliation evidence: $(grep -c 'Reconciliation evidence:' "$h/data/done-archive.md"); Captain decision lines: $(grep -c 'Captain decision:' "$h/data/done-archive.md")"
scout_meta "$h" s5-scout sample-moot
run "refused: only reconciliation evidence" refuse "only reconciliation evidence, not a recorded captain answer" "$h" complete s5-scout --none

head_h "S6 adversarial: archived row that merely quotes the record markers is refused"
h=$(make_home s6); set_retention "$h" data/done-archive.md
printf 'Notes: the "Resolution recorded by fm-captain-hold." line and a "Captain decision:" line.\n' > "$h/forge.txt"
tx "$h" add sample-forged "Forged" --kind captain --repo sample --body-file "$h/forge.txt" >/dev/null
tx "$h" "done" sample-forged >/dev/null; filler "$h" filler-forge
scout_meta "$h" s6-scout sample-forged
run "refused: quoting markers is no record" refuse "archived without a recorded captain answer" "$h" complete s6-scout --none

head_h "S7 adversarial: call held for a different origin is refused"
h=$(make_home s7); set_retention "$h" data/done-archive.md
answered_call "$h" sample-other-origin some-other-scout
scout_meta "$h" s7-scout sample-other-origin
run "refused: held for another origin" refuse "" "$h" complete s7-scout --none

head_h "S8 adversarial: neighbour id (prefix of an archived id) does not resolve"
h=$(make_home s8); set_retention "$h" data/done-archive.md
answered_call "$h" sample-call-two s8-scout
scout_meta "$h" s8-scout sample-call
run "refused: only the exact archived id counts" refuse "" "$h" complete s8-scout --none
scout_meta "$h" s8-scout sample-call-two
run "exact id passes" pass "[answered and archived: sample-call-two]" "$h" complete s8-scout --none

head_h "S9 adversarial: id archived twice in one file - the NEWEST record decides"
h=$(make_home s9a); set_retention "$h" data/done-archive.md
answered_call "$h" sample-twice s9-scout
tx "$h" add sample-twice "again" --kind captain --repo sample >/dev/null && tx "$h" "done" sample-twice >/dev/null; filler "$h" filler-twice-a
say "  archive rows for the id: $(grep -c '^- \[.\] sample-twice' "$h/data/done-archive.md")"
scout_meta "$h" s9-scout sample-twice
run "older answered, newer unanswered => refused" refuse "" "$h" complete s9-scout --none
h=$(make_home s9b); set_retention "$h" data/done-archive.md
unanswered_call "$h" sample-twice
answered_call "$h" sample-twice s9-scout
say "  archive rows for the id: $(grep -c '^- \[.\] sample-twice' "$h/data/done-archive.md")"
scout_meta "$h" s9-scout sample-twice
run "older unanswered, newer answered => passes" pass "" "$h" complete s9-scout --none

head_h "S10 archive path in .tasks.toml: absolute path, hash in path, spaced header"
h=$(make_home s10a); mkdir -p "$LAB/abs"; set_retention "$h" "$LAB/abs/answered.md"
answered_call "$h" sample-abs s10-scout; scout_meta "$h" s10-scout sample-abs
say "  call is in the absolute-path archive: $(grep -c sample-abs "$LAB/abs/answered.md")"
run "absolute archive path resolves" pass "[answered and archived: sample-abs]" "$h" complete s10-scout --none
h=$(make_home s10b); set_retention "$h" "data/closed#later.md"
answered_call "$h" sample-hash s10-scout; scout_meta "$h" s10-scout sample-hash
say "  archive file: $(ls "$h/data" | grep -F 'closed' | tr '\n' ' ')"
run "archive = \"data/closed#later.md\" names the whole file" pass "[answered and archived: sample-hash]" "$h" complete s10-scout --none
h=$(make_home s10c)
printf '%s\n' 'backend = "markdown"' '' '[ markdown ]' 'path = "data/backlog.md"' 'archive = "data/spaced.md"' 'done_keep = 1' > "$h/.tasks.toml"
answered_call "$h" sample-spaced s10-scout; scout_meta "$h" s10-scout sample-spaced
say "  call is in data/spaced.md: $(grep -c sample-spaced "$h/data/spaced.md")"
run "[ markdown ] header is honoured" pass "[answered and archived: sample-spaced]" "$h" complete s10-scout --none

head_h "S11 adversarial: settings the gate must refuse (answered row sits in the file the setting names)"
for form in inline quoted-header dotted duplicate-tables escape triple-quote non-string empty; do
  h=$(make_home "s11-$form"); set_retention "$h" data/redirected.md
  answered_call "$h" sample-form s11-scout; scout_meta "$h" s11-scout sample-form
  case $form in
    inline) printf '%s\n' 'backend = "markdown"' 'markdown = { path = "data/backlog.md", archive = "data/redirected.md", done_keep = 1 }' > "$h/.tasks.toml" ;;
    quoted-header) printf '%s\n' 'backend = "markdown"' '["markdown"]' 'path = "data/backlog.md"' 'archive = "data/redirected.md"' 'done_keep = 1' > "$h/.tasks.toml" ;;
    dotted) printf '%s\n' 'backend = "markdown"' 'markdown.path = "data/backlog.md"' 'markdown.archive = "data/redirected.md"' 'markdown.done_keep = 1' > "$h/.tasks.toml" ;;
    duplicate-tables) printf '%s\n' 'backend = "markdown"' '[markdown]' 'path = "data/backlog.md"' 'archive = "data/redirected.md"' '[markdown]' 'done_keep = 1' > "$h/.tasks.toml" ;;
    escape) printf '%s\n' 'backend = "markdown"' '[markdown]' 'path = "data/backlog.md"' "archive = \"data/\u0072edirected.md\"" 'done_keep = 1' > "$h/.tasks.toml" ;;
    triple-quote) printf '%s\n' 'backend = "markdown"' '[markdown]' 'path = "data/backlog.md"' 'archive = """data/redirected.md"""' 'done_keep = 1' > "$h/.tasks.toml" ;;
    non-string) printf '%s\n' 'backend = "markdown"' '[markdown]' 'path = "data/backlog.md"' 'archive = 5' 'done_keep = 1' > "$h/.tasks.toml" ;;
    empty) printf '%s\n' 'backend = "markdown"' '[markdown]' 'path = "data/backlog.md"' 'archive = ""' 'done_keep = 1' > "$h/.tasks.toml" ;;
  esac
  say "  -- form: $form"
  run "$form setting refused" refuse "" "$h" complete s11-scout --none
done

head_h "S12 adversarial: archive path set only in user-level ~/.tasks-axi/config.toml stays refused"
h=$(make_home s12); UH="$LAB/userhome-s12"; mkdir -p "$UH/.tasks-axi"
printf '%s\n' '[markdown]' 'archive = "data/user-archive.md"' > "$UH/.tasks-axi/config.toml"
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' 'done_keep = 1' > "$h/.tasks.toml"
saved=$USERHOME; USERHOME=$UH
answered_call "$h" sample-userlevel s12-scout; scout_meta "$h" s12-scout sample-userlevel
say "  call archived at: $(ls "$h/data" | tr '\n' ' ')"
run "refused: user-level archive path is not read" refuse "set outside this home's .tasks.toml" "$h" complete s12-scout --none
USERHOME=$saved

head_h "S13 adversarial: no tomllib / no python3 gets its own reason, not the syntax message"
h=$(make_home s13); set_retention "$h" data/done-archive.md
answered_call "$h" sample-nopy s13-scout; scout_meta "$h" s13-scout sample-nopy
real_python=$(command -v python3)
mkdir -p "$LAB/stub-notomllib" "$LAB/stub-failpy"
cat > "$LAB/stub-notomllib/python3" <<STUB
#!/bin/sh
shift 2
exec "$real_python" -I -c 'import sys; sys.modules["tomllib"] = None; exec(sys.stdin.read())' "\$@"
STUB
printf '#!/bin/sh\nexit 127\n' > "$LAB/stub-failpy/python3"
chmod +x "$LAB/stub-notomllib/python3" "$LAB/stub-failpy/python3"
for stub in stub-notomllib stub-failpy; do
  rc=0; out=$(PATH="$LAB/$stub:$PATH" cap "$h" complete s13-scout --none 2>&1) || rc=$?
  say "  \$ [python3 = $stub] fm-captain-hold.sh complete s13-scout --none -> exit $rc"
  printf '%s\n' "$out" | head -4 | sed 's/^/      | /'
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'needs python3 with tomllib' && ! printf '%s' "$out" | grep -q 'uses syntax the gate cannot read'; then verdict ok "own tomllib reason ($stub)"; else verdict bad "own tomllib reason ($stub)"; fi
done
run "same call passes again with real python3" pass "[answered and archived: sample-nopy]" "$h" complete s13-scout --none

head_h "S14 live rows unchanged: a still-open captain call is not satisfied by the archive path"
h=$(make_home s14); set_retention "$h" data/done-archive.md
cap "$h" hold sample-open --title "Open call" --reason "decide" --repo sample --origin s14-scout >/dev/null
scout_meta "$h" s14-scout sample-open
CAP=$BASECAP; run "BASE: an open live hold is a durable record, so the inventory passes" pass "" "$h" complete s14-scout --none
CAP=$HEADCAP; run "HEAD: same open live hold, same result, no archive disclosure" pass "reviewed (sample-open)" "$h" complete s14-scout --none
cap "$h" hold sample-open2 --title "Open call 2" --reason "decide" --repo sample --origin s14-scout >/dev/null
printf 'Go.\n' > "$h/a.txt"; cap "$h" answer sample-open2 --decision-file "$h/a.txt" >/dev/null
scout_meta "$h" s14-scout sample-open2
run "live closed (not yet archived) answered call passes with NO archive disclosure" pass "" "$h" complete s14-scout --none

head_h "S15 legacy short key resolves to an archived <origin>-decision-<key> row (answered passes, unanswered refuses)"
h=$(make_home s15); set_retention "$h" data/done-archive.md
answered_call "$h" s15-scout-decision-pick-one s15-scout
unanswered_call "$h" s15-scout-decision-keep-two
say "  archived legacy ids: $(grep -E '^- \[x\] s15-scout-decision' "$h/data/done-archive.md" | awk '{print $3}' | tr '\n' ' ')"
scout_meta "$h" s15-scout pick-one
run "short key pick-one -> archived s15-scout-decision-pick-one (answered)" pass "[answered and archived: s15-scout-decision-pick-one]" "$h" complete s15-scout --none
scout_meta "$h" s15-scout keep-two
run "short key keep-two -> archived legacy row without an answer" refuse "archived without a recorded captain answer" "$h" complete s15-scout --none

say
say "=== SUMMARY: expected=$GOOD unexpected=$BAD ==="
