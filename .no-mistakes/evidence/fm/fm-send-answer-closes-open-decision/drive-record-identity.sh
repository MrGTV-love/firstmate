#!/usr/bin/env bash
# Paired fixture: same text, task with no open decision; head vs base inbox
# record compared byte-for-byte after removing only the per-write at= stamp.
set -u
HEAD_ROOT=$1 BASE_ROOT=$2
eval "$("$HEAD_ROOT/bin/fm-lab-home.sh" env 2>/dev/null)"; LAB=$FM_HOME
trap 'tmux -L fm-lab kill-server 2>/dev/null; "$HEAD_ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
S=$LAB/state
tmux -L fm-lab new-session -d -s lab -n fm-n1 -x 200 -y 50 'cat >/dev/null'; tmux -L fm-lab new-window -d -t lab -n fm-n2 'cat >/dev/null'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0" FM_SEND_SETTLE=0
for id in n1 n2; do printf 'window=lab:fm-%s\nkind=ship\n' $id > "$S/$id.meta"; printf 'working: busy\nresolved [key=old]: answered: done\n' > "$S/$id.status"; done
text=$'plain steer text\nsecond line'
"$HEAD_ROOT/bin/fm-send.sh" n1 "$text" >/dev/null 2>&1; echo "head bare send exit=$?"
"$BASE_ROOT/bin/fm-send.sh" n2 "$text" >/dev/null 2>&1; echo "base bare send exit=$?"
h=$S/n1.inbox/001.msg b=$S/n2.inbox/001.msg
echo "--- head record"; cat "$h"; echo; echo "--- base record"; cat "$b"; echo
grep -v '^at=' "$h" > "$LAB/h"; grep -v '^at=' "$b" > "$LAB/b"
if cmp "$LAB/h" "$LAB/b"; then echo "RECORDS BYTE-IDENTICAL EXCEPT THE at= WRITE STAMP: yes ($(wc -c < "$h" | tr -d ' ') vs $(wc -c < "$b" | tr -d ' ') bytes)"; else echo "RECORDS DIFFER BEYOND at=: yes"; diff "$LAB/h" "$LAB/b"; fi
diff "$h" "$b" | sed 's/^/full diff: /'
