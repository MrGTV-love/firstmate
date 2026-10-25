#!/usr/bin/env bash
# usage: run.sh <name> <scenario-json-file> [extra omp args...]
set -u
LAB=/Users/charlesabrooker/tmp/fm-jev-dev-lab.Eh3uS2; ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5RB8318NTGZQW57YSPVBH7K; name=$1; scen=$2; shift 2
cp "$scen" $LAB/scenario.json
curl -fsS -X POST -d '{}' http://127.0.0.1:58255/reset >/dev/null
for f in model jev other lsp; do : > $LAB/$f.jsonl; done
: > $LAB/home/state/jev-guard.jsonl 2>/dev/null || true
cd $LAB/worktree
env -u TYPESAFE_API_KEY -u TYPESAFE_API_KEY_PRIVATE -u OPENROUTER_API_KEY -u ANTHROPIC_API_KEY -u OPENAI_API_KEY   HOME=$LAB/os-home TMPDIR=$LAB/tmp PI_CODING_AGENT_DIR=$LAB/agent OMP_SKIP_SETUP=1 PI_AUTO_QA_PUSH_URL=http://127.0.0.1:58255/autoqa HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost FM_TEST_SEAM=1 PI_EDIT_VARIANT=replace PI_DISABLE_LSPMUX=1   FM_JEV_GUARD_BASE_URL=http://127.0.0.1:58255/v1/systemone   timeout 120 omp -p "Run the planned device calls, then stop." --model lab/gpt-6.1-sol --thinking off --no-session   --no-extensions -e $LAB/extension.ts --config $ROOT/.omp/fm-worker-overlay.yml --no-skills --no-rules --no-title "$@"   < /dev/null > $LAB/out-$name.txt 2>&1
echo "exit=$?"
mkdir -p $LAB/results/$name
cp $LAB/model.jsonl $LAB/jev.jsonl $LAB/other.jsonl $LAB/lsp.jsonl $LAB/out-$name.txt $LAB/results/$name/ 2>/dev/null
cp $LAB/home/state/jev-guard.jsonl $LAB/results/$name/ 2>/dev/null || true
