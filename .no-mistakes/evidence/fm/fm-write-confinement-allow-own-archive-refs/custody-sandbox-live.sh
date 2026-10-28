#!/usr/bin/env bash
# Live check: build the real worker write profile (head and base builder) for a
# disposable Firstmate home, then run the documented custody-return git steps
# and adversarial ref writes under /usr/bin/sandbox-exec.
# Usage: custody-sandbox-live.sh <head-builder.py> <base-builder.py>
set -u
HEAD_BUILDER=$1 BASE_BUILDER=$2
LAB=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$LAB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 NM_HOME="$LAB/nm"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
UH="$LAB/user-home"; FMH="$LAB/fmhome"; PRIMARY="$FMH/projects/project"
mkdir -p "$UH/.claude" "$FMH/config" "$FMH/state" "$FMH/data/task-a1" "$NM_HOME/repos"
git init -q -b main "$PRIMARY"; git -C "$PRIMARY" commit -q --allow-empty -m base
git -C "$PRIMARY" worktree add -q -b fm/task-a1 "$LAB/wt/task-a1" main
git -C "$PRIMARY" worktree add -q -b fm/task-b2 "$LAB/wt/task-b2" main
for t in task-a1 task-b2 task-a task-a12; do printf 'kind=ship\n' > "$FMH/state/$t.meta"; done
WT="$LAB/wt/task-a1"; COMMON="$PRIMARY/.git"
git -C "$WT" commit -q --allow-empty -m submitted; S=$(git -C "$WT" rev-parse HEAD)
# A gate repo whose recovery ref holds the pipeline head P (S plus a fix commit).
git clone -q --bare "$PRIMARY" "$LAB/gate.git"
git -C "$WT" commit -q --allow-empty -m pipeline-fix; P=$(git -C "$WT" rev-parse HEAD)
git -C "$WT" push -q "$LAB/gate.git" "$P:refs/no-mistakes/recover/run1"
git -C "$WT" reset -q --hard "$S"; git -C "$WT" reflog expire --expire=now --all; git -C "$WT" gc -q --prune=now
S8=${S:0:8} P8=${P:0:8}
build() { HOME="$UH" python3 "$1" --worktree "$WT" --home "$FMH" --config "$FMH/config" --projects "$FMH/projects" \
  --data "$FMH/data/task-a1" --state "$FMH/state" --task task-a1 --harness claude --profile "$2" \
  --agent-dir "$UH/.claude" --branch fm/task-a1 --claude-session 11111111-2222-4333-8444-555555555555; }
sb() { local prof=$1; shift; HOME="$UH" /usr/bin/sandbox-exec -f "$prof" "$@"; }
step() { local label=$1; shift; local out rc; out=$("$@" 2>&1); rc=$?; printf '%-58s rc=%s %s\n' "$label" "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"; return $rc; }
check() { if eval "$2"; then echo "  PASS: $1"; else echo "  FAIL: $1"; FAILS=$((FAILS+1)); fi; }
FAILS=0
echo "lab=$LAB S=$S P=$P"

for which in base head; do
  echo; echo "=== $which builder: custody route under sandbox-exec ==="
  git -C "$WT" reset -q --hard "$S"
  for r in $(git -C "$WT" for-each-ref --format='%(refname)' refs/heads/archive); do git -C "$WT" update-ref -d "$r"; done
  rm -rf "$COMMON/refs/heads/archive" "$COMMON/logs/refs/heads/archive"
  prof="$LAB/$which.sb"; builder=$BASE_BUILDER; [ $which = head ] && builder=$HEAD_BUILDER
  step "build profile" build "$builder" "$prof"
  step "step 2: git branch archive/task-a1-submitted-$S8 S" sb "$prof" git -C "$WT" branch "archive/task-a1-submitted-$S8" "$S"; c1=$?
  step "step 2: git fetch --no-tags gate recover/run1" sb "$prof" git -C "$WT" fetch --no-tags "$LAB/gate.git" refs/no-mistakes/recover/run1
  fh=$(git -C "$WT" rev-parse -q --verify FETCH_HEAD 2>/dev/null)
  step "step 2: git branch archive/task-a1-pipeline-$P8 P" sb "$prof" git -C "$WT" branch "archive/task-a1-pipeline-$P8" "$P"; c2=$?
  step "step 2: same name again must refuse" sb "$prof" git -C "$WT" branch "archive/task-a1-pipeline-$P8" "$P"; c3=$?
  step "step 4: git reset --keep archive/task-a1-pipeline-$P8" sb "$prof" git -C "$WT" reset --keep "refs/heads/archive/task-a1-pipeline-$P8"; c4=$?
  if [ $which = base ]; then
    check "base refuses own submitted archive (the reported stuck state)" "[ $c1 -ne 0 ]"
    check "base refuses own pipeline archive" "[ $c2 -ne 0 ]"
    continue
  fi
  check "own submitted archive created at S" "[ $c1 -eq 0 ] && [ \"\$(git -C \"$WT\" rev-parse archive/task-a1-submitted-$S8)\" = $S ]"
  check "FETCH_HEAD resolves to P" "[ \"$fh\" = $P ]"
  check "own pipeline archive created at P" "[ $c2 -eq 0 ] && [ \"\$(git -C \"$WT\" rev-parse archive/task-a1-pipeline-$P8)\" = $P ]"
  check "existing archive name refused" "[ $c3 -ne 0 ]"
  check "reset --keep adopts P on fm/task-a1" "[ $c4 -eq 0 ] && [ \"\$(git -C \"$WT\" rev-parse fm/task-a1)\" = $P ]"
  check "archive reflogs written" "[ -s \"$COMMON/logs/refs/heads/archive/task-a1-pipeline-$P8\" ]"

  echo; echo "=== head builder: adversarial writes under sandbox-exec ==="
  b2=$(git -C "$WT" rev-parse fm/task-b2); ph=$(git -C "$PRIMARY" symbolic-ref HEAD)
  for name in archive/task-b2-submitted-0123abcd archive/task-a-submitted-0123abcd archive/task-a12-submitted-0123abcd \
              archive/task-a1-other-0123abcd archive/task-a1-submitted-0123ABCD archive/task-a1-submitted-0123abc \
              archive/task-a1-submitted-0123abcd-x archive/x/task-a1-submitted-0123abcd task-a1-submitted-0123abcd; do
    step "create refs/heads/$name" sb "$prof" git -C "$WT" update-ref "refs/heads/$name" HEAD
    check "refused $name" "! git -C \"$WT\" rev-parse -q --verify refs/heads/$name >/dev/null"
    git -C "$WT" update-ref -d "refs/heads/$name" 2>/dev/null
  done
  step "move another task's branch fm/task-b2" sb "$prof" git -C "$WT" update-ref refs/heads/fm/task-b2 HEAD
  check "fm/task-b2 unchanged" "[ \"\$(git -C \"$WT\" rev-parse fm/task-b2)\" = $b2 ]"
  step "delete another task's branch fm/task-b2" sb "$prof" git -C "$WT" branch -D fm/task-b2
  check "fm/task-b2 still exists" "git -C \"$WT\" rev-parse -q --verify fm/task-b2 >/dev/null"
  step "repoint primary HEAD" sb "$prof" git -C "$PRIMARY" symbolic-ref HEAD refs/heads/fm/task-b2
  check "primary HEAD unchanged" "[ \"\$(git -C \"$PRIMARY\" symbolic-ref HEAD)\" = $ph ]"
  step "plain file in refs/heads/archive/evil" sb "$prof" touch "$COMMON/refs/heads/archive/evil"
  check "refused stray file in archive folder" "[ ! -e \"$COMMON/refs/heads/archive/evil\" ]"
  step "rename refs/heads/archive folder" sb "$prof" mv "$COMMON/refs/heads/archive" "$COMMON/refs/heads/archive2"
  check "archive folder not renamed" "[ -d \"$COMMON/refs/heads/archive\" ] && [ ! -e \"$COMMON/refs/heads/archive2\" ]"
  step "symlink folder refs/heads/archive2 -> fm" sb "$prof" ln -s fm "$COMMON/refs/heads/archive2"
  check "refused symlink in refs/heads" "[ ! -L \"$COMMON/refs/heads/archive2\" ]"
  # Own archive files may hold any bytes, so a symref is writable; teardown must keep it (tests/fm-teardown.test.sh).
  step "own archive as symref to fm/task-b2 (teardown must keep)" sb "$prof" git -C "$WT" symbolic-ref "refs/heads/archive/task-a1-submitted-0a0a0a0a" refs/heads/fm/task-b2
  git -C "$WT" update-ref --no-deref -d refs/heads/archive/task-a1-submitted-0a0a0a0a 2>/dev/null

  echo; echo "=== head builder: own deletes, then archive folders removed while the worker runs ==="
  step "git branch -D own submitted archive" sb "$prof" git -C "$WT" branch -D "archive/task-a1-submitted-$S8"
  step "git branch -D own pipeline archive" sb "$prof" git -C "$WT" branch -D "archive/task-a1-pipeline-$P8"
  check "own archives deleted" "[ -z \"\$(git -C \"$WT\" for-each-ref refs/heads/archive)\" ]"
  step "rmdir empty archive folder (worker)" sb "$prof" rmdir "$COMMON/refs/heads/archive"
  check "worker cannot delete archive folder" "[ -d \"$COMMON/refs/heads/archive\" ]"
  rmdir "$COMMON/refs/heads/archive" "$COMMON/logs/refs/heads/archive"   # unconfined git/teardown does this
  step "git branch own submitted archive after folders gone" sb "$prof" git -C "$WT" branch "archive/task-a1-submitted-$S8" "$S"; c5=$?
  check "folders recreated and own archive created" "[ $c5 -eq 0 ] && [ -d \"$COMMON/logs/refs/heads/archive\" ] && git -C \"$WT\" rev-parse -q --verify archive/task-a1-submitted-$S8 >/dev/null"
  step "after recreate: other task's archive" sb "$prof" git -C "$WT" branch archive/task-b2-submitted-0123abcd
  check "other task's archive still refused" "! git -C \"$WT\" rev-parse -q --verify archive/task-b2-submitted-0123abcd >/dev/null"
  git -C "$WT" update-ref -d "refs/heads/archive/task-a1-submitted-$S8"

  echo; echo "=== head builder: project has a branch named 'archive' ==="
  rm -rf "$COMMON/refs/heads/archive" "$COMMON/logs/refs/heads/archive"
  git -C "$WT" branch archive "$S"
  step "build profile with refs/heads/archive a file" build "$HEAD_BUILDER" "$LAB/file.sb"; c6=$?
  check "builder succeeds" "[ $c6 -eq 0 ]"
  check "branch 'archive' kept" "git -C \"$WT\" rev-parse -q --verify refs/heads/archive >/dev/null"
  git -C "$WT" branch -D archive
  step "own archive name with no grant" sb "$LAB/file.sb" git -C "$WT" branch "archive/task-a1-submitted-$S8" "$S"
  check "own archive refused (no grant in this profile)" "! git -C \"$WT\" rev-parse -q --verify archive/task-a1-submitted-$S8 >/dev/null"
done
echo; echo "FAILS=$FAILS"; [ $FAILS -eq 0 ]
