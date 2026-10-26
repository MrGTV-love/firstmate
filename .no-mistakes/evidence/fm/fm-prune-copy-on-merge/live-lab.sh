#!/usr/bin/env bash
# Live lab for the merge prune: a disposable firstmate lab home, a private tmux
# server, the REAL treehouse binary on a throwaway TREEHOUSE_ROOT, real git
# origins on disk, the real bin/fm-teardown.sh, bin/fm-control.sh and
# bin/fm-merge-prune.sh. Only GitHub (gh, gh-axi), no-mistakes and docker are
# stubbed, because the merge happens on a local bare origin.
#
# Usage: live-lab.sh <worktree> <lab-dir>   (sourced helpers; see driver)
set -u
WT=${WT:?}
LAB=${LAB:?}
export HOME="$LAB/fakehome"
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
export FM_HOME="$LAB"
export TREEHOUSE_ROOT="$LAB/th"
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export PATH="$LAB/bin:$PATH"
STATE="$LAB/state"
DATA="$LAB/data"
PROJ="$LAB/projects/widget"
ORIGIN="$LAB/remote/widget.git"
T() { tmux "$@"; }

lab_init() {
  mkdir -p "$HOME" "$LAB/bin" "$LAB/gh" "$LAB/remote" "$LAB/projects"
  export TMUX_TMPDIR
  TMUX_TMPDIR=$("$WT/bin/fm-lab-home.sh" tmux-dir "$LAB")
  git init -q --bare "$ORIGIN"
  git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
  git clone -q "$ORIGIN" "$PROJ" 2>/dev/null
  git -C "$PROJ" checkout -q -b main
  printf '%s\n' '.venv/' 'node_modules/' '.claude/' '*.local' > "$PROJ/.gitignore"
  printf 'readme\n' > "$PROJ/README.md"
  git -C "$PROJ" add -A && git -C "$PROJ" commit -q -m base && git -C "$PROJ" push -q origin main
  git -C "$PROJ" remote set-head origin main
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$LAB/.tasks.toml"
  printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$DATA/backlog.md"
  # GitHub stand-ins: every PR number reads MERGED with the head recorded for it.
  cat > "$LAB/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/gh.log"
n=$(printf '%s\n' "$*" | grep -oE '/pull/[0-9]+' | head -1 | tr -dc 0-9)
[ -n "$n" ] || n=$(printf '%s\n' "$*" | grep -oE 'pr view [0-9]+' | tr -dc 0-9)
head=$(cat "$FM_HOME/gh/$n.head" 2>/dev/null)
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *"state,headRefOid,mergeCommit"*) printf '%s\t%s\t%s\n' MERGED "$head" ''; exit 0 ;;
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' MERGED "$head" "https://github.com/acme/widget/pull/$n"; exit 0 ;;
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
  "pr view") printf '%s\n' "pull_request:" "  number: ${3:-7}" "  state: merged" '  merged: "2026-10-26T00:00:00Z"'; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/bin/no-mistakes"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$LAB/bin/docker"
  chmod +x "$LAB/bin/"*
  T new-session -d -s firstmate -n lab -x 200 -y 50 -c "$PROJ" \
    -e HOME="$HOME" -e TREEHOUSE_ROOT="$TREEHOUSE_ROOT" -e FM_HOME="$LAB" -e PATH="$PATH" \
    -e GIT_AUTHOR_NAME=lab -e GIT_AUTHOR_EMAIL=lab@example.invalid -e GIT_COMMITTER_NAME=lab -e GIT_COMMITTER_EMAIL=lab@example.invalid
}

# new_task <id> <pr-number>: a tmux pane runs a real interactive `treehouse get`
# (as bin/fm-spawn.sh does), the task branch is committed and pushed, the PR is
# squash-merged on the origin, the slot is claimed, and the merge outcome is
# recorded through the real bin/fm-merge-outcome-lib.sh. Sets COPY and PANE.
new_task() {
  local id=$1 n=$2 head squash i
  T new-window -d -t firstmate -n "fm-$id" -c "$PROJ"
  T send-keys -t "firstmate:fm-$id" 'treehouse get' Enter
  COPY=
  for i in $(seq 1 120); do
    COPY=$(T display-message -p -t "firstmate:fm-$id" '#{pane_current_path}')
    case "$COPY" in "$TREEHOUSE_ROOT"/*) break ;; esac
    sleep 0.5
  done
  case "$COPY" in "$TREEHOUSE_ROOT"/*) ;; *) echo "treehouse get did not enter a pool slot: $COPY" >&2; return 1 ;; esac
  PANE=$(T display-message -p -t "firstmate:fm-$id" '#{pane_pid}')
  git -C "$COPY" checkout -q -b "fm/$id"
  printf '%s work\n' "$id" > "$COPY/$id.txt"
  git -C "$COPY" add "$id.txt" && git -C "$COPY" commit -q -m "$id work"
  git -C "$COPY" push -q origin "fm/$id" 2>/dev/null
  head=$(git -C "$COPY" rev-parse HEAD)
  if [ "${PIPELINE:-0}" = 1 ]; then
    # The no-mistakes pipeline pushed a fix commit on top of the copy's HEAD;
    # the merged PR head is that commit, which the copy never checked out.
    rm -rf "$LAB/pipeline-$id"
    git clone -q -b "fm/$id" "$ORIGIN" "$LAB/pipeline-$id" 2>/dev/null
    printf 'pipeline fix\n' > "$LAB/pipeline-$id/$id-fix.txt"
    git -C "$LAB/pipeline-$id" add -A && git -C "$LAB/pipeline-$id" commit -q -m "pipeline fix for $id"
    git -C "$LAB/pipeline-$id" push -q origin "fm/$id" 2>/dev/null
    head=$(git -C "$LAB/pipeline-$id" rev-parse HEAD)
    rm -rf "$LAB/pipeline-$id"
  fi
  git -C "$COPY" fetch -q origin
  squash=$(git -C "$COPY" commit-tree "$head^{tree}" -p "$(git -C "$COPY" rev-parse origin/main)" -m "$id work (#$n)")
  git -C "$COPY" push -q origin "$squash:refs/heads/main" 2>/dev/null
  git -C "$COPY" fetch -q origin
  printf '%s\n' "$head" > "$LAB/gh/$n.head"
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_treehouse_slot_owner_claim "$2" "$3" "$4"' _ "$WT" "$COPY" "$id" "$LAB" \
    || echo "slot claim failed for $COPY" >&2
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$COPY" "project=$PROJ" "kind=ship" \
    "mode=no-mistakes" "spawn_gen=lab-$id" "harness=claude" "backend=tmux" \
    "pr=https://github.com/acme/widget/pull/$n" "pr_head=$head" > "$STATE/$id.meta"
  printf 'done [at=%s]: PR https://github.com/acme/widget/pull/%s checks green\n' "$(($(date +%s) - 7200))" "$n" > "$STATE/$id.status"
  printf 'g1.1.1\n' > "$STATE/$id.busy-gen"
  printf 'v1 gen=g1.1.1 seq=1 state=idle source=claude-hook event=Stop ts=%s\n' "$(date +%s)" > "$STATE/$id.busy-state"
  touch "$STATE/.last-watcher-beat"
  awk -v row="- [ ] $id - Lab task $id (repo: widget, since 2026-10-26)" '{print} /^## In flight$/{print row}' \
    "$DATA/backlog.md" > "$DATA/backlog.md.tmp" && mv "$DATA/backlog.md.tmp" "$DATA/backlog.md"
  bash -c '. "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$2" "$3" "$4" "$5" self' _ \
    "$WT" "$LAB" "$STATE" "$id" "https://github.com/acme/widget/pull/$n" || echo "merge outcome not recorded" >&2
}

prune() { "$WT/bin/fm-merge-prune.sh" "$@"; }
wakes() { local n; n=$(grep -c "merge-prune:$1" "$STATE/.wake-queue" 2>/dev/null) || n=0; printf '%s' "$n"; }
show() {  # <id>
  echo "--- data/$1/merge-prune.log"; cat "$DATA/$1/merge-prune.log" 2>/dev/null
  echo "--- state/$1.merge-prune"; cat "$STATE/$1.merge-prune" 2>/dev/null || echo "(absent)"
  echo "--- merge-prune wakes for $1: $(wakes "$1")"; grep "merge-prune:$1" "$STATE/.wake-queue" 2>/dev/null
  echo "--- state/$1.meta present: $([ -e "$STATE/$1.meta" ] && echo yes || echo no)"
}
