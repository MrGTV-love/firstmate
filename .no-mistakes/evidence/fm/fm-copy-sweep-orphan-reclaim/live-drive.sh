#!/usr/bin/env bash
# Live drive of bin/fm-copy-sweep.sh in disposable lab homes.
# Real tools only (lsof, ps, git, du, cp, python3). No PATH shim unless a scenario
# says it injects a fault. The only stand-in is a python closeout driver, because
# Vernant's real driver is out of scope; it models the interface the sweep calls.
#   usage: live-drive.sh <scenario>...
set -u
REPO=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M6BSCW898RTPSF34A73QBC6S
SWEEP=$REPO/bin/fm-copy-sweep.sh
FAILS=0
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=lab GIT_COMMITTER_EMAIL=lab@example.invalid
unset GIT_DIR GIT_WORK_TREE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
PY=$(python3 -c 'import sys; print(sys.executable)')

ok() { printf 'PASS  %s\n' "$*"; }
no() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
eq() { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else no "$1: want [$2] got [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) no "$1: missing [$3]";; esac; }
hasnt() { case "$2" in *"$3"*) no "$1: found [$3]";; *) ok "$1";; esac; }
present() { if [ -e "$2" ] || [ -L "$2" ]; then ok "$1"; else no "$1: gone $2"; fi; }
absent() { if [ -e "$2" ] || [ -L "$2" ]; then no "$1: still $2"; else ok "$1"; fi; }

KIDS=()
lab_up() {  # sets FM_HOME, TMUX_TMPDIR, WORK, CLONE, TEARDOWN
  local err
  err=$(mktemp); eval "$("$REPO/bin/fm-lab-home.sh" env 2>"$err")"
  TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$err"); rm -f "$err"
  export FM_HOME TMUX_TMPDIR
  WORK=$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-work.XXXXXX")" && pwd -P)
  mkdir -p "$WORK/no-pool" "$FM_HOME/state" "$FM_HOME/config" "$FM_HOME/data" "$FM_HOME/projects"
  export FM_COPY_SWEEP_TREEHOUSE_ROOT=$WORK/no-pool
  unset FM_TEARDOWN_VERNANT_PYTHON
  export GIT_TRACE=$WORK/git-trace.log
  OUT= ; RC=0
  printf 'lab FM_HOME=%s\n' "$FM_HOME"
}
lab_down() {
  local k
  for k in "${KIDS[@]:-}"; do [ -z "$k" ] || kill "$k" 2>/dev/null; done
  KIDS=()
  chmod -R u+rwx "$FM_HOME" "$WORK" 2>/dev/null
  eval "$TEARDOWN" && rm -rf "$WORK"
  [ ! -e "$FM_HOME" ] && ok 'lab removed'
}

# <clone>: a project with a bare local origin. Ignored paths come from <ignore>.
make_project() {  # <clone> <ignore-lines>
  local clone=$1
  mkdir -p "$clone"; git -C "$clone" init -q -b main
  printf 'base\n' > "$clone/base.txt"
  printf '%b' "$2" > "$clone/.gitignore"
  git -C "$clone" add -A; git -C "$clone" commit -qm init
  git init -q --bare -b main "$WORK/$(basename "$(dirname "$clone")")-$(basename "$clone")-origin.git"
  git -C "$clone" remote add origin "$WORK/$(basename "$(dirname "$clone")")-$(basename "$clone")-origin.git"
  git -C "$clone" push -q -u origin main
  git -C "$clone" fetch -q origin
  git -C "$clone" remote set-head origin main
}

install_driver() {  # <clone>: the driver at the real path, the real python at the real venv path
  local clone=$1
  printf '.venv/\nscripts/\n' >> "$(git -C "$clone" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$clone/scripts/git-stability" "$clone/.venv/bin"
  ln -s "$PY" "$clone/.venv/bin/python"
  cat > "$clone/scripts/git-stability/closeout_pr.py" <<'DRIVER'
import json, os, subprocess, sys
copy = sys.argv[sys.argv.index("--cleanup-worktree") + 1]
execute = "--execute-cleanup" in sys.argv
name = os.path.basename(copy)
with open(os.path.join(os.getcwd(), "driver-calls.log"), "a") as log:
    log.write(f"{name} execute={execute}\n")
if name.startswith("stale"):
    print(json.dumps({"allowed": False, "reason": "verification_stale_or_uncovered_paths"}))
    sys.exit(3)
if name.startswith("retain"):
    print(json.dumps({"allowed": True, "ignored_payload_disposition": "archive_then_retain_tree"}))
    sys.exit(0)
if not execute:
    print(json.dumps({"allowed": True, "ignored_payload_disposition": "none"}))
    sys.exit(0)
subprocess.run(["git", "worktree", "unlock", copy], check=True)
subprocess.run(["git", "worktree", "remove", copy], check=True)
print(json.dumps({"allowed": True, "released": True}))
DRIVER
  printf 'driver-calls.log\n' >> "$(git -C "$clone" rev-parse --path-format=absolute --git-path info/exclude)"
}

# A lock in Vernant's format naming a process that really ran and really exited.
lock_gone() {  # <clone> <copy>
  local pid
  sleep 0.05 & pid=$!; wait "$pid"
  git -C "$1" worktree lock --reason "vernant-session-active owner=launcher:$pid launcher=$pid" "$2"
}

# Builds fm/squashed: two commits, squash-merged into main and pushed. Sets TIP, FORK.
make_squashed() {  # <clone>
  local clone=$1 src=$1/.claude/worktrees/src
  FORK=$(git -C "$clone" rev-parse HEAD)
  git -C "$clone" worktree add -qb fm/squashed "$src"
  printf 'first\n' > "$src/feature.txt"; git -C "$src" add feature.txt; git -C "$src" commit -qm 'first local change'
  printf 'second\n' >> "$src/feature.txt"; git -C "$src" commit -qam 'second local change'
  TIP=$(git -C "$src" rev-parse HEAD)
  git -C "$clone" merge -q --squash fm/squashed >/dev/null
  git -C "$clone" commit -qm 'PR 3159 squash delivered changes'
  git -C "$clone" push -q origin main
  git -C "$clone" fetch -q origin
  git -C "$clone" worktree remove "$src"
  git -C "$clone" merge-base --is-ancestor "$TIP" origin/main && no 'fixture is not a squash merge'
}

sweep() {  # <args...>: guards that every row is inside this lab before --apply is honored
  local a
  OUT=$(bash "$SWEEP" 2>&1); RC=$?
  a=$(printf '%s\n' "$OUT" | awk -F '\t' -v l="$FM_HOME" -v w="$WORK" 'NF>=4 && index($3,"/")==1 && index($3,l)!=1 && index($3,w)!=1 {print $3}')
  if [ -n "$a" ]; then printf 'ABORT: row outside the lab: %s\n' "$a"; exit 9; fi
  [ "$#" = 0 ] || { OUT=$(bash "$SWEEP" "$@" 2>&1); RC=$?; }
  printf -- '--- fm-copy-sweep.sh %s (exit %s)\n%s\n' "$*" "$RC" "$OUT" | sed "s#$FM_HOME#<lab>#g; s#$WORK#<work>#g"
}
class_of() { printf '%s\n' "$OUT" | awk -F '\t' -v c="$1" 'NF>=4 && $3==c {print $1; exit}'; }
reason_of() { printf '%s\n' "$OUT" | awk -F '\t' -v c="$1" 'NF>=4 && $3==c {print $4; exit}'; }
preserves() {
  local key n=0 d
  key=$(printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1)
  for d in "$FM_HOME/data/copy-sweep/"*/nested-copy-preserved/"$key"; do [ -d "$d" ] && n=$((n + 1)); done
  printf '%s' "$n"
}
preserve_dir() {
  local key d
  key=$(printf '%s' "$1" | shasum -a 256 | cut -d ' ' -f 1)
  for d in "$FM_HOME/data/copy-sweep/"*/nested-copy-preserved/"$key"; do [ -d "$d" ] && printf '%s' "$d"; done
}
no_force() {
  local t
  t=$(grep -E 'trace: built-in: git worktree (remove|unlock)' "$WORK/git-trace.log" | grep -E -- ' (--force|-f)( |$)' || true)
  eq 'real git trace shows no forced worktree removal' '' "$t"
}
snapshot() {  # report-mode immutability: refs, worktrees, index bytes, every lab state/data file
  local c=$1
  git -C "$c" for-each-ref
  git -C "$c" worktree list --porcelain
  find "$c/.git/worktrees" -name index -exec shasum -a 256 {} + | sort
  (cd "$FM_HOME" && find state data config -type f -exec shasum -a 256 {} + | sort)
}

# ---------------------------------------------------------------------------
s_m1_squash() {
  lab_up
  local C=$FM_HOME/projects/vernant W; C=$FM_HOME/projects/vernant; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n'; install_driver "$C"; make_squashed "$C"
  for n in locked-clean unlocked-clean unique tracked untracked; do git -C "$C" worktree add -q --detach "$W/$n" "$TIP"; done
  printf 'not delivered\n' > "$W/unique/unique.txt"; git -C "$W/unique" add unique.txt; git -C "$W/unique" commit -qm 'unique unlanded content'
  printf 'dirty\n' >> "$W/tracked/feature.txt"
  printf 'untracked bytes\n' > "$W/untracked/new.txt"
  for n in locked-clean unique tracked untracked; do lock_gone "$C" "$W/$n"; done

  local before after; before=$(snapshot "$C")
  sweep
  after=$(snapshot "$C")
  eq 'report exit' 0 "$RC"
  eq 'report: locked squash copy' PENDING-DRIVER "$(class_of "$W/locked-clean")"
  eq 'report: unlocked squash copy' REAPABLE-PROVEN "$(class_of "$W/unlocked-clean")"
  eq 'report: one unique commit' HELD-UNPUSHED "$(class_of "$W/unique")"
  eq 'report: tracked edit' HELD-DIRTY "$(class_of "$W/tracked")"
  eq 'report: untracked file' HELD-DIRTY "$(class_of "$W/untracked")"
  has 'report names the content proof' "$(reason_of "$W/locked-clean")" 'content already in the default branch'
  [ "$before" = "$after" ] && ok 'report changed no ref, worktree, index, state or data file' || no 'report changed something'
  present 'report removed nothing' "$W/locked-clean"

  sweep --apply
  eq 'apply exit' 0 "$RC"
  absent 'apply reaped locked squash copy' "$W/locked-clean"
  absent 'apply reaped unlocked squash copy' "$W/unlocked-clean"
  has 'driver plan ran first, then execute' "$(cat "$C/driver-calls.log")" 'locked-clean execute=False'
  has 'driver execute ran' "$(cat "$C/driver-calls.log")" 'locked-clean execute=True'
  eq 'apply: unique commit held' HELD-UNPUSHED "$(class_of "$W/unique")"
  eq 'unique bytes intact' 'not delivered' "$(cat "$W/unique/unique.txt")"
  eq 'tracked edit intact' 'dirty' "$(tail -1 "$W/tracked/feature.txt")"
  eq 'untracked bytes intact' 'untracked bytes' "$(cat "$W/untracked/new.txt")"
  hasnt 'worktree list has no reaped copy' "$(git -C "$C" worktree list)" 'locked-clean'
  has 'removal log names the copy' "$(cat "$FM_HOME/data/copy-sweep.log")" "$W/locked-clean"
  has 'REMOVED line reports freed bytes' "$OUT" 'net freed'
  no_force
  sweep --apply
  eq 'a second apply is idempotent' 0 "$RC"
  present 'held copy survives a second apply' "$W/unique/unique.txt"
  lab_down
}

s_proof_adversary() {
  lab_up
  local C=$FM_HOME/projects/vernant W; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n'; install_driver "$C"; make_squashed "$C"
  # same message and same PR text as the squash, other content
  git -C "$C" worktree add -q --detach "$W/same-message" "$FORK"
  printf 'other bytes\n' > "$W/same-message/feature.txt"; git -C "$W/same-message" add feature.txt
  git -C "$W/same-message" commit -qm 'PR 3159 squash delivered changes'
  # one delivered commit plus partly delivered content
  git -C "$C" worktree add -q --detach "$W/partial" "$TIP"
  printf 'third\n' >> "$W/partial/feature.txt"; git -C "$W/partial" commit -qam 'second local change'
  # an arbitrary local lock tip: the commit's content only in another local branch
  git -C "$C" branch local-only "$TIP"
  git -C "$C" worktree add -q -b local-holder "$WORK/holder" "$TIP"
  printf 'local only\n' > "$WORK/holder/l.txt"; git -C "$WORK/holder" add l.txt; git -C "$WORK/holder" commit -qm 'local only'
  git -C "$C" worktree add -q --detach "$W/local-only" local-holder
  # content deleted by a merged change: main no longer has what the copy has
  git -C "$C" worktree add -q --detach "$W/reverted" "$TIP"
  # delivered, then edited to a different value by main on the same line: conflict
  git -C "$C" worktree add -q --detach "$W/conflict" "$FORK"
  printf 'first\nsecond but different\n' > "$W/conflict/feature.txt"; git -C "$W/conflict" add feature.txt; git -C "$W/conflict" commit -qm c
  # an empty commit on the tip (no content) stays reapable: control
  git -C "$C" worktree add -q --detach "$W/control" "$TIP"
  for n in same-message partial local-only reverted conflict control; do lock_gone "$C" "$W/$n"; done
  sweep
  for n in same-message partial local-only conflict; do
    eq "report before revert: $n has no content proof" HELD-UNPUSHED "$(class_of "$W/$n")"
  done
  eq 'report before revert: control is proved' PENDING-DRIVER "$(class_of "$W/control")"
  eq 'report before revert: delivered copy is proved' PENDING-DRIVER "$(class_of "$W/reverted")"
  git -C "$C" revert --no-edit HEAD >/dev/null; git -C "$C" push -q origin main; git -C "$C" fetch -q origin
  # after the revert, main no longer holds the feature, so nothing proves these copies
  sweep
  for n in same-message partial local-only reverted conflict control; do
    eq "report after revert: $n held" HELD-UNPUSHED "$(class_of "$W/$n")"
  done
  sweep --apply
  for n in same-message partial local-only reverted conflict control; do present "apply kept $n" "$W/$n"; done
  eq 'apply: no driver plan for an unproved copy' '' "$(cat "$C/driver-calls.log" 2>/dev/null)"
  git -C "$C" worktree remove "$WORK/holder"
  no_force
  lab_down

  # Local refs lie: origin/main here holds the squash, but the remote was rewound.
  lab_up
  C=$FM_HOME/projects/vernant; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n'; install_driver "$C"; make_squashed "$C"
  git -C "$C" worktree add -q --detach "$W/rewound-locked" "$TIP"; lock_gone "$C" "$W/rewound-locked"
  git -C "$C" worktree add -q --detach "$W/rewound-unlocked" "$TIP"
  git -C "$(git -C "$C" remote get-url origin)" update-ref refs/heads/main "$FORK"
  sweep
  eq 'report on stale local ref is only a prediction' PENDING-DRIVER "$(class_of "$W/rewound-locked")"
  sweep --apply
  present 'apply re-fetched and kept locked copy' "$W/rewound-locked"
  present 'apply re-fetched and kept unlocked copy' "$W/rewound-unlocked"
  eq 'apply: rewound locked copy' HELD-UNPUSHED "$(class_of "$W/rewound-locked")"
  eq 'apply: rewound unlocked copy' HELD-UNPUSHED "$(class_of "$W/rewound-unlocked")"
  lab_down

  # Origin unreachable: no fresh proof means no release.
  lab_up
  C=$FM_HOME/projects/vernant; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n'; install_driver "$C"; make_squashed "$C"
  git -C "$C" worktree add -q --detach "$W/nofetch-locked" "$TIP"; lock_gone "$C" "$W/nofetch-locked"
  git -C "$C" worktree add -q --detach "$W/nofetch-unlocked" "$TIP"
  git -C "$C" remote set-url origin "$WORK/gone.git"
  sweep --apply
  present 'fetch failure kept locked copy' "$W/nofetch-locked"
  present 'fetch failure kept unlocked copy' "$W/nofetch-unlocked"
  eq 'fetch failure: locked copy class' HELD-UNPUSHED "$(class_of "$W/nofetch-locked")"
  eq 'fetch failure: unlocked copy class' HELD-UNPUSHED "$(class_of "$W/nofetch-unlocked")"
  lab_down
}

s_custody_adversary() {
  lab_up
  local C=$FM_HOME/projects/vernant W live; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n'; install_driver "$C"; make_squashed "$C"
  for n in live-launcher pid-one hand-lock cwd-inside record-held stale-verify retain-archive outer; do
    git -C "$C" worktree add -q --detach "$W/$n" "$TIP"
  done
  sleep 600 & live=$!; KIDS+=("$live")
  git -C "$C" worktree lock --reason "vernant-session-active owner=launcher:$live launcher=$live" "$W/live-launcher"
  git -C "$C" worktree lock --reason "vernant-session-active owner=launcher:1 launcher=1" "$W/pid-one"
  git -C "$C" worktree lock --reason 'operator hold, do not touch' "$W/hand-lock"
  (cd "$W/cwd-inside" && exec sleep 600) & KIDS+=("$!")
  printf 'worktree=%s\nkind=ship\n' "$W/record-held" > "$FM_HOME/state/live-task.meta"
  lock_gone "$C" "$W/stale-verify"; lock_gone "$C" "$W/retain-archive"
  mkdir -p "$W/retain-archive/.claude/channel-outbox"; printf 'jsonl\n' > "$W/retain-archive/.claude/channel-outbox/a.jsonl"
  git -C "$C" worktree add -q --detach "$W/outer/.claude/worktrees/inner" "$TIP"
  printf 'inner uncommitted\n' > "$W/outer/.claude/worktrees/inner/inner.txt"
  sleep 1
  sweep --apply
  eq 'launcher alive holds' HELD-LOCKED "$(class_of "$W/live-launcher")"
  has 'reason says alive' "$(reason_of "$W/live-launcher")" 'is alive'
  eq 'launcher pid 1 (other user) holds' HELD-LOCKED "$(class_of "$W/pid-one")"
  eq 'hand lock holds' HELD-LOCKED "$(class_of "$W/hand-lock")"
  eq 'real process cwd inside holds' HELD-LIVE-TASK "$(class_of "$W/cwd-inside")"
  eq 'active task record holds' HELD-LIVE-TASK "$(class_of "$W/record-held")"
  eq 'driver refusal holds' HELD-LOCKED "$(class_of "$W/stale-verify")"
  has 'driver words shown' "$(reason_of "$W/stale-verify")" 'verification_stale_or_uncovered_paths'
  eq 'archive_then_retain_tree holds' HELD-LOCKED "$(class_of "$W/retain-archive")"
  has 'retain rule named' "$(reason_of "$W/retain-archive")" 'archive_then_retain_tree'
  eq 'inner copy held dirty' HELD-DIRTY "$(class_of "$W/outer/.claude/worktrees/inner")"
  eq 'outer copy held by inner' HELD-DIRTY "$(class_of "$W/outer")"
  for n in live-launcher pid-one hand-lock cwd-inside record-held stale-verify retain-archive outer; do present "$n kept" "$W/$n"; done
  eq 'archive case: one .jsonl left in place' 'jsonl' "$(cat "$W/retain-archive/.claude/channel-outbox/a.jsonl")"
  eq 'archive case: no preserve' 0 "$(preserves "$W/retain-archive")"
  hasnt 'archive case: driver never executed' "$(cat "$C/driver-calls.log")" 'retain-archive execute=True'
  hasnt 'refused case: driver never executed' "$(cat "$C/driver-calls.log")" 'stale-verify execute=True'
  sweep --apply
  eq 'archive case: second run adds no preserve' 0 "$(preserves "$W/retain-archive")"
  eq 'archive case: no tar appeared in lab data' '' "$(find "$FM_HOME/data" -name '*.tar*' 2>/dev/null)"
  lab_down
}

s_preserved_classes() {
  lab_up
  local C=$FM_HOME/projects/vernant W rel name src pres; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n.import_linter_cache/\n.tac/\ngraft/\nunique.dat\n*.tsbuildinfo\n.DS_Store\ngraphify-out/\n'
  for name in cache scratch log generated build-info unique no-ignored 'with space'; do
    git -C "$C" worktree add -q --detach "$W/$name" origin/main
  done
  mkdir -p "$W/cache/.import_linter_cache" "$W/scratch/.tac/tmp" "$W/log/.claude/logs" "$W/generated/graft" "$W/with space/.claude/logs/deep dir"
  printf 'cache bytes\n' > "$W/cache/.import_linter_cache/payload"
  printf 'scratch bytes\n' > "$W/scratch/.tac/tmp/payload"
  printf 'log bytes\n' > "$W/log/.claude/logs/payload"
  printf 'generated bytes\n' > "$W/generated/graft/payload"
  printf 'build info\n' > "$W/build-info/x.tsbuildinfo"
  printf 'unique bytes\n' > "$W/unique/unique.dat"
  printf 'space bytes\n' > "$W/with space/.claude/logs/deep dir/a b.log"
  sweep
  eq 'report: cache payload' REAPABLE-PROVEN "$(class_of "$W/cache")"
  eq 'report: scratch payload' REAPABLE-PROVEN "$(class_of "$W/scratch")"
  eq 'report: log payload' REAPABLE-PROVEN "$(class_of "$W/log")"
  eq 'report: generated payload' REAPABLE-PROVEN "$(class_of "$W/generated")"
  eq 'report: unique non-cache ignored' HELD-DIRTY "$(class_of "$W/unique")"
  sweep --apply
  eq 'apply exit' 0 "$RC"
  for pair in 'cache:.import_linter_cache/payload' 'scratch:.tac/tmp/payload' 'log:.claude/logs/payload' 'generated:graft/payload' 'build-info:x.tsbuildinfo' 'with space:.claude/logs/deep dir/a b.log'; do
    name=${pair%%:*}; rel=${pair#*:}
    absent "$name copy reaped" "$W/$name"
    eq "$name exactly one preserve" 1 "$(preserves "$W/$name")"
    pres=$(preserve_dir "$W/$name")
    present "$name preserved bytes exist" "$pres/$rel"
    src=$(shasum -a 256 "$pres/$rel" | cut -d ' ' -f 1)
    has "$name manifest matches actual preserved bytes" "$(cat "$pres/SHA256SUMS")" "$src  $rel"
    printf 'class=%s sha256=%s content=%s\n' "$name" "$src" "$(cat "$pres/$rel")"
  done
  eq 'preserved cache content byte-exact' 'cache bytes' "$(cat "$(preserve_dir "$W/cache")/.import_linter_cache/payload")"
  eq 'no-ignored copy leaves no preserve' 0 "$(preserves "$W/no-ignored")"
  absent 'no-ignored copy reaped' "$W/no-ignored"
  present 'unique non-cache ignored holds the copy' "$W/unique/unique.dat"
  eq 'unique bytes intact' 'unique bytes' "$(cat "$W/unique/unique.dat")"
  eq 'held copy is not preserved' 0 "$(preserves "$W/unique")"
  no_force
  lab_down

  # An unreadable ignored payload: cannot prove bytes, so nothing is removed.
  lab_up
  C=$FM_HOME/projects/vernant; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n'
  git -C "$C" worktree add -q --detach "$W/unreadable" origin/main
  mkdir -p "$W/unreadable/.claude/logs/secret"; printf 'log\n' > "$W/unreadable/.claude/logs/secret/x"
  chmod 000 "$W/unreadable/.claude/logs/secret"
  sweep --apply
  chmod 755 "$W/unreadable/.claude/logs/secret"
  eq 'unreadable payload fails the run' 1 "$RC"
  has 'FAILED line names the copy' "$OUT" "FAILED"$'\t'"$W/unreadable"
  eq 'unreadable payload bytes intact' 'log' "$(cat "$W/unreadable/.claude/logs/secret/x")"
  lab_down
}

s_regenerable() {
  lab_up
  local C=$FM_HOME/projects/vernant W n; W=$C/.claude/worktrees
  make_project "$C" '.claude/\nnode_modules/\n.venv/\nvenv/\n__pycache__/\n.pytest_cache/\n.mypy_cache/\n.ruff_cache/\n.next/\n.turbo/\n.cache/\nbuild/\nunique.dat\n'
  install_driver "$C"
  for n in all-names root-cache locked-regen deep link-out; do git -C "$C" worktree add -q --detach "$W/$n" origin/main; done
  git -C "$C" worktree add -q --detach "$W/not-ignored" origin/main
  # Root level: the names the existing skip list already treats as disposable.
  for n in node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .next; do
    mkdir -p "$W/all-names/$n/sub"; dd if=/dev/zero of="$W/all-names/$n/sub/blob" bs=1024 count=64 2>/dev/null
  done
  # Inside an ignored entry: every name of the closed class, at any depth.
  for n in node_modules .venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .next .turbo .cache; do
    mkdir -p "$W/all-names/.claude/d/e/$n"; printf 'x\n' > "$W/all-names/.claude/d/e/$n/payload"
  done
  printf 'keep\n' > "$W/all-names/.claude/d/e/keep.txt"
  mkdir -p "$W/all-names/.claude/d/e/node_modules2"; printf 'near\n' > "$W/all-names/.claude/d/e/node_modules2/near.txt"
  # A root .cache is outside the owner's skip list: the recorded rule keeps holding it.
  mkdir -p "$W/root-cache/.cache"; printf 'root cache\n' > "$W/root-cache/.cache/payload"
  mkdir -p "$W/locked-regen/node_modules/p" "$W/locked-regen/build/node_modules/q"
  printf 'js\n' > "$W/locked-regen/node_modules/p/i.js"; printf 'js\n' > "$W/locked-regen/build/node_modules/q/i.js"
  printf 'note\n' > "$W/locked-regen/build/keep.txt"; printf 'unique\n' > "$W/locked-regen/unique.dat"
  lock_gone "$C" "$W/locked-regen"
  mkdir -p "$W/deep/.claude/tool/node_modules/p" "$W/deep/.claude/logs"
  printf 'js\n' > "$W/deep/.claude/tool/node_modules/p/i.js"; printf 'keep\n' > "$W/deep/.claude/logs/keep.log"
  # A symlink named as a class member points at bytes outside the copy.
  mkdir -p "$WORK/outside"; printf 'outside bytes\n' > "$WORK/outside/precious"
  mkdir -p "$W/link-out/.claude"; ln -s "$WORK/outside" "$W/link-out/.claude/.cache"
  # node_modules that is NOT ignored is plain untracked work.
  git -C "$W/not-ignored" rm -q --cached .gitignore; git -C "$W/not-ignored" commit -qm 'drop ignore rules' 2>/dev/null
  rm -f "$W/not-ignored/.gitignore"
  mkdir -p "$W/not-ignored/node_modules/p"; printf 'work\n' > "$W/not-ignored/node_modules/p/i.js"
  sweep
  has 'report row names regenerable bytes' "$(reason_of "$W/all-names")" 'regenerable'
  has 'report row says not preserved' "$(reason_of "$W/all-names")" 'removed with it, not preserved'
  has 'report has the regenerable total line' "$OUT" 'regenerable: '
  eq 'report: locked regenerable copy' PENDING-DRIVER "$(class_of "$W/locked-regen")"
  eq 'report: root .cache keeps holding (recorded rule)' HELD-DIRTY "$(class_of "$W/root-cache")"
  hasnt 'report: held row has no regenerable claim' "$(reason_of "$W/root-cache")" 'regenerable'
  sweep --apply
  absent 'all class names: copy reaped' "$W/all-names"
  eq 'all class names: one preserve' 1 "$(preserves "$W/all-names")"
  eq 'all class names: other ignored bytes preserved' 'keep' "$(cat "$(preserve_dir "$W/all-names")/.claude/d/e/keep.txt")"
  eq 'all class names: near name kept' 'near' "$(cat "$(preserve_dir "$W/all-names")/.claude/d/e/node_modules2/near.txt")"
  eq 'all class names: no class dir preserved' '' "$(find "$(preserve_dir "$W/all-names")" -type d \( -name node_modules -o -name .venv -o -name venv -o -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache -o -name .next -o -name .turbo -o -name .cache \))"
  has 'REMOVED line names the copy' "$OUT" "REMOVED"$'\t'"$W/all-names"
  present 'root .cache copy kept' "$W/root-cache/.cache/payload"
  absent 'locked copy reaped through the driver' "$W/locked-regen"
  eq 'locked copy: one preserve' 1 "$(preserves "$W/locked-regen")"
  eq 'locked copy: build bytes preserved' 'note' "$(cat "$(preserve_dir "$W/locked-regen")/build/keep.txt")"
  eq 'locked copy: unique bytes preserved' 'unique' "$(cat "$(preserve_dir "$W/locked-regen")/unique.dat")"
  absent 'locked copy: node_modules left out' "$(preserve_dir "$W/locked-regen")/node_modules"
  absent 'locked copy: nested node_modules left out' "$(preserve_dir "$W/locked-regen")/build/node_modules"
  absent 'deep copy reaped' "$W/deep"
  eq 'deep copy: sibling log preserved' 'keep' "$(cat "$(preserve_dir "$W/deep")/.claude/logs/keep.log")"
  absent 'deep copy: node_modules left out at depth' "$(preserve_dir "$W/deep")/.claude/tool/node_modules"
  absent 'symlink copy reaped' "$W/link-out"
  eq 'symlink target outside the copy intact' 'outside bytes' "$(cat "$WORK/outside/precious")"
  present 'symlink itself preserved, not followed' "$(preserve_dir "$W/link-out")/.claude/.cache"
  [ -L "$(preserve_dir "$W/link-out")/.claude/.cache" ] && ok 'preserved entry is still a symlink' || no 'preserved entry is not a symlink'
  present 'not-ignored node_modules is kept' "$W/not-ignored/node_modules/p/i.js"
  no_force
  lab_down
}

s_refused_growth() {
  lab_up
  local C=$FM_HOME/projects/vernant W run; W=$C/.claude/worktrees
  make_project "$C" '.claude/\nnode_modules/\n'
  git -C "$C" -c protocol.file.allow=always submodule --quiet add "$(git -C "$C" remote get-url origin)" vendored
  git -C "$C" commit -qm 'hold a submodule'; git -C "$C" push -q origin main; git -C "$C" fetch -q origin
  git -C "$C" worktree add -q --detach "$W/refused" origin/main
  git -C "$W/refused" -c protocol.file.allow=always submodule --quiet update --init
  mkdir -p "$W/refused/.claude" "$W/refused/node_modules/p"
  dd if=/dev/urandom of="$W/refused/.claude/keep.bin" bs=1048576 count=2 2>/dev/null
  printf 'js\n' > "$W/refused/node_modules/p/i.js"
  local sum; sum=$(shasum -a 256 "$W/refused/.claude/keep.bin" | cut -d ' ' -f 1)
  for run in 1 2 3; do
    sweep --apply
    eq "run $run: exit" 1 "$RC"
    has "run $run: git refused" "$OUT" 'git worktree remove refused'
    eq "run $run: preserve count" 0 "$(preserves "$W/refused")"
    eq "run $run: original bytes" "$sum" "$(shasum -a 256 "$W/refused/.claude/keep.bin" | cut -d ' ' -f 1)"
    present "run $run: regenerable intact" "$W/refused/node_modules/p/i.js"
  done
  eq 'data/copy-sweep has no leftover preserve bytes' '' "$(find "$FM_HOME/data/copy-sweep" -type f 2>/dev/null)"
  no_force
  lab_down
}

# A real background writer, cwd outside the copy, no cp shim. Slow payload widens the window.
writer() {  # <file> <mode:overwrite|newfile>
  ( cd "$WORK" || exit; i=0; while :; do i=$((i + 1))
      case "$2" in overwrite) printf 'tick %s\n' "$i" > "$1" ;; newfile) printf 'n\n' > "$1-$i" ;; esac
      sleep 0.02; done ) >/dev/null 2>&1 &
  WRITER=$!; KIDS+=("$WRITER")
}
s_live_writer() {
  lab_up
  local C=$FM_HOME/projects/vernant W run n; W=$C/.claude/worktrees
  make_project "$C" '.claude/\nnode_modules/\n'
  install_driver "$C"
  for n in activity newcontent mismatch waiting; do
    git -C "$C" worktree add -q --detach "$W/$n" origin/main
    mkdir -p "$W/$n/.claude/.cache"
    printf 'original %s\n' "$n" > "$W/$n/.claude/keep.txt"
    dd if=/dev/urandom of="$W/$n/.claude/big.bin" bs=1048576 count=64 2>/dev/null
  done

  # 1. activity only: the writer changes a regenerable file during preservation.
  git -C "$C" worktree lock --reason 'hold others off' "$W/newcontent"
  git -C "$C" worktree lock --reason 'hold others off' "$W/mismatch"
  git -C "$C" worktree lock --reason 'hold others off' "$W/waiting"
  writer "$W/activity/.claude/.cache/tick" overwrite; local w1=$WRITER
  for run in 1 2 3; do
    sweep --apply
    eq "activity run $run: exit" 1 "$RC"
    has "activity run $run: stopped" "$OUT" "FAILED"$'\t'"$W/activity"$'\t'"ignored payload changed"
    eq "activity run $run: preserve count" 0 "$(preserves "$W/activity")"
    eq "activity run $run: original intact" 'original activity' "$(cat "$W/activity/.claude/keep.txt")"
  done
  kill "$w1"; wait "$w1" 2>/dev/null
  sweep --apply
  absent 'activity: quiet run reaps' "$W/activity"
  eq 'activity: exactly one preserve after release' 1 "$(preserves "$W/activity")"
  eq 'activity: preserve holds original' 'original activity' "$(cat "$(preserve_dir "$W/activity")/.claude/keep.txt")"

  # 2. only new content appears during preservation.
  git -C "$C" worktree unlock "$W/newcontent"
  writer "$W/newcontent/.claude/late" newfile; local w2=$WRITER
  for run in 1 2 3; do
    sweep --apply
    has "newcontent run $run: stopped" "$OUT" "FAILED"$'\t'"$W/newcontent"$'\t'"ignored payload changed"
    eq "newcontent run $run: preserve count" 0 "$(preserves "$W/newcontent")"
  done
  kill "$w2"; wait "$w2" 2>/dev/null
  sweep --apply
  absent 'newcontent: quiet run reaps' "$W/newcontent"
  eq 'newcontent: exactly one preserve' 1 "$(preserves "$W/newcontent")"

  # 3. a real change to a preserved original keeps the preserve as evidence.
  git -C "$C" worktree unlock "$W/mismatch"
  writer "$W/mismatch/.claude/keep.txt" overwrite; local w3=$WRITER
  sweep --apply
  eq 'mismatch: exit' 1 "$RC"
  has 'mismatch: stopped' "$OUT" "FAILED"$'\t'"$W/mismatch"
  present 'mismatch: copy kept' "$W/mismatch/.claude/keep.txt"
  local kept; kept=$(preserves "$W/mismatch")
  eq 'mismatch: preserve kept as evidence' 1 "$kept"
  kill "$w3"; wait "$w3" 2>/dev/null
  sweep --apply
  absent 'mismatch: quiet run reaps' "$W/mismatch"
  eq 'mismatch: evidence preserve kept, final bytes preserved too' 2 "$(preserves "$W/mismatch")"

  # 4. locked route: WAITING with no preserve growth until quiet.
  git -C "$C" worktree unlock "$W/waiting"; lock_gone "$C" "$W/waiting"
  # .claude is outside the locked route's preserve list; build/ is inside it.
  printf 'build/\n' >> "$(git -C "$C" rev-parse --path-format=absolute --git-path info/exclude)"
  mkdir -p "$W/waiting/build/.cache"; printf 'keep waiting\n' > "$W/waiting/build/keep.txt"
  dd if=/dev/urandom of="$W/waiting/build/big.bin" bs=1048576 count=64 2>/dev/null
  writer "$W/waiting/build/.cache/tick" overwrite; local w4=$WRITER
  sweep --apply
  eq 'locked activity: exit' 1 "$RC"
  local p1 p2; p1=$(preserves "$W/waiting")
  printf 'locked activity preserve count after run 1: %s\n' "$p1"
  sweep --apply
  eq 'locked activity: WAITING while the writer runs' WAITING "$(class_of "$W/waiting")"
  p2=$(preserves "$W/waiting")
  eq 'locked activity: WAITING adds no preserve' "$p1" "$p2"
  hasnt 'locked activity: no execute while writing' "$(cat "$C/driver-calls.log")" 'waiting execute=True'
  kill "$w4"; wait "$w4" 2>/dev/null
  sweep --apply       # the first quiet run records the quiet fingerprint
  [ -e "$W/waiting" ] && sweep --apply
  absent 'locked activity: released once quiet' "$W/waiting"
  has 'locked activity: released through the driver' "$(cat "$C/driver-calls.log")" 'waiting execute=True'
  printf 'locked activity preserves at the end: %s\n' "$(preserves "$W/waiting")"
  local d f=0
  while IFS= read -r d; do [ "$(cat "$d/build/keep.txt" 2>/dev/null)" = 'keep waiting' ] && f=1; done < <(preserve_dir "$W/waiting"; printf '\n')
  eq 'locked activity: bytes are in a preserve' 1 "$f"
  no_force
  lab_down
}

s_confined_process() {
  lab_up
  local C=$FM_HOME/projects/vernant W live badbin; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n'; install_driver "$C"; make_squashed "$C"
  for n in dead-launcher live-launcher; do git -C "$C" worktree add -q --detach "$W/$n" "$TIP"; done
  lock_gone "$C" "$W/dead-launcher"
  sleep 600 & live=$!; KIDS+=("$live")
  git -C "$C" worktree lock --reason "vernant-session-active owner=launcher:$live launcher=$live" "$W/live-launcher"
  local profile='(version 1)(allow default)'
  OUT=$(sandbox-exec -p "$profile" bash -c 'ps -p $$ -o pid= >/dev/null 2>&1; echo $?' 2>&1)
  eq 'real ps is refused inside the sandbox' 126 "$OUT"

  OUT=$(sandbox-exec -p "$profile" bash "$SWEEP" 2>&1); RC=$?
  printf -- '--- sandboxed report (exit %s)\n%s\n' "$RC" "$OUT" | sed "s#$FM_HOME#<lab>#g; s#$WORK#<work>#g"
  eq 'confined: exited launcher proved absent' PENDING-DRIVER "$(class_of "$W/dead-launcher")"
  eq 'confined: live launcher holds' HELD-LOCKED "$(class_of "$W/live-launcher")"
  has 'confined: reason says alive' "$(reason_of "$W/live-launcher")" 'is alive'

  # fault: the helper's interpreter fails while ps stays refused.
  badbin=$WORK/badbin; mkdir -p "$badbin"; printf '#!/bin/sh\nexit 1\n' > "$badbin/python3"; chmod +x "$badbin/python3"
  OUT=$(PATH="$badbin:$PATH" sandbox-exec -p "$profile" bash "$SWEEP" 2>&1); RC=$?
  printf -- '--- sandboxed report with failed helper (exit %s)\n%s\n' "$RC" "$OUT" | sed "s#$FM_HOME#<lab>#g; s#$WORK#<work>#g"
  eq 'failed helper: dead launcher still holds' HELD-LOCKED "$(class_of "$W/dead-launcher")"
  has 'failed helper: absence not proved' "$(reason_of "$W/dead-launcher")" 'cannot be observed'
  OUT=$(PATH="$badbin:$PATH" sandbox-exec -p "$profile" bash "$SWEEP" --apply 2>&1); RC=$?
  present 'failed helper: apply keeps the copy' "$W/dead-launcher"

  # confined apply with a working helper really releases the dead-launcher copy.
  OUT=$(sandbox-exec -p "$profile" bash "$SWEEP" --apply 2>&1); RC=$?
  printf -- '--- sandboxed apply (exit %s)\n%s\n' "$RC" "$OUT" | sed "s#$FM_HOME#<lab>#g; s#$WORK#<work>#g"
  absent 'confined apply reaps the exited-launcher copy' "$W/dead-launcher"
  present 'confined apply keeps the live-launcher copy' "$W/live-launcher"
  lab_down
}

s_real_shapes() {
  # Reported shape: a registered lane home, record gone, squash-merged orphan.
  lab_up
  local lane=$WORK/lane-d1 P W n; P=$lane/projects/vernant; W=$P/.claude/worktrees
  mkdir -p "$lane/state" "$lane/data" "$lane/config"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$FM_HOME" > "$lane/.fm-secondmate-parent"
  printf -- '- d1 - d1 (home: %s; scope: fixture; projects: vernant; added 2026-10-18)\n' "$lane" >> "$FM_HOME/data/secondmates.md"
  printf 'kind=secondmate\nhome=%s\n' "$lane" > "$FM_HOME/state/d1.meta"
  make_project "$P" '.claude/\n'; install_driver "$P"; make_squashed "$P"
  for n in fm-vernant-d1-grounding-clock-baseline-v2 fm-vernant-d1-corpus-xlsx-upload-v10 stale-verify lane-record retain-archive; do
    git -C "$P" worktree add -q --detach "$W/$n" "$TIP"
    lock_gone "$P" "$W/$n"
  done
  printf 'worktree=%s\nkind=ship\n' "$W/lane-record" > "$lane/state/lane-task.meta"
  sweep
  eq 'lane: squash-merged orphan is found and proved' PENDING-DRIVER "$(class_of "$W/fm-vernant-d1-grounding-clock-baseline-v2")"
  eq 'lane: lane record holds its copy' HELD-LIVE-TASK "$(class_of "$W/lane-record")"
  sweep --apply
  absent 'lane: PR-3159-shaped orphan reaped' "$W/fm-vernant-d1-grounding-clock-baseline-v2"
  absent 'lane: second orphan reaped' "$W/fm-vernant-d1-corpus-xlsx-upload-v10"
  present 'lane: driver-refused copy kept' "$W/stale-verify"
  present 'lane: archive-retain copy kept' "$W/retain-archive"
  present 'lane: lane-record copy kept' "$W/lane-record"
  no_force
  lab_down

  # Pool slot shape, read from treehouse-state.json. The sweep changes no pool file.
  lab_up
  local TH=$WORK/th SLOT; SLOT=$TH/pool1/1/repo; mkdir -p "$TH/pool1/1"
  make_project "$SLOT" '.claude/\n'; make_squashed "$SLOT"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$SLOT" > "$TH/pool1/treehouse-state.json"
  local st; st=$(shasum -a 256 "$TH/pool1/treehouse-state.json")
  export FM_COPY_SWEEP_TREEHOUSE_ROOT=$TH
  git -C "$SLOT" worktree add -q --detach "$SLOT/.claude/worktrees/orphan" "$TIP"
  sweep --apply
  absent 'pool slot: nested squash copy reaped' "$SLOT/.claude/worktrees/orphan"
  present 'pool slot: slot itself untouched' "$SLOT/base.txt"
  eq 'pool state file unchanged' "$st" "$(shasum -a 256 "$TH/pool1/treehouse-state.json")"
  lab_down

  # check mode: the watcher's report-only entry names the same class and removes nothing.
  lab_up
  local C=$FM_HOME/projects/vernant; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n'; install_driver "$C"; make_squashed "$C"
  git -C "$C" worktree add -q --detach "$W/orphan" "$TIP"; lock_gone "$C" "$W/orphan"
  dd if=/dev/zero of="$W/orphan/.claude-pad" bs=1024 count=1 2>/dev/null; rm -f "$W/orphan/.claude-pad"
  printf 'default-container 0\ndefault-pool off\nload-limit 100000\n' > "$FM_HOME/config/copy-budget"
  OUT=$(FM_CHECK_TIMEOUT=120 bash "$SWEEP" check 2>&1); RC=$?
  printf -- '--- check (exit %s)\n%s\n' "$RC" "$OUT" | sed "s#$FM_HOME#<lab>#g; s#$WORK#<work>#g"
  has 'check names the candidate PENDING-DRIVER' "$OUT" 'PENDING-DRIVER'
  present 'check removed nothing' "$W/orphan"
  eq 'check never asks the driver' '' "$(cat "$C/driver-calls.log" 2>/dev/null)"
  lab_down
}

s_scale() {
  lab_up
  local C=$FM_HOME/projects/vernant W t0 t1; W=$C/.claude/worktrees
  make_project "$C" '.claude/\nnode_modules/\n'
  git -C "$C" worktree add -q --detach "$W/many" origin/main
  mkdir -p "$W/many/node_modules/p" "$W/many/.claude/logs"
  (cd "$W/many/node_modules/p" && i=0; while [ "$i" -lt 30000 ]; do : > "f $i.js"; i=$((i + 1)); done)
  (cd "$W/many/.claude/logs" && i=0; while [ "$i" -lt 3000 ]; do printf '%s\n' "$i" > "l$i.log"; i=$((i + 1)); done)
  t0=$SECONDS
  OUT=$(bash "$SWEEP" --apply 2>&1); RC=$?
  t1=$SECONDS
  printf 'apply on 30000 regenerable + 3000 preserved files: exit=%s seconds=%s\n' "$RC" "$((t1 - t0))"
  printf '%s\n' "$OUT" | tail -5 | sed "s#$FM_HOME#<lab>#g"
  eq 'scale: exit' 0 "$RC"
  absent 'scale: copy reaped' "$W/many"
  eq 'scale: preserve holds all 3000 logs' 3000 "$(find "$(preserve_dir "$W/many")/.claude/logs" -type f | wc -l | tr -d ' ')"
  lab_down
}

# A real commit lands while the sweep is preserving. No shim: a watcher waits for
# the preserve staging directory to appear, then commits unique work into the copy.
late_commit_case() {  # <unlocked|locked>
  lab_up
  local C=$FM_HOME/projects/vernant W copy=$FM_HOME/projects/vernant/.claude/worktrees/late watcher; W=$C/.claude/worktrees
  make_project "$C" '.claude/\nbuild/\n'; install_driver "$C"; make_squashed "$C"
  git -C "$C" worktree add -q --detach "$copy" "$TIP"
  # .claude/logs is what the unlocked route preserves; build/ is what the locked route preserves.
  local pay=.claude/logs; [ "$1" = unlocked ] || pay=build
  mkdir -p "$copy/$pay"; printf 'keep\n' > "$copy/$pay/keep.txt"
  dd if=/dev/urandom of="$copy/$pay/big.bin" bs=1048576 count=64 2>/dev/null
  [ "$1" = unlocked ] || lock_gone "$C" "$copy"
  OUT=$(bash "$SWEEP" 2>&1); RC=$?
  ( cd "$WORK" || exit
    n=0; while [ -z "$(find "$FM_HOME/data/copy-sweep" -type d -name nested-copy-preserved 2>/dev/null)" ]; do
      sleep 0.01; n=$((n + 1)); [ "$n" -lt 12000 ] || exit 1; done
    printf 'written during preservation\n' > "$copy/late.txt"
    git -C "$copy" add late.txt && git -C "$copy" commit -qm 'unique commit during preservation'
    echo committed > "$WORK/watcher.done" ) & watcher=$!; KIDS+=("$watcher")
  OUT=$(bash "$SWEEP" --apply 2>&1); RC=$?
  wait "$watcher" 2>/dev/null
  printf -- '--- apply with a commit during preservation, %s (exit %s)\n%s\n' "$1" "$RC" "$OUT" | sed "s#$FM_HOME#<lab>#g; s#$WORK#<work>#g"
  present "$1: the watcher really committed" "$WORK/watcher.done"
  eq "$1: run reports a failure" 1 "$RC"
  eq "$1: unique commit bytes intact" 'written during preservation' "$(cat "$copy/late.txt")"
  eq "$1: commit still at HEAD" 'unique commit during preservation' "$(git -C "$copy" log -1 --format=%s)"
  eq "$1: original payload intact" 'keep' "$(cat "$copy/$pay/keep.txt")"
  hasnt "$1: driver never executed" "$(cat "$C/driver-calls.log" 2>/dev/null)" 'late execute=True'
  OUT=$(bash "$SWEEP" --apply 2>&1); RC=$?
  eq "$1: next run holds the unique commit" HELD-UNPUSHED "$(class_of "$copy")"
  eq "$1: no forced removal" '' "$(grep -E 'trace: built-in: git worktree (remove|unlock)' "$WORK/git-trace.log" | grep -E -- ' (--force|-f)( |$)' || true)"
  lab_down
}
s_late_commit() {
  late_commit_case unlocked
  late_commit_case locked
  # A reaped copy on a named branch keeps the branch: its commits stay reachable.
  lab_up
  local C=$FM_HOME/projects/vernant W tip; W=$C/.claude/worktrees
  make_project "$C" '.claude/\n'; make_squashed "$C"
  git -C "$C" worktree add -q -b fm/named "$W/named" "$TIP"
  tip=$(git -C "$C" rev-parse fm/named)
  sweep --apply
  absent 'named branch copy reaped' "$W/named"
  eq 'named branch survives the reap' "$tip" "$(git -C "$C" rev-parse fm/named)"
  lab_down
}

for s in "$@"; do
  printf '\n===== %s =====\n' "$s"
  "s_$s"
done
printf '\nscenario failures: %s\n' "$FAILS"
exit "$FAILS"
