#!/bin/bash
# Model-free stand-in for the claude CLI (round 6 lab). It records its argv,
# confinement and the env vars fm-spawn must unset, then tries the T5 attacks
# against the real other task r6o. No provider call.
case "${1:-}" in --version) echo '2.1.310 (Claude Code)'; exit 0 ;; esac
[ -n "${FM_TASK_INBOX:-}" ] || exit 0
OWN=$(basename "$FM_TASK_INBOX" .inbox) OTHER=r6o
H=__LAB__/home
out=$H/data/$OWN/probe.txt
[ "$OWN" != "$OTHER" ] || { echo "other task ran: confinement=${FM_WRITE_CONFINEMENT:-unset}" > "$out"; echo done >> "$out"; exit 0; }
try() { if ( eval "$2" ) </dev/null >/dev/null 2>&1; then r=ok; else r=refused; fi; printf '%-58s -> %s\n' "$1" "$r"; }
{
echo "argv: $*"
echo "FM_WRITE_CONFINEMENT=${FM_WRITE_CONFINEMENT:-unset} TMPDIR=${TMPDIR:-} cwd=$(pwd -P)"
echo "CURSOR_AGENT=${CURSOR_AGENT-<unset>} CURSOR_INVOKED_AS=${CURSOR_INVOKED_AS-<unset>} GEMINI_CLI=${GEMINI_CLI-<unset>} ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY+<set>}${ANTHROPIC_API_KEY-<unset>} LAB_MARK=${LAB_MARK-<unset>}"
try "(a) rm -rf /private/tmp/claude-$(id -u)/base.$OTHER* (B3)" "rm -rf /private/tmp/claude-$(id -u)/base.$OTHER*"
echo "    (a) other fixture survives: $([ -e /private/tmp/claude-$(id -u)/base.$OTHER/payload ] && echo yes || echo no)"
try "(b) find ~/tmp -name '*$OTHER*' -delete (B15 sweep)" "find $HOME/tmp -mindepth 1 -name '*$OTHER*' -delete"
echo "    (b) other ~/tmp fixture survives: $([ -e $HOME/tmp/fixture-$OTHER/payload ] && echo yes || echo no)"
try "(c) python Path(data/$OTHER/eval-target).unlink() (H3)" "python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).unlink()' $H/data/$OTHER/eval-target"
echo "    (c) target survives: $([ -e $H/data/$OTHER/eval-target ] && echo yes || echo no)"
try "(d) write in own nested worktree (.claude/worktrees)" "echo probe > ./r6-nested-write.txt && [ -s ./r6-nested-write.txt ]"
try "(e) append own state/$OWN.status" "echo 'working: lab probe' >> $H/state/$OWN.status"
try "(e) whole-file rewrite of state/$OTHER.status" "printf 'replaced\n' > $H/state/$OTHER.status"
try "primary checkout README append" "echo x >> $H/projects/notes/README.md"
try "own data dir write" "echo x > $H/data/$OWN/own"
echo done
} > "$out" 2>&1
