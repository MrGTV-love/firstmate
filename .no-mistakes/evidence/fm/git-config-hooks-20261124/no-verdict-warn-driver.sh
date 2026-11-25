#!/usr/bin/env bash
# Drive the real bin/fm-spawn.sh into an endpoint that never runs the staged
# launch (the suite's fake tmux endpoint), with FM_TEST_SEAM and
# FM_GIT_HOOKS_VERDICT_POLLS unset, so the production verdict bound applies.
# Usage: no-verdict-warn-driver.sh <firstmate-root>
set -u
. "$1/tests/lib.sh"; . "$1/tests/fixtures.sh"
unset FM_TEST_SEAM
T=$(fm_test_tmproot fm-noverdict) || exit 1
trap 'chmod -R u+w "$T" 2>/dev/null; fm_test_cleanup' EXIT
home=$T/home proj=$T/project wt=$T/wt id=noverdict-$$
fakebin=$(fm_test_make_spawn_fakebin "$T/fake")
fm_test_spawn_home "$home" omp
fm_test_spawn_brief "$home" "$id"
fm_git_worktree "$proj" "$wt" fixture-noverdict
start=$(date +%s)
out=$(env -u FM_TEST_SEAM -u FM_GIT_HOOKS_VERDICT_POLLS bash -c '. "$1/tests/lib.sh"; . "$1/tests/fixtures.sh"; unset FM_TEST_SEAM FM_GIT_HOOKS_VERDICT_POLLS; shift; fm_test_run_spawn "$@"' _ "$1" \
  "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off --harness omp)
status=$?
end=$(date +%s)
echo "spawn exit status: $status"
echo "seconds fm-spawn waited: $((end - start))"
echo "verdict warning lines:"; printf '%s\n' "$out" | grep -i 'verdict' | sed 's/^/  /'
echo "task record published: $([ -e "$home/state/$id.meta" ] && echo yes || echo no)"
rm -rf "/tmp/fm-$id" "/tmp/fm-$id+"* 2>/dev/null
