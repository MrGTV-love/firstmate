#!/usr/bin/env bash
# usage: cli-scenario.sh <worktree> <scenario>
# Drives ONE scenario through the real bin/fm-teardown.sh of <worktree>, in a
# scratch FM_HOME/state/data/config built by the suite's own fixture builders
# (make_case: a fake treehouse pool slot, a fake closeout driver, a throwaway
# project and origin), all under this run's own TMPDIR. One teardown per
# scenario arm. It never touches a real pool slot, home, lock or task.
# Every fact is printed as "FACT ok|BAD ..."; the run's artefacts (stdout,
# stderr, git worktree argv log, driver argv log, preserve listing) are copied
# out before the scratch root is removed.
set -u
W=$1 SC=$2
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M87E3DXKY8YXG964RQ01FZ3D/rerun-s3
export TMPDIR=${SCEN_TMPDIR:-/Users/charlesabrooker/tmp/nm-01M87E3D-test-cli}
mkdir -p "$TMPDIR"
cd "$W" || exit 2
ART="$EV/scenario-$SC.artefacts"
rm -rf "$ART"; mkdir -p "$ART"

# shellcheck source=/dev/null
. tests/fm-teardown-helpers.sh
case "$SC" in
  s3-*|s4-*) SUITE=tests/fm-teardown.test.sh ;;
  *) SUITE=tests/fm-teardown-cleanup.test.sh ;;
esac
# The suite's fixture functions, without its helper source line and its runner line.
eval "$(sed -e '/^\. "\$(dirname "\${BASH_SOURCE\[0\]}")\/fm-teardown-helpers.sh"\( || exit 1\)\{0,1\}$/d' -e '$d' "$SUITE")"

BAD=0
fact() {  # <0|1> <text>
  if [ "$1" = 0 ]; then echo "FACT ok  - $2"; else echo "FACT BAD - $2"; BAD=1; fi
}
has() { grep -qF -- "$1" "$2" 2>/dev/null; }
CASE_DIR=
save() {
  [ -n "$CASE_DIR" ] && [ -d "$CASE_DIR" ] || return 0
  local f
  for f in stdout stderr git-worktree.log closeout.log closeout-plan.log closeout.record treehouse.log mutate.sh; do
    [ -f "$CASE_DIR/$f" ] && cp "$CASE_DIR/$f" "$ART/$f"
  done
  (cd "$CASE_DIR" && find data -type f 2>/dev/null | LC_ALL=C sort) > "$ART/data-files.txt"
  find "$CASE_DIR/data" -name SHA256SUMS -type f 2>/dev/null | while IFS= read -r f; do
    printf '== %s\n' "${f#"$CASE_DIR"/}"; cat "$f"
  done > "$ART/preserve-SHA256SUMS.txt"
  git -C "$CASE_DIR/project" worktree list --porcelain > "$ART/worktree-list.txt" 2>&1 || true
}
on_exit() {
  local rc=$?
  save
  [ -z "${LIVE_PID:-}" ] || { kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null; }
  teardown_fixture_cleanup 2>/dev/null || true
  fm_test_cleanup 2>/dev/null || true
  exit "$rc"
}
trap on_exit EXIT

show_cmd() {  # <case>
  echo "\$ env FM_HOME=$1/home FM_ROOT_OVERRIDE=$1/code-root FM_STATE_OVERRIDE=$1/state FM_DATA_OVERRIDE=$1/data FM_CONFIG_OVERRIDE=$1/config NM_HOME=$1/nm PATH=$1/fakebin:\$PATH $TEARDOWN task-x1 $*"
}

# Ignored files in <copy>: one per class the rulings name.
seed_ignored() {  # <copy> [all|claude-only]
  local exclude
  exclude=$(git -C "$1" rev-parse --path-format=absolute --git-path info/exclude)
  printf '%s\n' .claude/channel-outbox/ .opencode/ notes/ .cache/ >> "$exclude"
  mkdir -p "$1/.claude/channel-outbox" "$1/.opencode/state"
  printf 'one\n' > "$1/.claude/channel-outbox/a.jsonl"
  printf 'evidence\n' > "$1/.opencode/state/log.json"
  [ "${2:-all}" = all ] || return 0
  mkdir -p "$1/notes" "$1/.cache"
  printf 'run\n' > "$1/.cache/run.bin"
  printf 'only here\n' > "$1/notes/unique.dat"
}
WIDE_FILES='.cache/run.bin:run .claude/channel-outbox/a.jsonl:one .opencode/state/log.json:evidence notes/unique.dat:only_here'

# A git wrapper that logs worktree argv and runs <case>/mutate.sh once, at the
# first `git worktree unlock` (immediately before the release's real unlock).
add_unlock_mutation() {  # <case>
  cat > "$1/fakebin/git" <<SH
#!/usr/bin/env bash
for argument in "\$@"; do
  if [ "\$argument" = worktree ]; then printf '%s\n' "\$*" >> "$1/git-worktree.log"; break; fi
done
case " \$* " in
  *" worktree unlock "*)
    if [ ! -e "$1/mutated" ]; then : > "$1/mutated"; bash "$1/mutate.sh"; fi ;;
esac
exec "\${REAL_GIT_FOR_TEST:?}" "\$@"
SH
  chmod +x "$1/fakebin/git"
}

# Preserved copies of <rel> under data/task-x1/nested-copy-preserved, as
# "<bytes>|<sums-line-matches>" per preserve.
preserved_of() {  # <case> <rel>
  local p sums
  find "$1/data/task-x1/nested-copy-preserved" -path "*/files/$2" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r p; do
    sums=no
    grep -qxF "$(shasum -a 256 "$p" | awk '{print $1}')  $2" "${p%/files/*}/meta/SHA256SUMS" 2>/dev/null && sums=yes
    printf '%s|sums=%s\n' "$(tr '\n' ' ' < "$p" | sed 's/ $//')" "$sums"
  done
}

assert_released() {  # <label-in-stderr> <pid>
  local c=$FOREIGN_CASE
  has "released creation lock 'vernant-session-active owner=launcher:$2 launcher=$2' on $1 copy $FOREIGN_COPY" "$c/stderr"; fact $? "stderr reports the script's own release of the dead launcher's lock on the $1 copy"
  has "removed it without force" "$c/stderr"; fact $? "stderr says the removal was unforced"
  has "worktree unlock $FOREIGN_COPY" "$c/git-worktree.log"; fact $? "git argv log shows a plain 'worktree unlock' by the script"
  grep -Fxq -- "-C $FOREIGN_SLOT worktree remove $FOREIGN_COPY" "$c/git-worktree.log"; fact $? "git argv log shows the plain non-forced 'worktree remove'"
  ! grep -Eq 'worktree remove .*(^| )(-f|--force)( |$)' "$c/git-worktree.log"; fact $? "no forced removal in the git argv log"
  ! has 'run git worktree unlock' "$c/stderr" && ! has 'fm-captain-hold.sh hold' "$c/stderr"; fact $? "no owner command printed (no 'run git worktree unlock', no hold command)"
  [ ! -e "$FOREIGN_COPY" ]; fact $? "the copy is gone"
  [ ! -e "$c/state/task-x1.meta" ]; fact $? "the task record is gone"
}

assert_kept_locked() {
  local c=$FOREIGN_CASE
  [ -e "$FOREIGN_COPY/.git" ]; fact $? "the copy is still there"
  git -C "$c/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | grep -q '^locked'; fact $? "the copy is still locked"
  [ -e "$c/state/task-x1.meta" ]; fact $? "the task record is still there"
  ! has 'released creation lock' "$c/stderr"; fact $? "no release was printed"
}

assert_wide_preserved() {  # [<file:bytes>...]  (bytes: '_' stands for a space)
  local c=$FOREIGN_CASE f want got
  [ "$#" -gt 0 ] || set -- $WIDE_FILES
  for f in "$@"; do
    want="$(printf '%s' "${f#*:}" | tr _ ' ')|sums=yes"
    got=$(preserved_of "$c" "${f%%:*}")
    printf '%s\n' "$got" | grep -qxF "$want"; fact $? "${f%%:*} preserved byte for byte with its SHA256SUMS line (found: $(printf '%s' "$got" | paste -sd ';' -))"
  done
}

rc=0
case "$SC" in
  r6-foreign-release)
    # R6-1 + S1: foreign copy of a ship task, dead launcher, interpreter unavailable.
    # Only .claude/.opencode ignored files: the default list (the kept-files hold)
    # skips them, so the copy reaches the direct release, which must keep them whole.
    dead_launcher_pid
    make_foreign_copy_case foreign-release "$FOREIGN_DEAD_PID"; CASE_DIR=$FOREIGN_CASE
    add_git_worktree_log "$FOREIGN_CASE"
    seed_ignored "$FOREIGN_COPY" claude-only
    rm -f "$FOREIGN_CASE/vernant-python"
    show_cmd "$FOREIGN_CASE"; run_foreign_teardown rc; echo "teardown rc=$rc"
    [ "$rc" = 0 ]; fact $? "teardown exits 0"
    assert_released foreign "$FOREIGN_DEAD_PID"
    assert_wide_preserved .claude/channel-outbox/a.jsonl:one .opencode/state/log.json:evidence
    ;;
  r8-foreign-held)
    # R8-1 on a ship task: a foreign copy holding a top-level .cache and notes/
    # (default-list ignored files) is held by the base kept-files rule: never
    # unlocked, never removed, byte for byte unchanged.
    dead_launcher_pid
    make_foreign_copy_case foreign-held "$FOREIGN_DEAD_PID"; CASE_DIR=$FOREIGN_CASE
    add_git_worktree_log "$FOREIGN_CASE"
    seed_ignored "$FOREIGN_COPY"
    rm -f "$FOREIGN_CASE/vernant-python"
    before=$(cd "$FOREIGN_COPY" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256)
    show_cmd "$FOREIGN_CASE"; run_foreign_teardown rc; echo "teardown rc=$rc"
    grep -m1 'held foreign copy' "$FOREIGN_CASE/stdout"
    has "held foreign copy $FOREIGN_COPY stays" "$FOREIGN_CASE/stdout" && has 'it holds ignored files that exist nowhere else: .cache notes' "$FOREIGN_CASE/stdout"; fact $? "the copy is held and the notice names .cache and notes"
    [ -e "$FOREIGN_COPY/.git" ]; fact $? "the copy is still there"
    git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | grep -q '^locked vernant-session-active'; fact $? "the copy is still locked with its Vernant lock"
    after=$(cd "$FOREIGN_COPY" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256)
    [ "$before" = "$after" ]; fact $? "every file of the copy is byte for byte unchanged"
    ! grep -Eq 'worktree (unlock|remove)' "$FOREIGN_CASE/git-worktree.log"; fact $? "no worktree unlock or remove ran"
    ;;
  r6-own-release)
    # R6-1 own nested + S1: own nested copy, dead launcher, interpreter unavailable.
    dead_launcher_pid
    make_own_locked_copy_case own-release enclosing "$FOREIGN_DEAD_PID"; CASE_DIR=$FOREIGN_CASE
    add_git_worktree_log "$FOREIGN_CASE"
    seed_ignored "$FOREIGN_COPY"
    rm -f "$FOREIGN_CASE/vernant-python"
    show_cmd "$FOREIGN_CASE"; run_foreign_teardown rc; echo "teardown rc=$rc"
    [ "$rc" = 0 ]; fact $? "teardown exits 0"
    assert_released 'own nested' "$FOREIGN_DEAD_PID"
    assert_wide_preserved
    ;;
  r7-own-late-claude)
    # R7-1 adversarial: a .claude file appears in the own copy just before the unlock.
    dead_launcher_pid
    make_own_locked_copy_case own-late enclosing "$FOREIGN_DEAD_PID"; CASE_DIR=$FOREIGN_CASE
    seed_ignored "$FOREIGN_COPY"
    rm -f "$FOREIGN_CASE/vernant-python"
    add_unlock_mutation "$FOREIGN_CASE"
    printf 'printf "late\\n" > %q\n' "$FOREIGN_COPY/.claude/channel-outbox/c.jsonl" > "$FOREIGN_CASE/mutate.sh"
    show_cmd "$FOREIGN_CASE"; run_foreign_teardown rc; echo "teardown rc=$rc"
    [ -e "$FOREIGN_CASE/mutated" ]; fact $? "the late file was written at the unlock"
    [ "$rc" = 1 ]; fact $? "teardown exits 1"
    has 'the .claude and .opencode trees whole included' "$FOREIGN_CASE/stderr" && has 'its lock was restored' "$FOREIGN_CASE/stderr"; fact $? "the refusal names the unpreserved .claude/.opencode file and says the lock was restored"
    [ "$(cat "$FOREIGN_COPY/.claude/channel-outbox/c.jsonl" 2>/dev/null)" = late ]; fact $? "the late file is still in the copy"
    ! grep -q 'worktree remove' "$FOREIGN_CASE/git-worktree.log"; fact $? "no worktree remove ran"
    assert_kept_locked
    ;;
  r8-foreign-late-change)
    # R8-1 adversarial on the reachable foreign shape: after the preserve and just
    # before the unlock, a .claude file changes and a new top-level .cache file
    # appears. No byte may be lost: either the copy stays with them, or the new
    # bytes are preserved with SHA256SUMS lines and the earlier preserve is kept aside.
    dead_launcher_pid
    make_foreign_copy_case foreign-late "$FOREIGN_DEAD_PID"; CASE_DIR=$FOREIGN_CASE
    seed_ignored "$FOREIGN_COPY" claude-only
    rm -f "$FOREIGN_CASE/vernant-python"
    add_unlock_mutation "$FOREIGN_CASE"
    printf 'mkdir -p %q\nprintf "late\\n" > %q\nprintf "one-rerun\\n" > %q\n' "$FOREIGN_COPY/.cache" "$FOREIGN_COPY/.cache/run.bin" "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl" > "$FOREIGN_CASE/mutate.sh"
    show_cmd "$FOREIGN_CASE"; run_foreign_teardown rc; echo "teardown rc=$rc"
    [ -e "$FOREIGN_CASE/mutated" ]; fact $? "the change was written at the unlock"
    grep -v '^●' "$FOREIGN_CASE/stderr" | grep -m3 -E 'REFUSED|released creation lock|not released'
    echo "preserves of .cache/run.bin: $(preserved_of "$FOREIGN_CASE" .cache/run.bin | paste -sd ';' -)"
    echo "preserves of .claude/channel-outbox/a.jsonl: $(preserved_of "$FOREIGN_CASE" .claude/channel-outbox/a.jsonl | paste -sd ';' -)"
    if [ -e "$FOREIGN_COPY" ]; then
      echo "outcome: copy kept"
      [ "$(cat "$FOREIGN_COPY/.cache/run.bin")" = late ] && [ "$(cat "$FOREIGN_COPY/.claude/channel-outbox/a.jsonl")" = one-rerun ]; fact $? "copy kept: the new .cache and .claude bytes are still in the copy"
      ! grep -q 'worktree remove' "$FOREIGN_CASE/git-worktree.log"; fact $? "copy kept: no worktree remove ran"
    else
      echo "outcome: copy removed"
      preserved_of "$FOREIGN_CASE" .cache/run.bin | grep -qxF 'late|sums=yes'; fact $? "copy removed: the new .cache/run.bin bytes are preserved with their SHA256SUMS line"
      preserved_of "$FOREIGN_CASE" .claude/channel-outbox/a.jsonl | grep -qxF 'one-rerun|sums=yes'; fact $? "copy removed: the new .claude bytes are preserved with their SHA256SUMS line"
      preserved_of "$FOREIGN_CASE" .claude/channel-outbox/a.jsonl | grep -q '^one|'; fact $? "the earlier preserve holding the old .claude bytes is kept aside"
      ! grep -Eq 'worktree remove .*(^| )(-f|--force)( |$)' "$FOREIGN_CASE/git-worktree.log"; fact $? "no forced removal"
    fi
    ;;
  live-launcher)
    # Adversarial / S2: the launcher is alive and started before its lock.
    dead_launcher_pid
    make_own_locked_copy_case live-launcher enclosing "$FOREIGN_DEAD_PID"; CASE_DIR=$FOREIGN_CASE
    add_git_worktree_log "$FOREIGN_CASE"
    seed_ignored "$FOREIGN_COPY"
    rm -f "$FOREIGN_CASE/vernant-python"
    sleep 900 & LIVE_PID=$!
    git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY"
    git -C "$FOREIGN_CASE/project" worktree lock --reason "vernant-session-active owner=launcher:$LIVE_PID launcher=$LIVE_PID" "$FOREIGN_COPY"
    : > "$FOREIGN_CASE/git-worktree.log"
    lockf="$(git -C "$FOREIGN_COPY" rev-parse --absolute-git-dir)/locked"
    locked_at=$(( $(date +%s) - 120 )); start=$(( locked_at - 1 ))
    python3 -c 'import os, sys; t = int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$lockf" "$locked_at"
    cat > "$FOREIGN_CASE/fakebin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"-p $LIVE_PID -o pid="*|*"-o pid= -p $LIVE_PID"*) echo " $LIVE_PID"; exit 0 ;;
  *"-p $LIVE_PID -o etime="*|*"-o etime= -p $LIVE_PID"*)
    age=\$(( \$(date +%s) - $start )); printf '%02d:%02d:%02d\n' \$(( age / 3600 )) \$(( age % 3600 / 60 )) \$(( age % 60 )); exit 0 ;;
  *"-p $LIVE_PID -o lstart="*|*"-o lstart= -p $LIVE_PID"*)
    TZ=UTC0 LC_ALL=C "$(command -v python3)" -c 'import sys, time; print(time.strftime("%a %b %e %H:%M:%S %Y", time.gmtime(int(sys.argv[1]))))' $start; exit 0 ;;
esac
exec "\${REAL_PS_FOR_TEST:?}" "\$@"
SH
    chmod +x "$FOREIGN_CASE/fakebin/ps"
    show_cmd "$FOREIGN_CASE"; run_foreign_teardown rc; echo "teardown rc=$rc"
    [ "$rc" = 1 ]; fact $? "teardown exits 1"
    grep -E "launcher (process )?$LIVE_PID" "$FOREIGN_CASE/stderr" | head -3
    grep -qE "launcher (process )?$LIVE_PID (may still be running|is still running|is running)" "$FOREIGN_CASE/stderr"; fact $? "the refusal names the live launcher pid"
    ! grep -q 'worktree unlock' "$FOREIGN_CASE/git-worktree.log"; fact $? "no unlock ran"
    [ -z "$(preserved_of "$FOREIGN_CASE" .claude/channel-outbox/a.jsonl)" ]; fact $? "no wide (.claude) preserve was made"
    kill -0 "$LIVE_PID" 2>/dev/null; fact $? "the live launcher was not signalled"
    assert_kept_locked
    ;;
  s2-open-file-holder)
    # S2: a process holds a file in the copy open (cwd outside); dead launcher.
    dead_launcher_pid
    make_own_locked_copy_case holder enclosing "$FOREIGN_DEAD_PID"; CASE_DIR=$FOREIGN_CASE
    add_git_worktree_log "$FOREIGN_CASE"
    rm -f "$FOREIGN_CASE/vernant-python"
    held="$(cd "$FOREIGN_COPY" && pwd -P)/.git"
    # shellcheck disable=SC2016
    teardown_fixture_start "$FOREIGN_CASE" KILL bash -c 'exec 3<"$1"; exec sleep 3600' holder "$held"
    hpid=$TEARDOWN_FIXTURE_PID
    for _ in $(seq 100); do "$REAL_LSOF_FOR_TEST" -p "$hpid" -Fn 2>/dev/null | grep -qxF "n$held" && break; sleep 0.05; done
    cat > "$FOREIGN_CASE/fakebin/lsof" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -d cwd "*) exit 0 ;;
  *" -Fpfn "*) exec "\${REAL_LSOF_FOR_TEST:?}" "\$@" ;;
esac
exit 1
SH
    chmod +x "$FOREIGN_CASE/fakebin/lsof"
    show_cmd "$FOREIGN_CASE"; run_foreign_teardown rc; echo "teardown rc=$rc"
    [ "$rc" = 1 ]; fact $? "teardown exits 1"
    has "process $hpid holds $held open" "$FOREIGN_CASE/stderr"; fact $? "the refusal names holder pid $hpid and the held file"
    kill -0 "$hpid" 2>/dev/null; fact $? "the holder was not signalled"
    ! grep -q 'worktree unlock' "$FOREIGN_CASE/git-worktree.log"; fact $? "no unlock ran"
    assert_kept_locked
    teardown_fixture_stop "$hpid"
    ;;
  s3-squash-accept)
    case_dir=$(make_case content-shape-main-moved-on); CASE_DIR=$case_dir
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    land_on_origin_main "$case_dir" feature.txt hello
    land_on_origin_main "$case_dir" later.txt "main moved on"
    content_case_treehouse "$case_dir"
    echo "\$ (scratch home $case_dir) $TEARDOWN task-x1"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?; echo "teardown rc=$rc"
    [ "$rc" = 0 ]; fact $? "teardown exits 0"
    grep -m1 'landed by content' "$case_dir/stderr"
    has 'landed by content: every change of ' "$case_dir/stderr" && has ' is already in remotes/origin/main (' "$case_dir/stderr"; fact $? "the content proof and its compared base are printed"
    ! has 'fm-captain-hold.sh hold' "$case_dir/stderr"; fact $? "no hold command printed"
    [ ! -e "$case_dir/state/task-x1.meta" ]; fact $? "the task record is gone"
    ;;
  s3-squash-refuse)
    case_dir=$(make_case content-differs-unique); CASE_DIR=$case_dir
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    wt_commit_file "$case_dir" own.txt "only this copy holds this" "add unique work"
    land_on_origin_main "$case_dir" feature.txt hello
    land_on_origin_main "$case_dir" feature.txt "hello, then edited on main"
    content_case_treehouse "$case_dir"
    echo "\$ (scratch home $case_dir) $TEARDOWN task-x1"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?; echo "teardown rc=$rc"
    [ "$rc" != 0 ]; fact $? "teardown refuses"
    grep -m3 -E 'REFUSED|own.txt' "$case_dir/stderr"
    [ -e "$case_dir/state/task-x1.meta" ] && [ -f "$case_dir/wt/own.txt" ]; fact $? "the task record and the unique file stay"
    ;;
  s4-bundle-attended)
    make_bundle_copy_case bundle-call-unheld; case_dir=$NESTED_CASE; CASE_DIR=$case_dir
    head=$(git -C "$NESTED_COPY" rev-parse HEAD); hash=$(cut -f2 "$case_dir/data/task-x1/preservation-bundles.tsv")
    tasks-axi unhold task-x1 --file "$case_dir/data/backlog.md" >/dev/null || fact 1 "release the fixture hold"
    echo "\$ (scratch home $case_dir) FM_HOME=$case_dir/home $TEARDOWN task-x1"
    FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?; echo "teardown rc=$rc"
    [ "$rc" = 0 ]; fact $? "teardown exits 0"
    stored="$case_dir/data/task-x1/preserved-bundles/$hash.bundle"
    [ ! -e "$NESTED_COPY" ]; fact $? "the copy is gone"
    ! has 'fm-captain-hold.sh hold' "$case_dir/stderr"; fact $? "no hold command printed"
    has "preserved in bundle $stored, not landed" "$case_dir/data/backlog.md"; fact $? "the row closes with the bundle note"
    ! grep -q 'hold_kind: *captain' "$case_dir/data/backlog.md"; fact $? "no captain hold exists"
    git init -q --bare "$case_dir/restored.git" && git -C "$case_dir/restored.git" fetch -q "$stored" "$head:refs/heads/recovered" \
      && [ "$(git -C "$case_dir/restored.git" show recovered:work.txt)" = 'recoverable work' ]; fact $? "the stored bundle restores the work after the copy is gone"
    ;;
  s4-bundle-unattended)
    make_bundle_copy_case bundle-unattended-branch; case_dir=$NESTED_CASE; CASE_DIR=$case_dir
    echo "\$ (scratch home $case_dir) FM_HOME=$case_dir/home FM_SUPERVISION_ACTOR=branch $TEARDOWN task-x1"
    FM_HOME="$case_dir/home" FM_SUPERVISION_ACTOR=branch run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?; echo "teardown rc=$rc"
    [ "$rc" = 1 ]; fact $? "teardown exits 1"
    has 'recorded bundles require attended teardown' "$case_dir/stderr"; fact $? "the refusal names the attended-only rule"
    [ -e "$NESTED_COPY/work.txt" ] && [ -e "$case_dir/state/task-x1.meta" ]; fact $? "the copy and the task record stay"
    ;;
  s5-bundle-credit)
    make_locked_bundle_case bundle-credit-own own single; CASE_DIR=$FOREIGN_CASE
    show_cmd "$FOREIGN_CASE" FM_STUB_REQUIRE_CREDIT=1; run_foreign_teardown rc FM_STUB_REQUIRE_CREDIT=1; echo "teardown rc=$rc"
    [ "$rc" = 0 ]; fact $? "teardown exits 0"
    echo "driver argv: $(cat "$FOREIGN_CASE/closeout.log")"
    [ "$(wc -l < "$FOREIGN_CASE/closeout.log" | tr -d ' ')" = 1 ] && grep -Eq -- "--cleanup-worktree $FOREIGN_COPY --bundle-record [^ ]+ --execute-cleanup\$" "$FOREIGN_CASE/closeout.log"; fact $? "the driver ran once with exactly one --bundle-record credit"
    ! has ' --pr ' "$FOREIGN_CASE/closeout.log"; fact $? "no --pr beside the record"
    [ ! -e "$FOREIGN_COPY" ]; fact $? "the copy is gone"
    ;;
  s5-pr-credit)
    make_locked_bundle_case pr-credit own single; CASE_DIR=$FOREIGN_CASE
    head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
    git -C "$FOREIGN_COPY" push -q origin "HEAD:refs/pull/7/head"
    append_pr_meta_url "$FOREIGN_CASE"; add_gh_pr_merged_for_head "$FOREIGN_CASE" "$head"
    show_cmd "$FOREIGN_CASE" FM_STUB_REQUIRE_CREDIT=1; run_foreign_teardown rc FM_STUB_REQUIRE_CREDIT=1; echo "teardown rc=$rc"
    [ "$rc" = 0 ]; fact $? "teardown exits 0"
    echo "driver argv: $(cat "$FOREIGN_CASE/closeout.log")"
    [ "$(cat "$FOREIGN_CASE/closeout.log")" = "$FOREIGN_SLOT|--cleanup-worktree $FOREIGN_COPY --pr 7 --execute-cleanup" ]; fact $? "the driver ran once with exactly --pr 7"
    [ ! -e "$FOREIGN_CASE/closeout.record" ]; fact $? "no bundle record beside --pr"
    [ ! -e "$FOREIGN_COPY" ]; fact $? "the copy is gone"
    ;;
  s6-late-record-at-unlock)
    make_locked_bundle_case late-record-unlock own single; CASE_DIR=$FOREIGN_CASE
    add_late_mutation_hooks unlock
    head=$(git -C "$FOREIGN_COPY" rev-parse HEAD)
    IFS=$'\t' read -r bundle hash _ < "$FOREIGN_CASE/data/task-x1/preservation-bundles.tsv"
    others=$(git bundle list-heads "$bundle" | awk -v h="$head" '$1 != h {print $1}' | LC_ALL=C sort -u | paste -sd ' ' -)
    line=$(printf '%s\t%s\t%s' "$bundle" "$hash" "$others")
    printf 'printf %%s\\\\n %q > %q\n' "$line" "$FOREIGN_CASE/data/task-x1/preservation-bundles.tsv" > "$FOREIGN_CASE/mutate.sh"
    show_cmd "$FOREIGN_CASE"; run_foreign_teardown rc; echo "teardown rc=$rc"
    [ -e "$FOREIGN_CASE/git-protects-ran.done" ]; fact $? "the record was rewritten at the unlock"
    [ "$rc" = 1 ]; fact $? "teardown exits 1"
    grep -m2 -E 'not released|REFUSED' "$FOREIGN_CASE/stderr"
    ! grep -q 'worktree remove' "$FOREIGN_CASE/git-worktree.log"; fact $? "no worktree remove ran (final proof stopped it)"
    [ -e "$FOREIGN_COPY/.git" ] && git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | grep -q '^locked'; fact $? "the copy stays, locked again"
    ;;
  r8-foreign-cache-tabpath)
    # R8-1 on a CLI-reachable foreign direct release WITH default-list ignored
    # files: the held-copy rule does not apply to a copy whose path holds a tab
    # (teardown_foreign_copy_hold_applies), so this copy, holding a pre-existing
    # top-level .cache/run.bin, notes/ and .claude/.opencode files, goes to the
    # direct release. At the unlock .cache/run.bin changes (the R8-1 sequence).
    # No byte may be lost: the new bytes are preserved with SHA256SUMS lines and
    # the earlier preserve is kept, or the copy stays holding them.
    dead_launcher_pid
    make_foreign_copy_case foreign-cache-tab "$FOREIGN_DEAD_PID"; CASE_DIR=$FOREIGN_CASE
    reason=$(git -C "$FOREIGN_CASE/project" worktree list --porcelain | grep -A4 -F "worktree $FOREIGN_COPY" | sed -n 's/^locked //p')
    newcopy="$(dirname "$FOREIGN_COPY")/fc"$'\t'"tab"
    git -C "$FOREIGN_CASE/project" worktree unlock "$FOREIGN_COPY" \
      && git -C "$FOREIGN_CASE/project" worktree move "$FOREIGN_COPY" "$newcopy" \
      && git -C "$FOREIGN_CASE/project" worktree lock --reason "$reason" "$newcopy"; fact $? "the fixture copy moved to a tab path and relocked with '$reason'"
    FOREIGN_COPY=$newcopy
    seed_ignored "$FOREIGN_COPY"
    rm -f "$FOREIGN_CASE/vernant-python"
    add_unlock_mutation "$FOREIGN_CASE"
    printf 'printf "run-v2\\n" > %q\n' "$FOREIGN_COPY/.cache/run.bin" > "$FOREIGN_CASE/mutate.sh"
    show_cmd "$FOREIGN_CASE"; run_foreign_teardown rc; echo "teardown rc=$rc"
    [ -e "$FOREIGN_CASE/mutated" ]; fact $? "the .cache change was written at the unlock"
    grep -v '^●' "$FOREIGN_CASE/stderr" | grep -m3 -E 'REFUSED|released creation lock|not released|held foreign copy'
    grep -m2 'held foreign copy' "$FOREIGN_CASE/stdout"
    for f in .cache/run.bin notes/unique.dat .claude/channel-outbox/a.jsonl .opencode/state/log.json; do
      echo "preserves of $f: $(preserved_of "$FOREIGN_CASE" "$f" | paste -sd ';' -)"
    done
    if [ -e "$FOREIGN_COPY" ]; then
      echo "outcome: copy kept"
      [ "$(cat "$FOREIGN_COPY/.cache/run.bin")" = run-v2 ]; fact $? "copy kept: the new .cache bytes are still in the copy"
      ! grep -q 'worktree remove' "$FOREIGN_CASE/git-worktree.log"; fact $? "copy kept: no worktree remove ran"
    else
      echo "outcome: copy removed"
      grep -q 'worktree unlock' "$FOREIGN_CASE/git-worktree.log"; fact $? "the script ran a plain worktree unlock"
      ! grep -Eq 'worktree remove .*(^| )(-f|--force)( |$)' "$FOREIGN_CASE/git-worktree.log"; fact $? "no forced removal"
      preserved_of "$FOREIGN_CASE" .cache/run.bin | grep -qxF 'run-v2|sums=yes'; fact $? "copy removed: the new top-level .cache/run.bin bytes are preserved with their SHA256SUMS line"
      preserved_of "$FOREIGN_CASE" .cache/run.bin | grep -qxF 'run|sums=yes'; fact $? "copy removed: the earlier preserve with the old .cache bytes is kept"
      assert_wide_preserved notes/unique.dat:only_here .claude/channel-outbox/a.jsonl:one .opencode/state/log.json:evidence
    fi
    ;;
  *) echo "unknown scenario $SC"; exit 2 ;;
esac
echo "SCENARIO $SC: $([ "$BAD" = 0 ] && echo PASS || echo FAIL)"
exit "$BAD"
