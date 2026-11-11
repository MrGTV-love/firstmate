#!/usr/bin/env bash
# mkfocus.sh <tree> <name>: writes <tree>/tests/<name>.test.sh holding the test
# setup, the up-source block, and the rival trust case only.
in="$1/tests/fm-live-lab.test.sh"; out="$1/tests/$2.test.sh"
awk '
  /^# ---- Claude lab/ {setup_done=1}
  !setup_done {print; next}
  /^# A rival Claude writer drops/ {up=1}
  up {print; if (/commit -qm source/) up=0; next}
  /^FAKEBIN="\$TMP_ROOT\/fakebin"/ {rv=1}
  rv {print; if (/^pass "up re-registers/) {rv=0; tail=1}; next}
  tail && /^RIVAL_CASE_ACTIVE=no/ {print; tail=0; next}
  {tail=0}
' "$in" > "$out"
chmod +x "$out"
