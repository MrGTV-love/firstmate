#!/usr/bin/env bash
# Contract: parsed .no-mistakes.yaml must leave commands.test absent or empty,
# integrate newer main by merge (rebase.strategy: merge), and keep test
# instructions targeted, synchronous in the foreground, and lab-bounded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NM="$ROOT/.no-mistakes.yaml"

test_nm_has_no_deterministic_test_command() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
cmds = doc["commands"] || {}
val = cmds.is_a?(Hash) ? cmds["test"] : nil
puts (val.nil? || val == false || val == "") ? "" : val.inspect
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  if [ -n "$val" ]; then
    fail "commands.test must be absent or empty so Test stays intent-targeted; got: $val"
  fi
  pass "no-mistakes does not configure commands.test"
}

test_nm_has_no_deterministic_test_command

test_nm_integrates_main_by_merge() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local val
  val=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
r = doc["rebase"]
puts r.is_a?(Hash) ? r["strategy"].to_s : ""
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  [ "$val" = "merge" ] || fail "rebase.strategy must be merge so the rebase step keeps the submitted head an ancestor; got: '$val'"
  pass "no-mistakes integrates newer main by merge"
}

test_nm_integrates_main_by_merge

test_nm_test_instructions_stay_targeted_and_foreground() {
  command -v ruby >/dev/null 2>&1 \
    || fail "ruby is required to parse .no-mistakes.yaml for this contract"
  local text
  text=$(ruby -ryaml -e '
doc = YAML.load_file(ARGV[0]) || {}
t = doc["test"]
puts t.is_a?(Hash) ? t["instructions"].to_s : ""
' "$NM") || fail "failed to parse .no-mistakes.yaml as YAML"
  printf '%s' "$text" | grep -qi 'targeted' \
    || fail "test.instructions must require targeted validation so local Test stays fast"
  printf '%s' "$text" | grep -qi 'foreground' \
    || fail "test.instructions must require synchronous foreground test execution"
  printf '%s' "$text" | grep -q 'bin/fm-herdr-lab.sh' \
    || fail "test.instructions must retain the bin/fm-herdr-lab.sh boundary"
  printf '%s' "$text" | grep -q 'bin/fm-lab-home.sh' \
    || fail "test.instructions must retain the bin/fm-lab-home.sh boundary"
  pass "no-mistakes test.instructions enforces targeted foreground checks and lab boundaries"
}

test_nm_test_instructions_stay_targeted_and_foreground
