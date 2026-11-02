#!/bin/bash
# Runs in a throwaway Linux container: the real proc guard reads the real RLIMIT_NPROC and a real process count.
set -u
export HOME=/tmp/h FM_HOME=/tmp/fm FM_DURATION_FILE=off; mkdir -p $HOME/.no-mistakes $FM_HOME/state
sqlite3 $HOME/.no-mistakes/state.sqlite "CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT, status TEXT NOT NULL, ci_ready_at INTEGER, awaiting_agent_since INTEGER);"
ulimit -u 400
echo "soft RLIMIT_NPROC=$(ulimit -u) warn line=240 cpus=$(nproc)"
pids=(); for i in $(seq 1 260); do sleep 600 & pids+=($!); done
echo "real user processes now: $(ps -u "$(id -u)" --no-headers | wc -l)"
/w/bin/fm-cpu-pass.sh pipeline-start -- touch /tmp/started 2>/tmp/err &
start=$!
sleep 5
echo "--- after 5 s with the pile-up:"; cat /tmp/err
[ -e /tmp/started ] && echo "FAIL started during pile-up" || echo "PASS no start during pile-up"
survivors=$(kill -0 "${pids[0]}" 2>/dev/null && echo alive)
echo "running work: $survivors"
kill "${pids[@]}" 2>/dev/null; wait "${pids[@]}" 2>/dev/null
wait $start; rc=$?
echo "--- after the pile-up cleared: rc=$rc"; cat /tmp/err
[ -e /tmp/started ] && echo "PASS started after the pile-up cleared" || echo "FAIL no start"
