#!/usr/bin/env bash
. "$(dirname "$0")/lab.sh"
lab_reset; lab_init; lab_tmux_start
out_begin S2-fallback-closeout-refusal-ignored-files-and-nested-copy
say "### S2: teardown refuses with the closeout driver's text (SEAM: exact line from bin/fm-teardown-nested-lib.sh; everything after it is real). The copy is squash-merged (tree == main), has scratch ignored files, a preserved bug-evidence record and a clean pushed orphan nested clone. The fallback proves it, keeps the records, ends the pane's shell, REAL treehouse destroys the slot."
mkworld ign 120 || exit 1
mkdir -p "$WT/.claude/bug-evidence" "$WT/node_modules/x"
printf 'closeout\n' > "$WT/.claude/bug-evidence/slot.json"; printf x > "$WT/node_modules/x/i.js"
n=$WT/.claude/worktrees/n1; git clone -q "$W/origin.git" "$n" 2>/dev/null
seam_refuse closeout
prune "$W" arm ign --run; say "arm exit=$?"
for i in $(seq 1 120); do grep -q 'reaped\|retained' "$DATA/ign/merge-prune.log" 2>/dev/null && break; sleep 1; done
sleep 2
dump_world ign
say "--- preserved records:"; (cd "$DATA/ign/merge-prune-preserved" 2>/dev/null && find . -type f | sort) | tee -a "$OUT"
check "S2 teardown first refused with the closeout driver's exact-tree text" grep -q "exact tree not covered" "$W/td.log.out"
check "S2 slot destroyed (gone from disk)" test ! -e "$WT"
check "S2 real treehouse destroy called once, as the reaper does" bash -c "grep -qx 'destroy $WT --include-leased --yes' '$W/th.log' && [ \"\$(grep -c '^destroy ' '$W/th.log')\" = 1 ]"
check "S2 nothing forced" nothing_forced ign
check "S2 task record closed after the fallback" test ! -e "$STATE/ign.meta"
check "S2 preserved bug-evidence record copied with a checksum before removal" bash -c "find '$DATA/ign/merge-prune-preserved' -name slot.json | grep -q . && find '$DATA/ign/merge-prune-preserved' -name SHA256SUMS | grep -q ."
check "S2 no wake" test "$(wake_count ign)" = 0
check "S2 pane window still open when the second teardown began (only its idle shell was ended)" grep -q 'copy_present=no tmux_windows=\[anchor fm-ign \]' "$W/td.log"
finish
