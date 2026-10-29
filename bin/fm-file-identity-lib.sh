#!/usr/bin/env bash
# Compare persisted device:inode[:generation] identities across a volume remount.
# The caller proves the object's remaining facts (content for PR artifacts,
# birth time and observed state for status markers) before adopting the result.
fm_file_identity_device_shifted() {  # <recorded> <current>
  local recorded=$1 current=$2 old_device new_device inode
  case "$recorded:$current" in *$'\t'*|*$'\n'*) return 1 ;; esac
  case "$recorded" in *:*) ;; *) return 1 ;; esac
  case "$current" in *:*) ;; *) return 1 ;; esac
  old_device=${recorded%%:*}; new_device=${current%%:*}
  case "$old_device" in ''|*[!0-9]*) return 1 ;; esac
  case "$new_device" in ''|*[!0-9]*) return 1 ;; esac
  inode=${recorded#*:}; inode=${inode%%:*}
  case "$inode" in ''|*[!0-9]*) return 1 ;; esac
  [ "$old_device" != "$new_device" ] && [ "${recorded#*:}" = "${current#*:}" ]
}
