#!/usr/bin/env bash
# Live driver: real bin/fm-send.sh (head and base) against a disposable marked
# lab FM_HOME, delivering to real panes on a private fm-lab tmux socket.
# Usage: drive-fm-send.sh <head-root> <base-root>
set -u
HEAD_ROOT=$1 BASE_ROOT=$2
eval "$("$HEAD_ROOT/bin/fm-lab-home.sh" env 2>/tmp/fm-lab-env.$$)"
TEARDOWN=$(grep -o '[^ ]*/bin/fm-lab-home.sh teardown .*' /tmp/fm-lab-env.$$ | head -1)
rm -f /tmp/fm-lab-env.$$
LAB=$FM_HOME
echo "lab FM_HOME=$LAB"
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/fm-lab"
tmux -L fm-lab new-session -d -s lane -n fm-t1 'cat'
tmux -L fm-lab new-window -t lane -n fm-t2 'cat'
export TMUX="$SOCK,0,0"
mkdir -p "$LAB/config"; : > "$LAB/config/fleet-ledger"

reset_task() {  # <id> <status-content-or-empty>
  rm -rf "$LAB/state/$1".inbox "$LAB/state/$1".status
  printf 'window=lane:fm-%s\nkind=ship\n' "$1" > "$LAB/state/$1.meta"
  [ -n "$2" ] && printf '%s' "$2" > "$LAB/state/$1.status"
  tmux -L fm-lab send-keys -t "lane:fm-$1" C-l 2>/dev/null
  tmux -L fm-lab clear-history -t "lane:fm-$1"
}
snap() { (cd "$LAB/state" && find . -type f ! -name 'guard-events.jsonl' ! -name '.guard-*' -print | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(cksum < "$f")"; done); }
run() {  # <root> <args...>
  local root=$1; shift
  (cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
     FM_HOME="$LAB" FM_SEND_SETTLE=0 "$root/bin/fm-send.sh" "$@") >"$LAB/out" 2>"$LAB/err"
  echo "rc=$?"; echo "--- stdout:"; cat "$LAB/out"; echo "--- stderr:"; cat "$LAB/err"
}
drain() { echo "--- drain OPEN DECISIONS:"; FM_STATE_OVERRIDE="$LAB/state" "$HEAD_ROOT/bin/fm-wake-drain.sh" 2>/dev/null | grep -A6 'OPEN DECISIONS' || echo "(no OPEN DECISIONS section)"; }
pane() { echo "--- pane lane:fm-$1:"; tmux -L fm-lab capture-pane -p -t "lane:fm-$1" | grep -v '^$' || echo "(pane empty)"; }
inbox() { echo "--- inbox records:"; find "$LAB/state/$1.inbox" -type f 2>/dev/null | sort | while read -r f; do echo "[$f]"; cat "$f"; echo; done; [ -d "$LAB/state/$1.inbox" ] || echo "(no inbox)"; }
status() { echo "--- status file:"; cat "$LAB/state/$1.status" 2>/dev/null || echo "(none)"; }
hdr() { echo; echo "==================== $* ===================="; }
TWO=$'needs-decision [key=k1]: pick REST or RPC\nblocked [key=k2]: need the staging token\n'

for which in BASE HEAD; do
  root=$HEAD_ROOT; [ "$which" = BASE ] && root=$BASE_ROOT
  hdr "S1 [$which] bare send to lane with open k1+k2"
  reset_task t1 "$TWO"; b=$(snap); run "$root" t1 "go with REST"; sleep 1
  a=$(snap); [ "$b" = "$a" ] && echo "STATE: unchanged" || { echo "STATE: changed"; diff <(echo "$b") <(echo "$a"); }
  inbox t1; pane t1; drain
done

hdr "S2 [HEAD] --resolve-key k1"
reset_task t1 "$TWO"; run "$HEAD_ROOT" t1 --resolve-key k1 "go with REST"; sleep 1; status t1; inbox t1; pane t1; drain

hdr "S3 [HEAD] --answers-none"
reset_task t1 "$TWO"; run "$HEAD_ROOT" t1 --answers-none "routine nudge: keep going"; sleep 1; status t1; inbox t1; pane t1; drain

hdr "S4 [HEAD] --answers-none with --resolve-key (contradictory)"
reset_task t1 "$TWO"; b=$(snap); run "$HEAD_ROOT" t1 --answers-none --resolve-key k1 "go"; a=$(snap)
[ "$b" = "$a" ] && echo "STATE: unchanged" || echo "STATE: changed"; inbox t1

for which in BASE HEAD; do
  root=$HEAD_ROOT; [ "$which" = BASE ] && root=$BASE_ROOT
  hdr "S5 [$which] bare send to task with no open decision"
  reset_task t2 ""; run "$root" t2 "hello there"; sleep 1
  find "$LAB/state/t2.inbox" -type f | sort | while read -r f; do sed -E 's/[0-9]{10,}/<TS>/g' "$f" ; echo; done > "$LAB/t2-$which.rec"
  inbox t2; pane t2
done
hdr "S5 compare inbox record bytes (timestamps masked)"
diff "$LAB/t2-BASE.rec" "$LAB/t2-HEAD.rec" && echo "RECORDS IDENTICAL"
cat "$LAB/t2-HEAD.rec"

hdr "S6 [HEAD] --answers-none on task with no open decision"
reset_task t2 ""; run "$HEAD_ROOT" t2 --answers-none "hello there"; inbox t2

for which in BASE HEAD; do
  root=$HEAD_ROOT; [ "$which" = BASE ] && root=$BASE_ROOT
  hdr "S7 [$which] mistyped --resolve-key k9"
  reset_task t1 "$TWO"; b=$(snap); run "$root" t1 --resolve-key k9 "answer"; a=$(snap)
  [ "$b" = "$a" ] && echo "STATE: unchanged" || echo "STATE: changed"
done

RES=$'blocked [key=pending-reply-abcdef0123456789]: pending-reply-missed: no reply from secondmate\n'
hdr "S8a [HEAD] bare send, only open entry is reserved pending-reply key"
reset_task t1 "$RES"; run "$HEAD_ROOT" t1 "status please"; inbox t1
hdr "S8b [HEAD] --resolve-key pending-reply key"
reset_task t1 "$RES"; run "$HEAD_ROOT" t1 --resolve-key pending-reply-abcdef0123456789 "here is the reply"; status t1; drain
hdr "S8c [HEAD] --answers-none on reserved key"
reset_task t1 "$RES"; run "$HEAD_ROOT" t1 --answers-none "status please"; status t1; drain

hdr "S9 [HEAD] --key Enter to lane with open keys (not subject)"
reset_task t1 "$TWO"; run "$HEAD_ROOT" t1 --key Enter; drain

hdr "S10 [HEAD] -- ends options: literal text starting with --answers-none"
reset_task t1 "$TWO"; run "$HEAD_ROOT" t1 --answers-none -- "--answers-none is literal here"; inbox t1

hdr "S11 [HEAD] printed resend, legacy fm-t1 label selector, bare"
reset_task t1 "$TWO"; run "$HEAD_ROOT" fm-t1 "go"

tmux -L fm-lab kill-server
eval "$TEARDOWN" && rm -rf "$LAB" && echo "lab torn down"
