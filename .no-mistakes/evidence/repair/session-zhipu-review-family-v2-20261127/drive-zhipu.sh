#!/usr/bin/env bash
# Manual live drive of bin/fm-review-record.py (review/verify/plan) for the Zhipu/GLM family.
# Usage: drive-zhipu.sh <worktree-root>. Everything lives in a mktemp dir removed at exit.
set -u
ROOT=$1; RECORD="$ROOT/bin/fm-review-record.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/zhipu-live.XXXXXX"); trap 'rm -rf "$T"' EXIT
URL=https://github.com/example/repo/pull/9
git init -q -b main "$T/wt"; echo x > "$T/wt/README.md"; git -C "$T/wt" add README.md
G="git -C $T/wt -c user.name=Lab -c user.email=lab@example.invalid"
$G commit -qm initial; BASE=$(git -C "$T/wt" rev-parse HEAD)
$G commit -q --allow-empty -m 'ship implementation'; HEAD1=$(git -C "$T/wt" rev-parse HEAD)
mkdb() { mkdir -p "$1"; python3 - "$1/state.sqlite" "$URL" "${@:2}" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")
db.execute("INSERT INTO runs VALUES ('r1','repo1','fm/fixture',?)", (sys.argv[2],))
for row in sys.argv[3:]:
    m, p = row.split("|", 1)
    db.execute("INSERT INTO agent_invocations VALUES ('r1','pi',?,?)", (m, p))
db.commit()
PY
}
mkdb "$T/nm-empty"
n=0
case_() { n=$((n+1)); C="$T/c$n"; mkdir -p "$C/home/state"; cp -R "$T/wt" "$C/wt"
  printf '%s\n' "worktree=$C/wt" kind=ship "model=$1" branch=fm/fixture mode=direct-PR > "$C/home/state/task-x1.meta"; }
review() { printf 'VERDICT: PASS head=%s\nIndependent reader evidence.\n' "$HEAD1" > "$C/report.md"
  FM_HOME="$C/home" "$RECORD" review --pr "$URL" --head "$HEAD1" --verdict PASS --reader-model "$1" \
    --author-groups "$2" --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
    --report "$C/report.md" >/dev/null 2>"$C/rec.err"; echo "record rc=$? $(head -c 300 "$C/rec.err")"; }
verify() { NM_HOME="${1:-$T/nm-empty}" FM_HOME="$C/home" "$RECORD" verify --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" --review-only --json; echo "verify rc=$?"; }
plan() { NM_HOME="${1:-$T/nm-empty}" FM_HOME="$C/home" "$RECORD" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE"; echo "plan rc=$?"; }

echo "=== S1: zai/glm-5.4 reader covers anthropic author (claude-opus-5-5)"
case_ claude-opus-5-5; review zai/glm-5.4 '{"ship":["claude-opus-5-5"]}'; verify; plan | jq -c '{uncovered,groups}'

echo; echo "=== S2a: zai/glm-5.4 reader vs openrouter/z-ai/glm-5.4 author (same family, other route)"
case_ openrouter/z-ai/glm-5.4; review zai/glm-5.4 '{"ship":["openrouter/z-ai/glm-5.4"]}'; verify; plan | jq -c '{uncovered}'
for pair in 'openrouter/z-ai/glm-5.4|zai/glm-4.6' 'GLM-5.4|zhipu/glm-5' 'zai/glm-5.4:free|glm-5.4'; do
  r=${pair%%|*}; a=${pair#*|}
  echo; echo "=== S2b: reader $r vs author $a"
  case_ "$a"; review "$r" "{\"ship\":[\"$a\"]}"; verify | tail -2
done

for bad in 'glm!!!' 'glm---' 'glm-5.4---' 'zai???' 'zai' 'glimpse-1' 'z-ai/mystery-1' 'zai/glm!!!' 'glm-5.4.' 'glm..5' 'z-ai' 'zhipu/glm-5_'; do
  echo; echo "=== S3: malformed/unrecognized reader '$bad' vs anthropic author"
  case_ claude-opus-5-5; review "$bad" '{"ship":["claude-opus-5-5"]}'; verify | tail -2
done

echo; echo "=== S4: pipeline DB provider normalization (plan groups)"
mkdb "$T/nm-prov" '|zai' '|z-ai' 'glm-5.4|zai' 'glm!!!|zai' 'mystery-12|z-ai' '|ZAI' '|Z-AI' '|gpt' '|OpenAI' '|openai' 'gpt-5|zai' 'mystery-9|gpt' 'mystery-11|moonſhot'
case_ claude-opus-5-5; review sonnet '{"ship":["claude-opus-5-5"]}'
plan "$T/nm-prov" | jq -c '.groups | to_entries[] | select(.key|startswith("no-mistakes:")) | {group:.key, models:[.value[]|.model]}'

echo; echo "=== S4b: pipeline zai provider (empty model) author blocks a GLM reader end-to-end"
mkdb "$T/nm-zai" '|zai'
case_ claude-opus-5-5; review zai/glm-5.4 '{"ship":["claude-opus-5-5"]}'; verify "$T/nm-zai" | tail -2; plan "$T/nm-zai" | jq -c '{uncovered}'

echo; echo "=== S4c: pipeline glm!!!+zai stays unknown and refuses even a GLM reader as unknown author"
mkdb "$T/nm-bad" 'glm!!!|zai'
case_ claude-opus-5-5; review zai/glm-5.4 '{"ship":["claude-opus-5-5"]}'; verify "$T/nm-bad" | tail -2

echo; echo "=== S5: existing families unchanged: sonnet reader covers gpt-5.1; gpt-5.1 reader refused for gpt author"
case_ gpt-5.1; review sonnet '{"ship":["gpt-5.1"]}'; verify | tail -2
case_ gpt-5.1; review openai/gpt-6.1-terra '{"ship":["gpt-5.1"]}'; verify | tail -2
