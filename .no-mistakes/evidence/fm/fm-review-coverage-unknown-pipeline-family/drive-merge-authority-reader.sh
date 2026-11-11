#!/usr/bin/env bash
# Drives the real bin/fm-merge-authority-lib.sh reader/persist against crafted
# records in a disposable state dir. Usage: <repo-root> <scratch-dir>
set -u
ROOT=$1 W=$2
mkdir -p "$W/home/state"; chmod 700 "$W/home/state"
export FM_HOME="$W/home" FM_STATE_OVERRIDE="$W/home/state"
. "$ROOT/bin/fm-wake-lib.sh"; . "$ROOT/bin/fm-merge-authority-lib.sh"
S="$W/home/state"; R="$S/task-x1.merge-authority"
try() {
  local label=$1 rc; shift
  : > "$R.new"; printf '%s\n' "$@" > "$R.new"; chmod 600 "$R.new"; mv -f "$R.new" "$R"
  if fm_merge_authority_read "$S" task-x1 github github.com example/repo 9; then rc=0; else rc=$?; fi
  printf '%-44s read_rc=%s authority=%s fact=[%s]\n' "$label" "$rc" "$FM_MERGE_AUTHORITY" "$FM_MERGE_AUTHORITY_REVIEW_FACT"
}
H=(fm-merge-authority-v1 github github.com example/repo 9 attended)
try "legacy 6-line record" "${H[@]}"
try "7-line with exact fact" "${H[@]}" "pipeline author family not recorded"
try "7-line with junk fact (adversarial)" "${H[@]}" "anything else"
try "8-line fact + extra (adversarial)" "${H[@]}" "pipeline author family not recorded" extra
try "7-line empty fact line (adversarial)" "${H[@]}" ""
printf 'pr=https://github.com/example/repo/pull/9\n' > "$W/meta"
if fm_merge_authority_persist "$S" task-x1 "$W/meta" github github.com example/repo 9 attended "bogus fact"; then
  echo "persist with bogus fact: ACCEPTED"
else
  echo "persist with bogus fact: refused"
fi
