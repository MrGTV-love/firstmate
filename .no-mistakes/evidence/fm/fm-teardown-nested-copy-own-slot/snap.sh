#!/usr/bin/env bash
# snapshot: every file under state/ and data/ and tasktmp with sha256, heads, claim, treehouse lease state, tmux windows
C=$1; . $C/vars; export TREEHOUSE_ROOT=$C/pool
for d in $FM_HOME/state $FM_HOME/data $C/tasktmp; do [ -d $d ] && find $d ! -name '*.lock' ! -path '*.lock/*' ! -name '.last-watcher-beat' ! -name '.fm-lab*' ! -name '.guard*' | LC_ALL=C sort | while read f; do [ -f "$f" ] && echo "file ${f#$FM_HOME/} $(shasum -a 256 <"$f"|cut -c1-16)" || echo "dir ${f#$FM_HOME/}"; done; done
echo "copy: $( [ -d $COPY ] && git -C $COPY rev-parse HEAD || echo ABSENT) dirty=$( [ -d $COPY ] && git -C $COPY status --porcelain | wc -l | tr -d ' ')"
echo "slot-head: $(git -C $SLOT rev-parse HEAD 2>/dev/null || echo ABSENT)"
echo "claim: $(cat $(dirname $SLOT)/.fm-slot-owner 2>/dev/null | tr '\n' ' ' || echo ABSENT)"
echo "treehouse status:"; (cd $C/project && treehouse status 2>/dev/null | sed 's/^/  /')
echo "tmux windows: $(tmux list-windows -a -F '#S:#W' 2>/dev/null | tr '\n' ' ')"
