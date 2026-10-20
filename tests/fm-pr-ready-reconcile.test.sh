#!/usr/bin/env bash
# Automatic PR handoff: real registration, capacity release, bounded status
# reads, rotating admission, and per-head refusal memory in an isolated home.
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
    if [ -f "$FM_READY_CASE/draft" ]; then printf '{"isDraft":true}\n';
    else printf '{"isDraft":false}\n'; fi ;;
  *'--json headRefOid'*) git -C "$FM_READY_CASE/project" rev-parse HEAD ;;
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
exec "$REAL_TAIL" "$@"
SH
  chmod +x "$FAKEBIN/gh" "$FAKEBIN/tail"
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
    PATH="$FAKEBIN:$PATH" bash "$ROOT/bin/fm-pr-ready-reconcile.sh" 2>&1
}

occupancy() {
  local lock
  FM_HOME="$CASE/home"
  lock=$(fm_treehouse_project_lock_path "$CASE/project")
  fm_project_capacity_occupants "$lock" "$CASE/project" "$CASE/home/state" ignored || fail "$FM_PROJECT_CAPACITY_ERROR"
  printf '%s\n' "$FM_PROJECT_CAPACITY_OCCUPANTS"
}

assert_registered() {
  grep -qxF "pr=$URL" "$CASE/home/state/$1.meta" || fail "$1 PR not recorded: ${out:-}"
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

for rejection in draft unreachable unreadable-forge; do
  make_case "$rejection"
  write_ship ready ship direct-PR
  case "$rejection" in
    draft) : > "$CASE/draft" ;;
    unreadable-forge) : > "$CASE/unreadable-forge" ;;
  esac
  if [ "$rejection" != draft ]; then
    git -C "$CASE/project" commit -q --allow-empty -m unpublished
    HEAD=$(git -C "$CASE/project" rev-parse HEAD)
  fi
  before=$(shasum -a 256 "$CASE/home/state/ready.meta")
  out=$(run_pass)
  [ "$(printf '%s\n' "$out" | grep -c 'registration refused:')" -eq 1 ] || fail "$rejection refusal not printed exactly once"
  assert_unregistered ready
  [ "$before" = "$(shasum -a 256 "$CASE/home/state/ready.meta")" ] || fail "$rejection refusal changed record"
  calls_before=$(wc -l < "$CASE/gh.calls")
  [ -z "$(run_pass)" ] || fail "$rejection repeated refusal output"
  [ "$calls_before" -eq "$(wc -l < "$CASE/gh.calls")" ] || fail "$rejection retried same head"
  git -C "$CASE/project" commit -q --allow-empty -m next-head
  HEAD=$(git -C "$CASE/project" rev-parse HEAD)
  out=$(run_pass)
  [ "$(printf '%s\n' "$out" | grep -c 'registration refused:')" -eq 1 ] || fail "$rejection new head not retried"
  [ "$calls_before" -lt "$(wc -l < "$CASE/gh.calls")" ] || fail "$rejection new head never reached registration"
  pass "$rejection is refused once without mutation; same head stays quiet and new head retries"
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

make_case cap
for id in a b c d e f g h i j k; do write_ship "$id"; done
out=$(run_pass)
registered=$(grep -l '^pr=' "$CASE/home/state/"*.meta | wc -l)
[ "$registered" -eq 8 ] || fail "candidate cap was $registered instead of 8"
assert_unregistered i
out=$(run_pass)
for id in a b c d e f g h i j k; do assert_registered "$id"; done
pass 'fixed eight-record pass cap rotates fairly and later candidates register on the next pass'

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
FM_READY_CASE="$CASE" FM_ROOT_OVERRIDE="$CASE/root" FM_HOME="$CASE/home" \
  FM_STATE_OVERRIDE="$CASE/home/state" FM_CONFIG_OVERRIDE="$CASE/home/config" \
  FM_BACKEND=tmux FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 FM_IDLE_REAP_INTERVAL=0 FM_TYPESAFE_HEALTH_INTERVAL=0 \
  FM_LAVISH_AUTO_RETIRE_INTERVAL=0 PATH="$FAKEBIN:$PATH" \
  bash "$ROOT/bin/fm-watch.sh" > "$CASE/housekeeping.out" 2>&1 &
watch_pid=$!
fm_test_track_watcher_state "$CASE/home/state"
for ((i=0; i<600; i++)); do
  grep -q '^pr=' "$CASE/home/state/ready.meta" \
    && [ -f "$CASE/home/state/ready.check.sh" ] \
    && [ ! -d "$CASE/home/state/.pr-ready-reconcile/lock" ] && break
  sleep 0.1
done
kill -TERM "$watch_pid" 2>/dev/null || true
wait "$watch_pid" 2>/dev/null || true
out=$(cat "$CASE/housekeeping.out")
assert_registered ready
[ "$status_before" = "$(shasum -a 256 "$CASE/home/state/ready.status")" ] || fail 'housekeeping edited worker status'
pass 'real watcher registers ready PR before notification exit, without supervisor action or status edits'
