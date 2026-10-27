#!/usr/bin/env bash
# Live harness for the merge-time pool-copy prune (branch fm/fm-prune-copy-on-merge).
#
# Each scenario mints its own marked lab home (bin/fm-lab-home.sh env), a
# private tmux server (tmux -L fm-lab) and a throwaway Treehouse pool
# (TREEHOUSE_ROOT in a temp dir, HOME pointed at a temp dir so the real
# ~/.treehouse is never read or written). The REAL treehouse binary, the REAL
# tmux, the REAL bin/fm-merge-prune.sh, bin/fm-teardown.sh, bin/fm-control.sh
# and bin/fm-busy-event.sh run. The task pane is a real tmux pane whose login
# shell ran a real `treehouse get`. Only GitHub (gh, gh-axi), no-mistakes and
# docker are stand-ins, because the PR is a local squash merge into a local
# bare origin.
#
# Usage: live-harness.sh <scenario> <transcript-file>
set -u
REPO=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5YE70NYR3YRQ45G490SQZBF
SCN=$1
OUT=$2
: > "$OUT"
exec 3>>"$OUT"
say() { printf '%s\n' "$*" >&3; }
show() { say "\$ $*"; "$@" >&3 2>&1; say "[exit $?]"; }

eval "$("$REPO/bin/fm-lab-home.sh" env 2>/dev/null)"
LAB=$FM_HOME
X=$(cd "$(mktemp -d /tmp/fmpx.XXXXXX)" && pwd -P)
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/fm-lab"
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null || true
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 && rm -rf "$LAB"
  chmod -R u+w "$X" 2>/dev/null; rm -rf "$X"
}
trap cleanup EXIT

mkdir -p "$X/home" "$X/bin" "$X/th"
: > "$X/home/.zshrc"; : > "$X/home/.zshenv"; : > "$X/home/.zprofile"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
fmenv() {
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
    HOME="$X/home" FM_HOME="$LAB" TREEHOUSE_ROOT="$X/th" PATH="$X/bin:$PATH" SHELL=/bin/zsh \
    TMUX="$SOCK,0,0" TMUX_TMPDIR="$TMUX_TMPDIR" GH_LOG="$X/gh.log" "$@"
}
STATE=$LAB/state
DATA=$LAB/data

# --- GitHub, no-mistakes and docker stand-ins -------------------------------
cat > "$X/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$X/bin/docker" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$X/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged"; exit 0 ;;
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-10-27T00:00:00Z"'; exit 0 ;;
esac
exit 0
SH
chmod +x "$X/bin/no-mistakes" "$X/bin/docker" "$X/bin/gh-axi"
write_gh() {  # <pr head sha>
  cat > "$X/bin/gh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$GH_LOG"
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,mergeCommit"*) printf '%s\t%s\t%s\n' MERGED '$1' ''; exit 0 ;;
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED '$1' 'https://github.com/acme/widget/pull/7'; exit 0 ;;
      *"--json state "*) printf '%s\n' MERGED; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$1'; exit 0 ;;
    esac ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$X/bin/gh"
}

# --- the project, its origin, and a real treehouse pane ---------------------
git init -q --bare "$X/origin.git"
git -C "$X/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$X/origin.git" "$X/seed" 2>/dev/null
git -C "$X/seed" checkout -q -b main
printf '%s\n' '.venv/' 'node_modules/' '__pycache__/' '.DS_Store' '.claude/' '*.local' > "$X/seed/.gitignore"
printf 'readme\n' > "$X/seed/README.md"
git -C "$X/seed" add -A && git -C "$X/seed" commit -q -m base && git -C "$X/seed" push -q origin main
rm -rf "$X/seed"
git clone -q "$X/origin.git" "$X/project" 2>/dev/null
git -C "$X/project" remote set-head origin main 2>/dev/null

# A second window stands for the rest of the fleet, so the lab server outlives the task window.
fmenv tmux -L fm-lab new-session -d -s firstmate -n fleet -x 200 -y 50 -c "$X"
fmenv tmux -L fm-lab new-window -d -t firstmate: -n fm-t1 -c "$X/project"
sleep 1
fmenv tmux -L fm-lab send-keys -t firstmate:fm-t1 'treehouse get' Enter
SLOT=
for _ in $(seq 1 90); do
  p=$(tmux -L fm-lab display -p -t firstmate:fm-t1 '#{pane_current_path}' 2>/dev/null)
  case "$p" in "$X/th"/*) SLOT=$p; break ;; esac
  sleep 1
done
if [ -z "$SLOT" ]; then
  say "SETUP FAILED: treehouse get did not enter a slot"; tmux -L fm-lab capture-pane -p -t firstmate:fm-t1 >&3; exit 9
fi
SLOT=$(cd "$SLOT" && pwd -P)
PANE_PID=$(tmux -L fm-lab display -p -t firstmate:fm-t1 '#{pane_pid}')
say "lab home: $LAB"
say "throwaway pool (TREEHOUSE_ROOT): $X/th"
say "task copy acquired by a real 'treehouse get' in tmux pane firstmate:fm-t1: $SLOT"

# The task's work: a branch, pushed, then squash-merged into main the way GitHub does.
git -C "$SLOT" checkout -q -b fm/t1
printf 'work\n' > "$SLOT/work.txt"
git -C "$SLOT" add work.txt && git -C "$SLOT" commit -q -m "task work"
git -C "$SLOT" push -q origin fm/t1 2>/dev/null
squash=$(git -C "$SLOT" commit-tree 'HEAD^{tree}' -p "$(git -C "$SLOT" rev-parse origin/main)" -m "task work (#7)")
git -C "$SLOT" push -q origin "$squash:refs/heads/main" 2>/dev/null
git -C "$SLOT" fetch -q origin
git -C "$X/project" fetch -q origin
HEAD_SHA=$(git -C "$SLOT" rev-parse HEAD)
write_gh "$HEAD_SHA"

# What bin/fm-spawn.sh leaves: the slot-owner claim and the task record.
fmenv bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_slot_owner_claim "$2" t1 "$3"' _ "$REPO" "$SLOT" "$LAB" || say "claim failed"
printf '%s\n' "window=firstmate:fm-t1" "endpoint_task_id=t1" "worktree=$SLOT" "project=$X/project" "kind=ship" \
  "mode=no-mistakes" "spawn_gen=lab-t1" "harness=claude" "backend=tmux" \
  "pr=https://github.com/acme/widget/pull/7" "pr_head=$HEAD_SHA" > "$STATE/t1.meta"
printf 'done [at=%s]: PR https://github.com/acme/widget/pull/7 checks green\n' "$(( $(date +%s) - 120 ))" > "$STATE/t1.status"
touch "$STATE/.last-watcher-beat"
# The worker's Stop hook: an idle busy record (the real writer).
GEN=$(fmenv "$REPO/bin/fm-busy-event.sh" arm "$STATE" t1 --state idle --source claude-hook --event Stop)
# The merge path's verified-merge marker (the real writer).
fmenv bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_poll_merge_mark_notified "$2" t1 github github.com acme/widget 7' _ "$REPO" "$STATE" || say "marker failed"

pane_tree() {
  say "--- processes in the task pane (pid ppid comm args):"
  ps -axo pid=,ppid=,comm=,args= | awk -v root="$PANE_PID" '
    { pid[$1]=$2; line[$1]=$0 }
    END { for (p in pid) { q=p; while (q in pid && q!=root && q>1) q=pid[q]; if (q==root) print line[p] } }' >&3
}
evidence() {
  say "--- data/t1/merge-prune.log:"; cat "$DATA/t1/merge-prune.log" >&3 2>/dev/null || say "(none)"
  say "--- state/t1.merge-prune (prune record):"; cat "$STATE/t1.merge-prune" >&3 2>/dev/null || say "(none: record cleared)"
  say "--- merge-prune wakes in state/.wake-queue: $(grep -c 'merge-prune' "$STATE/.wake-queue" 2>/dev/null || echo 0)"
  grep 'merge-prune' "$STATE/.wake-queue" >&3 2>/dev/null || true
  say "--- task record state/t1.meta: $([ -e "$STATE/t1.meta" ] && echo present || echo gone)"
  say "--- task copy $SLOT on disk: $([ -e "$SLOT" ] && echo PRESENT || echo GONE)"
  say "--- real treehouse status (throwaway pool):"
  (cd "$X/project" && fmenv treehouse status) >&3 2>&1 || true
  say "--- tmux windows on the lab server:"; tmux -L fm-lab list-windows -a >&3 2>&1 || say "(lab tmux server gone)"
}
run_prune() {  # <args...>
  say "\$ bin/fm-merge-prune.sh $*"
  fmenv "$REPO/bin/fm-merge-prune.sh" "$@" >&3 2>&1
  say "[exit $?]"
}
wait_log() {  # <pattern> <seconds>
  local i
  for i in $(seq 1 "$2"); do
    grep -q "$1" "$DATA/t1/merge-prune.log" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}
copy_gone_for() {  # <seconds>
  local i
  for i in $(seq 1 "$1"); do [ -e "$SLOT" ] || return 0; sleep 1; done
  return 1
}

RESULT=FAIL
. "$(dirname "$0")/live-scenarios.sh"
say ""
say "=== scenario: $SCN"
"scn_$SCN"
say ""
say "RESULT: $RESULT"
