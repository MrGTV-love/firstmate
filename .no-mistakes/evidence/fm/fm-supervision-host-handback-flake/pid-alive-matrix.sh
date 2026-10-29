#!/usr/bin/env bash
# Drive fm_pid_alive from a given fm-wake-lib.sh under the bash running this
# script. Each row: case name, expected exit, observed exit, stderr, and whether
# a caller under set -u kept running after the call.
# Usage: pid-alive-matrix.sh <fm-wake-lib.sh> <scratch dir>
set -u
lib=$1
root=$2
rm -rf "$root"; mkdir -p "$root"
printf 'bash %s  lib %s\n' "$BASH_VERSION" "$lib"
printf '%-34s %-8s %-8s %-6s %s\n' case expected got after stderr

orphan() { sh -c 'sleep 300 >/dev/null 2>&1 & echo $!'; }

probe() {  # <case> <expected> <proc root or -> <pid>
  local name=$1 want=$2 proc=$3 pid=$4 out rc after err
  out=$( { if [ "$proc" = - ]; then unset FM_PROC_ROOT_OVERRIDE; else export FM_PROC_ROOT_OVERRIDE=$proc; fi
           bash -c 'set -u; . "$1"; fm_pid_alive "$2"; rc=$?; echo "rc=$rc"; echo after' _ "$lib" "$pid"; } 2>"$root/err")
  rc=$(printf '%s\n' "$out" | sed -n 's/^rc=//p'); [ -n "$rc" ] || rc=ABORT
  case "$out" in *after*) after=yes ;; *) after=NO ;; esac
  err=$(tr '\n' ' ' < "$root/err")
  local verdict=ok; [ "$rc" = "$want" ] && [ "$after" = yes ] && [ -z "$err" ] || verdict=WRONG
  printf '%-34s %-8s %-8s %-6s %s  [%s]\n' "$name" "$want" "$rc" "$after" "${err:--}" "$verdict"
}

live=$(orphan)
mk() { mkdir -p "$root/$1/$live"; }

mk normal;  printf '%s (sleep) S 1 2 3\n' "$live" > "$root/normal/$live/stat"
probe 'live, normal stat' 0 "$root/normal" "$live"
mk zombie;  printf '%s (sleep) Z 1 2 3\n' "$live" > "$root/zombie/$live/stat"
probe 'live, stat says zombie' 1 "$root/zombie" "$live"
mk tricky;  printf '%s (a) Z)\n(b) S 1 2 3\n' "$live" > "$root/tricky/$live/stat"
probe 'live, comm with ") Z" and newline' 0 "$root/tricky" "$live"
mk empty;   : > "$root/empty/$live/stat"
probe 'live, empty stat' 0 "$root/empty" "$live"
mk dir;     mkdir "$root/dir/$live/stat"
probe 'live, stat read fails (dir)' 0 "$root/dir" "$live"
mk sock;    perl -MIO::Socket::UNIX -e 'chdir $ARGV[0] or die; IO::Socket::UNIX->new(Local=>"stat",Listen=>1) or die' "$root/sock/$live"
probe 'live, stat open fails (socket)' 0 "$root/sock" "$live"
probe 'live, no proc entry (ps path)' 0 "$root/none" "$live"

# The race itself, ordered without a clock: stat is a FIFO, so the probe passes
# kill -0 and the readability test, then blocks opening it. Only once the probe
# is inside the open does the helper kill the process, wait until it is gone,
# and close the FIFO with nothing written.
race() {  # <case> <expected> <kill: yes|no>
  local name=$1 want=$2 dokill=$3 pid
  pid=$(orphan)
  mkdir -p "$root/fifo-$dokill/$pid"; mkfifo "$root/fifo-$dokill/$pid/stat"
  ( exec 3>"$root/fifo-$dokill/$pid/stat"
    if [ "$dokill" = yes ]; then kill "$pid"; while kill -0 "$pid" 2>/dev/null; do sleep 0.01; done; fi
    exec 3>&- ) &
  probe "$name" "$want" "$root/fifo-$dokill" "$pid"
  wait
  kill "$pid" 2>/dev/null
}
race 'exits while its stat is read' 1 yes
race 'alive, stat read returns empty' 0 no

dead=$(orphan); kill "$dead"; while kill -0 "$dead" 2>/dev/null; do sleep 0.01; done
mkdir -p "$root/deaddir/$dead/stat"
probe 'dead before probe, dir stat' 1 "$root/deaddir" "$dead"

# A real unreaped zombie through the ps path.
zfile=$root/zpid
perl -e 'my $c = fork; if (!$c) { exit 0 } open my $f, ">", $ARGV[0]; print $f "$c\n"; close $f; sleep 60' "$zfile" &
zparent=$!
while [ ! -s "$zfile" ]; do sleep 0.01; done
zpid=$(cat "$zfile")
while [ "$(ps -o stat= -p "$zpid" | cut -c1)" != Z ]; do sleep 0.01; done
probe 'real zombie (ps path)' 1 - "$zpid"
kill "$zparent" "$live" 2>/dev/null
wait 2>/dev/null
rm -rf "$root"
