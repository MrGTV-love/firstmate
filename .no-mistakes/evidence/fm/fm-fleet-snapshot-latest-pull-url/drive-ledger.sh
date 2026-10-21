#!/usr/bin/env bash
# Drives the REAL bin/fm-open-loops.sh --json (<ROOT>) on a disposable FM_HOME.
# The task has NO pr= in its record. Its status log names a withdrawn PR 1, then the replacement PR 2.
# A fake `gh` plays the forge: PR 2 is open, PR 1 is gone (HTTP 404). Everything else is empty.
# Usage: drive-ledger.sh <root-of-firstmate-checkout> <label>
set -u
ROOT=$1; LABEL=$2
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-ledger-live.XXXXXX")
trap 'rm -rf "$W"' EXIT
H=$W/home; FB=$W/fakebin
mkdir -p "$H/state" "$H/data" "$H/projects" "$H/config" "$FB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/no-mistakes"
cat > "$FB/tmux" <<'TMUX'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) case "$*" in *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'working\nesc to interrupt\n' ;;
esac
exit 0
TMUX
cat > "$FB/gh" <<'GH'
#!/usr/bin/env bash
# fake forge: `gh api -i <endpoint>`
ep=${*: -1}
printf '%s\n' "$ep" >> "${FAKE_GH_LOG:?}"
hdr() { printf 'HTTP/2.0 %s\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 4900\r\nX-Ratelimit-Reset: %s\r\nX-Ratelimit-Resource: core\r\n\r\n' "$1" "$(( $(date +%s) + 3600 ))"; }
case "$ep" in
  repos/example/repo/pulls/2)
    hdr '200 OK'
    printf '{"number":2,"html_url":"https://github.com/example/repo/pull/2","state":"open","draft":false,"merged":false,"updated_at":"2026-10-21T00:00:00Z","head":{"sha":"%s","ref":"fm/live","repo":{"full_name":"example/repo"}},"base":{"ref":"main"}}\n' "$(printf 'a%.0s' $(seq 40))" ;;
  repos/example/repo/pulls/1)
    hdr '404 Not Found'; printf '{"message":"Not Found"}\n'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  *'/pulls?'*|*check-runs*|*statuses*|*reviews*|*comments*) hdr '200 OK'; printf '[]\n' ;;
  *) hdr '200 OK'; printf '{}\n' ;;
esac
GH
chmod +x "$FB/no-mistakes" "$FB/tmux" "$FB/gh"
U=https://github.com/example/repo/pull
# a real local git project + task worktree, and a backlog row, so the rest of the ledger is healthy
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git init -q -b main "$H/projects/alpha" && git -C "$H/projects/alpha" commit -q --allow-empty -m init
git -C "$H/projects/alpha" remote add origin https://github.com/example/repo.git
git -C "$H/projects/alpha" worktree add -q -b fm/live-task "$W/wt" main
echo work > "$W/wt/work.txt" && git -C "$W/wt" add work.txt && git -C "$W/wt" commit -q -m "worker commit not yet landed"
printf '## In flight\n- [ ] live-task - Live Task (repo: alpha) (kind: ship) (since 2026-10-21)\n' > "$H/data/backlog.md"
printf 'window=firstmate:fm-live-task\nworktree=%s\nproject=%s\nharness=claude\nkind=ship\nmode=ship\nyolo=off\nbranch=fm/live-task\n' "$W/wt" "$H/projects/alpha" > "$H/state/live-task.meta"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$H/state" live-task)
"$ROOT/bin/fm-busy-event.sh" apply "$H/state" live-task busy --gen "$gen" --source claude-hook --event user-prompt-submit
printf 'done: PR %s/1 checks green\nworking: PR 1 withdrawn, replacement %s/2\n' $U $U > "$H/state/live-task.status"
echo "== $LABEL  ($ROOT/bin/fm-open-loops.sh --json)"
env PATH="$FB:$PATH" FM_HOME="$H" FAKE_GH_LOG="$W/gh.log" NM_HOME="$W/nm" "$ROOT/bin/fm-open-loops.sh" --json > "$W/ledger.json" 2> "$W/err.txt"
echo "exit=$?"
echo "--- snapshot PR the ledger read for the task:"
env PATH="$FB:$PATH" FM_HOME="$H" "$ROOT/bin/fm-fleet-snapshot.sh" --home-input 2>/dev/null | jq -c '.tasks[] | {id, pr: .pr}'
echo "--- forge endpoints the ledger asked for:"; grep -E 'pulls/[0-9]+$' "$W/gh.log" | sort | uniq -c
echo "--- ledger complete flag and degraded coverage rows:"
jq -c '{complete}' "$W/ledger.json"
jq -r '.rows[]? | select(.category=="coverage") | "\(.subject) :: \(.evidence)"' "$W/ledger.json" | cut -c1-240
[ -s "$W/err.txt" ] && { echo "--- stderr:"; head -c 400 "$W/err.txt"; }
exit 0
