
# ---- live scenarios (appended after the harness definitions) ----
HDR_RECIPE=$(sed -n '/^#   bundle=\/durable/,/^#   printf .%s\\t%s\\t%s/p' "$ROOT/bin/fm-teardown.sh" | sed 's/^#   //')
LIVE_EVID=${LIVE_EVID:?}
RESULTS=$LIVE_EVID/scenario-results.txt
: > "$RESULTS"
rec() { printf '%s\n' "$*" | tee -a "$RESULTS"; }

# Run the header recipe verbatim (bash) for the nested copy.
run_header_recipe() {  # <case_dir> <copy> <bundle>
  local case_dir=$1 copy=$2 bundle_path=$3
  bash -c "bundle='$bundle_path'; copy='$copy'; task=task-x1; FM_HOME='$case_dir'; $(printf '%s\n' "$HDR_RECIPE" | sed '1d')"
}

mk_case() {  # <name> [mode]  -> sets NESTED_* ; one unlanded commit, no bundle
  make_nested_slot_case "$1" enclosing .claude/worktrees/live "${2:-no-mistakes}"
  printf 'recoverable work\n' > "$NESTED_COPY/work.txt"
  git -C "$NESTED_COPY" add work.txt
  git -C "$NESTED_COPY" commit -qm 'unpublished work 1'
  printf 'more work\n' > "$NESTED_COPY/work2.txt"
  git -C "$NESTED_COPY" add work2.txt
  git -C "$NESTED_COPY" commit -qm 'unpublished work 2'
  BUNDLE_PATH="$NESTED_CASE/durable/preservation/task.bundle"
  LIVE_HEAD=$(git -C "$NESTED_COPY" rev-parse HEAD)
}

td() {  # <case_dir> [args...]  -> rc in $RC, logs in <case>/out,err
  local c=$1; shift
  RC=0
  local h=$c/home; [ -d "$h" ] || h=$c/primary-home
  FM_HOME="$h" run_teardown "$c" "$@" > "$c/out" 2> "$c/err" || RC=$?
  cp "$c/err" "$LIVE_EVID/$(basename "$c").stderr.txt"
  { echo "--- cmd: fm-teardown.sh task-x1 $* (rc=$RC)"; cat "$c/out"; } > "$LIVE_EVID/$(basename "$c").stdout.txt"
}

check() {  # <ok-cmd...> ; records pass/fail text
  local label=$1; shift
  if "$@"; then rec "  ok: $label"; else rec "  FAIL: $label"; LIVE_FAILED=1; fi
}
LIVE_FAILED=0
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }

S1_happy_path_header_recipe() {
  rec "S1 header recipe (verbatim) then ordinary teardown, no --force"
  mk_case live-s1; local c=$NESTED_CASE
  seed_backlog_in_flight "$c"
  run_header_recipe "$c" "$NESTED_COPY" "$BUNDLE_PATH" >/dev/null 2>"$LIVE_EVID/s1-recipe.stderr" || { rec "  FAIL: recipe errored"; LIVE_FAILED=1; }
  cp "$c/data/task-x1/preservation-bundles.tsv" "$LIVE_EVID/s1-preservation-bundles.tsv"
  td "$c"
  check "exit code 0" [ "$RC" = 0 ]
  check "copy removed" [ ! -e "$NESTED_COPY" ]
  check "task record retired" [ ! -e "$c/state/task-x1.meta" ]
  check "pool slot returned by treehouse" has "$c/treehouse.log" "return --force $NESTED_SLOT"
  check "stderr names bundle path" has "$c/err" "$BUNDLE_PATH"
  check "stderr names preserved tip $LIVE_HEAD" has "$c/err" "$LIVE_HEAD"
  check "no REFUSED line" hasnt "$c/err" "REFUSED"
  check "backlog row closed as not landed" has "$c/data/backlog.md" "preserved in bundle $BUNDLE_PATH, not landed"
  local r="$c/restored.git"; git init -q --bare "$r"; git -C "$r" fetch -q "$BUNDLE_PATH" "$LIVE_HEAD:refs/heads/recovered" 2>>"$LIVE_EVID/s1-restore.stderr"
  check "commits recoverable from bundle alone (work.txt)" [ "$(git -C "$r" show recovered:work.txt 2>/dev/null)" = "recoverable work" ]
  check "commits recoverable from bundle alone (work2.txt)" [ "$(git -C "$r" show recovered:work2.txt 2>/dev/null)" = "more work" ]
  check "bundle + record survive cleanup" [ -f "$BUNDLE_PATH" -a -f "$c/data/task-x1/preservation-bundles.tsv" ]
  cp "$c/data/backlog.md" "$LIVE_EVID/s1-backlog-after.md"
  S1_CASE=$c
}

S2_no_record_still_refuses() {
  rec "S2 baseline: unlanded commits and no bundle record still refuse (copy kept)"
  mk_case live-s2; local c=$NESTED_CASE
  td "$c"
  check "exit code 1" [ "$RC" = 1 ]
  check "REFUSED line" has "$c/err" "REFUSED: the ship deliverable is not landed"
  check "missing record named" has "$c/err" "missing preservation record"
  check "copy kept" [ -e "$NESTED_COPY/.git" ]
  check "task record kept" [ -e "$c/state/task-x1.meta" ]
  check "slot not returned" [ ! -e "$c/treehouse.log" ]
}

S3_tampered_bundle() {
  rec "S3 adversarial: bundle bytes changed after the record was written"
  mk_case live-s3; local c=$NESTED_CASE
  run_header_recipe "$c" "$NESTED_COPY" "$BUNDLE_PATH" >/dev/null 2>&1
  printf 'tamper\n' >> "$BUNDLE_PATH"
  td "$c"
  check "exit code 1" [ "$RC" = 1 ]
  check "sha256 mismatch named" has "$c/err" "sha256 does not match record"
  check "copy kept" [ -e "$NESTED_COPY/.git" ]
  check "slot not returned" [ ! -e "$c/treehouse.log" ]
}

S4_stale_bundle_then_rebundle() {
  rec "S4 adversarial: new commit after bundling refuses; re-bundle then ordinary teardown works"
  mk_case live-s4; local c=$NESTED_CASE
  run_header_recipe "$c" "$NESTED_COPY" "$BUNDLE_PATH" >/dev/null 2>&1
  printf 'late\n' > "$NESTED_COPY/late.txt"; git -C "$NESTED_COPY" add late.txt; git -C "$NESTED_COPY" commit -qm late
  local late; late=$(git -C "$NESTED_COPY" rev-parse HEAD)
  td "$c"
  check "first run exit 1" [ "$RC" = 1 ]
  check "missing late tip named" has "$c/err" "bundle does not list unlanded tip $late"
  check "copy kept" [ -e "$NESTED_COPY/.git" ]
  run_header_recipe "$c" "$NESTED_COPY" "$BUNDLE_PATH" >/dev/null 2>&1
  td "$c"
  check "after re-bundle exit 0, no --force" [ "$RC" = 0 ]
  check "copy removed" [ ! -e "$NESTED_COPY" ]
}

S5_bundle_inside_pool() {
  rec "S5 adversarial: bundle stored inside the pool is not durable"
  mk_case live-s5; local c=$NESTED_CASE
  BUNDLE_PATH="$c/pool/retained.bundle"
  run_header_recipe "$c" "$NESTED_COPY" "$BUNDLE_PATH" >/dev/null 2>&1
  td "$c"
  check "exit code 1" [ "$RC" = 1 ]
  check "inside pool named" has "$c/err" "bundle is inside"
  check "copy kept" [ -e "$NESTED_COPY/.git" ]
}

S6_pushed_pr_open_with_side_branch() {
  rec "S6 adversarial: pushed copy, PR open, side branch unlanded, valid bundle -> delivery proof still required"
  mk_case live-s6; local c=$NESTED_CASE
  append_pr_meta_url "$c"
  git -C "$NESTED_COPY" push -q origin fm/task-x1-v2
  local side; side=$(git -C "$NESTED_COPY" commit-tree 'HEAD^{tree}' -p origin/main -m 'side work')
  git -C "$NESTED_COPY" update-ref refs/heads/fm/side-only "$side"
  run_header_recipe "$c" "$NESTED_COPY" "$BUNDLE_PATH" >/dev/null 2>&1
  td "$c"
  check "exit code 1" [ "$RC" = 1 ]
  check "delivery-proof reason" has "$c/err" "copy has no unlanded tips of its own; existing delivery proof is still required"
  check "bundle not accepted" hasnt "$c/err" "preserved unlanded commits in bundle"
  check "copy kept" [ -e "$NESTED_COPY/.git" ]
  check "slot not returned" [ ! -e "$c/treehouse.log" ]
}

S7_dirty_copy_with_valid_bundle() {
  rec "S7 adversarial: valid bundle does not excuse uncommitted changes"
  mk_case live-s7; local c=$NESTED_CASE
  run_header_recipe "$c" "$NESTED_COPY" "$BUNDLE_PATH" >/dev/null 2>&1
  printf 'uncommitted\n' > "$NESTED_COPY/dirty.txt"
  td "$c"
  check "exit code nonzero" [ "$RC" != 0 ]
  check "dirty copy kept" [ -f "$NESTED_COPY/dirty.txt" ]
  check "slot not returned" [ ! -e "$c/treehouse.log" ]
  check "uncommitted changes named" grep -qi "uncommitted" "$c/err"
}

S8_thin_bundle() {
  rec "S8 adversarial: thin bundle (needs a base the bundle lacks) cannot restore alone"
  mk_case live-s8; local c=$NESTED_CASE
  local first; first=$(git -C "$NESTED_COPY" rev-parse HEAD~1)
  record_preservation_bundle "$c" "$NESTED_COPY" "$BUNDLE_PATH" "$first..fm/task-x1-v2" || { rec "  FAIL: fixture"; LIVE_FAILED=1; }
  td "$c"
  check "exit code 1" [ "$RC" = 1 ]
  check "restore failure named" has "$c/err" "bundle cannot be restored in an isolated repository"
  check "copy kept" [ -e "$NESTED_COPY/.git" ]
}

S9_plain_worktree_both_modes() {
  local mode
  for mode in no-mistakes local-only; do
    rec "S9 ($mode) plain task worktree (not nested) with unlanded commits: refuse without bundle, ordinary route with bundle"
    local c; c=$(make_case "live-s9-$mode")
    write_meta "$c" "$mode" ship
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/treehouse.log"\nexit 0\n' "$c" > "$c/fakebin/treehouse"; chmod +x "$c/fakebin/treehouse"
    seed_backlog_in_flight "$c"
    wt_commit_file "$c" unlanded.txt "unlanded work" "unpushed work"
    local head; head=$(git -C "$c/wt" rev-parse HEAD)
    td "$c"
    check "$mode: no bundle -> exit 1" [ "$RC" = 1 ]
    check "$mode: no bundle -> REFUSED (unlanded)" has "$c/err" "REFUSED"
    check "$mode: no bundle -> not the home-resolution refusal" hasnt "$c/err" "cannot resolve the root Firstmate home"
    cp "$c/err" "$LIVE_EVID/live-s9-$mode.nobundle.stderr.txt"
    check "$mode: no bundle -> worktree kept" [ -e "$c/wt/.git" ]
    check "$mode: no bundle -> treehouse return NOT called" [ ! -e "$c/treehouse.log" ]
    run_header_recipe "$c" "$c/wt" "$c/durable/$mode.bundle" >/dev/null 2>&1
    td "$c"
    check "$mode: bundle -> exit 0, no --force" [ "$RC" = 0 ]
    check "$mode: bundle -> treehouse return called for the worktree" has "$c/treehouse.log" "return --force $c/wt"
    check "$mode: bundle -> task record retired" [ ! -e "$c/state/task-x1.meta" ]
    check "$mode: bundle -> row not claimed landed" has "$c/data/backlog.md" "preserved in bundle $c/durable/$mode.bundle, not landed"
    check "$mode: bundle -> no 'local main' claim" hasnt "$c/data/backlog.md" "local main"
    local r="$c/restored.git"; git init -q --bare "$r"; git -C "$r" fetch -q "$c/durable/$mode.bundle" "$head:refs/heads/recovered" 2>/dev/null
    check "$mode: commit recoverable" [ "$(git -C "$r" show recovered:unlanded.txt 2>/dev/null)" = "unlanded work" ]
  done
}

S1_happy_path_header_recipe
S2_no_record_still_refuses
S3_tampered_bundle
S4_stale_bundle_then_rebundle
S5_bundle_inside_pool
S6_pushed_pr_open_with_side_branch
S7_dirty_copy_with_valid_bundle
S8_thin_bundle
S9_plain_worktree_both_modes
rec "LIVE_FAILED=$LIVE_FAILED"
echo "$S1_CASE" > "$LIVE_EVID/.s1case"
cp -R "$S1_CASE/data" "$LIVE_EVID/s1-data-copy" 2>/dev/null || true
exit "$LIVE_FAILED"
