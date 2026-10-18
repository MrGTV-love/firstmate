#!/usr/bin/env bash
# tests/fm-merge-prune.test.sh - bin/fm-merge-prune.sh and bin/fm-merge-prune-lib.sh.
#
# A merged task's pool copy must be pruned right after its PR merges, with no
# human step, and an unsafe copy must never be removed. This suite drives the
# real scripts against a fake pool in a temp directory: a throwaway
# TREEHOUSE_ROOT, bare origins, real git clones as pool copies, and a stub
# `treehouse` first on PATH that records its arguments and removes the fake
# directory. The real treehouse binary and the real ~/.treehouse are never
# touched; the stub proves only the CALL SHAPE the fallback makes
# (`treehouse destroy <copy> --include-leased --yes`), not how the real tool
# behaves.
#
# Sections:
#   1. arming and the due-time rules
#   2. orchestration against a stub teardown: transient refusals back off and then
#      succeed, one wake for a retained copy, nothing forced
#   3. the provable-scratch fallback against the fake pool: what is removed and
#      what is kept
#   4. mutation proof both ways: each safety proof, broken, makes a keep case
#      fail; each permission, broken, makes a removal case fail
#   5. the merge path end to end through bin/fm-pr-merge.sh and the real teardown
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_HOME
fm_git_identity fmtest fmtest@example.invalid
# tests/lib.sh turns arming off for every other suite; this one tests it.
export FM_MERGE_PRUNE=1

TMP_ROOT=$(fm_test_tmproot fm-merge-prune)
NOW=$(date +%s)
OLD=$((NOW - 7200))
PR=https://github.com/acme/widget/pull/7
BIN_DIR="$ROOT/bin"
WN=0
SCN_WHY=
WORKER_PIDS=()

cleanup_workers() {
  local pid
  for pid in ${WORKER_PIDS[@]+"${WORKER_PIDS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  WORKER_PIDS=()
}
trap cleanup_workers EXIT

# --- the fake pool ------------------------------------------------------------

# make_world builds one isolated world and sets W, HOME_DIR, STATE, DATA, POOL,
# ORIGIN and COPY (the task's pool copy: <pool root>/pool1/1/repo).
make_world() {
  local seed
  WN=$((WN + 1))
  W="$TMP_ROOT/w$WN"
  HOME_DIR="$W/home"
  STATE="$HOME_DIR/state"
  DATA="$HOME_DIR/data"
  POOL="$W/th"
  ORIGIN="$W/origin.git"
  COPY="$POOL/pool1/1/repo"
  mkdir -p "$STATE" "$DATA" "$HOME_DIR/config" "$POOL/pool1/1" "$W/bin" "$W/fakehome"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$HOME_DIR/.tasks.toml"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  seed="$W/seed"
  git clone -q "$ORIGIN" "$seed" 2>/dev/null
  git -C "$seed" checkout -q -b main
  printf '%s\n' '.venv/' 'node_modules/' '__pycache__/' '.DS_Store' '.claude/' '.tac/' '.mypy_cache/' '*.local' > "$seed/.gitignore"
  printf 'readme\n' > "$seed/README.md"
  git -C "$seed" add -A
  git -C "$seed" commit -q -m base
  git -C "$seed" push -q origin main
  rm -rf "$seed"
  git clone -q "$ORIGIN" "$COPY" 2>/dev/null
  git -C "$COPY" checkout -q -b fm/t1
  printf 'work\n' > "$COPY/work.txt"
  git -C "$COPY" add work.txt
  git -C "$COPY" commit -q -m "task work"
  git -C "$COPY" push -q origin fm/t1
  install_stubs
  mk_task t1 "$COPY"
}

install_stubs() {
  cat > "$W/bin/treehouse" <<'SH'
#!/usr/bin/env bash
# Stand-in for treehouse. It accepts exactly the call the reaper makes and
# removes the fake directory; every other call is logged and refused.
printf '%s\n' "$*" >> "$TH_LOG"
if [ "${1:-}" = destroy ] && [ "$#" -eq 4 ] && [ "$3" = --include-leased ] && [ "$4" = --yes ]; then
  case "$2" in
    "$TREEHOUSE_ROOT"/*/*/*) ;;
    *) echo "stub treehouse: $2 is outside the fake pool" >&2; exit 3 ;;
  esac
  [ ! -s "$TH_FAIL" ] || { echo "stub treehouse: destroy refused" >&2; exit 4; }
  rm -rf "$2"
  exit 0
fi
echo "stub treehouse: unexpected arguments: $*" >&2
exit 9
SH
  cat > "$W/bin/teardown-stub" <<'SH'
#!/usr/bin/env bash
# Stand-in for bin/fm-teardown.sh. Records how it was called, then behaves as
# the mode file says.
printf 'args=%s|admission=%s|prune=%s\n' "$*" "${FM_IDLE_REAP_ADMISSION:-}" "${FM_IDLE_REAP_MERGE_PRUNE:-}" >> "$STUB_LOG"
mode=$(cat "$STUB_MODE" 2>/dev/null || echo ok)
copy=$(sed -n 's/^worktree=//p' "$FM_STATE_OVERRIDE/$1.meta" 2>/dev/null)
done_ok() { rm -f "$FM_STATE_OVERRIDE/$1.meta"; exit 0; }
case "$mode" in
  ok) rm -f "$FM_STATE_OVERRIDE/$1.status"; done_ok "$1" ;;
  flaky)
    n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0)
    printf '%s\n' $((n + 1)) > "$STUB_COUNT"
    [ "$n" -ge 1 ] || exit 75
    done_ok "$1"
    ;;
  lock) exit 75 ;;
  lease) exit 6 ;;
  timeout) exit 124 ;;
  ineligible) echo "REFUSED: automatic reap ineligible: active: busy state busy" >&2; exit 1 ;;
  lifecycle) echo "error: another lifecycle action is already running for task $1; nothing was changed" >&2; exit 1 ;;
  pipeline) echo "REFUSED: no-mistakes run for $1 is still parked after axi abort" >&2; exit 1 ;;
  false-positive)
    if [ -e "$copy" ]; then
      echo "REFUSED: closeout driver: exact tree not covered by the merged PR" >&2
      exit 1
    fi
    done_ok "$1"
    ;;
  refuse-always) echo "REFUSED: $1 has work that has not landed" >&2; exit 1 ;;
esac
SH
  cat > "$W/bin/control-stub" <<'SH'
#!/usr/bin/env bash
# Stand-in for bin/fm-control.sh: stops the finished worker's session.
printf '%s\n' "$*" >> "$CONTROL_LOG"
if [ -s "$WORKER_PID_FILE" ]; then
  kill "$(cat "$WORKER_PID_FILE")" 2>/dev/null || true
fi
exit 0
SH
  chmod +x "$W/bin/treehouse" "$W/bin/teardown-stub" "$W/bin/control-stub"
  : > "$W/th.log"; : > "$W/stub.log"; : > "$W/control.log"; : > "$W/th.fail"
  printf 'false-positive\n' > "$W/stub.mode"
}

# mk_task <id> <copy>: a finished ship whose merge was verified, a day old.
mk_task() {
  local id=$1 copy=$2
  fm_write_meta "$STATE/$id.meta" "window=w:$id" "kind=ship" "harness=claude" "backend=herdr" \
    "worktree=$copy" "pr=$PR"
  printf 'done [at=%s]: PR %s checks green\n' "$OLD" "$PR" > "$STATE/$id.status"
  printf 'g1.1.1\n' > "$STATE/$id.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$STATE/$id.busy-state"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n7\n' > "$STATE/$id.pr-poll-merge-notified"
  chmod 0600 "$STATE/$id.pr-poll-merge-notified"
  fm_touch_epoch "$OLD" "$STATE/$id.pr-poll-merge-notified"
}

# prune <args...>: run the script under test (BIN_DIR) inside the current world.
prune() {
  HOME="$W/fakehome" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    TREEHOUSE_ROOT="$POOL" PATH="$W/bin:$PATH" \
    TH_LOG="$W/th.log" TH_FAIL="$W/th.fail" STUB_LOG="$W/stub.log" STUB_MODE="$W/stub.mode" \
    STUB_COUNT="$W/stub.count" CONTROL_LOG="$W/control.log" WORKER_PID_FILE="$W/worker.pid" \
    FM_MERGE_PRUNE_TEARDOWN_BIN="$W/bin/teardown-stub" FM_MERGE_PRUNE_CONTROL_BIN="$W/bin/control-stub" \
    FM_MERGE_PRUNE_EXIT_WAIT="${EXIT_WAIT:-0}" \
    "$BIN_DIR/fm-merge-prune.sh" "$@"
}

rec_field() {  # <id> <key>
  sed -n "s/^$2=//p" "$STATE/$1.merge-prune" 2>/dev/null | sed -n 1p
}

set_rec() {  # <id> <key> <value>
  local tmp="$STATE/.rec.tmp"
  sed "s/^$2=.*/$2=$3/" "$STATE/$1.merge-prune" > "$tmp" && mv -f "$tmp" "$STATE/$1.merge-prune"
}

wake_count() {
  local n
  n=$(grep -c 'merge-prune:t1' "$STATE/.wake-queue" 2>/dev/null) || n=0
  printf '%s' "$n"
}

stub_calls() { wc -l < "$W/stub.log" | tr -d ' '; }
destroy_calls() { grep -c '^destroy ' "$W/th.log" 2>/dev/null || true; }

# A process that works inside a directory, like a finished worker's session or a
# stray editor. The pid is recorded so the stub control can stop the worker.
start_inside() {  # <dir> <pidfile-or-empty>
  local pid
  (cd "$1" && exec sleep 300) &
  pid=$!
  WORKER_PIDS+=("$pid")
  [ -z "$2" ] || printf '%s\n' "$pid" > "$2"
}

why() { SCN_WHY=$1; return 1; }

# go: arm the task (once) and make one forced attempt, as the merge path does.
# go: arm the task (once) and make one forced attempt, as the merge path does.
go() {
  [ -e "$STATE/t1.merge-prune" ] || prune arm t1 >/dev/null 2>&1
  prune run t1 --now >/dev/null 2>&1
}

# --- scenarios: each returns 0 when the contract holds, else sets SCN_WHY --------
# A scenario builds its own world and runs against BIN_DIR, so the mutation
# section can run the very same scenario against a deliberately broken copy.

scn_scratch_copy_is_removed() {
  local sums f
  make_world
  mkdir -p "$COPY/.venv/lib" "$COPY/node_modules/p" "$COPY/__pycache__" "$COPY/.mypy_cache" \
    "$COPY/.claude/bug-evidence" "$COPY/.claude/channel-outbox" "$COPY/.tac/tmp" "$COPY/.tac/uv-cache"
  printf x > "$COPY/.venv/lib/x.py"; printf x > "$COPY/node_modules/p/i.js"; printf x > "$COPY/__pycache__/a.pyc"
  printf x > "$COPY/.mypy_cache/m"; printf x > "$COPY/.DS_Store"; printf x > "$COPY/.tac/tmp/t"; printf x > "$COPY/.tac/uv-cache/c"
  printf '{}' > "$COPY/.claude/settings.local.json"
  printf 'evidence-one\n' > "$COPY/.claude/bug-evidence/ev1.json"
  printf 'rate-one\n' > "$COPY/.claude/channel-outbox/rate.json"
  ln -s /nonexistent "$COPY/.venv/link"
  start_inside "$COPY" "$W/worker.pid"
  EXIT_WAIT=3 go || why "run exited nonzero" || return 1
  [ ! -e "$COPY" ] || why "the clean scratch copy was not removed" || return 1
  [ "$(destroy_calls)" = 1 ] || why "treehouse destroy was called $(destroy_calls) times" || return 1
  [ "$(sed -n 1p "$W/th.log")" = "destroy $COPY --include-leased --yes" ] \
    || why "treehouse was called as: $(cat "$W/th.log")" || return 1
  if grep -Eq -- '--force|--include-unlanded|--include-in-use' "$W/th.log" "$W/stub.log"; then
    why "something was forced" || return 1
  fi
  [ ! -e "$STATE/t1.merge-prune" ] || why "the prune record outlived the reap" || return 1
  grep -q 'reaped' "$DATA/t1/merge-prune.log" || why "the log does not say reaped" || return 1
  grep -q 'merge-prune reaped copy' "$STATE/t1.status" || why "the status does not say reaped" || return 1
  [ "$(wake_count)" = 0 ] || why "a reaped copy raised a wake" || return 1
  [ -s "$W/control.log" ] && [ -z "$(grep -vx 't1 exit' "$W/control.log")" ] || why "the finished worker was not stopped by 't1 exit': $(cat "$W/control.log")" || return 1
  f=$(find "$DATA/t1/merge-prune-preserved" -path '*/root/.claude/bug-evidence/ev1.json' 2>/dev/null | sed -n 1p)
  [ -n "$f" ] && [ "$(cat "$f")" = evidence-one ] || why "the bug-evidence record was not preserved" || return 1
  f=$(find "$DATA/t1/merge-prune-preserved" -path '*/root/.claude/channel-outbox/rate.json' 2>/dev/null | sed -n 1p)
  [ -n "$f" ] && [ "$(cat "$f")" = rate-one ] || why "the channel-outbox rate file was not preserved" || return 1
  sums=$(find "$DATA/t1/merge-prune-preserved" -name SHA256SUMS | sed -n 1p)
  [ -n "$sums" ] && [ "$(wc -l < "$sums" | tr -d ' ')" = 2 ] || why "the checksum manifest does not list both records" || return 1
  (cd "$(dirname "$sums")" && shasum -a 256 -c SHA256SUMS >/dev/null 2>&1) || why "the checksums do not verify" || return 1
  [ "$(stub_calls)" = 2 ] || why "teardown ran $(stub_calls) times, want refusal then completion" || return 1
  grep -q '^args=t1|admission=1|prune=1$' "$W/stub.log" || why "teardown was not called as 't1' with the admission markers: $(cat "$W/stub.log")" || return 1
  return 0
}

scn_changed_file_is_kept() {
  make_world
  printf 'edited\n' >> "$COPY/README.md"
  go
  [ -e "$COPY/README.md" ] || why "the copy with a changed file was removed" || return 1
  [ "$(destroy_calls)" = 0 ] || why "destroy was called on a copy with a changed file" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'changed or untracked' || why "the wake does not name the copy and the reason" || return 1
  go; go
  [ "$(wake_count)" = 1 ] || why "repeat attempts raised more wakes: $(wake_count)" || return 1
  [ "$(rec_field t1 state)" = retained ] || why "the record is not retained" || return 1
  grep -q 'merge-prune retained' "$STATE/t1.status" || why "the status does not say retained" || return 1
  # The cleanup's own note must not hide the worker's `done` from later attempts.
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" "$BIN_DIR/fm-idle-session-reap.sh" scan \
    | grep -q "^reap	t1	" || why "the cleanup's own status note made the finished worker look unfinished" || return 1
  return 0
}

scn_untracked_file_is_kept() {
  make_world
  printf 'mine\n' > "$COPY/new-file.txt"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy with an untracked file was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

scn_unpushed_commit_is_kept() {
  make_world
  printf 'later\n' > "$COPY/later.txt"
  git -C "$COPY" add later.txt
  git -C "$COPY" commit -q -m "unpushed"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy with an unpushed commit was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'commit(s) on no remote' || why "the wake does not name the copy and the unpushed commit" || return 1
  return 0
}

scn_stash_is_kept() {
  make_world
  printf 'wip\n' >> "$COPY/README.md"
  git -C "$COPY" stash -q
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy holding a stash entry was removed" || return 1
  return 0
}

scn_live_process_is_kept() {
  make_world
  start_inside "$COPY" ""
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "the copy with a live process inside was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'process(es) inside' || why "the wake does not name the copy and the process" || return 1
  return 0
}

# A nested copy: a second clone inside the task's copy, under an ignored tree.
make_nested() {  # <rel>
  git clone -q "$ORIGIN" "$COPY/$1" 2>/dev/null
}

scn_nested_unpushed_commit_keeps_the_slot() {
  make_world
  make_nested .claude/worktrees/n1
  printf 'orphan\n' > "$COPY/.claude/worktrees/n1/orphan.txt"
  git -C "$COPY/.claude/worktrees/n1" add orphan.txt
  git -C "$COPY/.claude/worktrees/n1" commit -q -m "unpushed in nested"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "an unpushed nested commit did not keep the slot" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY/.claude/worktrees/n1" "$STATE/.wake-queue" | grep -q 'commit(s) on no remote' || why "the wake does not name the nested copy" || return 1
  return 0
}

scn_clean_nested_copy_goes_with_the_slot() {
  make_world
  make_nested .claude/worktrees/n1
  mkdir -p "$COPY/.claude/worktrees/n1/node_modules" "$COPY/.claude/worktrees/n1/.claude/bug-evidence"
  printf x > "$COPY/.claude/worktrees/n1/node_modules/x"
  printf 'nested-evidence\n' > "$COPY/.claude/worktrees/n1/.claude/bug-evidence/e.json"
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a clean pushed nested copy kept the slot: $(rec_field t1 reason)" || return 1
  find "$DATA/t1/merge-prune-preserved" -path '*/nested-.claude__worktrees__n1/.claude/bug-evidence/e.json' | grep -q . \
    || why "the nested copy's preserve-list record was not preserved" || return 1
  return 0
}

scn_unique_ignored_file_is_kept() {
  make_world
  printf 'only here\n' > "$COPY/precious.local"
  go
  [ -e "$COPY/precious.local" ] && [ "$(destroy_calls)" = 0 ] || why "a unique ignored file was removed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'precious.local' || why "the wake does not name the unique file" || return 1
  return 0
}

scn_non_pool_copy_is_kept() {
  make_world
  git clone -q "$ORIGIN" "$W/outside" 2>/dev/null
  git -C "$W/outside" checkout -q -b fm/t1 origin/fm/t1
  mk_task t1 "$W/outside"
  go
  [ -e "$W/outside" ] && [ "$(destroy_calls)" = 0 ] || why "a copy outside the pool was destroyed" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

# A squash merge leaves the task's commits on no remote branch; the merged
# PR's head is the proof they landed.
scn_pr_head_proves_a_squash_merged_commit() {
  make_world
  printf 'last\n' > "$COPY/last.txt"
  git -C "$COPY" add last.txt
  git -C "$COPY" commit -q -m "landed through the PR head only"
  git -C "$COPY" push -q origin HEAD:refs/pull/7/head
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a commit proved landed by the PR head kept the copy: $(rec_field t1 reason)" || return 1
  return 0
}

scn_pipeline_refusal_never_falls_back() {
  make_world
  printf 'pipeline\n' > "$W/stub.mode"
  go
  [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || why "a live-pipeline refusal was overridden by the fallback" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

scn_destroy_failure_keeps_the_copy_with_one_wake() {
  make_world
  printf 'locked\n' > "$W/th.fail"
  go
  [ -e "$COPY" ] || why "the stub refused destroy but the copy is gone" || return 1
  [ "$(wake_count)" = 1 ] || why "want exactly one wake, got $(wake_count)" || return 1
  return 0
}

# The 2026-10-18 case where an old retained copy is cleaned later: the retry is
# silent and succeeds.
scn_retained_copy_is_reaped_when_the_cause_clears() {
  make_world
  printf 'edited\n' >> "$COPY/README.md"
  go
  [ "$(wake_count)" = 1 ] || why "want one wake while retained" || return 1
  git -C "$COPY" checkout -q -- README.md
  set_rec t1 next_at 0
  prune run t1 >/dev/null 2>&1
  [ ! -e "$COPY" ] && [ ! -e "$STATE/t1.merge-prune" ] || why "the cleared copy was not reaped on the quiet retry" || return 1
  [ "$(wake_count)" = 1 ] || why "the quiet retry raised another wake" || return 1
  return 0
}

run_scenario() {  # <name>
  SCN_WHY=
  cleanup_workers
  if "$1"; then cleanup_workers; return 0; fi
  cleanup_workers
  return 1
}

assert_scenario() {  # <name> <label>
  run_scenario "$1" || fail "$2: $SCN_WHY"$'\n'"prune log: $(cat "$DATA/t1/merge-prune.log" 2>/dev/null)"$'\n'"record: $(cat "$STATE/t1.merge-prune" 2>/dev/null)"$'\n'"treehouse: $(cat "$W/th.log" 2>/dev/null)"
  pass "$2"
}

scn_search_indexer_does_not_keep_the_copy() {
  local real_ps pid
  make_world
  real_ps=$(command -v ps)
  start_inside "$COPY" ""
  pid=${WORKER_PIDS[$((${#WORKER_PIDS[@]} - 1))]}
  # The copy reports a Spotlight worker, named as macOS names it, as its only
  # process; ps answers for that pid the way macOS does.
  cat > "$W/bin/lsof" <<SH
#!/usr/bin/env bash
printf '%s\n' $pid
SH
  cat > "$W/bin/ps" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"-o comm= -p $pid") echo /System/Library/Frameworks/CoreServices.framework/Support/mdworker_shared ;;
  *) exec $real_ps "\$@" ;;
esac
SH
  chmod +x "$W/bin/lsof" "$W/bin/ps"
  go
  [ ! -e "$COPY" ] && [ "$(destroy_calls)" = 1 ] || why "a search indexer's read kept the copy: $(rec_field t1 reason)" || return 1
  [ "$(wake_count)" = 0 ] || why "an indexer-only read raised a wake" || return 1
  return 0
}

# --- 1. arming ----------------------------------------------------------------

test_arm_needs_a_verified_merge() {
  local out
  make_world
  out=$(prune arm t1 2>&1) || fail "arm failed: $out"
  [ -f "$STATE/t1.merge-prune" ] || fail "a verified merge did not arm the prune"
  [ "$(rec_field t1 pr)" = "$PR" ] && [ "$(rec_field t1 state)" = pending ] || fail "armed record is wrong: $(cat "$STATE/t1.merge-prune")"
  set_rec t1 attempts 5
  prune arm t1 >/dev/null 2>&1
  [ "$(rec_field t1 attempts)" = 5 ] || fail "arming twice reset the record"
  rm -f "$STATE/t1.merge-prune" "$STATE/t1.pr-poll-merge-notified"
  prune arm t1 >/dev/null 2>&1
  [ ! -e "$STATE/t1.merge-prune" ] || fail "a PR with no merge marker armed the prune"
  mk_task t1 "$COPY"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n99\n' > "$STATE/t1.pr-poll-merge-notified"
  prune arm t1 >/dev/null 2>&1
  [ ! -e "$STATE/t1.merge-prune" ] || fail "a marker for a different PR armed the prune"
  pass "only a verified merge of the recorded PR arms the prune, and arming is idempotent"
}

test_arm_skips_tasks_it_does_not_own() {
  make_world
  printf 'kind=scout\n' >> "$STATE/t1.meta"
  mk_task t2 "$COPY"; printf 'remote_host=far\n' >> "$STATE/t2.meta"
  mk_task t3 "$COPY"; sed -i.bak 's/^kind=ship/kind=secondmate/' "$STATE/t3.meta"
  prune arm t2 >/dev/null 2>&1; prune arm t3 >/dev/null 2>&1
  [ ! -e "$STATE/t2.merge-prune" ] || fail "a remote task was armed"
  [ ! -e "$STATE/t3.merge-prune" ] || fail "a secondmate was armed"
  mk_task t4 "$COPY"
  FM_MERGE_PRUNE=0 prune arm t4 >/dev/null 2>&1
  [ ! -e "$STATE/t4.merge-prune" ] || fail "FM_MERGE_PRUNE=0 still armed"
  prune arm 'bad id' >/dev/null 2>&1 && fail "an invalid id was accepted"
  pass "remote tasks, secondmates and a disabled setting are never armed"
}

test_run_not_due_does_nothing() {
  make_world
  prune arm t1 >/dev/null 2>&1
  set_rec t1 next_at $((NOW + 600))
  prune run t1 >/dev/null 2>&1
  [ "$(stub_calls)" = 0 ] || fail "a record that is not due was attempted"
  prune run t1 --now >/dev/null 2>&1
  [ "$(stub_calls)" -ge 1 ] || fail "--now did not attempt"
  pass "a record that is not due waits, and --now overrides"
}

test_missing_task_or_changed_pr_drops_the_record() {
  make_world
  prune arm t1 >/dev/null 2>&1
  rm -f "$STATE/t1.meta"
  prune run t1 --now >/dev/null 2>&1
  [ ! -e "$STATE/t1.merge-prune" ] && [ "$(stub_calls)" = 0 ] || fail "a record for a vanished task was kept or attempted"
  mk_task t1 "$COPY"
  prune arm t1 >/dev/null 2>&1
  sed -i.bak 's#^pr=.*#pr=https://github.com/acme/widget/pull/8#' "$STATE/t1.meta"
  prune run t1 --now >/dev/null 2>&1
  [ ! -e "$STATE/t1.merge-prune" ] && [ "$(stub_calls)" = 0 ] || fail "a record for a different PR was kept or attempted"
  pass "a vanished task or a different PR drops the record without calling teardown"
}

# --- 2. orchestration against a stub teardown -----------------------------------

test_merge_cleanup_runs_teardown_unforced() {
  make_world
  printf 'ok\n' > "$W/stub.mode"
  prune arm t1 >/dev/null 2>&1
  prune run t1 --now >/dev/null 2>&1
  [ "$(stub_calls)" = 1 ] || fail "teardown ran $(stub_calls) times"
  [ "$(cat "$W/stub.log")" = "args=t1|admission=1|prune=1" ] || fail "teardown was not asked plainly: $(cat "$W/stub.log")"
  [ ! -e "$STATE/t1.merge-prune" ] || fail "the record outlived a completed teardown"
  grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the log does not say reaped"
  [ "$(destroy_calls)" = 0 ] || fail "a completed teardown needed no fallback"
  pass "a verified merge asks teardown once, never forced, and logs reaped"
}

test_transient_refusals_back_off_silently_then_succeed() {
  local mode delay
  for mode in lock lease timeout ineligible lifecycle; do
    make_world
    printf '%s\n' "$mode" > "$W/stub.mode"
    prune arm t1 >/dev/null 2>&1
    prune run t1 --now >/dev/null 2>&1
    [ -e "$COPY" ] && [ "$(destroy_calls)" = 0 ] || fail "$mode: a transient refusal touched the copy"
    [ "$(rec_field t1 state)" = pending ] && [ "$(rec_field t1 attempts)" = 1 ] || fail "$mode: not a pending first attempt: $(cat "$STATE/t1.merge-prune")"
    delay=$(( $(rec_field t1 next_at) - $(date +%s) ))
    [ "$delay" -ge 50 ] && [ "$delay" -le 70 ] || fail "$mode: first backoff is ${delay}s, want about 60s"
    [ "$(wake_count)" = 0 ] || fail "$mode: a transient refusal raised a wake"
    prune run t1 >/dev/null 2>&1
    [ "$(stub_calls)" = 1 ] || fail "$mode: retried before the backoff elapsed"
    printf 'ok\n' > "$W/stub.mode"
    set_rec t1 next_at 0
    prune run t1 >/dev/null 2>&1
    [ ! -e "$STATE/t1.merge-prune" ] && [ "$(stub_calls)" = 2 ] || fail "$mode: the retry did not succeed"
    grep -q 'reaped' "$DATA/t1/merge-prune.log" || fail "$mode: the retry did not log reaped"
  done
  pass "co-tenant, lease, timeout, not-ready and lifecycle refusals retry on later ticks and then succeed, silently"
}

test_flaky_contention_retries_through_the_sweep() {
  local now
  make_world
  printf 'flaky\n' > "$W/stub.mode"
  prune arm t1 >/dev/null 2>&1
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 1 ] && [ -e "$STATE/t1.merge-prune" ] || fail "the first sweep did not meet the contention"
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 1 ] || fail "a sweep ran a record that was not due"
  set_rec t1 next_at 0
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 2 ] && [ ! -e "$STATE/t1.merge-prune" ] || fail "the second due sweep did not finish the prune"
  now=$(date +%s)
  [ "$(cat "$STATE/.merge-prune-next")" -le $((now + 301)) ] || fail "the next-sweep hint is unbounded"
  pass "the sweep retries a contended task on a later tick and finishes it"
}

test_backoff_doubles_to_a_cap_and_wakes_once() {
  local want got
  make_world
  printf 'lock\n' > "$W/stub.mode"
  prune arm t1 >/dev/null 2>&1
  for want in 60 120 240 480; do
    prune run t1 --now >/dev/null 2>&1
    got=$(( $(rec_field t1 next_at) - $(date +%s) ))
    [ "$got" -ge $((want - 10)) ] && [ "$got" -le $((want + 10)) ] || fail "backoff is ${got}s, want about ${want}s"
  done
  set_rec t1 attempts 10
  prune run t1 --now >/dev/null 2>&1
  got=$(( $(rec_field t1 next_at) - $(date +%s) ))
  [ "$got" -ge 3590 ] && [ "$got" -le 3610 ] || fail "backoff is ${got}s, want the 3600s cap"
  set_rec t1 attempts 22
  prune run t1 --now >/dev/null 2>&1
  [ "$(wake_count)" = 0 ] || fail "a wake before the attempt limit"
  prune run t1 --now >/dev/null 2>&1
  [ "$(wake_count)" = 1 ] || fail "no wake at the attempt limit"
  prune run t1 --now >/dev/null 2>&1
  [ "$(wake_count)" = 1 ] || fail "more than one wake after the limit"
  pass "backoff doubles from 60s to a 3600s cap and one wake follows the 24th attempt"
}

test_sweep_runs_only_due_records_and_at_most_three() {
  local id
  make_world
  printf 'ok\n' > "$W/stub.mode"
  for id in a1 a2 a3 a4 a5; do
    mk_task "$id" "$W/none-$id"
    prune arm "$id" >/dev/null 2>&1
  done
  set_rec a5 next_at $((NOW + 9999))
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 3 ] || fail "a sweep ran $(stub_calls) teardowns, want 3"
  prune sweep >/dev/null 2>&1
  [ "$(stub_calls)" = 4 ] || fail "the next sweep ran $(( $(stub_calls) - 3 )) teardowns, want the 1 due record left"
  [ -e "$STATE/a5.merge-prune" ] || fail "a record that is not due was run"
  pass "a sweep runs only due records, at most 3 per pass"
}

# --- 3. the fallback against the fake pool ---------------------------------------

test_fallback_removes_a_clean_pushed_unused_scratch_copy() { assert_scenario scn_scratch_copy_is_removed "a copy refused by a false positive but clean, pushed and unused is removed, preserve-list files copied with checksums first"; }
test_fallback_keeps_a_changed_file() { assert_scenario scn_changed_file_is_kept "a changed tracked file keeps the copy with exactly one wake naming it"; }
test_fallback_keeps_an_untracked_file() { assert_scenario scn_untracked_file_is_kept "an untracked file keeps the copy with exactly one wake"; }
test_fallback_keeps_an_unpushed_commit() { assert_scenario scn_unpushed_commit_is_kept "an unpushed commit keeps the copy with exactly one wake naming it"; }
test_fallback_keeps_a_stash() { assert_scenario scn_stash_is_kept "a stash entry keeps the copy"; }
test_fallback_keeps_a_live_process() { assert_scenario scn_live_process_is_kept "a live process inside keeps the copy with exactly one wake"; }
test_fallback_nested_unpushed_commit_keeps_the_slot() { assert_scenario scn_nested_unpushed_commit_keeps_the_slot "an unpushed commit in a NESTED copy keeps the whole slot"; }
test_fallback_removes_a_clean_nested_copy_with_the_slot() { assert_scenario scn_clean_nested_copy_goes_with_the_slot "a clean pushed orphan nested copy goes with its slot, its preserve-list records preserved"; }
test_fallback_keeps_unique_ignored_files() { assert_scenario scn_unique_ignored_file_is_kept "a unique ignored file outside the preserve list and the scratch patterns keeps the copy"; }
test_fallback_keeps_a_non_pool_copy() { assert_scenario scn_non_pool_copy_is_kept "a copy outside the pool is never destroyed"; }
test_fallback_accepts_the_merged_pr_head() { assert_scenario scn_pr_head_proves_a_squash_merged_commit "a commit proved landed by the merged PR head does not keep the copy"; }
test_fallback_ignores_a_search_indexer() { assert_scenario scn_search_indexer_does_not_keep_the_copy "a system search indexer (Spotlight) reading the copy does not keep it; any other process does"; }
test_fallback_never_overrides_a_live_pipeline_refusal() { assert_scenario scn_pipeline_refusal_never_falls_back "a refusal about a live pipeline is retained, never overridden"; }
test_fallback_destroy_failure_keeps_the_copy() { assert_scenario scn_destroy_failure_keeps_the_copy_with_one_wake "a destroy the tool refuses keeps the copy with one wake"; }
test_retained_copy_is_reaped_quietly_when_the_cause_clears() { assert_scenario scn_retained_copy_is_reaped_when_the_cause_clears "a retained copy is reaped on the quiet retry once its cause clears"; }

# --- 4. mutation proof, both ways ------------------------------------------------
#
# Each mutation edits a COPY of bin/ so that exactly one criterion is broken.
# Weakening a safety proof must make the matching keep scenario fail (the copy
# would be destroyed). Tightening a permission must make the matching removal
# scenario fail (a provably clean copy would be kept). A mutation whose target
# text is not found exactly once is itself a failure, so a mutation can never
# silently do nothing.

mutate() {  # <name> <file-in-bin> <old> <new> -> echoes the mutated bin dir
  local dir="$TMP_ROOT/mut-$1"
  rm -rf "$dir"
  mkdir -p "$dir"
  cp -R "$ROOT/bin" "$dir/bin"
  python3 - "$dir/bin/$2" "$3" "$4" <<'PY' || return 1
import sys
path, old, new = sys.argv[1:4]
text = open(path).read()
if text.count(old) != 1:
    sys.exit('mutation target found %d times: %s' % (text.count(old), old))
open(path, 'w').write(text.replace(old, new))
PY
  printf '%s\n' "$dir/bin"
}

expect_caught() {  # <name> <file> <old> <new> <scenario> <what the mutation breaks>
  local dir
  dir=$(mutate "$1" "$2" "$3" "$4") || fail "mutation $1 could not be applied"
  BIN_DIR=$dir
  if run_scenario "$5"; then
    BIN_DIR="$ROOT/bin"
    fail "mutation $1 ($6) was NOT caught by $5"
  fi
  BIN_DIR="$ROOT/bin"
}

test_unsafe_mutations_are_caught() {
  local lib=fm-merge-prune-lib.sh orch=fm-merge-prune.sh
  expect_caught no-dirty-check $lib '  if [ -n "$dirty" ]; then' '  if false; then' scn_changed_file_is_kept "changed-file proof"
  expect_caught no-untracked-check $lib '  if [ -n "$dirty" ]; then' '  if false; then' scn_untracked_file_is_kept "untracked-file proof"
  expect_caught no-unpushed-check $lib '  if [ "$unpushed" != 0 ]; then' '  if false; then' scn_unpushed_commit_is_kept "unpushed-commit proof"
  expect_caught no-stash-check $lib '  if [ "$stashes" != 0 ]; then' '  if false; then' scn_stash_is_kept "stash proof"
  expect_caught no-process-check $lib "  out=\$(printf '%s\\n' \"\$out\" | sort -u | tr '\\n' ' ')" '  out=' scn_live_process_is_kept "live-process proof"

  expect_caught no-nested-check $lib '    FM_MP_NESTED+=("$dir")' '    :' scn_nested_unpushed_commit_keeps_the_slot "nested-copy proof"
  expect_caught unique-is-scratch $lib '  if fm_mp_scratch_name "$name"; then' '  if true; then' scn_unique_ignored_file_is_kept "unique-ignored-file proof"
  expect_caught no-pool-check $lib '    "$root"/*/*/*) return 0 ;;' '    *) return 0 ;;' scn_non_pool_copy_is_kept "pool-copy proof"
  expect_caught pipeline-not-barred $orch '    *"no-mistakes run"*|*"held for the captain"*|*"leaked process"*) return 0 ;;' '    *"never-matches"*) return 0 ;;' scn_pipeline_refusal_never_falls_back "live-pipeline bar"
  expect_caught note-hides-done fm-idle-reap-lib.sh '    note*": merge-prune "*) ;;' '    "never"*) ;;' scn_changed_file_is_kept "cleanup-note tolerance"
  expect_caught wake-every-time $orch '  if [ "$R_WAKE" = 0 ]; then' '  if true; then' scn_changed_file_is_kept "one-wake rule"
  pass "mutation proof (unsafe direction): breaking any safety proof makes its keep case fail"
}

test_over_strict_mutations_are_caught() {
  local lib=fm-merge-prune-lib.sh
  expect_caught no-scratch-names $lib '  if fm_mp_scratch_name "$name"; then' '  if false; then' scn_scratch_copy_is_removed "scratch patterns"
  expect_caught no-claude-scratch $lib '    .claude/*|.opencode|.opencode/*) return 0 ;;' '    .opencode|.opencode/*) return 0 ;;' scn_scratch_copy_is_removed ".claude scratch rule"
  expect_caught no-tac-scratch $lib '    .tac/tmp|.tac/tmp/*|.tac/uv-cache|.tac/uv-cache/*) return 0 ;;' '    .tac/NEVER) return 0 ;;' scn_scratch_copy_is_removed ".tac scratch rule"
  expect_caught no-preserve-list $lib '    .claude/bug-evidence|.claude/bug-evidence/*|.claude/channel-outbox|.claude/channel-outbox/*)' '    .claude/NEVER-MATCHES)' scn_scratch_copy_is_removed "preserve list"
  expect_caught no-checksums $lib '      shasum -a 256 -- "$file" || exit 1' '      :' scn_scratch_copy_is_removed "checksum manifest"
  expect_caught indexer-counts-as-use $lib '    fm_mp_indexer_pid "$pid" || kept="${kept:+$kept }$pid"' '    kept="${kept:+$kept }$pid"' scn_search_indexer_does_not_keep_the_copy "search-indexer exemption"
  expect_caught pr-head-ignored $lib '  [ -z "$prsha" ] || extra=("$prsha")' '  extra=()' scn_pr_head_proves_a_squash_merged_commit "merged-PR-head proof"
  expect_caught nested-never-passes fm-merge-prune.sh '    fm_mp_prove_git "$n" "" || { record_verdict "$real"; return 1; }' '    false || { record_verdict "$real"; return 1; }' scn_clean_nested_copy_goes_with_the_slot "nested-copy removal"
  pass "mutation proof (over-strict direction): tightening any permission makes its removal case fail"
}

# --- 5. end to end through the real teardown --------------------------------------
#
# The fake pool, the real bin/fm-teardown.sh, and the real prune scripts. Only
# the outside world is stubbed: tmux, gh-axi/gh (the merged PR), no-mistakes and
# treehouse (whose `return` and `destroy` both remove the fake copy).

# make_e2e_world: make_world plus a project clone, the stubs real teardown calls,
# and a pool lease record, so teardown can run against the pool copy.
make_e2e_world() {
  local head
  make_world
  git clone -q "$ORIGIN" "$W/project" 2>/dev/null
  git -C "$W/project" remote set-head origin main 2>/dev/null || true
  mkdir -p "$W/code-root" "$W/primary-home"
  ln -s "$ROOT/bin" "$W/code-root/bin"
  cat > "$W/bin/treehouse" <<'SH'
#!/usr/bin/env bash
# Fake pool: `return` and the reaper's `destroy` both remove the fake copy.
printf '%s\n' "$*" >> "$TH_LOG"
case "${1:-}" in
  return) for a in "$@"; do wt=$a; done; rm -rf "$wt"; exit 0 ;;
  destroy)
    [ "$#" -eq 4 ] && [ "$3" = --include-leased ] && [ "$4" = --yes ] || { echo "stub treehouse: unexpected arguments: $*" >&2; exit 9; }
    case "$2" in "$TREEHOUSE_ROOT"/*/*/*) ;; *) echo "stub treehouse: outside the fake pool" >&2; exit 3 ;; esac
    rm -rf "$2"; exit 0 ;;
esac
exit 0
SH
  # The real teardown, with every call it is given recorded.
  cat > "$W/bin/teardown-real" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
# A case may make teardown refuse the way the 2026-10-18 closeout driver did, so
# the fallback alone decides.
if [ -e "$REFUSE_FLAG" ]; then
  echo "REFUSED: closeout driver: exact tree not covered by the merged PR" >&2
  exit 1
fi
exec "$ROOT/bin/fm-teardown.sh" "$@"
SH
  chmod +x "$W/bin/teardown-real"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/tmux"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/no-mistakes"
  head=$(git -C "$COPY" rev-parse HEAD)
  cat > "$W/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged"; exit 0 ;;
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"'; exit 0 ;;
esac
exit 0
SH
  cat > "$W/bin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,mergeCommit"*) printf '%s\t%s\t%s\n' MERGED '$head' ''; exit 0 ;;
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED '$head' 'https://github.com/acme/widget/pull/7'; exit 0 ;;
      *"--json state "*) printf '%s\n' MERGED; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head'; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$W/bin/treehouse" "$W/bin/tmux" "$W/bin/no-mistakes" "$W/bin/gh-axi" "$W/bin/gh"
  fm_fake_docker "$W/bin"
  printf '{"worktrees":[{"name":"1","path":"%s","leased":true,"lease_holder":"t1"}]}\n' "$COPY" > "$POOL/pool1/treehouse-state.json"
  fm_write_meta "$STATE/t1.meta" "window=firstmate:fm-t1" "endpoint_task_id=t1" "worktree=$COPY" \
    "project=$W/project" "kind=ship" "mode=no-mistakes" "spawn_gen=e2e-t1" "harness=claude" "backend=tmux" \
    "pr=$PR" "pr_head=$head"
  touch "$STATE/.last-watcher-beat"
}

# prune_real <args...>: the prune scripts with the REAL teardown and control.
prune_real() {
  HOME="$W/fakehome" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_ROOT_OVERRIDE="$W/code-root" NM_HOME="$W/nm" \
    TREEHOUSE_ROOT="$POOL" PATH="$W/bin:$PATH" TH_LOG="$W/th.log" FM_MERGE_PRUNE_EXIT_WAIT=0 \
    FM_TEARDOWN_GUARD_DONE=1 ROOT="$ROOT" STUB_LOG="$W/stub.log" FM_MERGE_PRUNE_TEARDOWN_BIN="$W/bin/teardown-real" REFUSE_FLAG="$W/refuse" \
    FM_MERGE_PRUNE_CONTROL_BIN="$W/bin/control-stub" CONTROL_LOG="$W/control.log" WORKER_PID_FILE="$W/worker.pid" \
    "$BIN_DIR/fm-merge-prune.sh" "$@"
}

wake_count_real() {
  local n
  n=$(grep -c 'merge-prune:t1' "$STATE/.wake-queue" 2>/dev/null) || n=0
  printf '%s' "$n"
}

# Nothing is forced: teardown is only ever asked for the task by name, and the
# fallback's treehouse calls never carry a force or an include-unlanded flag.
# (Teardown's own `treehouse return --force` is the landed-work-guarded return
# of the slot it has just proved safe; it is not a forced teardown.)
assert_nothing_forced() {  # <label>
  if [ -s "$W/stub.log" ] && [ -n "$(grep -vx 't1' "$W/stub.log")" ]; then
    fail "$1: teardown was asked with extra arguments: $(cat "$W/stub.log")"
  fi
  if grep -Eq -- '--include-unlanded|--include-in-use|^destroy .*--force' "$W/th.log"; then
    fail "$1: treehouse was forced: $(cat "$W/th.log")"
  fi
}

assert_not_destroyed() {  # <label>
  if grep -q '^destroy ' "$W/th.log"; then
    fail "$1: a copy was destroyed: $(cat "$W/th.log")"
  fi
}

test_e2e_merge_prunes_the_copy_with_the_real_teardown() {
  make_e2e_world
  prune_real arm t1 --run || fail "arm --run failed"
  fm_test_wait_until 60 test ! -e "$STATE/t1.merge-prune" || fail "the detached attempt did not finish: $(cat "$DATA/t1/merge-prune.log" 2>/dev/null)"
  [ ! -e "$COPY" ] || fail "the pool copy is still there after the merge"
  [ ! -e "$STATE/t1.meta" ] || fail "the task record is still there: real teardown did not complete"
  grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the log does not say reaped: $(cat "$DATA/t1/merge-prune.log")"
  [ "$(wake_count_real)" = 0 ] || fail "a clean prune raised a wake"
  grep -q '^return ' "$W/th.log" || fail "teardown did not return the slot through treehouse"
  assert_nothing_forced "e2e merge"
  pass "end to end: a verified merge arms the prune, the detached run reaps the copy through the real teardown, and the log says reaped"
}

test_e2e_transient_contention_retries_then_succeeds() {
  local holder
  make_e2e_world
  prune_real arm t1
  # Another lifecycle action (a co-tenant's control action) holds the task's
  # lock, so real teardown refuses without changing anything.
  sleep 120 &
  holder=$!
  WORKER_PIDS+=("$holder")
  mkdir "$STATE/.control-t1.lock"
  printf '%s\n' "$holder" > "$STATE/.control-t1.lock/pid"
  prune_real run t1 --now >/dev/null 2>&1
  [ -e "$COPY" ] && [ -e "$STATE/t1.meta" ] || fail "contention closed something: the copy or record is gone"
  [ "$(rec_field t1 state)" = pending ] && [ "$(rec_field t1 attempts)" = 1 ] || fail "contention was not a pending retry: $(cat "$STATE/t1.merge-prune")"
  [ "$(wake_count_real)" = 0 ] || fail "contention raised a wake"
  assert_nothing_forced "e2e contention"
  assert_not_destroyed "e2e contention"
  prune_real run t1 >/dev/null 2>&1
  [ -e "$STATE/t1.meta" ] || fail "a retry ran before its backoff elapsed"
  kill "$holder" 2>/dev/null || true
  rm -rf "$STATE/.control-t1.lock"
  set_rec t1 next_at 0
  prune_real run t1 >/dev/null 2>&1
  [ ! -e "$COPY" ] && [ ! -e "$STATE/t1.meta" ] && [ ! -e "$STATE/t1.merge-prune" ] || fail "the retry after the contention cleared did not reap: $(cat "$DATA/t1/merge-prune.log")"
  grep -q 'retry in' "$DATA/t1/merge-prune.log" && grep -q 'reaped: teardown completed' "$DATA/t1/merge-prune.log" || fail "the log does not show the retry and then reaped"
  pass "end to end: a co-tenant's lifecycle lock makes the real teardown refuse, the prune retries later without a wake, and then reaps"
}

# Real teardown refuses a copy that went on after its PR merged (a stale PR
# head), though that follow-up commit is pushed and nothing is lost. The
# fallback proves the copy clean, pushed and unused, removes it, and teardown
# then finishes the records.
test_e2e_false_positive_refusal_is_reaped_by_the_fallback() {
  make_e2e_world
  printf 'follow-up\n' > "$COPY/followup.txt"
  git -C "$COPY" add followup.txt
  git -C "$COPY" commit -q -m "follow-up after the merge"
  git -C "$COPY" push -q origin fm/t1
  mkdir -p "$COPY/.claude/bug-evidence" "$COPY/node_modules/x"
  printf 'closeout\n' > "$COPY/.claude/bug-evidence/slot.json"
  printf x > "$COPY/node_modules/x/i.js"
  prune_real arm t1
  start_inside "$COPY" "$W/worker.pid"
  FM_MERGE_PRUNE_EXIT_WAIT=3 prune_real run t1 --now >/dev/null 2>&1
  if [ -e "$STATE/t1.merge-prune" ] && grep -q 'process(es) inside' "$STATE/t1.merge-prune"; then
    fail "the finished worker was never stopped: $(cat "$STATE/t1.merge-prune")"
  fi
  [ ! -e "$COPY" ] || fail "the copy was not removed by the fallback: $(cat "$DATA/t1/merge-prune.log")"
  [ ! -e "$STATE/t1.meta" ] || fail "teardown did not finish the records after the fallback: $(cat "$DATA/t1/merge-prune.log")"
  grep -q 'fallback destroyed' "$DATA/t1/merge-prune.log" || fail "the log does not say the fallback destroyed it"
  grep -q 'reaped: removed by fallback' "$DATA/t1/merge-prune.log" || fail "the log does not say reaped"
  grep -qx "destroy $COPY --include-leased --yes" "$W/th.log" || fail "the fallback did not call destroy as the reaper does: $(cat "$W/th.log")"
  find "$DATA/t1/merge-prune-preserved" -name slot.json | grep -q . || fail "the bug-evidence record was not preserved before removal"
  [ "$(wake_count_real)" = 0 ] || fail "a reaped copy raised a wake"
  assert_nothing_forced "e2e fallback"
  pass "end to end: a copy real teardown refuses for a pushed follow-up is removed by the fallback, preserved records first, and teardown then closes the task"
}

test_e2e_unsafe_copies_are_never_removed() {
  local what
  for what in dirty unpushed nested-unpushed; do
    make_e2e_world
    case "$what" in
      dirty) printf 'edit\n' >> "$COPY/README.md" ;;
      unpushed)
        printf 'new\n' > "$COPY/new.txt"; git -C "$COPY" add new.txt; git -C "$COPY" commit -q -m "unpushed work" ;;
      nested-unpushed)
        : > "$W/refuse"
        git clone -q "$ORIGIN" "$COPY/.claude/worktrees/n1" 2>/dev/null
        printf 'o\n' > "$COPY/.claude/worktrees/n1/o.txt"
        git -C "$COPY/.claude/worktrees/n1" add o.txt
        git -C "$COPY/.claude/worktrees/n1" commit -q -m "unpushed in nested" ;;
    esac
    prune_real arm t1
    prune_real run t1 --now >/dev/null 2>&1
    [ -e "$COPY" ] || fail "$what: an unsafe copy was removed"
    [ -e "$STATE/t1.meta" ] || fail "$what: the task record was closed over an unsafe copy"
    assert_nothing_forced "e2e $what"
    assert_not_destroyed "e2e $what"
    [ "$(wake_count_real)" = 1 ] || fail "$what: want exactly one wake, got $(wake_count_real): $(cat "$STATE/.wake-queue" 2>/dev/null)"
    grep -F "$COPY" "$STATE/.wake-queue" | grep -q 'merge-prune kept' || fail "$what: the wake does not name the copy"
    prune_real run t1 --now >/dev/null 2>&1; prune_real run t1 --now >/dev/null 2>&1
    [ "$(wake_count_real)" = 1 ] || fail "$what: repeat attempts raised more wakes"
    cleanup_workers
  done
  pass "end to end: a changed file, an unpushed commit and an unpushed NESTED commit each keep the copy, force nothing, and raise exactly one wake"
}

# --- run ----------------------------------------------------------------------
#
# Usage: bash tests/fm-merge-prune.test.sh [test_function_name ...]

ALL_TESTS=(
  test_arm_needs_a_verified_merge
  test_arm_skips_tasks_it_does_not_own
  test_run_not_due_does_nothing
  test_missing_task_or_changed_pr_drops_the_record
  test_merge_cleanup_runs_teardown_unforced
  test_transient_refusals_back_off_silently_then_succeed
  test_flaky_contention_retries_through_the_sweep
  test_backoff_doubles_to_a_cap_and_wakes_once
  test_sweep_runs_only_due_records_and_at_most_three
  test_fallback_removes_a_clean_pushed_unused_scratch_copy
  test_fallback_keeps_a_changed_file
  test_fallback_keeps_an_untracked_file
  test_fallback_keeps_an_unpushed_commit
  test_fallback_keeps_a_stash
  test_fallback_keeps_a_live_process
  test_fallback_nested_unpushed_commit_keeps_the_slot
  test_fallback_removes_a_clean_nested_copy_with_the_slot
  test_fallback_keeps_unique_ignored_files
  test_fallback_keeps_a_non_pool_copy
  test_fallback_accepts_the_merged_pr_head
  test_fallback_ignores_a_search_indexer
  test_fallback_never_overrides_a_live_pipeline_refusal
  test_fallback_destroy_failure_keeps_the_copy
  test_retained_copy_is_reaped_quietly_when_the_cause_clears
  test_e2e_merge_prunes_the_copy_with_the_real_teardown
  test_e2e_transient_contention_retries_then_succeeds
  test_e2e_false_positive_refusal_is_reaped_by_the_fallback
  test_e2e_unsafe_copies_are_never_removed
  test_unsafe_mutations_are_caught
  test_over_strict_mutations_are_caught
)
if [ "$#" -gt 0 ]; then
  for name in "$@"; do
    declare -F "$name" >/dev/null || fail "unknown test case: $name"
  done
  ALL_TESTS=("$@")
fi
for name in "${ALL_TESTS[@]}"; do
  "$name"
done
