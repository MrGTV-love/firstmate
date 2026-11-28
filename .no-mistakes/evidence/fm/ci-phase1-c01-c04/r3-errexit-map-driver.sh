#!/usr/bin/env bash
# Prints "<case> <errexit-on|off>" for every registered case of a teardown test file,
# by running the file's real registry + fm_test_before_case through the real
# fm_test_run_cases in tests/lib.sh, with each case body replaced by a probe.
set -u
WT=$1 src=$2   # src: file path holding the test file text
. "$WT/tests/lib.sh" >/dev/null 2>&1
start=$(grep -n '^teardown_test_cases=($' "$src" | cut -d: -f1)
stop=$(grep -n '^fm_test_run_cases ' "$src" | cut -d: -f1)
eval "$(sed -n "${start},$((stop-1))p" "$src")"
for c in "${teardown_test_cases[@]}"; do
  eval "$c() { case \$- in *e*) echo \"$c on\";; *) echo \"$c off\";; esac; }"
done
fm_test_run_cases "${teardown_test_cases[@]}" --
