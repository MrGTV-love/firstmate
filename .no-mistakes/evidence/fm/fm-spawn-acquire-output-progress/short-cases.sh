#!/usr/bin/env bash
# Short live acquisition cases on fresh empty scratch pools (head only), run in parallel.
WT=$1 EV=$2
mkpool() { S=$(mktemp -d /tmp/fmths.XXXXXX); mkdir -p "$S/h" "$S/pool" "$S/p"
  git -C "$S/p" init -q; printf 'max_trees = 8\n' > "$S/p/treehouse.toml"
  git -C "$S/p" add -A; git -C "$S/p" -c user.email=a@b -c user.name=a commit -q -m t; echo "$S"; }
P1=$(mkpool); P2=$(mkpool); P3=$(mkpool); P4=$(mkpool)
TH_MODE=stuck TH_EVERY=3 STALL=30 bash "$EV/live-spawn.sh" "$WT" r2-head-stall30-stuck-loop "$P1" "$EV" &
TH_MODE=newcands TH_COUNT=10 TH_EVERY=12 STALL=30 bash "$EV/live-spawn.sh" "$WT" r2-head-stall30-new-candidates "$P2" "$EV" &
TH_MODE=newcands TH_COUNT=100 TH_EVERY=8 STALL=30 CEILING=45 bash "$EV/live-spawn.sh" "$WT" r2-head-explicit-ceiling45-new-candidates "$P3" "$EV" &
STALL=abc bash "$EV/live-spawn.sh" "$WT" r2-head-invalid-stall-override "$P4" "$EV" &
wait
chmod -R u+w "$P1" "$P2" "$P3" "$P4"; rm -rf "$P1" "$P2" "$P3" "$P4"; echo SHORT-DONE
