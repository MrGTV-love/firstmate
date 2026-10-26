#!/usr/bin/env bash
# Live lab driver for the auto-arm handling-race scenarios.
# Usage: live-driver.sh <plain-checkout-tree> <label> <evidence-dir> <gate-worktree>
# The tree must be a plain git checkout (fm_primary_root_matches refuses a linked
# worktree), made with: git archive <rev> | tar -x -C <tree>; git -C <tree> init; add; commit.
# Steps, all on a private tmux socket and a marked lab FM_HOME:
#   1. mint lab home, opt in the host, register a no-op custom check (supervision need)
#   2. start real `claude --model haiku` with FM_SUPERVISION_HOST_PARK_SECONDS=90, trust the folder
#   3. prompt 1 ("OK"), whose Stop hook parks the host; wait for its first close
#   4. after the next park starts, have main run bin/fm-wake-drain.sh once without acknowledging
#   5. wait for that park's boundary close and record the hook's ledger outcome and failure notice
#   6. capture evidence and tear the lab down
set -u
TREE=$1 LABEL=$2 E=$3 GATE=$4
sleep_s() { python3 -c "import time;time.sleep($1)"; }
eval "$("$GATE/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
OUT="$E/live-$LABEL-lab.txt"
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null || true
  sleep_s 3
  "$GATE/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB" && echo "torn down $LAB" >> "$OUT"
}
trap cleanup EXIT
obs() { printf '%s %s\n' "$(date +%s)" "$*" >> "$OUT"; }
snap() { obs "$1 marker=$(cat "$LAB/state/.watcher-down" 2>/dev/null) ledger=[$(head -1 "$LAB/state/.claude-autoarm-epoch" 2>/dev/null)] notice=$( [ -e "$LAB/state/.claude-autoarm-failure-notified" ] && cat "$LAB/state/.claude-autoarm-failure-notified" || echo absent) queue_rows=$(wc -l < "$LAB/state/.wake-queue" 2>/dev/null | tr -d ' ') held=$( [ -e "$LAB/state/.main-eligible-rows.held" ] && echo yes || echo no) watchlock=$( [ -e "$LAB/state/.watch.lock" ] && echo yes || echo no)"; }
pane() { tmux -L fm-lab capture-pane -p -t primary; }
submit() {  # <text> <done-regex>
  tmux -L fm-lab send-keys -t primary "$1"
  sleep_s 1
  tmux -L fm-lab send-keys -t primary C-m
}

printf '# LIVE lab (%s): real %s (haiku) primary from %s (%s), FM_HOME=%s, FM_SUPERVISION_HOST_PARK_SECONDS=90\n' \
  "$LABEL" "$(claude --version)" "$TREE" "$(git -C "$TREE" log --oneline -1)" "$LAB" > "$OUT"
touch "$LAB/config/supervision-host"
printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/state/idle.check.sh"
chmod 700 "$LAB/state/idle.check.sh"
FM_HOME="$LAB" "$GATE/bin/fm-check-register.sh" idle >/dev/null

cd "$TREE" || exit 1
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE tmux -L fm-lab new-session -d -x 200 -y 50 -s primary -c "$TREE" \
  -e FM_HOME="$LAB" -e FM_SUPERVISION_HOST_PARK_SECONDS=90 claude --model haiku --allowedTools 'Bash(bin/fm-wake-drain.sh:*)'
for _ in $(seq 1 30); do sleep_s 1; pane | grep -q 'trust this folder' && break; done
if pane | grep -q 'trust this folder'; then tmux -L fm-lab send-keys -t primary Down Enter; fi
for _ in $(seq 1 60); do sleep_s 1; [ -e "$LAB/state/.session-start-complete" ] && break; done
sleep_s 5
obs "session lock=$(cat "$LAB/state/.lock" 2>/dev/null)"

submit 'Reply with only the word OK. Do not run any tools.'
for _ in $(seq 1 60); do sleep_s 2; [ -s "$LAB/state/.supervision-host.log" ] && break; done
obs "host started"
# First close (pass-through or boundary) and its commit.
for _ in $(seq 1 75); do sleep_s 2; [ "$(wc -l < "$LAB/state/.supervision-host.log")" -ge 2 ] && break; done
sleep_s 2
snap "after first host close"
# Let main handle whatever arrived, then wait until a fresh park starts.
FIRST_CLOSE=$(sed -n '2p' "$LAB/state/.supervision-host.log" | cut -f1)
fresh_start() { awk -F '\t' -v s="$1" '$1 > s && $2 == "start" { t = $1 } END { if (t) print t; else exit 1 }' "$LAB/state/.supervision-host.log"; }
for _ in $(seq 1 90); do sleep_s 2; fresh_start "$FIRST_CLOSE" >/dev/null && break; done
if ! fresh_start "$FIRST_CLOSE" >/dev/null; then
  snap "NO fresh park within 180 s of the first close: nothing rewoke main or re-armed"
  submit 'Reply with only the word OK. Do not run any tools.'
  for _ in $(seq 1 60); do sleep_s 2; fresh_start "$FIRST_CLOSE" >/dev/null && break; done
fi
PARK_START=$(fresh_start "$FIRST_CLOSE")
sleep_s 8
snap "fresh park started at $PARK_START"
submit 'Lab test step: run bin/fm-wake-drain.sh exactly once, then reply with only the word DRAINED. Do not run any acknowledgement or any other command in this turn.'
for _ in $(seq 1 40); do sleep_s 2; pane | grep -q '⏺ DRAINED' && break; done
sleep_s 3
snap "after main's mid-park drain"
for _ in $(seq 1 120); do
  sleep_s 1
  awk -F '\t' -v s="$PARK_START" '$1 > s && $2 == "boundary"' "$LAB/state/.supervision-host.log" | grep -q . && break
done
sleep_s 3
snap "after the park's boundary close"
sleep_s 25
snap "after main handled the delivery"
{
  echo "## state/.supervision-host.log"; cat "$LAB/state/.supervision-host.log"
  echo "## pane"; tmux -L fm-lab capture-pane -p -S -400 -t primary | grep -v '^\s*$' | grep -v '^⚠'
} >> "$OUT"
