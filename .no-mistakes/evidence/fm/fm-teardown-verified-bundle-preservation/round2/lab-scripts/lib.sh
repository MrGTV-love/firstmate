# Lab helpers. Source after eval of fm-lab-home.sh env. Needs WT (gate worktree).
set -u
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@lab GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@lab
STUB="$FM_HOME/../$(basename "$FM_HOME").stubs"
mkdir -p "$STUB"
# External services only: GitHub CLI and the no-mistakes daemon are stubbed so
# the lab never reaches the real forge or the real pipeline daemon.
cat > "$STUB/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr view") echo "error: pull request not found" >&2; exit 1;; "pr list") echo '[]'; exit 0;; esac
exit 0
SH
cat > "$STUB/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []"; exit 0;; "pr view") echo "error: pull request not found" >&2; exit 1;; esac
exit 0
SH
cat > "$STUB/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
export TREEHOUSE_ROOT="$FM_HOME/pool"
mkdir -p "$FM_HOME/pool" "$FM_HOME/state" "$FM_HOME/data" "$FM_HOME/projects" "$FM_HOME/work"
[ -f "$FM_HOME/data/backlog.md" ] || printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$FM_HOME/data/backlog.md"

# new_task <id> [mode]: origin + project clone + task worktree with one unpushed commit.
new_task() {
  local id=$1 mode=${2:-local-only} w="$FM_HOME/work/$1"
  mkdir -p "$w"
  git init -q --bare -b main "$w/origin.git"
  git init -q -b main "$w/project"
  echo base > "$w/project/README"; git -C "$w/project" add README; git -C "$w/project" commit -qm base
  git -C "$w/project" remote add origin "$w/origin.git"; git -C "$w/project" push -q -u origin main
  local copy
  copy=$(cd "$w/project" && treehouse get --lease --lease-holder "$id" -b "fm/$id" 2>"$w/treehouse-get.err") || { cat "$w/treehouse-get.err"; return 1; }
  ln -s "$copy" "$w/copy"
  printf 'task=%s\nhome=%s\n' "$id" "$FM_HOME" > "$(dirname "$copy")/.fm-slot-owner"
  echo "work of $id" > "$copy/work.txt"; git -C "$copy" add work.txt; git -C "$copy" commit -qm "unpublished work of $id"
  printf '%s\n' "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$copy" "branch=fm/$id" \
    "project=$w/project" "kind=ship" "mode=$mode" "spawn_gen=lab-$id" > "$FM_HOME/state/$id.meta"
  tasks-axi add "$id" "lab task $id" --kind ship --file "$FM_HOME/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$FM_HOME/data/backlog.md" >/dev/null
  COPY="$copy"; PROJ="$w/project"; W="$w"
}
# record_bundle <id> <bundle> [rev...]: the documented recipe from the fm-teardown.sh header.
record_bundle() {
  local task=$1 bundle=$2 copy; copy=$(cd "$FM_HOME/work/$1/copy" && pwd -P); shift 2
  [ $# -gt 0 ] || set -- --all
  mkdir -p "${bundle%/*}" "$FM_HOME/data/$task"
  git -C "$copy" bundle create "$bundle" "$@" 2>/dev/null &&
  git -C "$copy" bundle verify "$bundle" >/dev/null 2>&1 &&
  digest=$(shasum -a 256 "$bundle" | awk '{print $1}') &&
  tips=$(git bundle list-heads "$bundle" | awk '{print $1}' | LC_ALL=C sort -u | paste -sd ' ' -) &&
  printf '%s\t%s\t%s\n' "$bundle" "$digest" "$tips" > "$FM_HOME/data/$task/preservation-bundles.tsv"
}
hold_call() {  # <id> <bundle> <tips>
  "$WT/bin/fm-captain-hold.sh" hold "$1" --owner captain \
    --reason "Land or drop the unlanded commits of $1: preserved in bundle $2, recorded tips $3."
}
teardown() {  # <id> [args]
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    "$WT/bin/fm-teardown.sh" "$@"
}
show() { echo "\$ $*"; "$@"; echo "[exit $?]"; }
