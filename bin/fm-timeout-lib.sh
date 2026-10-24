#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks), and a command killed by
#       signal n, which reports 128+n on every mechanism - so a SIGKILLed child
#       is 137 and a SIGTERMed one 143, never the 0 a caller would read as
#       success. A signal-death status the wrapper records while the runner
#       already reports the bound is the bound's own TERM, not the command's
#       exit, and is reported as 124 too. Only 137 raised by GNU/BSD timeout's
#       own KILL escalation, with no status recorded by the bounded command,
#       also collapses into 124: there it means the bound fired, not that the
#       command chose to die.
#
#   fm_exec_timed <seconds> <grace-seconds> <command> [args...]
#       Replaces the calling shell with the bounded command, so it must be the
#       last command of a subshell: the bound kills the command, not the
#       caller. The command runs in its own process group; TERM goes to that
#       group at the bound, and KILL once <grace-seconds> more have passed,
#       for a command that ignores TERM or is mid-way through work it will not
#       abandon. A TERM, INT, or HUP delivered to the bounding process is
#       forwarded to the group and starts the same grace. The perl watchdog
#       also starts that escalation when its own parent dies before it could
#       be signalled (an owner torn down by an outer group-kill cannot leave
#       the bounded subtree orphaned behind it). The owner is captured before
#       the watchdog starts: FM_EXEC_TIMED_OWNER_PID when the caller names it,
#       else the calling script ($$) when fm_exec_timed runs in a subshell,
#       else the shell's parent. The escalation starts once that owner is gone
#       or the watchdog's parent changes, so an owner that dies while the
#       watchdog is still starting is detected too. The timeout/gtimeout
#       fallback does not track the owner: it bounds the command only by its
#       deadline and grace, so owner death alone does not stop the command.
#       Exit status is the command's own, except 124 (the bound was hit) or
#       137 (GNU timeout's status when its KILL had to fire); fm_timed_out
#       accepts both. The seconds and grace values must be positive integers
#       (125 otherwise). The perl watchdog is
#       preferred: once termination has begun it also KILLs whatever the group
#       left behind, so a descendant that outlives the command and holds its
#       output cannot keep a capturing caller waiting, and GNU timeout, the
#       fallback, cannot be followed by that reap from a replaced shell. A
#       descendant that moves into a process group of its own is outside both
#       signals and the reap (the Claude and Pi CLIs do this for every tool
#       command they run), so it ends only through the command's own TERM
#       handling; that is what the grace is for, and a command KILLed after
#       the grace can leave such a descendant running. With
#       no perl, timeout, or gtimeout on the host it refuses with 127 rather
#       than run unbounded: there is no bash fallback, because a monitor-mode
#       watchdog cannot replace the caller.
#
#   fm_timed_out <status>
#       0 iff <status> is how fm_run_timed or fm_exec_timed reports the bound.
#
#   fm_timeout_perl_bound <seconds> <command> [args...]
#       The perl hard bound itself, with fm_run_timed's status contract and its
#       stdin, stdout, and stderr passed straight through to the command. Both
#       fm_run_timed's perl arm and fm-nm-run-lib.sh's fm_nm_bounded call it, so
#       the perl bound has exactly one owner. It stops the command group with
#       TERM then KILL after 0.2 seconds on expiry (124), or on TERM (143),
#       INT (130), or HUP (129) delivered to the bounding process.
#       The watchdog occupies a separate group from both caller and command;
#       loss of the calling shell (${BASHPID:-$$}) or a changed parent starts
#       the same cleanup with status 143. This lets an inner watchdog finish
#       cleanup even when an outer bound KILLs the caller's group.
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four fm_run_timed mechanisms terminate the whole process GROUP, not just
# the direct child, so descendants that stay in that group cannot outlive its
# cleanup. GNU/BSD `timeout` does this by default because it does not run the
# command in the foreground process group; the perl fallback does it explicitly
# with setpgrp plus a negative pid, and the bash fallback uses monitor mode.
# A descendant that creates another group needs its own owner-death cleanup
# (as a nested Perl watchdog has); group signals alone cannot reach it.
set -u

# fm_run_progress <no-progress-seconds> <command...>: keep slow work running
# while stdout, stderr or cumulative process-tree CPU advances. Unlike the hard
# bounds below it has no wall-clock cutoff. fm-duration.py owns the Python
# runner; the Perl-core fallback preserves Python-optional shell readers with
# the same CPU/output rule. Both forward signals, clean up the owned command
# group and write no duration records. A nested call keeps its own bound, so a
# hung inner read is stopped by its own owner and the outer work continues.
fm_run_progress() {
  local seconds=$1 helper
  shift
  helper="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-duration.py"
  if fm_posix_python; then
    python3 "$helper" keep-going "$seconds" -- "$@"
  elif command -v perl >/dev/null 2>&1; then
    fm_run_perl_progress "$seconds" "$@"
  else
    printf 'fm_run_progress: Python 3 or Perl is required to observe command progress\n' >&2
    return 127
  fi
}

# fm_posix_python: 0 when python3 is a POSIX interpreter able to run
# fm-duration.py's process-group runners. A native Windows python3 on a Git Bash
# PATH is not, so callers fall back instead of failing every read. The answer is
# kept for the rest of this shell.
fm_posix_python() {
  if [ -z "${_FM_POSIX_PYTHON:-}" ]; then
    _FM_POSIX_PYTHON=0
    if command -v python3 >/dev/null 2>&1 \
      && python3 -c 'import os, sys; sys.exit(os.name != "posix")' >/dev/null 2>&1; then
      _FM_POSIX_PYTHON=1
    fi
  fi
  [ "$_FM_POSIX_PYTHON" = 1 ]
}

# fm_progress_check <record> <pid> <no-progress-seconds> [path...]: fm-duration.py
# progress-check, the identity-bound proof that pid's process tree and the paths
# made no progress for the interval (124 only then). Without a POSIX python3
# nothing can be proven, so it never returns 124 and writes one
# cpu_telemetry_unavailable line per shell instead of failing each call.
fm_progress_check() {
  local helper
  if ! fm_posix_python; then
    if [ "${_FM_PROGRESS_CHECK_WARNED:-0}" != 1 ]; then
      _FM_PROGRESS_CHECK_WARNED=1
      printf 'cpu_telemetry_unavailable: no POSIX python3 can check process progress here; hung work cannot be proven, so nothing is stopped for inactivity\n' >&2
    fi
    return 0
  fi
  helper="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-duration.py"
  python3 "$helper" progress-check "$@"
}

# Preserve the existing Python-optional shell readers. Perl core modules relay
# both streams and sample the same identity-bound /proc-or-ps CPU facts as
# fm-duration.py. The bound is inactivity only, including TERM cleanup; while no
# sample is available one warning names the platform and nothing is stopped for
# inactivity. Parent death and signals clean up the owned command group.
fm_run_perl_progress() {
  local owner=${BASHPID:-$$}
  # shellcheck disable=SC2016 # Perl, not the sourcing shell, expands this program.
  perl -MPOSIX=WNOHANG -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -MIO::Select -MIO::Handle -e '
    my ($owner, $idle) = (shift, shift);
    die "inactivity must be positive\n" unless $idle =~ /^\d+(?:[.]\d+)?$/ && $idle > 0;
    my $parent = getppid();
    my ($pending, $stopping, $exit_code) = (0, 0, 0);
    $SIG{TERM} = sub { $pending ||= 143 };
    $SIG{INT} = sub { $pending ||= 130 };
    $SIG{HUP} = sub { $pending ||= 129 };
    $SIG{PIPE} = sub { $pending ||= 143 };
    setpgrp(0, 0) or die "setpgrp: $!";
    pipe(my $out_r, my $out_w) or die "pipe: $!";
    pipe(my $err_r, my $err_w) or die "pipe: $!";
    my $pid = fork;
    die "fork: $!" unless defined $pid;
    if (!$pid) {
      $SIG{$_} = "DEFAULT" for qw(TERM INT HUP);
      setpgrp(0, 0);
      close $out_r; close $err_r;
      open STDOUT, ">&", $out_w or die "stdout: $!";
      open STDERR, ">&", $err_w or die "stderr: $!";
      close $out_w; close $err_w;
      exec @ARGV;
      exit 127;
    }
    setpgrp($pid, $pid);
    close $out_w; close $err_w;
    STDOUT->autoflush(1); STDERR->autoflush(1);
    my $streams = IO::Select->new($out_r, $err_r);
    my %sink = (fileno($out_r) => \*STDOUT, fileno($err_r) => \*STDERR);
    my (%observed, $last_cpu, $blind, $warned, $active, $last_tree);
    my $last_progress = clock_gettime(CLOCK_MONOTONIC);
    my $next_sample = 0;
    my $cadence = $idle / 4 < 1 ? $idle / 4 : 1;
    my $proc = $ENV{FM_PROC_ROOT_OVERRIDE} || "/proc";
    my $ticks = eval { POSIX::sysconf(POSIX::_SC_CLK_TCK()) } || 100;
    my $cpu = sub {
      my (%children, %times, $from_ps);
      # A Linux-compatible /proc (Git Bash/MSYS too, whose ps rejects these
      # -o fields) is chosen by capability. Include waited-child CPU so work
      # cannot vanish when a child is reaped between samples.
      if (-r "$proc/$pid/stat" && opendir my $dir, $proc) {
        for my $child (grep { /^\d+$/ } readdir $dir) {
          open my $stat, "<", "$proc/$child/stat" or next;
          my $line = <$stat>;
          next unless defined $line && (my $at = rindex $line, ")") >= 0;
          my @field = split " ", substr($line, $at + 1);
          next unless @field >= 20 && $field[1] =~ /^\d+$/;
          push @{$children{$field[1]}}, $child;
          $times{$child} = [($field[11] + $field[12] + $field[13] + $field[14]) / $ticks,
                            "proc $field[19]", $field[0] eq "R"];
        }
        closedir $dir;
      } else {
        $from_ps = 1;
        local $ENV{LC_ALL} = "C";
        open my $ps, "-|", "ps", "-S", "-axo", "pid=,ppid=,time=,stat=,lstart=" or return;
        while (my $line = <$ps>) {
          my ($child, $parent, $clock, $state, $identity) = split " ", $line, 5;
          next unless defined $identity && $child =~ /^\d+$/ && $parent =~ /^\d+$/;
          chomp $identity;
          my $seconds = 0;
          $seconds = $1 * 86400 if $clock =~ s/^(\d+)-//;
          my $part = 0;
          $part = $part * 60 + $_ for split /:/, $clock;
          push @{$children{$parent}}, $child;
          $times{$child} = [$seconds + $part, $identity, $state =~ /^R/];
        }
        close $ps or return;
      }
      $active = 0;
      my @members;
      my @todo = ($pid);
      while (@todo) {
        my $child = pop @todo;
        if (exists $times{$child}) {
          my ($seconds, $identity, $running) = @{$times{$child}};
          $active ||= $running;
          my $key = "$child:$identity";
          push @members, $key;
          $observed{$key} = $seconds if !exists $observed{$key} || $seconds > $observed{$key};
        }
        push @todo, @{$children{$child} || []};
      }
      # ps may omit waited-child CPU on Darwin. A changed tree is not a
      # consecutive idle observation, even when its last CPU burst was missed.
      if ($from_ps) {
        my $tree = join "\\n", sort @members;
        $active ||= defined $last_tree && $tree ne $last_tree;
        $last_tree = $tree;
      }
      my $total = 0;
      $total += $_ for values %observed;
      return $total;
    };
    my $relay = sub {
      my $stream = shift;
      my $count = sysread($stream, my $buffer, 65536);
      if (defined $count && $count > 0) {
        print {$sink{fileno($stream)}} $buffer;
        $last_progress = clock_gettime(CLOCK_MONOTONIC);
      } elsif (defined $count) {
        $streams->remove($stream); close $stream;
      } elsif (!$!{EINTR}) {
        $pending ||= 1;
      }
    };
    while (1) {
      my $done = waitpid $pid, WNOHANG;
      my $status = $?;
      if ($done == $pid) {
        kill "KILL", -$pid if $stopping;
        while (my @ready = $streams->can_read(0)) { $relay->($_) for @ready; }
        exit($stopping ? $exit_code : (($status & 127) ? 128 + ($status & 127) : $status >> 8));
      }
      exit 127 if $done == -1;
      $pending ||= 143 if getppid() != $parent || !kill(0, $owner);
      if ($pending) {
        if ($stopping) { kill "KILL", -$pid; }
        else {
          $stopping = 1; $exit_code = $pending;
          $last_progress = clock_gettime(CLOCK_MONOTONIC);
          kill "TERM", -$pid;
        }
        $pending = 0;
      }
      if ($streams->count) { $relay->($_) for $streams->can_read($cadence); }
      else { select undef, undef, undef, $cadence; }
      my $now = clock_gettime(CLOCK_MONOTONIC);
      if ($now >= $next_sample) {
        my $sample = $cpu->();
        $blind = !defined $sample;
        if ($blind && !$warned++) {
          print STDERR "cpu_telemetry_unavailable: neither /proc/<pid>/stat nor ps can sample process CPU on $^O; hung work cannot be recovered here, so nothing is stopped for inactivity while CPU cannot be sampled\n";
        }
        $last_progress = $now if defined $sample && ($active || !defined $last_cpu || $sample > $last_cpu);
        $last_cpu = $sample if defined $sample;
        $next_sample = $now + $cadence;
      }
      if ($now - $last_progress >= $idle && ($stopping || !$blind)) {
        if ($stopping) { kill "KILL", -$pid; }
        else {
          print STDERR "no_progress: command made no output or CPU progress\n";
          $pending = 124;
        }
      }
    }
  ' "$owner" "$@"
}

fm_timeout_mechanism() {
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

# fm_timeout_free_fd <floor>: print the lowest unused descriptor number >= floor.
fm_timeout_free_fd() {
  local fd=$1
  while [ "$fd" -lt 200 ]; do
    if ! { : >&"$fd"; } 2>/dev/null; then
      printf '%s\n' "$fd"
      return 0
    fi
    fd=$((fd + 1))
  done
  return 1
}

# fm_timeout_open_status <prefix>: make a status file, open a write and a read
# descriptor on it, and unlink it at once. The numbers go to FM_TIMEOUT_WFD and
# FM_TIMEOUT_RFD. Nothing named stays on disk, so a caller that dies by TERM,
# INT, HUP or KILL while waiting leaves no file behind. The one remaining gap is
# a KILL between mktemp and the unlink.
fm_timeout_open_status() {
  local status_file wfd rfd
  FM_TIMEOUT_WFD=
  FM_TIMEOUT_RFD=
  status_file=$(mktemp "${TMPDIR:-/tmp}/$1.XXXXXX" 2>/dev/null) || return 1
  wfd=$(fm_timeout_free_fd 20) || wfd=
  rfd=
  [ -z "$wfd" ] || rfd=$(fm_timeout_free_fd $((wfd + 1))) || rfd=
  if [ -z "$wfd" ] || [ -z "$rfd" ]; then
    rm -f "$status_file" 2>/dev/null || true
    return 1
  fi
  if ! { eval "exec $wfd>\"\$status_file\" $rfd<\"\$status_file\""; } 2>/dev/null; then
    eval "exec $wfd>&- $rfd<&-" 2>/dev/null || true
    rm -f "$status_file" 2>/dev/null || true
    return 1
  fi
  rm -f "$status_file" 2>/dev/null || true
  FM_TIMEOUT_WFD=$wfd
  FM_TIMEOUT_RFD=$rfd
}

# The command's exit status and the watchdog's "expired" line share one
# unlinked file (see fm_timeout_open_status).
fm_run_bash_timeout() {
  local seconds=$1 child_pid watchdog_pid command_rc recorded content wfd rfd monitor_was_on=0
  shift
  fm_timeout_open_status fm-bash-timeout-command || return 124
  wfd=$FM_TIMEOUT_WFD
  rfd=$FM_TIMEOUT_RFD
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    eval "exec $rfd<&-"
    eval "\"\$@\" $wfd>&-"
    command_rc=$?
    printf '%s\n' "$command_rc" >&"$wfd"
    exit "$command_rc"
  ) &
  child_pid=$!
  (
    set +m
    eval "exec $rfd<&-"
    sleep "$seconds"
    printf 'expired\n' >&"$wfd"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  content=$(cat <&"$rfd" 2>/dev/null || true)
  case "$content" in
    *expired*)
      wait "$watchdog_pid" 2>/dev/null || true
      command_rc=124
      ;;
    *)
      kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
      wait "$watchdog_pid" 2>/dev/null || true
      recorded=${content%%$'\n'*}
      case "$recorded" in ''|*[!0-9]*) ;; *) command_rc=$recorded ;; esac
      ;;
  esac
  eval "exec $wfd>&- $rfd<&-" 2>/dev/null || true
  return "$command_rc"
}

# The bounded command's own status travels in the unlinked file of
# fm_timeout_open_status. A named file removed only on the normal return leaked
# one entry per interrupted call (2394 fm-timeout-status.* found in a shared
# temp dir).
fm_run_external_timeout() {
  local runner=$1 seconds=$2 runner_pid runner_rc command_rc wfd rfd
  shift 2
  fm_timeout_open_status fm-timeout-status || return 124
  wfd=$FM_TIMEOUT_WFD
  rfd=$FM_TIMEOUT_RFD
  # Run timeout asynchronously so its pid - also the process-group id created
  # by GNU/BSD timeout without --foreground - remains available for cleanup.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. Explicitly reap that leftover group on a real timeout.
  # The wrapper closes the read side and hides the write side from the command.
  # shellcheck disable=SC2016  # Expansion is deliberately deferred to the child shell.
  "$runner" -k 1 "$seconds" bash -c '
    wfd=$1
    rfd=$2
    shift 2
    eval "exec $rfd<&-"
    eval "\"\$@\" $wfd>&-"
    command_rc=$?
    printf "%s\n" "$command_rc" >&"$wfd"
    exit "$command_rc"
  ' _ "$wfd" "$rfd" "$@" &
  runner_pid=$!
  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=
  IFS= read -r command_rc <&"$rfd" 2>/dev/null || true
  eval "exec $wfd>&- $rfd<&-" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$command_rc" -le 255 ]; then
        case "$runner_rc" in
          124) [ "$command_rc" -lt 128 ] && return "$command_rc" ;;
          *) return "$command_rc" ;;
        esac
      fi
      ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
}

# See the header for fm_timeout_perl_bound's shared status and cleanup contract.
# The command runs in a process group of its own. BOTH sides call setpgrp
# before anything can signal that group: a child that is slow to be scheduled
# (a loaded host) has not yet created it when a short bound fires, the TERM
# and KILL then reach nothing, and the child would run on, orphaned, in a group
# the bound can no longer find. The parent's call fails harmlessly with EACCES
# once the child has exec'd, which only happens after the child's own call.
# Signal handlers record pending cleanup before the fork, so an interruption
# during startup cannot bypass group creation and leave the child unowned.
fm_timeout_perl_bound() {  # <seconds> <command...>
  local owner=${BASHPID:-$$}
  # shellcheck disable=SC2016  # single quotes are deliberate: Perl expands its own variables.
  perl -MPOSIX=WNOHANG -e '
    my ($owner, $t) = (shift, shift);
    my $parent = getppid();
    my $pending = 0;
    $SIG{ALRM} = sub { $pending ||= 124 };
    $SIG{TERM} = sub { $pending ||= 143 };
    $SIG{INT} = sub { $pending ||= 130 };
    $SIG{HUP} = sub { $pending ||= 129 };
    setpgrp(0, 0) or die "setpgrp: $!";
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) {
      $SIG{$_} = "DEFAULT" for qw(ALRM TERM INT HUP);
      setpgrp(0, 0);
      exec @ARGV;
      exit 127;
    }
    setpgrp($pid, $pid);
    my $stop = sub {
      my $code = shift;
      $SIG{ALRM} = $SIG{TERM} = $SIG{INT} = $SIG{HUP} = "IGNORE";
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      waitpid $pid, 0;
      exit $code;
    };
    alarm $t;
    while (1) {
      $stop->($pending) if $pending;
      my $done = waitpid $pid, WNOHANG;
      exit(($? & 127) ? 128 + ($? & 127) : $? >> 8) if $done == $pid;
      exit 127 if $done == -1;
      $stop->(143) if getppid() != $parent || !kill(0, $owner);
      select undef, undef, undef, 0.05;
    }
  ' "$owner" "$@"
  return $?
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$@" ;;
    perl) fm_timeout_perl_bound "$seconds" "$@" ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}

fm_timed_out() {  # <status>
  case ${1:-} in
    124 | 137) return 0 ;;
  esac
  return 1
}

# The perl watchdog forks the command into its own process group (both sides
# call setpgid, so the group exists before either can signal it) and polls
# waitpid(WNOHANG) against wall-clock deadlines rather than using alarm+die,
# which keeps the bound off perl's platform-dependent syscall-restart signal
# semantics and off the drift of counting sleep intervals.
fm_exec_timed() {  # <seconds> <grace-seconds> <command...>
  local seconds=${1:-} grace=${2:-} value owner
  for value in "$seconds" "$grace"; do
    case "$value" in
      '' | 0* | *[!0-9]*)
        echo "fm_exec_timed: usage: fm_exec_timed <positive-seconds> <positive-grace-seconds> <command> [args...]" >&2
        exit 125
        ;;
    esac
  done
  shift 2
  if [ "$#" -eq 0 ]; then
    echo "fm_exec_timed: usage: fm_exec_timed <positive-seconds> <positive-grace-seconds> <command> [args...]" >&2
    exit 125
  fi
  owner=${FM_EXEC_TIMED_OWNER_PID:-$$}
  unset FM_EXEC_TIMED_OWNER_PID
  if command -v perl >/dev/null 2>&1; then
    exec perl -MPOSIX=WNOHANG,setpgid -MTime::HiRes=time -e '
      my ($bound, $grace, $owner, $shell_parent) = (shift, shift, shift, shift);
      # exec preserves the shell PID, including in Bash 3.2 subshells where
      # BASHPID is unavailable. Keep the pre-exec parent for startup races.
      $owner = $shell_parent if $owner == $$;
      my $parent = getppid();
      my ($pid, $pending, $kill_at, $timed_out) = (0, "", 0, 0);
      for my $sig (qw(TERM INT HUP)) {
        $SIG{$sig} = sub {
          if ($pid) { kill $sig, -$pid } else { $pending = $sig }
          $kill_at ||= time + $grace;
        };
      }
      my $child = fork;
      exit 127 unless defined $child;
      if ($child == 0) {
        $SIG{$_} = "DEFAULT" for qw(TERM INT HUP);
        setpgid(0, 0);
        exec @ARGV;
        exit 127;
      }
      setpgid($child, $child);
      $pid = $child;
      kill $pending, -$pid if $pending;
      my $deadline = time + $bound;
      sub finish {
        my $status = shift;
        kill "KILL", -$pid if $kill_at;
        exit 124 if $timed_out;
        exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
      }
      while (1) {
        my $done = waitpid $pid, WNOHANG;
        finish($?) if $done == $pid;
        exit 127 if $done == -1;
        if ($kill_at) {
          if (time >= $kill_at) {
            kill "KILL", -$pid;
            waitpid $pid, 0;
            finish($?);
          }
        } elsif (time >= $deadline) {
          $timed_out = 1;
          $kill_at = time + $grace;
          kill "TERM", -$pid;
        } elsif (getppid() != $parent || !kill(0, $owner)) {
          $kill_at = time + $grace;
          kill "TERM", -$pid;
        }
        select undef, undef, undef, 0.05;
      }
    ' -- "$seconds" "$grace" "$owner" "$PPID" "$@"
  elif command -v timeout >/dev/null 2>&1; then
    exec timeout -k "$grace" "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    exec gtimeout -k "$grace" "$seconds" "$@"
  fi
  printf 'fm_exec_timed: cannot bound %s within %ss: none of perl, timeout, or gtimeout is available\n' "${1##*/}" "$seconds" >&2
  exit 127
}
