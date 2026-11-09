#!/usr/bin/env bash
# Authenticated custom checks normally report latest state under their check path.
# The watcher sets FM_CHECK_EVENT_OUTPUT=1 for an authenticated check invocation.
# Event producers may then print one `fm-check-event <identity><TAB><payload>` line
# per event, with a stable nonempty [A-Za-z0-9._-] identity. Identity excludes
# changing presentation metadata such as queued counts. Ordinary output keeps
# latest-state semantics; events use <check-path>#event:<identity> as opaque keys.
# Only the existing queue/drain owns presentation, actor claims and acknowledgement.

FM_CUSTOM_CHECK_HASH=
FM_CUSTOM_CHECK_SNAPSHOT=

fm_custom_check_sha256() {
  local file=$1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

fm_custom_check_trust_read() {
  local state=$1 id=$2 trust state_device version hash
  FM_CUSTOM_CHECK_HASH=
  fm_pr_task_id_valid "$id" || return 1
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  trust="$state/$id.check-trust"
  fm_pr_private_file_valid "$trust" 600 "$state_device" || return 1
  exec 9< "$trust" || return 1
  IFS= read -r version <&9 || { exec 9<&-; return 1; }
  IFS= read -r hash <&9 || { exec 9<&-; return 1; }
  if IFS= read -r _extra <&9; then
    exec 9<&-
    return 1
  fi
  exec 9<&-
  [ "$version" = fm-custom-check-v1 ] || return 1
  [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  FM_CUSTOM_CHECK_HASH=$hash
}

fm_custom_check_registered() {
  local state=$1 id=$2 check hash state_device
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  hash=$(fm_custom_check_sha256 "$check") || return 1
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ]
}

fm_custom_check_snapshot_prepare() {
  local state=$1 id=$2 check hash state_device
  fm_custom_check_snapshot_cleanup
  check="$state/$id.check.sh"
  fm_custom_check_trust_read "$state" "$id" || return 1
  state_device=$(fm_pr_file_device "$state") || return 1
  fm_pr_private_file_valid "$check" 700 "$state_device" || return 1
  FM_CUSTOM_CHECK_SNAPSHOT=$(mktemp "$state/.fm-custom-check.XXXXXX") || return 1
  cp "$check" "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  chmod 0600 "$FM_CUSTOM_CHECK_SNAPSHOT" || { fm_custom_check_snapshot_cleanup; return 1; }
  [ -f "$FM_CUSTOM_CHECK_SNAPSHOT" ] && [ ! -L "$FM_CUSTOM_CHECK_SNAPSHOT" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_mode "$FM_CUSTOM_CHECK_SNAPSHOT")" = 600 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_device "$FM_CUSTOM_CHECK_SNAPSHOT")" = "$state_device" ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$(fm_pr_file_link_count "$FM_CUSTOM_CHECK_SNAPSHOT")" = 1 ] \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  hash=$(fm_custom_check_sha256 "$FM_CUSTOM_CHECK_SNAPSHOT") \
    || { fm_custom_check_snapshot_cleanup; return 1; }
  [ "$hash" = "$FM_CUSTOM_CHECK_HASH" ] || { fm_custom_check_snapshot_cleanup; return 1; }
}

fm_custom_check_snapshot_cleanup() {
  [ -z "$FM_CUSTOM_CHECK_SNAPSHOT" ] || rm -f -- "$FM_CUSTOM_CHECK_SNAPSHOT"
  FM_CUSTOM_CHECK_SNAPSHOT=
}

FM_CHECK_WAKE_REASON=
fm_check_queue_output() {  # <check-path> <captured-output>
  local check=$1 output=$2 line event payload reason malformed=0 state_output=
  FM_CHECK_WAKE_REASON=
  while IFS= read -r line; do
    case "$line" in
      'fm-check-event '*)
        event=${line#fm-check-event }
        case "$event" in
          *$'\t'*) payload=${event#*$'\t'}; event=${event%%$'\t'*} ;;
          *) event= ;;
        esac
        case "$event" in
          ''|*[!A-Za-z0-9._-]*)
            echo "error: malformed event output from $check" >&2
            malformed=$((malformed + 1))
            continue
            ;;
        esac
        reason="check: $check: $payload"
        fm_wake_append check "$check#event:$event" "$reason" || return 1
        [ -n "$FM_CHECK_WAKE_REASON" ] || FM_CHECK_WAKE_REASON=$reason
        ;;
      *)
        [ -z "$state_output" ] || state_output="$state_output"$'\n'
        state_output="$state_output$line"
        ;;
    esac
  done <<EOF
$output
EOF
  if [ "$malformed" -gt 0 ]; then
    [ -z "$state_output" ] || state_output="$state_output"$'\n'
    state_output="${state_output}refused $malformed malformed fm-check-event line(s)"
  fi
  if [ -n "$state_output" ]; then
    reason="check: $check: $state_output"
    fm_wake_append check "$check" "$reason" || return 1
    [ -n "$FM_CHECK_WAKE_REASON" ] || FM_CHECK_WAKE_REASON=$reason
  fi
  return 0
}
