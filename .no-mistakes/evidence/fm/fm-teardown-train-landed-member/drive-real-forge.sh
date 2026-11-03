#!/usr/bin/env bash
# Live check against the REAL GitHub forge, read-only.
# Runs the real bin/fm-teardown.sh in a throwaway home on a record-only task
# (copy gone) whose recorded PR is a real Vernant PR. The project is a temp
# blobless clone of MrGTV-love/vernant. `gh` is the real gh behind a filter that
# lets only `gh pr view` and `gh pr list` through and logs every call.
# treehouse, tmux, docker and no-mistakes are the suite's hermetic stubs.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M6G0SSW287C5ENA2421F4C38
LAB=$(cat /tmp/fm-train-lab.path)
. "$WT/tests/fm-teardown-helpers.sh"

real_case() {  # <name> <pr number>
  local c
  c=$(make_case "$1")
  git -C "$c/project" worktree remove --force "$c/wt" 2>/dev/null || true
  rm -rf "$c/project" "$c/wt"
  cp -R "$LAB/vernant" "$c/project"
  git -C "$c/project" config credential.helper '!/opt/homebrew/bin/gh auth git-credential'
  write_windowless_legacy_meta "$c" no-mistakes ship "$c/missing-wt"
  printf '%s\n' "pr=https://github.com/MrGTV-love/vernant/pull/$2" >> "$c/state/task-x1.meta"
  seed_backlog_in_flight "$c"
  add_logging_treehouse "$c"
  cat > "$c/fakebin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "gh \$*" >> "$c/gh.log"
case "\${1:-} \${2:-}" in
  "pr view"|"pr list") exec /opt/homebrew/bin/gh "\$@" ;;
esac
echo "read-only filter: blocked gh \$*" >&2
exit 97
SH
  chmod +x "$c/fakebin/gh"
  printf '%s\n' "$c"
}

show() {  # <case> <label>
  local c=$1 rc=0
  run_teardown "$c" > "$c/stdout" 2> "$c/stderr" || rc=$?
  echo "=== $2"
  echo "exit: $rc"
  echo "--- stdout:"; cat "$c/stdout"
  echo "--- stderr:"; cat "$c/stderr"
  echo "--- real gh calls (read-only filter):"; sed 's/^/  /' "$c/gh.log" 2>/dev/null
  echo "--- treehouse calls: $(tr '\n' ';' < "$c/treehouse.log" 2>/dev/null)"
  echo "--- task record present after: $([ -e "$c/state/task-x1.meta" ] && echo yes || echo no)"
  echo "--- backlog task-x1 after:"; tasks-axi show task-x1 --file "$c/data/backlog.md" 2>&1 | sed 's/^/  /'
  echo
}

echo "# real forge run at $(git -C "$WT" rev-parse HEAD), $(date -u +%FT%TZ)"
echo
show "$(real_case real-3528 3528)" \
  "R1. real Vernant PR 3528 (CLOSED, unmerged), listed by merged train PR 3599 at its head: expect accepted, naming 3599"
show "$(real_case real-3567 3567)" \
  "R2. real Vernant PR 3567 (CLOSED, unmerged), listed by no PR on the forge: expect refused"
show "$(real_case real-3444 3444)" \
  "R3. real Vernant PR 3444 (CLOSED, unmerged): merged PR 3451 names its URL and head sha in prose, not as '<url> at <sha>': expect refused"
