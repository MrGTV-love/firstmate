#!/usr/bin/env bash
# Automatic PR handoff: real registration, capacity release, bounded status
# reads, rotating eight-record admission, checks-green crew-state readings,
# refusal wakes, ten-minute refusal age-out, and a hard pass time limit in an
# isolated home.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$ROOT/bin/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-project-capacity-lib.sh
. "$ROOT/bin/fm-project-capacity-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pr-ready-reconcile)
fm_git_identity fmtest fmtest@example.invalid
REAL_TAIL=$(command -v tail)
export REAL_TAIL
URL=https://github.com/example/project/pull/42

make_case() {
  CASE="$TMP_ROOT/$1"
  mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/home/config" "$CASE/root/bin"
  FAKEBIN=$(fm_fakebin "$CASE")
  fm_git_init_commit "$CASE/project"
  fm_git_add_origin "$CASE/project" "$CASE/origin.git"
  HEAD=$(git -C "$CASE/project" rev-parse HEAD)
  git -C "$CASE/project" update-ref refs/remotes/origin/main "$HEAD"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE/root/bin/fm-guard.sh"
  chmod +x "$CASE/root/bin/fm-guard.sh"
  fm_fake_exit0 "$FAKEBIN" gh-axi no-mistakes
  cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_READY_CASE/gh.calls"
[ ! -f "$FM_READY_CASE/unreadable-forge" ] || exit 1
case "$*" in
  *'--json isDraft'*)
    if [ -f "$FM_READY_CASE/hang-always" ] && [[ "$*" = *'/pull/42 '* ]]; then
      printf '%s\n' "$$" >> "$FM_READY_CASE/persistent-hung.pids"
      exec sleep 600
    fi
    if [ -f "$FM_READY_CASE/hang-once" ]; then
      rm -f "$FM_READY_CASE/hang-once"
      printf '%s\n' "$$" > "$FM_READY_CASE/hung.pid"
      exec sleep 600
    fi
    if [ -f "$FM_READY_CASE/draft" ]; then printf '{"isDraft":true}\n';
    else printf '{"isDraft":false}\n'; fi ;;
  *'--json headRefOid'*)
    if [ -f "$FM_READY_CASE/forge-head" ]; then cat "$FM_READY_CASE/forge-head";
    else git -C "$FM_READY_CASE/project" rev-parse HEAD; fi ;;
  *) printf '[]\n' ;;
esac
SH
  cat > "$FAKEBIN/tail" <<'SH'
#!/usr/bin/env bash
case "${@: -1}" in
  *.status)
    printf '%s\n' "$*" >> "$FM_READY_CASE/tail.calls"
    [ "$1" = -c ] && [ "$2" = 65536 ] || exit 90 ;;
esac
# Ubuntu 26.04's uutils 0.10.0 tail reads a seekable file backwards in 64 KiB
# blocks and sizes the final block as size % 65536, so `-n` on a file of exactly
# 64 KiB reads an empty block and prints nothing. Reproduce it on every host.
if [ "$1" = -n ] && [ "$#" -eq 3 ] && [ -f "$3" ] && [ "$(wc -c < "$3")" -eq 65536 ]; then
  exit 0
fi
exec "$REAL_TAIL" "$@"
SH
  cat > "$FAKEBIN/fm-crew-state" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_READY_CASE/crew-state.calls"
if [ -f "$FM_READY_CASE/crew-state-hang.$1" ]; then
  printf '%s\n' "$$" > "$FM_READY_CASE/crew-state-hung.pid"
  exec sleep 600
fi
if [ -f "$FM_READY_CASE/crew-state.$1" ]; then cat "$FM_READY_CASE/crew-state.$1";
else printf 'state: working · source: run-step · validating (running) · run: 01RUN\n'; fi
SH
  chmod +x "$FAKEBIN/gh" "$FAKEBIN/tail" "$FAKEBIN/fm-crew-state"
  : > "$CASE/gh.calls"
}

write_ship() {  # <id> [kind] [mode]
  local id=$1
  fm_write_meta "$CASE/home/state/$id.meta" "kind=${2:-ship}" "mode=${3:-no-mistakes}" \
    "project=$CASE/project" "worktree=$CASE/project" "branch=main"
  printf 'done [at=1792479210]: PR %s checks green at %s\n' "$URL" "$HEAD" \
    > "$CASE/home/state/$id.status"
}

run_pass() {
  FM_READY_CASE="$CASE" FM_ROOT_OVERRIDE="$CASE/root" FM_HOME="$CASE/home" \
    FM_STATE_OVERRIDE="$CASE/home/state" FM_CONFIG_OVERRIDE="$CASE/home/config" \
    FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state" \
    PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-pr-ready-reconcile.sh" 2>&1
}

refusal_wakes() {  # <id>
  [ -f "$CASE/home/state/.wake-queue" ] || { echo 0; return; }
  awk -F '\t' -v key="pr-ready-refused:$1" '$3 == "check" && $4 == key' \
    "$CASE/home/state/.wake-queue" | wc -l | tr -d ' '
}

start_watcher() {  # [VAR=value...]
  env FM_READY_CASE="$CASE" FM_ROOT_OVERRIDE="$CASE/root" FM_HOME="$CASE/home" \
    FM_STATE_OVERRIDE="$CASE/home/state" FM_CONFIG_OVERRIDE="$CASE/home/config" \
    FM_BACKEND=tmux FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
    FM_CHECK_INTERVAL=999999 FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 \
    FM_LAVISH_AUTO_RETIRE_INTERVAL=0 PATH="$FAKEBIN:$PATH" "$@" \
    bash "$ROOT/bin/fm-watch.sh" > "$CASE/housekeeping.out" 2>&1 &
  watch_pid=$!
  fm_test_track_watcher_state "$CASE/home/state"
}

stop_watcher() {
  kill -TERM "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" 2>/dev/null || true
  out=$(cat "$CASE/housekeeping.out")
}

occupancy() {
  local lock
  FM_HOME="$CASE/home"
  lock=$(fm_treehouse_project_lock_path "$CASE/project")
  fm_project_capacity_occupants "$lock" "$CASE/project" "$CASE/home/state" ignored || fail "$FM_PROJECT_CAPACITY_ERROR"
  printf '%s\n' "$FM_PROJECT_CAPACITY_OCCUPANTS"
}

age_refusal() {  # <id> <seconds>
  fm_touch_epoch "$(($(date +%s) - $2))" "$CASE/home/state/.pr-ready-reconcile/$1.refused"
}

assert_registered() {
  grep -qxF "pr=${2:-$URL}" "$CASE/home/state/$1.meta" || fail "$1 PR not recorded: ${out:-}"
  grep -qxF "pr_head=$HEAD" "$CASE/home/state/$1.meta" || fail "$1 head not recorded"
  # Static poll scripts are private 0600 data, not executable custom checks.
  [ -f "$CASE/home/state/$1.check.sh" ] || fail "$1 merge poll not armed"
  ( . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_poll_artifacts_valid "$CASE/home/state" "$1" "$ROOT/bin/fm-pr-poll.sh"
  ) || fail "$1 merge poll registration is invalid"
}

assert_unregistered() {
  ! grep -q '^pr=' "$CASE/home/state/$1.meta" || fail "$1 unexpectedly registered"
  [ ! -e "$CASE/home/state/$1.check.sh" ] || fail "$1 unexpectedly armed"
}

# Use the same hard-bound runner as watcher housekeeping, with a forge that
# hangs on every attempt for the first ship, not just once.
make_case persistent-hang
write_ship a-hung
write_ship b-ready
printf 'done: PR https://github.com/example/project/pull/43 checks green\n' \
  > "$CASE/home/state/b-ready.status"
: > "$CASE/hang-always"
for attempt in 1 2; do
  rc=0
  fm_run_timed 10 env FM_READY_CASE="$CASE" FM_ROOT_OVERRIDE="$CASE/root" \
    FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" \
    FM_CONFIG_OVERRIDE="$CASE/home/config" PATH="$FAKEBIN:$PATH" \
    bash "$ROOT/bin/fm-pr-ready-reconcile.sh" > "$CASE/pass-$attempt.out" 2>&1 || rc=$?
  fm_timed_out "$rc" || fail "persistent hang pass $attempt did not hit its bound: $rc"
done
out=$(cat "$CASE/pass-2.out")
[ "$(wc -l < "$CASE/persistent-hung.pids")" -eq 2 ] || fail 'forge did not persistently hang in both passes'
while IFS= read -r hung_pid; do
  ! kill -0 "$hung_pid" 2>/dev/null || fail 'persistent forge process survived pass timeout'
done < "$CASE/persistent-hung.pids"
assert_unregistered a-hung
assert_registered b-ready https://github.com/example/project/pull/43
pass 'persistent early forge hang cannot starve a later healthy ship across bounded passes'

make_case age-out
write_ship ready
printf 'done: PR %s checks green\n' "$URL" > "$CASE/home/state/ready.status"
: > "$CASE/draft"
out=$(run_pass)
assert_unregistered ready
[ "$(printf '%s\n' "$out" | grep -c 'registration refused:')" -eq 1 ] || fail 'initial refusal missing'
[ "$(refusal_wakes ready)" -eq 1 ] || fail 'refusal did not queue exactly one check wake'
awk -F '\t' '$4 == "pr-ready-refused:ready"' "$CASE/home/state/.wake-queue" | grep -q "registration of $URL refused: .*draft" \
  || fail 'refusal wake does not name the PR and the draft reason'
age_refusal ready 660
out=$(run_pass)
[ "$(printf '%s\n' "$out" | grep -c 'registration refused:')" -eq 1 ] || fail 'aged refusal was not retried'
[ "$(refusal_wakes ready)" -eq 1 ] || fail 'the same refusal reason queued a second wake'
# The worker marks the PR ready without moving the copy: the head is unchanged.
rm "$CASE/draft"
calls_before=$(wc -l < "$CASE/gh.calls")
age_refusal ready 540
[ -z "$(run_pass)" ] || fail 'fresh refusal repeated output'
[ "$calls_before" -eq "$(wc -l < "$CASE/gh.calls")" ] || fail 'fresh refusal reached the forge'
assert_unregistered ready
age_refusal ready 660
out=$(run_pass)
[ "$HEAD" = "$(git -C "$CASE/project" rev-parse HEAD)" ] || fail 'fixture moved worker HEAD'
assert_registered ready
[ ! -e "$CASE/home/state/.pr-ready-reconcile/ready.refused" ] || fail 'registered task kept its refusal marker'
pass 'refusal queues one check wake per reason, skips the forge for ten minutes, then registers once the cause healed at the same head'

# fm-pr-check.sh runs fm-guard.sh before its gate, and the guard's banner
# changes from pass to pass; only the registrar's own refusal is the reason.
make_case guard-banner
write_ship ready ship direct-PR
git -C "$CASE/project" commit -q --allow-empty -m unpublished
cat > "$CASE/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
n=$(($(cat "$FM_READY_CASE/guard.count" 2>/dev/null || echo 0) + 1))
printf '%s\n' "$n" > "$FM_READY_CASE/guard.count"
printf 'WARNING: watcher still down (banner %s)\n' "$n" >&2
SH
out=$(run_pass)
assert_unregistered ready
[ "$(refusal_wakes ready)" -eq 1 ] || fail 'unreachable head did not queue exactly one check wake'
age_refusal ready 660
out=$(run_pass)
[ "$(cat "$CASE/guard.count")" -eq 2 ] || fail 'aged refusal did not reach the registrar again'
[ "$(refusal_wakes ready)" -eq 1 ] || fail "a changed guard banner queued a second wake for the same refusal: $out"
! grep -q 'banner' "$CASE/home/state/.wake-queue" || fail 'guard banner leaked into the refusal wake'
printf '%s\n' "$out" | grep -q 'registration refused: error: ' || fail "refusal line does not carry the registrar error: $out"
pass 'a changing fm-guard.sh banner neither re-wakes the same refusal nor enters its reason'

# The 2026-10-20 shape: the run is green and names its PR, but the worker never
# wrote a done line, so only fm-crew-state.sh's reading says the PR is ready.
make_case crew-state-green
write_ship ready
write_ship nolog
write_ship busy
write_ship direct ship direct-PR
for id in ready busy direct; do
  printf 'working [at=1792479210]: validating with /no-mistakes\n' > "$CASE/home/state/$id.status"
done
rm "$CASE/home/state/nolog.status"
for pair in ready:180 nolog:181 direct:187; do
  printf 'state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close): https://github.com/example/project/pull/%s · run: 01RUN\n' \
    "${pair#*:}" > "$CASE/crew-state.${pair%%:*}"
done
before=$(occupancy)
out=$(run_pass)
assert_registered ready https://github.com/example/project/pull/180
assert_registered nolog https://github.com/example/project/pull/181
assert_unregistered busy
assert_unregistered direct
[ "$before" -eq "$(($(occupancy) + 2))" ] || fail 'checks-green registration did not release one place per ship'
! grep -qx direct "$CASE/crew-state.calls" || fail 'direct-PR ship consulted the no-mistakes run reading'
calls_before=$(wc -l < "$CASE/crew-state.calls")
out=$(run_pass)
[ "$calls_before" -eq "$(($(wc -l < "$CASE/crew-state.calls") - 1))" ] || fail 'second pass did not re-read only the unready ship'
pass 'a green no-mistakes run with no done line registers from its fm-crew-state.sh PR; a busy run and a direct-PR lane do not'

# The real fm-crew-state.sh reading: CI turned green once, then main advanced
# far more often than no-mistakes' 40-line log tail holds. The green marker is
# only in the full log, and the ship must still register.
make_case crew-state-green-rearmed
write_ship ready
rm "$CASE/home/state/ready.status"
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'axi '|'axi status') cat "$FM_READY_CASE/nm-status" ;;
  'axi logs')
    case " $* " in
      *' --full '*) cat "$FM_READY_CASE/nm-ci.log" ;;
      *) "$REAL_TAIL" -n 40 "$FM_READY_CASE/nm-ci.log" ;;
    esac ;;
  'daemon '*) printf 'daemon running (pid 4242)\n' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/no-mistakes"
cat > "$CASE/nm-status" <<EOF
run:
  id: "01RUN"
  branch: main
  status: running
  head: "$HEAD"
  pr: "https://github.com/example/project/pull/192"
  findings: none
  steps[4]{step,status,findings,duration_ms}:
    intent,completed,0,0
    review,completed,0,0
    push,completed,0,0
    ci,running,0,0
EOF
{
  printf 'monitoring CI for PR #192 (timeout: 4h0m0s)...\n'
  printf 'all CI checks passed - still monitoring until merged or closed\n'
  for i in $(seq 1 60); do
    printf 'base branch advanced (%07d..%07d), re-arming CI monitor timeout\n' "$i" "$((i + 1))"
  done
} > "$CASE/nm-ci.log"
before=$(occupancy)
out=$(FM_READY_CASE="$CASE" FM_ROOT_OVERRIDE="$CASE/root" FM_HOME="$CASE/home" \
  FM_STATE_OVERRIDE="$CASE/home/state" FM_CONFIG_OVERRIDE="$CASE/home/config" \
  PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-pr-ready-reconcile.sh" 2>&1)
assert_registered ready https://github.com/example/project/pull/192
[ "$before" -eq "$(($(occupancy) + 1))" ] || fail 'green run past the log tail did not release its place'
pass 'a green run whose marker is 60 base-advance lines back still registers through the real crew-state reading'

# A run reading that never answers is cut at its own bound and skipped, so the
# ready ship after it still registers in the same pass.
make_case crew-state-hang
write_ship a-slow
write_ship b-ready
printf 'working [at=1792479210]: validating with /no-mistakes\n' > "$CASE/home/state/a-slow.status"
: > "$CASE/crew-state-hang.a-slow"
rc=0
fm_run_timed 60 env FM_READY_CASE="$CASE" FM_ROOT_OVERRIDE="$CASE/root" \
  FM_HOME="$CASE/home" FM_STATE_OVERRIDE="$CASE/home/state" \
  FM_CONFIG_OVERRIDE="$CASE/home/config" FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state" \
  PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-pr-ready-reconcile.sh" > "$CASE/pass.out" 2>&1 || rc=$?
out=$(cat "$CASE/pass.out")
[ "$rc" -eq 0 ] || fail "pass with a hung run reading did not finish on its own: $rc $out"
[ "$(printf '%s\n' "$out" | grep -c 'a-slow: run reading exceeded 10s; skipped this pass')" -eq 1 ] \
  || fail "hung run reading was not reported once: $out"
! kill -0 "$(cat "$CASE/crew-state-hung.pid")" 2>/dev/null || fail 'hung run reading outlived its bound'
assert_unregistered a-slow
assert_registered b-ready
pass 'a hung run reading is cut at its own bound and the later ready ship registers in the same pass'

make_case registration
write_ship ready
before=$(occupancy)
out=$(run_pass)
assert_registered ready
after=$(occupancy)
[ "$before" -eq "$((after + 1))" ] || fail "capacity did not fall by exactly one"
meta_before=$(shasum -a 256 "$CASE/home/state/ready.meta" "$CASE/home/state/ready.check.sh")
calls_before=$(wc -l < "$CASE/gh.calls")
[ -z "$(run_pass)" ] || fail 'second pass was not silent'
[ "$meta_before" = "$(shasum -a 256 "$CASE/home/state/ready.meta" "$CASE/home/state/ready.check.sh")" ] || fail 'second pass changed registration'
[ "$calls_before" -eq "$(wc -l < "$CASE/gh.calls")" ] || fail 'already registered PR queried again'
pass 'ready PR records pr/head, arms merge poll, releases exactly one place; second pass changes nothing'

make_case eligibility
write_ship scout scout
write_ship mate secondmate
write_ship local ship local-only
write_ship direct ship direct-PR
printf 'done [at=1792479210]: PR %s\n' "$URL" > "$CASE/home/state/direct.status"
write_ship pending
printf 'working: PR %s checks green is the eventual outcome\n' "$URL" > "$CASE/home/state/pending.status"
write_ship draft-wait
printf 'paused: PR %s checks green but deliberately held draft\n' "$URL" > "$CASE/home/state/draft-wait.status"
out=$(run_pass)
assert_registered direct
for id in scout mate local pending draft-wait; do assert_unregistered "$id"; done
pass 'direct-PR ready ship registers; scouts, secondmates, local-only, progress and draft waits are skipped'

make_case newest
write_ship ready
printf 'done: PR https://github.com/example/project/pull/43 checks green at %s\nresolved [key=review]: approval recorded\n' "$HEAD" \
  >> "$CASE/home/state/ready.status"
out=$(run_pass)
grep -qx 'pr=https://github.com/example/project/pull/43' "$CASE/home/state/ready.meta" || fail 'old ready signal won'
pass 'newest ready signal wins over an older PR and survives later resolution notes'

make_case declared-pr
write_ship ready
printf 'done: PR https://github.com/example/project/pull/195 checks green; follows up https://github.com/example/project/pull/180\n' \
  > "$CASE/home/state/ready.status"
out=$(run_pass)
assert_registered ready https://github.com/example/project/pull/195
! grep -q 'pull/180' "$CASE/home/state/ready.meta" || fail 'unrelated PR recorded'
pass 'the declared PR registers even when the note names another PR after it'

make_case leading-url
write_ship ready
printf 'done: follows up https://github.com/example/project/pull/180 - PR https://github.com/example/project/pull/195 checks green\n' \
  > "$CASE/home/state/ready.status"
out=$(run_pass)
assert_unregistered ready
[ -z "$out" ] || fail "malformed note produced output: $out"
[ ! -s "$CASE/gh.calls" ] || fail 'malformed note reached the forge'
pass 'a note that does not open with PR <url> registers no PR, least of all an unrelated leading one'

for rejection in draft unreachable unreadable-forge; do
  make_case "$rejection"
  mode=direct-PR
  [ "$rejection" != unreadable-forge ] || mode=no-mistakes
  write_ship ready ship "$mode"
  [ "$rejection" != draft ] || : > "$CASE/draft"
  if [ "$rejection" != draft ]; then
    git -C "$CASE/project" commit -q --allow-empty -m unpublished
    HEAD=$(git -C "$CASE/project" rev-parse HEAD)
  fi
  [ "$rejection" != unreadable-forge ] || : > "$CASE/unreadable-forge"
  before=$(shasum -a 256 "$CASE/home/state/ready.meta")
  out=$(run_pass)
  [ "$(printf '%s\n' "$out" | grep -c 'registration refused:')" -eq 1 ] || fail "$rejection refusal not printed exactly once"
  assert_unregistered ready
  [ "$before" = "$(shasum -a 256 "$CASE/home/state/ready.meta")" ] || fail "$rejection refusal changed record"
  calls_before=$(wc -l < "$CASE/gh.calls")
  [ -z "$(run_pass)" ] || fail "$rejection repeated refusal output"
  [ "$calls_before" -eq "$(wc -l < "$CASE/gh.calls")" ] || fail "$rejection retried inside the interval"
  case "$rejection" in
    draft) rm "$CASE/draft" ;;
    unreadable-forge) rm "$CASE/unreadable-forge" ;;
    unreachable) git -C "$CASE/project" update-ref refs/remotes/origin/main "$HEAD" ;;
  esac
  age_refusal ready 540
  [ -z "$(run_pass)" ] || fail "$rejection healed cause retried inside the interval"
  assert_unregistered ready
  age_refusal ready 660
  out=$(run_pass)
  assert_registered ready
  pass "$rejection is refused once without mutation, stays quiet for ten minutes, then registers at the same head"
done

make_case bounded
write_ship huge
printf 'done: PR %s checks green\n' "$URL" > "$CASE/home/state/huge.status"
awk 'BEGIN { for (i=0; i<200000; i++) print "continuation prose without any event" }' >> "$CASE/home/state/huge.status"
started=$SECONDS
out=$(run_pass)
[ "$((SECONDS - started))" -lt 60 ] || fail 'large log exceeded 60-second fixture bound'
assert_unregistered huge
grep -q -- '-c 65536 .*huge.status' "$CASE/tail.calls" || fail 'large log was not tail-bounded'
printf 'done [at=1792479210]: PR %s checks green at %s\n' "$URL" "$HEAD" >> "$CASE/home/state/huge.status"
out=$(run_pass)
assert_registered huge
[ "$((SECONDS - started))" -lt 60 ] || fail 'large-log ready registration exceeded 60-second fixture bound'
pass '200,000-line log uses only its bounded tail; old ready outside tail is ignored and new ready registers within 60s'

make_case capped-candidates
for id in a b c d e f g h i j k; do write_ship "$id"; done
before=$(occupancy)
out=$(run_pass)
for id in a b c d e f g h; do assert_registered "$id"; done
for id in i j k; do assert_unregistered "$id"; done
[ "$(wc -l < "$CASE/tail.calls")" -eq 8 ] || fail 'pass read more than eight status logs'
[ "$before" -eq "$(($(occupancy) + 8))" ] || fail 'first pass did not release exactly eight places'
out=$(run_pass)
for id in a b c d e f g h i j k; do assert_registered "$id"; done
[ "$before" -eq "$(($(occupancy) + 11))" ] || fail 'capacity did not fall by one per ship'
pass 'eight-record admission cap rotates fairly so later candidates register on the next pass'

make_case unreadable
write_ship a-record
write_ship b-log
write_ship c-ready
rm "$CASE/home/state/a-record.meta" "$CASE/home/state/b-log.status"
mkdir "$CASE/home/state/a-record.meta" "$CASE/home/state/b-log.status"
out=$(run_pass)
[ "$(printf '%s\n' "$out" | grep -c 'unreadable task record; skipped')" -eq 1 ] || fail 'unreadable record not reported once'
[ "$(printf '%s\n' "$out" | grep -c 'unreadable status log; skipped')" -eq 1 ] || fail 'unreadable log not reported once'
assert_registered c-ready
pass 'unreadable task record and log each report once without stopping the pass'

# Real watcher housekeeping entry point, with fixture forge and an isolated home.
make_case housekeeping
write_ship ready
fm_fake_exit0 "$FAKEBIN" tmux
status_before=$(shasum -a 256 "$CASE/home/state/ready.status")
start_watcher
for ((i=0; i<600; i++)); do
  grep -q '^pr=' "$CASE/home/state/ready.meta" \
    && [ -f "$CASE/home/state/ready.check.sh" ] \
    && [ ! -d "$CASE/home/state/.pr-ready-reconcile/lock" ] && break
  sleep 0.1
done
stop_watcher
assert_registered ready
[ "$status_before" = "$(shasum -a 256 "$CASE/home/state/ready.status")" ] || fail 'housekeeping edited worker status'
pass 'real watcher registers ready PR before notification exit, without supervisor action or status edits'

# A forge call that never returns must die with its pass, so a re-armed
# watcher's next tick can register the ready ship instead of every ship holding
# its place behind a pass that never ends. The watcher exits on the ready wake;
# the bounded pass outlives it, exactly as in production.
make_case hung-forge
write_ship ready
fm_fake_exit0 "$FAKEBIN" tmux
: > "$CASE/hang-once"
start_watcher FM_PR_READY_RECONCILE_TIMEOUT=2
for ((i=0; i<300; i++)); do [ -s "$CASE/hung.pid" ] && break; sleep 0.1; done
[ -s "$CASE/hung.pid" ] || { stop_watcher; fail 'registration pass never reached the hung forge call'; }
hung_pid=$(cat "$CASE/hung.pid")
for ((i=0; i<300; i++)); do kill -0 "$hung_pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$hung_pid" 2>/dev/null; then
  kill -KILL "$hung_pid" 2>/dev/null || true
  stop_watcher
  fail 'hung forge call outlived the pass limit'
fi
stop_watcher
assert_unregistered ready
start_watcher FM_PR_READY_RECONCILE_TIMEOUT=2
for ((i=0; i<600; i++)); do
  grep -q '^pr=' "$CASE/home/state/ready.meta" \
    && [ -f "$CASE/home/state/ready.check.sh" ] \
    && [ ! -d "$CASE/home/state/.pr-ready-reconcile/lock" ] && break
  sleep 0.1
done
stop_watcher
assert_registered ready
pass 'hung forge call is killed at the pass limit and the next watcher tick registers the ready ship'
