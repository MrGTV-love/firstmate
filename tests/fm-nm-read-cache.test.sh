#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-read-cache-lib.sh - the per-task cache in front of
# the no-mistakes queries bin/fm-crew-state.sh makes. It keeps a finished run's
# reads and nothing else.
#
# The fake `no-mistakes` below records every call it receives, so each case
# counts the calls a read made rather than trusting the cache's own account of
# itself. Cases:
#   (a) a finished run is read once and kept until a newer run replaces it, and
#       an unverifiable finished run is read again, never guessed
#   (b) a live run, a failed or timed-out call, an unknown inventory and the
#       daemon probe are read fresh on every call
#   (c) a hit prints exactly the bytes the fresh read printed, a failure keeps
#       its exit status, and a cold, a warm and a disabled read classify
#       identically across every run shape
#   (d) mutation checks: copies of bin/ with the finished-run validity check or
#       the finished-only rule defeated must FAIL the cases above
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-read-cache)
fm_git_identity fmtest fmtest@example.invalid

# This suite is the one that exercises the cache; tests/lib.sh turns it off.
export FM_CREW_STATE_NM_CACHE=on
export FM_CREW_STATE_NO_FORGE=1

BRANCH=fm/cached

# A fake no-mistakes serving files from $FM_FAKE_NM_DIR and logging every call.
make_fakebin() {  # <dir> -> echoes the fakebin path
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
d=${FM_FAKE_NM_DIR:?}
printf '%s\n' "$*" >> "$d/calls.log"
rc_of() { if [ -f "$1" ]; then cat "$1"; else printf 0; fi; }
case "${1:-}" in
  axi)
    shift
    if [ "$#" = 0 ]; then
      cat "$d/overview"
      exit "$(rc_of "$d/overview.rc")"
    fi
    case "$1" in
      status)
        shift
        if [ "${1:-}" = --run ]; then
          f="$d/run-${2:-}"
          [ -f "$f" ] || exit 1
          cat "$f"
          exit "$(rc_of "$f.rc")"
        fi
        cat "$d/status"
        exit "$(rc_of "$d/status.rc")" ;;
      logs)
        cat "$d/ci-logs" 2>/dev/null
        exit 0 ;;
    esac ;;
  runs)
    cat "$d/runs" 2>/dev/null
    exit 0 ;;
  daemon)
    printf 'daemon running\n'
    exit "$(rc_of "$d/daemon.rc")" ;;
esac
exit 0
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# One case: a throwaway repo on $BRANCH, its task record, and the fake's files.
new_case() {  # <name> -> echoes the case dir
  local d="$TMP_ROOT/$1" head
  mkdir -p "$d/state" "$d/nm" "$d/nmfake" "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" checkout -q -b "$BRANCH"
  head=$(git -C "$d/wt" rev-parse HEAD)
  printf '%s\n' "$head" > "$d/head"
  make_fakebin "$d" >/dev/null
  fm_write_meta "$d/state/cached.meta" "window=fm:fm-cached" "worktree=$d/wt" "kind=ship"
  : > "$d/nmfake/calls.log"
  printf '%s\n' "$d"
}

# Run detail in the TOON shape `axi status` prints. <id> <status> [outcome]
run_toon() {  # <case-dir> <id> <status> [outcome]
  printf 'run:\n  id: "%s"\n  branch: %s\n  status: %s\n  head: "%s"\n  pr: ""\n  findings: none\n' \
    "$2" "$BRANCH" "$3" "$(cat "$1/head")"
  [ "$3" = running ] && printf '  steps[2]{step,status,findings,duration_ms}:\n    intent,completed,0,0\n    review,running,0,0\n'
  [ -z "${4:-}" ] || printf 'outcome: %s\n' "$4"
}

# Serve <id> as the branch's only run: overview row, bare status, id read, and a
# state-database row so a finished run can be validated.
serve_run() {  # <case-dir> <id> <status> [outcome]
  local d=$1 id=$2 st=$3 short listed
  short=$(cut -c1-8 "$d/head")
  listed=$st
  # The overview and the database know fewer words than the detail object does.
  case "$st" in fixing|ci) listed=running ;; esac
  run_toon "$d" "$id" "$st" "${4:-}" > "$d/nmfake/status"
  cp "$d/nmfake/status" "$d/nmfake/run-$id"
  printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  "%s",%s,%s,%s,""\n' "$id" "$BRANCH" "$listed" "$short" > "$d/nmfake/overview"
  db_set_runs "$d" "$id:$listed:1"
}

# Rewrite the state database: <id:status:created_at> rows for $BRANCH.
db_set_runs() {  # <case-dir> <row>...
  local d=$1
  shift
  rm -f "$d/nm/state.sqlite"
  python3 - "$d/nm/state.sqlite" "$BRANCH" "$(cat "$d/head")" "$@" <<'PY' || fail "could not write the state database fixture"
import sqlite3
import sys

database, branch, head, *rows = sys.argv[1:]
with sqlite3.connect(database) as db:
    db.executescript("""
        CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
        CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                           status TEXT NOT NULL, head_sha TEXT NOT NULL, created_at INTEGER NOT NULL);
    """)
    db.execute("INSERT INTO repos VALUES ('repo', '/fixture/repo')")
    for row in rows:
        run_id, status, created = row.split(":")
        db.execute("INSERT INTO runs VALUES (?, 'repo', ?, ?, ?, ?)", (run_id, branch, status, head, int(created)))
PY
}

calls() {  # <case-dir> -> number of no-mistakes calls so far
  local n
  n=$(wc -l < "$1/nmfake/calls.log")
  printf '%s\n' "${n//[[:space:]]/}"
}

# One crew-state read through <crew-state script>, with the case's fakes.
read_state() {  # <case-dir> <crew-state-script>
  FM_FAKE_NM_DIR="$1/nmfake" NM_HOME="$1/nm" PATH="$1/fakebin:$PATH" \
    FM_STATE_OVERRIDE="$1/state" "$2" cached 2>/dev/null
}

# A quiet worker status log, as a task that finished its last turn leaves it.
age_status_log() {  # <case-dir>
  printf 'working [at=1]: start\n' > "$1/state/cached.status"
  fm_touch_epoch "$(( $(date +%s) - 1000 ))" "$1/state/cached.status"
}

# --- (a) finished runs ----------------------------------------------------------

case_finished_run_is_kept_until_the_id_changes() {  # <crew-state script> <name>
  local d out1 out2 out3 first
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN completed passed
  out1=$(read_state "$d" "$1")
  first=$(calls "$d")
  out2=$(read_state "$d" "$1")
  assert_contains "$out1" 'state: done' 'a passed run reads as done'
  assert_equals 3 "$first" 'a cold finished read makes the three calls'
  assert_equals "$first" "$(calls "$d")" 'a finished run is not read again'
  assert_equals "$out1" "$out2" 'the finished read keeps its line'
  # A newer run on the same branch replaces it: the cache must notice.
  run_toon "$d" 01NEW running > "$d/nmfake/status"
  cp "$d/nmfake/status" "$d/nmfake/run-01NEW"
  printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  "01NEW",%s,running,%s,""\n  "01RUN",%s,completed,%s,""\n' \
    "$BRANCH" "$(cut -c1-8 "$d/head")" "$BRANCH" "$(cut -c1-8 "$d/head")" > "$d/nmfake/overview"
  db_set_runs "$d" 01RUN:completed:1 01NEW:running:2
  out3=$(read_state "$d" "$1")
  assert_contains "$out3" 'state: working' 'a new run on the branch is read, not the finished one'
  assert_contains "$out3" '01NEW' 'the new run is named'
  pass "$2: a finished run is cached until a newer run replaces it"
}

case_finished_run_needs_the_database() {  # <crew-state script> <name>
  local d first
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN completed passed
  read_state "$d" "$1" >/dev/null
  first=$(calls "$d")
  rm -f "$d/nm/state.sqlite"
  read_state "$d" "$1" >/dev/null
  assert_equals "$(( first + 2 ))" "$(calls "$d")" 'without the database only the id-addressed read stays cached'
  pass "$2: an unverifiable finished run is read again, never guessed"
}

# --- (b) everything else is read fresh --------------------------------------------

case_live_run_is_read_fresh_every_time() {  # <crew-state script> <name>
  local d out1 out2 out3 first
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  out1=$(read_state "$d" "$1")
  first=$(calls "$d")
  out2=$(read_state "$d" "$1")
  out3=$(read_state "$d" "$1")
  assert_contains "$out1" 'state: working' 'the live run reads as working'
  assert_equals 3 "$first" 'a live read makes the status, overview and id-addressed calls'
  assert_equals "$(( first * 3 ))" "$(calls "$d")" 'every further live read makes the whole set of calls again'
  assert_equals "$out1" "$out2" 'the second live read prints the same line'
  assert_equals "$out1" "$out3" 'the third live read prints the same line'
  # A run that parks at a gate between two reads is seen by the very next read.
  printf '  gate:\n    step: review\n' >> "$d/nmfake/run-01RUN"
  cp "$d/nmfake/run-01RUN" "$d/nmfake/status"
  assert_not_equals "$out1" "$(read_state "$d" "$1")" 'a live run that changed is seen by the next read'
  pass "$2: a live run gets a fresh read on every call"
}

case_failure_is_read_fresh_every_time() {  # <crew-state script> <name>
  local d first out1 out2 out3 rc
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  for rc in 1 124; do
    printf '%s' "$rc" > "$d/nmfake/run-01RUN.rc"
    first=$(calls "$d")
    out1=$(read_state "$d" "$1")
    out2=$(read_state "$d" "$1")
    assert_contains "$out1" 'state: unknown' "a failed id read (exit $rc) reads as unknown"
    assert_equals "$out1" "$out2" "the second failed read (exit $rc) is still a failure"
    assert_equals "$(( first + 6 ))" "$(calls "$d")" "a failed read (exit $rc) is made again on every call"
  done
  rm -f "$d/nmfake/run-01RUN.rc"
  out3=$(read_state "$d" "$1")
  assert_contains "$out3" 'state: working' 'the recovered answer is used at once'
  pass "$2: a failed or timed-out call is read fresh on every call and never replayed"
}

case_unknown_inventory_is_read_fresh_every_time() {  # <crew-state script> <name>
  local d out1 out2 out3
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  "01RUN",%s,running,%s,""\n' "$BRANCH" "$(cut -c1-8 "$d/head")" > "$d/nmfake/overview"
  out1=$(read_state "$d" "$1")
  out2=$(read_state "$d" "$1")
  assert_contains "$out1" 'state: unknown' 'an unreadable inventory reads as unknown'
  assert_contains "$out2" 'state: unknown' 'the unreadable inventory is still unknown'
  serve_run "$d" 01RUN running
  out3=$(read_state "$d" "$1")
  assert_contains "$out3" 'state: working' 'the repaired inventory is read at once'
  pass "$2: an unknown inventory verdict is never kept"
}

case_daemon_probe_is_read_fresh_every_time() {
  local d first
  d=$(new_case daemon)
  age_status_log "$d"
  # A run head the copy does not hold sends the read through the daemon probe.
  printf 'abcdef0123456789abcdef0123456789abcdef01\n' > "$d/head"
  serve_run "$d" 01RUN running
  read_state "$d" "$CREW_STATE" >/dev/null
  first=$(grep -c '^daemon status$' "$d/nmfake/calls.log")
  assert_equals 1 "$first" 'the daemon probe is made, so the case proves something'
  printf 1 > "$d/nmfake/daemon.rc"
  read_state "$d" "$CREW_STATE" >/dev/null
  read_state "$d" "$CREW_STATE" >/dev/null
  assert_equals 3 "$(grep -c '^daemon status$' "$d/nmfake/calls.log")" 'the daemon is asked again on every read, answered or down'
  pass 'the daemon probe is read fresh on every call'
}

# --- (c) exactness and parity -------------------------------------------------------

case_hit_prints_the_bytes_of_the_fresh_read() {
  local d fb out1 out2 first
  d=$(new_case exact)
  fb=$d/fakebin
  db_set_runs "$d" 01RUN:completed:1
  # A finished run whose answer ends in blank lines and padding a trim would eat.
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
printf 'x\n' >> "$d/calls.log"
printf 'run:\n  id: "01RUN"\n  branch: $BRANCH\n  status: completed\n\nline  three  \noutcome: passed\n\n\n'
SH
  chmod +x "$fb/no-mistakes"
  : > "$d/calls.log"
  # The fake PATH and NM_HOME are intentionally scoped to this subshell.
  # shellcheck disable=SC2030
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-nm-read-cache-lib.sh"
    PATH="$fb:$PATH"
    export NM_HOME="$d/nm"
    fm_nmc_init "$d/state" cached "$d/wt" "$BRANCH" 10
    fm_nmc_read status status '' axi status > "$d/cold.bytes"
    printf '%s' "$?" > "$d/cold.rc"
    fm_nmc_read status status '' axi status > "$d/warm.bytes"
    printf '%s' "$?" > "$d/warm.rc"
  )
  first=$(wc -l < "$d/calls.log")
  cmp -s "$d/cold.bytes" "$d/warm.bytes" || fail 'a hit does not print the bytes of the fresh read'
  assert_equals 0a0a0a "$(tail -c 3 "$d/warm.bytes" | od -An -tx1 | tr -d ' \n')" 'the hit keeps the trailing newlines of the fresh read'
  assert_equals 0 "$(cat "$d/cold.rc")" 'the cold read succeeds'
  assert_equals 0 "$(cat "$d/warm.rc")" 'the warm read succeeds'
  assert_equals 1 "${first//[[:space:]]/}" 'the warm read was served without a second call'
  # A failure is never stored: it keeps its exit status and is asked again.
  cat > "$fb/no-mistakes" <<SH
#!/usr/bin/env bash
printf 'x\n' >> "$d/calls.log"
printf 'partial\n'
exit 7
SH
  : > "$d/calls.log"
  # The first subshell's PATH and NM_HOME do not carry over; this one sets its own.
  # shellcheck disable=SC2031
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-nm-read-cache-lib.sh"
    PATH="$fb:$PATH"
    export NM_HOME="$d/nm"
    fm_nmc_init "$d/state" cached2 "$d/wt" "$BRANCH" 10
    fm_nmc_read status status '' axi status > "$d/fail1.bytes"
    printf '%s' "$?" > "$d/fail1.rc"
    fm_nmc_read status status '' axi status > "$d/fail2.bytes"
    printf '%s' "$?" > "$d/fail2.rc"
  )
  out1=$(cat "$d/fail1.rc" "$d/fail2.rc")
  out2=$(wc -l < "$d/calls.log")
  assert_equals 77 "$out1" 'a failed call keeps its exit status on every read'
  assert_equals 2 "${out2//[[:space:]]/}" 'a failed call is made again, not replayed'
  pass 'a hit prints exactly the bytes of the fresh read, and a failure is never stored'
}

case_cold_warm_and_disabled_reads_classify_alike() {
  local d shape cold warm off
  for shape in running fixing parked passed failed cancelled; do
    d=$(new_case "parity-$shape")
    age_status_log "$d"
    case "$shape" in
      running) serve_run "$d" 01RUN running ;;
      fixing) serve_run "$d" 01RUN fixing ;;
      parked)
        serve_run "$d" 01RUN running
        printf '  gate:\n    step: review\n' >> "$d/nmfake/run-01RUN"
        cp "$d/nmfake/run-01RUN" "$d/nmfake/status" ;;
      passed) serve_run "$d" 01RUN completed passed ;;
      failed) serve_run "$d" 01RUN failed failed ;;
      cancelled) serve_run "$d" 01RUN cancelled cancelled ;;
    esac
    cold=$(read_state "$d" "$CREW_STATE")
    warm=$(read_state "$d" "$CREW_STATE")
    off=$(FM_CREW_STATE_NM_CACHE=off read_state "$d" "$CREW_STATE")
    assert_equals "$off" "$cold" "a cold cached $shape read matches an uncached one"
    assert_equals "$off" "$warm" "a warm cached $shape read matches an uncached one"
  done
  pass 'cold, warm and uncached reads classify every run shape the same'
}

case_answers_are_classified_by_what_they_say() {
  local d
  d=$(new_case classify)
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-nm-read-cache-lib.sh"
    fm_nmc_init "$d/state" cached "$d/wt" "$BRANCH" 10
    expect() {  # <fin|none> <label> <kind> <exit> <body> [hint]
      local got=none
      fm_nmc_classify "$3" "$4" "$5" "${6:-}" && got=fin
      [ "$got" = "$1" ] || { printf 'not ok - %s: expected %s, got %s\n' "$2" "$1" "$got" >&2; exit 1; }
    }
    expect fin 'a passed run' status 0 "$(run_toon "$d" 01RUN completed passed)"
    expect fin 'a failed run' status 0 "$(run_toon "$d" 01RUN failed failed)"
    expect fin 'a cancelled run read by id' status-run 0 "$(run_toon "$d" 01RUN cancelled cancelled)" 01RUN
    expect fin 'a ci log of a run the caller names as finished' logs 0 'CI checks passed' 01RUN
    expect none 'a ci log of a run still in flight' logs 0 'CI checks running' ''
    expect none 'an empty ci log' logs 0 '' 01RUN
    expect none 'an aborted run' status 0 "$(run_toon "$d" 01RUN aborted aborted)"
    expect none 'a run still in flight' status 0 "$(run_toon "$d" 01RUN running)"
    expect none 'a terminal status with no outcome yet' status 0 "$(run_toon "$d" 01RUN completed)"
    expect none 'an outcome that can still change' status 0 "$(run_toon "$d" 01RUN completed checks-passed)"
    expect none 'a branch with no run of its own' status 0 $'current_branch: fm/cached\nother_branch_run:\n  id: "01X"\n  branch: fm/other\n  status: completed\noutcome: passed'
    expect none 'a failed call' status 1 "$(run_toon "$d" 01RUN completed passed)"
    expect none 'a timed-out call' status 124 "$(run_toon "$d" 01RUN completed passed)"
    expect none 'an empty answer' status 0 ''
    expect none 'an error answer' status 0 "error: repo not initialized"
    expect none 'an id read answering for another run' status-run 0 "$(run_toon "$d" 01OTHER completed passed)" 01RUN
    expect none 'an id read answering for another branch' status-run 0 "$(run_toon "$d" 01RUN completed passed | sed 's|branch: fm/cached|branch: fm/other|')" 01RUN
    expect none 'a daemon that answered' daemon 0 'daemon running'
    expect none 'a runs listing' runs 0 'count: 1 of 1 total'
  ) || fail 'an answer was classified into the wrong class'
  pass 'answers are classified by what they say, and only a settled finished run is kept'
}

# --- (d) mutation checks ----------------------------------------------------------------

# A copy of bin/ whose cache library ends with <override>: a later definition
# wins, so the named predicate is defeated without matching any source text.
make_mutant() {  # <name> <override>
  local m="$TMP_ROOT/mutants/$1" f
  mkdir -p "$m/bin"
  # Every other script is linked, not copied: a script finds its siblings through
  # the directory it was started from, so the linked copy loads the mutated library.
  for f in "$ROOT/bin"/*; do
    ln -s "$f" "$m/bin/${f##*/}"
  done
  rm -f "$m/bin/fm-nm-read-cache-lib.sh"
  cp "$ROOT/bin/fm-nm-read-cache-lib.sh" "$m/bin/fm-nm-read-cache-lib.sh"
  printf '\n%s\n' "$2" >> "$m/bin/fm-nm-read-cache-lib.sh"
  printf '%s\n' "$m/bin/fm-crew-state.sh"
}

# The mutant must fail the case: it runs in a subshell so the case's own fail
# (which exits) is the signal rather than the end of this suite.
expect_mutant_caught() {  # <label> <case-function> <override>
  local script
  script=$(make_mutant "$1" "$3")
  if ( "$2" "$script" "mutant-$1" ) >/dev/null 2>&1; then
    fail "mutation survived: $1 left $2 passing"
  fi
  pass "mutation caught: $1 fails $2"
}

main() {
  local fn
  for fn in \
    case_finished_run_is_kept_until_the_id_changes \
    case_finished_run_needs_the_database \
    case_live_run_is_read_fresh_every_time \
    case_failure_is_read_fresh_every_time \
    case_unknown_inventory_is_read_fresh_every_time; do
    "$fn" "$CREW_STATE" "$fn"
  done
  case_daemon_probe_is_read_fresh_every_time
  case_hit_prints_the_bytes_of_the_fresh_read
  case_answers_are_classified_by_what_they_say
  case_cold_warm_and_disabled_reads_classify_alike

  expect_mutant_caught finished-always-valid case_finished_run_is_kept_until_the_id_changes 'fm_nmc_fin_valid() { return 0; }'
  expect_mutant_caught finished-needs-no-database case_finished_run_needs_the_database 'fm_nmc_fin_valid() { return 0; }'
  expect_mutant_caught live-run-kept case_live_run_is_read_fresh_every_time 'fm_nmc_classify() { FM_NMC_FIN=01RUN; return 0; }'
  expect_mutant_caught failure-kept case_failure_is_read_fresh_every_time 'fm_nmc_classify() { FM_NMC_FIN=01RUN; return 0; }'
}

main
