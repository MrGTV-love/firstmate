#!/usr/bin/env bash
# S6 (intent bug 2): the pre-allocation check refuses a new start only while a
# record's NESTED current copy sits in an UNLEASED slot, prints the lease remedy,
# and lets the start proceed once that slot is durably leased. Leased slots
# 1 and 2 also hold records' current copies and must not block.
. /tmp/fm-live.UI8CJx/lib.sh
cd "$WT_ROOT" || exit 1
TMUXV=$(cat "$W/lab-tmux-env")
T=live-new-scout2
spawn() { fm env TMUX="$TMUXV" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR= bin/fm-spawn.sh "$T" "$PROJ" --scout --backend tmux --harness omp; }
NESTED="$POOLDIR/10/proj/.claude/worktrees/liver2-claimant-b"
write_meta liver2-claimant-b "window=fmses:fm-liver2-claimant-b" "endpoint_task_id=liver2-claimant-b" "worktree=$NESTED" \
  "project=$PROJ" "harness=claude" "kind=ship" "mode=no-mistakes" "branch=fm/liver2-claimant-b" "spawn_gen=s6" "prior_worktree=$POOLDIR/10/proj"
say "records and lease state before"
for m in "$LAB"/state/*.meta; do echo "$(basename "$m"): $(grep ^worktree= "$m")"; done
th status 2>/dev/null | sed 1,4d | awk '$1<=10'
cp "$POOLDIR/treehouse-state.json" "$W/s6-th-before"
say "step 1: start a new scout while liver2-claimant-b's nested current copy sits in unleased slot 10"
out=$(spawn 2>&1); rc=$?
printf '%s\n[exit %s]\n' "$(grep -v -e '^●' <<<"$out")" "$rc"
check "refuses" [ "$rc" -ne 0 ]
check "refusal names slot 10 and the task" grep -Fq "proj-94bea6/10/proj contains task liver2-claimant-b's current copy" <<<"$out"
check "refusal prints the state-only lease remedy" grep -Fq "treehouse lease '10' --lease-holder 'liver2-claimant-b'" <<<"$out"
check "leased slot 1 (nested current copy) is not blamed" bash -c "! grep -Eq 'proj-94bea6/1/proj contains' <<<\"\$1\"" _ "$out"
check "no new record published" [ ! -e "$LAB/state/$T.meta" ]
check "Treehouse state unchanged by refused start" cmp -s "$W/s6-th-before" "$POOLDIR/treehouse-state.json"
check "no worker window opened" bash -c "! env -u TMUX TMUX_TMPDIR='$LAB/tmux' tmux list-windows -t fmses -F '#W' | grep -qx 'fm-$T'"
say "step 2: run the printed lease command (state-only)"
fingerprint "$NESTED" > "$W/s6-nested.fp"
th lease 10 --lease-holder liver2-claimant-b 2>&1 | tail -1
check "lease did not change the nested copy" bash -c ". $W/lib.sh; fingerprint '$NESTED' | cmp -s - '$W/s6-nested.fp'"
say "step 3: start the new scout again"
out=$(timeout 240 bash -c "$(declare -f fm spawn); LAB='$LAB' W='$W' TMUXV='$TMUXV' T='$T' PROJ='$PROJ'; spawn" 2>&1); rc=$?
printf '%s\n[exit %s]\n' "$(grep -v -e '^●' <<<"$out")" "$rc"
check "allocation check passes: no refusal" bash -c "! grep -q 'refusing allocation' <<<\"\$1\"" _ "$out"
check "a new slot was allocated and the scout spawned" grep -q "spawned $T .*worktree=" <<<"$out"
check "the new worker did not take a leased slot (1,2,3,4,5,10)" bash -c "! grep -Eq 'worktree=.*/proj-94bea6/(1|2|3|4|5|10)/proj$' <<<\"\$1\"" _ "$out"
check "leased slot 10 nested copy unchanged" bash -c ". $W/lib.sh; fingerprint '$NESTED' | cmp -s - '$W/s6-nested.fp'"
labtmux list-windows -t fmses -F '#W'
labtmux kill-window -t "fmses:fm-$T" 2>/dev/null && echo "stopped lab worker window fm-$T (no model configured in the lab HOME)"
say "S6 result: FAILS=$FAILS"
