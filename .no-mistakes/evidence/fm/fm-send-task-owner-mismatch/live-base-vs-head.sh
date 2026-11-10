#!/usr/bin/env bash
# Same correct-owner and no-task-id steers through base cb411ea3 bin/ and head bin/,
# each in its own marked lab home; compare durable record bytes (minus at=) and tmux effects.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M72J0F8JK5E0YM7A7MKYVDN2
BASE=$TMPDIR/base; mkdir -p "$BASE"
git -C "$WT" archive cb411ea377a5441cf41af17d1f21db85020bfd79 bin | tar -x -C "$BASE"
for rev in base head; do
  [ $rev = base ] && BIN=$BASE/bin || BIN=$WT/bin
  cd "$WT"
  eval "$(bin/fm-lab-home.sh env 2>"$TMPDIR/e")"; TD=$(sed -n 's/^fm-lab-home: teardown: //p' "$TMPDIR/e")
  S=$FM_HOME/state; mkdir -p "$S"
  tmux -L fm-lab new-session -d -s lab -n driver "bash --norc --noprofile -i"
  tmux -L fm-lab new-window -d -t lab: -n fm-fm-slack-main-window-intake "bash --norc --noprofile -i"
  export TMUX="$TMUX_TMPDIR/tmux-$(id -u)/fm-lab,0,0" FM_SEND_SETTLE=0 FM_GUARD_EVENT_LOG=$TMPDIR/g-$rev.jsonl
  printf 'window=lab:fm-fm-slack-main-window-intake\nkind=ship\nharness=claude\n' > "$S/fm-slack-main-window-intake.meta"
  printf 'window=lab:fm-other\nkind=ship\nharness=claude\n' > "$S/other.meta"
  i=0
  for msg in 'Run the PR 370 fix round for fm-slack-main-window-intake now.' 'plain steer with no task id'; do
    i=$((i+1))
    "$BIN/fm-send.sh" fm-slack-main-window-intake "$msg" > "$TMPDIR/o" 2>"$TMPDIR/err"; rc=$?
    echo "$rev send$i exit=$rc stderr_tail=$(grep -v '^●\|gate agent lifecycle\|watcher still down' "$TMPDIR/err" | sed "s#$FM_HOME#<HOME>#g" | tr '\n' ' ')"
    grep -v '^at=' "$S/fm-slack-main-window-intake.inbox/00$i.msg" > "$TMPDIR/$rev-$i.rec"
  done
  ls "$S" | grep -v '^\.' | sed "s/^/$rev state: /"
  tmux -L fm-lab kill-server; unset TMUX; eval "$TD"
done
for i in 1 2; do cmp "$TMPDIR/base-$i.rec" "$TMPDIR/head-$i.rec" && echo "record $i: base and head bytes identical (excluding at= timestamp)"; done
echo "--- head record 1:"; cat "$TMPDIR/head-1.rec"
