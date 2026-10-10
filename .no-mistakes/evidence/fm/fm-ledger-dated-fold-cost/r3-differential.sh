#!/bin/bash
# r3-differential.sh <base-bin> <target-bin> <scratch>: every changed reader on the tricky log, old vs new, in two locales.
base=$1 target=$2 scratch=$3 here=$(dirname "$0")
for loc in en_US.UTF-8 C; do
  for side in base target; do
    d=$scratch/$loc/$side; mkdir -p "$d/state"
    /bin/bash "$here/make-tricky-log.sh" > "$d/state/tricky.status"
  done
  run() {  # <label> <function> <args after the file...>
    local label=$1 fn=$2; shift 2
    for side in base target; do
      eval "bindir=\$$side"; d=$scratch/$loc/$side
      ( cd "$d" && LC_ALL=$loc FM_HOME=$d /bin/bash "$here/r3-call-lib.sh" "$bindir" "$fn" "$d/state/tricky.status" "$@" ) > "$d/$label.out" 2> "$d/$label.err"
      echo $? >> "$d/$label.out.rc"
    done
    if cmp -s "$scratch/$loc/base/$label.out" "$scratch/$loc/target/$label.out" && cmp -s "$scratch/$loc/base/$label.out.rc" "$scratch/$loc/target/$label.out.rc"; then
      printf '%-12s %-44s IDENTICAL to base (%s bytes, exit %s)\n' "$loc" "$label" "$(wc -c < "$scratch/$loc/target/$label.out" | tr -d ' ')" "$(tail -1 "$scratch/$loc/target/$label.out.rc")"
    else
      printf '%-12s %-44s DIFFERS from base\n' "$loc" "$label"; diff <(cat -v "$scratch/$loc/base/$label.out") <(cat -v "$scratch/$loc/target/$label.out")
    fi
  }
  run status_open_decisions status_open_decisions
  run status_open_decisions_dated status_open_decisions_dated
  run status_own_open_decisions status_own_open_decisions
  run status_open_decisions_incremental status_open_decisions_incremental
  run status_open_activities status_open_activities
  run status_has_open_needs_decision status_has_open_needs_decision
  for key in a b c re zz head.key headXkey tabby pending-reply-x1 last; do run "status_key_closing_verb[$key]" status_key_closing_verb "$key"; done
done
echo "--- target output, en_US.UTF-8 (cat -v) ---"
for f in status_open_decisions status_open_decisions_dated; do echo "[$f]"; cat -v "$scratch/en_US.UTF-8/target/$f.out"; echo; done
