#!/usr/bin/env bash
# Relaunch a REMOTE secondmate onto a new harness, model, or effort, then
# republish this parent's own route record to match what the host confirmed.
#
# Usage: fm-remote-secondmate-relaunch.sh <id> <harness> <model|default|-> <effort|default|->
#
# bin/fm-remote-secondmate-control.sh's relaunch verb runs entirely on the
# secondmate's own host and can only rewrite that host's own endpoint record;
# this parent's route record (state/<id>.meta here, marked remote_host=... to
# a different machine) is a separate file that verb has no access to. Running
# the relaunch alone therefore leaves this file naming the runtime the mate
# used to run, not the one it runs now.
#
# This wrapper is the missing other half. It runs the host-local relaunch
# through bin/fm-on.sh exactly as secondmate-provisioning documents, then reads
# the confirmed harness, model, and effort back out of the endpoint's own
# route report - the same read-back-from-the-endpoint shape bin/fm-spawn.sh
# already uses when it first records a remote route - and republishes this
# home's own metadata to match. A failed or refused relaunch leaves this
# parent's record untouched.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-compact-adviser-lib.sh
. "$SCRIPT_DIR/fm-compact-adviser-lib.sh"
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-secondmate-nudge-lib.sh
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ "$#" -eq 4 ] || usage
ID=$1
HARNESS=$2
MODEL=$3
EFFORT=$4
case "$ID" in ''|*[!A-Za-z0-9._-]*) die "invalid secondmate id: $ID" ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "no metadata for $ID at $META"
REMOTE_HOST=$(fm_meta_get "$META" remote_host)
[ -n "$REMOTE_HOST" ] \
  || die "task $ID is not a remotely placed secondmate; use bin/fm-control.sh $ID relaunch instead"

REMOTE_LOCK=$(fm_remote_inherit_transaction_lock_path "$STATE" "$ID") \
  || die "cannot resolve the remote inheritance transaction lock"
fm_lock_acquire_wait "$REMOTE_LOCK" || die "cannot lock the remote inheritance transaction"
PAIR_DIR=
trap 'fm_lock_release "$REMOTE_LOCK" || true; [ -z "$PAIR_DIR" ] || rm -rf -- "$PAIR_DIR"' EXIT
PAIR_DIR=$(mktemp -d "$STATE/.remote-relaunch-pair.XXXXXX") \
  || die "cannot stage the remote relaunch routing pair"
fm_config_inherit_pair_stage "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}" "$PAIR_DIR" 1 \
  || die "cannot stage the remote relaunch routing pair"
fm_config_inherit_pair_valid "$PAIR_DIR" || die "the remote relaunch routing pair is incoherent"
case "$MODEL" in
  -|default) ;;
  *) MODEL=$(FM_CONFIG_OVERRIDE="$PAIR_DIR" \
    "$SCRIPT_DIR/fm-model-index.sh" model "$HARNESS" "$MODEL") || exit $? ;;
esac
GENERATION=$(fm_remote_inherit_generation_next "$STATE" "$ID") \
  || die "cannot publish the remote inheritance generation"
REMOTE_MARKER=$(fm_secondmate_nudge_marker_path "$STATE" "$ID") \
  || die "cannot resolve the remote reread marker"
fm_secondmate_nudge_write "$STATE" "$ID" "$(fm_meta_get "$META" home)" "" remote \
  "$FM_REMOTE_SECOND_MATE_NUDGE_MESSAGE" 1 \
  || die "cannot record the remote reread marker"
if INHERIT_OUT=$(FM_CONFIG_INHERIT_PAIR_DIR="$PAIR_DIR" FM_CONFIG_INHERIT_LIVE=1 \
  "$SCRIPT_DIR/fm-remote-inherit-push.sh" "$ID" "$GENERATION" 2>&1); then
  :
else
  rc=$?
  printf '%s\n' "$INHERIT_OUT" >&2
  printf 'error: remote inheritance refused; the running secondmate was not relaunched\n' >&2
  exit "$rc"
fi

RELAUNCH_ARGS=("$ID" "$HARNESS" "$MODEL" "$EFFORT")
if [ "$(fm_compact_adviser_force_off)" = 1 ]; then
  RELAUNCH_ARGS+=(--compact-adviser-disable)
fi
RELAUNCH_OUT=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh \
  relaunch "${RELAUNCH_ARGS[@]}" </dev/null 2>&1) || {
  rc=$?
  printf '%s\n' "$RELAUNCH_OUT" >&2
  exit "$rc"
}
printf '%s\n' "$RELAUNCH_OUT"

# The confirmed identity comes from the route block the host prints after a
# successful relaunch, never from the human-readable "relaunched ..." summary
# line: a relaunch onto "default" prints that literal word there, while the
# endpoint's own record - and this parent's, to match it - store an empty
# field for "no explicit pin".
[ "$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^schema=//p' | tail -1)" \
  = fm-remote-secondmate-control.v1 ] \
  || die "the host relaunched $ID but reported no route confirmation to record"
NEW_HARNESS=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^harness=//p' | tail -1)
NEW_MODEL=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^model=//p' | tail -1)
NEW_EFFORT=$(printf '%s\n' "$RELAUNCH_OUT" | sed -n 's/^effort=//p' | tail -1)
[ -n "$NEW_HARNESS" ] || die "the host's route confirmation carried no harness to record"

META_LOCK=$(fm_meta_lock_path "$META") || die "metadata lock path is invalid for $ID"
fm_lock_acquire_wait "$META_LOCK"
META_TMP=$(mktemp "$STATE/.fm-remote-relaunch-meta.XXXXXX") || {
  fm_lock_release "$META_LOCK"
  die "cannot stage the updated record"
}
{
  printf 'harness=%s\n' "$NEW_HARNESS"
  printf 'model=%s\n' "$NEW_MODEL"
  printf 'effort=%s\n' "$NEW_EFFORT"
} >> "$META_TMP"
# Every other line is preserved in its original relative order after the
# refreshed harness/model/effort. A pr= line's own identity block (pr_head=
# and the x_* fields fm_pr_metadata_identity_parse allows after it) must stay
# LAST in the record: that parser rejects any other key following pr=, so
# writing harness/model/effort after it would break PR movement monitoring on
# a task that already had one armed.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    harness=*|model=*|effort=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" ;;
  esac
done < "$META"
chmod 0600 "$META_TMP"
mv -f -- "$META_TMP" "$META"
fm_lock_release "$META_LOCK"
rm -f -- "$REMOTE_MARKER"
