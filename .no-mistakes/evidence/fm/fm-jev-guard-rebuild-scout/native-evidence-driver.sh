#!/usr/bin/env bash
set -u
# Capture the real clients' requests, native output and guard records before the
# existing native test helper destroys each disposable scenario.
python3() {
  if [ "${1:-}" = -I ] && [[ "${2:-}" == */fm-jev-guard-native-assert.py ]]; then
    local lab=$3 backend=$4 phase=$5 kind=$6 dest
    dest="$JEV_EVIDENCE/native/$backend/$phase-$kind"
    mkdir -p "$dest"
    cp "$lab/model.jsonl" "$lab/jev.jsonl" "$lab/native.out" "$lab/scenario.json" "$lab/original.txt" "$dest/"
    [ ! -f "$lab/native-hook.json" ] || cp "$lab/native-hook.json" "$dest/native-hook.json"
    [ ! -f "$lab/home/state/jev-guard.jsonl" ] || cp "$lab/home/state/jev-guard.jsonl" "$dest/audit.jsonl"
  fi
  command python3 "$@"
}
export -f python3
exec python3 bin/fm-duration.py run test.jev-native-local -- bin/fm-test-run.sh --jobs 1 --json "$JEV_EVIDENCE/native-timing.json" tests/fm-jev-guard-omp-live-e2e.test.sh tests/fm-jev-guard-claude-live-e2e.test.sh
