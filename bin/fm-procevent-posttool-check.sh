#!/usr/bin/env bash
# Claude PostToolUse hook for captured, unhandled firstmate-owned Lavish replies.
# Usage: fm-procevent-posttool-check.sh
# In a genuine primary home, only the session-lock owner refreshes the source
# owner lease and receives one line of additional context while replies wait.
# No network, runner launches, wake draining, or result payload reads occur.
# Directory entries and acknowledgement/owner markers determine pending replies;
# only a candidate's adapter sidecar is read, capped at 16 bytes.
# Empty homes, handled replies, worker-owned rounds, and foreign hosts are silent.
set -u

[ "$#" -eq 0 ] || exit 2
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

PAYLOAD=$(cat 2>/dev/null || true)
[ -z "${GROK_AGENT:-}${GROK_HOOK_EVENT:-}" ] || exit 0
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fm_session_lock_owned_by_self "$STATE" || exit 0
[ "${FM_PROCEVENT_IN_RUNNER:-0}" != 1 ] || exit 0
[ ! -e "$STATE/.afk" ] || exit 0
# Active primary tools prove owner presence even between Stop-owned watch cycles.
if fm_procevent_any_registered "$STATE"; then
  fm_procevent_owner_lease_touch "$STATE" 2>/dev/null || true
fi

perl -MJSON::PP=encode_json -MEncode=decode,FB_CROAK -e '
  use strict;
  use warnings;
  my $dir = "$ARGV[0]/procevent-inbox";
  -d $dir && !-l $dir or exit 0;
  opendir my $entries, $dir or exit 0;
  while (my $name = readdir $entries) {
    $name =~ /\A(lavish-[a-zA-Z0-9_-]+)\.([0-9]+)\.result\z/ or next;
    my ($id, $sequence) = ($1, $2);
    next if length($id) > 64;
    my $base = "$dir/$id.$sequence";
    next unless -f "$base.result" && !-l "$base.result";
    next if -e "$base.handled" || -l "$base.handled";
    next if -e "$base.owner-task" || -l "$base.owner-task";
    next unless -f "$base.adapter" && !-l "$base.adapter";
    open my $adapter, "<", "$base.adapter" or next;
    read($adapter, my $kind, 16) or next;
    close $adapter;
    next unless $kind eq "lavish\n";
    my $result = decode("UTF-8", "$base.result", FB_CROAK);
    $result =~ s/\x27/\x27\x22\x27\x22\x27/g;
    my $quoted_result = chr(39) . $result . chr(39);
    my $notice = "Captured Lavish feedback is waiting: $id $sequence. Run bin/fm-wake-drain.sh now. ";
    $notice .= "If the drain has no row for this result, read it directly with bin/fm-procevent-lavish.sh read ";
    $notice .= $quoted_result . ". ";
    $notice .= "Handle the feedback, then acknowledge it with bin/fm-procevent.sh handled $id $sequence before continuing.";
    print encode_json({ hookSpecificOutput => { hookEventName => "PostToolUse", additionalContext => $notice } }), "\n";
    last;
  }
' "$STATE" 2>/dev/null
exit 0
