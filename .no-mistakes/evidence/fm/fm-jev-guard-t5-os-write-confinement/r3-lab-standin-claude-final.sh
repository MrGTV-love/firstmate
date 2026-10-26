#!/bin/bash
# Model-free stand-in for the claude harness (run 2): attacks a real other task (t5lab1).
printf "%s\n" "$*" > /private/tmp/fm-lab.XGfLMG/argv.${FM_TASK_ID:-none} 2>/dev/null
case "${1:-}" in --version) echo '2.1.310 (Claude Code)'; exit 0 ;; esac
OWN=t5lab2 OTHER=t5lab1 H='/private/tmp/fm-lab.XGfLMG/home' U='/private/tmp/fm-lab.XGfLMG/user-home'
[ "${FM_TASK_INBOX:-}" = "$H/state/$OWN.inbox" ] || exit 0
out=${PROBE_OUT:-$H/data/$OWN/probe.txt}
try() { if ( eval "$2" ) </dev/null >/dev/null 2>&1; then r=ok; else r=refused; fi; printf '%-62s -> %s\n' "$1" "$r"; }
{
echo "FM_WRITE_CONFINEMENT=${FM_WRITE_CONFINEMENT:-unset} TMPDIR=$TMPDIR cwd=$(pwd -P)"
try "(a) rm -rf /private/tmp/claude-501/base.$OTHER* (B3)" "rm -rf /private/tmp/claude-501/base.$OTHER*"
echo "    (a) other task fixture survives: $([ -e /private/tmp/claude-501/base.$OTHER/payload ] && echo yes || echo no)"
try "(b) aged sweep find ~/tmp -name fm-teardown.* -mtime +1 rm (B15)" "find $U/tmp -mindepth 1 -maxdepth 1 -name 'fm-teardown.*' -mtime +1 -exec rm -rf {} +"
echo "    (b) other task fixture survives: $([ -e $U/tmp/fm-teardown.$OTHER/old ] && echo yes || echo no)"
try "(c) python eval Path(data/$OTHER/eval-target).unlink() (H3)" "python3 /private/tmp/fm-lab.XGfLMG/fakebin/unlink-eval.py $H/data/$OTHER/eval-target"
echo "    (c) target survives: $([ -e $H/data/$OTHER/eval-target ] && echo yes || echo no)"
try "(d) write in own nested worktree (.claude/worktrees)" "echo probe > ./t5-nested-write.txt && [ -s ./t5-nested-write.txt ]"
try "(e) append own state/$OWN.status" "echo 'working [at=1]: lab probe' >> $H/state/$OWN.status"
try "(e) whole-file rewrite of state/$OTHER.status" "printf 'replaced\n' > $H/state/$OTHER.status"
try "(e) rename-over of state/$OTHER.status" "printf 'replaced\n' > $TMPDIR/o && mv -f $TMPDIR/o $H/state/$OTHER.status"
echo "    (e) other status unchanged: $(grep -q replaced $H/state/$OTHER.status && echo no || echo yes)"
try "other task temp root /tmp/fm-$OTHER write" "touch /tmp/fm-$OTHER/steal"
try "other task worktree write" "touch $(sed -n 's/^worktree=//p' $H/state/$OTHER.meta)/steal"
try "own temp dir write" "echo x > $TMPDIR/own"
try "own data dir write" "echo x > $H/data/$OWN/own"
try "primary checkout write" "echo x >> $H/projects/notes/README.md"
try "fleet config write (direct)" "touch $H/config/direct-proof-2"
try "unprotected path outside every root (default-allow)" "touch /private/tmp/fm-lab.XGfLMG/outside/default-allow-2"
try "delegated write via running tmux server (residual)" "tmux run-shell 'touch $H/config/residual-proof-2'; sleep 1; [ -e $H/config/residual-proof-2 ]"
session=; for a in "$@"; do [ "$prev" = --session-id ] && session=$a; prev=$a; done
c=$U/.claude; slug=$(pwd -P | sed 's/[^A-Za-z0-9]/-/g'); oldid=${PROBE_OLD_ID:-none}
echo "session-id from argv: $session"
for id in "$session" "$oldid" 99999999-8888-4777-8666-555555555555; do
  for e in "session-env/$id/probe" "file-history/$id/probe" "tasks/$id/probe" "projects/$slug/$id.jsonl"; do
    try "session write $e" "mkdir -p \"$c/\$(dirname $e)\" && : >> \"$c/$e\""
  done; done
echo "done"
} > "$out" 2>&1
