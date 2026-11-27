#!/usr/bin/env bash
cd /tmp/fmlintlive.9Rph/e2e
run() { env -u FM_HOME -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE -u NO_MISTAKES_GATE CI= GITHUB_ACTIONS= FM_LINT_CACHE_DIR=/tmp/fmlintlive.9Rph/e2e-cache FM_LINT_SLOT_DIR=/tmp/fmlintlive.9Rph/e2e-slots FM_DURATION_FILE=/tmp/fmlintlive.9Rph/durations.jsonl bin/fm-lint.sh --jobs 2; }
echo "### RUN 1 (cold)"; s=$(date +%s); run; echo "rc=$? seconds=$(($(date +%s)-s))"
echo "### RUN 2 (warm)"; s=$(date +%s); run; echo "rc=$? seconds=$(($(date +%s)-s))"
