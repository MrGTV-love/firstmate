#!/usr/bin/env bash
# Long candidate walk (AP1 discrimination): base vs head, production defaults, real treehouse/git/tmux.
# A treehouse wrapper prints 200 distinct candidate lines, one every 10 s (2000 s), then runs the real get.
WT=$1 EV=$2
mkpool() { S=$(mktemp -d /tmp/fmth$1.XXXXXX); mkdir -p "$S/h" "$S/pool" "$S/p"
  git -C "$S/p" init -q; printf 'max_trees = 8\n' > "$S/p/treehouse.toml"
  git -C "$S/p" add -A; git -C "$S/p" -c user.email=a@b -c user.name=a commit -q -m t; echo "$S"; }
B=$(mktemp -d /tmp/fmbase.XXXXXX); git -C "$WT" archive 2a4694b74 | tar -x -C "$B"
git -C "$B" init -q; git -C "$B" add -A; git -C "$B" -c user.email=a@b -c user.name=a commit -q -m 'unmodified export of base 2a4694b74'
SH=$(mkpool h); SB=$(mkpool b)
TH_MODE=newcands TH_COUNT=200 TH_EVERY=10 bash "$EV/live-spawn.sh" "$WT" head-defaults-long-candidate-walk "$SH" "$EV" &
TH_MODE=newcands TH_COUNT=200 TH_EVERY=10 FMROOT=$B bash "$EV/live-spawn.sh" "$WT" base-unmodified-long-candidate-walk "$SB" "$EV" &
wait
chmod -R u+w "$SH" "$SB" "$B"; rm -rf "$SH" "$SB" "$B"; echo PAIR-DONE
