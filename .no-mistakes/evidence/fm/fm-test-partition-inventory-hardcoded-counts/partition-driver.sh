#!/usr/bin/env bash
# partition-driver.sh <checkout-root> <src-test-file> <case>...
# Loads the real partition functions and the named test cases from <src-test-file>
# (each copied verbatim from "^name() {" to the next "^}"), points ROOT at
# <checkout-root>, and runs each case. Exit status is the first failure.
set -u
root=$1 src=$2; shift 2
. "$root/tests/lib.sh"
ROOT=$root
names="partition_registered partition_called partition_defined partition_called_elsewhere partition_problems assert_partition_exact partition_fixture_group partition_fixture_calls $*"
for n in $names; do
  body=$(awk -v n="$n" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$src")
  [ -n "$body" ] && eval "$body"
done
for c in "$@"; do
  declare -F "$c" >/dev/null || { echo "no such case in $src: $c"; exit 3; }
  ( "$c" ) || exit $?
done
