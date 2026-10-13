#!/usr/bin/env bash
cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4V6XW5CXASK5PGXT9N1YKDR
E=/Users/charlesabrooker/.no-mistakes/evidence/01M4V6XW5CXASK5PGXT9N1YKDR
for t in fm-project-capacity fm-idle-session-reap fm-teardown-endpoint-safety; do
  s=$(date +%s)
  bash bin/fm-proc-budget.sh -- bash tests/$t.test.sh > $E/$t.log 2>&1
  echo "$t exit=$? secs=$(( $(date +%s)-s ))" >> $E/summary.txt
done
bash bin/fm-doc-audience-check.sh > $E/doc-audience.log 2>&1; echo "doc-audience exit=$?" >> $E/summary.txt
echo DONE >> $E/summary.txt
