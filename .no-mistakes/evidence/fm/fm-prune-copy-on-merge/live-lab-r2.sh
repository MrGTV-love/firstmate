#!/usr/bin/env bash
# Live lab for the merge-prune change: the REAL bin/fm-merge-prune.sh, the REAL
# bin/fm-teardown.sh and the REAL treehouse binary, against a disposable lab
# home (bin/fm-lab-home.sh) and a disposable treehouse pool (TREEHOUSE_ROOT in a
# throwaway directory). Only GitHub (gh, gh-axi) and no-mistakes/docker are
# stand-ins, because a real merged PR cannot be made from a gate. tmux is the
# real binary on a private TMUX_TMPDIR server inside the lab.
#
# Usage: live-lab.sh <worktree> <scenario>
set -u
REPO=$1
SCN=$2
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-mp-live.XXXXXX")
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export HOME="$BASE/fakehome"
mkdir -p "$HOME" "$BASE/bin"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export TREEHOUSE_ROOT="$BASE/th"
export TREEHOUSE_NO_UPDATE_CHECK=1
REAL_TH=$(command -v treehouse)
STATE="$LAB/state"; DATA="$LAB/data"
PR=https://github.com/acme/widget/pull/7
say() { printf '\n$ %s\n' "$*"; }
show() { printf '%s\n' "--- $1"; cat "$2" 2>/dev/null || echo "(absent)"; }

cleanup() {
  tmux kill-server 2>/dev/null || true
  # Give the pool back so nothing leaks, then remove both throwaway roots.
  [ -n "${COPY:-}" ] && [ -e "$COPY" ] && (cd "$BASE/project" && "$REAL_TH" destroy "$COPY" --include-leased --include-unlanded --include-in-use --yes >/dev/null 2>&1)
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB" "$BASE"
}
trap cleanup EXIT

# --- world: origin, project clone, one REAL treehouse leased slot ------------
git init -q --bare "$BASE/origin.git"
git -C "$BASE/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$BASE/origin.git" "$BASE/seed" 2>/dev/null
git -C "$BASE/seed" checkout -q -b main
printf '%s\n' '.venv/' 'node_modules/' '__pycache__/' '.DS_Store' '.mypy_cache/' > "$BASE/seed/.gitignore"
case "$SCN" in unignored-nested*) ;; *) printf '%s\n' '.claude/' >> "$BASE/seed/.gitignore" ;; esac
printf 'readme\n' > "$BASE/seed/README.md"
git -C "$BASE/seed" add -A && git -C "$BASE/seed" commit -q -m base && git -C "$BASE/seed" push -q origin main
git clone -q "$BASE/origin.git" "$BASE/project" 2>/dev/null
git -C "$BASE/project" remote set-head origin main 2>/dev/null
if [ "${ACQUIRE:-lease}" = pane ]; then
  # The crew-spawn shape: the pane's own shell runs the interactive
  # `treehouse get`, whose subshell is the idle shell inside the slot.
  export SHELL=/bin/bash
  tmux new-session -d -x 200 -y 50 -s firstmate -n fm-t1 -c "$BASE/project" "bash --noprofile --norc -c '\"$REAL_TH\" get -b fm/t1; exec sleep 3600'"
  for _ in $(seq 1 30); do
    COPY=$(find "$TREEHOUSE_ROOT/.treehouse" -mindepth 3 -maxdepth 3 -type d -name project 2>/dev/null | head -1)
    [ -n "$COPY" ] && [ -e "$COPY/.git" ] && break; sleep 1
  done
  sleep 2
else
  COPY=$(cd "$BASE/project" && "$REAL_TH" get --lease --lease-holder t1 -b fm/t1 2>/dev/null)
fi
[ -d "$COPY" ] || { echo "treehouse get failed"; exit 1; }
printf 'task=t1\nhome=%s\n' "$LAB" > "$(dirname "$COPY")/.fm-slot-owner"
printf 'work\n' > "$COPY/work.txt"
git -C "$COPY" add work.txt && git -C "$COPY" commit -q -m "task work"
git -C "$COPY" push -q origin fm/t1 2>/dev/null
HEAD_SHA=$(git -C "$COPY" rev-parse HEAD)
case "$SCN" in
  normal-merge|disarmed|unverified|contention|watcher)
    # GitHub "merge commit": main gets the branch tip as an ancestor.
    git -C "$BASE/project" fetch -q origin
    git -C "$COPY" push -q origin "HEAD:refs/heads/main" ;;
  *)
    # GitHub "squash merge": one new commit with the copy's tree, not on the branch.
    squash=$(git -C "$COPY" commit-tree 'HEAD^{tree}' -p "$(git -C "$COPY" rev-parse origin/main)" -m "task work (#7)")
    git -C "$COPY" push -q origin "$squash:refs/heads/main" ;;
esac
git -C "$COPY" fetch -q origin

# --- GitHub and pipeline stand-ins: the PR is merged with head HEAD_SHA ------
cat > "$BASE/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged"; exit 0 ;;
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-10-22T00:00:00Z"'; exit 0 ;;
esac
exit 0
SH
cat > "$BASE/bin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,mergeCommit"*) printf '%s\t%s\t%s\n' MERGED '$HEAD_SHA' ''; exit 0 ;;
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED '$HEAD_SHA' '$PR'; exit 0 ;;
      *"--json state "*) printf '%s\n' MERGED; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$HEAD_SHA'; exit 0 ;;
    esac ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$BASE/bin/no-mistakes"
# Every real treehouse call is logged, then passed to the real binary.
cat > "$BASE/bin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BASE/th.log"
exec "$REAL_TH" "\$@"
SH
chmod +x "$BASE/bin/"*
printf '#!/usr/bin/env bash\nexit 0\n' > "$BASE/bin/docker"
chmod +x "$BASE/bin/docker"
export PATH="$BASE/bin:$PATH"
export NM_HOME="$BASE/nm"
# tests/lib.sh exports FM_MERGE_PRUNE=0 for the unit suite; the product default is on.
unset FM_MERGE_PRUNE
[ "$SCN" != disarmed ] || export FM_MERGE_PRUNE=0

# --- the task record, as fm-spawn and the merge poll leave it ---------------
NOW=$(date +%s); OLD=$((NOW - 7200))
cat > "$STATE/t1.meta" <<EOF
window=firstmate:fm-t1
endpoint_task_id=t1
worktree=$COPY
project=$BASE/project
kind=ship
mode=no-mistakes
spawn_gen=live-t1
harness=claude
backend=tmux
pr=$PR
pr_head=$HEAD_SHA
EOF
printf 'done [at=%s]: PR %s checks green\n' "$OLD" "$PR" > "$STATE/t1.status"
printf 'g1.1.1\n' > "$STATE/t1.busy-gen"
printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$NOW" > "$STATE/t1.busy-state"
if [ "$SCN" != unverified ]; then
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n7\n' > "$STATE/t1.pr-poll-merge-notified"
  chmod 0600 "$STATE/t1.pr-poll-merge-notified"
  touch -t "$(date -r "$OLD" +%Y%m%d%H%M.%S)" "$STATE/t1.pr-poll-merge-notified"
fi
touch "$STATE/.last-watcher-beat"
# A real tmux session on the lab's private server stands for the task's pane.
# Like a crew pane: the pane's own shell (outside the copy) started the
# `treehouse get` subshell, an idle interactive shell inside the copy.
if [ "${ACQUIRE:-lease}" = pane ]; then
  PANE_PID=$(tmux display-message -p -t firstmate:fm-t1 '#{pane_pid}')
  TH_GET=$(pgrep -P "$PANE_PID" | head -1)
  IDLE_SHELL=$(pgrep -P "$TH_GET" | head -1)
  echo "pane process tree:"; ps -o pid,ppid,command -p "$PANE_PID,$TH_GET,$IDLE_SHELL" | cut -c1-160
else
tmux new-session -d -x 200 -y 50 -s firstmate -n fm-t1 -c "$BASE" "bash --noprofile --norc -c '(cd \"$COPY\" && exec bash --noprofile --norc -i); exec sleep 3600'"
sleep 1
PANE_PID=$(tmux display-message -p -t firstmate:fm-t1 '#{pane_pid}')
IDLE_SHELL=$(pgrep -P "$PANE_PID" | head -1)
fi
echo "tmux pane shell pid $PANE_PID (cwd $BASE); idle shell in copy pid $IDLE_SHELL"

echo "lab home: $LAB"
echo "pool slot (real treehouse): $COPY"
echo "copy HEAD: $HEAD_SHA   origin/main: $(git -C "$COPY" rev-parse origin/main)"
say treehouse status
(cd "$BASE/project" && "$REAL_TH" status 2>&1 | sed -n 1,10p)

prune() { FM_HOME="$LAB" "$REPO/bin/fm-merge-prune.sh" "$@"; }

closeout_wrapper() {
    # Vernant's closeout driver lives only in that managed project. This wrapper
    # prints its 2026-10-18 refusal while the copy exists, then runs the REAL
    # teardown, so the prune's fallback alone decides.
    cat > "$BASE/bin/teardown-closeout" <<SH2
#!/usr/bin/env bash
if [ -e "$COPY" ]; then
  echo "REFUSED: Vernant's closeout driver did not release foreign copy $COPY/.claude/worktrees/n1 (exit 1): exact tree not covered by the merged PR" >&2
  exit 1
fi
exec "$REPO/bin/fm-teardown.sh" "\$@"
SH2
    chmod +x "$BASE/bin/teardown-closeout"
    export FM_MERGE_PRUNE_TEARDOWN_BIN="$BASE/bin/teardown-closeout"
}
case "$SCN" in
  dirty-untracked)
    printf 'unique\n' > "$COPY/notes-only-here.txt" ;;
  follow-up)
    printf 'follow-up\n' > "$COPY/followup.txt"
    git -C "$COPY" add followup.txt && git -C "$COPY" commit -q -m "follow-up after the merge"
    git -C "$COPY" push -q origin fm/t1 2>/dev/null ;;
  fallback-squash)
    mkdir -p "$COPY/node_modules/x" "$COPY/.claude/bug-evidence"
    printf x > "$COPY/node_modules/x/i.js"; printf 'closeout\n' > "$COPY/.claude/bug-evidence/slot.json"
    closeout_wrapper ;;
  squash-scratch)
    mkdir -p "$COPY/node_modules/x" "$COPY/.mypy_cache"
    printf x > "$COPY/node_modules/x/i.js"; printf c > "$COPY/.mypy_cache/c" ;;
  unignored-nested)
    git clone -q "$BASE/origin.git" "$COPY/.claude/worktrees/n1" 2>/dev/null
    closeout_wrapper ;;
  unignored-nested-wt)
    # A nested LINKED worktree (detached at the landed head), not covered by .gitignore.
    git -C "$COPY" worktree add -q --detach "$COPY/.claude/worktrees/n1" HEAD 2>/dev/null
    closeout_wrapper ;;
  unignored-nested-wt-locked)
    git -C "$COPY" worktree add -q --detach "$COPY/.claude/worktrees/n1" HEAD 2>/dev/null
    git -C "$COPY" worktree lock --reason "lab: someone holds this" "$COPY/.claude/worktrees/n1"
    closeout_wrapper ;;
  unignored-nested-unpushed)
    git clone -q "$BASE/origin.git" "$COPY/.claude/worktrees/n1" 2>/dev/null
    printf 'unpushed\n' > "$COPY/.claude/worktrees/n1/only-here.txt"
    git -C "$COPY/.claude/worktrees/n1" add only-here.txt && git -C "$COPY/.claude/worktrees/n1" commit -q -m "unpushed nested work"
    closeout_wrapper ;;
  unignored-nested-unique)
    git clone -q "$BASE/origin.git" "$COPY/.claude/worktrees/n1" 2>/dev/null
    mkdir -p "$COPY/.claude/private"; printf 'only copy\n' > "$COPY/.claude/private/unique.bin"
    closeout_wrapper ;;
  contention)
    sleep 300 & HOLDER=$!
    mkdir "$STATE/.control-t1.lock"; printf '%s\n' "$HOLDER" > "$STATE/.control-t1.lock/pid" ;;
esac
say "git -C <copy> status --porcelain --untracked-files=all"
git -C "$COPY" status --porcelain --untracked-files=all

if [ "$SCN" = watcher ]; then
  say "fm-merge-prune.sh arm t1   (the exact arm-only call the watcher's merge poll makes)"
  prune arm t1; echo "rc=$?"
else
  say "fm-merge-prune.sh arm t1 --run   (the exact call bin/fm-pr-merge.sh makes after a verified merge)"
  prune arm t1 --run; echo "rc=$?"
fi
show "state/t1.merge-prune right after arm" "$STATE/t1.merge-prune"
if [ "$SCN" = watcher ]; then
  sleep 3
  show "data/t1/merge-prune.log before the watcher starts (arm only: no attempt yet)" "$DATA/t1/merge-prune.log"
  say "start the REAL bin/fm-watch.sh on the lab home (merge-prune tick every 1s; idle reap off)"
  # The harness re-arms the watcher after each exit (it exits to hand a wake back).
  (
    for n in 1 2 3 4 5 6 7 8; do
      echo "watcher run $n start $(date -u +%H:%M:%S)" >> "$BASE/watch.out"
      FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_IDLE_REAP_INTERVAL=0 FM_MERGE_PRUNE_INTERVAL=1 \
        FM_CHECK_INTERVAL=99999999 FM_HEARTBEAT=99999999 FM_HOME_SUMMARY_INTERVAL=99999999 \
        FM_OPEN_LOOPS_INTERVAL=99999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
        timeout 40 "$REPO/bin/fm-watch.sh" >> "$BASE/watch.out" 2>> "$BASE/watch.err"
      echo "watcher run $n exit rc=$? $(date -u +%H:%M:%S)" >> "$BASE/watch.out"
      [ -e "$STATE/t1.merge-prune" ] || break
    done
  ) &
  WATCH_PID=$!
fi
# The detached attempt: wait until it has written an outcome.
case "$SCN" in
  disarmed|unverified) sleep 3 ;;
  *) for _ in $(seq 1 120); do
       grep -qE 'reaped|kept|retry in|retain' "$DATA/t1/merge-prune.log" 2>/dev/null && break
       sleep 1
     done ;;
esac
sleep 2
if [ "$SCN" = watcher ]; then
  wait "$WATCH_PID" 2>/dev/null
  sleep 3; echo "--- watcher runs (stdout):"; cat "$BASE/watch.out"; echo "--- watcher stderr (last lines):"; tail -8 "$BASE/watch.err"
fi
if [ "$SCN" = contention ]; then
  show "state/t1.merge-prune while another lifecycle action holds the task lock" "$STATE/t1.merge-prune"
  say "release the co-tenant lock, make the record due, run the sweep (what the watcher tick starts)"
  kill "$HOLDER" 2>/dev/null; rm -rf "$STATE/.control-t1.lock"
  sed -i.bak 's/^next_at=.*/next_at=0/' "$STATE/t1.merge-prune"; rm -f "$STATE/t1.merge-prune.bak"
  prune sweep; echo "rc=$?"
fi
if [ "$SCN" = squash-scratch ] || [ "$SCN" = unignored-nested ]; then
  : # outcome printed below
fi
case "$SCN" in unignored-nested*) echo "--- nested copy before outcome check: see below";; esac
if [ "$SCN" = dirty-untracked ] || [ "$SCN" = follow-up ] || [ "$SCN" = unignored-nested-unique ] || [ "$SCN" = unignored-nested-unpushed ] || [ "$SCN" = unignored-nested-wt-locked ]; then
  say "two more forced attempts (must not raise a second wake)"
  prune run t1 --now; prune run t1 --now
fi

echo
echo "===== OUTCOME ($SCN) ====="
show "data/t1/merge-prune.log" "$DATA/t1/merge-prune.log"
show "state/t1.merge-prune" "$STATE/t1.merge-prune"
echo "--- task record state/t1.meta: $([ -e "$STATE/t1.meta" ] && echo present || echo gone)"
echo "--- pool copy dir: $([ -e "$COPY" ] && echo present || echo gone)"
[ -e "$COPY" ] && { echo "--- slot HEAD: $(git -C "$COPY" rev-parse --short HEAD 2>/dev/null)"; echo "--- copy branch: $(git -C "$COPY" symbolic-ref -q --short HEAD || echo detached)"; echo "--- copy status:"; git -C "$COPY" status --porcelain --untracked-files=all; }
case "$SCN" in unignored-nested*)
  echo "--- nested copy $COPY/.claude/worktrees/n1: $([ -e "$COPY/.claude/worktrees/n1" ] && echo present || echo gone)"
  [ -e "$COPY/.claude/worktrees/n1" ] && { echo "--- nested HEAD log:"; git -C "$COPY/.claude/worktrees/n1" log --oneline -3; }
  [ -e "$COPY/.claude/private/unique.bin" ] && echo "--- root unique file .claude/private/unique.bin: present ($(cat "$COPY/.claude/private/unique.bin"))"
  echo "--- git worktree list of the pool's base repo:"; git -C "$BASE/project" worktree list 2>/dev/null; [ -e "$COPY" ] && git -C "$COPY" worktree list 2>/dev/null
  ;; esac
echo "--- tmux pane shell $PANE_PID alive: $(kill -0 "$PANE_PID" 2>/dev/null && echo yes || echo no); idle shell $IDLE_SHELL alive: $(kill -0 "$IDLE_SHELL" 2>/dev/null && echo yes || echo no)"
echo "--- tmux pane content (lab server):"; tmux capture-pane -p -t firstmate:fm-t1 2>/dev/null | grep -v '^$' | tail -15 || echo "(window gone)"
[ -n "${TH_GET:-}" ] && echo "--- treehouse get process $TH_GET alive: $(kill -0 "$TH_GET" 2>/dev/null && echo yes || echo no)"
echo "--- wakes naming merge-prune:t1: $(grep -c 'merge-prune:t1' "$STATE/.wake-queue" 2>/dev/null || echo 0)"
grep 'merge-prune:t1' "$STATE/.wake-queue" 2>/dev/null | cut -c1-400
show "real treehouse calls made by teardown and the prune" "$BASE/th.log"
say treehouse status
(cd "$BASE/project" && "$REAL_TH" status 2>&1 | sed -n 1,10p)
[ -d "$DATA/t1/merge-prune-preserved" ] && { echo "--- preserved files:"; find "$DATA/t1/merge-prune-preserved" -type f | sed "s#$DATA#data#"; }
exit 0
