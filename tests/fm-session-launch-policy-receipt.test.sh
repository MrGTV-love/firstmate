#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-launch-policy-receipt)
trap fm_test_cleanup EXIT
# shellcheck source=bin/fm-session-launch-policy-lib.sh
. "$ROOT/bin/fm-session-launch-policy-lib.sh"

for transition in first replacement addition; do
  for failure in generation key publication; do
    [ "$transition:$failure" != addition:generation ] || continue
    (
      STATE="$TMP_ROOT/$transition-$failure"
      mkdir -p "$STATE"
      FM_WAKE_QUEUE="$STATE/.wake-queue"
      FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
      # shellcheck source=bin/fm-wake-lib.sh
      . "$ROOT/bin/fm-wake-lib.sh"
      MARKER="$STATE/.session-launch-refused-worker"
      old_generation=receipt-generation-1
      next_generation=receipt-generation-2
      expected_keys=1
      expected_wakes=1
      if [ "$transition" != first ]; then
        fm_session_launch_policy_refusal_notify "$STATE" worker "$old_generation" 'check: prior refusal' 'prior error' \
          || fail 'initial refusal failed'
        cp "$MARKER" "$STATE/prior-receipt"
        expected_wakes=2
      fi
      if [ "$transition" = addition ]; then
        next_generation=$old_generation
        expected_keys=2
      fi
      inject=1
      printf() {
        if [ "$inject" = 1 ] && [ "${new:-0}" = 1 ] && [ "${1:-}" = '%s\n' ]; then
          if { [ "$failure" = generation ] && [ "${2:-}" = "$next_generation" ]; } \
            || { [ "$failure" = key ] && [ "${2:-}" = "${key:-}" ]; }; then
            builtin printf 'partial'
            return 73
          fi
        fi
        builtin printf "$@"
      }
      _fm_atomic_replace() {
        if [ "$inject" = 1 ] && [ "$failure" = publication ] && [ "$2" = "$MARKER" ]; then
          return 73
        fi
        mv -f -- "$1" "$2"
      }
      rc=0
      fm_session_launch_policy_refusal_notify "$STATE" worker "$next_generation" 'check: current refusal' 'current error' || rc=$?
      [ "$rc" = 1 ] || fail "$transition $failure did not reject failed receipt publication"
      [ -z "$FM_SESSION_LAUNCH_REFUSAL_WAKE" ] || fail 'failed receipt exposed a successful notification'
      if [ "$transition" = first ]; then
        [ ! -e "$MARKER" ] && [ ! -L "$MARKER" ] || fail 'failed first write published a partial receipt'
      else
        cmp -s "$STATE/prior-receipt" "$MARKER" || fail 'failed write damaged the prior receipt'
      fi
      [ ! -e "$FM_WAKE_QUEUE_LOCK" ] && [ ! -L "$FM_WAKE_QUEUE_LOCK" ] || fail 'failed write retained the queue lock'
      for staged in "$MARKER".tmp.*; do
        [ ! -e "$staged" ] || fail 'failed write retained its staging file'
      done
      [ "$(fm_wake_queued_keys check | wc -l | tr -d ' ')" = "$expected_wakes" ] \
        || fail 'receipt failure lost or duplicated the queued refusal'
      inject=0
      fm_session_launch_policy_refusal_notify "$STATE" worker "$next_generation" 'check: current refusal' 'current error' \
        || fail 'receipt could not be published after storage recovered'
      [ -z "$FM_SESSION_LAUNCH_REFUSAL_WAKE" ] || fail 'receipt repair duplicated notification of the queued refusal'
      awk -v generation="$next_generation" -v keys="$expected_keys" '
        NR == 1 { if ($0 != generation) exit 1; next }
        { if (index($0, "session-launch-refused-worker-" generation "-") != 1) exit 1; count++ }
        END { if (count != keys) exit 1 }
      ' "$MARKER" || fail 'repaired receipt did not contain its complete generation and key set'
      fm_session_launch_policy_refusal_notify "$STATE" worker "$next_generation" 'check: current refusal' 'current error' \
        || fail 'published receipt did not deduplicate the next refusal'
      [ -z "$FM_SESSION_LAUNCH_REFUSAL_WAKE" ] || fail 'published receipt repeated the notification'
      [ "$(fm_wake_queued_keys check | wc -l | tr -d ' ')" = "$expected_wakes" ] \
        || fail 'receipt repair enqueued a duplicate refusal'
      pass "$transition receipt survives $failure failure and recovers without duplicate wakes"
    )
  done
done
