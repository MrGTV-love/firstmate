#!/usr/bin/env bash
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S6b-worker-steered-after-teardown-answered
say "### S6b: teardown answers 'not landed' (SEAM line), then the captain steers the worker. The fallback asks again whether the worker is finished: nothing is stopped, signalled or destroyed; the attempt backs off silently"
mkworld steer 132 || exit 1
seam_refuse not-landed
export STEER_AFTER_FIRST=1
prune "$W" arm steer; prune "$W" run steer --now
unset STEER_AFTER_FIRST
dump_world steer
say "record: $(tr '\n' '|' < "$STATE/steer.merge-prune")"
check "S6b worker still running" kill -0 "$WORKER"
check "S6b no stop (exit verb) was sent" test ! -s "$W/ctl.log"
check "S6b nothing destroyed, copy and record kept" bash -c "[ -e '$WT' ] && [ -e '$STATE/steer.meta' ] && [ \"\$(grep -c '^destroy ' '$W/th.log')\" = 0 ]"
check "S6b record is pending (backed off), not retained" bash -c "grep -qx 'state=pending' '$STATE/steer.merge-prune' && grep -qx 'attempts=1' '$STATE/steer.merge-prune'"
check "S6b the reason says the worker is not finished" grep -q 'automatic reap ineligible' "$STATE/steer.merge-prune"
check "S6b silent: no wake" test "$(wake_count steer)" = 0
check "S6b pane shell and window untouched" bash -c "TMUX_TMPDIR='$TMUXDIR' tmux -L fm-lab list-windows -t firstmate -F '#W' | grep -qx fm-steer"
finish
