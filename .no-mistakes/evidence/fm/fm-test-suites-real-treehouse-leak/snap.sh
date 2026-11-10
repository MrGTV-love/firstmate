#!/usr/bin/env bash
# Read-only snapshot of a Treehouse root: names + mtimes, two levels (same rule as tests/treehouse-test-safety.sh).
. "$1/tests/treehouse-test-safety.sh"
fm_test_treehouse_snapshot "$2"
