#!/usr/bin/env bash
# End-to-end: REAL fm-open-loops.sh (which calls the REAL fm-fleet-snapshot.sh --home-input and the REAL
# fm-gh-rest.sh) against a disposable lab home. Only the GitHub network edge (`gh api -i`) is a double.
# The double returns 404 for the withdrawn PR (pull/1) and a live PR for the replacement (pull/2).
# usage: drive-ledger.sh <lab-home> <code-root> <scenario: replaced|control>
set -u
LAB=$1
CODE=$2
SCEN=$3
FB="$LAB/fakebin"
mkdir -p "$FB" "$LAB/state" "$LAB/data" "$LAB/projects" "$LAB/config"
rm -rf "$LAB"/state/* "$LAB"/data/*
cat > "$FB/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) case "$*" in *pane_current_command*) printf 'codex\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'work in progress\nesc to interrupt\n' ;;
esac
exit 0
SH
cat > "$FB/gh" <<'PY'
#!/usr/bin/env python3
# `gh api -i` double. 404 for the withdrawn PR; 200 for the replacement; empty list for any listing.
import json, os, sys, time
args = sys.argv[1:]
assert args[:2] == ['api', '-i'], args
path = '/' + args[-1].lstrip('/')
with open(os.environ['GH_REQUESTS'], 'a') as f:
    f.write(path + '\n')
rate = ('X-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4000\r\n'
        'X-Ratelimit-Reset: %d\r\nX-Ratelimit-Resource: core\r\n' % (int(time.time()) + 3600))
if path.endswith('/pulls/1'):
    sys.stdout.write('HTTP/2.0 404 Not Found\r\n' + rate + '\r\n{"message":"Not Found"}')
    sys.stderr.write('gh: Not Found (HTTP 404)\n')
    sys.exit(1)
if path.endswith('/pulls/2'):
    value = {'number': 2, 'html_url': 'https://github.com/example/repo/pull/2', 'state': 'open', 'merged_at': None,
             'draft': False, 'updated_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
             'head': {'sha': os.environ['PR_HEAD'], 'ref': 'fm/replaced', 'repo': {'full_name': 'example/repo'}}}
else:
    value = []
body = json.dumps(value)
sys.stdout.write('HTTP/2.0 200 OK\r\nEtag: "e%d"\r\n' % (abs(hash(path)) % 100000) + rate + '\r\n' + body)
PY
chmod +x "$FB/no-mistakes" "$FB/tmux" "$FB/gh"
U=https://github.com/example/repo/pull
# A real project clone whose origin is on GitHub (no network read: the ledger only reads the origin URL).
rm -rf "$LAB/projects/repo" "$LAB/wt-replaced"
git init -q -b main "$LAB/projects/repo"
git -C "$LAB/projects/repo" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m base
git -C "$LAB/projects/repo" remote add origin https://github.com/example/repo.git
git -C "$LAB/projects/repo" worktree add -q -b fm/replaced "$LAB/wt-replaced" 2>/dev/null
# One unlanded commit on the task branch: the ledger must then consult the forge about the task's PR.
echo work > "$LAB/wt-replaced/work.txt"
git -C "$LAB/wt-replaced" add work.txt
git -C "$LAB/wt-replaced" -c user.name=lab -c user.email=lab@example.invalid commit -q -m 'task work'
export PR_HEAD=$(git -C "$LAB/wt-replaced" rev-parse HEAD)
printf '## In flight\n- [ ] replaced - Replaced PR task (repo: repo) (kind: ship) (since 2026-10-19)\n' > "$LAB/data/backlog.md"
printf 'window=firstmate:fm-replaced\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=ship\nbranch=fm/replaced\nyolo=off\n' \
  "$LAB/wt-replaced" "$LAB/projects/repo" > "$LAB/state/replaced.meta"
gen=$("$CODE/bin/fm-busy-event.sh" arm "$LAB/state" replaced)
"$CODE/bin/fm-busy-event.sh" apply "$LAB/state" replaced busy --gen "$gen" --source claude-hook --event user-prompt-submit
case "$SCEN" in
  replaced) printf 'done: PR %s/1 checks green\nworking: PR 1 withdrawn, replacement %s/2\n' $U $U > "$LAB/state/replaced.status" ;;
  control)  printf 'working: replacement PR %s/2 only\n' $U > "$LAB/state/replaced.status" ;;
esac
: > "$LAB/gh-requests"
env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$FB:$PATH" FM_HOME="$LAB" NM_HOME="$LAB/nm" GH_REQUESTS="$LAB/gh-requests" \
  "$CODE/bin/fm-open-loops.sh" --json > "$LAB/ledger.json" 2> "$LAB/ledger.err"
echo "exit=$?"
jq -c '{schema, complete, coverage_rows:[.rows[]|select(.category=="coverage")|{subject,evidence}]}' "$LAB/ledger.json"
echo "forge requests:"; sort -u "$LAB/gh-requests"

if [ "${ACK:-0}" = 1 ]; then
  RUN() { env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$FB:$PATH" FM_HOME="$LAB" NM_HOME="$LAB/nm" GH_REQUESTS="$LAB/gh-requests" "$CODE/bin/fm-open-loops.sh" "$@"; }
  RUN --heartbeat > /dev/null 2>&1; echo "heartbeat exit=$?"
  echo "published state/open-loops.json complete=$(jq -r .complete "$LAB/state/open-loops.json") overdue_rows=$(jq '[.rows[]|select(.overdue)]|length' "$LAB/state/open-loops.json")"
  echo "--- present-overdue:"; RUN --present-overdue 2>&1 | cut -c1-300
  RUN --check-actions > "$LAB/check.out" 2>&1; echo "check-actions exit=$? (1 means acknowledgement is refused: an overdue row has no recorded action)"
  cut -c1-300 "$LAB/check.out"
fi
