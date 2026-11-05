#!/usr/bin/env bash
# test_worker_trees_stop_on_signal in the Linux container: base and head, three times each, with and without the CI values.
set -u
for side in base head; do
  cp -R /$side /tmp/$side; cd /tmp/$side || exit 1
  [ -x /tmp/bin/shellcheck ] || bin/fm-install-shellcheck.sh /tmp/bin >/dev/null 2>&1
  export PATH=/tmp/bin:$PATH
  for i in 1 2 3; do
    out=$(CI=true GITHUB_ACTIONS=true bash tests/fm-lint-slots.test.sh test_worker_trees_stop_on_signal 2>&1); rc=$?
    echo "$side CI values try $i exit=$rc: $(printf '%s\n' "$out" | grep -E '^(ok|not ok)' | cut -c1-120)"
  done
  out=$(bash tests/fm-lint-slots.test.sh test_worker_trees_stop_on_signal 2>&1); rc=$?
  echo "$side no CI values exit=$rc: $(printf '%s\n' "$out" | grep -E '^(ok|not ok)' | cut -c1-120)"
done
