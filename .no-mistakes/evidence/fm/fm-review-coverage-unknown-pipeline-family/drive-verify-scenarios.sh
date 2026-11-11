#!/usr/bin/env bash
# Live scenario driver for fm-review-coverage-unknown-pipeline-family.
# Drives the real bin/fm-review-record.py CLI (review / captain-word / verify)
# against disposable fixtures: a throwaway git repo, a throwaway FM_HOME and a
# throwaway NM_HOME (absent, empty, recorded-run, or corrupt state.sqlite).
# Usage: drive-verify-scenarios.sh <bin-dir> <label>
set -u
BIN=$1 LABEL=$2
RECORD="$BIN/fm-review-record.py"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-verify.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
URL=https://github.com/example/repo/pull/9

TPL="$WORK/tpl"
mkdir -p "$TPL"; git -C "$TPL" init -q -b main
echo x > "$TPL/README.md"; git -C "$TPL" add README.md
git -C "$TPL" -c user.name=T -c user.email=t@example.invalid commit -qm initial
BASE=$(git -C "$TPL" rev-parse HEAD)
git -C "$TPL" -c user.name=T -c user.email=t@example.invalid commit -q --allow-empty -m 'ship implementation'
HEAD1=$(git -C "$TPL" rev-parse HEAD)

mkcase() {  # <name> <ship-model>
  local d="$WORK/$1"
  mkdir -p "$d/home/state"; cp -R "$TPL" "$d/wt"
  printf '%s\n' "worktree=$d/wt" kind=ship "model=$2" branch=fm/fixture mode=no-mistakes project=demo \
    > "$d/home/state/task-x1.meta"
  printf '%s\n' "$d"
}
rev() {  # <case> <verdict> <reader> <authors-json> [extra]
  local d=$1 v=$2 r=$3 a=$4; shift 4
  printf 'VERDICT: %s head=%s\nIndependent reader evidence.\n' "$v" "$HEAD1" > "$d/report.md"
  FM_HOME="$d/home" python3 "$RECORD" review --pr "$URL" --head "$HEAD1" --verdict "$v" \
    --reader-model "$r" --author-groups "$a" --loosens-deny-allow-list no --widens-guard no \
    --customer-data-billing-spend no --report "$d/report.md" "$@" >/dev/null 2>&1 \
    || echo "  (record $v by $r refused by CLI)"
}
word() { FM_HOME="$1/home" python3 "$RECORD" captain-word --pr "$URL" --head "$HEAD1" --words "$2" >/dev/null; }
ver() {  # <case> <nm-home> [--json]
  local d=$1 nm=$2; shift 2
  local out rc=0
  out=$(NM_HOME="$nm" FM_HOME="$d/home" python3 "$RECORD" verify --pr "$URL" --head "$HEAD1" \
    --task task-x1 --base "$BASE" "$@" 2>&1) || rc=$?
  printf '  $ verify %s\n  exit=%s\n%s\n' "$*" "$rc" "$(printf '%s\n' "$out" | sed 's/^/    /')"
}
nmdb() {  # <dir> [model provider]  -> state.sqlite, optionally with one matching run
  mkdir -p "$1"
  python3 - "$1/state.sqlite" "$URL" "${2-}" "${3-}" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")
if sys.argv[3]:
    db.execute("INSERT INTO runs VALUES ('r1','repo','fm/fixture',?)", (sys.argv[2],))
    db.execute("INSERT INTO agent_invocations VALUES ('r1','acp:omp',?,?)", (sys.argv[3], sys.argv[4] or None))
db.commit()
PY
}
A='{"ship":["gpt-5.1"],"no-mistakes:unknown":["unknown"]}'
echo "=== $LABEL: $(cd "$BIN/.." && git rev-parse --short HEAD 2>/dev/null || echo extracted) bin=$BIN"

echo; echo "## S1 RC1 ship=gpt-5.1 (openai), no state.sqlite, ONE claude PASS"
c=$(mkcase s1 gpt-5.1); rev "$c" PASS sonnet "$A"; ver "$c" "$c/absent-nm"; ver "$c" "$c/absent-nm" --json

echo; echo "## S2 same-family reader: ship=gpt-5.1, ONE gpt-5.1 PASS (must refuse)"
c=$(mkcase s2 gpt-5.1); rev "$c" PASS gpt-5.1 "$A"; ver "$c" "$c/absent-nm" --json

echo; echo "## S3 unknown ship (builder) mystery-9, ONE claude PASS (must refuse)"
c=$(mkcase s3 mystery-9); rev "$c" PASS sonnet '{"ship":["mystery-9"],"no-mistakes:unknown":["unknown"]}'; ver "$c" "$c/absent-nm" --json

echo; echo "## S4 unknown newest reader mystery-9 (must refuse)"
c=$(mkcase s4 gpt-5.1); rev "$c" PASS mystery-9 "$A"; ver "$c" "$c/absent-nm" --json

echo; echo "## S5 known pipeline: run recorded claude-sonnet-5-5; claude reader refused, gemini accepted with no fact"
c=$(mkcase s5 gpt-5.1); nmdb "$c/nm" claude-sonnet-5-5 anthropic
K='{"ship":["gpt-5.1"],"no-mistakes:anthropic":["claude-sonnet-5-5"]}'
rev "$c" PASS sonnet "$K"; ver "$c" "$c/nm" --json
rev "$c" PASS gemini-3-pro "$K"; ver "$c" "$c/nm"; ver "$c" "$c/nm" --json

echo; echo "## S6 adversarial: corrupt state.sqlite (evidence present, unreadable), ONE claude PASS (must refuse, no relief)"
c=$(mkcase s6 gpt-5.1); mkdir -p "$c/nm"; printf 'not a database' > "$c/nm/state.sqlite"
rev "$c" PASS sonnet "$A"; ver "$c" "$c/nm" --json

echo; echo "## S7 adversarial: conflicting provider/model (claude-sonnet-5-5 + provider openai), ONE claude PASS (must refuse)"
c=$(mkcase s7 gpt-5.1); nmdb "$c/nm" claude-sonnet-5-5 openai
rev "$c" PASS sonnet "$A"; ver "$c" "$c/nm" --json

echo; echo "## S8 adversarial: partly unknown ship [gpt-5.1, mystery-9], claude PASS all + gemini PASS ship only (must refuse)"
c=$(mkcase s8 gpt-5.1); printf 'model=mystery-9\n' > "$c/home/state/task-x1.control-relaunch.meta-prior"
P='{"ship":["gpt-5.1","mystery-9"],"no-mistakes:unknown":["unknown"]}'
rev "$c" PASS sonnet "$P"; rev "$c" PASS gemini-3-pro "$P" --covered-groups '["ship"]'; ver "$c" "$c/absent-nm" --json

echo; echo "## S9 two known reader families on unknown pipeline: claude + gemini PASS (accept, NO fact)"
c=$(mkcase s9 gpt-5.1); rev "$c" PASS sonnet "$A"; rev "$c" PASS gemini-3-pro "$A"; ver "$c" "$c/absent-nm"; ver "$c" "$c/absent-nm" --json

echo; echo "## S10 after FAIL: gemini PASS, deepseek FAIL, sole claude PASS (accept WITH fact)"
c=$(mkcase s10 gpt-5.1); rev "$c" PASS gemini-3-pro "$A"; rev "$c" FAIL deepseek-v3 "$A"; rev "$c" PASS sonnet "$A"
ver "$c" "$c/absent-nm"; ver "$c" "$c/absent-nm" --json

echo; echo "## S11 captain-word, deepseek FAIL, sole claude PASS (captain-word WITH fact)"
c=$(mkcase s11 gpt-5.1); word "$c" 'Merge this PR.'; rev "$c" FAIL deepseek-v3 "$A"; rev "$c" PASS sonnet "$A"
ver "$c" "$c/absent-nm"; ver "$c" "$c/absent-nm" --json

echo; echo "## S12 FAIL then ONE same-ship-family gpt PASS (must refuse; FAIL stands)"
c=$(mkcase s12 gpt-5.1); rev "$c" FAIL deepseek-v3 "$A"; rev "$c" PASS gpt-5.1 "$A"; ver "$c" "$c/absent-nm" --json

echo; echo "## S13 --help describes the new rule"
python3 "$RECORD" --help 2>&1 | tr '\n' ' ' | grep -o "Only the derived no-mistakes:unknown group[^.]*\." || echo "  (no new-rule sentence in --help)"
