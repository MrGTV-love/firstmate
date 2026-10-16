#!/usr/bin/env bash
# Run: FM_JEV_GUARD_OMP_LIVE=1 bash tests/fm-jev-guard-omp-live-e2e.test.sh
# Installed OMP, private scripted providers, no paid model or Jev requests.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_JEV_GUARD_OMP_LIVE omp python3 node jq curl bash
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
# shellcheck source=tests/fm-jev-guard-native-helpers.sh
. "$ROOT/tests/fm-jev-guard-native-helpers.sh"
fm_jev_native_run omp
