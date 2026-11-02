#!/usr/bin/env bash
# A4b: reach the real fail-closed home check. The gate check is passed with the test switch; the home is a temp typo.
set -u
WT=$PWD; S=$(mktemp -d "${TMPDIR:-/tmp}/fm-r5t.XXXXXX"); trap 'rm -rf "$S"' EXIT
unset FM_GUARD_EVENT_LOG FM_TASK_ID
mkdir "$S/base"; git archive 1a8fdf768 bin | tar -x -C "$S/base"
send() { local home=$1; shift; (cd "$S" && env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_GATE_REFUSE_BYPASS=1 FM_HOME="$home" "$@" sess:win probe 2>&1); }
for row in "head-default:$WT/bin/fm-send.sh:" "head-explicit-log:$WT/bin/fm-send.sh:$S/e.jsonl" "base-default:$S/base/bin/fm-send.sh:"; do
  IFS=: read -r name bin ex <<<"$row"; home=$S/typo-$name/nested; rc=0
  if [ -n "$ex" ]; then o=$(FM_GUARD_EVENT_LOG=$ex send "$home" "$bin") || rc=$?; else o=$(send "$home" "$bin") || rc=$?; fi
  echo "$name: rc=$rc home created=$([ -e "$S/typo-$name" ] && echo yes || echo no) | $(echo "$o" | sed "s#$S#<tmp>#g" | tail -1 | cut -c1-150)"
done
