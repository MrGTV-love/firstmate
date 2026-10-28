#!/usr/bin/env bash
# Live probe: does the head profile's own-archive grant reach any name that is
# not a case-variant of this task's own archive name? Usage: case-probe-live.sh <head-builder.py>
set -u
LAB=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$LAB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 NM_HOME="$LAB/nm" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
UH="$LAB/u"; FMH="$LAB/fm"; PRIMARY="$FMH/projects/project"; mkdir -p "$UH/.claude" "$FMH/config" "$FMH/state" "$FMH/data/task-a1"
git init -q -b main "$PRIMARY"; git -C "$PRIMARY" commit -q --allow-empty -m base
git -C "$PRIMARY" worktree add -q -b fm/task-a1 "$LAB/wt" main
for t in task-a1 task-b2; do printf 'kind=ship\n' > "$FMH/state/$t.meta"; done
HOME="$UH" python3 "$1" --worktree "$LAB/wt" --home "$FMH" --config "$FMH/config" --projects "$FMH/projects" --data "$FMH/data/task-a1" \
  --state "$FMH/state" --task task-a1 --harness claude --profile "$LAB/p.sb" --agent-dir "$UH/.claude" --branch fm/task-a1 \
  --claude-session 11111111-2222-4333-8444-555555555555 || exit 1
for name in archive/task-a1-submitted-0123ABCD archive/TASK-A1-submitted-0123abcd archive/task-a1-SUBMITTED-0123abcd \
            archive/TASK-B2-submitted-0123abcd archive/task-b2-submitted-0123ABCD ARCHIVE/task-a1-submitted-0123abcd; do
  HOME="$UH" /usr/bin/sandbox-exec -f "$LAB/p.sb" git -C "$LAB/wt" update-ref "refs/heads/$name" HEAD 2>/dev/null; rc=$?
  ls_name=$(ls "$PRIMARY/.git/refs/heads/archive" 2>/dev/null | tr '\n' ' ')
  printf '%-40s confined rc=%s  archive dir: %s\n' "$name" "$rc" "$ls_name"
  git -C "$LAB/wt" update-ref -d "refs/heads/$name" 2>/dev/null
done
