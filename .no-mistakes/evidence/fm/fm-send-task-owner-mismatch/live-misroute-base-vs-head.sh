#!/usr/bin/env bash
# The 15:57Z misroute (intake fix round sent to secondmate fm-mini) through base
# cb411ea3 bin/ and head bin/, each in its own marked lab home.
WT=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M72J0F8JK5E0YM7A7MKYVDN2
BASE=$TMPDIR/base; mkdir -p "$BASE"; git -C "$WT" archive cb411ea377a5441cf41af17d1f21db85020bfd79 bin | tar -x -C "$BASE"
for rev in base head; do
  [ $rev = base ] && BIN=$BASE/bin || BIN=$WT/bin
  cd "$WT"; eval "$(bin/fm-lab-home.sh env 2>"$TMPDIR/e")"; TD=$(sed -n 's/^fm-lab-home: teardown: //p' "$TMPDIR/e")
  S=$FM_HOME/state; M=$FM_HOME/projects/mini-home; mkdir -p "$S" "$M/state"
  tmux -L fm-lab new-session -d -s lab -n fm-fm-mini "bash --norc --noprofile -i"
  export TMUX="$TMUX_TMPDIR/tmux-$(id -u)/fm-lab,0,0" FM_SEND_SETTLE=0 FM_GUARD_EVENT_LOG=$TMPDIR/g-$rev.jsonl
  printf 'window=lab:fm-fm-slack-main-window-intake\nkind=ship\nharness=claude\n' > "$S/fm-slack-main-window-intake.meta"
  printf 'window=lab:fm-fm-mini\nendpoint_task_id=fm-mini\nworktree=%s\nharness=claude\nkind=secondmate\nmode=secondmate\nhome=%s\n' "$M" "$M" > "$S/fm-mini.meta"
  "$BIN/fm-send.sh" fm-mini 'Run the PR 370 fix round for fm-slack-main-window-intake now.' >/dev/null 2>"$TMPDIR/err"; rc=$?
  echo "$rev: fm-send fm-mini '<intake fix round>' exit=$rc"
  grep -v '^●\|gate agent lifecycle\|watcher still down' "$TMPDIR/err" | sed "s#$FM_HOME#<HOME>#g;s/^/  /"
  echo "  fm-mini inbox: $(ls "$S/fm-mini.inbox" 2>/dev/null | tr '\n' ' ' || true)$([ -d "$S/fm-mini.inbox" ] || echo ABSENT)"
  echo "  pending replies armed: $(ls "$S/pending-replies" 2>/dev/null | grep -vc '^\.')"
  tmux -L fm-lab kill-server; unset TMUX; eval "$TD"
done
