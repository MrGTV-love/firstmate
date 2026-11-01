# Source inside one shell invocation. Needs RIG, WT=worktree root.
export RIG_REAL_HOME=$HOME
R=MrGTV-love/firstmate; PRN=343; URL=https://github.com/$R/pull/$PRN
H=abb8fb21831ae0abe1d874031dc3873595191be6
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M6BGN0JVBZ69X7N7T9AR9GW9
compare_json() { # tip mergebase behind
  printf '{"base_commit":{"sha":"%s"},"merge_base_commit":{"sha":"%s"},"behind_by":%s,"ahead_by":5,"status":"diverged"}\n' "$1" "$2" "$3"
}
new_lab() { # name [url] [head] -> sets LAB, SCEN_DIR; makes lab FM_HOME and task meta
  local name=$1 url=${2:-$URL} head=${3:-$H}
  SCEN_DIR=$RIG/scen/$name; rm -rf "$SCEN_DIR"; mkdir -p "$SCEN_DIR"; export SCEN_DIR RIG
  LAB=$("$WT/bin/fm-lab-home.sh" create "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")")
  mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$RIG/userhome/.no-mistakes"
  [ -f "$RIG/userhome/.no-mistakes/state.sqlite" ] || python3 -c 'import sqlite3, sys; sqlite3.connect(sys.argv[1]).executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")' "$RIG/userhome/.no-mistakes/state.sqlite"
  cp "$WT/.tasks.toml" "$LAB/.tasks.toml" 2>/dev/null || true
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  git -C "$RIG/task" checkout -q --detach "$head"
  printf '%s\n' "window=fm-task-rig" "worktree=$RIG/task" "project=$RIG/project" "kind=ship" "model=gpt-5.1-codex" "branch=rig/head" "mode=no-mistakes" > "$LAB/state/rig-task.meta"
  git -C "$RIG/task" update-ref refs/remotes/origin/rig/head "$head"
  env -u NO_MISTAKES_GATE FM_HOME="$LAB" HOME="$RIG/userhome" PATH="$RIG/bin:$PATH" python3 "$WT/bin/fm-review-record.py" captain-word --pr "$url" --head "$head" --words "lab rig record, only in this disposable lab" >/dev/null
}
drive() { # label script_root url args...  appends transcript
  local label=$1 root=$2 url=$3 rc=0; shift 3
  { echo; echo "=== $label"; echo "\$ bin/fm-pr-merge.sh rig-task $url $*"; } >> "$OUT"
  env -u NO_MISTAKES_GATE -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$LAB" HOME="$RIG/userhome" PATH="$RIG/bin:$PATH" FM_PR_GITHUB_MERGEABLE_RETRY_DELAY=0 TASKS_AXI_BACKEND=markdown \
    "$root/bin/fm-pr-merge.sh" rig-task "$url" "$@" > "$SCEN_DIR/out" 2>&1 || rc=$?
  cut -c1-420 "$SCEN_DIR/out" >> "$OUT"
  echo "exit=$rc" >> "$OUT"
  echo "merge call reached: $(grep -c '^BLOCKED-MERGE' "$SCEN_DIR/gh.log" || true); $(grep '^BLOCKED-MERGE' "$SCEN_DIR/gh.log" | head -1 | cut -c1-160)" >> "$OUT"
  echo "non-read gh calls refused by rig: $(grep -c '^REFUSED' "$SCEN_DIR/gh.log" || true); $(grep '^REFUSED' "$SCEN_DIR/gh.log"|head -2|cut -c1-120)" >> "$OUT"
  echo "Actions reads: $(grep -c 'actions/' "$SCEN_DIR/gh.log" || true); compare reads: $(grep -c '/compare/' "$SCEN_DIR/gh.log" || true)" >> "$OUT"
  echo "guard events: $(jq -rc '[.guard,.decision]|join(":")' "$LAB/state/guard-events.jsonl" 2>/dev/null | tr '\n' ' ')" >> "$OUT"
  LAST_RC=$rc
}
