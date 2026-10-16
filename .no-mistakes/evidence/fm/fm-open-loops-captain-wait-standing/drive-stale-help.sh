#!/usr/bin/env bash
# Live: help line names --hold; a quota-stale ledger keeps a standing hold; the hold ending on a stale ledger re-presents.
set -u
BIN=$1; KEY=d1-expired-preservation-ledger; ORIGIN=vernant-d1-intake
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); trap 'rm -rf "$LAB"' EXIT
"$BIN/fm-lab-home.sh" create "$LAB" >/dev/null
NOW=$(date -u +%s); iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
fm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_SUPERVISION_ACTOR=main "$@"; }
held() { printf '## In flight\n- [ ] %s - Decide (repo: firstmate) (kind: ship) (hold: need captain decision) (hold-kind: captain)\n  Captain hold set: %s\n\n## Queued\n\n## Done\n' "$KEY" "$(iso $((NOW-36000)))" > "$LAB/data/backlog.md"; }
held
printf 'blocked [at=%s] [key=%s]: needs captain decision\n' "$((NOW-36000))" "$KEY" > "$LAB/state/$ORIGIN.status"
fm "$BIN/fm-open-loops.sh" --heartbeat >/dev/null
ROW=$(jq -r '.rows[]|select(.owner=="firstmate")|.id' "$LAB/state/open-loops.json")
CROW=$(jq -r '.rows[]|select(.owner=="captain")|.id' "$LAB/state/open-loops.json")
echo "--- present-overdue output (help line)"
fm "$BIN/fm-open-loops.sh" --present-overdue | grep -E '^help:' 
wake() { fm bash -c '. "$1"; fm_wake_append check report "check: $2"' _ "$BIN/fm-wake-lib.sh" "$1"; }
bnd() { grep -oE -e '--ack-through [0-9]+ --recovery-generation [A-Za-z0-9._-]+' "$1" | head -1; }
wake t1; fm "$BIN/fm-wake-drain.sh" >/dev/null 2>"$LAB/e"; B=$(bnd "$LAB/e")
fm "$BIN/fm-open-loops.sh" action "$CROW" escalated --evidence "captain hold" >/dev/null
fm "$BIN/fm-open-loops.sh" action "$ROW" escalated --evidence "asked" 
fm "$BIN/fm-wake-drain.sh" $B >/dev/null 2>&1; echo "clear exit $?"
echo "--- mark ledger quota-stale (as the collector does when the GitHub quota floor trips)"
jq '.stale=true|.stale_reason="quota low (500 of 5000); resets in an hour"|.complete=false|.rows|=map(.stale=true)' "$LAB/state/open-loops.json" > "$LAB/x" && mv "$LAB/x" "$LAB/state/open-loops.json"
wake t2; fm "$BIN/fm-wake-drain.sh" >"$LAB/o" 2>"$LAB/e"; B=$(bnd "$LAB/e")
echo "stale+held: row presented=$(grep -c "$ORIGIN:$KEY" "$LAB/o") (want 0)"
fm "$BIN/fm-wake-drain.sh" $B >/dev/null 2>&1; echo "stale+held: clear exit $? (want 0)"
printf '## In flight\n\n## Queued\n\n## Done\n- [x] %s - Decide (repo: firstmate) (kind: ship)\n' "$KEY" > "$LAB/data/backlog.md"
wake t3; fm "$BIN/fm-wake-drain.sh" >"$LAB/o" 2>"$LAB/e"; B=$(bnd "$LAB/e")
echo "stale+answered: row presented=$(grep -c "$ORIGIN:$KEY" "$LAB/o") (want 1)"
fm "$BIN/fm-wake-drain.sh" $B >/dev/null 2>&1; echo "stale+answered: clear exit $? (want 1)"
