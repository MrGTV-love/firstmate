#!/usr/bin/env bash
# S6 (adversarial): copies that must never reach the driver stay registered with
# unchanged lock bytes: live launcher, foreign lock, dirty, unpushed, and a real
# process whose cwd is inside (seen by the real lsof). One clean dead-launcher
# copy is released in the same run. The sweep's own git calls are logged and
# must hold no unlock, lock, --force or -f.
set -u
. "$(dirname "$0")/live-lab-lib.sh"
new_world s6
echo "LAB=$W"
for n in live foreign dirty unpushed proc good; do add_copy "$n"; done
(cd "$W" && exec sleep 600) & LIVE=$!
git -C "$SLOT" worktree lock --reason "vernant-session-active owner=launcher:$LIVE launcher=$LIVE" "$(cp_ live)"
git -C "$SLOT" worktree lock --reason 'hand-held by an operator' "$(cp_ foreign)"
for n in dirty unpushed proc good; do lock_dead "$n"; done
printf 'work in progress\n' > "$(cp_ dirty)/untracked.txt"
printf 'local only\n' > "$(cp_ unpushed)/local.txt"
git -C "$(cp_ unpushed)" add local.txt && git -C "$(cp_ unpushed)" commit -qm 'local only'
(cd "$(cp_ proc)" && exec sleep 600) & INSIDE=$!
sleep 1
lockhash() { shasum -a 256 "$(git -C "$(cp_ "$1")" rev-parse --absolute-git-dir)/locked" | awk '{print $1}'; }
for n in live foreign dirty unpushed proc; do eval "before_$n=$(lockhash "$n")"; done
git_logger
sweep --apply; echo "rc=$?"
echo "--- driver calls (closeout.log):"; cat "$CTL/closeout.log" 2>/dev/null | sed "s|$W|<LAB>|g"
for n in live foreign dirty unpushed proc; do
  b=$(eval echo "\$before_$n")
  printf '%s registered=%s lock-unchanged=%s\n' "$n" "$(registered "$n" && echo yes || echo no)" "$([ "$b" = "$(lockhash "$n")" ] && echo yes || echo NO)"
done
printf 'good registered=%s\n' "$(registered good && echo yes || echo no)"
echo "--- sweep's own git calls total: $(wc -l < "$W/sweep-git.log" | tr -d ' ')"
echo "--- forbidden sweep git calls (worktree lock/unlock, --force, -f, -ff):"
grep -E 'worktree (unlock|lock)|(^| )(--force|-ff?)( |$)' "$W/sweep-git.log" || echo "(none)"
echo "--- sweep's own 'worktree remove' calls: $(grep -c 'worktree remove' "$W/sweep-git.log")"
kill "$LIVE" "$INSIDE" 2>/dev/null; wait 2>/dev/null
rm -rf "$W"; echo "lab removed"
