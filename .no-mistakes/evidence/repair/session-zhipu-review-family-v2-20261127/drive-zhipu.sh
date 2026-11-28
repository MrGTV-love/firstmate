#!/usr/bin/env bash
# Live driver: runs the real bin/fm-review-record.py CLI (head and, for contrast, base)
# against disposable FM_HOME / NM_HOME / git fixtures under a mktemp dir.
set -u
WT=$1; BASE_COMMIT=$2; PREV_COMMIT=$3; EARLY_COMMIT=$4
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-zhipu-live.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/basebin"; git -C "$WT" archive "$BASE_COMMIT" bin | tar -x -C "$T/basebin"
mkdir -p "$T/prevbin"; git -C "$WT" archive "$PREV_COMMIT" bin | tar -x -C "$T/prevbin"
mkdir -p "$T/earlybin"; git -C "$WT" archive "$EARLY_COMMIT" bin | tar -x -C "$T/earlybin"; EARLYREC="$T/earlybin/bin/fm-review-record.py"
HEADREC="$WT/bin/fm-review-record.py"; BASEREC="$T/basebin/bin/fm-review-record.py"; PREVREC="$T/prevbin/bin/fm-review-record.py"
URL=https://github.com/example/repo/pull/9
# git fixture
git init -q -b main "$T/tpl"; echo x > "$T/tpl/R"; git -C "$T/tpl" add R
git -C "$T/tpl" -c user.name=t -c user.email=t@e.invalid commit -qm initial
BASE=$(git -C "$T/tpl" rev-parse HEAD)
git -C "$T/tpl" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m 'ship implementation'
HEAD1=$(git -C "$T/tpl" rev-parse HEAD)
n=0
mkdb() { # <dir> then rows "agent|model|provider"
  local d=$1; shift; mkdir -p "$d"
  python3 - "$d/state.sqlite" "$URL" "$@" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")
if len(sys.argv) > 3:
    db.execute("INSERT INTO runs VALUES ('r1','repo1','fm/fixture',?)", (sys.argv[2],))
for row in sys.argv[3:]:
    a, m, p = row.split("|")
    db.execute("INSERT INTO agent_invocations VALUES ('r1',?,?,?)", (a, m, p))
db.commit()
PY
}
mkcase() { # <author model> ; prints case dir
  local c; c=$(mktemp -d "$T/case.XXXXXX"); mkdir -p "$c/home/state"; cp -R "$T/tpl" "$c/wt"
  printf 'worktree=%s\nkind=ship\nmodel=%s\nbranch=fm/fixture\nmode=direct-PR\n' "$c/wt" "$1" > "$c/home/state/task-x1.meta"
  printf '%s\n' "$c"
}
review() { # <rec> <case> <reader> <authors-json> [extra]
  printf 'VERDICT: PASS head=%s\nIndependent reader evidence.\n' "$HEAD1" > "$2/report.md"
  FM_HOME="$2/home" "$1" review --pr "$URL" --head "$HEAD1" --verdict PASS --reader-model "$3" \
    --author-groups "$4" --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
    --report "$2/report.md" "${@:5}" >/dev/null 2>"$2/review.err" || echo "  (review record refused: $(head -c 200 "$2/review.err"))"
}
verify() { # <rec> <case> <nmhome>
  local out rc=0; out=$(NM_HOME="$3" FM_HOME="$2/home" "$1" verify --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" --review-only --json 2>&1) || rc=$?
  printf '  verify exit=%s %s\n' "$rc" "$(printf '%s' "$out" | jq -c '{ok, reader_family, groups: ([.author_groups // {} | to_entries[] | {(.key): [.value[].family]}] | add), err: (.error.message // null | if . then .[0:140] else . end)}' 2>/dev/null || printf '%s' "$out" | head -c 300)"
}
plan_groups() { # <rec> <case> <nmhome>
  NM_HOME="$3" FM_HOME="$2/home" "$1" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" 2>&1 \
    | jq -c '{groups: (.groups | map_values([.[].model])), uncovered: [.uncovered[]? | .families]}' 2>/dev/null
}
EMPTY="$T/nm-empty"; mkdb "$EMPTY"

echo "=== S1: GLM reader covers an Anthropic author (reader spellings) ==="
for r in zai/glm-5.4 ZAI/GLM-5.4 z-ai/glm-5.4 openrouter/z-ai/glm-4.5:free glm-5.4; do
  c=$(mkcase claude-opus-5-5); echo "reader=$r author=claude-opus-5-5"; review "$HEADREC" "$c" "$r" '{"ship":["claude-opus-5-5"]}'; verify "$HEADREC" "$c" "$EMPTY"
done
echo
echo "=== S2: GLM reader refused for a GLM author (same-family self-review, any route spelling) ==="
for a in openrouter/z-ai/glm-5.4 zai/glm-4.6 GLM-5; do
  c=$(mkcase "$a"); echo "reader=zai/glm-5.4 author=$a"; review "$HEADREC" "$c" zai/glm-5.4 "{\"ship\":[\"$a\"]}"; verify "$HEADREC" "$c" "$EMPTY"; printf '  plan: %s\n' "$(plan_groups "$HEADREC" "$c" "$EMPTY")"
done
echo
echo "=== S3: lookalike / malformed / trailing-slash reader ids stay unknown (head vs first feature commit $EARLY_COMMIT) ==="
for r in 'zai/glm-5.4ſ' 'zai/glm-5.4/' 'zäi/glm-5.4/' 'zäi/glm-5.4' 'glm!!!' 'glm-5.4---' 'zai' 'z-ai/mystery-1' 'glimpse-1'; do
  rr=$r
  for which in head early; do
    rec=$HEADREC; [ $which = early ] && rec=$EARLYREC
    c=$(mkcase claude-opus-5-5); echo "[$which] reader=$r codepoints=$(python3 -c 'import sys;print([hex(ord(c)) for c in sys.argv[1] if ord(c)>127])' "$r")"; review "$rec" "$c" "$rr" '{"ship":["claude-opus-5-5"]}'; verify "$rec" "$c" "$EMPTY"
  done
done
echo
echo "=== S4: pipeline rows (agent|model|provider) -> pipeline author group (head vs base) ==="
for row in 'pi||zai' 'pi||z-ai' 'pi||ZAI' 'pi||Zai' 'pi|glm-5.4|zai' 'pi|glm-5.4|openai' 'pi|glm!!!|openai' 'pi|glm!!!|zai' 'pi|mystery-12|z-ai' 'pi|glm-5.4ſ|zai' 'pi|glm-5.4ſ-2|anthropic' 'pi|zäi/glm-5.4|openai' 'pi|zai/glm-5.4/|openai' 'pi|zäi/glm-5.4/|anthropic' 'pi|mystery-9|gpt' 'pi|mystery-10|OpenAI' 'pi|mystery-11|moonſhot' 'pi||openai' 'pi|mystery-1|openai' 'pi|gpt-5.1|openai'; do
  nm=$(mktemp -d "$T/nm.XXXXXX"); mkdb "$nm" "$row"
  for which in head base; do
    rec=$HEADREC; [ $which = base ] && rec=$BASEREC
    c=$(mkcase claude-opus-5-5); printf '[%s] row=%-34s plan: %s\n' "$which" "$row" "$(plan_groups "$rec" "$c" "$nm")"
  done
done
echo
echo "=== S5: reported harm path: one GLM read vs malformed-GLM-with-openai pipeline row (head vs pre-fix commit $PREV_COMMIT) ==="
nm="$T/nm-harm"; mkdb "$nm" 'pi|glm!!!|openai'
for which in head prev; do
  rec=$HEADREC; [ $which = prev ] && rec=$PREVREC
  c=$(mkcase claude-opus-5-5); echo "[$which] reader=zai/glm-5.4 pipeline row=pi|glm!!!|openai, ship=claude-opus-5-5"
  g=$(NM_HOME="$nm" FM_HOME="$c/home" "$rec" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" | jq -c '.groups | with_entries(.value |= map(.model))')
  echo "  derived author groups: $g"
  review "$rec" "$c" zai/glm-5.4 "$g" --covered-groups '["all"]'
  verify "$rec" "$c" "$nm"; printf '  plan: %s\n' "$(plan_groups "$rec" "$c" "$nm")"
done
echo
echo "=== S4b: malformed/non-ASCII/trailing-slash GLM model ids under every provider -> no-mistakes:unknown ==="
for m in 'glm!!!' 'glm-5.4ſ' 'zai/glm-5.4/' 'zäi/glm-5.4'; do
  for prov in anthropic openai google deepseek xai moonshot meta zhipu zai z-ai; do
    nm=$(mktemp -d "$T/nm.XXXXXX"); mkdb "$nm" "pi|$m|$prov"; c=$(mkcase claude-opus-5-5)
    printf '[head] row=%-28s pipeline groups: %s\n' "pi|$m|$prov" "$(NM_HOME="$nm" FM_HOME="$c/home" "$HEADREC" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" | jq -c '.groups | with_entries(select(.key|startswith("no-mistakes:"))) | keys')"
  done
done
for row in 'pi||zhipu' 'pi|mystery-12|zhipu' 'pi|glm-5.4|zhipu'; do
  nm=$(mktemp -d "$T/nm.XXXXXX"); mkdb "$nm" "$row"; c=$(mkcase claude-opus-5-5)
  printf '[head] row=%-28s pipeline groups: %s\n' "$row" "$(NM_HOME="$nm" FM_HOME="$c/home" "$HEADREC" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" | jq -c '.groups | with_entries(select(.key|startswith("no-mistakes:"))) | keys')"
done
echo
echo "=== S4c: pipeline author routed through zai/z-ai: GLM reader refused, GPT reader accepted (verify) ==="
for row in 'pi||zai' 'pi||z-ai' 'pi|glm-5.4|zai' 'pi|glm-5.4|zhipu'; do
  nm=$(mktemp -d "$T/nm.XXXXXX"); mkdb "$nm" "$row"
  for reader in zai/glm-5.4 gpt-5.1; do
    c=$(mkcase claude-opus-5-5)
    g=$(NM_HOME="$nm" FM_HOME="$c/home" "$HEADREC" plan --pr "$URL" --head "$HEAD1" --task task-x1 --base "$BASE" | jq -c '.groups | with_entries(.value |= map(.model))')
    echo "[head] row=$row reader=$reader derived=$g"
    review "$HEADREC" "$c" "$reader" "$g" --covered-groups '["all"]'
    verify "$HEADREC" "$c" "$nm"
  done
done
echo
echo "=== S6: unchanged families still work (regression) ==="
c=$(mkcase claude-opus-5-5); echo "reader=gpt-5.1 author=claude-opus-5-5"; review "$HEADREC" "$c" gpt-5.1 '{"ship":["claude-opus-5-5"]}'; verify "$HEADREC" "$c" "$EMPTY"
c=$(mkcase gpt-5.1); echo "reader=gpt-5.2 author=gpt-5.1 (same family)"; review "$HEADREC" "$c" gpt-5.2 '{"ship":["gpt-5.1"]}'; verify "$HEADREC" "$c" "$EMPTY"
c=$(mkcase gpt-5.1); echo "reader=zai/glm-5.4 author=gpt-5.1"; review "$HEADREC" "$c" zai/glm-5.4 '{"ship":["gpt-5.1"]}'; verify "$HEADREC" "$c" "$EMPTY"
