#!/usr/bin/env bash
# Side check: after a session start whose bound fires, do fm-startup-network
# entries stay in TMPDIR for good, and does the base commit do the same?
set -u
WT=$1 BASE_REV=$2; SB=$(mktemp -d /tmp/fmnm-s8.XXXXXX) || exit 1
case "$SB" in /tmp/fmnm-s8.*) ;; *) exit 1 ;; esac
mkdir -p "$SB/base"; git -C "$WT" archive "$BASE_REV" | tar -x -C "$SB/base"
for side in target base; do
  [ "$side" = target ] && src=$WT || src=$SB/base
  L=$(mktemp -d "$SB/lab-$side.XXXXXX"); FMH=$("$WT/bin/fm-lab-home.sh" create "$L/home"); TT=$("$WT/bin/fm-lab-home.sh" tmux-dir "$FMH")
  T=$SB/t-$side; mkdir -p "$T"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMPDIR="$T" FM_HOME="$FMH" TMUX_TMPDIR="$TT" FM_SESSION_START_BUDGET=1 "$src/bin/fm-session-start.sh" >/dev/null 2>&1
  echo "$side rc=$?"
  for w in 0 30 60; do sleep $((w ? 30 : 0)); echo "  $side after ${w}s: $(cd "$T" && ls -1A | sed 's/\.[A-Za-z0-9]\{6\}$/.XXXXXX/' | tr '\n' ' ') | open by: $(lsof +D "$T" -Fc 2>/dev/null | sed -n 's/^c//p' | sort -u | tr '\n' ' ')"; done
  "$WT/bin/fm-lab-home.sh" teardown "$FMH"
done
rm -rf -- "$SB"
