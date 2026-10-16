#!/usr/bin/env bash
# Adversarial live scenarios: real fm-open-loops.sh collector + real fm-wake-drain.sh in disposable lab homes.
# Usage: drive-adversarial.sh <bin-dir>
set -u
BIN=$1
KEY=d1-expired-preservation-ledger
ORIGIN=vernant-d1-intake
LABS=()
cleanup() { for l in "${LABS[@]}"; do rm -rf "$l"; done; }
trap cleanup EXIT
NOW=$(date -u +%s)
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
PASS=0; FAIL=0
check() { # check "<what>" <cmd...>  (cmd exit 0 = true)
  local what=$1; shift
  if "$@"; then PASS=$((PASS+1)); printf '  PASS  %s\n' "$what"; else FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$what"; fi
}
fm() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
         -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" FM_SUPERVISION_ACTOR=main "$@"; }
loops() { fm "$BIN/fm-open-loops.sh" "$@"; }
drain() { fm "$BIN/fm-wake-drain.sh" "$@"; }
wake() { fm bash -c '. "$1"; fm_wake_append check report "check: $2"' _ "$BIN/fm-wake-lib.sh" "$1"; }
queued() { drain --queued | wc -l | tr -d ' '; }
held_entry() { # held_entry TASK [extra-flags]
  printf -- '- [ ] %s - Decide (repo: firstmate) (kind: ship) (hold: need captain decision) (hold-kind: captain)%s\n  Captain hold set: %s\n' \
    "$1" "${2:-}" "$(iso $((NOW-36000)))"
}
write_backlog() { { printf '## In flight\n'; for e in "$@"; do printf '%s\n' "$e"; done; printf '\n## Queued\n\n## Done\n'; } > "$LAB/data/backlog.md"; }
newlab() { # newlab <held task>...
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); LABS+=("$LAB")
  "$BIN/fm-lab-home.sh" create "$LAB" >/dev/null 2>&1 || mkdir -p "$LAB"/{state,data,config,projects}
  local entries=(); for t in "$@"; do entries+=("$(held_entry "$t")"); done
  write_backlog "${entries[@]}"
  printf 'blocked [at=%s] [key=%s]: needs captain decision on ledger expiry\n' "$((NOW-36000))" "$KEY" > "$LAB/state/$ORIGIN.status"
  loops --heartbeat >/dev/null
  ROW=$(jq -r '.rows[]|select(.owner=="firstmate")|.id' "$LAB/state/open-loops.json")
  CROW=$(jq -r '.rows[]|select(.owner=="captain")|.id' "$LAB/state/open-loops.json" | head -1)
}
boundary() { grep -oE -e '--ack-through [0-9]+ --recovery-generation [A-Za-z0-9._-]+' "$1" | head -1; }
turn() { # turn <label>: wake + drain; sets B (ack args), TURN_OUT
  wake "$1"; drain >"$LAB/turn.out" 2>"$LAB/turn.err"; B=$(boundary "$LAB/turn.err")
}
clear_ok() { drain $B >/dev/null 2>&1; }       # unquoted on purpose: B is "--ack-through N --recovery-generation G"
presented() { grep -q "$ORIGIN:$KEY" "$LAB/turn.out"; }
receipt_captain_row() { loops action "$CROW" escalated --evidence "captain hold is the decision" >/dev/null 2>&1; }
not() { ! "$@"; }

echo "### A. one clear empties a large pile (the 465-record incident shape)"
newlab $KEY
turn first; receipt_captain_row; loops action "$ROW" escalated --evidence "asked the captain" >"$LAB/rec.out"
check "receipt reports a standing captain hold" grep -q "standing: captain hold $KEY" "$LAB/rec.out"
clear_ok
for i in $(seq 1 465); do wake "pile$i"; done
echo "  queued before drain: $(queued)"
turn bigdrain
check "465-record pile: firstmate row is not re-presented" not presented
check "465-record pile: one acknowledgement is accepted" clear_ok
check "queue is empty after one clear" test "$(queued)" = 0

echo "### B. hold deferred to a date (--until) keeps standing"
newlab $KEY
turn first; receipt_captain_row; loops action "$ROW" escalated --evidence "asked the captain" >/dev/null; clear_ok
write_backlog "$(held_entry $KEY ' (hold-until: 2999-01-01)')"
loops --heartbeat >/dev/null
turn dated
check "dated hold: row not re-presented" not presented
check "dated hold: clear accepted" clear_ok
check "dated hold: --check-actions passes" loops --check-actions

echo "### C. hold re-stamped (a new hold lifecycle) re-presents the row"
newlab $KEY
turn first; receipt_captain_row; loops action "$ROW" escalated --evidence "asked the captain" >/dev/null; clear_ok
write_backlog "$(held_entry $KEY | sed "s/Captain hold set: .*/Captain hold set: $(iso $((NOW-3600)))/")"
loops --heartbeat >/dev/null
turn reheld
check "re-held: row presented again" presented
check "re-held: clear refused" not clear_ok

echo "### D. unreadable backlog fails closed (no standing from a read failure)"
newlab $KEY
turn first; receipt_captain_row; loops action "$ROW" escalated --evidence "asked the captain" >/dev/null; clear_ok
rm "$LAB/data/backlog.md"; ln -s "$LAB/data/missing-backlog" "$LAB/data/backlog.md"
turn unreadable
check "unreadable backlog: row presented again" presented
check "unreadable backlog: clear refused" not clear_ok

echo "### E. bound hold ending re-presents; a non-bound candidate ending does not"
newlab $ORIGIN $KEY
turn first; receipt_captain_row; loops action "$ROW" escalated --evidence "asked the captain" >"$LAB/rec.out"; clear_ok
check "two held candidates: the row key binds first" grep -q "standing: captain hold $KEY;" "$LAB/rec.out"
write_backlog "$(held_entry $KEY)"          # the origin-task candidate ends; key hold remains
loops --heartbeat >/dev/null
turn other-ended
check "non-bound candidate ended: still standing" not presented
check "non-bound candidate ended: clear accepted" clear_ok
write_backlog "$(held_entry $ORIGIN)"       # the bound key hold ends
loops --heartbeat >/dev/null
turn bound-ended
check "bound hold ended: row presented again" presented
check "bound hold ended: clear refused" not clear_ok

echo "### F. a task id written in the evidence never binds; unheld explicit --hold is refused"
newlab elsewhere
turn first; receipt_captain_row
loops action "$ROW" escalated --evidence "tracked as elsewhere; captain notified." >"$LAB/rec.out"
check "evidence mentions a held task: reported as no standing" grep -q "standing: no" "$LAB/rec.out"
check "evidence mention stores no hold" test "$(jq -r --arg r "$ROW" '.handling.actions[$r].hold // "none"' "$LAB/state/open-loops.json")" = none
clear_ok
turn next
check "evidence-only receipt answers just its own turn (re-presented)" presented
loops action "$ROW" escalated --evidence "asked" --hold not-held >"$LAB/rec2.out" 2>&1
check "explicit --hold on an unheld task is refused" grep -q "still held for the captain" "$LAB/rec2.out"
loops action "$ROW" escalated --evidence "asked" --hold elsewhere >"$LAB/rec3.out" 2>&1
check "explicit --hold on a held task binds it" grep -q "standing: captain hold elsewhere;" "$LAB/rec3.out"
clear_ok
turn after-explicit
check "explicit hold stands on later turns" not presented

echo "### G. --hold on a non-escalated kind is refused"
newlab $KEY
turn first
loops action "$ROW" deferred --evidence "waiting" --hold $KEY --recheck "$(iso $((NOW+600)))" >"$LAB/rec.out" 2>&1
check "--hold with deferred is refused" grep -q "only valid for escalated" "$LAB/rec.out"

echo; echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
