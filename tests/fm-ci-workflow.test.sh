#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR, main pushes coalesce into one
# running plus one pending run per branch without ever cancelling the running
# one, and every CI job carries a finite hang tripwire drawn from the
# three-tier timeout policy that docs/fm-test-portable-shards.md "Timeouts"
# owns (fast, normal, heavy), so no job drifts back to a one-off number.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3 ref=${4:-refs/heads/main}
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
  "github.ref" => ARGV[4],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |token| value.call(token) }.find { |v| !v.empty? }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id" "$ref"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

# Tier membership is the executable inventory of the timeout policy: a new job
# must join a tier, and a job-level value outside these tiers is exactly the
# one-off number the policy removed.
FAST_TIER_JOBS='plan test-coverage invariants tests-timing-aggregate'
SERIAL_JOBS=$(for n in $(seq 1 25); do printf 'tests-portable-serial-%s ' "$n"; done)
NORMAL_TIER_JOBS="lint tests-portable-parallel-1 tests-portable-parallel-2 ${SERIAL_JOBS}macos-stock-bash"
HEAVY_TIER_JOBS='tests-herdr'

# Print the one timeout every listed job shares; fail on any disagreement.
tier_timeout() {  # <tier> <job>...
  local tier=$1 job first actual
  shift
  first=
  for job in "$@"; do
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    case "$actual" in ''|*[!0-9]*) fail "$job ($tier tier) has no integer timeout, got $actual" ;; esac
    if [ -z "$first" ]; then
      first=$actual
    elif [ "$actual" != "$first" ]; then
      fail "$tier tier jobs must share one timeout, got $first and $actual ($job)"
    fi
  done
  printf '%s\n' "$first"
}

# Print every job id in the workflow, one per line.
workflow_jobs() {
  ruby -ryaml -e 'puts YAML.load_file(ARGV[0]).fetch("jobs").keys' "$CI_WORKFLOW"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_coalesce_without_cancelling() {
  local first second pr other_branch
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "every push to one branch must share a group so a burst keeps one pending run, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel the running run, got $(cancel_of "$first")"
  pr=$(resolve_concurrency pull_request 108 900012) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" != "$(group_of "$pr")" ] \
    || fail "a main push must not share a group with a pull request run ($(group_of "$pr"))"
  other_branch=$(resolve_concurrency push '' 900013 refs/heads/release) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$other_branch")" ] \
    || fail "pushes to different branches must not share a group ($(group_of "$other_branch"))"
  pass "main pushes share one group per branch and never cancel the running run"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

# Every job sits in exactly one tier, and the workflow carries exactly three
# distinct job-level timeouts: one per tier, no one-off numbers.
test_every_job_belongs_to_exactly_one_timeout_tier() {
  local expected actual distinct
  # shellcheck disable=SC2086
  expected=$(printf '%s\n' $FAST_TIER_JOBS $NORMAL_TIER_JOBS $HEAVY_TIER_JOBS | LC_ALL=C sort)
  [ "$(printf '%s\n' "$expected" | LC_ALL=C sort -u)" = "$expected" ] \
    || fail "a job is listed in more than one timeout tier:"$'\n'"$expected"
  actual=$(workflow_jobs | LC_ALL=C sort) || fail "could not list ci.yml jobs"
  [ "$actual" = "$expected" ] \
    || fail "ci.yml jobs and the timeout tiers disagree; every job must join one tier"$'\n'"workflow: $(printf '%s' "$actual" | tr '\n' ' ')"$'\n'"tiers: $(printf '%s' "$expected" | tr '\n' ' ')"
  distinct=$(for job in $expected; do job_timeout "$job"; done | LC_ALL=C sort -u | wc -l | tr -d ' ')
  [ "$distinct" = 3 ] \
    || fail "ci.yml must carry exactly three distinct job timeouts (fast, normal, heavy), got $distinct"
  pass "every ci.yml job belongs to one of the three timeout tiers"
}

# Fast tier: seconds-long checks share one short tripwire in the 5-10 minute band.
test_fast_tier_shares_one_short_tripwire() {
  local fast
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  [ "$fast" -ge 5 ] && [ "$fast" -le 10 ] \
    || fail "fast tier must be a 5-10 minute hang tripwire, got $fast"
  pass "fast tier jobs share one $fast minute tripwire"
}

# Normal tier: every test or lint lane shares ONE fixed 60-minute budget,
# above the fast tier. That budget is a hang tripwire, not a packing estimate.
test_normal_tier_shares_one_budget() {
  local fast normal
  # shellcheck disable=SC2086
  fast=$(tier_timeout fast $FAST_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  [ "$normal" -gt "$fast" ] \
    || fail "normal tier ($normal) must exceed the fast tier ($fast)"
  [ "$normal" = 60 ] \
    || fail "normal tier must be the single 60-minute shared budget, got $normal"
  pass "normal tier jobs share one $normal minute budget"
}

# Heavy tier: Herdr alone carries a job-level last-resort backstop above the
# normal tier, while its family-run step owns a tighter tripwire so the
# always() cleanup and timing upload still run after a hang.
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop() {
  local normal heavy step
  # shellcheck disable=SC2086
  normal=$(tier_timeout normal $NORMAL_TIER_JOBS) || exit 1
  # shellcheck disable=SC2086
  heavy=$(tier_timeout heavy $HEAVY_TIER_JOBS) || exit 1
  [ "$heavy" -gt "$normal" ] \
    || fail "heavy tier backstop ($heavy) must exceed the normal tier ($normal)"
  [ "$heavy" -ge 90 ] && [ "$heavy" -le 120 ] \
    || fail "heavy tier backstop must stay a 90-120 minute last resort, got $heavy"
  step=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("steps")
index = steps.index { |s| s["id"] == "run-real-herdr-family" }
raise "no run-real-herdr-family step" unless index
teardown = steps.index { |s| s["id"] == "cleanup-herdr-lab-sessions" }
raise "no cleanup-herdr-lab-sessions step" unless teardown
raise "teardown must follow the family-run step" unless teardown > index
raise "teardown must run under always()" unless steps[teardown]["if"].to_s.strip == "always()"
puts steps[index].fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" tests-herdr) || fail "could not read the Herdr family-run step"
  case "$step" in ''|*[!0-9]*) fail "the Herdr family-run step needs its own timeout-minutes, got $step" ;; esac
  [ "$step" = 60 ] \
    || fail "the Herdr family-run step must be the 60-minute tripwire, got $step"
  [ "$step" -lt "$heavy" ] \
    || fail "the Herdr step tripwire ($step) must stay below the job backstop ($heavy)"
  pass "Herdr keeps a $step minute step tripwire under a $heavy minute job backstop"
}

# One job per serial shard (so a shard the plan skips still reports under its own
# name). The jobs must be the same job but for their number, and together they
# must be exactly the shard lanes the runner defines for the planned count, so a
# CI job list and the runner cannot disagree about a shard.
test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
plan, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--plan-ci")
raise "cannot plan the full suite" unless status.success?
planned = plan.lines.map { |l| l.chomp.split("=", 2) }.to_h
total = Integer(planned.fetch("serial_count"))
serial = jobs.select { |id, _| id.match?(/\Atests-portable-serial-\d+\z/) }
raise "expected #{total} serial shard jobs, found #{serial.length}" unless serial.length == total
canonical = nil
serial.each do |id, job|
  n = Integer(id[/\d+\z/])
  raise "#{id} must be named Behavior portable serial #{n}, got #{job["name"].inspect}" unless job["name"] == "Behavior portable serial #{n}"
  raise "#{id} must need the plan" unless Array(job["needs"]) == ["plan"]
  raise "#{id} must run when the plan has at least #{n} shards, got #{job["if"].inspect}" \
    unless job["if"].to_s.strip == "fromJSON(needs.plan.outputs.serial_count) >= #{n}"
  steps = job.fetch("steps")
  shard = steps.find { |s| s["uses"] == "./.github/actions/portable-serial-shard" }
  raise "#{id} must run the portable-serial-shard action" unless shard
  raise "#{id} must pass its own shard number" unless shard.fetch("with").fetch("shard").to_i == n
  raise "#{id} must pass the planned total" unless shard.fetch("with").fetch("total").to_s.include?("needs.plan.outputs.serial_count")
  normalized = Marshal.load(Marshal.dump(job))
  normalized["name"] = nil
  normalized["if"] = nil
  normalized["steps"].each { |s| s.fetch("with", {})["shard"] = nil if s["uses"] == "./.github/actions/portable-serial-shard" }
  canonical ||= normalized
  raise "#{id} differs from the other serial shard jobs beyond its number" unless normalized == canonical
end
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = (1..total).map { |n| "portable-serial-#{n}of#{total}" }
raise "CI jobs and runner disagree" unless actual.sort == expected.sort
lint = jobs.fetch("lint").fetch("strategy")
raise "lint failures must not cancel another partition" unless lint.fetch("fail-fast") == false
matrix = lint.fetch("matrix")
raise "unexpected lint dimensions" unless matrix.keys == ["partition"]
parts = matrix.fetch("partition")
roots = parts.flat_map do |p|
  output, result = Open3.capture2(File.join(root, "bin/fm-lint.sh"), "--partition", "#{p}of#{parts.length}", "--list-files")
  raise "unsupported lint partition" unless result.success?
  output.lines.map(&:strip)
end
canonical_roots, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical_roots.lines.map(&:strip).sort
RUBY
  pass "CI serial shard jobs match the executable lanes one to one and canonical lint roots are covered exactly once"
}

# Every behavior-test job waits for the plan and runs only when the plan asks for
# it. A job the plan leaves out is skipped, which the forge reports as a skipped
# check rather than a pending one, so no required result is left waiting.
test_every_behavior_test_job_is_planned() {
  ruby -ryaml - "$CI_WORKFLOW" <<'RUBY' || fail "behavior test jobs must be planned"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
(%w[tests-portable-parallel-1 tests-portable-parallel-2 tests-herdr] + (1..25).map { |n| "tests-portable-serial-#{n}" }).each do |name|
  job = jobs.fetch(name)
  needs = Array(job["needs"])
  raise "#{name} must need the plan" unless needs.include?("plan")
  condition = job["if"].to_s
  raise "#{name} must run only when the plan asks for it, got #{condition.inspect}" unless condition.include?("needs.plan.outputs.")
end
%w[lint test-coverage invariants macos-stock-bash].each do |name|
  raise "#{name} runs on every change and must not depend on the plan" if Array(jobs.fetch(name)["needs"]).include?("plan")
end
RUBY
  pass "every behavior-test job is gated on the plan and the always-on jobs are not"
}

# The plan step is the shell that decides full or selected. Run it as written
# for every event that must run the whole suite, so a push to main or a manual
# run can never fall into a partial selection.
test_the_full_suite_runs_for_pushes_manual_runs_and_the_force_label() {
  local script out event label lane
  script=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("plan").fetch("steps")
puts steps.find { |s| s["id"] == "plan" }.fetch("run")
' "$CI_WORKFLOW") || fail "could not read the plan step"
  for event in push workflow_dispatch pull_request; do
    label=false
    case "$event" in
      pull_request)
        # A labeled pull request is forced full; an unlabeled one whose checkout
        # is not a merge commit is full too (the selector has no base to diff).
        label=true
        ;;
    esac
    out=$(run_plan_step "$script" "$event" "$label") || fail "the plan step failed for $event"
    assert_equals full "$(printf '%s\n' "$out" | sed -n 's/^mode=//p' | head -n 1)" "$event must run the full suite"
    assert_equals 25 "$(printf '%s\n' "$out" | sed -n 's/^serial_count=//p' | head -n 1)" "$event must plan every serial shard"
    for lane in parallel_1 parallel_2 herdr any_lane; do
      assert_equals true "$(printf '%s\n' "$out" | sed -n "s/^$lane=//p" | head -n 1)" "$event must plan $lane"
    done
  done
  out=$(run_plan_step "$script" pull_request false) || fail "the plan step failed for an unmerged checkout"
  assert_equals full "$(printf '%s\n' "$out" | sed -n 's/^mode=//p' | head -n 1)" "a pull request checkout that is not a merge commit must run the full suite"
  # A manual run that names a base replays the selection for that diff instead:
  # HEAD..HEAD changes nothing, so the replay selects nothing and plans no job.
  out=$(run_plan_step "$script" workflow_dispatch false HEAD) || fail "the plan step failed for a replay"
  assert_equals selected "$(printf '%s\n' "$out" | sed -n 's/^mode=//p' | head -n 1)" "a manual run with a base replays the selection"
  assert_equals false "$(printf '%s\n' "$out" | sed -n 's/^any_lane=//p' | head -n 1)" "an empty diff plans no behavior job"
  assert_equals 0 "$(printf '%s\n' "$out" | sed -n 's/^serial_count=//p' | head -n 1)" "and no serial shard"
  pass "pushes, manual runs, the ci-full label and an unmergeable checkout plan the full suite, and a manual replay plans the diff it is given"
}

# A replay diffs the given base against the checked-out HEAD, builds the graph
# from that same tree and plans the jobs that tree's runner owns. The checkout
# here is a copy of this tree with one more commit that edits a file a few tests
# read and deletes one of those tests: the deleted test must not be selected and
# every other reader must be, whatever stale head value the environment holds.
test_a_replay_diffs_graphs_and_plans_the_checked_out_head() {
  local script checkout probe=.tasks.toml readers victim expected out
  script=$(ruby -ryaml -e '
steps = YAML.load_file(ARGV[0]).fetch("jobs").fetch("plan").fetch("steps")
puts steps.find { |s| s["id"] == "plan" }.fetch("run")
' "$CI_WORKFLOW") || fail "could not read the plan step"
  checkout="$(fm_test_tmproot fm-ci-replay)/checkout"
  mkdir -p "$checkout"
  git -C "$ROOT" ls-files -z | tar -C "$ROOT" --null -T - -cf - 2>/dev/null | tar -C "$checkout" -xf -
  assert_present "$checkout/bin/fm-test-select.py" "the checkout copy is missing the selector"
  fm_git_identity
  git -C "$checkout" init -q -b main
  git -C "$checkout" add -A
  git -C "$checkout" commit -q -m base || fail "could not commit the checkout's base"
  readers=$(printf '%s\n' "$probe" | (cd "$checkout" && python3 bin/fm-test-select.py --paths-from -) | sed -n 's/^test=//p')
  victim=$(printf '%s\n' "$readers" | grep -vx tests/fm-ci-workflow.test.sh | head -n 1)
  [ -n "$victim" ] && [ "$(printf '%s\n' "$readers" | grep -c .)" -ge 2 ] \
    || fail "$probe must be read by at least two tests for this check, got: $readers"
  expected=$(printf '%s\n' "$readers" | grep -vx "$victim")
  printf '\n' >>"$checkout/$probe"
  git -C "$checkout" rm -q "$victim"
  git -C "$checkout" commit -q -a -m head || fail "could not commit the checkout's head"
  out=$(FM_REPLAY_HEAD=$(git -C "$checkout" rev-parse HEAD~1) \
    run_plan_step "$script" workflow_dispatch false HEAD~1 "$checkout") || fail "the plan step failed for a replay"
  assert_equals selected "$(printf '%s\n' "$out" | sed -n 's/^mode=//p' | head -n 1)" "a replay of a one-file change is a partial selection"
  assert_equals "$expected" "$(printf '%s\n' "$out" | sed -n '/^selection<</,/^FM_SELECTION_END$/p' | sed '1d;$d')" \
    "the replay selects every remaining reader of $probe and not the test HEAD deleted"
  assert_equals true "$(printf '%s\n' "$out" | sed -n 's/^any_lane=//p' | head -n 1)" "the checkout's runner plans the selected tests"
  pass "a manual replay diffs, graphs and plans the checked-out HEAD"
}

# Run the plan step's script in a scratch output directory and print what it
# would write to $GITHUB_OUTPUT. It runs from the repository root, as CI does,
# or from the given checkout.
run_plan_step() {  # <script> <event> <label> [<replay-base> [<checkout>]]
  local scratch
  scratch=$(fm_test_tmproot fm-ci-plan)
  : >"$scratch/output"
  : >"$scratch/summary"
  (
    cd "${5:-$ROOT}" || exit 1
    RUNNER_TEMP="$scratch" FM_EVENT_NAME=$2 FM_FULL_LABEL=$3 FM_REPLAY_BASE=${4:-} \
      GITHUB_OUTPUT="$scratch/output" GITHUB_STEP_SUMMARY="$scratch/summary" \
      bash -c "$1" >/dev/null 2>&1
  ) || return 1
  cat "$scratch/output"
}

# Each parallel job's runner invocation is read from its parsed run step and
# split into words, so the check is the --lane and --jobs the runner receives,
# whichever spelling or flag order the step uses.
test_parallel_lanes_pass_the_modeled_job_count() {
  local jobs
  jobs=$("$ROOT/bin/fm-test-run.sh" --check-coverage 2>/dev/null \
    | sed -n 's/.*parallel_jobs=\([0-9][0-9]*\).*/\1/p')
  [ -n "$jobs" ] || fail "the runner did not report parallel_jobs, so CI cannot be checked against the model"
  [ "$jobs" -gt 1 ] || fail "parallel_jobs must be greater than one, got $jobs"
  ruby -ryaml -rshellwords - "$CI_WORKFLOW" "$jobs" <<'RUBY' || fail "portable parallel CI job count"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
want = ARGV[1]
%w[1 2].each do |n|
  job = "tests-portable-parallel-#{n}"
  lane = "portable-parallel-#{n}"
  commands = jobs.fetch(job).fetch("steps").map { |s| s["run"] }.compact.flat_map do |run|
    run.gsub(/\\\n/, " ").lines.reject { |l| l.strip.start_with?("#") }.map { |l| Shellwords.split(l) }
  end.select { |words| words.first == "bin/fm-test-run.sh" }
  raise "#{job} must invoke bin/fm-test-run.sh exactly once, got #{commands.length}" unless commands.length == 1
  words = commands.first.drop(1)
  options = {}
  index = 0
  while index < words.length
    word = words[index]
    if (match = word.match(/\A--(lane|jobs)=(.*)\z/))
      options[match[1]] = match[2]
    elsif %w[--lane --jobs].include?(word)
      options[word.delete_prefix("--")] = words[index + 1]
      index += 1
    end
    index += 1
  end
  raise "#{job} must run --lane #{lane}, got #{options["lane"].inspect}" unless options["lane"] == lane
  raise "#{job} must pass --jobs #{want}, the count CI runs and the model starts from, got #{options["jobs"].inspect}" \
    unless options["jobs"] == want
end
RUBY
  pass "both portable parallel jobs pass the concurrency the model starts from"
}

test_ci_matrices_match_executable_partitions
test_every_behavior_test_job_is_planned
test_the_full_suite_runs_for_pushes_manual_runs_and_the_force_label
test_a_replay_diffs_graphs_and_plans_the_checked_out_head
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_coalesce_without_cancelling
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
test_parallel_lanes_pass_the_modeled_job_count
