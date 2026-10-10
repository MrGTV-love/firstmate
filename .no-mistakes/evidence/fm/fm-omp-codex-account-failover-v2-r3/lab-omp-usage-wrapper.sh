#!/usr/bin/env bash
# Lab-only quota view: serve a disposable usage fixture when one is staged,
# otherwise pass every call (including usage) to the real omp.
if [ "${1:-}" = usage ] && [ -f "/Users/charlesabrooker/tmp/fm-lab.Vqf1Dk/usage-fixture.jq" ]; then
  printf '%s %s\n' "$(date +%s)" "fixture" >> "/Users/charlesabrooker/tmp/fm-lab.Vqf1Dk/usage-calls.log"
  exec jq -n --argjson now "$(date +%s)" -f "/Users/charlesabrooker/tmp/fm-lab.Vqf1Dk/usage-fixture.jq"
fi
[ "${1:-}" != usage ] || printf '%s %s\n' "$(date +%s)" "real" >> "/Users/charlesabrooker/tmp/fm-lab.Vqf1Dk/usage-calls.log"
exec /Users/charlesabrooker/.bun/bin/omp "$@"
