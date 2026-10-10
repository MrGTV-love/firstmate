#!/usr/bin/env bash
# Claude PostToolUse hook for captured, unhandled firstmate-owned Lavish replies.
# Usage: fm-procevent-posttool-check.sh
# In a genuine primary home, only the session-lock owner refreshes the source
# owner lease and receives one line of additional context while replies wait.
# Its helper agents' events refresh that lease too, but never receive the notice.
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
HELPER=0
printf '%s' "$PAYLOAD" | perl -MJSON::PP=decode_json -e '
  local $/;
  my $payload = eval { decode_json(<STDIN>) };
  exit(ref($payload) eq "HASH" && exists($payload->{agent_id}) ? 0 : 1);
' 2>/dev/null && HELPER=1
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
[ "$HELPER" -eq 0 ] || exit 0

perl -MJSON::PP=encode_json -MEncode=decode,FB_CROAK -MFile::Spec -e '
  use strict;
  use warnings;
  my ($state, $home, $root, $scripts) = map { File::Spec->rel2abs($_) } @ARGV;
  my $quote = sub {
    my $value = shift;
    $value = decode("UTF-8", $value, FB_CROAK);
    $value =~ s/\x27/\x27\x22\x27\x22\x27/g;
    return chr(39) . $value . chr(39);
  };
  my $selectors = "FM_HOME=" . $quote->($home)
    . " FM_STATE_OVERRIDE=" . $quote->($state)
    . " FM_ROOT_OVERRIDE=" . $quote->($root) . " ";
  my $drain = $selectors . $quote->("$scripts/fm-wake-drain.sh");
  my $read = $selectors . $quote->("$scripts/fm-procevent-lavish.sh") . " read ";
  my $handled = $selectors . $quote->("$scripts/fm-procevent.sh") . " handled ";
  my $dir = "$state/procevent-inbox";
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
    my $notice = "A captured Lavish result is waiting: $id $sequence. Run `$drain` now. ";
    $notice .= "If the drain has no row for this result, read it directly with `";
    $notice .= $read . $quote->("$base.result") . "`. ";
    $notice .= "Handle the result, then acknowledge it with `$handled$id $sequence` before continuing.";
    print encode_json({ hookSpecificOutput => { hookEventName => "PostToolUse", additionalContext => $notice } }), "\n";
    last;
  }
' "$STATE" "$FM_HOME" "$FM_ROOT" "$SCRIPT_DIR" 2>/dev/null
exit 0
