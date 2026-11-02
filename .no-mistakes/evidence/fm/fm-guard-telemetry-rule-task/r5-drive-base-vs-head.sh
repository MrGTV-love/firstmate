#!/usr/bin/env bash
# Adversarial: same inputs to base (1a8fdf768) and head scripts; guard outcomes must match.
set -u
WT=$PWD; B=$(mktemp -d "${TMPDIR:-/tmp}/fm-base.XXXXXX"); trap 'rm -rf "$B"' EXIT
git archive 1a8fdf768 | tar -x -C "$B"
unset FM_GUARD_EVENT_LOG FM_GATE_REFUSE_BYPASS FM_TASK_ID
for side in base head; do
  R=$WT; [ $side = base ] && R=$B
  H=$(mktemp -d "${TMPDIR:-/tmp}/fm-cmp.XXXXXX"); mkdir -p "$H/state"
  export FM_GUARD_EVENT_LOG="$H/ev.jsonl"
  ( cd "$WT" && FM_HOME="$H" "$R/bin/fm-send.sh" t hi >/dev/null 2>&1 ); a=$?
  ( . "$R/bin/fm-api-key-guard-lib.sh"; ANTHROPIC_API_KEY=dummy-not-a-key fm_api_key_guard claude 0 '' 0 '' >/dev/null 2>&1 ); b=$?
  ( . "$R/bin/fm-api-key-guard-lib.sh"; ANTHROPIC_API_KEY=dummy-not-a-key fm_api_key_guard claude 1 '' 0 '' >/dev/null 2>&1 ); c=$?
  ( . "$R/bin/fm-api-key-guard-lib.sh"; ANTHROPIC_API_KEY=dummy-not-a-key fm_api_key_guard claude 0 acct 0 '' >/dev/null 2>&1 ); d=$?
  ( cd "$WT" && FM_HOME='' "$R/bin/fm-send.sh" t hi >/dev/null 2>&1 ); e=$?
  echo "$side: gate-refuse(non-lab fm-send)=$a api-key(no waiver)=$b api-key(--allow-api-key)=$c api-key(worker account)=$d fm-send(empty FM_HOME)=$e rows=$(wc -l <"$H/ev.jsonl" 2>/dev/null || echo 0)"
  rm -rf "$H"
done
