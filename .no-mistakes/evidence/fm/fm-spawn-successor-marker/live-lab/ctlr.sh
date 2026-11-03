. $SB/drv/lib.sh
say "CONTROL for F3: relaunch the plain (non-successor) admitted task ctl the same way"
note "ctl successor_of lines: $(grep -c '^successor_of=' "$FM_HOME/state/ctl.meta")"
for p in $(pgrep -f "state/ctl.inbox"); do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
sleep 3
TAILN=10 run spawn ctl --relaunch --harness claude
note "ctl relaunch exit=$RC"
