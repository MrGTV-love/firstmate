#!/usr/bin/env bash
# Extra adversarial probes against the real hook on a plain-checkout tree of TARGET.
set -u
W=${WORKTREE:?}; TARGET=${TARGET:?}
cd "$W"
unset FM_GUARD_GRACE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
L=$FM_HOME; S=$L/state; C=$L/projects/primary
export FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100
mkdir -p "$C"; git archive "$TARGET" | tar -x -C "$C"
git -C "$C" init -q; git -C "$C" -c user.name=lab -c user.email=lab@example.invalid add -A -f; git -C "$C" -c user.name=lab -c user.email=lab@example.invalid commit -qm tree --no-verify
echo "implementation_root=$W head=$TARGET tree=$(git -C "$C" rev-parse 'HEAD^{tree}') expected=$(git rev-parse "$TARGET^{tree}") lab=$L"
sleep 3000 & HOLD=$!; disown $HOLD 2>/dev/null
trap 'kill $HOLD 2>/dev/null; chmod -R u+rwX "$L" 2>/dev/null; "$W/bin/fm-lab-home.sh" teardown "$L" && rm -rf "$L"' EXIT
clean() { chmod -R u+rwX "$S" 2>/dev/null; find "$S" -mindepth 1 -maxdepth 1 ! -name .fm-lab-tmux-dir -exec rm -rf {} + ; : >"$S/task1.meta"; }
hook() { OUT=$(printf '{"stop_hook_active":true,"session_id":"%s"}' "${1:-sess-a}" | FM_HOME=$L bash "$C/bin/fm-turnend-guard.sh" --claude 2>&1); RC=$?; }
seqn() { local n=$1 sid=${2:-sess-a} i rcs=""; for ((i=0;i<n;i++)); do hook "$sid"; rcs+="$RC "; done; echo "   rc=[$rcs] budget=$(tr '\n' ' ' <"$S/.turnend-claude-blocks" 2>/dev/null)"; echo "   events: $(jq -c '[.decision,.cleared_by]' "$S/guard-events.jsonl" 2>/dev/null | sort | uniq -c | tr '\n' ';')"; }

echo "A1 garbage budget count: stops stay inside the budget"
clean; printf 'session=sess-a\ncount=abc\nepoch=\n' >"$S/.turnend-claude-blocks"; seqn 6
echo "A2 budget file is empty"
clean; : >"$S/.turnend-claude-blocks"; seqn 6
echo "A3 stale budget lock with a dead pid is reclaimed: normal count, not budget-unavailable"
clean; mkdir "$S/.turnend-claude-blocks.lock"; echo 999999 >"$S/.turnend-claude-blocks.lock/pid"; seqn 6
echo "A4 budget lock path is a plain file"
clean; : >"$S/.turnend-claude-blocks.lock"; seqn 6
echo "A5 budget file is read-only (the guard's rename still replaces it)"
clean; printf 'session=sess-a\ncount=1\nepoch=\n' >"$S/.turnend-claude-blocks"; chmod 444 "$S/.turnend-claude-blocks"; seqn 5
echo "A6 a new session gets its own three blocks; the old session does not reset the count to a lower one"
clean; seqn 5 sess-a; seqn 5 sess-b
echo "A7 budget override 1 and invalid override"
clean; FM_CLAUDE_TURNEND_BLOCK_BUDGET=1 seqn 3
clean; FM_CLAUDE_TURNEND_BLOCK_BUDGET=abc seqn 5
echo "A8 twelve parallel Stops in one session never exceed three exit-2 blocks"
clean; d=$(mktemp -d); for i in $(seq 1 12); do ( printf '{"stop_hook_active":true,"session_id":"sess-a"}' | FM_HOME=$L bash "$C/bin/fm-turnend-guard.sh" --claude >/dev/null 2>&1; echo $? >"$d/$i" ) & done; wait
echo "   exits: $(cat "$d"/* | sort | uniq -c | tr '\n' ';') budget=$(tr '\n' ' ' <"$S/.turnend-claude-blocks" 2>/dev/null)"; echo "   events: $(jq -c '[.decision,.cleared_by]' "$S/guard-events.jsonl" 2>/dev/null | sort | uniq -c | tr '\n' ';')"; rm -rf "$d"
echo "A9 state directory unreadable (chmod 000)"
clean; chmod 000 "$S"; seqn 3; chmod 755 "$S"
echo "A10 state directory read-only, budget file exists with count already past budget"
clean; printf 'session=sess-a\ncount=9\nepoch=\n' >"$S/.turnend-claude-blocks"; chmod 555 "$S"; seqn 3; chmod 755 "$S"
echo "A11 exit output of a budget-unavailable stop is valid JSON for the harness"
clean; mkdir "$S/.turnend-claude-blocks"; hook; echo "   rc=$RC json_ok=$(jq -e .systemMessage <<<"$OUT" >/dev/null 2>&1 && echo yes || echo no) msg=$(jq -r .systemMessage <<<"$OUT" | cut -c1-260)"
echo "A12 exit output of an exhausted stop is valid JSON"
clean; seqn 3 >/dev/null; hook; hook; echo "   rc=$RC json_ok=$(jq -e .systemMessage <<<"$OUT" >/dev/null 2>&1 && echo yes || echo no) msg=$(jq -r .systemMessage <<<"$OUT" | cut -c1-260)"
echo "A13 secondmate busy record: blocked Stop records busy, allowed Stop records idle"
clean
W2=$(mktemp -t fm-busy-writer); cat >"$W2" <<'WEOF'
#!/usr/bin/env bash
echo "$*" >>"$BUSY_LOG"
WEOF
chmod +x "$W2"; export BUSY_LOG=$(mktemp -t fm-busy-log)
printf 'writer=%s\nstate=%s\nid=sm\ngen=1\n' "$W2" "$L/data" >"$C/.fm-busy-stop"
seqn 4 >/dev/null; mkdir -p "$S/x"; rm -rf "$S/x"; rm -f "$S/.turnend-claude-blocks"; mkdir "$S/.turnend-claude-blocks"; hook
awk '{print "   " $3, $4, $NF}' "$BUSY_LOG"; rm -f "$W2" "$BUSY_LOG" "$C/.fm-busy-stop"
echo done
