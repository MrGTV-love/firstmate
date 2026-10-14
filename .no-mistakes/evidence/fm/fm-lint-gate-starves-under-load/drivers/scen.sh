#!/usr/bin/env bash
# Live gate scenarios against real bin/fm-lint.sh + ShellCheck 0.11.0 in a private pool.
set -u
LAB=$(cat /tmp/fm-lint-lab-path.txt)
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
ts() { perl -MTime::HiRes=time -e 'printf "%.2f", time - $ARGV[0]' "$T0"; }
log() { printf '[t+%6ss] %s\n' "$(ts)" "$*"; }
gate_pid() { ls "$1"/queue.0* 2>/dev/null | head -1 | sed -E "s|.*queue\.[0-9]+\.([0-9]+)\..*|\1|"; }
running_sc() { ps -axww -o command= | grep -E "^\S*/shellcheck .*$1" | grep -vc grep; }
admission_free() { perl -MFcntl=:flock -e 'open(my $f, ">>", $ARGV[0]) or exit 2; if (flock($f, LOCK_EX|LOCK_NB)) { flock($f, LOCK_UN); exit 0 } exit 1' "$1/admission.lock"; }
wait_for() { local d=$(( $(date +%s) + $2 )); until eval "$1"; do [ "$(date +%s)" -lt "$d" ] || return 1; sleep 0.05; done; }
start_hold() { rm -f "$1.release"; perl "$LAB/hold.pl" "$1/slot.0" "$1.release" > "$1.held" & HOLDER=$!; wait_for "grep -q held $1.held" 10; }
release_hold() { touch "$1.release"; wait "$HOLDER"; }
lint() { local slots=$1 out=$2; shift 2; FM_LINT_HOST_SLOTS=1 LAB_SLOTS="$slots" "$LAB/lint.sh" --jobs 1 "$@" > "$out" 2>&1; }
