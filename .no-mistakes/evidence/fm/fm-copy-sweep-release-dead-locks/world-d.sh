#!/usr/bin/env bash
# World D: guards with the real driver. proc: a process has its cwd inside; dirty: an untracked file;
# uniq: a unique non-generated ignored file (the real driver plans archive_then_retain_tree).
set -u
WT=$1 LAB=$2; . "$(dirname "$0")/lab-lib.sh"
new_world d
DEAD=$(dead_pid)
for n in proc dirty uniq; do add_copy "$n" merged "$DEAD"; done
git -C "$SLOT" fetch -q origin
(cd "$(cp_of proc)" && exec sleep 3600) & INSIDE=$!
printf 'scratch\n' > "$(cp_of dirty)/untracked.txt"
mkdir -p "$(cp_of uniq)/.claude/notes"; printf 'a unique note\n' > "$(cp_of uniq)/.claude/notes/keep.md"
printf '%s\n' .afkx/ >> "$SLOT/.git/info/exclude"; mkdir -p "$(cp_of uniq)/.afkx/raw-logs"; printf 'outbox\n' > "$(cp_of uniq)/.afkx/raw-logs/channel-outbox.jsonl"
echo "===== check (the watcher's entry)"; sweep check; echo "exit=$?"; echo "worktrees still registered: $(git -C "$SLOT" worktree list | grep -c worktrees/)"
for r in 1 2; do echo; echo "===== RUN $r: --apply"; sweep --apply; echo "exit=$?"
  echo "worktrees still registered: $(git -C "$SLOT" worktree list | grep -c worktrees/)   preserved files: $(find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -type f 2>/dev/null | wc -l | tr -d ' ')   receipts: $(ls "$HOMED/data/copy-sweep/retained" 2>/dev/null | wc -l | tr -d ' ')"; done
echo "uniq still holds its outbox: $(cat "$(cp_of uniq)/.afkx/raw-logs/channel-outbox.jsonl")"
kill "$INSIDE"
