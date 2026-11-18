#!/usr/bin/env bash
# Live acquisition proof: real bin/fm-spawn.sh, real tmux (private lab socket dir),
# real treehouse and real Git against a scratch pool. Only the worker CLI (codex),
# no-mistakes and gh are exit-0 stand-ins, because they run after acquisition.
# Usage: live-spawn.sh <worktree> <name> <scratch-pool-dir> <evidence-dir>
# Env: STALL, CEILING (acquisition overrides), HANG_AFTER (git shim hangs after N calls),
#      FMROOT (fm-spawn tree to run; default the worktree).
set -u
WT=$1 NAME=$2 S=$3 EV=$4
FMROOT=${FMROOT:-$WT}
# shellcheck disable=SC1091
. "$WT/tests/fixtures.sh"
L=$(mktemp -d /tmp/fmlive.XXXXXX)
FM_HOME=$L/home
"$WT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null || { echo 'lab create failed'; exit 2; }
TMUX_TMPDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$FM_HOME") || exit 2
export FM_HOME TMUX_TMPDIR; unset TMUX
FAKEBIN=$L/fakebin; SHIM=$L/shim; mkdir -p "$FAKEBIN" "$SHIM"
fm_test_fake_no_mistakes "$FAKEBIN"; fm_test_fake_gh "$FAKEBIN"; fm_test_fake_gh_axi "$FAKEBIN"; fm_fake_exit0 "$FAKEBIN" codex
printf 'codex\n' > "$FM_HOME/config/crew-harness"
if [ -n "${HANG_AFTER:-}" ]; then
  cat > "$SHIM/git" <<EOS
#!/bin/bash
n=\$(( \$(cat '$L/gitcount' 2>/dev/null || echo 0) + 1 )); echo \$n > '$L/gitcount'
[ \$n -le $HANG_AFTER ] || exec /bin/sleep 100000
exec /usr/bin/git "\$@"
EOS
  chmod +x "$SHIM/git"
fi
REAL_TH=$(command -v treehouse)
# TH_MODE=newcands: before the real get, print one NEW candidate line every TH_EVERY s, TH_COUNT times, no Git.
# TH_MODE=stuck: print the SAME candidate with a changing counter every TH_EVERY s, forever, no Git.
if [ -n "${TH_MODE:-}" ]; then
  cat > "$SHIM/treehouse" <<EOS
#!/bin/bash
if [ "\${1:-}" = get ]; then
  i=0
  while :; do
    i=\$((i + 1))
    if [ '$TH_MODE' = stuck ]; then
      printf 'treehouse: checked %s: refused: unlanded work (pass %d)\n' '$S/pool/.treehouse/stuck-loop/1/p' "\$i" >&2
    else
      [ "\$i" -le ${TH_COUNT:-0} ] || break
      printf 'treehouse: checked %s: refused: unlanded work\n' "$S/pool/.treehouse/walk/\$i/p" >&2
    fi
    /bin/sleep ${TH_EVERY:-10}
  done
fi
exec '$REAL_TH' "\$@"
EOS
  chmod +x "$SHIM/treehouse"
fi
export HOME=$S/h TREEHOUSE_ROOT=$S/pool GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
T=$(command -v tmux)
# Keep every walk long: give any clean pool copy an unlanded commit before the run.
for d in "$S"/pool/.treehouse/p-*/*/p; do
  [ "$(git -C "$d" log -1 --format=%s 2>/dev/null)" = unlanded ] || git -C "$d" -c user.email=a@b -c user.name=a commit -q --allow-empty -m unlanded
done
"$T" -f /dev/null new-session -d -s firstmate -n sentinel "/bin/sleep 100000" || exit 2
"$T" set-option -g default-shell /bin/bash
# A login-shell startup file can put the normal PATH first; fix the pane PATH in the pane command itself.
"$T" set-option -g default-command "exec /usr/bin/env PATH='$SHIM:$FAKEBIN:$PATH' /bin/bash --noprofile --norc"
"$T" set-environment -g PATH "$SHIM:$FAKEBIN:$PATH"
# The session keeps the PATH it was created with; set it there too so pane shells see the shims.
# Mirror every new pane to a log, so a refused acquisition (whose window is destroyed) still leaves its pane output.
"$T" set-hook -g after-new-window "pipe-pane -o 'cat >> $L/pane.log'"
"$T" set-environment -t firstmate PATH "$SHIM:$FAKEBIN:$PATH"
for v in HOME TREEHOUSE_ROOT GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL; do "$T" set-environment -g "$v" "${!v}"; done
ID=live-$NAME
fm_test_spawn_brief "$FM_HOME" "$ID" 'Live acquisition proof.'
OUT=$EV/live-$NAME.transcript.txt
{
  echo "# scenario $NAME  fm-spawn tree: $FMROOT ($(git -C "$FMROOT" rev-parse HEAD 2>/dev/null || echo scratch-export))"
  echo "# treehouse $(treehouse --version 2>&1)  load: $(uptime)"
  echo "# STALL=${STALL:-<unset>} CEILING=${CEILING:-<unset>} HANG_AFTER=${HANG_AFTER:-<none>} TH_MODE=${TH_MODE:-<real get only>} TH_COUNT=${TH_COUNT:-} TH_EVERY=${TH_EVERY:-}"
  echo "# pool before: $(cd "$S/p" && treehouse status 2>&1 | awk 'NR>1{print $2}' | sort | uniq -c | tr '\n' ' ')"
} > "$OUT"
cd "$S/p" || exit 2
t0=$(date +%s)
env -u NO_MISTAKES_GATE_UNUSED -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u SPAWN_ACQUIRE_STALL -u SPAWN_ACQUIRE_CEILING \
  ${STALL:+SPAWN_ACQUIRE_STALL=$STALL} ${CEILING:+SPAWN_ACQUIRE_CEILING=$CEILING} \
  FM_SPAWN_NO_GUARD=1 PATH="$FAKEBIN:$PATH" \
  bash "$FMROOT/bin/fm-spawn.sh" "$ID" "$S/p" --backend tmux --harness codex --allow-api-key --mode no-mistakes --yolo off >> "$OUT" 2>&1
rc=$?
t1=$(date +%s)
{
  echo "# exit=$rc wall=$((t1 - t0))s"
  tr=$(ls -d "$FM_HOME"/data/"$ID"/.acquire-trace.* 2>/dev/null | head -1)
  echo "# acquisition trace dir after spawn: ${tr:-<removed>}"
  [ -z "$tr" ] || for f in "$tr"/*; do [ -e "$f" ] && echo "#   $f git-starts=$(grep -c '"event":"start"' "$f")"; done
  [ -z "${HANG_AFTER:-}" ] || echo "# git shim calls: $(cat "$L/gitcount" 2>/dev/null)"
  if [ "$rc" = 0 ]; then
    win=$("$T" list-windows -t firstmate -F '#{window_name}' | grep "fm-$ID" | head -1)
    "$T" send-keys -t "firstmate:$win" "printf '%s\\n' \"\${GIT_TRACE2_EVENT-unset}\" > '$L/trace-env'" Enter
    for _ in $(seq 1 60); do [ -s "$L/trace-env" ] && break; /bin/sleep 1; done
    echo "# GIT_TRACE2_EVENT in acquired pane shell: $(cat "$L/trace-env" 2>/dev/null || echo '<probe timed out>')"
    echo "# meta: $(grep -h '^worktree=' "$FM_HOME"/state/"$ID".meta 2>/dev/null)"
  fi
  echo "# pool after: $(cd "$S/p" && treehouse status 2>&1 | awk 'NR>1{print $2}' | sort | uniq -c | tr '\n' ' ')"
  echo "# treehouse wrapper calls seen in pane capture: $("$T" capture-pane -p -J -S -400 -t "firstmate:$("$T" list-windows -t firstmate -F '#{window_name}' | grep "fm-$ID" | head -1)" 2>/dev/null | grep -c '^treehouse: checked')"
  echo "# git shim present: $([ -x "$SHIM/git" ] && echo yes || echo no); treehouse wrapper present: $([ -x "$SHIM/treehouse" ] && echo yes || echo no)"
  echo "# --- mirrored pane output (pipe-pane), lines matching treehouse/acquire, last 20 ---"
  tr -d '\r' < "$L/pane.log" 2>/dev/null | grep -aE 'treehouse|__firstmate_acquire' | tail -20
  echo "# mirrored 'treehouse: checked' lines: $(tr -d '\r' < "$L/pane.log" 2>/dev/null | grep -ac 'treehouse: checked')"
  echo "# --- pane capture of spawn window (last 25 lines) ---"
  for w in $("$T" list-windows -t firstmate -F '#{window_id}' 2>/dev/null); do "$T" capture-pane -p -J -t "$w" -S -200 2>/dev/null | grep -v '^$' | tail -25; done
} >> "$OUT" 2>&1
pid=$("$T" display-message -p '#{pid}' 2>/dev/null)
"$T" kill-server 2>/dev/null
for _ in $(seq 1 100); do [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || break; /bin/sleep 0.1; done
for _ in 1 2 3 4 5; do [ -z "$("$WT/bin/fm-test-reap-orphans.sh" --owner-pid "$$" --root "$L" 2>/dev/null)" ] && break; done
/bin/sleep 5
"$WT/bin/fm-lab-home.sh" teardown "$FM_HOME" >> "$OUT" 2>&1 && echo "# lab torn down" >> "$OUT"
chmod -R u+w "$L" 2>/dev/null; rm -rf "$L"; /bin/sleep 3; chmod -R u+w "$L" 2>/dev/null; rm -rf "$L"; [ ! -e "$L" ] && echo "# lab dir removed" >> "$OUT"
echo "rc=$rc out=$OUT"
