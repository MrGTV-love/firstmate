#!/usr/bin/env bash
# The whole slots suite on Linux, with an init process (--init) so orphans are reaped, and with CI's values.
set -u
cp -R /head /tmp/head; cd /tmp/head || exit 1
bin/fm-install-shellcheck.sh /tmp/bin >/dev/null 2>&1; export PATH=/tmp/bin:$PATH
CI=true GITHUB_ACTIONS=true bash tests/fm-lint-slots.test.sh > /tmp/suite.out 2>&1; rc=$?
cut -c1-170 /tmp/suite.out | grep -E '^(ok|not ok)'; echo "suite exit=$rc"
