#!/usr/bin/env bash
# usage: run.sh <case> <tools> <grant-json-or-none> <scenario-json> [extra omp args...]
set -u
LAB=/Users/charlesabrooker/tmp/fm-t4-lab.PtjvJJ; ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5V29PD99JFK5BG4M7JKKY14
case_name=$1 tools=$2 grant=$3 scenario=$4; shift 4
base="http://127.0.0.1:$(cat $LAB/port)"
rm -rf "$LAB/home" "$LAB/worktree"; mkdir -p "$LAB/home/config" "$LAB/home/state" "$LAB/home/data" "$LAB/worktree" "$LAB/out/$case_name"
printf 'TYPESAFE_API_KEY=synthetic-local-only\n' > "$LAB/home/.env"
[ "$grant" = none ] || printf 'egress=%s\n' "$grant" > "$LAB/home/state/native.meta"
printf '%s' "$scenario" > "$LAB/scenario.json"
: > "$LAB/model.jsonl"; : > "$LAB/jev.jsonl"
curl -fsS -X POST -d '{}' "$base/reset" >/dev/null
export FM_TEST_SEAM=1 FM_JEV_GUARD_BASE_URL="$base/v1/systemone" FM_GUARD_EVENT_LOG="$LAB/out/$case_name/guard-events.jsonl" FM_LAB_UNLISTED_MARK="$LAB/worktree/unlisted-ran"
(cd "$LAB/worktree" && env -u NO_MISTAKES_GATE HOME="$LAB/os-home" PI_CODING_AGENT_DIR="$LAB/agent" OMP_SKIP_SETUP=1 TMPDIR="$LAB/tmp"   timeout 120 omp -p "Use the one tool call, then stop." --model native/gpt-6.1-sol --thinking off --no-session   --no-extensions -e "$LAB/extension.ts" --config "$ROOT/.omp/fm-worker-overlay.yml" "$@" --no-skills --no-rules --no-title --no-lsp --tools "$tools"   < /dev/null > "$LAB/out/$case_name/omp.out" 2>&1)
echo "omp exit=$?" >> "$LAB/out/$case_name/omp.out"
cp "$LAB/model.jsonl" "$LAB/out/$case_name/model.jsonl"
cp "$LAB/home/state/jev-guard.jsonl" "$LAB/out/$case_name/jev-guard.jsonl" 2>/dev/null || : > "$LAB/out/$case_name/jev-guard.jsonl"
ls "$LAB/worktree" > "$LAB/out/$case_name/worktree-files.txt"
