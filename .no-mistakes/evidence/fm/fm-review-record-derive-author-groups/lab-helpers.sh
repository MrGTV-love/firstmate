# Lab helpers. Source with S and W set.
set -u
RR="$W/bin/fm-review-record.py"
URL=https://github.com/example/repo/pull/197
mk() {  # name mode model
  L=$S/$1; rm -rf "$L"; mkdir -p "$L/home/state" "$L/nm"
  git init -q -b main "$L/wt"; git -C "$L/wt" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
  BASE=$(git -C "$L/wt" rev-parse HEAD); git -C "$L/wt" checkout -q -b fm/x
  { echo "worktree=$L/wt"; echo "project=$L/wt"; echo "branch=fm/x"; echo kind=ship
    [ -n "$3" ] && echo "model=$3"; [ -n "$2" ] && echo "mode=$2"; } > "$L/home/state/task-x1.meta"
  export FM_HOME=$L/home FM_STATE_OVERRIDE=$L/home/state NM_HOME=$L/nm
}
commit() { git -C "$L/wt" -c user.name=t -c user.email=t@x commit -q --allow-empty -m "$1"; HEAD_SHA=$(git -C "$L/wt" rev-parse HEAD); }
db() {  # python statements using add_run(id, pr, branch), add_inv(run, step, agent, model, provider)
  python3 - "$L/nm/state.sqlite" "$S/schema.sql" "$L/wt" "$1" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1]); db.execute("PRAGMA journal_mode=WAL")
if not db.execute("SELECT 1 FROM sqlite_master WHERE name='runs'").fetchone():
    db.executescript(open(sys.argv[2]).read())
    db.execute("INSERT INTO repos (id, working_path, upstream_url, created_at) VALUES ('r', ?, 'u', 0)", (sys.argv[3],))
n = [0]
def add_run(i, pr, branch):
    db.execute("INSERT INTO runs (id, repo_id, branch, head_sha, base_sha, pr_url, created_at, updated_at) VALUES (?, 'r', ?, 'h', 'b', ?, 0, 0)", (i, branch, pr))
def add_inv(run, step, agent, model, provider):
    n[0] += 1
    db.execute("INSERT INTO agent_invocations (id, run_id, step_name, round, purpose, agent, model, model_provider, session_mode, started_at, completed_at, duration_ms, exit_status) VALUES (?, ?, ?, 1, 'p', ?, ?, ?, 'fresh', 0, 0, 0, 'completed')", (f"{run}-{n[0]}", run, step, agent, model, provider))
exec(sys.argv[4])
db.commit(); db.close()
PY
}
rec() {  # verdict reader groups [covered]
  printf 'VERDICT: %s head=%s\nlab report\n' "$1" "$HEAD_SHA" > "$L/report-$RANDOM.md"; local rp; rp=$(ls -t "$L"/report-*.md | head -1)
  local -a cov=(); [ $# -ge 4 ] && cov=(--covered-groups "$4")
  echo "\$ fm-review-record.py review --verdict $1 --reader-model $2 --author-groups '$3' ${cov[*]:-}"
  "$RR" review --pr "$URL" --head "$HEAD_SHA" --verdict "$1" --reader-model "$2" --author-groups "$3" ${cov[@]+"${cov[@]}"} \
    --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no --report "$rp"; echo "  rc=$?"
}
ver() {
  echo "\$ fm-review-record.py verify --pr $URL --head <head> --task task-x1 --base <base>"
  "$RR" verify --pr "$URL" --head "$HEAD_SHA" --task task-x1 --base "$BASE" | sed "s#$S#<lab>#g"; echo "  rc=${PIPESTATUS[0]}"
}
