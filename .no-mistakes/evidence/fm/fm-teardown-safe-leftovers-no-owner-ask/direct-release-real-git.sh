#!/bin/bash
# Disposable driver: sources the product libraries from <tree>/bin and calls
# teardown_dead_launcher_release on throwaway repos with REAL git locks, a REAL
# `git worktree unlock` and a REAL non-forced `git worktree remove`.
# Stubbed (host limit Main 1850: no process-table scan): launcher liveness, holder
# scan, record-ownership scan, landing proof (admits the copy as landed),
# Git-protects check (says no), admitted-bundle recheck (says current).
set -u
BIN=$1 BASE=$(mktemp -d /private/tmp/fm-fm-teardown-safe-leftovers-no-owner-ask/drr.XXXXXX)
export HOME="$BASE/home" TMPDIR="$BASE/tmp" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t.invalid
mkdir -p "$HOME" "$TMPDIR"
secondmate_registry_parse_line() { :; }
fm_refuse_text() { printf '%s' "$1"; }
. "$BIN/fm-lock-lib.sh"; . "$BIN/fm-task-copy-lib.sh"; . "$BIN/fm-backlog-transition-lib.sh"; . "$BIN/fm-teardown-nested-lib.sh"
LIVE=0
teardown_launcher_gone() { [ "$LIVE" = 1 ] && return 1; return 0; }
teardown_launcher_live_since() { [ "$LIVE" = 1 ] && return 0; return 1; }
teardown_copy_holder_free() { return 0; }
teardown_foreign_copy_unowned() { return 0; }
teardown_landed() { teardown_admit "$1" landed "$(git -C "$1" rev-parse HEAD)" "refs/heads/main $(git -C "$1" rev-parse main)"; return 0; }
teardown_copy_git_protects() { return 1; }
teardown_admitted_bundles_current() { return 0; }
eval "real_first_seen() $(declare -f teardown_lock_is_first_seen | tail -n +2)"
teardown_lock_is_first_seen() {
  case "$shape" in
    own-late) printf 'late\n' > "$copy/.claude/channel-outbox/c.jsonl" ;;
    foreign-late) printf 'changed\n' > "$copy/.claude/channel-outbox/a.jsonl" ;;
    foreign-late-cache) printf 'rerun\n' > "$copy/.cache/run.bin" ;;
  esac
  real_first_seen "$@"
}
TEARDOWN_CLOSEOUT_PROOF=fixture
LOCK='vernant-session-active owner=launcher:4194305 launcher=4194305'
for shape in foreign own-nested own-late foreign-late foreign-late-cache live-launcher; do
  echo "=================== shape=$shape"
  kind=foreign; case "$shape" in own-*) kind='own nested' ;; esac
  LIVE=0; [ "$shape" != live-launcher ] || LIVE=1
  repo="$BASE/$shape-project" copy="$BASE/$shape-copy"
  PROJ=$repo DATA="$BASE/$shape-data/data" STATE="$BASE/$shape-state" WT=$copy ID=fixture META="$BASE/$shape.meta"
  mkdir -p "$DATA/$ID" "$STATE"; : > "$META"
  git init -q -b main "$repo"
  printf '/.claude/\n/.opencode/\n/notes/\n/.cache/\n' > "$repo/.gitignore"
  git -C "$repo" add .gitignore && git -C "$repo" commit -qm initial
  git -C "$repo" worktree add -q -b "f-$shape" "$copy" main
  mkdir -p "$copy/.claude/channel-outbox" "$copy/.claude/bug-evidence" "$copy/.opencode/state" "$copy/notes" "$copy/.cache"
  printf 'run\n' > "$copy/.cache/run.bin"
  printf 'one\n' > "$copy/.claude/channel-outbox/a.jsonl"
  printf 'closeout record\n' > "$copy/.claude/bug-evidence/r.json"
  printf 'evidence\n' > "$copy/.opencode/state/log.json"
  printf 'only here\n' > "$copy/notes/unique.dat"
  git -C "$repo" worktree lock --reason "$LOCK" "$copy"
  echo "before: $(git -C "$repo" worktree list --porcelain | grep -A0 -E '^locked' )"
  TEARDOWN_ADMIT_DIRS=() TEARDOWN_ADMIT_KINDS=() TEARDOWN_ADMIT_HEADS=() TEARDOWN_ADMIT_STORED=() TEARDOWN_ADMIT_RECORD=()
  TEARDOWN_LOCK_SEEN_DIRS=() TEARDOWN_LOCK_SEEN_TEXT=() TEARDOWN_FOREIGN_PROCS=()
  TEARDOWN_NESTED_COPIES=("$copy") TEARDOWN_FOREIGN_COPIES=() TEARDOWN_BUNDLE_SWEEP_PROOF=
  teardown_copy_lock_file "$copy"; teardown_lock_seen "$copy" "$TEARDOWN_FOREIGN_LOCK"
  TEARDOWN_PRESERVE_DIR=
  [ "$kind" != 'own nested' ] || teardown_own_preserve "$copy" 2>/dev/null || echo "own-preserve failed"
  head=$(git -C "$copy" rev-parse HEAD)
  rc=0; teardown_dead_launcher_release "$repo" "$copy" "$head" "$kind" || rc=$?
  echo "release rc=$rc"
  echo "why=${TEARDOWN_RELEASE_WHY:-none}"
  if [ -d "$copy" ]; then echo "copy: STILL PRESENT"; else echo "copy: removed"; fi
  echo "worktree list after:"; git -C "$repo" worktree list --porcelain | sed 's/^/  /'
  echo "preserved files (path  sha256 via SHA256SUMS):"
  find "$DATA/$ID/nested-copy-preserved" -name SHA256SUMS -path '*/meta/*' 2>/dev/null | while read -r m; do echo "  manifest $m"; sed 's/^/    /' "$m"; done
  for f in $(cd "$DATA/$ID/nested-copy-preserved" 2>/dev/null && find . -path '*/files/*' -type f | sort); do echo "  $f = $(cat "$DATA/$ID/nested-copy-preserved/$f")"; done
done
echo "base=$BASE"
