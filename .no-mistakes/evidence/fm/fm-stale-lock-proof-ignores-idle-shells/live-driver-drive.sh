#!/usr/bin/env bash
# Live driver: real bin/fm-fleet-sync.sh against a disposable lab home.
# Usage: drive.sh <bin-root> <lab> <scenario>
set -u
ROOTDIR=$1 LAB=$2 SC=$3
name="demo-$SC"
work="$LAB/work-$name"; remote="$LAB/remotes/$name.git"; clone="$LAB/projects/$name"
mkdir -p "$LAB/remotes"
q() { git "$@" >/dev/null 2>&1; }
git init -q "$work"; git -C "$work" symbolic-ref HEAD refs/heads/main
echo v0 > "$work/f"; q -C "$work" add f; q -C "$work" -c user.name=t -c user.email=t@t commit -m C0
git clone -q --bare "$work" "$remote"
q -C "$work" remote add origin "file://$remote"
q -C "$work" push -u origin main; q -C "$work" push origin main:refs/heads/feature
git clone -q "file://$remote" "$clone"
q -C "$clone" branch feature origin/feature
echo v1 > "$work/f"; q -C "$work" -c user.name=t -c user.email=t@t commit -am C1
q -C "$work" push origin main; q -C "$work" push origin --delete feature
q -C "$clone" pack-refs --all
lock="$clone/.git/packed-refs.lock"
echo "== scenario $SC  (bin root: $ROOTDIR)"
echo "clone: $clone"
echo "clone HEAD before: $(git -C "$clone" rev-parse --short HEAD)   origin main: $(git -C "$remote" rev-parse --short main)"
TM=(env TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab)
cleanup_pids=()
case "$SC" in
  idle-shells|idle-shells-fresh|argv-mentions-git)
    : > "$lock"
    if [ "$SC" != idle-shells-fresh ]; then touch -t "$(date -v-150M +%Y%m%d%H%M.%S)" "$lock"; fi
    # Two interactive zsh pane shells (like herdr panes) with cwd in the clone,
    # each running a long-lived child named "treehouse" (a tiny pause() binary).
    : # "$LAB/fakebin/treehouse" is a prebuilt pause() binary stand-in
    for p in pane1 pane2; do
      "${TM[@]}" new-session -d -s "$SC-$p" -x 120 -y 30 -c "$clone" "zsh -f -i"
      "${TM[@]}" send-keys -t "$SC-$p" "$LAB/fakebin/treehouse get" Enter
    done
    if [ "$SC" = argv-mentions-git ]; then
      (cd "$clone" && exec bash -c 'msg="git fetch origin --prune"; read -r _' < <(sleep 600)) &
      cleanup_pids+=($!)
    fi
    want=4; [ "$SC" = argv-mentions-git ] && want=5
    for i in $(seq 1 100); do [ "$(lsof -t -- "$clone" 2>/dev/null | wc -l)" -ge "$want" ] && break; sleep 0.2; done
    ;;
  live-git-cwd)
    : > "$lock"; touch -t "$(date -v-150M +%Y%m%d%H%M.%S)" "$lock"
    # A real Git process idling with its cwd in the clone.
    (cd "$clone" && exec git cat-file --batch < <(sleep 600) > /dev/null) &
    cleanup_pids+=($!); sleep 1
    ;;
  lock-held-by-shell)
    : > "$lock"; touch -t "$(date -v-150M +%Y%m%d%H%M.%S)" "$lock"
    # A non-Git process that holds the lock file itself open, cwd elsewhere.
    (cd / && exec zsh -f -c "exec 8<'$lock'; sleep 600") &
    cleanup_pids+=($!); sleep 1
    ;;
  prepared-git-txn)
    q -C "$clone" branch fm-lock-held; q -C "$clone" pack-refs --all
    mkfifo "$LAB/txn-in-$SC"; exec 7<> "$LAB/txn-in-$SC"
    (cd "$clone" && exec git update-ref --stdin < "$LAB/txn-in-$SC" > "$LAB/txn-out-$SC" 2>&1 7>&-) &
    cleanup_pids+=($!)
    printf 'start\ndelete refs/heads/fm-lock-held\nprepare\n' >&7
    for i in $(seq 1 100); do grep -q 'prepare: ok' "$LAB/txn-out-$SC" 2>/dev/null && break; sleep 0.2; done
    touch -t "$(date -v-150M +%Y%m%d%H%M.%S)" "$lock"
    ;;
esac
echo "--- lock file: $(ls -l "$lock" | awk '{print $5" bytes, mtime "$6" "$7" "$8}')"
echo "--- lsof on lock file (empty = nobody has it open):"
lsof -- "$lock" 2>&1 | sed 's/^/    /'
echo "--- processes with cwd/fd in clone dir:"
lsof +c 0 -- "$clone" 2>&1 | awk '{print "    "$1, $2, $4}'
echo "--- run: FM_HOME=\$LAB $ROOTDIR/bin/fm-fleet-sync.sh $name"
start=$(date +%s)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" "$ROOTDIR/bin/fm-fleet-sync.sh" "$name" > "$LAB/out-$SC" 2> "$LAB/err-$SC"
rc=$?
echo "exit=$rc  elapsed=$(( $(date +%s) - start ))s"
echo "--- stdout:"; sed 's/^/    /' "$LAB/out-$SC"
echo "--- stderr (lock lines):"; grep -i "lock\|fetch" "$LAB/err-$SC" | sed 's/^/    /'
echo "--- after: lock present? $([ -e "$lock" ] && echo YES || echo no)   clone HEAD: $(git -C "$clone" rev-parse --short HEAD)   origin main: $(git -C "$remote" rev-parse --short main)"
if [ "$SC" = prepared-git-txn ]; then printf 'abort\n' >&7; sleep 0.5; echo "--- txn: $(tr '\n' ' ' < "$LAB/txn-out-$SC")"; exec 7>&-; fi
for p in "${cleanup_pids[@]+"${cleanup_pids[@]}"}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done
for p in pane1 pane2; do "${TM[@]}" kill-session -t "$SC-$p" 2>/dev/null; done
true
