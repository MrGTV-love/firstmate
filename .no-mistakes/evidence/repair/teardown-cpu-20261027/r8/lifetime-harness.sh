#!/usr/bin/env bash
# Run one lifetime regression case from r7/lifetime-block.sh against TREE's own
# product and tests/lib.sh, with the same fixtures tests/fm-home-summary-refresh.test.sh
# builds. Usage: lifetime-harness.sh TREE nested-bash|nested-default|held-worker|escape
set -u
TREE=$1 CASE=$2
BLOCK="$(cd "$(dirname "$0")" && pwd)/lifetime-block-head.sh"
# shellcheck disable=SC1091
. "$TREE/tests/lib.sh"
WRITER="$ROOT/bin/fm-home-summary-refresh.sh"
TMP_ROOT=$(fm_test_tmproot fm-r8-lifetime)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
harness_cleanup() {
  local hold reg
  for hold in ${LIFE_HOLDS:-}; do rm -f "$hold"; done
  for reg in ${LIFE_REGISTRIES:-}; do fm_test_wait_processes "$reg" || FM_TEST_WAIT_FAILED=1; done
  fm_test_cleanup
}
trap harness_cleanup EXIT
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'fixture pane\n> \n' ;;
esac
exit 0
SH
cat > "$FAKEBIN/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_TEST_NM_COUNT:-}" ]; then
  printf '.\n' >> "$FM_TEST_NM_COUNT"
fi
if [ -n "${FM_TEST_NM_HOLD:-}" ] && [ -e "$FM_TEST_NM_HOLD" ]; then
  printf '%s\n' "$$" > "$FM_TEST_NM_HOLD.entered"
  while [ -e "$FM_TEST_NM_HOLD" ]; do sleep 0.1; done
fi
if [ -n "${FM_TEST_NM_MARKER:-}" ]; then
  printf '%s\n' "$$" > "$FM_TEST_NM_MARKER"
  sleep "${FM_TEST_NM_SLEEP:-30}"
fi
exit 0
SH
chmod +x "$FAKEBIN/tmux" "$FAKEBIN/no-mistakes"
new_bare_home() {  # <name> -> prints the home path
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '# Seeded Firstmate home\n' > "$home/AGENTS.md"
  printf '%s\n' "$1" > "$home/.fm-secondmate-home"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' "$home"
}
COALESCE_HOME=$(new_bare_home coalesce-home)
printf '## In flight\n- [ ] co-task - Coalesce triggers (repo: firstmate) (kind: ship) (since 2026-08-28)\n\n## Queued\n\n## Done\n' \
  > "$COALESCE_HOME/data/backlog.md"
mkdir -p "$COALESCE_HOME/projects/task"
fm_git_init_commit "$COALESCE_HOME/projects/task"
fm_write_meta "$COALESCE_HOME/state/co-task.meta" \
  "window=fmtest:fm-co-task" "worktree=$COALESCE_HOME/projects/task" \
  "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes" "spawn_gen=fm.coalesce1234"
co_busy_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$COALESCE_HOME/state" co-task)
"$ROOT/bin/fm-busy-event.sh" apply "$COALESCE_HOME/state" co-task idle \
  --gen "$co_busy_gen" --source claude-hook --event stop
sed '/^nested_mode_case bash$/,$d' "$BLOCK" > "$TMP_ROOT/block-functions.sh"
# shellcheck disable=SC1090,SC1091
. "$TMP_ROOT/block-functions.sh"
case "$CASE" in
  nested-bash) nested_mode_case bash ;;
  nested-default) nested_mode_case default ;;
  held-worker) held_worker_case ;;
  escape) escape_case ;;
esac
pass "$CASE"
