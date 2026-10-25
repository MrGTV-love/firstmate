#!/usr/bin/env bash
# Model-free stand-in for a harness CLI: runs the lab plan for its task, then idles.
name=$(basename "$0")
case "${1:-}" in
  --version) case "$name" in omp) echo 'omp/18.12.6' ;; claude) echo '2.1.310 (Claude Code)' ;; codex) echo 'codex-cli 1.0.0' ;; esac; exit 0 ;;
esac
case " $* " in *" models "*) echo '[]'; exit 0 ;; esac
[ -n "${FM_TASK_INBOX:-}" ] || exit 0
id=$(basename "$FM_TASK_INBOX" .inbox)
if [ -f "/private/tmp/fm-lab-uh.FX2EML/plans/$id.sh" ]; then
  bash "/private/tmp/fm-lab-uh.FX2EML/plans/$id.sh" "$name" "$@" > "/private/tmp/fm-lab.gTPwcx/data/$id/probe.txt" 2>&1
fi
echo "stand-in $name for $id: plan done; idling"
exec sleep 3600
