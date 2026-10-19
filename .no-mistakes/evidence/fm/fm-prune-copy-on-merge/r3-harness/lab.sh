#!/usr/bin/env bash
# Live-validation harness for fm-merge-prune (lab only). Sourced by scenario scripts.
# Real: git, treehouse, tmux, lsof, bin/fm-teardown.sh, bin/fm-merge-prune*.sh.
# Seams: gh (forge), docker/no-mistakes (no-ops), fm-control.sh exit (FM_MERGE_PRUNE_CONTROL_BIN).
set -u
REPO=${REPO_OVERRIDE:-/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M586AMGM98NA3A9EA5XJ1TPG}
LAB=$(cat /Users/charlesabrooker/tmp/.fm-lab-current)
EV=${EV_OVERRIDE:-/Users/charlesabrooker/.no-mistakes/evidence/01M586AMGM98NA3A9EA5XJ1TPG}
TMUXDIR=$(cat "$LAB/.tmuxdir")
STATE=$LAB/state
DATA=$LAB/data
REALTH=/Users/charlesabrooker/.local/bin/treehouse
export TMUX_TMPDIR=$TMUXDIR
TMUXVAL=
OUT=
NPASS=0
NFAIL=0

lab_tmux_start() {
  if ! TMUX_TMPDIR=$TMUXDIR tmux -L fm-lab has-session -t firstmate 2>/dev/null; then
    env -u TMUX TMUX_TMPDIR="$TMUXDIR" HOME="$LAB/home" PATH="$LAB/bin:$PATH" \
      tmux -L fm-lab new-session -d -s firstmate -n anchor -x 200 -y 50 -c "$LAB"
  fi
  TMUXVAL=$(TMUX_TMPDIR=$TMUXDIR tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
  export TMUXVAL
}
ltmux() { env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab "$@"; }

# lab_env <world-dir> -- cmd...: run cmd with the lab environment of one world.
lab_run() {
  local w=$1; shift
  env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_GATE_REFUSE_BYPASS \
    HOME="$LAB/home" FM_HOME="$LAB" NM_HOME="$LAB/nm" TREEHOUSE_ROOT="$w/th" PATH="$LAB/bin:$PATH" \
    TMUX="$TMUXVAL" TMUX_TMPDIR="$TMUXDIR" TH_LOG="$w/th.log" TD_LOG="$w/td.log" CTL_LOG="$w/ctl.log" \
    WORKER_PID_DIR="$LAB/workers" REPO="$REPO" REFUSE_FLAG="$w/refuse" \
    FM_MERGE_PRUNE="${FM_MERGE_PRUNE:-1}" FM_MERGE_PRUNE_TEARDOWN_BIN="$LAB/bin/teardown-rec" FM_MERGE_PRUNE_CONTROL_BIN="$LAB/bin/control-stub" \
    FM_MERGE_PRUNE_EXIT_WAIT="${FM_MERGE_PRUNE_EXIT_WAIT:-8}" GH_DATA="$LAB/ghdata" \
    "$@"
}
prune() { local w=$1; shift; lab_run "$w" "$REPO/bin/fm-merge-prune.sh" "$@"; }

lab_init() {
  mkdir -p "$LAB/bin" "$LAB/home" "$LAB/nm" "$LAB/ghdata" "$LAB/workers" "$LAB/h"
  printf '[user]\n\tname = Lab\n\temail = lab@example.invalid\n[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n' > "$LAB/home/.gitconfig"
  cat > "$LAB/bin/gh" <<'SH'
#!/usr/bin/env bash
# Forge stand-in: every PR is MERGED, with the head recorded in $GH_DATA/<n>.head.
n=
for a in "$@"; do case "$a" in */pull/*) n=${a##*/} ;; esac; done
head=$(cat "$GH_DATA/$n.head" 2>/dev/null || true)
# forge outage seam: a per-PR flag file makes every read fail
if [ -e "$GH_DATA/$n.down" ]; then echo "error: HTTP 502 (forge outage)" >&2; exit 1; fi
# forge flake seam: fail every read while the path named in $GH_DATA/flaky-while-exists exists
if [ -s "$GH_DATA/flaky-while-exists" ] && [ -e "$(cat "$GH_DATA/flaky-while-exists")" ]; then
  echo "error: HTTP 502 (forge flake)" >&2; exit 1
fi
url=https://github.com/acme/widget/pull/$n
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *"state,headRefOid,mergeCommit"*) printf '%s\t%s\t%s\n' MERGED "$head" ''; exit 0 ;;
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED "$head" "$url"; exit 0 ;;
      *"--json state "*) printf '%s\n' MERGED; exit 0 ;;
      *"headRefOid"*) printf '%s\n' "$head"; exit 0 ;;
    esac ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  cat > "$LAB/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged"; exit 0 ;;
  "pr view") printf '%s\n' "pull_request:" "  number: 7" "  state: merged"; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/bin/no-mistakes"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/bin/docker"
  cat > "$LAB/bin/treehouse" <<SH
#!/usr/bin/env bash
# Recording shim: logs every call, snapshots the slot at destroy time, then runs the REAL treehouse.
printf '%s\n' "\$*" >> "\${TH_LOG:-/dev/null}"
if [ "\${1:-}" = destroy ] && [ -n "\${2:-}" ]; then
  c=\$2
  printf '   [at destroy time] slot HEAD=%s (%s); branch=%s; status=[%s]; processes inside=[%s]\n' \\
    "\$(git -C "\$c" rev-parse --short HEAD 2>&1)" "\$(git -C "\$c" log -1 --format=%s 2>&1)" \\
    "\$(git -C "\$c" symbolic-ref -q --short HEAD 2>/dev/null || echo detached)" \\
    "\$(git -C "\$c" status --porcelain 2>&1 | tr '\n' ';')" \\
    "\$(command -p lsof -a -d cwd +D "\$c" -t 2>/dev/null | sort -u | tr '\n' ' ')" >> "\${TH_LOG:-/dev/null}"
fi
exec $REALTH "\$@"
SH
  cat > "$LAB/bin/teardown-rec" <<'SH'
#!/usr/bin/env bash
# Records one call of the REAL bin/fm-teardown.sh (state before/after, output) and runs it.
id=$1
copy=$(sed -n 's/^worktree=//p' "$FM_HOME/state/$id.meta" 2>/dev/null | tail -1)
win=$(sed -n 's/^window=//p' "$FM_HOME/state/$id.meta" 2>/dev/null | tail -1)
pp=$(tmux display-message -p -t "$win" '#{pane_pid}' 2>/dev/null)
tree() { ps -axo pid=,ppid=,comm= 2>/dev/null | awk -v p="$pp" '{par[$1]=$2; c[$1]=$3} END{for(k in par){q=par[k]; for(n=0;n<32&&q>1;n++){ if(q==p){printf "%s(%s) ", k, c[k]; break} q=par[q]}}}'; }
printf 'teardown call: args=[%s] admission=%s copy_present=%s tmux_windows=[%s] pane_shell=%s descendants=[%s]\n' \
  "$*" "${FM_IDLE_REAP_ADMISSION:-}" "$([ -e "$copy" ] && echo yes || echo no)" \
  "$(tmux list-windows -t firstmate -F '#W' 2>/dev/null | tr '\n' ' ')" "${pp:-none}" "$(tree)" >> "$TD_LOG"
if [ -s "$REFUSE_FLAG" ] && [ -e "$copy" ]; then
  # SEAM: print one refusal line, copied word for word from bin/fm-teardown.sh / bin/fm-teardown-nested-lib.sh, while the copy exists
  case "$(cat "$REFUSE_FLAG")" in
    not-landed) echo "REFUSED: the ship deliverable is not landed; a pushed branch alone is not completion." | tee -a "$TD_LOG.out" >&2 ;;
    closeout) echo "REFUSED: Vernant's closeout driver did not release own nested copy $copy/.claude/worktrees/n1 (exit 1): exact tree not covered by the merged PR" | tee -a "$TD_LOG.out" >&2 ;;
    leaked) echo "REFUSED: leaked worktree processes for $id remain after 3 reap attempts; preserving the worktree/tasktmp for manual inspection or retry." | tee -a "$TD_LOG.out" >&2 ;;
  esac
  printf 'teardown exit=1 (SEAM refusal) copy_present_after=yes\n' >> "$TD_LOG"
  if [ "${UNTRACKED_AFTER_FIRST:-0}" = 1 ]; then
    # SEAM: a file appears in the copy right after teardown's own dirt check
    printf 'late\n' > "$copy/late-untracked.txt"
  fi
  if [ "${STEER_AFTER_FIRST:-0}" = 1 ]; then
    # SEAM: the captain steers the worker right after teardown's first answer
    printf 'v1 gen=g1.1.1 seq=2 state=busy source=claude-hook event=UserPromptSubmit ts=%s\n' "$(date +%s)" > "$FM_HOME/state/$id.busy-state"
  fi
  exit 1
fi
"$REPO/bin/fm-teardown.sh" "$@" 2>&1 | tee -a "$TD_LOG.out"
rc=${PIPESTATUS[0]}
printf 'teardown exit=%s copy_present_after=%s tmux_windows_after=[%s] descendants_after=[%s]\n' \
  "$rc" "$([ -e "$copy" ] && echo yes || echo no)" "$(tmux list-windows -t firstmate -F '#W' 2>/dev/null | tr '\n' ' ')" "$(tree)" >> "$TD_LOG"
exit "$rc"
SH
  cat > "$LAB/bin/control-stub" <<'SH'
#!/usr/bin/env bash
# Seam for `fm-control.sh <id> exit`: the finished agent exits (its process ends), the pane stays open,
# the deliberate-exit marker is written and the busy record retired, as the real verb does.
printf '%s\n' "$*" >> "$CTL_LOG"
if [ -s "$WORKER_PID_DIR/$1.pid" ]; then
  wp=$(cat "$WORKER_PID_DIR/$1.pid")
  kill "$wp" 2>/dev/null || true
fi
gen=$(cat "$FM_HOME/state/$1.busy-gen" 2>/dev/null || true)
printf 'gen=%s\n' "${gen:--}" > "$FM_HOME/state/$1.control-exit"
[ -z "$gen" ] || "$REPO/bin/fm-busy-event.sh" retire "$FM_HOME/state" "$1" --gen "$gen" >/dev/null 2>&1
exit 0
SH
  chmod +x "$LAB"/bin/*
}

find_worker() {  # <slot>: pid of the 'sleep 900' working inside the slot
  local p c
  for p in $(pgrep -f 'sleep 900'); do
    c=$(lsof -a -d cwd -p "$p" -Fn 2>/dev/null | sed -n 's/^n//p')
    if [ "${c#"$1"}" != "$c" ]; then echo "$p"; return 0; fi
  done
  return 1
}

# mkworld <id> <pr-number>: project + origin + REAL treehouse slot entered by a tmux pane,
# the agent (a sleep) running in the slot, a task branch with one pushed commit, the PR
# squash-merged on origin/main, refs/pull/<n>/head on origin, and the task record.
# Sets W (world dir), WT (slot path), TIP (branch tip), PANE (pane shell pid).
mkworld() {
  local id=$1 n=$2 seed i out
  W=$LAB/w-$id
  mkdir -p "$W/th"
  : > "$W/th.log"; : > "$W/td.log"; : > "$W/td.log.out"; : > "$W/ctl.log"
  git init -q --bare "$W/origin.git"
  git -C "$W/origin.git" symbolic-ref HEAD refs/heads/main
  seed=$W/seed
  git clone -q "$W/origin.git" "$seed" 2>/dev/null
  git -C "$seed" checkout -q -b main
  printf '%s\n' '.venv/' 'node_modules/' '__pycache__/' '.DS_Store' '.claude/' '.tac/' '.mypy_cache/' '*.local' > "$seed/.gitignore"
  printf 'readme\n' > "$seed/README.md"
  git -C "$seed" add -A; git -C "$seed" commit -q -m base; git -C "$seed" push -q origin main
  rm -rf "$seed"
  git clone -q "$W/origin.git" "$W/proj" 2>/dev/null
  git -C "$W/proj" remote set-head origin main >/dev/null 2>&1 || true
  # the pane the task runs in: the pane's own shell, then the REAL `treehouse get` subshell in the slot
  ltmux new-window -d -t firstmate: -n "fm-$id" -c "$W/proj" \
    -e "TREEHOUSE_ROOT=$W/th" -e "TH_LOG=$W/th.log" -e "HOME=$LAB/home" -e "PATH=$LAB/bin:$PATH" \
    "bash --noprofile --norc"
  sleep 1
  ltmux send-keys -t "firstmate:fm-$id" "treehouse get -b fm/$id" Enter
  for i in $(seq 1 60); do
    out=$(ltmux display-message -p -t "firstmate:fm-$id" '#{pane_current_path}')
    case "$out" in "$W/th"/*) break ;; esac
    sleep 1
  done
  WT=$(cd "$out" 2>/dev/null && pwd -P) || { echo "mkworld: pane never entered a slot (cwd=$out)"; return 1; }
  PANE=$(ltmux display-message -p -t "firstmate:fm-$id" '#{pane_pid}')
  # the agent: a process of the pane's slot shell, working inside the copy
  ltmux send-keys -t "firstmate:fm-$id" "sleep 900" Enter
  sleep 1
  pgrep -f 'sleep 900' >/dev/null || true
  git -C "$WT" config user.name Lab; git -C "$WT" config user.email lab@example.invalid
  printf 'work for %s\n' "$id" > "$WT/work-$id.txt"
  git -C "$WT" add "work-$id.txt"; git -C "$WT" commit -q -m "task work $id"
  git -C "$WT" push -q origin "fm/$id" 2>/dev/null
  TIP=$(git -C "$WT" rev-parse HEAD)
  # GitHub keeps refs/pull/<n>/head after a merge
  git -C "$W/origin.git" update-ref "refs/pull/$n/head" "$TIP"
  # squash merge: main gets one new commit with exactly the branch tip's tree
  local sq
  sq=$(git -C "$WT" commit-tree 'HEAD^{tree}' -p "$(git -C "$WT" rev-parse origin/main)" -m "task work $id (#$n)")
  git -C "$WT" push -q origin "$sq:refs/heads/main" 2>/dev/null
  git -C "$WT" fetch -q origin
  printf '%s\n' "$TIP" > "$LAB/ghdata/$n.head"
  # task record
  local old=$(( $(date +%s) - 7200 )) ts
  ts=$(date -r "$old" +%Y%m%d%H%M.%S)
  cat > "$STATE/$id.meta" <<EOF
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$WT
project=$W/proj
kind=ship
mode=no-mistakes
spawn_gen=lab-$id
harness=claude
backend=tmux
pr=https://github.com/acme/widget/pull/$n
pr_head=$TIP
EOF
  printf 'done [at=%s]: PR https://github.com/acme/widget/pull/%s checks green\n' "$old" "$n" > "$STATE/$id.status"
  printf 'g1.1.1\n' > "$STATE/$id.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$(date +%s)" > "$STATE/$id.busy-state"
  printf 'fm-pr-poll-merge-notified-v1\ngithub\ngithub.com\nacme/widget\n%s\n' "$n" > "$STATE/$id.pr-poll-merge-notified"
  chmod 0600 "$STATE/$id.pr-poll-merge-notified"
  touch -t "$ts" "$STATE/$id.pr-poll-merge-notified"
  touch "$STATE/.last-watcher-beat"
  # the agent's pid (child of the slot shell) for the control seam
  WORKER=$(find_worker "$WT")
  printf '%s\n' "$WORKER" > "$LAB/workers/$id.pid"
  # the fleet's own slot-owner claim (bin/fm-spawn.sh writes it after `treehouse get`)
  ( . "$REPO/bin/fm-wake-lib.sh" 2>/dev/null && fm_treehouse_slot_owner_claim "$WT" "$id" "$LAB" ) >/dev/null 2>&1 || true
}

# ---- reporting -----------------------------------------------------------------
out_begin() { OUT=$EV/r3-live-$1.txt; : > "$OUT"; NPASS=0; NFAIL=0; }
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
check() {  # <label> <command...>  PASS when the command succeeds
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then say "PASS $label"; NPASS=$((NPASS+1)); else say "FAIL $label"; NFAIL=$((NFAIL+1)); fi
}
dump_world() {  # <id>
  local id=$1 w=$LAB/w-$1
  say "--- prune record:"; { cat "$STATE/$id.merge-prune" 2>/dev/null || echo "(none)"; } | tee -a "$OUT"
  say "--- prune log:"; { sed "s#$LAB#<LAB>#g" "$DATA/$id/merge-prune.log" 2>/dev/null || echo "(none)"; } | tee -a "$OUT"
  say "--- wake queue (this task):"; { grep "merge-prune:$id" "$STATE/.wake-queue" 2>/dev/null | sed "s#$LAB#<LAB>#g" || echo "(none)"; } | tee -a "$OUT"
  say "--- treehouse calls:"; { sed "s#$LAB#<LAB>#g" "$w/th.log" ; } | tee -a "$OUT"
  say "--- teardown calls:"; { sed "s#$LAB#<LAB>#g" "$w/td.log"; } | tee -a "$OUT"
  say "--- teardown output:"; { sed "s#$LAB#<LAB>#g" "$w/td.log.out"; } | tee -a "$OUT"
  say "--- control (agent stop) calls:"; { cat "$w/ctl.log"; } | tee -a "$OUT"
  say "--- real treehouse status:"; { (cd "$w/proj" && lab_run "$w" "$LAB/bin/treehouse" status 2>&1 | sed "s#$LAB#<LAB>#g"); } | tee -a "$OUT"
  say "--- tmux windows: $(ltmux list-windows -t firstmate -F '#W' | tr '\n' ' ')"
}
wake_count() { local n; n=$(grep -c "merge-prune:$1" "$STATE/.wake-queue" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
nothing_forced() { ! grep -Eq -- '--include-unlanded|--include-in-use|^destroy .*--force' "$LAB/w-$1/th.log"; }
destroy_calls() { local n; n=$(grep -c '^destroy ' "$LAB/w-$1/th.log" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
finish() {
  say "=== $NPASS pass, $NFAIL fail"
}

# main_moves_on <id>: another PR lands on main and edits the task's own file, so the
# task's tree is no longer contained in main's tree by a clean merge (a conflict).
main_moves_on() {
  local id=$1 t=$LAB/w-$1/mv
  rm -rf "$t"; git clone -q "$LAB/w-$id/origin.git" "$t" 2>/dev/null
  git -C "$t" config user.name Lab; git -C "$t" config user.email lab@example.invalid
  printf 'edited later by another PR\n' > "$t/work-$id.txt"
  git -C "$t" commit -qam "later PR edits the file"; git -C "$t" push -q origin main 2>/dev/null
  rm -rf "$t"
  git -C "$WT" fetch -q origin
}
# flaky_forge <id>: the forge cannot be read while this task's slot exists
flaky_forge() { printf '%s\n' "$WT" > "$LAB/ghdata/flaky-while-exists"; }
unflaky_forge() { : > "$LAB/ghdata/flaky-while-exists"; }

# lab_reset: stop this lab's private tmux server and clear every world (idempotent).
lab_reset() {
  env -u TMUX TMUX_TMPDIR="$TMUXDIR" tmux -L fm-lab kill-server 2>/dev/null || true
  local p d
  for p in $(pgrep -f 'sleep 900' 2>/dev/null); do
    lsof -a -d cwd -p "$p" -Fn 2>/dev/null | grep -q "$LAB" && kill "$p" 2>/dev/null
  done
  for d in "$LAB"/w-*; do [ -e "$d" ] && { chmod -R u+rwx "$d" 2>/dev/null; rm -rf "$d"; }; done
  for d in "$STATE"/* "$STATE"/.[a-zA-Z]*; do [ -e "$d" ] && rm -rf "$d"; done
  for d in "$DATA"/* "$LAB"/workers/* "$LAB"/ghdata/*; do [ -e "$d" ] && rm -rf "$d"; done
  return 0
}

# forge_down <pr>: the forge cannot be read for this PR (teardown cannot prove the landing itself)
forge_down() { : > "$LAB/ghdata/$1.down"; }

# seam_refuse <class>: teardown prints that exact refusal while the copy exists (flag read at call time)
seam_refuse() { printf '%s\n' "$1" > "$W/refuse"; }
