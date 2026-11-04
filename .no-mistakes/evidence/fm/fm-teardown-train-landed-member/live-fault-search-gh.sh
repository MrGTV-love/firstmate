#!/usr/bin/env bash
# Fault injection: the forge search ("gh pr list") fails as if the network dropped;
# every other gh call goes to the real gh against the real forge.
if [ "${1:-} ${2:-}" = "pr list" ]; then echo "error: connection reset (injected)" >&2; exit 1; fi
exec /opt/homebrew/bin/gh "$@"
