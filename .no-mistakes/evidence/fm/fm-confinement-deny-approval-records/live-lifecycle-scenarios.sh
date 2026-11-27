#!/usr/bin/env bash
# Independent live driver: real bin/fm-write-confinement.py (base and head) and
# real /usr/bin/sandbox-exec on a disposable fixture home and repository.
# Usage: live-lifecycle-scenarios.sh <worktree-root> <base-commit>
set -u
ROOT=$1
BASE=$2
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-lifecycle.XXXXXX")
S=$(cd "$S" && pwd -P)
trap 'chmod -R u+w "$S" 2>/dev/null; rm -rf "$S"' EXIT
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export OMP_PROFILE='' PI_PROFILE='' PI_CONFIG_DIR=.omp
git -C "$ROOT" show "$BASE:bin/fm-write-confinement.py" > "$S/base-builder.py"
HEAD_BUILDER="$ROOT/bin/fm-write-confinement.py"
SESSION=11111111-2222-4333-8444-555555555555

mkfixture() { # <name> <with-module:0|1>
  local f="$S/$1"
  mkdir -p "$f/home/state" "$f/home/data/task" "$f/home/config" "$f/home/projects" "$f/nm/repos" "$f/user-home/.claude" "$f/remote"
  git init -q -b main "$f/home/projects/proj"
  echo hi > "$f/home/projects/proj/README.md"
  if [ "$2" = 1 ]; then mkdir -p "$f/home/projects/proj/scripts/git_management"; echo '# vernant' > "$f/home/projects/proj/scripts/git_management/worktree_lifecycle.py"; fi
  git -C "$f/home/projects/proj" add -A && git -C "$f/home/projects/proj" commit -qm init
  git init -q --bare "$f/remote/origin.git"
  git -C "$f/home/projects/proj" remote add origin "$f/remote/origin.git"
  git -C "$f/home/projects/proj" push -q origin main
  git -C "$f/home/projects/proj" worktree add -q -b fm/task "$f/wt"
  printf 'spawn_gen=live\nwindow=fmtest:fm-task\nworktree=%s\nproject=fmtest\n' "$f/wt" > "$f/home/state/task.meta"
  : > "$f/home/state/task.status"
  echo "$f"
}
build() { # <fixture> <base|head> <profile> [extra args...]
  local f=$1 which=$2 profile=$3; shift 3
  local builder=$HEAD_BUILDER proj=(--project "$f/home/projects/proj")
  [ "$which" = base ] && { builder=$S/base-builder.py; proj=(); }
  [ "${NO_PROJECT:-0}" = 1 ] && proj=()
  HOME="$f/user-home" NM_HOME="$f/nm" python3 "$builder" --worktree "$f/wt" ${proj[@]+"${proj[@]}"} --home "$f/home" \
    --config "$f/home/config" --projects "$f/home/projects" --data "$f/home/data/task" --state "$f/home/state" \
    --task task --branch fm/task --harness claude --claude-session "$SESSION" --profile "$profile" "$@"
}
confined() { # <profile> <fixture> <shell snippet>
  ( cd "$2/wt" && HOME="$2/user-home" /usr/bin/sandbox-exec -f "$1" /bin/sh -c "$3" )
}
try() { # <label> <profile> <fixture> <snippet>
  local out rc
  out=$(confined "$2" "$3" "$4" 2>&1); rc=$?
  printf '  %-52s exit=%s %s\n' "$1" "$rc" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)"
}

snap() { ( cd "$L" 2>/dev/null && find owned-paths-approvals captain-drop \( -type f -o -type l -o -type d \) -print -exec cat {} \; 2>/dev/null | shasum | cut -c1-12 ) ; }
reset() {
  [ -d "$L" ] || { [ -d "$f/wt/old-lifecycle" ] && mv "$f/wt/old-lifecycle" "$L"; }
  mkdir -p "$L"; rm -rf "$A" "$D" "$f/wt/old-a" "$f/wt/prep" "$f/wt/prep2"
  mkdir -p "$A" "$D/other-task"; echo supervisor > "$A/seed.json"; echo supervisor > "$D/other-task/record.json"
  echo forged > "$f/wt/forged.json"
}
case_() { # <label> <snippet> [pre-hook]
  reset; [ -z "${3:-}" ] || eval "$3"
  local before after; before=$(snap)
  local out rc; out=$(confined "$f/p.sb" "$f" "$2" 2>&1); rc=$?
  after=$(snap); local ch=no; [ "$before" = "$after" ] && [ -d "$L" ] || ch=YES
  printf '  %-46s exit=%s records-changed=%-3s %s\n' "$1" "$rc" "$ch" "$(printf '%s' "$out" | tr '\n' ' ' | sed "s#$S#<S>#g" | cut -c1-150)"
}
fresh() { # <tag> -> sets f, C, L, A, D, G and builds profile
  f=$(mkfixture "$1" 1); C="$f/home/projects/proj/.git"; L="$C/vernant-worktree-lifecycle"; A="$L/owned-paths-approvals"; D="$L/captain-drop"
  [ "$which" = base ] && mkdir -p "$L"   # base never creates it; give the worker the same starting state
  build "$f" "$which" "$f/p.sb" 2>"$f/build.err" || { echo "  build: REFUSED $(cat "$f/build.err")"; return 1; }
  G=$(git -C "$f/wt" rev-parse --absolute-git-dir)
}
for which in base head; do
  echo "=== $which builder: confined worker vs lifecycle records (fixture with Vernant module) ==="
  fresh "lc-$which" || continue
  echo "  build ok; lifecycle folder present after build: $( [ -d "$L" ] && echo yes || echo no )"
  case_ "approvals: create own approval"            "echo forged > '$A/task.json'"
  case_ "approvals: overwrite seeded record"        "echo forged > '$A/seed.json'"
  case_ "approvals: append seeded record"           "echo forged >> '$A/seed.json'"
  case_ "approvals: delete seeded record"           "rm '$A/seed.json'"
  case_ "approvals: rename forged file in"          "mv '$f/wt/forged.json' '$A/moved.json'"
  case_ "approvals: hard link forged file in"       "ln '$f/wt/forged.json' '$A/link.json'"
  case_ "approvals: symlink in"                     "ln -s '$f/wt/forged.json' '$A/sym.json'"
  case_ "captain-drop: <task>/record.json"          "mkdir -p '$D/task' && echo forged > '$D/task/record.json'"
  case_ "captain-drop: <task>/captain-words.txt"    "mkdir -p '$D/task' && echo yes > '$D/task/captain-words.txt'"
  case_ "captain-drop: overwrite other record"      "echo forged > '$D/other-task/record.json'"
  case_ "captain-drop: delete other record"         "rm '$D/other-task/record.json'"
  case_ "swap prepared folder onto approvals"       "mkdir -p prep && echo forged > prep/task.json && mv '$A' '$f/wt/old-a' && mv prep '$A'"
  case_ "rename whole lifecycle folder away"        "mv '$L' '$f/wt/old-lifecycle'"
  case_ "approvals absent: mkdir folder itself"     "mkdir '$A'"                                         "rm -rf '$A'"
  case_ "approvals absent: rename prepared folder"  "mkdir -p prep2 && echo forged > prep2/task.json && mv prep2 '$A'" "rm -rf '$A'"
  case_ "captain-drop absent: mkdir -p task folder" "mkdir -p '$D/task' && echo f > '$D/task/record.json'" "rm -rf '$D'"
  echo "  --- sibling lifecycle paths (must stay writable; records must not change) ---"
  case_ "sibling: slot manifest + retired receipt"  "mkdir -p '$L/retired' && echo m > '$L/slot.json.tmp' && mv '$L/slot.json.tmp' '$L/slot.json' && echo r > '$L/retired/slot.json' && cat '$A/seed.json'" 
  case_ "sibling: python mkdir(parents,exist_ok)"   "python3 -c \"import pathlib; pathlib.Path('$L').mkdir(parents=True, exist_ok=True); print('mkdir-ok')\""
  case_ "read a record (reads stay open)"           "cat '$A/seed.json' '$D/other-task/record.json'"
  echo "  --- own .git / commondir ---"
  try "own .git: append"           "$f/p.sb" "$f" "echo x >> .git"
  try "own commondir: overwrite"   "$f/p.sb" "$f" "echo /tmp/fake > '$G/commondir'"
  echo "  .git now: $(sed "s#$S#<S>#g" "$f/wt/.git" | tr '\n' ' ') commondir now: $(cat "$G/commondir")"
  echo "  --- ordinary git work (fresh fixture) ---"
  fresh "git-$which" || continue
  try "git status/add/commit"              "$f/p.sb" "$f" "git status --short >/dev/null && echo w > work.txt && git add work.txt && git commit -qm work && git log --oneline -1"
  try "git branch --list / show-current"   "$f/p.sb" "$f" "git branch --list | tr '\n' ' '; git branch --show-current"
  try "git checkout -B own branch"         "$f/p.sb" "$f" "git checkout -q -B fm/task && echo ok"
  try "git fetch origin"                   "$f/p.sb" "$f" "git -c fetch.prune=false fetch -q origin && echo fetched"
  try "git worktree add other path"        "$f/p.sb" "$f" "git worktree add -q --detach '$f/home/data/task/extra-wt' && echo added"
  try "git gc"                             "$f/p.sb" "$f" "git gc -q 2>&1 | sed 's#$S#<S>#g'; echo gc-exit=\${PIPESTATUS:-?}; git status --short | head -1; echo after-gc-ok"
  echo "  --- unconfined supervisor control (no profile) ---"
  reset; out=$( (echo supervisor > "$A/task.json" && mkdir -p "$D/task" && echo s > "$D/task/record.json" && echo s > "$D/task/captain-words.txt" && echo wrote) 2>&1); echo "  supervisor unconfined approve+drop write: $out"
  echo "  --- folder swaps that would plant a forged .git / commondir (fresh fixture each) ---"
  fresh "sw1-$which" && { try "swap worktree folder" "$f/p.sb" "$f" "mkdir -p '$f/home/data/task/prep' && printf 'gitdir: /tmp/fake\n' > '$f/home/data/task/prep/.git' && mv '$f/wt' '$f/home/data/task/old' && mv '$f/home/data/task/prep' '$f/wt' && echo swapped"; echo "    .git now: $(sed "s#$S#<S>#g" "$f/wt/.git" 2>/dev/null)"; }
  fresh "sw2-$which" && { try "swap gitdir folder" "$f/p.sb" "$f" "mkdir -p '$f/home/data/task/prepg' && echo /tmp/fake > '$f/home/data/task/prepg/commondir' && mv '$G' '$f/home/data/task/oldg' && mv '$f/home/data/task/prepg' '$G' && echo swapped"; echo "    commondir now: $(cat "$G/commondir" 2>/dev/null)"; }
done

echo "=== project without the Vernant module (head builder) ==="
f=$(mkfixture plain 0)
build "$f" head "$f/p.sb" && echo "  build: ok; lifecycle folder: $( [ -e "$f/home/projects/proj/.git/vernant-worktree-lifecycle" ] && echo present || echo absent )"
try "worker commit in plain project" "$f/p.sb" "$f" "echo w > w.txt && git add w.txt && git commit -qm w && echo committed"

echo "=== pre-build repoint and missing --project (head vs base builder) ==="
for which in base head; do
  f=$(mkfixture "rp-$which" 1)
  git init -q "$f/fake"; git -C "$f/fake" commit -q --allow-empty -m fake
  mkdir -p "$f/fake/.git/worktrees/wt"; cp "$(git -C "$f/wt" rev-parse --absolute-git-dir)"/{HEAD,index} "$f/fake/.git/worktrees/wt/" 2>/dev/null
  echo "$f/fake/.git" > "$f/fake/.git/worktrees/wt/commondir"; echo "$f/wt/.git" > "$f/fake/.git/worktrees/wt/gitdir"
  git -C "$f/fake" update-ref refs/heads/fm/task HEAD
  printf 'ref: refs/heads/fm/task\n' > "$f/fake/.git/worktrees/wt/HEAD"
  cp "$f/wt/.git" "$f/wt/.git.real"
  printf 'gitdir: %s\n' "$f/fake/.git/worktrees/wt" > "$f/wt/.git"
  if build "$f" "$which" "$f/p.sb" 2>"$f/err"; then echo "  $which: repointed .git -> BUILT profile (protects $(git -C "$f/wt" rev-parse --git-common-dir))"; else echo "  $which: repointed .git -> REFUSED: $(cat "$f/err")"; fi
  echo "  profile published: $( [ -e "$f/p.sb" ] && echo yes || echo no )"
  cp "$f/wt/.git.real" "$f/wt/.git"; rm -f "$f/p.sb"
  G=$(git -C "$f/wt" rev-parse --absolute-git-dir); cp "$G/commondir" "$f/cd.real"; echo "$f/fake/.git" > "$G/commondir"
  if build "$f" "$which" "$f/p.sb" 2>"$f/err"; then echo "  $which: repointed commondir -> BUILT profile"; else echo "  $which: repointed commondir -> REFUSED: $(cat "$f/err")"; fi
  cp "$f/cd.real" "$G/commondir"; rm -f "$f/p.sb"
  ln "$G/commondir" "$f/home/data/task/commondir-alias"
  if build "$f" "$which" "$f/p.sb" 2>"$f/err"; then echo "  $which: hard-linked commondir -> BUILT profile"; else echo "  $which: hard-linked commondir -> REFUSED: $(cat "$f/err")"; fi
  rm -f "$f/home/data/task/commondir-alias" "$f/p.sb"
  if [ "$which" = head ]; then
    if NO_PROJECT=1 build "$f" head "$f/p.sb" 2>"$f/err"; then echo "  head: no --project -> BUILT profile"; else echo "  head: no --project -> REFUSED: $(cat "$f/err")"; fi
    echo "  profile published: $( [ -e "$f/p.sb" ] && echo yes || echo no )"
    if build "$f" head "$f/p.sb" 2>"$f/err"; then echo "  head: restored fixture -> BUILT profile"; else echo "  head: restored -> REFUSED: $(cat "$f/err")"; fi
  fi
done
