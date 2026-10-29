#!/usr/bin/env bash
# Drive the real bin/fm-pr-ready-reconcile.sh (and the real bin/fm-crew-state.sh
# it calls) on the "green run past the log tail" case from
# tests/fm-pr-ready-reconcile.test.sh, in a disposable home, with three
# no-mistakes status shapes:
#   old       - the pre-fix fixture: no head_sha and no verification_plan block
#   new       - the fixed fixture: head_sha plus a verification_plan snapshot
#   tampered  - the fixed fixture, but the snapshot bytes no longer match sha256
# Only the fake forge (gh) and fake no-mistakes CLI are stand-ins; the
# reconcile and crew-state code is the real product at <root>.
# Usage: drive-ready-reconcile.sh <repo-root> old|new|tampered
set -eu
ROOT_ARG=$1 SHAPE=$2
# shellcheck source=/dev/null
. "$ROOT_ARG/tests/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-drive-ready)
fm_git_identity fmtest fmtest@example.invalid
REAL_TAIL=$(command -v tail); export REAL_TAIL
CASE="$TMP_ROOT/case"
mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/home/config" "$CASE/root/bin"
FAKEBIN=$(fm_fakebin "$CASE")
fm_git_init_commit "$CASE/project"
fm_git_add_origin "$CASE/project" "$CASE/origin.git"
HEAD=$(git -C "$CASE/project" rev-parse HEAD)
git -C "$CASE/project" update-ref refs/remotes/origin/main "$HEAD"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE/root/bin/fm-guard.sh"; chmod +x "$CASE/root/bin/fm-guard.sh"
fm_fake_exit0 "$FAKEBIN" gh-axi
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'--json isDraft'*) printf '{"isDraft":false}\n' ;;
  *'--json headRefOid'*) git -C "$FM_READY_CASE/project" rev-parse HEAD ;;
  *) printf '[]\n' ;;
esac
SH
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
chmod +x "$FAKEBIN/gh" "$FAKEBIN/no-mistakes"
fm_write_meta "$CASE/home/state/ready.meta" kind=ship mode=no-mistakes \
  "project=$CASE/project" "worktree=$CASE/project" branch=main
mkdir -p "$CASE/home/data/ready"
PLAN="$CASE/home/data/ready/verification-plan.md"
printf 'ready fixture verification plan\n' > "$PLAN"
plan_sha=$(shasum -a 256 "$PLAN" | awk '{print $1}')
{
  printf 'run:\n  id: "01RUN"\n  branch: main\n  status: running\n  head: "%s"\n' "$HEAD"
  [ "$SHAPE" = old ] || printf '  head_sha: %s\n' "$HEAD"
  printf '  pr: "https://github.com/example/project/pull/192"\n  findings: none\n'
  if [ "$SHAPE" != old ]; then
    printf '  verification_plan:\n    path: %s\n    sha256: %s\n    source_path: %s\n    captured_at: %s\n' \
      "$PLAN" "$plan_sha" "$PLAN" "$(date +%s)"
  fi
  printf '  steps[4]{step,status,findings,duration_ms}:\n    intent,completed,0,0\n    review,completed,0,0\n    push,completed,0,0\n    ci,running,0,0\n'
} > "$CASE/nm-status"
[ "$SHAPE" != tampered ] || printf 'edited after capture\n' >> "$PLAN"
{
  printf 'monitoring CI for PR #192 (timeout: 4h0m0s)...\n'
  printf 'all CI checks passed - still monitoring until merged or closed\n'
  for i in $(seq 1 60); do printf 'base branch advanced (%07d..%07d), re-arming CI monitor timeout\n' "$i" "$((i + 1))"; done
} > "$CASE/nm-ci.log"
env_run() {
  env FM_READY_CASE="$CASE" FM_ROOT_OVERRIDE="$CASE/root" FM_HOME="$CASE/home" \
    FM_STATE_OVERRIDE="$CASE/home/state" FM_CONFIG_OVERRIDE="$CASE/home/config" \
    PATH="$FAKEBIN:$PATH" "$@"
}
echo "--- shape=$SHAPE: real bin/fm-crew-state.sh ready"
env_run bash "$ROOT_ARG/bin/fm-crew-state.sh" ready 2>&1 || true
echo "--- shape=$SHAPE: real bin/fm-pr-ready-reconcile.sh"
env_run bash "$ROOT_ARG/bin/fm-pr-ready-reconcile.sh" 2>&1 || echo "(reconcile exit $?)"
echo "--- shape=$SHAPE: resulting ready.meta pr/pr_head lines"
grep -E '^(pr|pr_head)=' "$CASE/home/state/ready.meta" || echo "(no pr= line: ready PR not recorded)"
