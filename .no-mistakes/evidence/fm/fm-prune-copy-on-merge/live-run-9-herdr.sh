#!/usr/bin/env bash
# Round 3: S5h - a job in the task's HERDR pane (a named fm-lab-* Herdr session
# provisioned by bin/fm-herdr-lab.sh) keeps the copy with one wake before
# teardown. The pool, records and prune are real; the teardown is a refusing
# logger, so a missed pane check shows as a teardown call instead of touching
# any Herdr state through teardown.
set -u
. "$(dirname "$0")/live-lab.sh"
lab_init
HL="$WT/bin/fm-herdr-lab.sh"
SESSION=$("$HL" name prune) || { echo "herdr lab name failed"; exit 1; }
echo "herdr lab session: $SESSION"
"$HL" provision "$SESSION" 2>&1 | tail -3
cat > "$LAB/bin/teardown-refuse" <<X
#!/usr/bin/env bash
printf '=== teardown %s\\n' "\$*" >> "$LAB/teardown-calls.log"
echo "REFUSED: lab stub (the pane check should have kept this copy)" >&2
exit 1
X
chmod +x "$LAB/bin/teardown-refuse"
export FM_MERGE_PRUNE_TEARDOWN_BIN="$LAB/bin/teardown-refuse"
new_task th1 81; C=$COPY
ws=$("$HL" run "$SESSION" workspace create --cwd "$C" --label prune-lab --no-focus 2>&1); echo "workspace create: $ws" | head -c 600; echo
HP=$(printf '%s' "$ws" | jq -r '.. | objects | .pane_id? // empty' 2>/dev/null | head -1)
echo "herdr pane: $HP"
"$HL" run "$SESSION" pane run "$HP" "sleep 906" >/dev/null 2>&1; sleep 3
info=$("$HL" run "$SESSION" pane process-info --pane "$HP" 2>&1); echo "process-info: $info" | head -c 600; echo
SP=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty')
echo "herdr pane shell pid $SP children: $(pgrep -lP "$SP" | tr '\n' ' ')"
sed -i.bak -e "s/^backend=.*/backend=herdr/" -e "s#^window=.*#window=$SESSION:$HP#" "$STATE/th1.meta"
grep -E '^(backend|window)=' "$STATE/th1.meta"
prune arm th1 >/dev/null 2>&1
prune run th1 --now >/dev/null 2>&1; prune run th1 --now >/dev/null 2>&1
show th1
echo "teardown calls for th1: $(grep -c '^=== teardown th1' "$LAB/teardown-calls.log" 2>/dev/null || echo 0)"
echo "job alive: $(pgrep -f 'sleep 906' >/dev/null && echo yes || echo no)"
pkill -f 'sleep 906'
"$HL" teardown "$SESSION" 2>&1 | tail -2; echo "herdr lab teardown rc=$?"
