#!/usr/bin/env bash
# Token-free real SessionStart descendants under the production Seatbelt policy.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "$(uname -s)" != Darwin ]; then
  printf 'skip: live: macOS Seatbelt only; Linux remains unconfined\n'
  exit 0
fi
fm_live_gate default-on FM_WRITE_CONFINEMENT_LIVE python3 git bun
export FM_WRITE_CONFINEMENT_LIVE_RUN=1
bash "$ROOT/tests/fm-write-confinement.test.sh"
