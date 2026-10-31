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
FAST_TIER_JOBS='test-coverage invariants tests-timing-aggregate'
NORMAL_TIER_JOBS='lint tests-portable-parallel-1 tests-portable-parallel-2 tests-portable-serial macos-stock-bash'
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

test_ci_matrices_match_executable_partitions() {
  ruby -ryaml -ropen3 - "$CI_WORKFLOW" "$ROOT" <<'RUBY' || fail "CI partition contract"
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
root = ARGV[1]
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
raise "serial failures must not cancel other shards" unless serial.fetch("fail-fast") == false
matrix = serial.fetch("matrix")
raise "unexpected serial dimensions" unless matrix.keys == ["shard"]
shards = matrix.fetch("shard")
lanes, status = Open3.capture2(File.join(root, "bin/fm-test-run.sh"), "--list-lanes")
raise "cannot list runner lanes" unless status.success?
actual = lanes.lines.map(&:strip).select { |l| l.match?(/\Aportable-serial-\d+of\d+\z/) }
expected = shards.map { |s| "portable-serial-#{s}of#{shards.length}" }
raise "CI matrix and runner disagree" unless actual.sort == expected.sort
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
canonical, result = Open3.capture2({"CI" => "true"}, File.join(root, "bin/fm-lint.sh"), "--list-files")
raise "lint matrix loses or duplicates canonical roots" unless result.success? && roots.sort == canonical.lines.map(&:strip).sort
RUBY
  pass "CI matrices cover every executable serial lane and canonical lint root exactly once"
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

# Execute each producer's shell on an actual merge checkout, then resolve the
# upload inputs from its outputs. This catches recording the event base rather
# than the merge parent (a rerun may have a newer event base).
test_pull_request_uploads_actual_tested_tree() {
  ruby -ryaml -rtmpdir -ropen3 -rjson - "$ROOT" <<'RUBY' || fail "pull_request tested-tree artifacts"
root = ARGV.fetch(0)
%w[ci no-mistakes-required].each do |workflow|
  doc = YAML.load_file("#{root}/.github/workflows/#{workflow}.yml")
  context = {"github.event_name" => "pull_request", "matrix.partition" => 1,
             "github.run_attempt" => 3}
  expand = lambda do |value|
    value.to_s.gsub(/\$\{\{\s*(.*?)\s*\}\}/) { context.fetch(Regexp.last_match(1)).to_s }
  end
  enabled = lambda do |step|
    next true unless step.key?("if")
    expression = step.fetch("if").gsub(/github\.event_name|matrix\.partition/) { |key| JSON.generate(context.fetch(key)) }
    eval(expression) # The fixture resolves workflow predicates, not shell source.
  end
  uploads = []
  doc.fetch("jobs").each_value do |job|
    steps = job.fetch("steps", [])
    steps.each_with_index do |step, index|
      next unless step.fetch("uses", "").start_with?("actions/upload-artifact@")
      next unless step.fetch("with").fetch("name").start_with?("fm-tested-tree-")
      next unless enabled.call(step)
      raise "tree upload needs a checkout first" unless steps.take(index).any? { |s| s.fetch("uses", "").start_with?("actions/checkout@") }
      producer = steps.take(index).find { |s| s["id"] == "tested-tree" && enabled.call(s) }
      raise "no enabled producer" unless producer
      Dir.mktmpdir("fm-workflow-tree-") do |dir|
        git = lambda do |*args|
          out, status = Open3.capture2e("git", "-C", dir, *args)
          raise out unless status.success?
          out.strip
        end
        git.call("init", "-q")
        git.call("config", "user.name", "fixture")
        git.call("config", "user.email", "fixture@example.invalid")
        File.write("#{dir}/base", "base")
        git.call("add", "."); git.call("commit", "-qm", "base")
        base = git.call("rev-parse", "HEAD")
        git.call("checkout", "-qb", "fixture-pr")
        File.write("#{dir}/head", "head")
        git.call("add", "."); git.call("commit", "-qm", "head")
        head = git.call("rev-parse", "HEAD")
        git.call("checkout", "-q", "--detach", base)
        git.call("merge", "--no-ff", "-qm", "merge", head)
        tree = git.call("rev-parse", "HEAD^{tree}")
        output = "#{dir}/outputs"
        env = {"GITHUB_OUTPUT" => output, "RUNNER_TEMP" => dir}
        result, status = Open3.capture2e(env, "bash", "-eu", "-c", producer.fetch("run"), chdir: dir)
        raise result unless status.success?
        File.readlines(output, chomp: true).each do |line|
          key, value = line.split("=", 2)
          context["steps.tested-tree.outputs.#{key}"] = value
        end
        context["runner.temp"] = dir
        inputs = step.fetch("with")
        name = expand.call(inputs.fetch("name"))
        raise "record does not bind actual checked tree, merge parent and attempt: #{name}" unless name == "fm-tested-tree-#{tree}-base-#{base}-attempt-3"
        raise "upload payload missing" unless File.read(expand.call(inputs.fetch("path"))).split == [tree, base]
        uploads << name
      end
    end
  end
  raise "#{workflow}: no PR run record uploaded" if uploads.empty?
end
RUBY
  pass "both pull_request workflows upload the actual checked merge tree and parent for the run attempt"
}

test_pull_request_uploads_actual_tested_tree
test_ci_matrices_match_executable_partitions
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_coalesce_without_cancelling
test_every_job_has_a_finite_timeout
test_every_job_belongs_to_exactly_one_timeout_tier
test_fast_tier_shares_one_short_tripwire
test_normal_tier_shares_one_budget
test_heavy_tier_keeps_a_step_tripwire_under_a_job_backstop
test_parallel_lanes_pass_the_modeled_job_count
