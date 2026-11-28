#!/usr/bin/env bash
# Live drive: real claude as lab primary via bin/fm-lab-home.sh primary, then kill-server and the printed teardown.
set -u
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M8FCS29G4AQGSPZ5VK1TSQGS
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M8FCS29G4AQGSPZ5VK1TSQGS
sid() { python3 -c 'import os,sys
try: print(os.getsid(int(sys.argv[1])))
except OSError: print("gone")' "$1"; }
echo '$ eval "$(bin/fm-lab-home.sh env)"'
eval "$(bin/fm-lab-home.sh env 2>"$EV/live-env.err")"
cat "$EV/live-env.err"
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/live-env.err")
echo "FM_HOME=$FM_HOME TMUX_TMPDIR=$TMUX_TMPDIR"
# Outside decoy: own session, cwd in the lab home, never part of the lab.
python3 -c 'import os,sys,time,signal
if os.fork(): sys.exit(0)
os.setsid(); os.chdir(sys.argv[1])
log=sys.argv[2]
for s in (1,2,15,18): signal.signal(s, lambda n,f: open(log,"a").write("%d\n"%n))
open(sys.argv[3],"w").write("%d\n"%os.getpid())
t=time.time()+300
while time.time()<t: time.sleep(0.2)' "$FM_HOME" "$EV/live-decoy.signals" "$EV/live-decoy.pid" </dev/null >/dev/null 2>&1
sleep 0.5; DECOY=$(cat "$EV/live-decoy.pid"); echo "outside decoy pid $DECOY sid $(sid $DECOY)"
echo '$ bin/fm-lab-home.sh primary "$FM_HOME" claude'
bin/fm-lab-home.sh primary "$FM_HOME" claude; echo "rc=$?"
echo '$ cat $FM_HOME/state/.fm-lab-launches'; cat "$FM_HOME/state/.fm-lab-launches"
PANE=$(tmux -L fm-lab display-message -p -t primary '#{pane_pid}')
SERVER=$(tmux -L fm-lab display-message -p -t primary '#{pid}')
sleep 10
echo '$ tmux -L fm-lab capture-pane -p -t primary  (first 25 lines)'
tmux -L fm-lab capture-pane -p -t primary | sed '/^$/d' | head -25
echo "--- processes in the primary pane session $PANE (pid ppid lstart command):"
LAB_PIDS=$(ps -A -o pid= | while read p; do [ "$(sid $p)" = "$PANE" ] && echo $p; done)
for p in $LAB_PIDS; do ps -o pid=,ppid=,lstart=,command= -p $p | cut -c1-160; done
echo "$LAB_PIDS" > "$EV/live-lab-pids.txt"
echo '$ tmux -L fm-lab kill-server'
tmux -L fm-lab kill-server; echo "rc=$?"
sleep 1
kill -0 $SERVER 2>/dev/null && echo "server $SERVER still alive" || echo "server $SERVER gone"
echo "--- lab session processes still alive after kill-server:"
for p in $LAB_PIDS; do ps -o pid=,ppid=,command= -p $p 2>/dev/null | cut -c1-160; done
echo "$ (cd / && ${TEARDOWN%% && rm -rf *})"
(cd / && eval "${TEARDOWN%% && rm -rf *}"); echo "rc=$?"
echo "--- lab session processes alive after teardown:"
left=0; for p in $LAB_PIDS; do ps -o pid=,command= -p $p 2>/dev/null && left=1; done; echo "left=$left"
echo "--- any process whose session is $PANE now:"
ps -A -o pid= | while read p; do [ "$(sid $p)" = "$PANE" ] && ps -o pid=,command= -p $p; done; echo "(end)"
kill -0 $DECOY && echo "outside decoy $DECOY alive"; echo "decoy signals: [$(cat "$EV/live-decoy.signals" 2>/dev/null)]"
ls -d "$TMUX_TMPDIR" 2>/dev/null && echo "socket dir kept" || echo "socket dir removed"
ls "$FM_HOME/state/.fm-lab-launches" 2>/dev/null || echo "launch record removed"
kill $DECOY; sleep 0.3; kill -0 $DECOY 2>/dev/null && kill -KILL $DECOY
echo "$ $TEARDOWN"; eval "$TEARDOWN"; echo "rc=$?"; ls -d "$FM_HOME" 2>/dev/null || echo "lab home removed"
