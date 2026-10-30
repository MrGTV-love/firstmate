#!/usr/bin/env bash
# Behavior tests for the scratch entries Firstmate commands make in the shared
# temp dir (bin/fm-scratch-lib.sh owns the naming and the reaping).
#
# What this pins: fm-timeout-status, fm-gh-rest, fm-remote-reply-ingest,
# fm-contributions, fm-session-start-stage, fm-lavish-poll and fm-test-reap
# entries piled up by the thousand in a shared temp dir (2663, 784, 328, 325, 294,
# 179 and 140 measured on 2026-10-28), because a command that is KILLed runs no
# trap and nothing ever removed what it left. Each command below, run with its
# own empty TMPDIR, must leave nothing after a normal run, an error exit, and
# TERM, INT and HUP; and the next run must remove the entry a killed owner left
# while keeping the entry of an owner that is still alive.
# The bash -c scripts below expand their own variables in the child shell.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-scratch-leaks)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
SIGNALS="TERM INT HUP"

new_tmp() {
  mktemp -d "$TMP_ROOT/tmp.XXXXXX" || fail "cannot make a fresh TMPDIR"
}

entries() {  # <dir>: its immediate entries, one per line
  find "$1" -mindepth 1 -maxdepth 1 2>/dev/null
}

assert_clean() {  # <tmpdir> <what>
  [ -z "$(entries "$1")" ] || fail "$2 left an entry in TMPDIR: $(cd "$1" && find . -mindepth 1 | tr '\n' ' ')"
}

wait_for_file() {  # <path>
  local tries=0
  while [ ! -s "$1" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 600 ] || fail "timed out waiting for $1"
    sleep 0.05
  done
}

# A pid that has ended: the owner a KILLed command would have named.
dead_pid() {
  bash -c 'printf "%s" "$$"'
}

plant() {  # <tmpdir> <prefix> <f|d> <pid>: an entry owned by <pid>, as fm_scratch_new names it
  local entry="$1/$2.scratch/$4.PLANT1"
  mkdir -p "$1/$2.scratch"
  if [ "$3" = d ]; then mkdir "$entry"; : > "$entry/payload"; else : > "$entry"; fi
}

# signal_status <signal>: the wait status a command gives when the signal ends
# it through the default action or a trap that re-raises it; - for INT, which
# ends some of them with their own error status once the helper is gone.
signal_status() {
  case "$1" in TERM) echo 143 ;; HUP) echo 129 ;; *) echo - ;; esac
}

# stall_signal <tmpdir> <signal> <status> <pidfile> <command...>: run the
# command with TMPDIR=<tmpdir> until it records the stalled helper's pid in
# <pidfile>, then send the signal to the command and stop the helper. <status>
# is the exact wait status the command must give, or - for only the first two
# checks below.
stall_signal() {
  local tmp=$1 sig=$2 want=$3 pidfile=$4 cmd_pid helper_pid tries=0
  shift 4
  rm -f "$pidfile"
  # perl restores the default SIGINT that a shell's background job ignores.
  TMPDIR="$tmp" perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$@" >/dev/null 2>&1 &
  cmd_pid=$!
  wait_for_file "$pidfile"
  helper_pid=$(cat "$pidfile")
  [ -n "$(entries "$tmp")" ] || fail "a command stalled before it held a scratch entry, so $sig would prove nothing"
  kill -"$sig" "$cmd_pid" 2>/dev/null || true
  # Retirement signals the whole process group, helper included; a shell that
  # holds a trap runs it only once its foreground helper has ended.
  kill -"$sig" "$helper_pid" 2>/dev/null || true
  while kill -0 "$helper_pid" 2>/dev/null && [ "$tries" -lt 20 ]; do tries=$((tries + 1)); sleep 0.05; done
  kill -KILL "$helper_pid" 2>/dev/null || true
  wait "$cmd_pid" 2>/dev/null
  STALL_STATUS=$?
  # The command must have ended because of the signal: not as a success, not by
  # a KILL (137: it never ran its trap), and with the exit status it gives that
  # signal.
  [ "$STALL_STATUS" -ne 0 ] && [ "$STALL_STATUS" -ne 137 ] \
    || fail "a command sent $sig ended with wait status $STALL_STATUS instead of by its signal handling"
  [ "$want" = - ] || [ "$STALL_STATUS" -eq "$want" ] \
    || fail "a command sent $sig ended with wait status $STALL_STATUS, not $want"
  # Let a surviving subshell of the command notice that its helper is gone.
  sleep 0.3
}

# check_reaps_dead_owner <what> <prefix> <f|d> <run-function>
check_reaps_dead_owner() {
  local what=$1 prefix=$2 kind=$3 runner=$4 tmp dead live
  tmp=$(new_tmp)
  dead=$(dead_pid)
  sleep 300 &
  live=$!
  plant "$tmp" "$prefix" "$kind" "$dead"
  plant "$tmp" "$prefix" "$kind" "$live"
  "$runner" "$tmp" >/dev/null 2>&1 || true
  kill -KILL "$live" 2>/dev/null || true
  assert_absent "$tmp/$prefix.scratch/$dead.PLANT1" \
    "$what did not remove the entry a killed owner left"
  assert_present "$tmp/$prefix.scratch/$live.PLANT1" \
    "$what removed the entry of an owner that is still running"
  pass "$what removes what a killed owner left and keeps a live owner's entry"
}

# --- fm-gh-rest ---------------------------------------------------------------
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "${FAKE_GH_MODE:-ok}" in
  ok)
    printf 'HTTP/2.0 200 OK\r\nETag: "abc"\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4999\r\nX-Ratelimit-Reset: 4102444800\r\nX-Ratelimit-Resource: core\r\n\r\n[1]'
    ;;
  fail)
    printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{"message":"bad gateway"}'
    exit 1
    ;;
  stall)
    printf '%s\n' "$$" > "$FAKE_STALL_PIDFILE"
    exec sleep 120
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

run_gh_rest() {  # <tmpdir> [mode]
  env TMPDIR="$1" FAKE_GH_MODE="${2:-ok}" FM_STATE_OVERRIDE="$TMP_ROOT/gh-state" PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/fm-gh-rest.sh" get repos/o/r/items
}

test_gh_rest() {
  local tmp sig
  tmp=$(new_tmp)
  run_gh_rest "$tmp" ok >/dev/null || fail "fm-gh-rest get failed on a healthy forge"
  assert_clean "$tmp" "a normal fm-gh-rest read"
  run_gh_rest "$tmp" fail >/dev/null 2>&1 && fail "fm-gh-rest hid a forge error"
  assert_clean "$tmp" "an fm-gh-rest read that exited on a forge error"
  for sig in $SIGNALS; do
    stall_signal "$tmp" "$sig" "$(signal_status "$sig")" "$TMP_ROOT/gh.pid" env FAKE_GH_MODE=stall FAKE_STALL_PIDFILE="$TMP_ROOT/gh.pid" \
      FM_STATE_OVERRIDE="$TMP_ROOT/gh-state" PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-gh-rest.sh" get repos/o/r/items
    assert_clean "$tmp" "an fm-gh-rest read ended by $sig"
  done
  check_reaps_dead_owner "fm-gh-rest" fm-gh-rest d run_gh_rest
  pass "fm-gh-rest leaves no entry after a normal run, an error exit, TERM, INT or HUP"
}

# --- fm-timeout-lib (fm-timeout-status) ---------------------------------------
mkdir -p "$TMP_ROOT/timeout-bin"
printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$TMP_ROOT/timeout-bin/timeout"
chmod +x "$TMP_ROOT/timeout-bin/timeout"

run_timeout() {  # <tmpdir>
  env TMPDIR="$1" bash -c '
    . "$1/bin/fm-timeout-lib.sh"
    PATH="$2:$PATH"
    fm_run_timed 20 true
  ' _ "$ROOT" "$TMP_ROOT/timeout-bin"
}

test_timeout_status() {
  local tmp
  tmp=$(new_tmp)
  run_timeout "$tmp" || fail "a bounded call failed"
  assert_clean "$tmp" "a normal bounded call"
  # The signalled exits of the caller are pinned by tests/fm-timeout-lib.test.sh.
  check_reaps_dead_owner "fm_run_timed" fm-timeout-status f run_timeout
}

# --- fm-contributions ---------------------------------------------------------
REAL_JQ=$(command -v jq || true)
# The stall comes on the slurp of the saved records, after the command holds its
# scratch dir and its traps; the clock read before them goes through.
cat > "$FAKEBIN/jq" <<SH
#!/usr/bin/env bash
if [ -n "\${FAKE_STALL_PIDFILE:-}" ] && [ "\${1-}" = -s ]; then
  printf '%s\n' "\$\$" > "\$FAKE_STALL_PIDFILE"
  exec sleep 120
fi
exec "$REAL_JQ" "\$@"
SH
chmod +x "$FAKEBIN/jq"

run_contributions() {  # <tmpdir> [subcommand]
  env TMPDIR="$1" FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-contributions.sh" "${2:-pending}"
}

test_contributions() {
  local tmp sig
  [ -n "$REAL_JQ" ] || { echo "skip: jq not found"; return 0; }
  tmp=$(new_tmp)
  run_contributions "$tmp" pending >/dev/null || fail "fm-contributions pending failed"
  assert_clean "$tmp" "a normal fm-contributions run"
  run_contributions "$tmp" no-such-subcommand >/dev/null 2>&1 && fail "fm-contributions accepted an unknown subcommand"
  assert_clean "$tmp" "an fm-contributions run that exited on an error"
  for sig in $SIGNALS; do
    stall_signal "$tmp" "$sig" 1 "$TMP_ROOT/jq.pid" env FAKE_STALL_PIDFILE="$TMP_ROOT/jq.pid" \
      FM_HOME="$HOME_DIR" PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-contributions.sh" pending
    assert_clean "$tmp" "an fm-contributions run ended by $sig"
  done
  check_reaps_dead_owner "fm-contributions" fm-contributions d run_contributions
  pass "fm-contributions leaves no entry after a normal run, an error exit, TERM, INT or HUP"
}

# --- fm-procevent-remote-reply.sh ingest (fm-remote-reply-ingest) -------------
make_result() {  # <path> <payload>
  local payload=$2 hash empty size
  hash=$(printf '%s' "$payload" | shasum -a 256 | awk '{print $1}')
  empty=$(printf '' | shasum -a 256 | awk '{print $1}')
  size=${#payload}
  printf 'schema=fm-remote-delta.v1\nstatus=delta\npath=state/parent-replies.status\nfrom_offset=0\nto_offset=%s\nfrom_prefix_sha256=%s\nto_prefix_sha256=%s\npayload_sha256=%s\npayload_bytes=%s\nreason=ok\n\n%s' \
    "$size" "$empty" "$hash" "$hash" "$size" "$payload" > "$1"
}

run_ingest() {  # <tmpdir> [result]
  local home
  home=$(mktemp -d "$TMP_ROOT/ingest-home.XXXXXX")
  mkdir -p "$home/state" "$home/data"
  env TMPDIR="$1" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/fm-procevent-remote-reply.sh" ingest ios "${2:-$TMP_ROOT/result.good}"
}

test_remote_reply_ingest() {
  local tmp sig empty out
  tmp=$(new_tmp)
  make_result "$TMP_ROOT/result.good" $'working: remote check\n'
  make_result "$TMP_ROOT/result.bad" $'working: remote check\n'
  # A payload that no longer matches its committed digest is an error exit after
  # the staging directory exists.
  sed -i.bak 's/remote check/forged check_/' "$TMP_ROOT/result.bad"
  run_ingest "$tmp" >/dev/null || fail "a valid remote reply did not ingest"
  assert_clean "$tmp" "a normal remote reply ingest"
  run_ingest "$tmp" "$TMP_ROOT/result.bad" >/dev/null 2>&1 && fail "a forged remote reply ingested"
  assert_clean "$tmp" "a remote reply ingest that exited on an error"
  empty=$(printf '' | shasum -a 256 | awk '{print $1}')
  printf 'schema=fm-remote-delta.v1\nstatus=continuity-broken\npath=state/parent-replies.status\nfrom_offset=0\nto_offset=0\nfrom_prefix_sha256=%s\nto_prefix_sha256=%s\npayload_sha256=%s\npayload_bytes=0\nreason=truncated\n\n' \
    "$empty" "$empty" "$empty" > "$TMP_ROOT/result.broken"
  out=$(run_ingest "$tmp" "$TMP_ROOT/result.broken" 2>&1) && fail "a continuity break ingested as a delta"
  assert_contains "$out" "continuity-broken: ios" "the continuity break was not handled: $out"
  assert_clean "$tmp" "a remote reply ingest that handled a continuity break"
  cat > "$FAKEBIN/tail" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_STALL_PIDFILE:-}" ]; then
  printf '%s\n' "$$" > "$FAKE_STALL_PIDFILE"
  exec sleep 120
fi
exec /usr/bin/tail "$@"
SH
  chmod +x "$FAKEBIN/tail"
  for sig in $SIGNALS; do
    mkdir -p "$TMP_ROOT/sig-home/state" "$TMP_ROOT/sig-home/data"
    stall_signal "$tmp" "$sig" "$(signal_status "$sig")" "$TMP_ROOT/tail.pid" env FAKE_STALL_PIDFILE="$TMP_ROOT/tail.pid" \
      FM_HOME="$TMP_ROOT/sig-home" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKEBIN:$PATH" \
      bash "$ROOT/bin/fm-procevent-remote-reply.sh" ingest ios "$TMP_ROOT/result.good"
    assert_clean "$tmp" "a remote reply ingest ended by $sig"
  done
  rm -f "$FAKEBIN/tail"
  check_reaps_dead_owner "fm-procevent-remote-reply ingest" fm-remote-reply-ingest d run_ingest
  pass "remote reply ingest leaves no entry after a normal run, an error exit, TERM, INT or HUP"
}

# --- fm-session-start.sh (fm-session-start-stage) -----------------------------
run_session_start() {  # <tmpdir> [timeout-seconds]
  env TMPDIR="$1" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SESSION_START_TIMEOUT="${2:-60}" \
    bash "$ROOT/bin/fm-session-start.sh"
}

# The stage file proof stands alone: bootstrap's deferred network helpers
# (fm-startup-network*, outside this change) make and remove their own entries
# on their own schedule, and the whole-TMPDIR checks below see those too.
assert_no_stage_file() {  # <tmpdir> <what>
  [ -z "$(find "$1" -name 'fm-session-start-stage*' 2>/dev/null)" ] \
    || fail "$2 left a session start stage entry: $(find "$1" -name 'fm-session-start-stage*' | tr '\n' ' ')"
}

test_session_start() {
  local tmp sig started=0 pid bound_out
  tmp=$(new_tmp)
  run_session_start "$tmp" 60 >/dev/null 2>&1 || fail "a session start failed on an empty home"
  assert_no_stage_file "$tmp" "a normal session start"
  # Bootstrap's deferred network checks run on after the digest is out and make
  # their own entries; they finish by themselves.
  while [ -n "$(entries "$tmp")" ] && [ "$started" -lt 200 ]; do started=$((started + 1)); sleep 0.1; done
  assert_clean "$tmp" "a normal session start"
  bound_out=$(run_session_start "$tmp" 1 2>&1)
  assert_contains "$bound_out" 'STARTUP TRUNCATED' "a one-second bound did not truncate the digest"
  assert_no_stage_file "$tmp" "a session start whose runtime bound fired"
  assert_clean "$tmp" "a session start whose runtime bound fired"
  for sig in $SIGNALS; do
    TMPDIR="$tmp" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SESSION_START_TIMEOUT=60 \
      perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' bash "$ROOT/bin/fm-session-start.sh" >/dev/null 2>&1 &
    pid=$!
    started=0
    # The child writes its first stage only after the parent holds its trap.
    while [ -z "$(find "$tmp/fm-session-start-stage.scratch" -type f -size +0 2>/dev/null)" ] && [ "$started" -lt 200 ]; do
      started=$((started + 1))
      sleep 0.05
    done
    [ -n "$(find "$tmp/fm-session-start-stage.scratch" -type f -size +0 2>/dev/null)" ] || fail "the session start never wrote its stage file"
    kill -"$sig" "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ ! -d "$tmp/fm-session-start-stage.scratch" ] || fail "a session start ended by $sig left its stage file: $(entries "$tmp/fm-session-start-stage.scratch")"
    # The digest's child outlives its parent briefly; it must not recreate the file.
    sleep 0.5
  done
  check_reaps_dead_owner "fm-session-start" fm-session-start-stage f run_session_start
  pass "fm-session-start leaves no stage file after a normal run, a fired bound, TERM, INT or HUP"
}

# --- fm-procevent-lavish.sh poll (fm-lavish-poll) -----------------------------
LAVISH_STATE="$TMP_ROOT/lavish-state"
mkdir -p "$LAVISH_STATE"
ARTIFACT="$TMP_ROOT/board.html"
printf '<h1>board</h1>\n' > "$ARTIFACT"
perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -MEncode=decode -e '
  my ($path, $artifact) = @ARGV;
  my $real = realpath($artifact) // die "missing artifact";
  my $key = substr(sha256_hex($real), 0, 16);
  open my $out, ">", $path or die $!;
  print $out encode_json({ sessions => { $key => { key => $key, file => decode("UTF-8", $real), status => "open",
    url => "http://127.0.0.1:14387/session/0123456789abcdef" } } });
' "$LAVISH_STATE/state.json" "$ARTIFACT"
cat > "$FAKEBIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = poll ] || exit 2
case "${FAKE_LAVISH_MODE:-feedback}" in
  feedback) printf 'session:\n  status: feedback\nprompts[1]{tag,prompt}:\n  message,answer\n' ;;
  error) printf 'error: Lavish Editor server connection failed\ncode: VALIDATION_ERROR\n'; exit 1 ;;
  stall)
    printf '%s\n' "$$" > "$FAKE_STALL_PIDFILE"
    exec sleep 120
    ;;
esac
SH
chmod +x "$FAKEBIN/lavish-axi"

run_lavish_poll() {  # <tmpdir> [mode]
  env TMPDIR="$1" FAKE_LAVISH_MODE="${2:-feedback}" FM_HOME="$HOME_DIR" LAVISH_AXI_STATE_DIR="$LAVISH_STATE" \
    FM_LAVISH_POLL_RETRY_DELAY=1 PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-procevent-lavish.sh" poll "$ARTIFACT"
}

test_lavish_poll() {
  local tmp sig
  tmp=$(new_tmp)
  run_lavish_poll "$tmp" feedback >/dev/null 2>&1 || fail "a lavish poll that returned feedback failed"
  assert_clean "$tmp" "a normal lavish poll"
  run_lavish_poll "$tmp" error >/dev/null 2>&1 && fail "a lavish poll hid a CLI error"
  assert_clean "$tmp" "a lavish poll that exited on a CLI error"
  for sig in $SIGNALS; do
    stall_signal "$tmp" "$sig" "$(signal_status "$sig")" "$TMP_ROOT/lavish.pid" env FAKE_LAVISH_MODE=stall FAKE_STALL_PIDFILE="$TMP_ROOT/lavish.pid" \
      FM_HOME="$HOME_DIR" LAVISH_AXI_STATE_DIR="$LAVISH_STATE" FM_LAVISH_POLL_RETRY_DELAY=1 PATH="$FAKEBIN:$PATH" \
      bash "$ROOT/bin/fm-procevent-lavish.sh" poll "$ARTIFACT"
    assert_clean "$tmp" "a lavish poll ended by $sig"
  done
  check_reaps_dead_owner "fm-procevent-lavish poll" fm-lavish-poll f run_lavish_poll
  pass "a lavish poll leaves no response file after a normal run, an error exit, TERM, INT or HUP"
}

# --- fm-test-reap-orphans.sh (fm-test-reap) -----------------------------------
# A root whose marker names a dead owner makes the reaper allocate its working
# directory; a sweep that finds nothing must allocate nothing.
make_dead_root() {  # <parent>
  local root
  root=$(mktemp -d "$1/fm-dead-root.XXXXXX")
  printf '%s\nno-such-identity\n' "$(dead_pid)" > "$root/.fm-test-fixture"
  printf '%s\n' "$root"
}

run_reaper() {  # <tmpdir>
  env TMPDIR="$1" bash "$ROOT/bin/fm-test-reap-orphans.sh" --tmpdir "$TMP_ROOT/reaper-scan"
}

test_reaper() {
  local tmp sig
  tmp=$(new_tmp)
  mkdir -p "$TMP_ROOT/reaper-scan"
  run_reaper "$tmp" >/dev/null 2>&1 || fail "the reaper failed on an empty scan directory"
  assert_clean "$tmp" "a reaper sweep that found nothing"
  make_dead_root "$TMP_ROOT/reaper-scan" >/dev/null
  # Whether the process list can be read depends on the host; the working
  # directory must be gone either way.
  run_reaper "$tmp" >/dev/null 2>&1 || true
  assert_clean "$tmp" "a normal reaper sweep"
  # An error exit after the working directory exists: a process list that cannot
  # be read. The fake ps records what the reaper had made by the time it ran, so
  # the case proves the allocation happened before the error.
  cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
find "$TMPDIR" -mindepth 2 -maxdepth 2 > "$FAKE_PS_SEEN"
exit 1
SH
  chmod +x "$FAKEBIN/ps"
  rm -f "$TMP_ROOT/ps.seen"
  env TMPDIR="$tmp" FAKE_PS_SEEN="$TMP_ROOT/ps.seen" PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/fm-test-reap-orphans.sh" --tmpdir "$TMP_ROOT/reaper-scan" >/dev/null 2>&1 \
    && fail "the reaper reported success when the process list could not be read"
  [ -s "$TMP_ROOT/ps.seen" ] || fail "the reaper never made its working directory before the process list failed"
  assert_clean "$tmp" "a reaper run that exited on an error after making its working directory"
  rm -f "$FAKEBIN/ps"
  cat > "$FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FAKE_STALL_PIDFILE"
exec sleep 120
SH
  chmod +x "$FAKEBIN/ps"
  for sig in $SIGNALS; do
    stall_signal "$tmp" "$sig" "$(signal_status "$sig")" "$TMP_ROOT/ps.pid" env FAKE_STALL_PIDFILE="$TMP_ROOT/ps.pid" PATH="$FAKEBIN:$PATH" \
      bash "$ROOT/bin/fm-test-reap-orphans.sh" --tmpdir "$TMP_ROOT/reaper-scan"
    assert_clean "$tmp" "a reaper sweep ended by $sig"
  done
  rm -f "$FAKEBIN/ps"
  check_reaps_dead_owner "fm-test-reap-orphans" fm-test-reap d run_reaper
  pass "the reaper leaves no working directory after a normal run, an error exit, TERM, INT or HUP"
}

# --- fm-scratch-lib: the container it trusts and the empty-container race ------
scratch_new() {  # <tmpdir> <f|d> <prefix> [env...]
  local tmp=$1 kind=$2 prefix=$3
  shift 3
  env TMPDIR="$tmp" "$@" bash -c '. "$1"; fm_scratch_new "$2" "$3"' _ "$ROOT/bin/fm-scratch-lib.sh" "$kind" "$prefix"
}

test_scratch_lib() {
  local tmp outside dead path out
  # A container path that is a symlink is neither reaped through nor used.
  tmp=$(new_tmp)
  outside=$(new_tmp)
  dead=$(dead_pid)
  mkdir "$outside/$dead.PLANT1"
  ln -s "$outside" "$tmp/fm-gh-rest.scratch"
  path=$(scratch_new "$tmp" d fm-gh-rest) || fail "fm_scratch_new failed beside a symlinked container"
  assert_present "$outside/$dead.PLANT1" "the scratch reaper removed an entry through a symlinked container"
  case "$path" in "$tmp/fm-gh-rest."??????) ;; *) fail "fm_scratch_new used a symlinked container: $path" ;; esac
  [ -d "$path" ] && [ ! -L "$path" ] || fail "fm_scratch_new beside a symlinked container made no directory: $path"
  [ -z "$(find "$outside" -mindepth 1 -maxdepth 1 ! -name "$dead.PLANT1")" ] \
    || fail "fm_scratch_new wrote into the target of a symlinked container"

  # Another process's release removes the empty container between mkdir and
  # mktemp, three times in a row; the request must still succeed.
  tmp=$(new_tmp)
  mkdir -p "$TMP_ROOT/race-bin"
  cat > "$TMP_ROOT/race-bin/mktemp" <<'SH'
#!/usr/bin/env bash
n=$(cat "$RACE_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$RACE_COUNT"
if [ "$n" -lt 3 ]; then
  for last; do :; done
  rmdir "${last%/*}"
  exit 1
fi
exec "$RACE_REAL_MKTEMP" "$@"
SH
  chmod +x "$TMP_ROOT/race-bin/mktemp"
  rm -f "$TMP_ROOT/race-count"
  path=$(scratch_new "$tmp" f fm-timeout-status PATH="$TMP_ROOT/race-bin:$PATH" \
    RACE_COUNT="$TMP_ROOT/race-count" RACE_REAL_MKTEMP="$(command -v mktemp)") \
    || fail "fm_scratch_new failed when a concurrent release removed its empty container"
  assert_equals 4 "$(cat "$TMP_ROOT/race-count")" "the race fixture did not remove the container three times"
  case "$path" in "$tmp/fm-timeout-status.scratch/"*) ;; *) fail "fm_scratch_new made its entry elsewhere: $path" ;; esac
  assert_present "$path" "fm_scratch_new reported an entry it did not make"
  env TMPDIR="$tmp" bash -c '. "$1"; fm_scratch_release "$2"' _ "$ROOT/bin/fm-scratch-lib.sh" "$path"
  assert_clean "$tmp" "a released scratch entry"
  pass "fm_scratch_new never enters a symlinked container and survives a container removed under it"

  # A release removes the empty container and another caller makes it again,
  # both between this caller's mkdir and mktemp, three times in a row; the
  # request must still succeed in its container.
  tmp=$(new_tmp)
  mkdir -p "$TMP_ROOT/remake-bin"
  cat > "$TMP_ROOT/remake-bin/mktemp" <<'SH'
#!/usr/bin/env bash
n=$(cat "$RACE_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$RACE_COUNT"
if [ "$n" -lt 3 ]; then
  for last; do :; done
  rmdir "${last%/*}"
  mkdir -m 700 "${last%/*}"
  exit 1
fi
exec "$RACE_REAL_MKTEMP" "$@"
SH
  chmod +x "$TMP_ROOT/remake-bin/mktemp"
  rm -f "$TMP_ROOT/remake-count"
  path=$(scratch_new "$tmp" f fm-timeout-status PATH="$TMP_ROOT/remake-bin:$PATH" \
    RACE_COUNT="$TMP_ROOT/remake-count" RACE_REAL_MKTEMP="$(command -v mktemp)") \
    || fail "fm_scratch_new failed when a peer removed and remade its container under it"
  assert_equals 4 "$(cat "$TMP_ROOT/remake-count")" "the remake fixture did not race the container three times"
  case "$path" in "$tmp/fm-timeout-status.scratch/"*) ;; *) fail "fm_scratch_new made its entry elsewhere after a remade container: $path" ;; esac
  assert_present "$path" "fm_scratch_new reported an entry it did not make after a remade container"
  env TMPDIR="$tmp" bash -c '. "$1"; fm_scratch_release "$2"' _ "$ROOT/bin/fm-scratch-lib.sh" "$path"
  assert_clean "$tmp" "a scratch entry released after a remade container"

  # Many callers make and release entries of one prefix at once; every call
  # gets its entry and nothing is left.
  tmp=$(new_tmp)
  out=$(env TMPDIR="$tmp" bash -c '
    . "$1"
    for i in $(seq 1 24); do
      (
        for j in 1 2 3 4 5 6 7 8; do
          p=$(fm_scratch_new f fm-timeout-status) && [ -f "$p" ] || { echo miss; exit 1; }
          fm_scratch_release "$p"
        done
      ) &
    done
    wait' _ "$ROOT/bin/fm-scratch-lib.sh" 2>&1)
  [ -z "$out" ] || fail "parallel fm_scratch_new calls on one prefix did not all get an entry: $out"
  assert_clean "$tmp" "parallel scratch entries of one prefix"
  pass "fm_scratch_new survives a container removed and remade by peers under it"

  # Another user swaps the container for a symlink between the ownership check
  # and mktemp; the entry made through it is removed and never returned.
  tmp=$(new_tmp)
  outside=$(new_tmp)
  mkdir -p "$TMP_ROOT/swap-bin"
  cat > "$TMP_ROOT/swap-bin/mktemp" <<'SH'
#!/usr/bin/env bash
n=$(cat "$RACE_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((n + 1))" > "$RACE_COUNT"
if [ "$n" -eq 0 ]; then
  for last; do :; done
  rmdir "${last%/*}"
  ln -s "$SWAP_TARGET" "${last%/*}"
fi
exec "$RACE_REAL_MKTEMP" "$@"
SH
  chmod +x "$TMP_ROOT/swap-bin/mktemp"
  rm -f "$TMP_ROOT/swap-count"
  path=$(scratch_new "$tmp" f fm-timeout-status PATH="$TMP_ROOT/swap-bin:$PATH" SWAP_TARGET="$outside" \
    RACE_COUNT="$TMP_ROOT/swap-count" RACE_REAL_MKTEMP="$(command -v mktemp)") \
    || fail "fm_scratch_new failed when its container was swapped for a symlink under it"
  [ -z "$(entries "$outside")" ] || fail "fm_scratch_new left an entry in the target of a container swapped under it: $(entries "$outside")"
  case "$path" in "$tmp/fm-timeout-status."??????) ;; *) fail "fm_scratch_new returned a path through a container swapped under it: $path" ;; esac
  [ -f "$path" ] && [ ! -L "$path" ] || fail "fm_scratch_new after a swapped container made no file: $path"
  pass "fm_scratch_new never returns an entry made through a container swapped under it"

  # Another user plants the container as a symlink between the check and mkdir.
  tmp=$(new_tmp)
  outside=$(new_tmp)
  mkdir -p "$TMP_ROOT/plant-bin"
  cat > "$TMP_ROOT/plant-bin/mkdir" <<'SH'
#!/usr/bin/env bash
for last; do :; done
ln -s "$PLANT_TARGET" "$last"
SH
  chmod +x "$TMP_ROOT/plant-bin/mkdir"
  path=$(scratch_new "$tmp" f fm-timeout-status PATH="$TMP_ROOT/plant-bin:$PATH" PLANT_TARGET="$outside") \
    || fail "fm_scratch_new failed when its container was planted as a symlink"
  case "$path" in "$tmp/fm-timeout-status."??????) ;; *) fail "fm_scratch_new used a container planted as a symlink: $path" ;; esac
  [ -z "$(entries "$outside")" ] || fail "fm_scratch_new wrote into the target of a planted container"
  pass "fm_scratch_new checks the container it made, not only the path before mkdir"

  # A copy of fm-timeout-lib.sh or fm-gh-rest.sh without its sibling library
  # still runs its command and leaves nothing behind.
  tmp=$(new_tmp)
  mkdir -p "$TMP_ROOT/alone-bin"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$ROOT/bin/fm-gh-rest.sh" "$TMP_ROOT/alone-bin/"
  out=$(env TMPDIR="$tmp" bash -c '. "$1"; fm_run_timed 5 echo ran' _ "$TMP_ROOT/alone-bin/fm-timeout-lib.sh" 2>&1) \
    || fail "a lone copy of fm-timeout-lib.sh did not run its command: $out"
  assert_equals ran "$out" "a lone copy of fm-timeout-lib.sh printed more than its command's output"
  assert_clean "$tmp" "a bounded command run from a lone copy of fm-timeout-lib.sh"
  out=$(env TMPDIR="$tmp" FM_STATE_OVERRIDE="$TMP_ROOT/gh-state" PATH="$FAKEBIN:$PATH" \
    bash "$TMP_ROOT/alone-bin/fm-gh-rest.sh" get repos/o/r/items 2>&1) || fail "a lone copy of fm-gh-rest.sh failed: $out"
  assert_clean "$tmp" "a read through a lone copy of fm-gh-rest.sh"
  pass "lone copies of fm-timeout-lib.sh and fm-gh-rest.sh keep working without fm-scratch-lib.sh"
}

test_gh_rest
test_timeout_status
test_contributions
test_remote_reply_ingest
test_session_start
test_lavish_poll
test_reaper
test_scratch_lib
