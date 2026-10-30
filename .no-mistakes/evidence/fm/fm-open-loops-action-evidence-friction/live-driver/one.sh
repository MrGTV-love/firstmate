#!/usr/bin/env bash
# one.sh CODE_ROOT LABEL SCENARIO TRANSCRIPT : mint a lab home, drive one scenario, tear the lab down.
set -u
W=/tmp/fm-livedrive.RRnk1T
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M65E7AQPFCP41EYKNQ9XBCF5
eval "$("$WT/bin/fm-lab-home.sh" env 2>"$W/lab-$2-$3.stderr")"
export FM_HOME TMUX_TMPDIR
python3 "$W/drive.py" "$W" "$1" "$2" "$3" "$4"; rc=$?
env -u TMUX tmux kill-server 2>/dev/null
"$WT/bin/fm-lab-home.sh" teardown "$FM_HOME" && rm -rf "$FM_HOME"
echo "lab torn down: $FM_HOME rc=$rc"
exit $rc
