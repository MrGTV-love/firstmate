#!/usr/bin/env bash
# Live driver: real bin/fm-fleet-snapshot.sh and real bin/fm-open-loops.sh --heartbeat
# against a disposable FM_HOME and a forge double. pull/1 is withdrawn (forge 404),
# pull/2 is the open replacement. Usage: drive-ledger.sh <bin-tree-root> <label> <work-dir>
set -u
code=$1 label=$2 work=$3
home=$work/home fb=$work/fakebin
rm -rf "$work"; mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$fb" "$work/nm"
cat > "$fb/gh" <<'GH'
#!/usr/bin/env python3
import json, sys, time
args = sys.argv[1:]
path = '/' + args[-1].lstrip('/')
open(sys.argv[0] + '.log', 'a').write(path + '\n')
rate = f"X-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4000\r\nX-Ratelimit-Reset: {int(time.time())+3600}\r\nX-Ratelimit-Resource: core\r\n"
if path.endswith('/pulls/1'):
    sys.stdout.write('HTTP/2.0 404 Not Found\r\n' + rate + '\r\n{"message":"Not Found"}')
    sys.stderr.write('gh: Not Found (HTTP 404)\n'); sys.exit(1)
if path.endswith('/pulls/2'):
    body = {"html_url": "https://github.com/example/repo/pull/2", "number": 2, "state": "open",
            "merged_at": None, "draft": False, "created_at": "2026-10-20T00:00:00Z",
            "updated_at": "2026-10-20T00:00:00Z", "user": {"login": "fm"},
            "head": {"sha": __import__("os").environ["PR2_HEAD"], "ref": "fm/replaced", "repo": {"full_name": "example/repo"}},
            "base": {"ref": "main", "repo": {"full_name": "example/repo"}}}
elif '/check-runs' in path: body = {"check_runs": []}
elif '/pulls?' in path or '/statuses' in path: body = []
else: body = {}
sys.stdout.write('HTTP/2.0 200 OK\r\nEtag: "e"\r\n' + rate + '\r\n' + json.dumps(body))
GH
printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"
cat > "$fb/tmux" <<'TM'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf 'fm-replaced\n' ;;
  display-message) case "$*" in *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
TM
chmod +x "$fb/gh" "$fb/no-mistakes" "$fb/tmux"
# Real git: a bare origin, the project clone, and the task copy with one unlanded commit.
export GIT_AUTHOR_NAME=fm GIT_AUTHOR_EMAIL=fm@example.invalid GIT_COMMITTER_NAME=fm GIT_COMMITTER_EMAIL=fm@example.invalid
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.$work/origin.git.insteadOf" GIT_CONFIG_VALUE_0=https://github.com/example/repo.git
git init -q --bare "$work/origin.git"; git -C "$work/origin.git" symbolic-ref HEAD refs/heads/main
git init -q -b main "$work/seed"; echo base > "$work/seed/base"; git -C "$work/seed" add base
git -C "$work/seed" commit -q -m baseline; git -C "$work/seed" remote add origin https://github.com/example/repo.git
git -C "$work/seed" push -q origin main; cp -R "$work/seed" "$home/projects/project"
git clone -q https://github.com/example/repo.git "$work/wt"; git -C "$work/wt" checkout -q -b fm/replaced
echo change > "$work/wt/change"; git -C "$work/wt" add change; git -C "$work/wt" commit -q -m 'replacement work'
export PR2_HEAD; PR2_HEAD=$(git -C "$work/wt" rev-parse HEAD)
printf '## In flight\n- [ ] replaced - Replaced PR task (repo: project) (kind: ship) (since 2026-10-19)\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
printf 'window=firstmate:fm-replaced\nbackend=tmux\nworktree=%s\nproject=%s\nbranch=fm/replaced\nkind=ship\nmode=ship\nharness=claude\nyolo=off\n' \
  "$work/wt" "$home/projects/project" > "$home/state/replaced.meta"
gen=$(env FM_HOME="$home" "$code/bin/fm-busy-event.sh" arm "$home/state" replaced)
env FM_HOME="$home" "$code/bin/fm-busy-event.sh" apply "$home/state" replaced busy --gen "$gen" --source claude-hook --event user-prompt-submit
printf 'done: PR https://github.com/example/repo/pull/1 checks green\nworking: PR 1 withdrawn, replacement https://github.com/example/repo/pull/2\n' > "$home/state/replaced.status"
run() { env -u NO_MISTAKES_GATE -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX PATH="$fb:$PATH" FM_HOME="$home" NM_HOME="$work/nm" "$@"; }
echo "=== [$label] status log ==="; cat "$home/state/replaced.status"
echo "=== [$label] \$ FM_HOME=<lab> bin/fm-fleet-snapshot.sh --json | jq '.tasks[].pr' ==="
run "$code/bin/fm-fleet-snapshot.sh" --json | jq -c '.tasks[] | {id, pr}'
echo "=== [$label] \$ FM_HOME=<lab> bin/fm-open-loops.sh --heartbeat ==="
run "$code/bin/fm-open-loops.sh" --heartbeat >/dev/null 2>"$work/heartbeat.err"; echo "exit=$?"
echo "=== [$label] published state/open-loops.json: complete + coverage rows ==="
jq -c '{complete, coverage_rows: [.rows[] | select(.category == "coverage") | {subject, evidence}], rows: [.rows[] | {category, subject, evidence}]}' "$home/state/open-loops.json"
echo "=== [$label] forge requests ==="; sort -u "$fb/gh.log"
echo "=== [$label] \$ bin/fm-open-loops.sh --check-actions (wake drain gate) ==="
run "$code/bin/fm-open-loops.sh" --check-actions; echo "exit=$?"
