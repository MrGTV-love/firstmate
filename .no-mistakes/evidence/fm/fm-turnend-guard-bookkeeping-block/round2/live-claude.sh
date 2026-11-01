#!/usr/bin/env bash
# Real Claude Code primary in a marked lab home, on a private tmux socket, on a
# plain-checkout copy of the target commit (the guard exempts linked worktrees).
# Usage: live-claude.sh <scenario> ; scenarios: absent unwritable supervised stock-broken-watcher
set -u
scenario=${1:?}; W=${WORKTREE:?}; E=${EVID:?}; TARGET=${TARGET:?}; LIMIT=${LIMIT:-420}; WANT=${WANT:-4}
cd "$W"
unset FM_GUARD_GRACE FM_ARM_CONFIRM_TIMEOUT
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
L=$FM_HOME; S=$L/state; C=$L/projects/primary; OUT=$E/live-${LABEL:-$scenario}
mkdir -p "$C"; git archive "$TARGET" | tar -x -C "$C"
git -C "$C" init -q; git -C "$C" -c user.name=lab -c user.email=lab@example.invalid add -A -f; git -C "$C" -c user.name=lab -c user.email=lab@example.invalid commit -qm tree --no-verify
echo "lab=$L tree=$(git -C "$C" rev-parse 'HEAD^{tree}') expected=$(git rev-parse "$TARGET^{tree}") target=$TARGET" | tee "$OUT.txt"
T() { tmux -L fm-lab "$@"; }
cleanup() {
  T capture-pane -p -t primary -S -400 >"$OUT.pane-final.txt" 2>/dev/null
  T kill-server 2>/dev/null
  p=$(cat "$S/.watch.lock/pid" 2>/dev/null); [ -n "$p" ] && kill "$p" 2>/dev/null
  cp "$S/guard-events.jsonl" "$OUT.guard-events.jsonl" 2>/dev/null
  for f in .watch-cycle-exits.log .supervision-host.log; do tail -n 15 "$S/$f" 2>/dev/null | cut -c1-240 >"$OUT$f"; done
  ls -d ~/.claude/projects/*"$(basename "$L" | tr . -)"* >>"$OUT.txt" 2>/dev/null
  chmod -R u+rwX "$L" 2>/dev/null
  { [ -e "$S/.turnend-claude-blocks" ] && ls -ld "$S/.turnend-claude-blocks"; cat "$S/.turnend-claude-blocks" 2>/dev/null; cat "$S/.claude-autoarm-epoch" 2>/dev/null; ls -a "$S"; } >>"$OUT.txt" 2>&1
  "$W/bin/fm-lab-home.sh" teardown "$L" && rm -rf "$L"
}
trap cleanup EXIT
rm_autoarm() { jq '.hooks.Stop[0].hooks |= map(select(.command | contains("fm-claude-stop-autoarm") | not))' "$C/.claude/settings.json" >"$C/.claude/settings.json.new" && mv "$C/.claude/settings.json.new" "$C/.claude/settings.json"; echo "settings: Stop hooks now: $(jq -c '[.hooks.Stop[0].hooks[].command|capture("bin/(?<s>[a-z-]+\\.sh)").s]' "$C/.claude/settings.json")" | tee -a "$OUT.txt"; }
case $scenario in
  absent|unwritable|supervised) rm_autoarm ;;
  stock-broken-watcher) printf '#!/usr/bin/env bash\nexit 1\n' >"$C/bin/fm-watch.sh"; chmod +x "$C/bin/fm-watch.sh" ;;
esac
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ATTENDED -u CLAUDE_PID -u CLAUDE_EFFORT -u CLAUDE_CODE_EXECPATH -u CLAUDE_CODE_FORK_SUBAGENT -u CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS -u ANTHROPIC_DEFAULT_SONNET_MODEL \
  tmux -L fm-lab new-session -d -x 180 -y 50 -s primary -c "$C" -e FM_HOME="$L" "$HOME/.local/bin/claude --model haiku; sleep 2"
ready=0
for i in $(seq 1 90); do
  sleep 2; P=$(T capture-pane -p -t primary 2>/dev/null) || { echo "pane gone"; break; }
  if grep -qi 'trust this folder\|Yes, I trust\|trust the files' <<<"$P"; then T send-keys -t primary Down; sleep 0.5; T send-keys -t primary Enter; sleep 2; continue; fi
  if grep -qiE 'not logged in|/login|Select login|Invalid API' <<<"$P"; then echo "LOGIN PROBLEM"; printf '%s\n' "$P"; exit 3; fi
  if grep -q '^.*❯' <<<"$P" && [ -e "$S/.lock" -o "$i" -gt 20 ]; then ready=1; break; fi
done
echo "ready=$ready after ${i} polls" | tee -a "$OUT.txt"
T capture-pane -p -t primary >"$OUT.pane-start.txt"
[ "$ready" = 1 ] || { cat "$OUT.pane-start.txt"; exit 4; }
sleep 5
: >"$S/task1.meta"
case $scenario in
  unwritable) mkdir "$S/.turnend-claude-blocks" ;;
  supervised)
    mkdir "$S/.claude-autoarm-failure-notified"
    FM_HOME=$L nohup bash "$C/bin/fm-watch-arm.sh" >"$OUT.watcher.log" 2>&1 </dev/null & disown
    for i in $(seq 1 60); do [ -s "$S/.watch.lock/pid" ] && [ -e "$S/.last-watcher-beat" ] && break; sleep 0.5; done
    echo "real watcher pid=$(cat "$S/.watch.lock/pid" 2>/dev/null)" | tee -a "$OUT.txt"
    ;;
esac
T send-keys -t primary -l "${PROMPT:-Lab test. Reply with only the word ack. Use no tools. If a stop hook says supervision needs repair, do not repair it and use no tools: reply with only the word ack again.}"
sleep 1; T send-keys -t primary Enter
t0=$(date +%s); last=-1; stable=0
while [ $(( $(date +%s)-t0 )) -lt "$LIMIT" ]; do
  sleep 5
  P=$(T capture-pane -p -t primary -S -400 2>/dev/null)
  printf '%s\n' "$P" >"$OUT.pane-latest.txt"
  n=$(wc -l <"$S/guard-events.jsonl" 2>/dev/null | tr -d ' '); n=${n:-0}
  if grep -q 'esc to interrupt\|Stop hook\|running stop' <<<"$(tail -8 <<<"$P")"; then stable=0; fi
  if [ "$n" = "$last" ]; then stable=$((stable+1)); else stable=0; last=$n; fi
  echo "t=$(( $(date +%s)-t0 )) events=$n stable=$stable" >>"$OUT.txt"
  [ "$n" -ge "$WANT" ] && [ "$stable" -ge 6 ] && break
done
if [ "$scenario" = stock ]; then
  echo "--- stage 2: real status change wakes the watcher; pull-warning sampled read-only from outside" | tee -a "$OUT.txt"
  echo "before wake: lock=$(cat "$S/.watch.lock/pid" 2>/dev/null) guard=[$(FM_GUARD_READ_ONLY=1 FM_HOME=$L bash "$C/bin/fm-guard.sh" 2>&1 | grep -c 'WATCHER DOWN')]" | tee -a "$OUT.txt"
  printf 'needs-decision: lab test wake, reply ack\n' >>"$S/task1.status"
  for i in $(seq 1 24); do
    sleep 5
    g=$(FM_GUARD_READ_ONLY=1 FM_HOME=$L bash "$C/bin/fm-guard.sh" 2>&1)
    echo "t=$((i*5)) lock=$(cat "$S/.watch.lock/pid" 2>/dev/null) alive=$(kill -0 "$(cat "$S/.watch.lock/pid" 2>/dev/null)" 2>/dev/null && echo y || echo n) banner=$(grep -c 'WATCHER DOWN' <<<"$g") reminder=$(grep -ci 'still down\|reminder' <<<"$g") busy=$(T capture-pane -p -t primary | grep -c 'esc to interrupt')" | tee -a "$OUT.txt"
  done
  T capture-pane -p -t primary -S -400 >"$OUT.pane-latest.txt"
fi
echo "--- deny/warn/allow events" | tee -a "$OUT.txt"
jq -c '{decision,cleared_by,repeat}' "$S/guard-events.jsonl" 2>/dev/null | tee -a "$OUT.txt"
echo "--- pane tail"; tail -40 "$OUT.pane-latest.txt"
