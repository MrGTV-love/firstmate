#!/usr/bin/env bash
# Live driver: real fm-open-loops.sh collector + real fm-wake-drain.sh in a disposable lab home.
# Usage: drive-live.sh <bin-dir> <label>
# Scenario: firstmate-owned status question row "vernant-d1-intake:d1-expired-preservation-ledger"
# whose captain-held backlog task is "d1-expired-preservation-ledger" (the incident shape).
set -u
BIN=$1; LABEL=$2
REPO_ROOT=$(cd "$BIN/.." && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
"$BIN/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || mkdir -p "$LAB"/{state,data,config,projects}
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/projects"
NOW=$(date -u +%s)
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
KEY=d1-expired-preservation-ledger
ORIGIN=vernant-d1-intake

fm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
         -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_SUPERVISION_ACTOR=main "$@"; }
loops() { fm "$BIN/fm-open-loops.sh" "$@"; }
drain() { fm "$BIN/fm-wake-drain.sh" "$@"; }
wake() { fm bash -c '. "$1"; fm_wake_append check report "check: $2"' _ "$BIN/fm-wake-lib.sh" "$1"; }
queued() { drain --queued | wc -l | tr -d ' '; }
backlog_held() {
  cat > "$LAB/data/backlog.md" <<EOF
## In flight
- [ ] $KEY - Decide expired preservation ledger (repo: firstmate) (kind: ship) (hold: need captain decision on ledger expiry) (hold-kind: captain)
  Captain hold set: $(iso $((NOW-36000)))

## Queued

## Done
EOF
}
backlog_answered() {
  cat > "$LAB/data/backlog.md" <<EOF
## In flight

## Queued

## Done
- [x] $KEY - Decide expired preservation ledger (repo: firstmate) (kind: ship)
EOF
}
step() { printf '\n=== [%s] %s\n' "$LABEL" "$*"; }
rc() { printf '  -> exit %s\n' "$1"; }

backlog_held
printf 'blocked [at=%s] [key=%s]: needs captain decision on ledger expiry\n' "$((NOW-36000))" "$KEY" > "$LAB/state/$ORIGIN.status"

step "1 collect the ledger with the real collector (--heartbeat)"
loops --heartbeat >/dev/null; rc $?
ROW=$(jq -r --arg s "$ORIGIN:$KEY" '.rows[]|select(.subject==$s)|.id' "$LAB/state/open-loops.json")
OWNER=$(jq -r --arg s "$ORIGIN:$KEY" '.rows[]|select(.subject==$s)|.owner' "$LAB/state/open-loops.json")
echo "  firstmate-owned incident row id=$ROW owner=$OWNER"

step "2 first handling turn: drain presents the overdue row; clear is refused without a receipt"
wake turn1
drain >"$LAB/d1.out" 2>"$LAB/d1.err"; rc $?
grep -E "OVERDUE|$ORIGIN:$KEY" "$LAB/d1.out" | head -3
B=$(grep -oE -e '--ack-through [0-9]+ --recovery-generation [A-Za-z0-9._-]+' "$LAB/d1.err" | head -1)
echo "  boundary: $B"
# shellcheck disable=SC2086
drain $B >/dev/null 2>"$LAB/a1.err"; rc $?
head -c 300 "$LAB/a1.err"; echo

step "3 record escalated receipt (no --hold: the key binds the captain-held task automatically)"
CROW=$(jq -r '.rows[]|select(.owner=="captain")|.id' "$LAB/state/open-loops.json")
echo "  (the collector also emits the captain-owned hold row $CROW; it takes its own standing receipt)"
loops action "$CROW" escalated --evidence "captain hold is the decision" >/dev/null; rc $?
loops action "$ROW" escalated --evidence "asked the captain to decide the ledger expiry"; rc $?
echo "  stored hold: $(jq -c --arg r "$ROW" '.handling.actions[$r].hold' "$LAB/state/open-loops.json")"
# shellcheck disable=SC2086
drain $B >/dev/null 2>"$LAB/a2.err"; rc $?
echo "  (exit 0 above = the wake clear succeeded)"
echo "  queued wake records after clear: $(queued)"

step "4 the pile-up cannot form: five later handling turns over two days, with re-collection each time"
for n in 1 2 3 4 5; do
  T=$((NOW + n * 36000))
  FM_OPEN_LOOPS_NOW=$T loops --heartbeat >/dev/null
  wake "later$n"
  FM_OPEN_LOOPS_NOW=$T drain >"$LAB/l$n.out" 2>"$LAB/l$n.err"; r1=$?
  B2=$(grep -oE -e '--ack-through [0-9]+ --recovery-generation [A-Za-z0-9._-]+' "$LAB/l$n.err" | head -1)
  # shellcheck disable=SC2086
  FM_OPEN_LOOPS_NOW=$T drain $B2 >/dev/null 2>&1; r2=$?
  pres=$(grep -c "$ORIGIN:$KEY" "$LAB/l$n.out")
  echo "  turn $n: drain exit=$r1 row presented=$pres clear exit=$r2 queued after=$(queued)"
done
echo "  --check-actions exit: $(loops --check-actions >/dev/null 2>&1; echo $?)"
echo "  row still visible in report: $(loops --report | grep -c "$ORIGIN:$KEY")"

step "5 the captain answers the hold: the row is presented again and clear is refused until a new action"
backlog_answered
loops --heartbeat >/dev/null
wake after-answer
drain >"$LAB/p.out" 2>"$LAB/p.err"; rc $?
echo "  row presented again: $(grep -c "$ORIGIN:$KEY" "$LAB/p.out")"
B3=$(grep -oE -e '--ack-through [0-9]+ --recovery-generation [A-Za-z0-9._-]+' "$LAB/p.err" | head -1)
# shellcheck disable=SC2086
drain $B3 >/dev/null 2>&1; rc $?
