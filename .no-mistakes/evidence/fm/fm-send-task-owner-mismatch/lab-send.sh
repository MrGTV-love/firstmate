#!/usr/bin/env bash
# Run bin/fm-send.sh (or another bin/ entrypoint) inside the contained env against the lab; print exit.
T=$1; shift; . "$T/lab.env"
cd /Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M72J0F8JK5E0YM7A7MKYVDN2
printf '$'; printf ' %q' "$@"; echo
env -i PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin LANG=en_US.UTF-8 HOME=$T/home TMPDIR=$T/tmp FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR TMUX=$TMUX FM_GUARD_EVENT_LOG=$FM_GUARD_EVENT_LOG FM_SEND_SETTLE=0 "$@" 2>&1 | grep -v '^●\|gate agent lifecycle\|watcher still down'
echo "exit=${PIPESTATUS[0]}"
