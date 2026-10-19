#!/usr/bin/env bash
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S6-busy-worker-and-plain-tree
say "### S6: a worker that turns busy is not stopped; the attempt backs off, silently"
mkworld busy 130 || exit 1
printf 'v1 gen=g1.1.1 seq=2 state=busy source=claude-hook event=UserPromptSubmit ts=%s\n' "$(date +%s)" > "$STATE/busy.busy-state"
prune "$W" arm busy; prune "$W" run busy --now
dump_world busy
say "record: $(tr '\n' '|' < "$STATE/busy.merge-prune")"
check "S6 busy worker still running" kill -0 "$WORKER"
check "S6 no stop (exit verb) was sent" test ! -s "$W/ctl.log"
check "S6 nothing destroyed, copy and record kept" bash -c "[ -e '$WT' ] && [ -e '$STATE/busy.meta' ] && [ \"\$(grep -c '^destroy ' '$W/th.log')\" = 0 ]"
check "S6 record is pending with one attempt" bash -c "grep -qx 'state=pending' '$STATE/busy.merge-prune' && grep -qx 'attempts=1' '$STATE/busy.merge-prune'"
check "S6 silent: no wake" test "$(wake_count busy)" = 0
check "S6 window still open" bash -c "TMUX_TMPDIR='$TMUXDIR' tmux -L fm-lab list-windows -t firstmate -F '#W' | grep -qx fm-busy"
say ""
say "### S7: a plain git tree at <root>/a/b/c is not a pool copy: kept, one wake, nothing stopped or destroyed (needs the fallback to run: SEAM not-landed refusal)"
mkworld plain 131 || exit 1
P=$LAB/w-plain/th/a/b/c; mkdir -p "$(dirname "$P")"; git clone -q "$W/origin.git" "$P" 2>/dev/null; git -C "$P" checkout -q -b fm/plain origin/fm/plain
sed -i.bak "s#^worktree=.*#worktree=$P#" "$STATE/plain.meta"; rm -f "$STATE/plain.meta.bak"
seam_refuse not-landed
prune "$W" arm plain; prune "$W" run plain --now; prune "$W" run plain --now
dump_world plain
check "S7 plain tree kept" test -e "$P"
check "S7 nothing destroyed" test "$(destroy_calls plain)" = 0
check "S7 exactly one wake" test "$(wake_count plain)" = 1
check "S7 wake says it is not a pool slot" bash -c "grep 'merge-prune:plain' '$STATE/.wake-queue' | grep -q 'not a Treehouse pool slot'"
check "S7 no stop was sent" test ! -s "$W/ctl.log"
finish
