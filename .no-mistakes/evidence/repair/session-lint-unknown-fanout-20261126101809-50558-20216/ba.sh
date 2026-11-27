#!/usr/bin/env bash
P=$1 r=$2
for v in e2e-base e2e; do
  rm -rf "$P/ba-cache-$v"; mkdir "$P/ba-cache-$v"; cd "$P/$v" || exit 1
  for n in 1 2; do
    s=$(date +%s)
    o=$(env -u FM_HOME CI= GITHUB_ACTIONS= FM_LINT_CACHE_DIR=$P/ba-cache-$v FM_LINT_SLOT_DIR=$P/slots FM_DURATION_FILE=$P/ba-dur.jsonl bin/fm-lint.sh --jobs 1 "$r" 2>&1); rc=$?
    echo "[$v run $n] rc=$rc seconds=$(( $(date +%s) - s )) $(grep -q "cache hit $r" <<<"$o" && echo 'cache hit' || echo 'no cache hit (cold ShellCheck)')"
  done
done
