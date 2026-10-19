# sourced: builds the lab world pieces. LAB must be set.
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
RG=/usr/bin/git
TH=$LAB/th; SLOT=$TH/pool1/1/repo; ORIGIN=$LAB/origin.git
export LAB_CTL=$LAB/ctl LAB_REAL_GIT=$RG
build_slot() {
  mkdir -p $SLOT $TH/pool1/1 $LAB/ctl
  $RG -C $SLOT init -q -b main
  printf '.venv/\nnode_modules/\n*.log\noutbox/\n' > $SLOT/.gitignore
  printf '# lab\n' > $SLOT/README.md
  $RG -C $SLOT add .gitignore README.md && $RG -C $SLOT commit -qm initial
  $RG clone -q --bare $SLOT $ORIGIN
  $RG -C $SLOT remote add origin file://$ORIGIN
  $RG -C $SLOT fetch -q origin
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > $TH/pool1/treehouse-state.json
  mkdir -p $SLOT/scripts/git-stability $SLOT/.venv/bin
  cp $LAB/closeout_pr.py $SLOT/scripts/git-stability/closeout_pr.py
  ln -s /opt/homebrew/bin/python3 $SLOT/.venv/bin/python
  excl=$($RG -C $SLOT rev-parse --path-format=absolute --git-path info/exclude)
  printf 'scripts/\n.venv/\n' >> "$excl"
}
# make_copy <name> <landed|pushed|unpushed> : nested worktree with one commit
make_copy() {
  local n=$1 how=$2 c=$SLOT/.claude/worktrees/$1
  $RG -C $SLOT fetch -q origin
  $RG -C $SLOT worktree add -q -b fm/$n $c origin/main
  printf '%s\n' "$n" > $c/$n.txt
  $RG -C $c add $n.txt && $RG -C $c commit -qm "$n"
  case $how in
    landed)   $RG -C $c push -q origin fm/$n && $RG -C $c push -q origin fm/$n:main ;;
    pushed)   $RG -C $c push -q origin fm/$n ;;
    unpushed) : ;;
  esac
}
# ign <name> <log-kib> <blob-mib>: unique ignored log (needs preserving) + allow-listed blob
ign() {
  local c=$SLOT/.claude/worktrees/$1
  [ "${2:-0}" = 0 ] || { mkdir -p $c/outbox; head -c $(( $2 * 1024 )) /dev/urandom > $c/outbox/channel.log; }
  [ "${3:-0}" = 0 ] || { mkdir -p $c/node_modules; dd if=/dev/urandom of=$c/node_modules/blob.bin bs=1048576 count=$3 2>/dev/null; }
}
# lock <name> <pid> [backdate]
lock() {
  local c=$SLOT/.claude/worktrees/$1
  $RG -C $SLOT worktree lock --reason "vernant-session-active owner=launcher:$2 launcher=$2" $c
  if [ -n "${3:-}" ]; then touch -t 202001010000 "$($RG -C $c rev-parse --absolute-git-dir)/locked"; fi
}
dead_pid() { sleep 0 & local p=$!; wait $p; echo $p; }
sweep() {  # sweep [args]: runs the real script against the lab
  ( cd /Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M59VR0KXA291XPS5P8FH76XM && \
    env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$LAB/bin:$PATH" FM_HOME=$LAB FM_COPY_SWEEP_TREEHOUSE_ROOT=$TH LAB_CTL=$LAB/ctl LAB_REAL_GIT=$RG \
    bin/fm-copy-sweep.sh "$@" )
}
