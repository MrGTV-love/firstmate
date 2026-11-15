#!/usr/bin/env bash
# Live driver: real bin/fm-send.sh (head and base) against a disposable marked
# lab FM_HOME and a real tmux server on the private fm-lab socket, whose worker
# pane runs `cat` as a stand-in lane. No stub transports.
# Usage: drive-live.sh <worktree> <base-root>
set -u
WT=$1; BASE=$2
eval "$("$WT/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
echo "lab home: $LAB  (tmux dir: $TMUX_TMPDIR)"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
tmux -L fm-lab new-session -d -s lab -n fm-t1 -x 200 -y 50 cat
tmux -L fm-lab new-window -d -t lab -n fm-t2 cat
tmux -L fm-lab new-window -d -t lab -n fm-mate cat
SOCK=$(tmux -L fm-lab display-message -p '#{socket_path}')
export TMUX="$SOCK,0,0"   # fm-send's plain `tmux` calls reach the lab socket only
export FM_SEND_SETTLE=0

S=$LAB/state
two_key() { # <task>
  printf 'window=lab:fm-%s\nkind=ship\n' "$1" > "$S/$1.meta"
  printf 'needs-decision [key=k1]: pick REST or RPC\nblocked [key=k2]: need the staging token\n' > "$S/$1.status"
  rm -rf "$S/$1.inbox"
}
snap() { (cd "$LAB" && find state -print | LC_ALL=C sort | while IFS= read -r p; do
  [ -f "$p" ] && printf 'f %s %s\n' "$p" "$(cksum < "$p")" || printf 'd %s\n' "$p"; done); }
pane() { tmux -L fm-lab capture-pane -p -t "lab:$1" | sed '/^$/d' | tail -3; }
drain() { "$1/bin/fm-wake-drain.sh" 2>/dev/null | grep -E 'key=' || echo "(no open decisions listed)"; }
run() { # <label> <bin-root> <args...>
  local label=$1 root=$2; shift 2
  echo; echo "=== $label"
  echo "\$ fm-send.sh $*"
  "$root/bin/fm-send.sh" "$@" >"$LAB/out" 2>"$LAB/err"; rc=$?
  echo "exit=$rc"
  sed 's/^/  stdout| /' "$LAB/out"; grep -v '^\[fm-guard\]' "$LAB/err" | sed 's/^/  stderr| /'
}

echo; echo "##### S1 bare send, open k1+k2 (HEAD)"
two_key t1; before=$(snap)
run "head bare" "$WT" t1 "go with REST"
after=$(snap)
[ "$before" = "$after" ] && echo "STATE: unchanged (no inbox, no status line)" || { echo "STATE CHANGED:"; diff <(echo "$before") <(echo "$after"); }
echo "pane fm-t1:"; pane fm-t1
echo "drain:"; drain "$WT"

echo; echo "##### S1-base same bare send on BASE (the defect)"
two_key t2
run "base bare" "$BASE" t2 "go with REST"
echo "inbox: $(ls "$S/t2.inbox" 2>/dev/null | tr '\n' ' ')"; echo "pane fm-t2:"; pane fm-t2
echo "status log:"; cat "$S/t2.status"
echo "drain (keys still open after delivered answer):"; drain "$WT"
rm -rf "$S/t2.inbox" "$S/t2.status" "$S/t2.meta"

echo; echo "##### S2 --answers-none (HEAD)"
two_key t1; st_before=$(cat "$S/t1.status")
run "head none" "$WT" t1 --answers-none "unrelated nudge"
echo "record:"; sed 's/^/  /' "$S/t1.inbox/"*.msg
[ "$st_before" = "$(cat "$S/t1.status")" ] && echo "STATUS: no line appended" || echo "STATUS CHANGED"
echo "pane fm-t1:"; pane fm-t1
echo "drain:"; drain "$WT"

echo; echo "##### S3 --resolve-key k1 (HEAD)"
run "head resolve k1" "$WT" t1 --resolve-key k1 "REST it is"
echo "status log:"; sed 's/^/  /' "$S/t1.status"
echo "drain:"; drain "$WT"
run "head bare after k1 closed (only k2 left)" "$WT" t1 "next"

echo; echo "##### S4 contradictory pair (HEAD)"
two_key t1; before=$(snap)
run "head none+resolve" "$WT" t1 --answers-none --resolve-key k1 "both"
run "head resolve+none" "$WT" t1 --resolve-key k1 --answers-none "both"
run "head split-form value --answers-none" "$WT" t1 --resolve-key --answers-none "both"
[ "$before" = "$(snap)" ] && echo "STATE: unchanged after all three refusals" || echo "STATE CHANGED"
run "head repeated --answers-none" "$WT" t1 --answers-none --answers-none "twice"

echo; echo "##### S5 mistyped key refused as on base"
two_key t1
run "head mistyped" "$WT" t1 --resolve-key nope "answer"
run "base mistyped" "$BASE" t1 --resolve-key nope "answer"

echo; echo "##### S6 no open decision: delivered, record same as base"
printf 'window=lab:fm-t1\nkind=ship\n' > "$S/t1.meta"
printf 'needs-decision [key=old]: choose\nresolved [key=old]: answered: done\nworking: busy\n' > "$S/t1.status"
rm -rf "$S/t1.inbox"
run "head bare, nothing open" "$WT" t1 "plain steer"
h=$(sed '/^at=/d' "$S/t1.inbox/001.msg"); rm -rf "$S/t1.inbox"
run "base bare, nothing open" "$BASE" t1 "plain steer"
b=$(sed '/^at=/d' "$S/t1.inbox/001.msg"); rm -rf "$S/t1.inbox"
[ "$h" = "$b" ] && echo "RECORD: head == base (at= line aside)" || { echo "RECORD DIFFERS"; diff <(echo "$h") <(echo "$b"); }
run "head none, nothing open" "$WT" t1 --answers-none "plain steer"
n=$(sed '/^at=/d' "$S/t1.inbox/001.msg"); rm -rf "$S/t1.inbox"
[ "$n" = "$b" ] && echo "RECORD: none-flag == base (at= line aside)" || echo "RECORD DIFFERS"
run "head flag-like message words, nothing open" "$WT" t1 please run --resolve-key k1 later
echo "record body:"; sed 's/^/  /' "$S/t1.inbox/001.msg"; rm -rf "$S/t1.inbox"
run "base flag-like message words, nothing open" "$BASE" t1 please run --resolve-key k1 later
rm -rf "$S/t1.inbox"

echo; echo "##### S7 dash key split form as base"
printf 'blocked [key=-urgent]: choose\n' > "$S/t1.status"
run "head --resolve-key -urgent" "$WT" t1 --resolve-key -urgent "go with the fix"
echo "drain:"; drain "$WT"; rm -rf "$S/t1.inbox"

echo; echo "##### S8 -- escape sends literal flag text"
two_key t1
run "head -- --answers-none" "$WT" t1 --answers-none -- --answers-none is literal text
echo "record body:"; sed 's/^/  /' "$S/t1.inbox/001.msg"
run "head bare -- (no choice) still refuses" "$WT" t1 -- --answers-none text

echo; echo "##### S9 reserved pending-reply key"
corr=abcdef0123456789; key=pending-reply-$corr
printf 'window=lab:fm-mate\nkind=ship\n' > "$S/mate.meta"
printf 'blocked [key=%s]: pending-reply-missed: task=mate pending-reply-id=%s request=ship it\n' "$key" "$corr" > "$S/mate.status"
run "head bare to reserved" "$WT" mate "carry on"
run "head none to reserved" "$WT" mate --answers-none "carry on"
echo "drain:"; drain "$WT"
run "head resolve reserved" "$WT" mate --resolve-key "$key" "ack, false escalation"
echo "status log:"; sed 's/^/  /' "$S/mate.status"
echo "drain:"; drain "$WT"

echo; echo "##### S10 not subject: --key Enter and explicit backend target"
two_key t1
run "head --key Enter" "$WT" t1 --key Enter
run "head explicit backend target" "$WT" lab:fm-t2 "typed text"
echo "pane fm-t2:"; pane fm-t2

echo; echo "##### S11 promote's printed next: command run as-is (flagless) on a lane with open key"
printf 'window=lab:fm-t1\nkind=scout\n' > "$S/t1.meta"
printf 'needs-decision [key=ship-it]: should I build it?\n' > "$S/t1.status"; rm -rf "$S/t1.inbox"
run "head flagless promote-style send" "$WT" t1 "Promoted: ship it"

echo; echo "##### pane transcript (worker stand-in fm-t1)"; tmux -L fm-lab capture-pane -p -t lab:fm-t1 | sed '/^$/d'

tmux -L fm-lab kill-server
"$WT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"
echo; echo "teardown done: lab exists? $([ -e "$LAB" ] && echo yes || echo no)"
