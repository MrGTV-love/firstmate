#!/usr/bin/env bash
# Live driver: runs the real bin/fm-send.sh (head, and base for comparison)
# against a disposable marked lab home with a REAL tmux server on the lab's
# private socket. Usage: drive-fm-send.sh <head-root> <base-root>
set -u
HEAD_ROOT=$1 BASE_ROOT=$2
eval "$("$HEAD_ROOT/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
trap 'tmux -L fm-lab kill-server 2>/dev/null; "$HEAD_ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1; rm -rf "$LAB"' EXIT
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
echo "lab home: $LAB"
tmux -L fm-lab new-session -d -s lab -n fm-placeholder -x 200 -y 50 'cat >/dev/null'
SOCK=$(tmux -L fm-lab display-message -p '#{socket_path}')
export TMUX="$SOCK,0,0"
export FM_SEND_SETTLE=0
S=$LAB/state
mkwin() { tmux -L fm-lab new-window -d -t lab -n "fm-$1" 'cat >/dev/null'; printf 'window=lab:fm-%s\nkind=ship\n' "$1" > "$S/$1.meta"; }
pane() { tmux -L fm-lab capture-pane -p -t "lab:fm-$1" | sed '/^$/d'; }
ledger() { [ -d "$S/$1.inbox" ] && find "$S/$1.inbox" -type f | sort | sed "s|$S/||" || echo "(no inbox dir)"; }
drain() { FM_STATE_OVERRIDE="$S" "$HEAD_ROOT/bin/fm-wake-drain.sh" 2>/dev/null | grep -E 'OPEN DECISIONS|\[key=' || echo "(drain lists no open decision)"; }
run() { # <label> <root> <args...>
  local label=$1 root=$2; shift 2
  echo
  echo "===== $label"
  echo "\$ fm-send.sh $*   [$( [ "$root" = "$HEAD_ROOT" ] && echo head || echo base )]"
  "$root/bin/fm-send.sh" "$@" >"$LAB/out" 2>"$LAB/err"; local rc=$?
  echo "exit=$rc"; echo "--- stdout"; cat "$LAB/out"; echo "--- stderr"; cat "$LAB/err"
}
state() { # <id>
  echo "--- status file $1"; sed -E 's/ \[at=[0-9]+\]//' "$S/$1.status" 2>/dev/null || echo "(none)"
  echo "--- inbox records"; ledger "$1"
  echo "--- pane text"; pane "$1"
  echo "--- pending-replies"; ls "$S/pending-replies" 2>/dev/null || echo "(none)"
  echo "--- drain"; drain
}
open2() { printf 'needs-decision [key=k1]: pick REST or RPC\nblocked [key=k2]: need the staging token\n' > "$S/$1.status"; }

echo "################ D1 base reproduces the defect"
mkwin b1; open2 b1
run "BASE bare send to task with open k1,k2" "$BASE_ROOT" b1 "go with REST"; state b1

echo; echo "################ D1(a) head bare send refuses"
mkwin t1; open2 t1
run "HEAD bare send to task with open k1,k2" "$HEAD_ROOT" t1 "go with REST"; state t1
run "HEAD bare send via legacy fm-<id> label" "$HEAD_ROOT" fm-t1 "go with REST"; state t1

echo; echo "################ D2(c) contradictory pair"
run "HEAD --answers-none + --resolve-key" "$HEAD_ROOT" t1 --answers-none --resolve-key k1 "go with REST"; state t1

echo; echo "################ D2(e) mistyped key, head vs base"
run "HEAD mistyped --resolve-key" "$HEAD_ROOT" t1 --resolve-key k9 "go with REST"
run "BASE mistyped --resolve-key" "$BASE_ROOT" t1 --resolve-key k9 "go with REST"; state t1

echo; echo "################ D2(b) none-flag delivers, keys stay open"
run "HEAD --answers-none" "$HEAD_ROOT" t1 --answers-none "routine check-in: please post status"; state t1
echo "--- record body"; cat "$S"/t1.inbox/*.msg 2>/dev/null || find "$S/t1.inbox" -type f -exec cat {} \;

echo; echo "################ D2(a) --resolve-key k1 closes k1 only"
run "HEAD --resolve-key k1" "$HEAD_ROOT" t1 --resolve-key k1 "go with REST"; state t1

echo; echo "################ repeated --answers-none accepted"
run "HEAD --answers-none --answers-none" "$HEAD_ROOT" t1 --answers-none --answers-none "second routine steer"; state t1

echo; echo "################ D3(c) --key and explicit backend target not subject"
run "HEAD --key Enter to task with open k2" "$HEAD_ROOT" t1 --key Enter
run "HEAD explicit backend target lab:fm-t1 (matches meta) text" "$HEAD_ROOT" lab:fm-t1 "explicit endpoint text"; state t1

echo; echo "################ typed plane (leading /) subject to the rule"
run "HEAD bare /help to task with open k2" "$HEAD_ROOT" t1 "/help"
run "HEAD --answers-none /help" "$HEAD_ROOT" t1 --answers-none "/help"; state t1

echo; echo "################ D1(e) reserved pending-reply key"
mkwin r1
printf 'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: secondmate reply overdue\n' > "$S/r1.status"
run "HEAD bare send to task with open reserved key" "$HEAD_ROOT" r1 "reply now"; state r1
run "HEAD --answers-none to reserved key task" "$HEAD_ROOT" r1 --answers-none "reply now"; state r1
run "HEAD --resolve-key reserved key" "$HEAD_ROOT" r1 --resolve-key pending-reply-abcdef0123456789 "reply now"; state r1

echo; echo "################ D1 paired: no open decision, byte-identical record head vs base"
mkwin n1; mkwin n2
printf 'working: busy\nresolved [key=old]: answered: done\n' > "$S/n1.status"
cp "$S/n1.status" "$S/n2.status"
run "HEAD bare send, no open decision" "$HEAD_ROOT" n1 "plain steer text"
run "BASE bare send, no open decision" "$BASE_ROOT" n2 "plain steer text"
h=$(find "$S/n1.inbox" -name '*.msg' | sort | head -1); b=$(find "$S/n2.inbox" -name '*.msg' | sort | head -1)
echo "--- head record: $h"; od -c "$h" | head -20
echo "--- base record: $b"; od -c "$b" | head -20
if cmp -s "$h" "$b"; then echo "RECORDS BYTE-IDENTICAL: yes"; else echo "RECORDS BYTE-IDENTICAL: no"; diff "$h" "$b"; fi
run "HEAD --answers-none, no open decision" "$HEAD_ROOT" n1 --answers-none "plain steer text 2"; state n1
