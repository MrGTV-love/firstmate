#!/usr/bin/env bash
# Drives the real bin/fm-review-record.py CLI over disposable FM_HOME/NM_HOME fixtures.
# Usage: drive-zhipu-cli.sh <path-to-fm-review-record.py> <label>
set -u
RECORD=$1; LABEL=$2
T=$(mktemp -d "${TMPDIR:-/tmp}/zhipu-drive.XXXXXX"); trap 'rm -rf "$T"' EXIT
URL=https://github.com/example/repo/pull/9
WT0="$T/wt0"; mkdir -p "$WT0"; git -C "$WT0" init -q -b main
echo x > "$WT0/README.md"; git -C "$WT0" add README.md
git -C "$WT0" -c user.name=t -c user.email=t@example.invalid commit -qm initial
BASE=$(git -C "$WT0" rev-parse HEAD)
git -C "$WT0" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m 'ship implementation'
HEAD1=$(git -C "$WT0" rev-parse HEAD)
mkdb() { mkdir -p "$1"; python3 - "$1/state.sqlite" "$URL" "${@:2}" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")
rows = sys.argv[3:]
if rows:
    db.execute("INSERT INTO runs (id, repo_id, branch, pr_url) VALUES ('r1','repo1','fm/fixture',?)", (sys.argv[2],))
for r in rows:
    m, p = r.split("|", 1)
    db.execute("INSERT INTO agent_invocations VALUES ('r1','pi',?,?)", (m, p))
db.commit()
PY
}
mkdb "$T/nm-empty"
n=0
mkcase() { local c; c=$(mktemp -d "$T/case.XXXXXX"); mkdir -p "$c/home/state"; cp -R "$WT0" "$c/wt"
  printf 'worktree=%s\nkind=ship\nmodel=%s\nbranch=fm/fixture\nmode=direct-PR\n' "$c/wt" "$1" > "$c/home/state/task-x1.meta"; echo "$c"; }
review() { local c=$1 reader=$2 authors=$3
  printf 'VERDICT: PASS head=%s\nIndependent reader evidence.\n' "$HEAD1" > "$c/report.md"
  FM_HOME="$c/home" "$RECORD" review --pr "$URL" --head "$HEAD1" --verdict PASS --reader-model "$reader" \
    --author-groups "$authors" --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
    --report "$c/report.md" >/dev/null 2>"$c/rec.err" || { echo "  record: refused: $(cat "$c/rec.err")"; }; }
verify() { local c=$1 nm=${2:-$T/nm-empty} rc=0 out
  out=$(NM_HOME="$nm" FM_HOME="$c/home" "$RECORD" verify --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" --review-only --json 2>&1) || rc=$?
  echo "  verify exit=$rc"; printf '%s\n' "$out" | jq -c '{ok, reader_family, author_groups, error: (if .error then {kind: .error.kind, message: (.error.message[:170] + "...")} else null end)}' 2>/dev/null || echo "  $out"; }
plan() { local c=$1 nm=${2:-$T/nm-empty} out
  out=$(NM_HOME="$nm" FM_HOME="$c/home" "$RECORD" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" 2>&1)
  echo "  plan: $(echo "$out" | jq -c '{groups, uncovered}' 2>/dev/null || echo "$out")"; }

echo "=== $LABEL: bin/fm-review-record.py"
echo "--- S1 GLM reader zai/glm-5.4 covers anthropic author claude-opus-5-5"
c=$(mkcase claude-opus-5-5); review "$c" zai/glm-5.4 '{"ship":["claude-opus-5-5"]}'; verify "$c"; plan "$c"
echo "--- S1b GLM reader zai/glm-5.4 covers openai author gpt-6.1-terra"
c=$(mkcase gpt-6.1-terra); review "$c" zai/glm-5.4 '{"ship":["gpt-6.1-terra"]}'; verify "$c"
echo "--- S1c anthropic reader covers GLM author openrouter/z-ai/glm-5.4"
c=$(mkcase openrouter/z-ai/glm-5.4); review "$c" claude-opus-5-5 '{"ship":["openrouter/z-ai/glm-5.4"]}'; verify "$c"
echo "--- S2 same-family: zai/glm-5.4 reader vs openrouter/z-ai/glm-5.4 author"
c=$(mkcase openrouter/z-ai/glm-5.4); review "$c" zai/glm-5.4 '{"ship":["openrouter/z-ai/glm-5.4"]}'; verify "$c"; plan "$c"
echo "--- S2b same-family across case spelling: Zhipu/GLM-4.6 reader vs zai/glm-5.4 author"
c=$(mkcase zai/glm-5.4); review "$c" Zhipu/GLM-4.6 '{"ship":["zai/glm-5.4"]}'; verify "$c"
for bad in 'glm!!!' 'glm---' 'glm-5.4---' 'zai???' 'zai' 'z-ai' 'glimpse-1' 'z-ai/mystery-1' 'zai/glm!!!' 'glm..5' 'glm-5.4.' ; do
  echo "--- S3 bad reader id '$bad' vs anthropic author"
  c=$(mkcase claude-opus-5-5); review "$c" "$bad" '{"ship":["claude-opus-5-5"]}'; verify "$c"
done
for canon in zhipu openai; do
  echo "--- S3p canonical family name parity: bare '$canon' reader vs anthropic author"
  c=$(mkcase claude-opus-5-5); review "$c" "$canon" '{"ship":["claude-opus-5-5"]}'; verify "$c"
done
echo "--- S4 pipeline DB providers: zai, z-ai, ZAI, gpt, OpenAI, moonſhot, openai, zai+gpt-5 conflict"
mkdb "$T/nm-prov" 'mystery-1|zai' 'mystery-2|z-ai' 'mystery-3|ZAI' 'mystery-4|gpt' 'mystery-5|OpenAI' 'mystery-6|moonſhot' 'mystery-7|openai' 'gpt-5|zai'
c=$(mkcase claude-opus-5-5); review "$c" zai/glm-5.4 '{"ship":["claude-opus-5-5"]}'; plan "$c" "$T/nm-prov"

echo "--- S5 pipeline DB zai/z-ai rows form no-mistakes:zhipu; GLM reader claiming it must be refused, Claude reader accepted"
mkdb "$T/nm-zhipu" 'mystery-1|zai' 'glm-5.4|z-ai'
c=$(mkcase gpt-6.1-terra); plan "$c" "$T/nm-zhipu"
echo "  S5a reader zai/glm-5.4 claims ship + no-mistakes:zhipu"
review "$c" zai/glm-5.4 '{"ship":["gpt-6.1-terra"],"no-mistakes:zhipu":["glm-5.4","mystery-1"]}'; verify "$c" "$T/nm-zhipu"
c=$(mkcase gpt-6.1-terra)
echo "  S5b reader claude-opus-5-5 claims ship + no-mistakes:zhipu"
review "$c" claude-opus-5-5 '{"ship":["gpt-6.1-terra"],"no-mistakes:zhipu":["glm-5.4","mystery-1"]}'; verify "$c" "$T/nm-zhipu"
