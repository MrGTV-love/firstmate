#!/usr/bin/env bash
# Independent drive of the real bin/fm-merge-prune.sh (from <bin-dir>) in
# throwaway worlds. Outside-world stubs (treehouse, teardown, control, tmux) are
# the suite's own, extracted from <test-file>. Usage: drive.sh <repo-root> <bin-dir> <test-file> <tmp>
set -u
ROOT=$1; BIN_DIR=$2; TF=$3; TMP_ROOT=$4
# Load the suite's helpers (world builder and outside-world stubs) without its runner.
sed -e '/^if \[ "\$#" -gt 0 \]; then$/,$d' -e "s|\"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|\"$ROOT/tests/lib.sh\"|" "$TF" > "$TMP_ROOT/suite-helpers.sh"
. "$TMP_ROOT/suite-helpers.sh"
BIN_DIR=$2
intent() {  # <expires> <branch> [jq filter] -> stdout
  jq -n --arg e "$1" --arg b "$2" '{artifacttype:"CommitIntent",schemaversion:"1.0.0",branch:$b,head_sha:"cd916701e5388f24c741a905c7be6a1348cf4e03",owned_paths:["docs/a.md"],validators:["ruff-check"],expires_at_iso:$e,base_ref:"origin/main"}' | jq -c "${3:-.}"
}
case_run() {  # <label> <want: removed|kept> <setup command...>
  local label=$1 want=$2; shift 2
  make_world
  printf '%s\n' '.claude/' >> "$(git -C "$COPY" rev-parse --path-format=absolute --git-path info/exclude)"
  printf 'branch=fm/t1\n' >> "$STATE/t1.meta"
  printf 'ok\n' > "$W/stub.mode"   # teardown returns the slot
  mkdir -p "$COPY/.claude"
  "$@"
  echo "=== $label (want $want)"
  echo "\$ git -C <copy> status --porcelain --ignored"; git -C "$COPY" status --porcelain --ignored | sed 's/^/  /'
  echo "\$ fm-merge-prune.sh arm t1"; prune arm t1 2>&1 | sed 's/^/  /'
  echo "  record branch= $(rec_field t1 branch)"
  echo "\$ fm-merge-prune.sh run t1 --now"; prune run t1 --now 2>&1 | sed 's/^/  /'
  if [ -e "$COPY" ]; then got=kept; else got=removed; fi
  echo "  copy: $got | destroy calls: $(destroy_calls) | wakes: $(wake_count) | record state: $(rec_field t1 state)"
  echo "  reason: $(rec_field t1 reason)"
  [ ! -s "$STATE/.wake-queue" ] || sed 's/^/  wake: /' "$STATE/.wake-queue"
  sed 's/^/  log: /' "$DATA/t1/merge-prune.log" 2>/dev/null | tail -3
  if [ "$got" = "$want" ]; then echo "RESULT $label: PASS ($got)"; else echo "RESULT $label: FAIL (got $got, want $want)"; fi
}
c_expired() { intent 2000-01-01T00:00:00+00:00 other/branch > "$COPY/.claude/commit-intent.json"; }
c_branch() { intent 2999-01-01T00:00:00+00:00 fm/t1 > "$COPY/.claude/commit-intent.json"; }
c_other_branch() { intent 2999-01-01T00:00:00+00:00 fm/t1-other > "$COPY/.claude/commit-intent.json"; }
c_plus_other_file() { c_expired; printf 'secret\n' > "$COPY/.claude/notes.md"; }
c_invalid() { intent 2000-01-01T00:00:00+00:00 fm/t1 '.owned_paths=["/etc"]' > "$COPY/.claude/commit-intent.json"; }
c_no_tz() { intent 2000-01-01T00:00:00 fm/t1 > "$COPY/.claude/commit-intent.json"; }
c_lookalike() { intent 2000-01-01T00:00:00+00:00 fm/t1 > "$COPY/.claude/commit-intent.json.bak"; }
c_root_lookalike() { intent 2000-01-01T00:00:00+00:00 fm/t1 > "$COPY/.claude/commit-intent.old.json"; }
case_run "A expired valid intent is the only leftover" removed c_expired
case_run "B unexpired intent naming the task branch" removed c_branch
case_run "C unexpired intent naming another branch" kept c_other_branch
case_run "D spent intent plus another .claude file" kept c_plus_other_file
case_run "E expired intent with absolute owned path" kept c_invalid
case_run "F expired intent with no timezone" kept c_no_tz
case_run "G spent payload at .claude/commit-intent.json.bak" kept c_lookalike
case_run "H spent payload at .claude/commit-intent.old.json" kept c_root_lookalike
