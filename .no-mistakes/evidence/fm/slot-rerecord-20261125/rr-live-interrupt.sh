#!/usr/bin/env bash
# Live interruption: TERM a real write run (started here, in the background) at a chosen delay, then inspect the record
# and audit records, then run the write again and require a consistent end state.
E=$(cd "$(dirname "$0")" && pwd)
. "$E/rr-live-lib.sh"
cd "$WT_ROOT" || exit 1
state_of_record() {
  local s; s=$(meta_sha)
  if [ "$s" = "$PRIOR" ]; then echo prior; elif slot_lines | grep -qx "slot_base_sha=$M1"; then echo renewed; else echo "other($s)"; fi
}
for d in "$@"; do
  fixture; renew
  PRIOR=$(meta_sha)
  say "T delay=${d}s: TERM a write run"
  ( unset FM_TASK_ID FM_SUPERVISION_ACTOR; exec ${XTRACE:+bash -x} "$CONTROL" "$RR_ID" rerecord-slot --manifest-sha "$(msha)" --note "$NOTE" ) > "$FX/run.out" 2>&1 &
  if [ "$d" = adopt ]; then
    # wait until the post-publish adoption check opens its stderr file inside the run's private snapshot directory,
    # keep a hard link to that file (the trap later removes the directory), then TERM at once
    i=0; f=
    t0=$SECONDS
    while [ -z "$f" ] && [ $((SECONDS - t0)) -lt 40 ]; do
      for g in "$FM_HOME/state/.$RR_ID.meta.rerecord-snap."*/adopt-err; do [ -e "$g" ] && [ "$(meta_sha)" != "$PRIOR" ] && f=$g; done
      i=$((i+1))
    done
    ln "$f" "$FX/adopt-err.link" && echo "linked $f"
  elif [ "${d%%+*}" = pub ]; then
    # wait until the task record's bytes change (this run's publish landed), then TERM at once
    i=0; while [ "$(meta_sha)" = "$PRIOR" ] && [ $i -lt 6000 ]; do sleep 0.005; i=$((i+1)); done
    echo "record changed after $i polls"
    case "$d" in pub+*) sleep "${d#pub+}"; echo "then waited ${d#pub+}s" ;; esac
  else
    sleep "$d"
  fi
  kill -TERM $! 2>/dev/null && echo "sent TERM" || echo "run had already exited"
  wait $!; echo "interrupted run exit=$?"
  if [ -n "${XTRACE:-}" ]; then cp "$FX/run.out" "$E/xtrace-$d.txt"; grep -v '^+' "$FX/run.out"; else
  echo "--- raw interrupted-run output ($(wc -c < "$FX/run.out" | tr -d ' ') bytes):"; cat "$FX/run.out"; echo "--- end raw"; fi
  [ ! -e "$FX/adopt-err.link" ] || { echo "--- bytes the trap wrote into the snapshot's adopt-err file (hard link kept after the trap removed it):"; cat "$FX/adopt-err.link"; echo "--- end adopt-err"; }
  echo "record after interrupt: $(state_of_record)"
  for a in "$(audit_dir)"/*.record; do [ -e "$a" ] && echo "audit $(basename "$a") result=$(sed -n 's/^result=//p' "$a")"; done
  echo "temporaries: $(ls -a "$FM_HOME/state" | grep -E "^\.$RR_ID\.(meta\.rerecord|rerecord-)" | tr '\n' ' ')"
  say "T delay=${d}s: the next write run"
  rr --manifest-sha "$(msha)" --note "$NOTE" | grep -v '^added_\|^rule_c\|^scope_split'
  echo "record after next run: $(state_of_record)"
  for a in "$(audit_dir)"/*.record; do [ -e "$a" ] && echo "audit $(basename "$a") result=$(sed -n 's/^result=//p' "$a")"; done
  pend=$(grep -l '^result=\(pending\|rolling-back\)$' "$(audit_dir)"/*.record 2>/dev/null | wc -l | tr -d ' ')
  echo "OPEN_AUDITS_AFTER_NEXT_RUN=$pend"
  cleanup_fixture
done
