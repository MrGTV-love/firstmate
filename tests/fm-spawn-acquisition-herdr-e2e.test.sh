#!/usr/bin/env bash
# Run the shared acquisition lifecycle regression in its generated Herdr lab (mode: off).
exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-acquisition-cleanup.test.sh" herdr off
