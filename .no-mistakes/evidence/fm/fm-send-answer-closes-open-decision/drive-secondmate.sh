#!/usr/bin/env bash
# Live driver: a local secondmate task (marked requests that create
# pending-reply expectations) in a marked lab home with a REAL tmux pane.
# Proves a refused bare send creates no pending-reply expectation and no record,
# and an expectation alone (no open status entry) does not cause a refusal.
set -u
ROOT=$1; cd "$ROOT"
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; LAB=$FM_HOME
trap 'tmux -L fm-lab kill-server 2>/dev/null; "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
echo "lab home: $LAB"
S=$LAB/state; SM=$LAB/data/sm1-home; mkdir -p "$SM/state"
tmux -L fm-lab new-session -d -s lab -n fm-sm1 -x 200 -y 50 'cat >/dev/null'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0" FM_SEND_SETTLE=0
printf '%s\n' window=lab:fm-sm1 endpoint_task_id=sm1 "worktree=$SM" "project=$SM" harness=echo kind=secondmate mode=secondmate yolo=off "home=$SM" projects=alpha > "$S/sm1.meta"
: > "$S/sm1.status"
snap() {
  echo "--- pending-replies: $(find "$S/pending-replies" -type f 2>/dev/null | wc -l | tr -d ' ') file(s)"; find "$S/pending-replies" -type f 2>/dev/null | sed "s|$S/||" | sort
  echo "--- inbox records: $(find "$S/sm1.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')"
  echo "--- status"; sed -E 's/ \[at=[0-9]+\]//' "$S/sm1.status"
  echo "--- drain"; FM_STATE_OVERRIDE="$S" bin/fm-wake-drain.sh 2>/dev/null | grep -E '^sm1 \[key=|OPEN DECISIONS \(' || echo "(no open decision)"
}
run() { echo; echo "===== $1"; shift; echo "\$ fm-send.sh $*"; bin/fm-send.sh "$@" >"$LAB/o" 2>"$LAB/e"; echo "exit=$?"; cat "$LAB/o"; grep -v '^fm-gate-refuse\|WARNING: watcher\|^●' "$LAB/e"; snap; }
echo "===== start"; snap
run "bare send, no open key: delivered, creates one expectation" sm1 "status of phase 7?"
run "bare send again, an expectation open but no status entry: still delivered" sm1 "and phase 8?"
printf 'needs-decision [key=audit-scope]: whole repo or one package\n' >> "$S/sm1.status"
run "open key added, bare send: refuses, no new expectation, no record" sm1 "and phase 9?"
run "--answers-none: delivered with marker, key stays open" sm1 --answers-none "and phase 9?"
echo "--- newest record body"; f=$(find "$S/sm1.inbox" -maxdepth 1 -name '*.msg' | sort | tail -1); cat "$f"
