#!/bin/bash
# <tree> : print each changed lib's resolved directory for several path forms
tree=$1
pairs="fm-afk-contract.sh:FM_AFK_CONTRACT_DIR fm-backend.sh:FM_BACKEND_LIB_DIR fm-backlog-transition-lib.sh:_FM_BACKLOG_TRANSITION_LIB_DIR fm-duration-lib.sh:FM_DURATION_HELPER fm-merge-authority-lib.sh:_FM_MERGE_AUTHORITY_LIB_DIR fm-merge-outcome-lib.sh:_FM_MERGE_OUTCOME_LIB_DIR fm-pending-reply-lib.sh:_FM_PENDING_REPLY_LIB_DIR fm-procevent-lib.sh:FM_PROCEVENT_LIB_ROOT fm-push-transition-lib.sh:FM_PUSH_TRANSITION_LIB_DIR fm-secondmate-liveness-lib.sh:FM_SM_LIVE_LIB_DIR fm-task-inbox-lib.sh:_FM_TASK_INBOX_LIB_DIR fm-x-lib.sh:_FM_X_LIB_DIR fm-marker-lib.sh:_FM_MARKER_LIB_DIR"
rm -f "$tree/../binlink"; ln -s "$tree/bin" "$tree/../binlink"
for p in $pairs; do f=${p%%:*} v=${p#*:}
  for form in abs rel dot bare link dslash; do
    case $form in
      abs) cwd=/ path="$tree/bin/$f" ;;
      rel) cwd=$tree path="bin/$f" ;;
      dot) cwd=$tree/bin path="./$f" ;;
      bare) cwd=$tree/bin path="$f" ;;
      link) cwd=/ path="$tree/../binlink/$f" ;;
      dslash) cwd=$tree path="bin//$f" ;;
    esac
    out=$(cd "$cwd" && bash -c 'set -x 2>/dev/null; set +x; . "$1" >/dev/null 2>&1; eval "printf %s \"\${$2-UNSET-or-unset-after-source}\""' _ "$path" "$v" 2>/dev/null)
    printf '%s %s %s=%s\n' "$f" "$form" "$v" "${out//$tree/TREE}"
  done
done
rm -f "$tree/../binlink"
