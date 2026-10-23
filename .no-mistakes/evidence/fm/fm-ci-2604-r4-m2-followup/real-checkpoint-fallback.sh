#!/bin/bash
set -eu
ROOT=$1
WORK=$2
TIMEOUT=$3
GTimeout=$4
mkdir -p "$WORK/perl-lib" "$WORK/tools"
printf 'die "live probe: POSIX module unavailable\\n";\n' > "$WORK/perl-lib/POSIX.pm"
ln -s "$(command -v python3)" "$WORK/tools/python3"
if command -v jq >/dev/null; then ln -s "$(command -v jq)" "$WORK/tools/jq"; fi
for fallback in timeout gtimeout; do
  home="$WORK/$fallback-home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  printf 'done: disposable real watcher wake via %s\n' "$fallback" > "$home/state/fallback-proof.status"
  touch -t 200001010000 "$home/state/fallback-proof.status"
  if [ "$fallback" = timeout ]; then executable=$TIMEOUT; else executable=$GTimeout; fi
  printf '#!/bin/bash\nprintf "selected: %s\\n" >> "$FM_FALLBACK_LOG"\nexec %q "$@"\n' "$fallback" "$executable" > "$WORK/tools/$fallback"
  chmod +x "$WORK/tools/$fallback"
  printf '\n=== real checkpoint with unusable POSIX and %s only ===\n' "$fallback"
  PATH="$WORK/tools:/usr/bin:/bin:/usr/sbin:/sbin" PERL5LIB="$WORK/perl-lib" perl -e 'print "Perl executable still works\n"'
  if PATH="$WORK/tools:/usr/bin:/bin:/usr/sbin:/sbin" PERL5LIB="$WORK/perl-lib" perl -MPOSIX=:sys_wait_h -e 'exit 0'; then
    echo 'broken module setup was not effective' >&2; exit 1
  fi
  status=0
  PATH="$WORK/tools:/usr/bin:/bin:/usr/sbin:/sbin" PERL5LIB="$WORK/perl-lib" \
    FM_FALLBACK_LOG="$home/selected-tool.log" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_PROCEVENT_CLAIM_ROOT="$WORK/claims" \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 5 > "$home/stdout" 2> "$home/stderr" || status=$?
  printf 'checkpoint exit=%s\n' "$status"
  cat "$home/stdout" "$home/stderr"
  cat "$home/selected-tool.log"
  [ "$status" -eq 0 ]
  grep -q '^signal: .*fallback-proof.status' "$home/stdout"
  [ ! -e "$home/state/.watch.lock/pid" ]
  printf 'persisted wake queue:\n'
  cat "$home/state/.wake-queue"
  printf 'watcher lock released=yes\n'
  rm "$WORK/tools/$fallback"
done
