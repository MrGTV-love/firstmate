#!/usr/bin/env bash
# Drives bin/fm-lab-home.sh env and the gate refusal live, from the gate worktree.
set -u
cd /Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M5V67F71R43THE1MJNPXPAD2
unset FM_HOME FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export NO_MISTAKES_GATE=1
echo "== git-common-dir: $(git rev-parse --git-common-dir)"
echo "== TMPDIR=$TMPDIR"

echo; echo "### S1: refusal names the env command (unmarked scratch home, gate context)"
SCRATCH=$(mktemp -d "$TMPDIR/not-a-lab.XXXXXX")
mkdir -p "$SCRATCH/state"
FM_HOME=$SCRATCH bin/fm-send.sh some-target "hello" ; echo "exit=$?"
echo "-- path signal only (NO_MISTAKES_GATE unset):"
env -u NO_MISTAKES_GATE FM_HOME=$SCRATCH bin/fm-send.sh some-target "hello" ; echo "exit=$?"
rm -rf "$SCRATCH"

echo; echo "### S2: eval \"\$(bin/fm-lab-home.sh env)\" from default TMPDIR, then follow refusal's advice"
eval "$(bin/fm-lab-home.sh env 2>/tmp/fmlabenv.stderr.$$)"; echo "env exit=$?"
echo "-- stderr shown to caller:"; cat /tmp/fmlabenv.stderr.$$
echo "FM_HOME=$FM_HOME"; echo "TMUX_TMPDIR=$TMUX_TMPDIR"
echo "canonical? $( [ "$FM_HOME" = "$(cd -P "$FM_HOME" && pwd -P)" ] && echo yes || echo NO)"
echo "marker line1: $(sed -n 1p "$FM_HOME/.fm-lab-home")"
ls -A "$FM_HOME"; ls -ld "$TMUX_TMPDIR"
echo "-- re-run lifecycle call with that FM_HOME:"
bin/fm-send.sh some-target "hello"; echo "exit=$? (3 would mean refused)"
LAB1=$FM_HOME; TD1=$(sed -n 's/^fm-lab-home: teardown: //p' /tmp/fmlabenv.stderr.$$)

echo; echo "### S3: symlinked TMPDIR=/tmp gives canonical /private/tmp home that is admitted"
out=$(TMPDIR=/tmp bin/fm-lab-home.sh env 2>/dev/null); echo "$out"
LAB2=$(bash -c "$out"'; printf %s "$FM_HOME"')
echo "canonical? $( [ "$LAB2" = "$(cd -P "$LAB2" && pwd -P)" ] && echo yes || echo NO)"
FM_HOME=$LAB2 bin/fm-send.sh some-target "hello"; echo "exit=$? (3 would mean refused)"
TMPDIR=/tmp bin/fm-lab-home.sh teardown "$LAB2" && rm -rf "$LAB2"; echo "lab2 removed: $([ -e "$LAB2" ] && echo NO || echo yes)"

echo; echo "### S4 (adversarial): containment unchanged"
echo "-- non-canonical alias (symlink) to a real marked lab:"
ln -s "$LAB1" "$TMPDIR/fm-lab-alias.$$"
FM_HOME=$TMPDIR/fm-lab-alias.$$ bin/fm-send.sh some-target "hello"; echo "exit=$?"
rm -f "$TMPDIR/fm-lab-alias.$$"
echo "-- populated dir cannot be marked by create:"
POP=$(mktemp -d "$TMPDIR/pop.XXXXXX"); echo data > "$POP/backlog.md"
bin/fm-lab-home.sh create "$POP"; echo "create exit=$?"; ls -A "$POP"; rm -rf "$POP"
echo "-- lab home with a stray FM_DATA_OVERRIDE:"
FM_DATA_OVERRIDE=/somewhere bin/fm-send.sh some-target "hello"; echo "exit=$?"
echo "-- env inside the repo is impossible: TMPDIR pointed inside worktree:"
TMPDIR=$PWD bin/fm-lab-home.sh env; echo "env exit=$?"; ls -d fm-lab.* 2>/dev/null || echo "no leftover fm-lab.* in worktree"

echo; echo "### S5: fresh-shell flow - re-export from stderr lines, private tmux server, guarded teardown"
EXPORTS=$(grep '^export ' /tmp/fmlabenv.stderr.$$)
bash -c "cd /; $EXPORTS"'; touch "$FM_HOME/config/supervision-host"; tmux -L fm-lab new-session -d -s primary -c /tmp -e FM_HOME="$FM_HOME" "sleep 300"; echo "socket in private dir:"; ls "$TMUX_TMPDIR"/tmux-*/; tmux -L fm-lab list-sessions'
echo "-- default tmux dir has no fm-lab socket: $(ls /private/tmp/tmux-$(id -u)/fm-lab 2>/dev/null || echo none)"
echo "-- teardown line while server alive (expected refusal, lab kept):"
(cd / && bash -c "$TD1"); echo "exit=$?  lab exists: $([ -d "$LAB1" ] && echo yes || echo no)"
echo "-- kill server via same socket, then teardown line from / in a fresh shell:"
bash -c "$EXPORTS"'; tmux -L fm-lab kill-server'
(cd / && bash -c "$TD1"); echo "exit=$?"
echo "lab removed: $([ -e "$LAB1" ] && echo NO || echo yes); socket dir removed: $([ -e "$TMUX_TMPDIR" ] && echo NO || echo yes)"
rm -f /tmp/fmlabenv.stderr.$$
