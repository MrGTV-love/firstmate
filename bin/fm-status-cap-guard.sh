#!/usr/bin/env bash
# fm-status-cap-guard.sh - detect and contain a status log that passed its size cap.
#
# Usage: fm-status-cap-guard.sh scan
#        fm-status-cap-guard.sh mark <path> <identity>
#
# bin/fm-status-append.sh bounds the sanctioned write path, but a foreign process
# can open a status log itself. On 2026-10-18 the shell inside an agent harness
# looped on a raw append and three logs reached 140 GB, 265 GB and 122 GB. The
# watcher (bin/fm-watch.sh, status_cap_tick) finds any status log or per-task
# sidecar over the cap with one stat per poll (fm_status_cap_unalerted,
# bin/fm-status-cap-lib.sh) and runs `scan` only when one has no alert yet.
#
# scan investigates each such file once and prints one record per file:
#   <identity><TAB><path><TAB><wake reason>
# The reason names the file, its size, its growth rate over a short sample, and the
# writer process found by lsof. It then contains the damage: when the writer is an
# omp process (the harness that produced the incident) it is stopped with SIGSTOP,
# which a later `kill -CONT <pid>` undoes. Exactly the pids lsof reported as holding
# the file open for writing and recognized as omp are signalled; any other writer,
# or none found, is named and left alone. It never deletes, truncates or rewrites a
# file. `FM_STATUS_CAP_STOP=0` makes it observe only.
#
# bin/fm-control.sh is the control plane for a task's agent, addressed by task id
# and driving its endpoint; it has no verb for one process id, and the writer is a
# lane's harness process that need not belong to the task whose log it filled. The
# one-process stop therefore lives here, guarded the same way: the pid must still
# be the omp process lsof named, must not be this process or one of its ancestors,
# and is checked again just before the signal.
#
# mark records that the watcher durably queued the wake for <path> at <identity>,
# so the same episode never wakes twice (marker file named in the cap library).
# Environment: FM_STATE_OVERRIDE (state dir), FM_STATUS_CAP_SAMPLE_SECS (growth
# sample, default 1), FM_STATUS_CAP_STOP (0 observes only), FM_STATUS_CAP_LSOF (the
# lsof command, for tests). The cap itself is FM_STATUS_CAP_BYTES.
#
# tests/fm-status-runaway-guard.test.sh is the regression entry point.
set -u

SCRIPT_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-status-cap-lib.sh
. "$SCRIPT_DIR/fm-status-cap-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"

LSOF=${FM_STATUS_CAP_LSOF:-lsof}
# One second between the first lsof look and the second look for a writer that reopens
# the log on every append. It is a sampling interval, not a deadline.
# measured: value=1 date=2026-10-18 host=Mac-Studio.local margin=5 (one lsof look takes 0.20 to 0.23 s)
SAMPLE_SECS=${FM_STATUS_CAP_SAMPLE_SECS:-1}
# measured: value=1 date=2026-10-18 host=Mac-Studio.local margin=5 (same interval; a malformed value falls back to it)
case "$SAMPLE_SECS" in ''|*[!0-9]*) SAMPLE_SECS=1 ;; esac
# measured: value=1 date=2026-10-18 host=Mac-Studio.local margin=5 (same interval; a zero value falls back to it)
[ "$SAMPLE_SECS" -gt 0 ] || SAMPLE_SECS=1

clean() { LC_ALL=C tr '\t\r\n' '   '; }

# "<pid> <command>" for every process holding <file> open for writing, one per
# line, read from lsof's machine-readable fields. The command is lsof's own name.
find_writers() {  # <file>
  local file=$1 out line pid='' cmd='' fd_mode
  # measured: value=10 date=2026-10-18 host=Mac-Studio.local margin=45 (three lsof runs on a local file, slowest 0.23s)
  out=$(fm_run_timed 10 "$LSOF" -nP -F pcfa -- "$file" 2>/dev/null) || :
  while IFS= read -r line; do
    case "$line" in
      p*) pid=${line#p}; cmd='' ;;
      c*) cmd=${line#c} ;;
      a*) fd_mode=${line#a}
        case "$fd_mode" in
          w|u) [ -n "$pid" ] && printf '%s %s\n' "$pid" "$cmd" ;;
        esac
        ;;
    esac
  done <<EOF
$out
EOF
}

# One process can hold the log through several descriptors; list each pid once.
unique_writers() {  # <file>
  find_writers "$1" | awk '!seen[$1]++'
}

# The executable base name of <pid>, from ps rather than lsof's truncated name.
process_name() {  # <pid>
  local comm
  comm=$(ps -p "$1" -o comm= 2>/dev/null) || return 1
  comm=${comm%"${comm##*[![:space:]]}"}
  comm=${comm#"${comm%%[![:space:]]*}"}
  [ -n "$comm" ] || return 1
  printf '%s' "${comm##*/}"
}

process_start() {  # <pid>
  ps -p "$1" -o lstart= 2>/dev/null
}

is_ancestor_or_self() {  # <pid>
  local want=$1 cur=$$ parent
  while [ -n "$cur" ] && [ "$cur" -gt 1 ] 2>/dev/null; do
    [ "$cur" = "$want" ] && return 0
    parent=$(ps -p "$cur" -o ppid= 2>/dev/null) || break
    cur=${parent//[[:space:]]/}
  done
  return 1
}

file_size() {  # <file>
  if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
    LC_ALL=C /usr/bin/stat -f '%z' "$1" 2>/dev/null
  else
    LC_ALL=C stat -c '%s' "$1" 2>/dev/null
  fi
}

# Stop pid with SIGSTOP when it is still the omp process found earlier. Prints
# the action text. Never signals this process, an ancestor, or pid 1 and below.
stop_writer() {  # <pid> <name> <start>
  local pid=$1 name=$2 start=$3
  case "$pid" in ''|*[!0-9]*) printf 'stopped nothing: unusable pid'; return 1 ;; esac
  if [ "$pid" -le 1 ] || is_ancestor_or_self "$pid"; then
    printf 'stopped nothing: pid %s is this guard or its own parent chain' "$pid"
    return 1
  fi
  if [ "$(process_name "$pid")" != "$name" ] || [ "$(process_start "$pid")" != "$start" ]; then
    printf 'stopped nothing: pid %s changed or exited before it could be stopped' "$pid"
    return 1
  fi
  if kill -STOP "$pid" 2>/dev/null; then
    printf 'stopped pid %s (%s) with SIGSTOP; resume it with kill -CONT %s' "$pid" "$name" "$pid"
    return 0
  fi
  printf 'stopped nothing: could not signal pid %s' "$pid"
  return 1
}

now_hires() {
  perl -MTime::HiRes=time -e 'printf "%.3f", time'
}

# Bytes per second between two (size, time) samples; the empty string when the
# interval is too short to mean anything.
rate_between() {  # <size-a> <time-a> <size-b> <time-b>
  perl -e '
    my ($a, $ta, $b, $tb) = @ARGV;
    my $dt = $tb - $ta;
    if ($dt < 0.02) { print ""; exit 0; }
    my $r = ($b - $a) / $dt;
    $r = 0 if $r < 0;
    printf "%d", $r;
  ' "$1" "$2" "$3" "$4"
}

# Containment first, measurement second: the growth rate is taken from the sample
# lsof's own run already spans, and every omp writer is stopped before anything
# sleeps, because at the incident's 0.2 to 0.7 GB/s each second costs hundreds of
# megabytes. Only a log with no writer found yet waits one sample for a second look.
investigate() {  # <size> <ident> <path>
  local size=$1 ident=$2 path=$3 cap size_a size_b size_end time_a time_b rate writers pid cmd name start line reason
  local writer_text='' action_text='' omp_found=0 seen_other='' retried=0
  fm_status_cap_bytes cap
  size_a=$(file_size "$path") || size_a=$size
  time_a=$(now_hires)
  writers=$(unique_writers "$path")
  size_b=$(file_size "$path") || size_b=$size_a
  time_b=$(now_hires)
  rate=$(rate_between "$size_a" "$time_a" "$size_b" "$time_b")
  if [ -z "$writers" ]; then
    # A writer that reopens the log on every append is between opens for most of an
    # lsof read; look once more after one sample, which also measures growth.
    sleep "$SAMPLE_SECS"
    retried=1
    writers=$(unique_writers "$path")
    size_end=$(file_size "$path") || size_end=$size_b
    time_b=$(now_hires)
    rate=$(rate_between "$size_a" "$time_a" "$size_end" "$time_b")
  fi
  size_end=$(file_size "$path") || size_end=$size_b
  [ -n "$rate" ] || rate=unmeasured
  if [ -z "$writers" ]; then
    writer_text='none found (lsof listed no process holding it open for writing)'
    action_text='stopped nothing'
  else
    while IFS=' ' read -r pid cmd; do
      [ -n "$pid" ] || continue
      name=$(process_name "$pid") || name=$cmd
      writer_text="${writer_text:+$writer_text, }pid $pid $name"
      if [ "$name" != omp ]; then
        seen_other="${seen_other:+$seen_other, }pid $pid ($name) is not an omp process"
        continue
      fi
      omp_found=1
      if [ "${FM_STATUS_CAP_STOP:-1}" = 0 ]; then
        action_text="${action_text:+$action_text; }stopped nothing: FM_STATUS_CAP_STOP=0"
        continue
      fi
      start=$(process_start "$pid")
      line=$(stop_writer "$pid" "$name" "$start") || :
      action_text="${action_text:+$action_text; }$line"
    done <<EOF
$writers
EOF
    if [ "$omp_found" -eq 0 ]; then
      action_text="stopped nothing: $seen_other"
    elif [ -n "$seen_other" ]; then
      action_text="$action_text; left alone: $seen_other"
    fi
  fi
  : "$retried"
  reason=$(printf 'check: status-log-over-cap: file=%s size=%s bytes (cap %s) growth=%s bytes/s writer=%s; %s; nothing was deleted, truncated or rewritten' \
    "${path##*/}" "$size_end" "$cap" "$rate" "$writer_text" "$action_text" | clean)
  printf '%s\t%s\t%s\n' "$ident" "$path" "$reason"
}

case "${1:-}" in
  scan)
    fm_status_cap_unalerted "$STATE" | while IFS=$'\t' read -r size ident path; do
      [ -n "$path" ] || continue
      investigate "$size" "$ident" "$path"
    done
    ;;
  mark)
    [ "$#" -eq 3 ] || { echo "usage: fm-status-cap-guard.sh mark <path> <identity>" >&2; exit 2; }
    marker=
    fm_status_cap_marker_path "$STATE" "$2" marker
    printf '%s\t%s\n' "$3" "$2" > "$marker"
    ;;
  *)
    echo "usage: fm-status-cap-guard.sh scan | mark <path> <identity>" >&2
    exit 2
    ;;
esac
