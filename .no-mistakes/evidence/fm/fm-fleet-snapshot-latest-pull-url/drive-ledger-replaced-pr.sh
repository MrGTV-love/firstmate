#!/bin/bash
# Drive the real open-work ledger (bin/fm-open-loops.sh --json, which reads the
# real bin/fm-fleet-snapshot.sh) in a disposable lab FM_HOME. The only stand-in
# is a disposable local "gh" that plays GitHub: PR 1 (withdrawn) is gone (404),
# PR 2 (its replacement) is open. Usage: drive-ledger-replaced-pr.sh <code-root>
set -u
cd "$1"
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
FAKE=$(mktemp -d "${TMPDIR:-/tmp}/fm-fake-forge.XXXXXX")
trap 'bin/fm-lab-home.sh teardown "$FM_HOME" >/dev/null 2>&1; rm -rf "$FM_HOME" "$FAKE"' EXIT
cat > "$FAKE/gh" <<'SH'
#!/bin/bash
endpoint=${!#}
printf '%s\n' "$endpoint" >> "$FAKE_LOG"
case "$endpoint" in
  */pulls/1|*/pulls/1\?*)
    printf 'HTTP/2.0 404 Not Found\r\nx-ratelimit-limit: 5000\r\nx-ratelimit-remaining: 4999\r\n\r\n{"message":"Not Found"}\n'
    echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
  */pulls/2|*/pulls/2\?*)
    printf 'HTTP/2.0 200 OK\r\nx-ratelimit-limit: 5000\r\nx-ratelimit-remaining: 4999\r\n\r\n'
    printf '{"html_url":"https://github.com/example/repo/pull/2","number":2,"state":"open","merged_at":null,"draft":false,"title":"replacement","head":{"ref":"fm/replaced","sha":"abc","repo":{"full_name":"example/repo"}},"base":{"ref":"main","repo":{"full_name":"example/repo"}},"user":{"login":"x"},"updated_at":"2026-10-27T00:00:00Z","created_at":"2026-10-27T00:00:00Z"}\n' ;;
  *)
    printf 'HTTP/2.0 200 OK\r\nx-ratelimit-limit: 5000\r\nx-ratelimit-remaining: 4999\r\n\r\n[]\n' ;;
esac
SH
chmod +x "$FAKE/gh"
export FAKE_LOG=$FAKE/calls.log; : > "$FAKE_LOG"
S=$FM_HOME/state
# A real task worktree: one landed baseline on origin main plus one unlanded
# commit on the task branch, so the ledger asks the forge about the task's PR.
G=(git -c user.name=fmlab -c user.email=fmlab@example.invalid -c init.defaultBranch=main)
"${G[@]}" init -q --bare "$FAKE/origin.git"
"${G[@]}" -C "$FAKE/origin.git" symbolic-ref HEAD refs/heads/main
"${G[@]}" init -q "$FAKE/seed"; echo base > "$FAKE/seed/base"
"${G[@]}" -C "$FAKE/seed" add base; "${G[@]}" -C "$FAKE/seed" commit -q -m baseline
"${G[@]}" -C "$FAKE/seed" push -q "$FAKE/origin.git" main
"${G[@]}" clone -q "$FAKE/origin.git" "$FM_HOME/projects/replaced-wt"
"${G[@]}" -C "$FM_HOME/projects/replaced-wt" checkout -q -b fm/replaced
echo work > "$FM_HOME/projects/replaced-wt/work"
"${G[@]}" -C "$FM_HOME/projects/replaced-wt" add work; "${G[@]}" -C "$FM_HOME/projects/replaced-wt" commit -q -m 'replacement work'
printf 'kind=ship\nbackend=tmux\nwindow=fm-lab:replaced\nworktree=%s\n' "$FM_HOME/projects/replaced-wt" > "$S/replaced.meta"
printf '## In flight\n- [ ] replaced - Replaced PR task (repo: alpha) (kind: ship) (since 2026-10-27)\n' > "$FM_HOME/data/backlog.md"
printf 'working: opened https://github.com/example/repo/pull/1\ndone: PR https://github.com/example/repo/pull/1 checks green\nworking: PR 1 withdrawn, replacement https://github.com/example/repo/pull/2\nfailed: worker crashed after replacement\n' > "$S/replaced.status"
echo "## snapshot pr for task 'replaced'"
FM_HOME="$FM_HOME" /bin/bash bin/fm-fleet-snapshot.sh --json | jq -c '.tasks[]|select(.id=="replaced")|.pr|{url,source}'
echo "## open-work ledger (fm-open-loops.sh --json)"
out=$(PATH="$FAKE:$PATH" FM_HOME="$FM_HOME" /bin/bash bin/fm-open-loops.sh --json 2>"$FAKE/err"); rc=$?
echo "exit=$rc"
printf '%s' "$out" | jq '{complete, rows: [.rows[] | {category, subject, evidence}]}'
echo "## forge PR reads the ledger made"; grep -E '/pulls/[0-9]+' "$FAKE_LOG" | sort -u
echo "## stderr"; head -20 "$FAKE/err"
