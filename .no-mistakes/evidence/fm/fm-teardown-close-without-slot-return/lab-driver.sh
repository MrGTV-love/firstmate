#!/usr/bin/env bash
# Live driver for the held-copy teardown change. Runs the REAL bin/fm-teardown.sh
# and the REAL treehouse + git + tmux, inside a disposable marked lab home.
# Only the external services (gh, gh-axi, no-mistakes, docker) are stubbed.
# Usage: lab-driver.sh <function> [args...]   (source-less; state in /tmp/fm-lab-path.txt)
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M587BMA51THKRGW46FVAMJCT
LAB=$(cat /tmp/fm-lab-path.txt)
SOCKDIR=$(cat "$LAB/state/.fm-lab-tmux-dir")
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M587BMA51THKRGW46FVAMJCT
PROJ=$LAB/projects/demo
STUBS=$LAB/stubs
export TREEHOUSE_ROOT="$LAB/th"

mk_stubs() {
  mkdir -p "$STUBS"
  cat > "$STUBS/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$STUBS/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$STUBS/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$STUBS/docker" <<'SH'
#!/usr/bin/env bash
# no stacks owned by lab tasks
exit 0
SH
  chmod +x "$STUBS"/*
}

# tmux, addressed through the lab's private socket (what a lab pane's $TMUX does)
lab_tmux() { env -u TMUX TMUX_TMPDIR="$SOCKDIR" tmux -L fm-lab "$@"; }
lab_tmux_env() {
  local pid
  pid=$(lab_tmux display-message -p '#{pid}')
  printf '%s/tmux-%s/fm-lab,%s,0' "$SOCKDIR" "$(id -u)" "$pid"
}

# mk_task <id>: acquire a real pool slot with a plain `treehouse get` in a
# tmux window (the production shape), then write the task record, the slot
# claim and the backlog row. Prints the slot path.
mk_task() {
  local id=$1 before after slot n
  before=$(cd "$PROJ" && treehouse status 2>/dev/null | grep -c 'in-use' || true)
  lab_tmux new-window -d -t firstmate -n "fm-$id" -c "$PROJ" \
    "TREEHOUSE_ROOT=$LAB/th SHELL=/bin/bash treehouse get; sleep 3600"
  for _ in $(seq 1 40); do
    after=$(cd "$PROJ" && treehouse status 2>/dev/null | grep -c 'in-use' || true)
    [ "$after" -gt "$before" ] && break
    sleep 0.5
  done
  # newest in-use slot whose path is not already claimed by a record
  slot=
  for p in $(cd "$PROJ" && treehouse status 2>/dev/null | awk '/in-use/ {print $3}'); do
    p=${p/#\~/$HOME}
    p=$(cd "$p" 2>/dev/null && pwd -P) || continue
    if ! grep -qs "^worktree=$p\$" "$LAB"/state/*.meta 2>/dev/null; then slot=$p; fi
  done
  [ -n "$slot" ] || { echo "no new slot" >&2; return 1; }
  git -C "$slot" checkout -q -b "fm/$id" origin/main
  printf 'task=%s\nhome=%s\n' "$id" "$LAB" > "$(dirname "$slot")/.fm-slot-owner"
  cat > "$LAB/state/$id.meta" <<EOF
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$slot
branch=fm/$id
project=$PROJ
kind=ship
mode=no-mistakes
spawn_gen=lab-$id
pr=https://github.com/example/repo/pull/7
EOF
  touch "$LAB/state/.last-watcher-beat"
  [ -f "$LAB/data/backlog.md" ] || printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
  tasks-axi add "$id" "lab fixture $id" --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  printf '%s\n' "$slot"
}

# add_foreign <slot> <name> <kind>: a sibling task's copy inside the slot, no record names it.
#   ignored  : clean, but holds an ignored file that exists nowhere else
#   unlanded : clean, but holds a commit on no remote
#   dirty    : tracked change left uncommitted
add_foreign() {
  local slot=$1 name=$2 kind=$3 copy exclude
  copy=$slot/.claude/worktrees/$name
  mkdir -p "$slot/.claude/worktrees"
  git -C "$slot" worktree add -q -b "fm/$name" "$copy" origin/main
  case $kind in
    ignored)
      exclude=$(git -C "$copy" rev-parse --path-format=absolute --git-path info/exclude)
      printf 'unique.dat\n' >> "$exclude"
      printf 'only here\n' > "$copy/unique.dat" ;;
    unlanded)
      printf 'unlanded\n' > "$copy/unlanded.txt"
      git -C "$copy" add unlanded.txt
      git -C "$copy" -c user.email=t@t -c user.name=t commit -qm 'unlanded foreign work' ;;
    dirty)
      printf 'edit\n' >> "$copy/README.md" ;;
  esac
  printf '%s\n' "$copy"
}

# fingerprint <copy>: path, mode, size, mtime of everything + sha256 of every file + git admin files.
fingerprint() {
  local copy=$1 admin f
  admin=$(git -C "$copy" rev-parse --absolute-git-dir)
  (cd "$copy" && LC_ALL=C find . -print0 | LC_ALL=C sort -z | xargs -0 ls -ldn
   LC_ALL=C find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
  (cd "$admin" && for f in HEAD locked gitdir commondir; do
     [ -e "$f" ] && { printf '%s ' "$f"; shasum -a 256 < "$f"; }
   done)
}

# run_td <id> [teardown args...]: run the real teardown inside the lab; prints stdout, stderr, exit code.
run_td() {
  local id=$1 rc=0
  shift
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
      -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" TMUX_TMPDIR="$SOCKDIR" TMUX="$(lab_tmux_env)" TREEHOUSE_ROOT="$LAB/th" \
      NM_HOME="$LAB/nm" PATH="$STUBS:$PATH" \
      "$WT/bin/fm-teardown.sh" "$id" "$@" > "$LAB/out.$id" 2> "$LAB/err.$id" || rc=$?
  echo "--- stdout"; cat "$LAB/out.$id"
  echo "--- stderr"; cat "$LAB/err.$id"
  echo "--- exit code: $rc"
  return 0
}

lease_of() {  # <slot> : the treehouse state entry for the slot
  local slot=$1 st
  st=$(ls "$LAB"/th/.treehouse/*/treehouse-state.json)
  perl -MJSON::PP -e '
    my ($f,$slot)=@ARGV; local $/; open my $h,"<",$f or die; my $j=decode_json(<$h>);
    for my $w (@{$j->{worktrees}}) { (my $p=$w->{path}) =~ s{/+$}{}; if ($p eq $slot) {
      print join(" ", map {"$_=".(defined $w->{$_}?$w->{$_}:"")} grep {/^(name|leased|lease_holder|owner_pid)$/} sort keys %$w), "\n"; exit } }
    print "(slot not in state)\n";' "$st" "$slot"
}

"$@"
