#!/usr/bin/env bash
# Behavior tests for bin/fm-nm-read-cache-lib.sh - the per-task cache in front of
# the no-mistakes queries bin/fm-crew-state.sh makes.
#
# The fake `no-mistakes` below records every call it receives, so each case
# counts the calls a read made rather than trusting the cache's own account of
# itself. Cases:
#   (a) repeated reads of a live run inside the time limit make one set of calls
#   (b) a status or progress event newer than the entry invalidates it, and an
#       older one does not
#   (c) a finished run is read once and kept until a newer run replaces it, even
#       past the live time limit
#   (d) a failure replays as a failure, only for the short failure window, and
#       a recovered answer is used as soon as the window closes
#   (e) a hit prints exactly the bytes the fresh read printed, with its exit
#       status, and a cold, a warm and a disabled read classify identically
#       across every run shape
#   (f) the daemon probe is read once, and a down answer is not kept long
#   (g) mutation checks: copies of bin/ with the invalidation, the finished-run
#       validity check, or the failure class defeated must FAIL the cases above
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CREW_STATE="$ROOT/bin/fm-crew-state.sh"
TMP_ROOT=$(fm_test_tmproot fm-nm-read-cache)
fm_git_identity fmtest fmtest@example.invalid

# This suite is the one that exercises the cache; tests/lib.sh turns it off.
export FM_CREW_STATE_NM_CACHE=on
export FM_CREW_STATE_NO_FORGE=1
unset FM_CREW_STATE_NM_CACHE_TTL FM_CREW_STATE_NM_CACHE_FAIL_TTL

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

# Age the status log so an entry written now is strictly newer than it.
age_status_log() {  # <case-dir>
  printf 'working [at=1]: start\n' > "$1/state/cached.status"
  fm_touch_epoch "$(( $(date +%s) - 1000 ))" "$1/state/cached.status"
}

# --- (a) repeated live reads --------------------------------------------------

case_live_reads_share_one_set_of_calls() {  # <crew-state script> <name>
  local d out1 out2 out3 first
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  out1=$(read_state "$d" "$1")
  first=$(calls "$d")
  out2=$(read_state "$d" "$1")
  out3=$(read_state "$d" "$1")
  assert_contains "$out1" 'state: working' 'the live run reads as working'
  assert_equals 3 "$first" 'a cold live read makes the status, overview and id-addressed calls'
  assert_equals "$first" "$(calls "$d")" 'two more reads inside the time limit make no further calls'
  assert_equals "$out1" "$out2" 'a warm read prints the cold read line'
  assert_equals "$out1" "$out3" 'a third read prints the same line'
  pass "$2: consecutive live reads inside the time limit make one set of calls"
}

# --- (b) status and progress events invalidate ---------------------------------

case_status_event_invalidates() {  # <crew-state script> <name>
  local d before
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  read_state "$d" "$1" >/dev/null
  before=$(calls "$d")
  read_state "$d" "$1" >/dev/null
  assert_equals "$before" "$(calls "$d")" 'an untouched log leaves the entry in force'
  fm_touch_epoch "$(( $(date +%s) + 5 ))" "$d/state/cached.status"
  read_state "$d" "$1" >/dev/null
  assert_equals "$(( before * 2 ))" "$(calls "$d")" 'a newer status line makes the next read ask again'
  pass "$2: a newer status event invalidates the entry and an older one does not"
}

case_progress_marker_invalidates() {  # <crew-state script> <name>
  local d before
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  read_state "$d" "$1" >/dev/null
  before=$(calls "$d")
  : > "$d/state/cached.progress"
  fm_touch_epoch "$(( $(date +%s) + 5 ))" "$d/state/cached.progress"
  read_state "$d" "$1" >/dev/null
  assert_equals "$(( before * 2 ))" "$(calls "$d")" 'a newer progress marker makes the next read ask again'
  pass "$2: a newer progress marker invalidates the entry"
}

case_live_entry_expires() {  # <crew-state script> <name>
  local d before
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  FM_CREW_STATE_NM_CACHE_TTL=2 read_state "$d" "$1" >/dev/null
  before=$(calls "$d")
  sleep 3
  FM_CREW_STATE_NM_CACHE_TTL=2 read_state "$d" "$1" >/dev/null
  assert_equals "$(( before * 2 ))" "$(calls "$d")" 'a live entry past its time limit is read again'
  pass "$2: a live entry expires after its time limit"
}

# --- (c) finished runs ----------------------------------------------------------

case_finished_run_is_kept_until_the_id_changes() {  # <crew-state script> <name>
  local d out1 out2 out3 first
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN completed passed
  out1=$(FM_CREW_STATE_NM_CACHE_TTL=1 read_state "$d" "$1")
  first=$(calls "$d")
  sleep 2
  out2=$(FM_CREW_STATE_NM_CACHE_TTL=1 read_state "$d" "$1")
  assert_contains "$out1" 'state: done' 'a passed run reads as done'
  assert_equals 3 "$first" 'a cold finished read makes the three calls'
  assert_equals "$first" "$(calls "$d")" 'a finished run is not read again, even past the live time limit'
  assert_equals "$out1" "$out2" 'the finished read keeps its line'
  # A newer run on the same branch replaces it: the cache must notice.
  run_toon "$d" 01NEW running > "$d/nmfake/status"
  cp "$d/nmfake/status" "$d/nmfake/run-01NEW"
  printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  "01NEW",%s,running,%s,""\n  "01RUN",%s,completed,%s,""\n' \
    "$BRANCH" "$(cut -c1-8 "$d/head")" "$BRANCH" "$(cut -c1-8 "$d/head")" > "$d/nmfake/overview"
  db_set_runs "$d" 01RUN:completed:1 01NEW:running:2
  out3=$(FM_CREW_STATE_NM_CACHE_TTL=1 read_state "$d" "$1")
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

# --- (d) failures -----------------------------------------------------------------

case_failure_is_not_served_as_success() {  # <crew-state script> <name>
  local d first out1 out2 out3
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  printf 1 > "$d/nmfake/run-01RUN.rc"
  out1=$(FM_CREW_STATE_NM_CACHE_FAIL_TTL=5 read_state "$d" "$1")
  first=$(calls "$d")
  out2=$(FM_CREW_STATE_NM_CACHE_FAIL_TTL=5 read_state "$d" "$1")
  assert_contains "$out1" 'state: unknown' 'a failed id read reads as unknown'
  assert_equals "$first" "$(calls "$d")" 'a failure is replayed inside the failure window'
  assert_equals "$out1" "$out2" 'the replay is still a failure'
  rm -f "$d/nmfake/run-01RUN.rc"
  sleep 6
  out3=$(FM_CREW_STATE_NM_CACHE_FAIL_TTL=5 read_state "$d" "$1")
  assert_contains "$out3" 'state: working' 'once the failure window closes the recovered answer is used'
  assert_equals "$(( first + 1 ))" "$(calls "$d")" 'only the failed call is repeated'
  pass "$2: a failure is replayed as a failure, briefly, and never outlives its window"
}

case_failures_can_be_left_uncached() {  # <crew-state script> <name>
  local d first
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  printf 1 > "$d/nmfake/run-01RUN.rc"
  FM_CREW_STATE_NM_CACHE_FAIL_TTL=0 read_state "$d" "$1" >/dev/null
  first=$(calls "$d")
  FM_CREW_STATE_NM_CACHE_FAIL_TTL=0 read_state "$d" "$1" >/dev/null
  assert_equals "$(( first + 1 ))" "$(calls "$d")" 'with a zero failure window the failed call is made again'
  pass "$2: a zero failure window caches no failure"
}

case_unknown_inventory_is_not_kept_long() {  # <crew-state script> <name>
  local d out1 out2 out3
  d=$(new_case "$2")
  age_status_log "$d"
  serve_run "$d" 01RUN running
  printf 'count: 2 of 2 total\nruns[2]{id,branch,status,head,pr}:\n  "01RUN",%s,running,%s,""\n' "$BRANCH" "$(cut -c1-8 "$d/head")" > "$d/nmfake/overview"
  out1=$(FM_CREW_STATE_NM_CACHE_FAIL_TTL=5 read_state "$d" "$1")
  assert_contains "$out1" 'state: unknown' 'an unreadable inventory reads as unknown'
  serve_run "$d" 01RUN running
  out2=$(FM_CREW_STATE_NM_CACHE_FAIL_TTL=5 read_state "$d" "$1")
  assert_contains "$out2" 'state: unknown' 'the unknown verdict is replayed inside the failure window'
  sleep 6
  out3=$(FM_CREW_STATE_NM_CACHE_FAIL_TTL=5 read_state "$d" "$1")
  assert_contains "$out3" 'state: working' 'the repaired inventory is read once the window closes'
  pass "$2: an unknown inventory verdict lives only for the failure window"
}

# --- (e) exactness and parity -------------------------------------------------------

case_hit_prints_the_bytes_of_the_fresh_read() {
  local d fb out1 out2 rc1 rc2
  d=$(new_case exact)
  fb=$d/fakebin
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf 'line one\n\nline  three  \n\n\n'
exit 7
SH
  chmod +x "$fb/no-mistakes"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-nm-read-cache-lib.sh"
    PATH="$fb:$PATH"
    fm_nmc_init "$d/state" cached "$d/wt" "$BRANCH" 10
    fm_nmc_read daemon-ish daemon '' daemon status > "$d/cold.bytes"
    printf '%s' "$?" > "$d/cold.rc"
    fm_nmc_read daemon-ish daemon '' daemon status > "$d/warm.bytes"
    printf '%s' "$?" > "$d/warm.rc"
  )
  out1=$(od -c < "$d/cold.bytes")
  out2=$(od -c < "$d/warm.bytes")
  rc1=$(cat "$d/cold.rc")
  rc2=$(cat "$d/warm.rc")
  assert_equals "$out1" "$out2" 'a hit prints the bytes of the fresh read, trailing newlines included'
  assert_equals 7 "$rc1" 'the cold read keeps the exit status'
  assert_equals 7 "$rc2" 'the warm read replays the exit status'
  pass 'a hit prints exactly the bytes and exit status of the fresh read'
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
    expect() {  # <expected-class> <label> <kind> <exit> <body> [hint]
      fm_nmc_classify "$3" "$4" "$5" "${6:-}"
      [ "$FM_NMC_CLASS" = "$1" ] || { printf 'not ok - %s: expected %s, got %s\n' "$2" "$1" "$FM_NMC_CLASS" >&2; exit 1; }
    }
    expect fin 'a passed run' status 0 "$(run_toon "$d" 01RUN completed passed)"
    expect fin 'a failed run' status 0 "$(run_toon "$d" 01RUN failed failed)"
    expect fin 'a cancelled run read by id' status-run 0 "$(run_toon "$d" 01RUN cancelled cancelled)" 01RUN
    expect live 'a run still in flight' status 0 "$(run_toon "$d" 01RUN running)"
    expect live 'a terminal status with no outcome yet' status 0 "$(run_toon "$d" 01RUN completed)"
    expect live 'an outcome that can still change' status 0 "$(run_toon "$d" 01RUN completed checks-passed)"
    expect live 'a branch with no run of its own' status 0 $'current_branch: fm/cached\nother_branch_run:\n  id: "01X"\n  branch: fm/other\n  status: completed\noutcome: passed'
    expect fail 'a failed call' status 1 "$(run_toon "$d" 01RUN completed passed)"
    expect fail 'an empty answer' status 0 ''
    expect fail 'an error answer' status 0 "error: repo not initialized"
    expect fail 'an id read answering for another run' status-run 0 "$(run_toon "$d" 01OTHER completed passed)" 01RUN
    expect fail 'an id read answering for another branch' status-run 0 "$(run_toon "$d" 01RUN completed passed | sed 's|branch: fm/cached|branch: fm/other|')" 01RUN
    expect live 'a daemon that answered' daemon 0 'daemon running'
    expect fail 'a daemon that did not answer' daemon 124 ''
  ) || fail 'an answer was classified into the wrong class'
  pass 'answers are classified by what they say, and only a settled finished run is kept for good'
}

# --- (f) the daemon probe -------------------------------------------------------------

case_daemon_probe_is_read_once() {
  local d first out1 out2
  d=$(new_case daemon)
  age_status_log "$d"
  # A run head the copy does not hold sends the read through the daemon probe.
  printf 'abcdef0123456789abcdef0123456789abcdef01\n' > "$d/head"
  serve_run "$d" 01RUN running
  out1=$(read_state "$d" "$CREW_STATE")
  first=$(calls "$d")
  out2=$(read_state "$d" "$CREW_STATE")
  assert_equals "$first" "$(calls "$d")" 'the daemon probe is not repeated inside the time limit'
  assert_equals "$out1" "$out2" 'the warm read keeps the verdict'
  grep -q '^daemon status$' "$d/nmfake/calls.log" || fail 'the daemon probe was never made, so the case proves nothing'
  pass 'the daemon probe is made once per time limit'
}

case_down_daemon_is_not_kept_long() {
  local d first
  d=$(new_case daemon-down)
  age_status_log "$d"
  printf 'abcdef0123456789abcdef0123456789abcdef01\n' > "$d/head"
  serve_run "$d" 01RUN running
  printf 1 > "$d/nmfake/daemon.rc"
  FM_CREW_STATE_NM_CACHE_FAIL_TTL=5 read_state "$d" "$CREW_STATE" >/dev/null
  first=$(grep -c '^daemon status$' "$d/nmfake/calls.log")
  sleep 6
  FM_CREW_STATE_NM_CACHE_FAIL_TTL=5 read_state "$d" "$CREW_STATE" >/dev/null
  assert_equals "$(( first + 1 ))" "$(grep -c '^daemon status$' "$d/nmfake/calls.log")" 'a down answer is asked again once the failure window closes'
  pass 'a down daemon answer lives only for the failure window'
}

# --- (g) mutation checks ----------------------------------------------------------------

# A copy of bin/ whose cache library ends with <override>: a later definition
# wins, so the named predicate is defeated without matching any source text.
make_mutant() {  # <name> <override>
  local m="$TMP_ROOT/mutants/$1"
  mkdir -p "$m"
  cp -R "$ROOT/bin" "$m/bin"
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
    case_live_reads_share_one_set_of_calls \
    case_status_event_invalidates \
    case_progress_marker_invalidates \
    case_live_entry_expires \
    case_finished_run_is_kept_until_the_id_changes \
    case_finished_run_needs_the_database \
    case_failure_is_not_served_as_success \
    case_failures_can_be_left_uncached \
    case_unknown_inventory_is_not_kept_long; do
    "$fn" "$CREW_STATE" "$fn"
  done
  case_hit_prints_the_bytes_of_the_fresh_read
  case_answers_are_classified_by_what_they_say
  case_cold_warm_and_disabled_reads_classify_alike
  case_daemon_probe_is_read_once
  case_down_daemon_is_not_kept_long

  expect_mutant_caught no-invalidation case_status_event_invalidates 'fm_nmc_invalidated() { return 1; }'
  expect_mutant_caught no-progress-invalidation case_progress_marker_invalidates 'fm_nmc_invalidated() { return 1; }'
  expect_mutant_caught finished-always-valid case_finished_run_is_kept_until_the_id_changes 'fm_nmc_fin_valid() { return 0; }'
  expect_mutant_caught failure-kept-as-live case_failure_is_not_served_as_success 'fm_nmc_classify() { FM_NMC_CLASS=live; FM_NMC_FIN=-; }'
  # shellcheck disable=SC2016  # The override is source text appended to the copied library.
  expect_mutant_caught live-never-expires case_live_entry_expires 'fm_nmc_fresh() { fm_nmc_invalidated "$3" && return 1; return 0; }'
  expect_mutant_caught finished-needs-no-database case_finished_run_needs_the_database 'fm_nmc_fin_valid() { return 0; }'
}

main
