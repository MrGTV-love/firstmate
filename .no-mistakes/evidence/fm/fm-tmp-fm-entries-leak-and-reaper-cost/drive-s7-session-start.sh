#!/usr/bin/env bash
# Live drive: the real bin/fm-session-start.sh in a marked lab home
# (bin/fm-lab-home.sh env) with an empty TMPDIR: normal run, fired bound, TERM
# to the script's own pid. Entries are counted at exit and again once every
# process that names the sandbox has ended (the deferred network worker).
set -u
WT=$1; SB=$(mktemp -d /tmp/fmnm-s7.XXXXXX) || exit 1
case "$SB" in /tmp/fmnm-s7.*) ;; *) exit 1 ;; esac
eval "$(TMPDIR=$SB "$WT/bin/fm-lab-home.sh" env 2>"$SB/env.err")"
T=$SB/t; mkdir -p "$T"
count() { printf '%s: entries in TMPDIR: %s  [%s]\n' "$1" "$(find "$T" -mindepth 1 | wc -l | tr -d ' ')" "$(cd "$T" && find . -mindepth 1 | sed 's/\.[A-Za-z0-9]\{6\}$/.XXXXXX/' | tr '\n' ' ')"; }
settle() {  # wait up to 180s for every process naming the sandbox to end
  local i; for i in $(seq 1 180); do ps -U "$(id -u)" -ww -o command= | grep -F "$SB" | grep -vqE 'grep|drive-s7' || { echo "background processes naming the sandbox ended after ${i}s"; return; }; sleep 1; done
  echo "still running after 180s:"; ps -U "$(id -u)" -ww -o pid=,command= | grep -F "$SB" | grep -vE 'grep|drive-s7' | sed "s#$SB#<SB>#g" | cut -c1-200
}
E=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMPDIR="$T" FM_HOME="$FM_HOME" TMUX_TMPDIR="$TMUX_TMPDIR")
echo "--- normal session start"; "${E[@]}" "$WT/bin/fm-session-start.sh" > "$SB/ss.out" 2>&1; echo "rc=$?"; grep -m1 'lock acquired' "$SB/ss.out"; count "at exit"; settle; count "after settle"
echo "--- session start whose bound fires (FM_SESSION_START_BUDGET=1)"; "${E[@]}" FM_SESSION_START_BUDGET=1 "$WT/bin/fm-session-start.sh" > "$SB/ss2.out" 2>&1; echo "rc=$?"; count "at exit"; settle; count "after settle"
for sig in TERM HUP; do
  echo "--- the script itself gets $sig after 1s"
  "${E[@]}" "$WT/bin/fm-session-start.sh" > "$SB/ss3.out" 2>&1 & p=$!
  sleep 1; echo "stage entry while running: $(find "$T" -path '*fm-session-start-stage.scratch/*' | sed "s#$T/##")"; kill -$sig $p; wait $p; echo "rc=$?"; count "at exit"; settle; count "after settle"
done
tmux -L fm-lab kill-server 2>/dev/null
"$WT/bin/fm-lab-home.sh" teardown "$FM_HOME"; rm -rf -- "$SB"; echo "torn down: $([ -e "$SB" ] && echo no || echo yes)"
