#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-contribution-cleanup)
cp -R "$ROOT/bin" "$TMP_ROOT/bin"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$TMP_ROOT/audit.bash" <<'SH'
kill() {
  case "${1:-}" in
    -0) ;;
    *) printf '%s\n' "$*" >> "$FM_TEST_KILLS" ;;
  esac
  builtin kill "$@"
}
SH
cat > "$TMP_ROOT/bin/fm-contributions.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_TEST_CONTRIBUTION_PID"
case "$FM_TEST_CLEANUP_CASE" in
  active-early) exec sleep 30 ;;
  failed-wait) exit 7 ;;
esac
exec "$FM_TEST_REAL_CONTRIBUTIONS" "$@"
SH
cat > "$FAKEBIN/cp" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    "$FM_HOME/state/task.meta")
      deadline=$((SECONDS + 10))
      while [ ! -s "$FM_TEST_CONTRIBUTION_PID" ]; do
        [ "$SECONDS" -lt "$deadline" ] || exit 90
        sleep 0.02
      done
      pid=$(cat "$FM_TEST_CONTRIBUTION_PID")
      if [ "$FM_TEST_CLEANUP_CASE" = completed-early ]; then
        while kill -0 "$pid" 2>/dev/null; do
          [ "$SECONDS" -lt "$deadline" ] || exit 91
          sleep 0.02
        done
      fi
      exit 1
      ;;
  esac
done
exec /bin/cp "$@"
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$TMP_ROOT/bin/fm-contributions.sh" "$FAKEBIN/cp" "$FAKEBIN/no-mistakes"

run_case() {
  local name=$1 mode=$2 home pid rc=0
  home=$TMP_ROOT/$name-${mode#--}
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  case "$name" in
    *-early) fm_write_meta "$home/state/task.meta" 'kind=ship' ;;
  esac
  : > "$home/kills"
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    BASH_ENV="$TMP_ROOT/audit.bash" FM_TEST_KILLS="$home/kills" \
    FM_TEST_CONTRIBUTION_PID="$home/contribution-pid" FM_TEST_CLEANUP_CASE="$name" \
    FM_TEST_REAL_CONTRIBUTIONS="$ROOT/bin/fm-contributions.sh" \
    "$TMP_ROOT/bin/fm-fleet-snapshot.sh" "$mode" > "$home/out" 2> "$home/err" || rc=$?
  pid=$(cat "$home/contribution-pid")
  case "$name" in
    active-early)
      [ "$rc" -eq 1 ] || fail "$name returned $rc instead of 1"
      [ "$(cat "$home/kills")" = "$pid" ] || fail "$name did not signal only its running contribution"
      deadline=$((SECONDS + 5))
      while kill -0 "$pid" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
          kill "$pid" 2>/dev/null || true
          fail "$name left its contribution running"
        fi
        sleep 0.02
      done
      ;;
    completed-early|failed-wait)
      [ "$rc" -eq 1 ] || fail "$name returned $rc instead of 1"
      [ ! -s "$home/kills" ] || fail "$name signalled a completed contribution"
      if [ "$name" = failed-wait ]; then
        assert_contains "$(cat "$home/err")" 'contribution coverage unavailable' 'failed contribution lost its error'
      else
        assert_contains "$(cat "$home/err")" 'task observation failed' 'early failure missed the observation boundary'
      fi
      ;;
    success)
      [ "$rc" -eq 0 ] || fail "$name $mode failed: $(cat "$home/err")"
      [ ! -s "$home/kills" ] || fail "$name signalled its consumed contribution"
      case "$mode" in
        --json) schema=fm-fleet-snapshot.v1 ;;
        --secondmate-home-summary) schema=fm-secondmate-home-summary.v1 ;;
      esac
      jq -e --arg schema "$schema" '.schema == $schema and .contributions.known == 0' "$home/out" >/dev/null \
        || fail "$name $mode changed the output contract"
      ;;
  esac
  pass "$name $mode preserves contribution job ownership"
}

run_case completed-early --secondmate-home-summary
run_case active-early --secondmate-home-summary
for mode in --json --secondmate-home-summary; do
  run_case failed-wait "$mode"
  run_case success "$mode"
done
