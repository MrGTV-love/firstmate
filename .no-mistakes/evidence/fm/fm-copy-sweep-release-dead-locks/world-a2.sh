#!/usr/bin/env bash
# World A2: real-driver refusals walked first use no slot (limit 2); git-call log shows who unlocks/removes.
set -u
WT=$1 LAB=$2; . "$(dirname "$0")/lab-lib.sh"
new_world a2
DEAD=$(dead_pid)
for i in 1 2 3; do add_copy "c$i" merged "$DEAD"; done
for i in 1 2 3; do add_copy "z-refused$i" pushed "$DEAD"; done
git -C "$SLOT" fetch -q origin
REALGIT=$(command -v git); mkdir -p "$W/shim"
cat > "$W/shim/git" <<SH
#!/bin/bash
printf '%s\t%s\n' "\$(ps -o comm= -p \$PPID | sed 's|.*/||')" "\$*" >> "$W/git-calls.log"
exec "$REALGIT" "\$@"
SH
chmod +x "$W/shim/git"
echo "===== RUN 1: --apply, FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=2 (walk order: z-refused3..1 first, then c3..c1)"
PATH="$W/shim:$PATH" FM_COPY_SWEEP_DRIVER_RELEASE_LIMIT=2 sweep --apply; echo "exit=$?"; state
echo; echo "===== git calls that unlock, lock or remove a worktree, by calling process:"
grep -E 'worktree (unlock|lock|remove)' "$W/git-calls.log" | sed "s|$LAB|\$LAB|g"
echo "===== any --force anywhere: $(grep -c -- '--force\| -f ' "$W/git-calls.log")"
