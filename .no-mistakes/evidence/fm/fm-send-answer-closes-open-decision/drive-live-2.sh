#!/usr/bin/env bash
# Follow-up live checks: what the contradictory-pair refusals change, and the
# explicit-backend-target send on head vs base against a `cat` pane.
set -u
WT=$1; BASE=$2
eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"; LAB=$FM_HOME
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
tmux -L fm-lab new-session -d -s lab -n fm-t1 -x 200 -y 50 cat
tmux -L fm-lab new-window -d -t lab -n fm-t2 cat
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0" FM_SEND_SETTLE=0
S=$LAB/state
printf 'window=lab:fm-t1\nkind=ship\n' > "$S/t1.meta"
printf 'needs-decision [key=k1]: pick REST or RPC\nblocked [key=k2]: need the staging token\n' > "$S/t1.status"
snap() { (cd "$LAB" && find state -print | LC_ALL=C sort | while IFS= read -r p; do
  [ -f "$p" ] && printf 'f %s %s\n' "$p" "$(cksum < "$p")" || printf 'd %s\n' "$p"; done); }
b=$(snap)
for args in "--answers-none --resolve-key k1 both" "--resolve-key k1 --answers-none both" "--resolve-key --answers-none both" "go with REST"; do
  "$WT/bin/fm-send.sh" t1 $args >/dev/null 2>&1; echo "head fm-send.sh t1 $args -> exit=$?"
done
echo "state diff after the four refusals:"; diff <(echo "$b") <(snap)
echo "guard-events.jsonl lines:"; sed 's/"ts":[^,]*,//' "$S/guard-events.jsonl" | cut -c1-200
echo "pane fm-t1 (expect empty):"; tmux -L fm-lab capture-pane -p -t lab:fm-t1 | sed '/^$/d'
for r in "$WT" "$BASE"; do
  "$r/bin/fm-send.sh" lab:fm-t2 "typed text" >/dev/null 2>"$LAB/err"; echo "$( [ "$r" = "$WT" ] && echo head || echo base ) explicit target exit=$? :: $(grep '^error' "$LAB/err" | cut -c1-90)"
done
tmux -L fm-lab kill-server
"$WT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"; echo "teardown: lab exists? $([ -e "$LAB" ] && echo yes || echo no)"
