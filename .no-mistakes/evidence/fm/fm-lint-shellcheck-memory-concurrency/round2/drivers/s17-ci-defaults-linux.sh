#!/usr/bin/env bash
# CI's own settings (FM_LINT_REQUIRE_BOUNDS=1, FM_LINT_JOBS=1, CI values, default memory limit), real ShellCheck, base vs head, four real repo roots. Then --jobs 2 with the same defaults.
set -u
ROOTS="tests/fm-lint-helpers.sh tests/fm-lint-workflows.test.sh tests/fm-lint-report.test.sh bin/fm-mem-guard.sh"
for side in base head; do
  cp -R /$side /tmp/$side; cd /tmp/$side || exit 1
  [ -x /tmp/bin/shellcheck ] || bin/fm-install-shellcheck.sh /tmp/bin >/dev/null 2>&1; export PATH=/tmp/bin:$PATH FM_LINT_CACHE_DIR=off
  for jobs in 1 2; do
    : > /tmp/samples
    ( while :; do ps -axo rss=,comm= | awk '$2=="shellcheck"{n++;s+=$1} END{print n+0,s+0}' >> /tmp/samples; sleep 0.1; done ) & SP=$!
    t=$SECONDS; FM_LINT_REQUIRE_BOUNDS=1 FM_LINT_JOBS=$jobs CI=true GITHUB_ACTIONS=true bin/fm-lint.sh --strict-version --telemetry /tmp/$side.$jobs.tsv $ROOTS > /tmp/$side.$jobs.out 2>&1; rc=$?
    kill $SP 2>/dev/null; wait $SP 2>/dev/null
    echo "$side FM_LINT_JOBS=$jobs exit=$rc wall_s=$((SECONDS-t)) $(awk '{if($1>n)n=$1;if($2>m)m=$2}END{printf "most_shellcheck=%d aggregate_peak_kib=%d samples=%d",n,m,NR}' /tmp/samples)"
    awk -F '\t' '$1=="end"{print "  " $3 " status=" $9 " outcome=" $10}' /tmp/$side.$jobs.roots.tsv
  done
done
for jobs in 1 2; do diff <(grep -v '^ledger:\|^fallback:\|^budget' /tmp/base.$jobs.out) <(grep -v '^ledger:\|^fallback:\|^budget' /tmp/head.$jobs.out) > /tmp/d.$jobs; echo "diff of the output, base vs head, FM_LINT_JOBS=$jobs: exit=$? lines=$(wc -l < /tmp/d.$jobs)"; sed -n 1,6p /tmp/d.$jobs | cut -c1-160; done
