#!/usr/bin/env bash
# Run the shared acquisition lifecycle regression in its generated Herdr lab.
bash "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-acquisition-cleanup.test.sh" herdr off || exit
exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-spawn-acquisition-cleanup.test.sh" herdr on
