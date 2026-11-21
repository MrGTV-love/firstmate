#!/usr/bin/env bash
# Capability shim for live validation only: answers `capabilities --json` as a
# schema-2 provider with a protected recovered holder; every other command runs
# the real installed treehouse binary unchanged.
if [ "${1:-}" = capabilities ]; then
  printf '%s\n' '{"schema_version":2,"version":"v3.1.7-lab-shim","persistent_recovered_leases":true,"recovered_quarantine_holder":"quarantined: persistent recovered lease"}'
  exit 0
fi
exec /Users/charlesabrooker/.local/bin/treehouse "$@"
