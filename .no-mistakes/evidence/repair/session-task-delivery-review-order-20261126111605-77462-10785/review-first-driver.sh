#!/usr/bin/env bash
# Drives the real bin/fm-review-record.py against a disposable fixture to check the
# task-delivery SKILL.md claims about review-first / parallel-with-CI PASS carry-over.
# Usage: review-first-driver.sh <worktree-root> <fixture-dir>
set -u
ROOT=$1 FX=$2
REC="$ROOT/bin/fm-review-record.py"
URL=https://github.com/example/repo/pull/9
SHIP=claude-opus-4-5
clean() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u NM_HOME "$@"; }
g() { git -C "$FX/$1/wt" -c user.name=Fixture -c user.email=fixture@example.invalid "${@:2}"; }
mkcase() { # <name>: wt with BASE, branch pr (R), branch trunk; meta mode=no-mistakes; empty pipeline db
  local c=$FX/$1
  mkdir -p "$c/home/state" "$c/nm" "$c/wt"
  git -C "$c/wt" init -q -b main
  printf 'base\n' > "$c/wt/README"; g "$1" add README; g "$1" commit -qm base
  g "$1" checkout -q -b pr; printf 'one\ntwo\n' > "$c/wt/app.txt"; g "$1" add app.txt; g "$1" commit -qm 'ship change'
  g "$1" checkout -q -b trunk main; printf 'other\n' > "$c/wt/other.txt"; g "$1" add other.txt; g "$1" commit -qm 'base moves'
  g "$1" checkout -q pr
  printf 'worktree=%s\nkind=ship\nmodel=%s\nbranch=fm/fixture\nmode=no-mistakes\nproject=%s\n' "$c/wt" "$SHIP" "$c/wt" > "$c/home/state/task-x1.meta"
  python3 -I -c 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")' "$c/nm/state.sqlite"
}
pipeline_run() { # <case> <run-id> <agent> <model>
  python3 -I -c 'import sqlite3,sys; d=sqlite3.connect(sys.argv[1]); d.execute("INSERT INTO runs VALUES (?,?,?,?)",(sys.argv[2],"r","fm/fixture",sys.argv[3])); d.execute("INSERT INTO agent_invocations VALUES (?,?,?,?)",(sys.argv[2],sys.argv[4],sys.argv[5],"")); d.commit()' "$FX/$1/nm/state.sqlite" "$2" "$URL" "$3" "$4"
  echo "+ pipeline run $2 recorded: agent=$3 model=$4"
}
review() { # <case> <head> <verdict> <reader> <authors-json>
  printf 'VERDICT: %s head=%s\nIndependent reader evidence.\n' "$3" "$2" > "$FX/$1/report.md"
  echo "+ review $3 at ${2:0:12} by $4 declaring $5"
  clean FM_HOME="$FX/$1/home" "$REC" review --pr "$URL" --head "$2" --verdict "$3" --reader-model "$4" \
    --author-groups "$5" --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
    --report "$FX/$1/report.md" >/dev/null && echo "  recorded" || echo "  record rc=$?"
}
verify() { # <case> <head> <base>
  local out rc=0
  out=$(clean NM_HOME="$FX/$1/nm" FM_HOME="$FX/$1/home" "$REC" verify --pr "$URL" --head "$2" --task task-x1 --base "$3" --json 2>&1) || rc=$?
  echo "+ verify live head ${2:0:12} -> rc=$rc"
  python3 -I -c 'import json,sys
o=json.loads(sys.argv[1])
if o.get("ok"): print("  ACCEPTED carried_from=%s reader=%s facts=%s" % ((o.get("carried_from") or "none (exact head)")[:12], o.get("reader_model"), o.get("facts")))
else: print("  REFUSED %s: %s" % (o["error"]["kind"], o["error"]["message"][:400]))' "$out" 2>/dev/null || echo "  raw: ${out:0:400}"
}
plan() { # <case> <head> <base>
  echo "+ plan at ${2:0:12}"
  clean NM_HOME="$FX/$1/nm" FM_HOME="$FX/$1/home" "$REC" plan --pr "$URL" --head "$2" --task task-x1 --base "$3" 2>&1 | python3 -I -c 'import json,sys; o=json.load(sys.stdin); print("  groups=%s uncovered=%s" % (json.dumps(o.get("groups")), json.dumps(o.get("uncovered"))))'
}
