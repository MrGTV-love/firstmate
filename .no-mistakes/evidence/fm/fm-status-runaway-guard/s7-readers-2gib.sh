#!/usr/bin/env bash
# Live: a 2 GiB (sparse) status log in the lab home, like the incident logs left in
# place. The real readers - the sanctioned append, the wake drain, crew-state and the
# fleet snapshot - must finish fast, refuse to read the log whole, name it, and not
# change it or copy it.
set -u
unset TMUX
ST="$FM_HOME/state"; H="$ST/huge.status"; WT="$FM_HOME/projects/wt"; mkdir -p "$WT"
sz(){ stat -f %z "$1"; }
perl -e 'my ($p)=@ARGV; open my $f,">",$p or die; for my $i (1..3000){print $f "working [at=$i]: event $i\n"}
  print $f "needs-decision [key=old-question]: an early question\n"; my $t="text\n" x 200000;
  seek($f, 2*1024*1024*1024 - length($t), 0) or die; print $f $t; close $f' "$H"
printf '%s\n' "window=firstmate:fm-huge" "worktree=$WT" "project=alpha" "harness=claude" "kind=ship" > "$ST/huge.meta"
echo "log=$(sz "$H") bytes ($(du -k "$H" | cut -f1) KiB on disk)"
t(){ local s e; s=$(perl -MTime::HiRes=time -e 'printf "%.2f",time'); "$@"; local rc=$?; e=$(perl -MTime::HiRes=time -e 'printf "%.2f",time'); echo "  -> exit=$rc in $(echo "$e - $s" | bc) s"; }
echo "== fm-status-append.sh done: on the 2 GiB log"; t "$PWD/bin/fm-status-append.sh" "$H" "done [at=$(date +%s)]: x"
echo "== bin/fm-wake-drain.sh"; t "$PWD/bin/fm-wake-drain.sh" > "$FM_HOME/data/drain.out" 2> "$FM_HOME/data/drain.err"; grep -i "huge" "$FM_HOME/data/drain.err" | head -3
echo "== bin/fm-crew-state.sh huge"; t "$PWD/bin/fm-crew-state.sh" huge 2>&1 | head -5
echo "== bin/fm-fleet-snapshot.sh --json"; t "$PWD/bin/fm-fleet-snapshot.sh" --json > "$FM_HOME/data/snap.json" 2> "$FM_HOME/data/snap.err"
grep -i "huge" "$FM_HOME/data/snap.err" | head -3
jq -c '[.tasks[]? | select(.id=="huge") | {id, hints: (.hints|{open_decisions_unreadable})}]' "$FM_HOME/data/snap.json" 2>/dev/null || head -c 300 "$FM_HOME/data/snap.json"
echo "log after=$(sz "$H") bytes; files over 1 MB in state besides *.status: $(find "$ST" -type f -size +1048576c ! -name '*.status' | wc -l | tr -d ' ')"
