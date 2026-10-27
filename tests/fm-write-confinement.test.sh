#!/usr/bin/env bash
# macOS kernel-level acceptance for T5, including actual production busy writes.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "$(uname -s)" != Darwin ]; then
  printf 'skip: macOS Seatbelt acceptance; Linux remains unconfined\n'
  exit 0
fi
TMP_ROOT=$(fm_test_tmproot fm-write-confinement)
export OMP_PROFILE='' PI_PROFILE='' PI_CONFIG_DIR=.omp
python3 "$ROOT/tests/fm-write-confinement.py" "$ROOT" "$TMP_ROOT"
pass "T5 a-e, gate push, duration, procevent and fleet-ledger writes, and refused writes and renames per protected asset class under the omp and Claude profiles"
