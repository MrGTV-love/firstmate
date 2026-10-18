#!/usr/bin/env bash
# Scenario M: drive the real `fm-procevent-lavish.sh sweep --auto` against a disposable lab home and Lavish store.
set -u
ROOT=$1; EV=$2
cd "$ROOT"
. "$EV/sweep-fixture.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); echo "$LAB" > "$EV/.slab"
bin/fm-lab-home.sh create "$LAB" >/dev/null; mkdir -p "$LAB/fakebin" "$LAB/procevent-claims"
printf '#!/bin/sh\nexit 0\n' > "$LAB/fakebin/lavish-axi"; chmod +x "$LAB/fakebin/lavish-axi"
export PATH="$LAB/fakebin:$PATH" FM_HOME=$LAB FM_PROCEVENT_CLAIM_ROOT=$LAB/procevent-claims LAVISH_AXI_STATE_DIR=$LAB/lavish-state
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE NO_MISTAKES_GATE
STORE=$LAB/lavish-state
OLD=2026-10-10T00:00:00Z
IDS=$LAB/ids.tsv; : > "$IDS"
reg() { # name status queued updated present
  local name=$1 st=$2 queued=$3 updated=$4 present=$5 art sid
  art=$(mk_board "$LAB" "$name")
  [ "$st" = none ] || mk_session "$STORE" "$art" "$st" "$queued" "$updated"
  sid=$(bin/fm-procevent-lavish.sh source-id "$art") || { echo "source-id failed"; return 1; }
  bin/fm-procevent.sh register lavish "$sid" -- "$ROOT/bin/fm-procevent-lavish.sh" poll "$art" >/dev/null || echo "register failed for $name"
  [ "$present" = gone ] && rm -f "$art"
  printf '%s\t%s\n' "$name" "$sid" >> "$IDS"
}
echo "### Scenario M: real 'fm-procevent-lavish.sh sweep --auto' against a disposable Lavish store"
reg open-present         open     0 -     present
reg open-missing         open     0 -     gone
reg open-missing-old     open     0 $OLD  gone
reg open-present-old     open     0 $OLD  present
reg ended-missing        ended    0 -     gone
reg ended-present        ended    0 -     present
reg nosession-present    none     0 -     present
reg nosession-missing    none     0 -     gone
reg feedback-missing     feedback 0 -     gone
reg queued-open          open     1 -     present
reg ended-queued-missing ended    1 -     gone
echo "--- dry run (sweep --dry-run --auto):"
bin/fm-procevent-lavish.sh sweep --dry-run --auto | sed "s#$LAB/boards/##" | sort
echo "--- real run (sweep --auto):"
bin/fm-procevent-lavish.sh sweep --auto | sed "s#$LAB/boards/##" | sort
echo "--- retirement record state/lavish-auto-retire.log:"
sed "s#$LAB/boards/##" "$LAB/state/lavish-auto-retire.log" | sort
echo "--- registered sources after the sweep:"
while IFS=$'\t' read -r n sid; do
  if find "$LAB/state" -name "$sid.source" 2>/dev/null | grep -q .; then echo "  registered: $n"; else echo "  RETIRED:    $n"; fi
done < "$IDS" | sort
echo "--- for contrast, MANUAL sweep (no --auto) dry run on the remaining sources:"
bin/fm-procevent-lavish.sh sweep --dry-run | sed "s#$LAB/boards/##" | sort
