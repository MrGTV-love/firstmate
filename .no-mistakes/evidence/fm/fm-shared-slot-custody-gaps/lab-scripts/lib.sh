# Shared helpers for the live shared-slot custody lab. Sourced by scenario scripts.
set -u
WT_ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M4Q181EP2V9JFRYXTJ2TPTW0
W=/tmp/fm-live.UI8CJx
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M4Q181EP2V9JFRYXTJ2TPTW0
LAB=$(cat "$W/lab-path")
POOLDIR=$(cd "$W/pool/.treehouse"/proj-* && pwd -P)
PROJ=$(cd "$W/proj" && pwd -P)

# Every product call: lab FM_HOME, lab tmux socket dir, lab Treehouse root, no
# inherited fleet overrides.
fm() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX -u TMUX_PANE \
    -u FM_TASK_ID -u FM_SUPERVISION_ACTOR \
    FM_HOME="$LAB" TMUX_TMPDIR="$LAB/tmux" TREEHOUSE_ROOT="$W/pool" "$@"
}
labtmux() { env -u TMUX TMUX_TMPDIR="$LAB/tmux" tmux "$@"; }
th() { (cd "$PROJ" && TREEHOUSE_ROOT="$W/pool" treehouse "$@"); }
say() { printf '\n### %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return $rc; }

# new_slot -> canonical path of a fresh, unleased, real Treehouse pool slot.
new_slot() {
  local p
  p=$(th get --lease --lease-holder seed 2>/dev/null) || return 1
  th return "$p" >/dev/null 2>&1 || return 1
  (cd "$p" && pwd -P)
}

write_meta() {  # <id> <key=value>...
  local id=$1; shift
  printf '%s\n' "$@" > "$LAB/state/$id.meta"
}
write_brief() {  # <id> <branch>
  mkdir -p "$LAB/data/$1"
  cat > "$LAB/data/$1/brief.md" <<EOF
# Task
## Captain's intent
Live lab task $1.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: $2
EOF
}
fingerprint() {  # <path>
  local path=$1
  git -C "$path" rev-parse HEAD
  git -C "$path" symbolic-ref --quiet HEAD || printf 'detached\n'
  git -C "$path" status --porcelain --untracked-files=all
  (cd "$path" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s ' "$f"; cksum < "$f"; done)
}
branches() { git -C "$PROJ" for-each-ref --format='%(refname) %(objectname)' refs/heads/; }
check() {  # <description> <command...>
  local d=$1; shift
  if "$@"; then printf 'CHECK PASS: %s\n' "$d"; else printf 'CHECK FAIL: %s\n' "$d"; FAILS=$((FAILS+1)); fi
}
FAILS=0
