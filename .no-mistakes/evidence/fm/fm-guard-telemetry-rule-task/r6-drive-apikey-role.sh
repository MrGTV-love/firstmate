#!/usr/bin/env bash
# Same inputs to base (1c4e2929f, private clone) and head: guard outcomes must
# match, and head rows carry rule, task and override. Real fm-api-key-guard-lib.sh,
# fm-send.sh (gate refusal) and fm-role.sh check (upstream-publish-role).
set -u
WT=$PWD; B=$(mktemp -d "${TMPDIR:-/tmp}/fm-r6ak.XXXXXX"); trap 'rm -rf "$B"' EXIT
git clone -q --no-checkout "$WT" "$B/base"; git -C "$B/base" checkout -q --detach 1c4e2929f
unset FM_GUARD_EVENT_LOG FM_GATE_REFUSE_BYPASS FM_TASK_ID ID
# A firstmate-lineage project with a publication target, for the role check.
git clone -q --no-checkout "$WT" "$B/proj"; git -C "$B/proj" remote set-url origin https://github.com/example/firstmate
for side in base head; do
  R=$WT; [ $side = base ] && R=$B/base
  H=$(mktemp -d "${TMPDIR:-/tmp}/fm-r6cmp.XXXXXX"); mkdir -p "$H/state" "$H/config"
  export FM_GUARD_EVENT_LOG="$H/ev.jsonl"
  ( cd "$WT" && FM_HOME="$H" "$R/bin/fm-send.sh" t hi >/dev/null 2>&1 ); a=$?
  ( . "$R/bin/fm-api-key-guard-lib.sh"; ID=ak-nowaiver ANTHROPIC_API_KEY=dummy-not-a-key fm_api_key_guard claude 0 '' 0 '' >/dev/null 2>&1 ); b=$?
  ( . "$R/bin/fm-api-key-guard-lib.sh"; ID=ak-waiver ANTHROPIC_API_KEY=dummy-not-a-key fm_api_key_guard claude 1 '' 0 '' >/dev/null 2>&1 ); c=$?
  ( . "$R/bin/fm-api-key-guard-lib.sh"; ID=ak-clean fm_api_key_guard claude 0 '' 0 '' >/dev/null 2>&1 ); d=$?
  r1=0; ID=role-user FM_HOME="$H" FM_ROOT_OVERRIDE="$B/proj" "$R/bin/fm-role.sh" check "$B/proj" >/dev/null 2>&1 || r1=$?
  r2=0; ID=role-consent FM_HOME="$H" FM_ROOT_OVERRIDE="$B/proj" "$R/bin/fm-role.sh" check "$B/proj" upstream-consent github.com/example/firstmate >/dev/null 2>&1 || r2=$?
  echo "$side: gate-refuse(non-lab fm-send)=$a api-key(no waiver)=$b api-key(--allow-api-key)=$c api-key(no key)=$d role(user, no consent)=$r1 role(task consent)=$r2"
  jq -c 'select(.guard=="claude-api-billing" or .guard=="upstream-publish-role" or .guard=="gate-agent-containment")|{guard,decision,rule,task,override,cleared_by}' "$H/ev.jsonl" 2>/dev/null | sed "s/^/  $side row: /"
  rm -rf "$H"
done
