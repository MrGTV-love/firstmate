#!/usr/bin/env bash
# Live harness for bin/fm-merge-prune.sh. Builds one disposable world:
#   - a bare origin and a project clone (real git)
#   - a REAL treehouse pool under a throwaway TREEHOUSE_ROOT, with HOME pointed
#     at a throwaway directory so the real ~/.treehouse is never touched
#   - a marked disposable firstmate lab home (bin/fm-lab-home.sh create)
#   - a REAL tmux server on the lab's private socket dir; the task pane runs the
#     REAL interactive `treehouse get -b fm/t1`, exactly as a crewmate spawn does,
#     and a long `sleep` inside that subshell stands for the finished agent
# Only the outside services are stubbed: GitHub (gh, gh-axi), no-mistakes,
# docker. The control verb (fm-control.sh exit) is a stub that stops the agent
# stand-in, because no real agent CLI runs in the pane.
set -u
HARNESS=/Users/charlesabrooker/tmp/fm-mp-harness.lWvmi7
REPO=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5FXS21WC4AF9A24Y1TGANTP
BIN="$REPO/bin"
PR=https://github.com/acme/widget/pull/7

say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

lab_env() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u FM_MERGE_PRUNE \
    HOME="$W/fakehome" FM_HOME="$LABH" TREEHOUSE_ROOT="$W/th" TMUX_TMPDIR="$TMUXDIR" \
    PATH="$W/bin:$PATH" SHELL=/bin/bash NM_HOME="$W/nm" \
    GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid \
    GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid \
    CONTROL_LOG="$W/control.log" AGENT_PID_FILE="$W/agent.pid" BUSY_EVENT_BIN="$BIN/fm-busy-event.sh" \
    GH_HEAD_FILE="$W/gh.head" GH_MODE_FILE="$W/gh.mode" \
    FM_MERGE_PRUNE_CONTROL_BIN="$W/bin/control-stub" FM_MERGE_PRUNE_TEARDOWN_BIN="$W/bin/teardown-rec" FM_MERGE_PRUNE_EXIT_WAIT=5 \
    ${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"} "$@"
}

gx() { git -c user.name=fmtest -c user.email=fmtest@example.invalid "$@"; }

lab_tmux() { lab_env tmux "$@"; }

make_world() {  # <name>
  W=$(mktemp -d "${TMPDIR:-/tmp}/fm-mp-world.XXXXXX")
  LABH=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$BIN/fm-lab-home.sh" create "$LABH" >/dev/null || { echo "lab create failed"; return 1; }
  TMUXDIR=$("$BIN/fm-lab-home.sh" tmux-dir "$LABH") || { echo "tmux-dir failed"; return 1; }
  mkdir -p "$W/bin" "$W/fakehome" "$W/th" "$W/nm"
  STATE="$LABH/state"; DATA="$LABH/data"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$LABH/.tasks.toml"
  ORIGIN="$W/origin.git"
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  gx clone -q "$ORIGIN" "$W/seed" 2>/dev/null
  gx -C "$W/seed" checkout -q -b main
  printf '%s\n' '.venv/' 'node_modules/' '.DS_Store' > "$W/seed/.gitignore"
  printf 'readme\n' > "$W/seed/README.md"
  gx -C "$W/seed" add -A && gx -C "$W/seed" commit -q -m base && gx -C "$W/seed" push -q origin main
  rm -rf "$W/seed"
  gx clone -q "$ORIGIN" "$W/project" 2>/dev/null
  git -C "$W/project" remote set-head origin main 2>/dev/null || true
  install_stubs
  printf "W=%q\nLABH=%q\nTMUXDIR=%q\n" "$W" "$LABH" "$TMUXDIR" > "$HARNESS/cur.env"
  : > "$W/control.log"
}

install_stubs() {
  (cd "$REPO" && bash -c '. tests/lib.sh >/dev/null 2>&1; fm_fake_docker "$1"' _ "$W/bin")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/no-mistakes"
  # GitHub: PR 7 is merged; its head is the sha in $GH_HEAD_FILE.
  cat > "$W/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "${GH_LOG:-/dev/null}"
head=$(cat "$GH_HEAD_FILE" 2>/dev/null)
mode=$(cat "$GH_MODE_FILE" 2>/dev/null || echo merged)
[ "$mode" != down ] || { echo "error connecting to api.github.com" >&2; exit 1; }
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *"state,headRefOid,mergeCommit"*) printf '%s\t%s\t%s\n' MERGED "$head" ''; exit 0 ;;
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED "$head" 'https://github.com/acme/widget/pull/7'; exit 0 ;;
      *"--json state "*) printf '%s\n' MERGED; exit 0 ;;
      *"headRefOid"*) printf '%s\n' "$head"; exit 0 ;;
    esac ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  cat > "$W/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged"; exit 0 ;;
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-10-21T00:00:00Z"'; exit 0 ;;
esac
exit 0
SH
  # fm-control.sh exit stand-in: stops the agent stand-in in the pane, records
  # the deliberate exit and retires the busy record, as the real verb does.
  cat > "$W/bin/control-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CONTROL_LOG"
[ ! -s "$AGENT_PID_FILE" ] || kill "$(cat "$AGENT_PID_FILE")" 2>/dev/null || true
state="$FM_HOME/state"
gen=$(cat "$state/$1.busy-gen" 2>/dev/null || true)
printf 'gen=%s\n' "${gen:--}" > "$state/$1.control-exit"
[ -z "$gen" ] || "$BUSY_EVENT_BIN" retire "$state" "$1" --gen "$gen" >/dev/null 2>&1
exit 0
SH
  # Transparent recorders: the REAL treehouse and the REAL teardown run; these
  # only log the arguments and the teardown output for the evidence transcript.
  cat > "$W/bin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$W/th.log"
exec /Users/charlesabrooker/.local/bin/treehouse "\$@"
SH
  cat > "$W/bin/teardown-rec" <<SH
#!/usr/bin/env bash
printf '=== teardown %s\n' "\$*" >> "$W/teardown.out"
"$BIN/fm-teardown.sh" "\$@" 2>&1 | tee -a "$W/teardown.out"
exit "\${PIPESTATUS[0]}"
SH
  chmod +x "$W/bin/no-mistakes" "$W/bin/gh" "$W/bin/gh-axi" "$W/bin/control-stub" "$W/bin/treehouse" "$W/bin/teardown-rec"
  : > "$W/th.log"; : > "$W/teardown.out"
}

# spawn_task: a tmux pane in the lab server runs the REAL `treehouse get -b fm/t1`
# from the project, as a crewmate spawn does; the agent stand-in is a sleep in
# that subshell. Sets COPY.
spawn_task() {
  local i
  lab_tmux new-session -d -s firstmate -n fm-t1 -c "$W/project" -x 200 -y 50 \
    "env -u TMUX_PANE bash --norc --noprofile -i" || return 1
  sleep 0.5
  lab_tmux send-keys -t firstmate:fm-t1 "export PS1='pane\$ '; treehouse get -b fm/t1" Enter
  for i in $(seq 1 60); do
    COPY=$(find "$W/th" -mindepth 4 -maxdepth 4 -type d -name project 2>/dev/null | head -1)
    [ -n "$COPY" ] && [ -e "$COPY/.git" ] && [ "$(git -C "$COPY" symbolic-ref -q --short HEAD 2>/dev/null)" = fm/t1 ] && break
    sleep 0.5
  done
  [ -n "$COPY" ] || { echo "no slot appeared"; lab_tmux capture-pane -p -t firstmate:fm-t1; return 1; }
  COPY=$(cd "$COPY" && pwd -P)
  sleep 1
  # The agent stand-in, in the treehouse subshell.
  lab_tmux send-keys -t firstmate:fm-t1 "sleep 30000 & echo \$! > '$W/agent.pid'; wait" Enter
  for i in $(seq 1 20); do [ -s "$W/agent.pid" ] && break; sleep 0.25; done
  # The spawn's slot-owner claim and the task record.
  printf 'task=t1\nhome=%s\n' "$LABH" > "$(dirname "$COPY")/.fm-slot-owner"
}

do_work_and_push() {
  printf 'work\n' > "$COPY/work.txt"
  gx -C "$COPY" add work.txt && gx -C "$COPY" commit -q -m "task work"
  gx -C "$COPY" push -q origin fm/t1 2>/dev/null
  git -C "$COPY" rev-parse HEAD > "$W/gh.head"
  # GitHub keeps the PR head at refs/pull/7/head.
  git -C "$COPY" push -q origin "HEAD:refs/pull/7/head" 2>/dev/null
}

squash_merge() {
  local squash
  squash=$(gx -C "$COPY" commit-tree 'HEAD^{tree}' -p "$(git -C "$COPY" rev-parse origin/main)" -m "task work (#7)")
  gx -C "$COPY" push -q origin "$squash:refs/heads/main"
  git -C "$COPY" fetch -q origin
}

# A merged PR leaves the branch deleted on GitHub (delete-branch-on-merge).
delete_remote_branch() {
  git -C "$COPY" push -q origin --delete fm/t1 2>/dev/null
  git -C "$COPY" fetch -q --prune origin
}

write_task_record() {
  local now old head
  now=$(date +%s); old=$((now - 7200))
  head=$(cat "$W/gh.head")
  cat > "$STATE/t1.meta" <<EOF
window=firstmate:fm-t1
endpoint_task_id=t1
worktree=$COPY
project=$W/project
kind=ship
mode=no-mistakes
spawn_gen=live-t1
harness=claude
backend=tmux
pr=$PR
pr_head=$head
EOF
  printf 'done [at=%s]: PR %s checks green\n' "$old" "$PR" > "$STATE/t1.status"
  printf 'g1.1.1\n' > "$STATE/t1.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$now" > "$STATE/t1.busy-state"
  # The merge poll's verified-merge marker (bin/fm-watch.sh writes it).
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n7\n' > "$STATE/t1.pr-poll-merge-notified"
  chmod 0600 "$STATE/t1.pr-poll-merge-notified"
  touch "$STATE/.last-watcher-beat"
}

prune() { lab_env "$BIN/fm-merge-prune.sh" "$@"; }

th_status() { (cd "$W/project" && lab_env treehouse status 2>&1); }

wakes() { local n; n=$(grep -c 'merge-prune:t1' "$STATE/.wake-queue" 2>/dev/null) || n=0; printf '%s' "$n"; }

teardown_world() {
  lab_tmux kill-server 2>/dev/null || true
  [ ! -s "$W/agent.pid" ] || kill "$(cat "$W/agent.pid")" 2>/dev/null || true
  "$BIN/fm-lab-home.sh" teardown "$LABH" || true
  rm -rf "$LABH" "$W"
}

# The managed project ships Vernant-style closeout tooling: a driver under
# scripts/git-stability that refuses a nested copy whose exact tree is not in the
# merged PR (the 2026-10-18 false positive), run with the slot's .venv python.
add_closeout_driver_to_project() {
  local seed="$W/seed2"
  gx clone -q "$ORIGIN" "$seed" 2>/dev/null
  mkdir -p "$seed/scripts/git-stability"
  cat > "$seed/scripts/git-stability/closeout_pr.py" <<'PY'
import sys
print("closeout: exact tree not covered by the merged PR; refusing --execute-cleanup", file=sys.stderr)
sys.exit(1)
PY
  printf '%s\n' '.claude/' >> "$seed/.gitignore"
  gx -C "$seed" add -A && gx -C "$seed" commit -q -m "closeout tooling" && gx -C "$seed" push -q origin main
  rm -rf "$seed"
  git -C "$W/project" pull -q --ff-only origin main
}

# A Vernant session made a nested linked worktree in the slot and left its
# creation lock (launcher long gone); the slot's .venv provides the python.
add_locked_nested_copy() {
  mkdir -p "$COPY/.venv/bin"
  ln -s /usr/bin/python3 "$COPY/.venv/bin/python"
  git -C "$COPY" worktree add -q --detach "$COPY/.claude/worktrees/n1" origin/main 2>/dev/null
  git -C "$COPY" worktree lock --reason "vernant-session-active owner=vernant-s1 launcher=99991" "$COPY/.claude/worktrees/n1"
}
