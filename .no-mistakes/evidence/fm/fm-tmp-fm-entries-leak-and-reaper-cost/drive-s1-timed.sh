#!/usr/bin/env bash
# Live drive: real bin/fm-timeout-lib.sh fm_run_timed in an empty TMPDIR, with
# the host's mechanism (timeout) and the bash fallback
# (FM_TIMEOUT_MECHANISM_OVERRIDE=bash, prefix fm-bash-timeout-command).
# Signalled callers start with INT/HUP/TERM at their default action (perl resets
# INT, which a background job of a non-interactive shell would otherwise ignore).
set -u
WT=$1; SB=$(mktemp -d /tmp/fmnm-s1.XXXXXX) || exit 1
case "$SB" in /tmp/fmnm-s1.*) ;; *) exit 1 ;; esac
export TMPDIR=$SB/t; mkdir -p "$TMPDIR"
count() { printf 'entries in TMPDIR: %s  [%s]\n' "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" "$(cd "$TMPDIR" && find . -mindepth 1 | tr '\n' ' ')"; }
for mech in host bash; do
  if [ "$mech" = bash ]; then export FM_TIMEOUT_MECHANISM_OVERRIDE=bash; else unset FM_TIMEOUT_MECHANISM_OVERRIDE; fi
  echo "===== mechanism: $(bash -c ". $WT/bin/fm-timeout-lib.sh; fm_timeout_mechanism")"
  echo "--- normal run (true)"; bash -c ". $WT/bin/fm-timeout-lib.sh; fm_run_timed 5 true"; echo "rc=$?"; count
  echo "--- error exit (exit 3)"; bash -c ". $WT/bin/fm-timeout-lib.sh; fm_run_timed 5 bash -c 'exit 3'"; echo "rc=$?"; count
  echo "--- bound fires (sleep 5 with 1s bound)"; bash -c ". $WT/bin/fm-timeout-lib.sh; fm_run_timed 1 sleep 5"; echo "rc=$?"; count
  for sig in TERM INT HUP; do
    echo "--- caller gets $sig while waiting"
    perl -e '$SIG{INT}=$SIG{HUP}=$SIG{TERM}="DEFAULT"; exec @ARGV or die' bash -c ". $WT/bin/fm-timeout-lib.sh; fm_run_timed 30 sleep 30" & p=$!
    sleep 1; kill -$sig $p; wait $p; echo "rc=$?"; sleep 1; count
  done
done
unset FM_TIMEOUT_MECHANISM_OVERRIDE
echo "===== KILL between the status file's creation and its unlink (the lib's own pieces hold the entry)"
bash -c ". $WT/bin/fm-timeout-lib.sh; f=\$(fm_scratch_new f fm-timeout-status); echo held \$f; kill -KILL \$\$"; echo "rc=$?"; count
echo "--- next fm_run_timed reaps what the killed owner left"; bash -c ". $WT/bin/fm-timeout-lib.sh; fm_run_timed 5 true"; echo "rc=$?"; count
echo "--- a live owner's entry is kept"
bash -c ". $WT/bin/fm-timeout-lib.sh; f=\$(fm_scratch_new f fm-timeout-status); echo held \$f; sleep 4" & p=$!; sleep 1
bash -c ". $WT/bin/fm-timeout-lib.sh; fm_run_timed 5 true"; echo "rc=$?"; count; kill $p; wait $p 2>/dev/null
rm -rf -- "$SB"
