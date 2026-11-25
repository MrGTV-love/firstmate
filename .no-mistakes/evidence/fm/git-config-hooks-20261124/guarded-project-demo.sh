#!/usr/bin/env bash
# Manual demo: a project that guards its hooks path, driven with the task hook
# carriers that bin/fm-git-strip-ai-trailers.sh installs (install + rows).
# Usage: guarded-project-demo.sh <firstmate-root>
set -u
ROOT=$1
T=$(mktemp -d /tmp/fm-guarded-demo.XXXXXX)
trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=w GIT_AUTHOR_EMAIL=w@x.invalid GIT_COMMITTER_NAME=w GIT_COMMITTER_EMAIL=w@x.invalid
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS
git init -q --bare "$T/origin.git"
git init -q -b main "$T/wt"; cd "$T/wt"
git remote add origin "$T/origin.git"
mkdir .githooks
for h in pre-commit reference-transaction pre-push; do
  printf '#!/bin/sh\necho repo:%s >> "%s/repohooks.log"\n' "$h" "$T" > .githooks/$h; chmod +x .githooks/$h
done
git config core.hooksPath .githooks
git add .githooks && git commit -q -m init
HOOKS="$T/task.git-hooks"
"$ROOT/bin/fm-git-strip-ai-trailers.sh" install "$HOOKS" "$T/wt" 0
ROWS=$("$ROOT/bin/fm-git-strip-ai-trailers.sh" rows "$HOOKS" 0)
# The project's hooks-path drift guard: deny raw git when the effective
# core.hooksPath is not the project's own .githooks.
guard() { local p; p=$(git config --get core.hooksPath); if [ "$p" = .githooks ]; then echo "guard: allow (core.hooksPath=$p)"; else echo "guard: DENY third-party hooks dir (core.hooksPath=$p)"; fi; }
cred=$(printf 'AKIA%s' ZZZZZZZZZZZZZZZZ)
try() {  # <label>
  echo "== $1"
  guard
  for ev in pre-commit commit-msg pre-push reference-transaction; do echo "git hook list $ev: $(git hook list $ev 2>&1 | tr '\n' ' ')"; done
  : > "$T/repohooks.log"
  printf '%s\n' "$cred" > leak; git add leak
  if git commit -q -m leak 2>/dev/null; then echo "credential commit: LANDED"; git reset -q --hard HEAD~1; else echo "credential commit: refused"; git reset -q --hard HEAD; git clean -qfd; fi
  printf '%s\n' "$cred" > leak; git add leak
  if git -c core.hooksPath=/dev/null commit -q -m leak2 2>/dev/null; then echo "credential commit with -c core.hooksPath=/dev/null: LANDED"; git reset -q --hard HEAD~1; else echo "credential commit with -c core.hooksPath=/dev/null: refused"; git reset -q --hard HEAD; git clean -qfd; fi
  echo x >> clean; git add clean
  git commit -q -m clean -m 'Co-Authored-By: Claude <noreply@anthropic.com>' && echo "clean commit: landed"
  echo "AI trailers in commit body: $(git log -1 --format=%B | grep -ci co-authored-by)"
  git push -q origin HEAD:refs/heads/demo 2>/dev/null && echo "clean push: landed"
  echo "repository's own hooks that ran: $(sort -u "$T/repohooks.log" | tr '\n' ' ')"
}
( export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$HOOKS"; try "LEGACY carrier (numbered GIT_CONFIG core.hooksPath)" )
( export GIT_CONFIG_PARAMETERS="$ROWS"; try "CONFIG carrier (hook.<name> rows in GIT_CONFIG_PARAMETERS)" )
echo "== teardown: task hooks dir removed, rows still in env"
chmod -R u+w "$HOOKS"; rm -rf "$HOOKS"
( export GIT_CONFIG_PARAMETERS="$ROWS"; printf '%s\n' "$cred" > leak; git add leak
  if git commit -q -m dangling 2>/dev/null; then echo "commit with dangling rows: landed (rows run no hook, like a dangling legacy core.hooksPath)"; else echo "commit with dangling rows: refused"; fi )
