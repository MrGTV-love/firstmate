#!/usr/bin/env bash
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S9-untracked-file-hidden-by-git-config
say "### S9 (adversarial, review round 9): status.showUntrackedFiles=no hides an untracked file from a plain 'git status --porcelain'. The file appears right after teardown's own dirt check (SEAM), so only the fallback's proof can stop the removal. The copy must be kept with one wake, and the file must survive."
mkworld hid 150 || exit 1
git -C "$W/proj" config status.showUntrackedFiles no
seam_refuse not-landed
export UNTRACKED_AFTER_FIRST=1
prune "$W" arm hid; prune "$W" run hid --now; prune "$W" run hid --now
unset UNTRACKED_AFTER_FIRST
say "plain 'git status --porcelain' in the copy prints: [$(git -C "$WT" status --porcelain)]  (hidden by config)"
say "'git status --porcelain --untracked-files=all' prints: [$(git -C "$WT" status --porcelain --untracked-files=all)]"
dump_world hid
say "record: $(sed -n 's/^reason=//p' "$STATE/hid.merge-prune" | sed "s#$LAB#<LAB>#g")"
check "S9 the late file is hidden from the plain status (the trap is set)" test -z "$(git -C "$WT" status --porcelain)"
check "S9 copy kept, the untracked file still there" test -f "$WT/late-untracked.txt"
check "S9 task record kept" test -e "$STATE/hid.meta"
check "S9 treehouse destroy never called" test "$(destroy_calls hid)" = 0
check "S9 agent not stopped" test ! -s "$W/ctl.log"
check "S9 exactly one wake after two attempts" test "$(wake_count hid)" = 1
check "S9 the reason names changed or untracked files" grep -q 'changed or untracked files' "$STATE/hid.merge-prune"
check "S9 nothing forced" nothing_forced hid
finish
