#!/usr/bin/env bash
# Controlled quota-axi stand-in: serves a fixed fixture; never reads live accounts.
case "${1:-}" in
  --version) printf 'quota-axi %s\n' "${CTL_QUOTA_VERSION:-0.1.55}" ;;
  --json) cat "${CTL_QUOTA_FIXTURE:?}" ;;
  *) exit 64 ;;
esac
