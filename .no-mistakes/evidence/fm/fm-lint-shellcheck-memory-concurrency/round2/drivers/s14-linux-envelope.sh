#!/usr/bin/env bash
# Inside a disposable Linux container: the head export, the pinned ShellCheck from the repo's own installer, the enforced envelope (the CI posture).
set -u
cp -R /head /tmp/w; cd /tmp/w || exit 1
bin/fm-install-shellcheck.sh /tmp/bin >/dev/null 2>&1; echo "installer exit=$?"; export PATH=/tmp/bin:$PATH
echo "$(uname -sm) ShellCheck $(shellcheck --version | sed -n 2p)"
F=/tmp/fx; mkdir -p $F; printf '#!/usr/bin/env bash\necho clean\n' > $F/clean.sh; printf '#!/usr/bin/env bash\nunused=1\n' > $F/warn.sh
export FM_LINT_CACHE_DIR=off
echo "## real, FM_LINT_REQUIRE_BOUNDS=1, CI=true, --strict-version: a clean and a finding root"
FM_LINT_REQUIRE_BOUNDS=1 CI=true bin/fm-lint.sh --strict-version $F/clean.sh $F/warn.sh > /tmp/r1.out 2>&1; echo "exit=$? (expect 1, a real finding)"; grep -E 'SC2034|bounds' /tmp/r1.out | cut -c1-160 | head -4
ls -d /var/tmp/firstmate-lint-*/lint-slots 2>/dev/null | sed 's/^/host pool: /'
echo "## real, enforced envelope, address-space limit too small for the source-following attempt: named death, then narrower retry"
FM_LINT_REQUIRE_BOUNDS=1 CI=true FM_LINT_JOBS=1 FM_LINT_ROOT_MEMORY_KIB=3145728 bin/fm-lint.sh --strict-version --telemetry /tmp/t.tsv bin/fm-watch.sh > /tmp/r2.out 2>&1; echo "exit=$?"; grep -E 'memory ceiling|fallback' /tmp/r2.out | cut -c1-200 | head -4
awk -F '\t' '$1=="end"{print "roots log: root=" $3 " status=" $9 " outcome=" $10}' /tmp/t.roots.tsv
echo "## refusals on Linux"
FM_LINT_SLOT_DIR=off bin/fm-lint.sh $F/clean.sh >/dev/null 2>&1; echo "FM_LINT_SLOT_DIR=off exit=$?"
FM_LINT_SLOT_DIR=/tmp/else bin/fm-lint.sh $F/clean.sh >/dev/null 2>&1; echo "FM_LINT_SLOT_DIR=other exit=$?"
echo "## two recorded roots under the enforced envelope: real runs overlap once they have records"
ls -l /usr/bin/time | cut -c1-60
for pass in cold warm; do FM_LINT_REQUIRE_BOUNDS=1 CI=true FM_LINT_JOBS=2 FM_LINT_ROOT_MEMORY_KIB=3145728 bin/fm-lint.sh --strict-version --telemetry /tmp/o.$pass.tsv $F/clean.sh tests/fm-lint-helpers.sh > /tmp/o.$pass.out 2>&1; echo "$pass exit=$?"; awk -F '\t' '$1=="end"{print "  " $3 " status=" $9 " outcome=" $10 " peak_rss_kib=" $11}' /tmp/o.$pass.roots.tsv; done
echo "## the whole slots suite, with the CI and GITHUB_ACTIONS values CI has"
CI=true GITHUB_ACTIONS=true bash tests/fm-lint-slots.test.sh 2>&1 | cut -c1-200 > /tmp/suite.out; rc=${PIPESTATUS[0]}; cat /tmp/suite.out; echo "suite exit=$rc"
