#!/usr/bin/env bash
# Shared definitions and fixture setup for the independently runnable
# captain-hold suites: tests/fm-captain-hold-lifecycle.test.sh,
# fm-captain-hold-sweep.test.sh, fm-captain-hold-keyed-answers.test.sh,
# fm-captain-hold-reconcile.test.sh, fm-captain-hold-cleanup.test.sh, and
# fm-captain-hold-archive.test.sh. Together they are the end-to-end tests for
# captain-held tasks: the one primitive behind "a decision is simply a task
# waiting on the captain", its completion gate, its recorded answers, the
# record-divergence guard over its two records, and the legacy compatibility for
# pre-collapse decision identities.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  git init -q -b main "$home/projects/sample" || fail "could not initialize sample project fixture"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  # Cleanup removes a task's own Docker objects, so without a stand-in it would
  # reach this host's real Docker daemon.
  fm_fake_docker "$fakebin"
  printf '%s\n' "$home"
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
}

# The Lavish review adapter, run against this suite's isolated home. The
# machine-wide process-event claim root is redirected into the fixture so arming
# a review here can never contend with a real one on this machine.
run_lavish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}

# The generic process-event runner, run against this suite's isolated home and
# its own claim root, so a review armed here can never contend with a real one.
run_procevent() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_PROCEVENT_CLAIM_ROOT="$home/procevent-claims" \
    "$ROOT/bin/fm-procevent.sh" "$@"
}

run_bearings() {  # <home> [extra args]
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-14T12:00:00Z \
    "$BEARINGS" --json "$@"
}

run_teardown() {  # <home> <id>
  local home=$1 id=$2
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id"
}

tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@")
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# Completes <id>'s captain-call inventory through a separate held task, because
# the origin task is never accepted as its own inventory entry.
complete_through_sibling() {  # <home> <origin-id>
  local home=$1 id=$2
  run_captain "$home" hold "$id-call" --title "Sibling captain call for $id" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    && run_captain "$home" complete "$id" "$id-call"
}

request_reconciles() {  # <home> <source-id> <task-id>...
  local home=$1 source_id=$2 id
  shift 2
  run_captain "$home" bind "$source_id" >/dev/null || return 1
  for id in "$@"; do printf '%s\n' "$id"; done \
    | run_captain "$home" reconcile-requests --source-id "$source_id" \
        --source "captured board result" >/dev/null
}

# Runs independent fixture cells at once, the way the retry matrix does. Each
# cell is a function name plus plain words, builds its own homes under unique
# names, and ends the way any case does: `fail` exits its subshell nonzero.
run_cells_in_parallel() {  # <label> <cell command>...
  local label=$1 dir cell n=0 failed=''
  shift
  dir=$(mktemp -d "$TMP_ROOT/cells.XXXXXX") || fail "could not create the $label results directory"
  for cell in "$@"; do
    n=$((n + 1))
    # shellcheck disable=SC2086
    (${cell} > "$dir/$n.log" 2>&1; echo $? > "$dir/$n.rc") &
  done
  wait
  n=0
  for cell in "$@"; do
    n=$((n + 1))
    [ "$(cat "$dir/$n.rc" 2>/dev/null)" = 0 ] \
      || failed="$failed${failed:+; }cell '$cell': $(tail -n 3 "$dir/$n.log" | tr '\n' ' ')"
  done
  [ -z "$failed" ] || fail "$label failures: $failed"
}

configure_merged_github() {  # <home>
  local home=$1
  cat > "$home/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *state,headRefOid,url*)
        printf 'MERGED\t%s\t%s\n' "${FM_TEST_MERGED_HEAD:-}" "${FM_TEST_MERGED_PR:-}"
        ;;
      *mergeStateStatus*)
        printf '%s\n' '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"1111111111111111111111111111111111111111","baseRefName":"main"}'
        ;;
      *headRefOid*) printf '%s\n' 1111111111111111111111111111111111111111 ;;
    esac
    ;;
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}" ;;
  "api graphql")
    case "$*" in
      *'contexts(first:'*)
        printf '%s\n' '{"data":{"repository":{"object":{"oid":"1111111111111111111111111111111111111111","statusCheckRollup":{"contexts":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"__typename":"CheckRun","id":"ci-1","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}}}}}}'
        ;;
      *) printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main' ;;
    esac
    ;;
  "api --paginate")
    case " $* " in
      *merge_queue*) ;;
      *) printf '%s\n' '[]' ;;
    esac
    ;;
  "api repos/"*) printf '%s\n' '{"name":"main","protected":false}' ;;
esac
SH
  cat > "$home/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
case "${1:-} ${2:-}" in
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
esac
SH
  chmod +x "$home/fakebin/gh" "$home/fakebin/gh-axi"
  : > "$home/gh.log"
  : > "$home/gh-axi.log"
}

run_pr_merge() {  # <home> <id> <url>
  local home=$1
  shift
  # Each fixture merge carries an independent PASS for the live head.
  printf 'VERDICT: PASS head=%s\n' 1111111111111111111111111111111111111111 > "$home/review.md"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-review-record.py" review \
    --pr "$2" --head 1111111111111111111111111111111111111111 \
    --verdict PASS --reader-model claude-opus-5-5 --author-groups '{"all":["gpt-5.1-codex"]}' \
    --loosens-deny-allow-list no --widens-guard no --customer-data-billing-spend no \
    --report "$home/review.md" >/dev/null || return
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_GH_LOG="$home/gh.log" \
    FM_TEST_GH_AXI_LOG="$home/gh-axi.log" "$ROOT/bin/fm-pr-merge.sh" "$@"
}

# Wait for <path> to appear, or for <pid> to exit. The wait is on that event, never
# on a poll count: how long cleanup takes to reach a barrier depends on host load.
test_pid_exited() {  # <pid>
  local stat
  kill -0 "$1" 2>/dev/null || return 0
  stat=$(ps -p "$1" -o stat= 2>/dev/null || true)
  case "$stat" in ''|Z*) return 0 ;; esac
  return 1
}

wait_for_test_file() {  # <path> <pid>
  # The 120 s ceiling only bounds a hang; it is the fake treehouse barrier's own 120 s hold.
  local path=$1 pid=$2 deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    [ -e "$path" ] && return 0
    if test_pid_exited "$pid"; then
      [ -e "$path" ]
      return
    fi
    sleep 0.01
  done
  return 1
}

install_reused_task_barriers() {  # <home>
  local home=$1
  cat > "$home/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_REUSE_TEARDOWN:-}" = 1 ] \
    && [ ! -e "${FM_TEST_REUSE_TEARDOWN_ONCE:-}" ]; then
  : > "$FM_TEST_REUSE_TEARDOWN_ONCE"
  : > "$FM_TEST_REUSE_TEARDOWN_READY"
  while [ ! -e "$FM_TEST_REUSE_TEARDOWN_RELEASE" ] \
      && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    "$FM_TEST_REAL_SLEEP" 0.01
  done
fi
exec "$FM_TEST_REAL_PERL" "$@"
SH
  cat > "$home/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_REUSE_MERGE:-}" = 1 ] && [ "${1:-}" = 0.1 ] \
    && [ ! -e "${FM_TEST_REUSE_MERGE_ONCE:-}" ]; then
  : > "$FM_TEST_REUSE_MERGE_ONCE"
  : > "$FM_TEST_REUSE_MERGE_READY"
  while [ ! -e "$FM_TEST_REUSE_MERGE_RELEASE" ] \
      && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    "$FM_TEST_REAL_SLEEP" 0.01
  done
fi
exec "$FM_TEST_REAL_SLEEP" "$@"
SH
  chmod +x "$home/fakebin/perl" "$home/fakebin/sleep"
}

# The retired command surface, kept for one release as a shim; in-flight
# pre-collapse work still drives the lifecycle through these spellings.
run_shim() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-decision-hold.sh" "$@"
}

write_origin_meta() {  # <home> <id> [kind]
  local home=$1 id=$2 kind=${3:-scout}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=$kind" \
    "mode=$kind" \
    "spawn_gen=fixture-$id"
}

# --- markdown-to-beads migration resolution ----------------------------------
#
# A home on the Beads backend no longer carries the legacy markdown ids a scout
# report attested: fm-hold-migration rehomed each held row under a prefixed fm-
# id and recorded its markdown identity in the row's notes as the exact line
# "migrated from data/backlog.md id <legacy id>". The fixture graph is driven
# through bd directly where possible because the npm-published tasks-axi ships
# the markdown backend only; the hold itself needs a beads-capable tasks-axi,
# so that family probes once and skips itself with an explicit reason on
# markdown-only installs, mirroring tests/fm-control-relaunch-recovery.test.sh.

# Build a fixture home whose configured backend is a scratch Beads graph.
# Echoes "<home>|<graph-beads-dir>". The graph repo dir is named "fm" because
# bd derives the row-id prefix from the repo directory name.
make_beads_home() {  # <name>
  local name=$1 case_dir home graph fb
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  graph="$case_dir/fm"
  mkdir -p "$home/data" "$home/config" "$home/projects" "$graph"
  (umask 077; mkdir -p "$home/state")
  git -C "$graph" init -q
  if ! (cd "$graph" && bd init >"$case_dir/bd-init.log" 2>&1); then
    cat "$case_dir/bd-init.log" >&2
    fail "fixture bd init failed on $graph"
  fi
  cat > "$home/.tasks.toml" <<EOF
backend = "beads"

[beads]
path = "$graph/.beads"
binary = "bd"
prefix = "fm"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
EOF
  fb=$(fm_fakebin "$home")
  fm_fake_exit0 "$fb" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home|$graph/.beads"
}

bdrow() {  # <beads-dir> <args...>
  BEADS_DIR="$1" bd "${@:2}"
}

# One capability probe for the migration family: can the installed tasks-axi
# operate on a beads-backed home? The npm-published tasks-axi cannot, and the
# hold fixture needs its beads backend; those installs skip with this reason.
probe_tasks_axi_beads() {
  local probe_home="$TMP_ROOT/.probe" probe_graph="$TMP_ROOT/.probe-fm"
  rm -rf "$probe_home" "$probe_graph"
  mkdir -p "$probe_home/data" "$probe_graph"
  git -C "$probe_graph" init -q
  (cd "$probe_graph" && bd init >/dev/null 2>&1) || return 1
  cat > "$probe_home/.tasks.toml" <<PROBEEOF
backend = "beads"

[beads]
path = "$probe_graph/.beads"
binary = "bd"
prefix = "fm"
PROBEEOF
  (cd "$probe_home" && tasks-axi list) >/dev/null 2>&1
}
TASKS_AXI_BEADS_OK=0
if bd --version >/dev/null 2>&1 && jq --version >/dev/null 2>&1 \
   && probe_tasks_axi_beads; then
  TASKS_AXI_BEADS_OK=1
fi

require_tasks_axi_beads() {  # <what>
  [ "$TASKS_AXI_BEADS_OK" = 1 ] && return 0
  pass "skipped on markdown-only tasks-axi: $1"
  return 1
}

write_scout_with_attested_inventory() {  # <home> <scout-id> <keys>
  local home=$1 scout=$2 keys=$3
  mkdir -p "$home/data/$scout"
  fm_write_meta "$home/state/$scout.meta" \
    "window=firstmate:fm-$scout" \
    "worktree=$home/projects/missing-$scout" \
    "project=$home/projects/sample" \
    "harness=codex" \
    "kind=scout" \
    "spawn_gen=fixture-$scout" \
    "decisions_reviewed=1" \
    "decision_keys=$keys"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Report\n\nThe investigation finished.\n' > "$home/data/$scout/report.md"
}

# A tasks-axi stub that knows ONLY the row ids it is given. The real
# beads-capable tasks-axi resolves a bare legacy id onto its prefixed row
# itself, answering before any migration lookup runs; against this stub the
# migrated-hold resolution order is what has to answer.
write_known_rows_stub() {  # <fakebin> <row-id...>
  local fb=$1 known
  shift
  known=$(printf '%s|' "$@")
  cat > "$fb/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '%s\n' '0.2.6' ;;
  update)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '--archive-body'
    ;;
  mv)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'usage: tasks-axi mv [<id>...]'
    ;;
  hold)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' '  --kind captain'
    ;;
  show)
    case "${2:-}" in
      @KNOWN@) ;;
      *) printf 'error: no task %s in this backlog\ncode: NOT_FOUND\n' "${2:-}" >&2; exit 1 ;;
    esac
    printf '%s\n' 'task:'
    printf '  id: %s\n' "$2"
    printf '%s\n' '  state: queued' '  held: yes' '  blocked: no' \
      '  hold_kind: captain' '  body: ""'
    ;;
  *) exit 1 ;;
esac
SH
  sed -i.bak "s%@KNOWN@%${known%|}%" "$fb/tasks-axi"
  rm -f "$fb/tasks-axi.bak"
  chmod +x "$fb/tasks-axi"
}

# Runs this suite's `tests` array, or only the named cases, then proves cleanup
# left no process-event runner or watchdog behind.
captain_hold_run_tests() {  # [case-name...]
  local requested candidate selected selected_test
  if [ "$#" -gt 0 ]; then
    for requested in "$@"; do
      selected=0
      for candidate in "${tests[@]}"; do
        [ "$requested" != "$candidate" ] || selected=1
      done
      [ "$selected" -eq 1 ] || fail "unknown captain hold lifecycle test: $requested"
    done
    tests=("$@")
  fi
  for selected_test in "${tests[@]}"; do
    "$selected_test" || exit "$?"
  done

  # Run the ordinary home-scoped cleanup before checking actual process state.
  # The watchdog may be asleep until its next owner check after a runner exits.
  fm_test_cleanup
  perl -MTime::HiRes=time,sleep -e '
    my ($root) = @ARGV;
    my $deadline = time + 10;
    while (1) {
      open my $ps, "-|", "ps", "axeww", "-o", "pid=", "-o", "command=" or die "ps: $!";
      my @leaked = grep {
        index($_, "$root/") >= 0 &&
        m{/fm-procevent[.]sh\s+(?:_start|_owner-watchdog)\s}
      } <$ps>;
      close $ps or die "cannot inspect process-event cleanup";
      exit 0 unless @leaked;
      die "runner or watchdog survived lifecycle cleanup:\n", @leaked if time >= $deadline;
      sleep 0.1;
    }
  ' "$TMP_ROOT" || fail "captain-hold lifecycle leaked a runner or watchdog"
  pass "captain-hold lifecycle leaves no runner or watchdog processes"
}
