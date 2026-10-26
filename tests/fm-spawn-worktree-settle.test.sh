#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the pane-path poll loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)
# Scale only the acquisition's one-second sleeps; fixture commands keep real time.
cat > "$TMP_ROOT/clock.sh" <<'SH'
sleep() {
  if [ "${1:-}" = 1 ]; then SECONDS=$((SECONDS + 60)); fi
  command sleep "$@"
}
SH

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*)
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_OUTPUT_PROGRESS:-0}" = 1 ]; then
      printf 'fetch progress %s\n' "$(cat "$FM_FAKE_PANE_COUNTFILE")"
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_COMPAT_LAUNCH_LOG:-}" ]; then
      for arg in "$@"; do
        case "$arg" in '. '*) printf '%s\n' "$arg" > "$FM_COMPAT_LAUNCH_LOG" ;; esac
      done
    fi
    exit 0 ;;

esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  HOME="$HOME_DIR/user-home" FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" BASH_ENV="$TMP_ROOT/clock.sh" \
    CLAUDE_CONFIG_DIR='' PI_CODING_AGENT_DIR='' OMP_PROFILE='' PI_PROFILE='' PI_CONFIG_DIR=.omp \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off "${@:2}" 2>&1
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 3 ] || fail "already-settled pane took $reads reads to confirm - expected the first read, one confirmation, and the launch-boundary cwd check"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "no path or output progress for 600s" \
    "spawn did not name the no-progress limit that ended the wait"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

test_slow_progressing_get_survives_old_window() {
  local rec id out status
  id=settle-slow-progress-z5
  rec=$(make_primary_case settle-slow-progress "$id" 12)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_OUTPUT_PROGRESS=1 run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "a get with output progress was refused: $out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "slow get did not publish its isolated copy"
  pass "a get with changing output keeps waiting beyond ten minutes of scaled total time"
}

test_progress_cannot_outlast_absolute_extreme() {
  local rec id out status
  id=settle-runaway-z6
  rec=$(make_primary_case settle-runaway "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_OUTPUT_PROGRESS=1 run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "endlessly changing output bypassed the absolute extreme"
  assert_contains "$out" "absolute extreme 1800s reached" \
    "spawn did not name the absolute extreme that ended the runaway wait"
  assert_not_contains "$out" "no path or output progress" \
    "ongoing output was counted as a stall"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "runaway acquisition published metadata"
  pass "output activity cannot keep an acquisition alive beyond the absolute extreme"
}

test_nonmeasured_harness_stays_unconfined_and_audited() {
  local rec id out source_line
  local FM_COMPAT_LAUNCH_LOG FM_COMPAT_MARKER FM_EXPECT_INBOX
  id=settle-unconfined-codex-z7
  rec=$(make_settle_case unconfined-codex "$id" 0)
  read_settle_record "$rec"
  FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
  FM_COMPAT_MARKER="$HOME_DIR/foreign-write-proof"
  FM_EXPECT_INBOX="$HOME_DIR/state/$id.inbox"
  export FM_COMPAT_LAUNCH_LOG FM_COMPAT_MARKER FM_EXPECT_INBOX
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'codex-cli 1.0.0\n'; exit 0; fi
if [ "${FM_TASK_INBOX:-}" = "${FM_EXPECT_INBOX:?}" ]; then
  printf 'unconfined\n' > "${FM_COMPAT_MARKER:?}"
fi
SH
  chmod +x "$FAKEBIN_DIR/codex"
  out=$(run_settle_spawn "$id")
  expect_code 0 "$?" "non-measured codex spawn was refused: $out"
  if [ "$(uname -s)" = Darwin ]; then
    assert_grep 'write_confinement=unconfined-macos-codex' "$HOME_DIR/state/$id.meta" "unconfined codex coverage absent from metadata"
    assert_contains "$out" 'harness=codex write_confinement=unconfined-macos-codex' "coverage audit did not name codex"
  fi
  assert_absent "$FM_COMPAT_MARKER" "preflight ran the compatibility probe as a worker"
  assert_present "$FM_COMPAT_LAUNCH_LOG" "spawn did not deliver a launch command"
  source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
  PATH="$FAKEBIN_DIR:$PATH" bash -c "$source_line"
  expect_code 0 "$?" "delivered codex launch did not execute unchanged"
  assert_equals unconfined "$(cat "$FM_COMPAT_MARKER")" "codex unexpectedly acquired a write boundary"
  pass "non-measured harness launches unchanged and explicitly reports unconfined coverage"
}

# write_claude_session_probe <fakebin> installs a model-free stand-in for
# Claude's own session writes: this session's session-env, file-history and
# tasks entries and its transcript under the slug of its working directory, then the
# same entries for a foreign session id.
write_claude_session_probe() {
  cat > "$1/claude-session-probe" <<'SH'
#!/usr/bin/env bash
root=$1 session=$2 other=$3
slug=$(cd "$4" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')
own=created foreign=refused
for id in "$session" "$other"; do
  for entry in "session-env/$id/probe" "file-history/$id/probe" "tasks/$id/probe" "projects/$slug/$id.jsonl"; do
    if { mkdir -p "$root/$(dirname "$entry")" && : >> "$root/$entry"; } 2>/dev/null; then written=1; else written=0; fi
    if [ "$id" = "$session" ]; then
      [ "$written" = 1 ] || own="refused:$entry"
    else
      [ "$written" = 0 ] || foreign="created:$entry"
    fi
  done
done
echo "own=$own"
echo "other=$foreign"
SH
  chmod +x "$1/claude-session-probe"
}

# The launch fm-spawn delivers for a measured harness runs inside the generated
# profile: a model-free stand-in for the harness records what it could do.
test_measured_harness_launch_runs_confined() {
  local harness rec id out source_line probe before version session_probe session other slug
  local FM_COMPAT_LAUNCH_LOG
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: macOS Seatbelt launch; Linux remains unconfined\n'
    return 0
  fi
  for harness in omp claude; do
    id=settle-confined-$harness-z8
    rec=$(make_settle_case "confined-$harness" "$id" 0)
    read_settle_record "$rec"
    printf '%s\n' "$harness" > "$HOME_DIR/config/crew-harness"
    FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
    export FM_COMPAT_LAUNCH_LOG
    probe="$HOME_DIR/data/$id/probe"
    version='omp/18.12.4'
    [ "$harness" = omp ] || version='2.1.310 (Claude Code)'
    cat > "$FAKEBIN_DIR/$harness" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version) printf '%s\\n' '$version'; exit 0 ;; esac
[ "\${FM_TASK_INBOX:-}" = '$HOME_DIR/state/$id.inbox' ] || exit 0
{
  if { printf 'replaced' >> '$PROJ_DIR/README.md'; } 2>/dev/null; then echo foreign=written; else echo foreign=refused; fi
  if { printf 'probe-status-append\\n' >> '$HOME_DIR/state/$id.status'; } 2>/dev/null; then echo status=appended; else echo status=refused; fi
  echo "tmpdir=\$TMPDIR"
  echo "confinement=\$FM_WRITE_CONFINEMENT"
} > '$probe'
SH
    session_probe="$HOME_DIR/data/$id/claude-session-probe"
    other=99999999-8888-4777-8666-555555555555
    if [ "$harness" = claude ]; then
      # An existing 0755 config root: the session folders the spawn creates
      # are owner-only, and a folder that was already there keeps its mode.
      mkdir -p "$HOME_DIR/user-home/.claude/unrelated"
      chmod 755 "$HOME_DIR/user-home/.claude" "$HOME_DIR/user-home/.claude/unrelated"
      write_claude_session_probe "$FAKEBIN_DIR"
      cat >> "$FAKEBIN_DIR/claude" <<SH
session=
while [ \$# -gt 0 ]; do [ "\$1" != --session-id ] || session=\$2; shift; done
{
  echo "session-id=\$session"
  claude-session-probe '$HOME_DIR/user-home/.claude' "\$session" '$other' '$WT_DIR'
} > '$session_probe'
SH
    fi
    chmod +x "$FAKEBIN_DIR/$harness"
    before=$(cat "$PROJ_DIR/README.md")
    out=$(run_settle_spawn "$id")
    expect_code 0 "$?" "confined $harness spawn was refused: $out"
    assert_grep 'write_confinement=seatbelt-v1' "$HOME_DIR/state/$id.meta" "confined $harness coverage absent from metadata"
    if [ "$harness" = claude ]; then
      slug=$(cd "$WT_DIR" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')
      assert_equals '755 755 700 700 700 700 700' "$(cd "$HOME_DIR/user-home/.claude" \
        && stat -f %Lp . unrelated session-env file-history tasks projects "projects/$slug" | tr '\n' ' ' | sed 's/ $//')" \
        "the spawn must create the Claude session folders owner-only and leave existing folders unchanged"
    fi
    assert_present "$FM_COMPAT_LAUNCH_LOG" "spawn did not deliver a $harness launch command"
    source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
    PATH="$FAKEBIN_DIR:$PATH" bash -c "$source_line"
    assert_present "$probe" "delivered $harness launch did not reach the harness"
    assert_equals $'foreign=refused\nstatus=appended\ntmpdir=/tmp/fm-'"$id"$'\nconfinement=seatbelt-v1' "$(cat "$probe")" \
      "delivered $harness launch ran outside its write profile"
    assert_equals "$before" "$(cat "$PROJ_DIR/README.md")" "confined $harness changed the primary checkout"
    assert_grep 'probe-status-append' "$HOME_DIR/state/$id.status" "confined $harness could not append its own status"
    if [ "$harness" = claude ]; then
      session=$(grep '^claude_session_id=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
      [ -n "$session" ] && [ "$(grep -c '^claude_session_id=' "$HOME_DIR/state/$id.meta")" = 1 ] \
        || fail "confined claude metadata must record exactly one session id"
      assert_equals "session-id=$session"$'\nown=created\nother=refused' "$(cat "$session_probe")" \
        "delivered claude launch must run under the recorded session id its profile grants, and only that one"
    fi
  done
  pass "measured harness launches run inside their generated write profile"
}

# A confined raw claude launch keeps running through the TeamClaude wrapper's
# --exec with the recorded session id spliced in, and its literal config root
# assignment becomes the root its write profile grants.
test_confined_raw_claude_launch_runs_through_teamclaude() {
  local rec id out source_line probe session raw_root other=99999999-8888-4777-8666-555555555555
  local FM_COMPAT_LAUNCH_LOG
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: macOS Seatbelt launch; Linux remains unconfined\n'
    return 0
  fi
  id=settle-raw-claude-z9
  rec=$(make_settle_case raw-claude "$id" 0)
  read_settle_record "$rec"
  printf 'teamclaude\n' > "$HOME_DIR/config/claude-launcher"
  fm_test_fake_teamclaude "$FAKEBIN_DIR"
  raw_root="$(dirname "$HOME_DIR")/raw claude root"
  mkdir -p "$raw_root"
  write_claude_session_probe "$FAKEBIN_DIR"
  probe="$HOME_DIR/data/$id/probe"
  cat > "$FAKEBIN_DIR/claude" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version) printf '2.1.310 (Claude Code)\\n'; exit 0 ;; esac
[ "\${FM_TASK_INBOX:-}" = '$HOME_DIR/state/$id.inbox' ] || exit 0
session=
[ "\${1:-}" != --session-id ] || session=\$2
{
  echo "session-id=\$session"
  echo "args=\${*:3}"
  echo "config=\$CLAUDE_CONFIG_DIR"
  echo "proxy=\${HTTPS_PROXY:+set}"
  claude-session-probe "\$CLAUDE_CONFIG_DIR" "\$session" '$other' '$WT_DIR'
} > '$probe'
SH
  chmod +x "$FAKEBIN_DIR/claude"
  FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
  export FM_COMPAT_LAUNCH_LOG
  # shellcheck disable=SC2016 # the literal substitution is the refused raw launch text
  if out=$(run_settle_spawn "$id" --harness 'claude --print $(claude --help)'); then fail "raw Claude spawn silently accepted command substitution: $out"; fi
  case "$out" in *'command substitution'*'named harness'*) ;; *) fail "raw Claude refusal omitted construct or remedy: $out" ;; esac
  assert_absent "$FM_COMPAT_LAUNCH_LOG" "a refused raw Claude command must not reach the worker"
  out=$(run_settle_spawn "$id" --harness "CLAUDE_CONFIG_DIR='$raw_root' claude --resume $other --model opus")
  expect_code 0 "$?" "confined raw claude spawn was refused: $out"
  assert_grep 'write_confinement=seatbelt-v1' "$HOME_DIR/state/$id.meta" "confined raw claude coverage absent from metadata"
  session=$(grep '^claude_session_id=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
  [ -n "$session" ] || fail "confined raw claude metadata must record its session id"
  assert_present "$FM_COMPAT_LAUNCH_LOG" "spawn did not deliver the raw claude launch"
  source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
  PATH="$FAKEBIN_DIR:$PATH" bash -c "$source_line"
  assert_equals "session-id=$session"$'\nargs=--fork-session --resume '"$other"$' --model opus\nconfig='"$raw_root"$'\nproxy=set\nown=created\nother=refused' "$(cat "$probe")" \
    "the raw claude launch must reach claude through TeamClaude under its recorded session id, with only that session writable in its own root"
  pass "a confined raw claude launch runs through TeamClaude with its session id and literal config root granted"
}

# A raw launch that runs claude after another command, behind a named wrapper or
# in a shell's -c text takes the Claude profile too.
test_compound_raw_claude_launch_runs_confined() {
  local rec id out source_line probe session raw index=0
  local FM_COMPAT_LAUNCH_LOG
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: macOS Seatbelt launch; Linux remains unconfined\n'
    return 0
  fi
  for raw in '[ -d src ] && cd src; claude --print hi' 'true && claude --print hi' '[[ -f README.md ]] && claude --print hi' \
    'env -u FM_UNSET_PROBE claude --print hi' "bash -c 'claude --print hi'"; do
    index=$((index + 1))
    id=settle-raw-compound-$index-z9
    rec=$(make_settle_case "raw-compound-$index" "$id" 0)
    read_settle_record "$rec"
    probe="$HOME_DIR/data/$id/probe"
    cat > "$FAKEBIN_DIR/claude" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version) printf '2.1.310 (Claude Code)\\n'; exit 0 ;; esac
[ "\${FM_TASK_INBOX:-}" = '$HOME_DIR/state/$id.inbox' ] || exit 0
session=
[ "\${1:-}" != --session-id ] || session=\$2
{
  echo "session-id=\$session"
  echo "args=\${*:3}"
  echo "confinement=\$FM_WRITE_CONFINEMENT"
  if { printf 'replaced' >> '$PROJ_DIR/README.md'; } 2>/dev/null; then echo foreign=written; else echo foreign=refused; fi
} > '$probe'
SH
    chmod +x "$FAKEBIN_DIR/claude"
    FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
    export FM_COMPAT_LAUNCH_LOG
    out=$(run_settle_spawn "$id" --harness "$raw")
    expect_code 0 "$?" "compound raw claude spawn was refused: $out"
    assert_equals claude "$(grep '^harness=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)" "compound raw claude launch was not recorded as claude: $raw"
    assert_grep 'write_confinement=seatbelt-v1' "$HOME_DIR/state/$id.meta" "compound raw claude launch ran unconfined: $raw"
    session=$(grep '^claude_session_id=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)
    [ -n "$session" ] || fail "compound raw claude metadata must record its session id"
    assert_present "$FM_COMPAT_LAUNCH_LOG" "spawn did not deliver the compound raw claude launch"
    source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
    (cd "$WT_DIR" && PATH="$FAKEBIN_DIR:$PATH" bash -c "$source_line")
    assert_equals "session-id=$session"$'\nargs=--print hi\nconfinement=seatbelt-v1\nforeign=refused' "$(cat "$probe")" \
      "compound raw claude launch must run inside its profile under its recorded session id: $raw"
  done
  # A claude found after a leading command, followed by a construct the Claude
  # route cannot rewrite, refuses rather than launching claude unconfined.
  # shellcheck disable=SC2016 # the literal constructs are the refused raw launch text
  for raw in 'true && claude --print "$(date)"' 'true && claude --print `date`' 'true && env "$PROGRAM" --print hi; claude --print hi'; do
    index=$((index + 1))
    id=settle-raw-compound-$index-z9
    rec=$(make_settle_case "raw-compound-$index" "$id" 0)
    read_settle_record "$rec"
    FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
    export FM_COMPAT_LAUNCH_LOG
    if out=$(run_settle_spawn "$id" --harness "$raw"); then fail "compound raw claude spawn with an unprovable construct was accepted: $raw: $out"; fi
    case "$out" in *'error: malformed raw launch command'*'repair: '*) ;; *) fail "compound raw claude refusal omitted the construct or repair: $raw: $out" ;; esac
    grep -F '"guard":"spawn-write-confinement"' "$HOME_DIR/state/guard-events.jsonl" 2>/dev/null | grep -qF '"decision":"deny"' \
      || fail "a refused compound raw claude spawn must record its write-confinement deny: $raw"
    assert_absent "$FM_COMPAT_LAUNCH_LOG" "a refused compound raw claude command must not reach the worker: $raw"
    assert_absent "$HOME_DIR/state/$id.meta" "a refused compound raw claude spawn published task metadata: $raw"
  done
  # Text the scanner cannot read before it finds a claude launches unchanged and
  # unconfined under its first program, recorded as such.
  index=$((index + 1))
  id=settle-raw-compound-$index-z9
  rec=$(make_settle_case "raw-compound-$index" "$id" 0)
  read_settle_record "$rec"
  FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
  export FM_COMPAT_LAUNCH_LOG
  probe="$HOME_DIR/data/$id/probe"
  cat > "$FAKEBIN_DIR/claude" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version) printf '2.1.310 (Claude Code)\\n'; exit 0 ;; esac
[ "\${FM_TASK_INBOX:-}" = '$HOME_DIR/state/$id.inbox' ] || exit 0
printf 'args=%s\\nconfinement=%s\\n' "\$*" "\$FM_WRITE_CONFINEMENT" > '$probe'
SH
  chmod +x "$FAKEBIN_DIR/claude"
  out=$(run_settle_spawn "$id" --harness 'true && (claude --print hi)')
  expect_code 0 "$?" "an unreadable raw launch must launch unchanged: $out"
  assert_equals true "$(grep '^harness=' "$HOME_DIR/state/$id.meta" | cut -d= -f2-)" "an unreadable raw launch must keep its first program"
  assert_grep 'write_confinement=unconfined-macos-true' "$HOME_DIR/state/$id.meta" "an unreadable raw launch must record that it runs unconfined"
  source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
  (cd "$WT_DIR" && PATH="$FAKEBIN_DIR:$PATH" bash -c "$source_line")
  assert_equals $'args=--print hi\nconfinement=unconfined-macos-true' "$(cat "$probe")" \
    "an unreadable raw launch must run its command unchanged, with no session id, as recorded"
  pass "a raw launch that runs claude after another command, behind a named wrapper or in shell -c text runs confined under its session id"
}

# make_unconfined_claude_case <name> <id> builds a Linux-simulated settle home
# whose fake claude records its argv and, when its second argument is a readable
# file, that file's contents. It binds the settle globals itself and leaves the
# delivered-launch log armed, so a caller only reads the record of its own case.
make_unconfined_claude_case() {
  local name=$1 id=$2 rec
  rec=$(make_settle_case "$name" "$id" 0)
  read_settle_record "$rec"
  if [ "$(uname -s)" != Linux ]; then
    cat > "$FAKEBIN_DIR/uname" <<'SH'
#!/usr/bin/env bash
[ "$*" != -s ] || { echo Linux; exit 0; }
exec /usr/bin/uname "$@"
SH
    chmod +x "$FAKEBIN_DIR/uname"
  fi
  cat > "$FAKEBIN_DIR/claude" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version) printf '2.1.310 (Claude Code)\\n'; exit 0 ;; esac
[ "\${FM_TASK_INBOX:-}" = '$HOME_DIR/state/$id.inbox' ] || exit 0
{
  printf 'args=%s\\n' "\$*"
  if [ -r "\${2:-}" ]; then printf 'prompt=%s\\n' "\$(cat "\$2")"; else printf 'prompt=\\n'; fi
} > '$HOME_DIR/data/$id/probe'
SH
  chmod +x "$FAKEBIN_DIR/claude"
  FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
  export FM_COMPAT_LAUNCH_LOG
  return 0
}

# An unconfined raw claude launch keeps the earlier memory-prefix placement, so
# shell constructs the confined session rewrite refuses still launch there.
test_unconfined_raw_claude_launch_keeps_shell_constructs() {
  local rec id out source_line probe
  local FM_COMPAT_LAUNCH_LOG
  id=settle-raw-claude-linux-z9
  rec=$(make_settle_case raw-claude-linux "$id" 0)
  read_settle_record "$rec"
  if [ "$(uname -s)" != Linux ]; then
    cat > "$FAKEBIN_DIR/uname" <<'SH'
#!/usr/bin/env bash
[ "$*" != -s ] || { echo Linux; exit 0; }
exec /usr/bin/uname "$@"
SH
    chmod +x "$FAKEBIN_DIR/uname"
  fi
  probe="$HOME_DIR/data/$id/probe"
  cat > "$FAKEBIN_DIR/claude" <<SH
#!/usr/bin/env bash
case "\${1:-}" in --version) printf '2.1.310 (Claude Code)\\n'; exit 0 ;; esac
[ "\${FM_TASK_INBOX:-}" = '$HOME_DIR/state/$id.inbox' ] || exit 0
printf '%s\\n' "\$@" > '$probe'
SH
  chmod +x "$FAKEBIN_DIR/claude"
  FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
  export FM_COMPAT_LAUNCH_LOG
  # shellcheck disable=SC2016 # the literal constructs are the raw launch text under test
  out=$(run_settle_spawn "$id" --harness 'claude --print "$(printf hi)" --model "${RAW_MODEL:-opus}"')
  expect_code 0 "$?" "unconfined raw claude spawn refused a shell construct: $out"
  assert_grep 'write_confinement=unconfined-linux' "$HOME_DIR/state/$id.meta" "unconfined raw claude coverage absent from metadata"
  assert_no_grep 'claude_session_id=' "$HOME_DIR/state/$id.meta" "an unconfined raw claude launch must not record a session id"
  assert_present "$FM_COMPAT_LAUNCH_LOG" "spawn did not deliver the unconfined raw claude launch"
  source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
  PATH="$FAKEBIN_DIR:$PATH" bash -c "$source_line"
  assert_equals $'--print\nhi\n--model\nopus' "$(cat "$probe")" \
    "the unconfined raw claude launch must run its shell constructs unchanged and without a session id"
  pass "an unconfined raw claude launch keeps shell constructs and gets no session id"
}


# A Bash-only construct keeps working on the unconfined route: the caller's own
# command reaches the pane shell, and a real dash pane still runs a POSIX one.
test_unconfined_raw_claude_launch_keeps_the_caller_shell() {
  local id out source_line staged probe
  local FM_COMPAT_LAUNCH_LOG
  id=settle-raw-claude-caller-z9
  make_unconfined_claude_case raw-claude-caller "$id"
  probe="$HOME_DIR/data/$id/probe"
  # --allow-api-key with no account pin and the ordinary launcher is the
  # configuration the earlier review measured: nothing else wraps this route.
  # shellcheck disable=SC2016 # the literal constructs are the raw launch text under test
  out=$(run_settle_spawn "$id" --harness 'claude --print "$(printf hi)" --model "${RAW_MODEL:-opus}"' --allow-api-key)
  expect_code 0 "$?" "unconfined raw claude spawn refused a shell construct: $out"
  assert_present "$FM_COMPAT_LAUNCH_LOG" "spawn did not deliver the unconfined raw claude launch"
  source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
  staged=${source_line#". '"}
  staged=${staged%"'"}
  [ -n "$staged" ] || staged=$source_line
  assert_no_grep '/bin/sh -c' "$staged" "an unconfined raw claude launch must keep the caller's command instead of handing it to this host's /bin/sh"
  : > "$probe"
  PATH="$FAKEBIN_DIR:$PATH" bash -c "$source_line"
  expect_code 0 "$?" "a bash pane could not run the delivered unconfined launch"
  assert_equals $'args=--print hi --model opus\nprompt=' "$(cat "$probe")" \
    "the unconfined raw claude launch must run its shell constructs unchanged"
  if [ -x /bin/dash ]; then
    : > "$probe"
    PATH="$FAKEBIN_DIR:$PATH" /bin/dash -c "$source_line"
    expect_code 0 "$?" "a dash pane could not run the delivered unconfined launch"
    assert_equals $'args=--print hi --model opus\nprompt=' "$(cat "$probe")" \
      "the unconfined raw claude launch must still run under a real dash pane shell"
  else
    printf 'skip: /bin/dash is absent, so the dash pane-shell run is skipped\n'
  fi
  # Bash-only syntax stays under the pane's own shell: a process substitution must
  # reach claude as data, never fail as a /bin/sh parse error of the raw text.
  id=settle-raw-claude-bash-z9
  make_unconfined_claude_case raw-claude-bash "$id"
  probe="$HOME_DIR/data/$id/probe"
  # shellcheck disable=SC2016 # the literal process substitution is the raw launch text under test
  out=$(run_settle_spawn "$id" --harness 'claude --print <(printf hi)' --allow-api-key)
  expect_code 0 "$?" "unconfined raw claude spawn refused a process substitution: $out"
  assert_no_grep '/bin/sh -c' "$FM_COMPAT_LAUNCH_LOG" "a Bash-only unconfined raw claude launch must not be handed to this host's /bin/sh"
  source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
  : > "$probe"
  PATH="$FAKEBIN_DIR:$PATH" bash -c "$source_line"
  expect_code 0 "$?" "a bash pane could not run the delivered process-substitution launch"
  assert_grep 'args=--print /dev/fd/' "$probe" "the process substitution did not reach claude as its prompt argument"
  assert_grep 'prompt=hi' "$probe" "the process substitution prompt did not reach claude intact"
  pass "an unconfined raw claude launch keeps the caller's shell and never gains a host /bin/sh"
}

# make_pane_shell_case <name> <id> builds a settle home whose fake omp records
# the argv it was run with, so a test can prove which shell parsed the launch.
make_pane_shell_case() {
  local name=$1 id=$2 rec
  rec=$(make_settle_case "$name" "$id" 0)
  read_settle_record "$rec"
  mkdir -p "$HOME_DIR/user-home"
  cat > "$FAKEBIN_DIR/omp" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != --version ] || { printf 'omp/18.1.20\\n'; exit 0; }
for argument in "\$@"; do printf 'arg=%s\\n' "\$argument"; done > '$HOME_DIR/data/$id/probe'
SH
  chmod +x "$FAKEBIN_DIR/omp"
  FM_COMPAT_LAUNCH_LOG="$HOME_DIR/delivered-launch"
  export FM_COMPAT_LAUNCH_LOG
  return 0
}

# A confined raw launch is parsed by the pane's own shell, not by this host's
# bash: a zsh-only modifier keeps working from a zsh pane, and a bash-only
# construct still runs from a dash pane, which falls back to /bin/bash.
test_confined_raw_launch_keeps_the_pane_shell() {
  local id out source_line staged probe zsh_bin dash_bin bash_bin expected_home
  local FM_COMPAT_LAUNCH_LOG
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: only the macOS seatbelt route re-parses through a pane shell\n'
    return 0
  fi
  zsh_bin=$(command -v zsh || true)
  dash_bin=
  [ ! -x /bin/dash ] || dash_bin=/bin/dash
  bash_bin=$(command -v bash || true)
  [ -n "$bash_bin" ] || fail "no bash on PATH for the bash pane case"
  id=settle-pane-shell-z9
  make_pane_shell_case pane-shell "$id"
  probe="$HOME_DIR/data/$id/probe"
  # shellcheck disable=SC2016 # the literal zsh modifier is the raw launch text under test
  out=$(run_settle_spawn "$id" --harness 'omp --config "${${HOME}:A}/worker.yml"')
  expect_code 0 "$?" "a confined raw omp launch with a zsh-only modifier was refused: $out"
  assert_grep 'write_confinement=seatbelt-v1' "$HOME_DIR/state/$id.meta" "the raw omp launch recorded no seatbelt coverage"
  assert_present "$FM_COMPAT_LAUNCH_LOG" "spawn did not deliver the confined raw omp launch"
  source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
  staged=${source_line#". '"}
  staged=${staged%"'"}
  [ -n "$staged" ] || staged=$source_line
  assert_grep '${fm_launch_shell:-/bin/bash}' "$staged" "the confined launch must select the pane shell with a /bin/bash fallback"
  expected_home=$(cd "$HOME_DIR/user-home" && pwd -P) || fail "the fixture HOME root is unreadable"
  if [ -n "$zsh_bin" ]; then
    # The replay must carry the same HOME the spawn gave its launch, or the
    # zsh modifier resolves against the operator's home instead of the fixture's.
    : > "$probe"
    env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
      "$zsh_bin" -c "$source_line"
    expect_code 0 "$?" "a zsh pane could not run the delivered confined launch: $(cat "$probe")"
    assert_grep 'arg=--config' "$probe" "the confined launch did not reach omp from a zsh pane"
    assert_grep "arg=$expected_home/worker.yml" "$probe" \
      "a zsh pane must resolve its own modifier inside the confined launch: $(cat "$probe")"
  else
    printf 'skip: zsh is absent, so the zsh pane case is not run\n'
  fi
  id=settle-pane-shell-expansion-z9
  make_pane_shell_case pane-shell-expansion "$id"
  probe="$HOME_DIR/data/$id/probe"
  out=$(run_settle_spawn "$id" --harness 'omp --config /tmp/{pane,shell}.yml')
  expect_code 0 "$?" "a confined raw omp launch with a brace list was refused: $out"
  source_line=$(cat "$FM_COMPAT_LAUNCH_LOG")
  # A bash pane keeps the caller's bash-only argument form: the brace list
  # expands before omp runs.
  : > "$probe"
  env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    "$bash_bin" -c "$source_line"
  expect_code 0 "$?" "a bash pane could not run the delivered confined launch: $(cat "$probe")"
  assert_grep 'arg=--config' "$probe" "the confined launch did not reach omp from a bash pane"
  assert_grep 'arg=/tmp/pane.yml' "$probe" "a bash pane must expand the caller's brace list"
  assert_grep 'arg=/tmp/shell.yml' "$probe" "a bash pane must expand the caller's whole brace list"
  if [ -n "$dash_bin" ]; then
    # dash cannot parse that form itself, so the same two arguments prove the
    # selected /bin/bash fallback ran the caller's text.
    : > "$probe"
    env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
      "$dash_bin" -c "$source_line"
    expect_code 0 "$?" "a dash pane could not run the delivered confined launch: $(cat "$probe")"
    assert_grep 'arg=--config' "$probe" "the confined launch did not reach omp from a dash pane"
    assert_grep 'arg=/tmp/pane.yml' "$probe" "a dash pane must hand the caller's bash-only text to /bin/bash"
    assert_grep 'arg=/tmp/shell.yml' "$probe" "a dash pane must let /bin/bash expand the caller's brace list"
  else
    printf 'skip: /bin/dash is absent, so the fallback pane case is not run\n'
  fi
  pass "a confined raw launch keeps the pane shell, with /bin/bash as the fallback"
}

# These are shell-language cases, not vendor behavior: execute only a task-local
# fake claude and compare the real Bash argv/stdin before and after rewriting.
test_raw_claude_shell_data_fidelity() {
  python3 - "$ROOT/bin/fm-raw-launch.py" "$TMP_ROOT/raw-shell" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

helper, directory = sys.argv[1:]
base = Path(directory)
base.mkdir()
fake = base / "claude"
fake.write_text("#!/usr/bin/env python3\nimport json,sys\nprint(json.dumps([sys.argv[1:],sys.stdin.read()]))\n")
fake.chmod(0o755)
env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ["PATH"])
session = "12345678-1234-4234-8234-123456789012"
marker = " --session-id " + session
bodies = [
    ("reviewer", "claude --print <<'PROMPT'\nA plain CLI usage example follows.\nclaude --help\nPROMPT\n"),
    ("literal", "claude --print <<END\nclaude --help\nEND\n"),
    ("double-quoted", 'claude --print <<"END"\nclaude --help\nEND\n'),
    ("tab-stripped", "claude --print <<-END\n\tclaude --help\n\tEND\n"),
    ("multiple", "claude --print <<ONE <<'TWO'\nclaude --help\nONE\nclaude --version\nTWO\n"),
    ("quoted", "claude --print 'a literal line\nclaude --help'"),
    ("quoted-placeholder", "claude --print '__CLAUDESESSION__ __CLAUDERAWPREFIX__'"),
    ("quoted-substitution-data", "claude --print <<'END'\n$(claude --help) `claude --help`\nEND\n"),
    ("comment", "claude --print <<END # claude --help\nclaude --help\nEND\n"),
    ("option-terminator", "claude -- --resume"),
    ("quoted-expansion-data", "claude --print '$FLAGS ${X} * [x] {a,b} --session-id x' \"literal \\$HOME\""),
    ("value-session-id", "claude --append-system-prompt --session-id --print hello"),
]
for label, source in bodies:
    rendered = subprocess.run([sys.executable, helper, "render-claude", source, session, ""], check=True, capture_output=True, text=True).stdout
    assert rendered == source.replace("claude", "claude" + marker, 1), label
    assert rendered.count(marker) == 1, label
    validated = subprocess.run([sys.executable, helper, "render-claude", source, "", ""], check=True, capture_output=True, text=True).stdout
    assert validated == source, label
    before = subprocess.run(["bash", "-c", source], check=True, capture_output=True, text=True, env=env)
    after = subprocess.run(["bash", "-c", rendered], check=True, capture_output=True, text=True, env=env)
    old_args, old_stdin = json.loads(before.stdout)
    args, stdin = json.loads(after.stdout)
    assert args == ["--session-id", session] + old_args, label
    assert stdin == old_stdin, label
    print("ok - raw Claude shell data byte fidelity:", label)
for source in ("[ -d src ] && cd src; claude --print hi", "[[ -f x ]] && claude --print hi"):
    rendered = subprocess.run([sys.executable, helper, "render-claude", source, session, ""], check=True, capture_output=True, text=True).stdout
    assert rendered == source.replace("claude", "claude" + marker, 1), source
    print("ok - raw Claude accepts a test bracket command:", source)
# A claude behind a named wrapper gets the session id after its own word; these
# wrappers run here, so the real argv proves it.
for source in (
    "env claude --print hi", "env -u FM_UNSET_PROBE claude --print hi", "env -- FOO=1 claude --print hi",
    "command claude --print hi", "exec claude --print hi", "exec -a worker claude --print hi",
    "nohup claude --print hi", "time claude --print hi", "time -p claude --print hi", "nice claude --print hi",
    "nice -n 5 claude --print hi", "true && nohup env -u X nice -n 1 claude --print hi",
):
    rendered = subprocess.run([sys.executable, helper, "render-claude", source, session, ""], check=True, capture_output=True, text=True).stdout
    assert rendered == source.replace("claude", "claude" + marker, 1), (source, rendered)
    args, _ = json.loads(subprocess.run(["bash", "-c", rendered], check=True, capture_output=True, text=True, env=env).stdout)
    assert args == ["--session-id", session, "--print", "hi"], (source, args)
    print("ok - raw Claude renders a claude behind a named wrapper:", source)
# Wrappers that may be absent on this host, or that clear the search path for
# the fake claude: the rendered command is the contract.
for source in (
    "env -i FOO=1 claude --print hi", "command -p claude --print hi", "timeout 3600 claude --print hi", "timeout -k 5 -s TERM 10 claude --print hi", "caffeinate claude --print hi",
    "caffeinate -i claude --print hi", "caffeinate -t 60 -di claude --print hi", "arch -arm64 claude --print hi",
    "arch -x86_64 claude --print hi", "arch -arch arm64 -e A=b claude --print hi", "stdbuf -o0 -e L claude --print hi",
    "stdbuf -i 0 claude --print hi", "timeout \"$T\" claude --print hi", "env -u \"$V\" A=\"$X\" claude --print hi",
):
    rendered = subprocess.run([sys.executable, helper, "render-claude", source, session, ""], check=True, capture_output=True, text=True).stdout
    assert rendered == source.replace("claude", "claude" + marker, 1), (source, rendered)
    print("ok - raw Claude renders a claude behind a named wrapper:", source)
# A shell's -c text is read by the same rules; the id and the prefix go inside
# that text, which runs with the same meaning.
for source, prefix in (
    ("bash -c 'claude --print hi'", ""), ("sh -e -c 'cd . && claude --print hi' name", ""),
    ("bash -lc \"nohup claude --print hi\"", "env "), ("zsh -c 'claude --print hi'", "command "),
):
    if source.startswith("zsh") and not any(Path(d, "zsh").exists() for d in os.environ["PATH"].split(os.pathsep)):
        print("skip: zsh is absent, so the zsh -c render case is not run")
        continue
    rendered = subprocess.run([sys.executable, helper, "render-claude", source, session, prefix], check=True, capture_output=True, text=True).stdout
    assert marker in rendered and rendered != source, (source, rendered)
    args, _ = json.loads(subprocess.run(["bash", "-c", rendered], check=True, capture_output=True, text=True, env=env).stdout)
    assert args == ["--session-id", session, "--print", "hi"], (source, rendered, args)
    print("ok - raw Claude renders a claude in shell -c text:", source)
forks = [
    ["--resume", "old-session"], ["-r", "old-session"], ["--continue"], ["-c"],
    ["--resume=old-session"], ["-rold-session"], ["-pc"], ["-p", "-cr"],
    ["--append-system-prompt", "--", "--resume", "old-id"],
    ["--model", "--", "--continue"],
    ["--append-system-prompt", "--fork-session", "--resume", "old-id"],
    ["-n", "--print", "-c"],
]
unforked = [
    ["--append-system-prompt", "--continue", "--print", "hello"],
    ["--append-system-prompt=--continue", "--print", "hello"],
    ["-n", "--resume", "--print", "hello"],
    ["-n--continue", "--print", "hello"],
    ["--print", "--", "--resume"],
    ["--resume", "old-session", "--fork-session"],
]
for fork, cases in ((["--fork-session"], forks), ([], unforked)):
    for arguments in cases:
        source = "claude " + " ".join("'" + argument + "'" for argument in arguments)
        rendered = subprocess.run([sys.executable, helper, "render-claude", source, session, ""], check=True, capture_output=True, text=True).stdout
        result = subprocess.run(["bash", "-c", rendered], input="resume prompt", check=True, capture_output=True, text=True, env=env)
        args, stdin = json.loads(result.stdout)
        assert args == ["--session-id", session] + fork + arguments, (arguments, args)
        assert stdin == "resume prompt", stdin
        print("ok - raw Claude", "forks" if fork else "does not fork", "for:", " ".join(arguments))
refusals = [
    ("command substitution", "claude --print $(claude --help)"),
    ("command substitution", "claude --print $(cat <<END\nclaude --help\nEND\n)"),
    ("backtick", "claude --print `claude --help`"),
    ("backtick", "claude --print `cat <<END\nclaude --help\nEND\n`"),
    ("double quote", 'claude --print "$(claude --help)"'),
    ("here-document", "claude <<END\n$(claude --help)\nEND\n"),
    ("line continuation in here-document delimiter", "claude <<E\\\nND\n$(claude --help)\nEND\n"),
    ("unterminated single quote", "claude 'prompt"),
    ("unterminated double quote", 'claude "prompt'),
    ("unterminated here-document", "claude <<END\nclaude --help\n"),
    ("unterminated here-document", "claude <<END"),
    ("process substitution", "claude <(claude --help)"),
    ("here-string", "claude <<<prompt"),
    ("--session-id", "claude --session-id 12345678-1234-4234-8234-123456789999 --print hi"),
    ("--session-id", "claude --print hi --session-id=other"),
    ("shell expansion", "claude $FLAGS"),
    ("shell expansion", 'claude --print "$PROMPT"'),
    ("shell expansion", "claude --model claude-sonnet-5-5[1m]"),
    ("shell expansion", "claude --print *.md"),
    ("shell expansion", "claude {--resume,old-id}"),
    ("shell expansion", "claude --x=[ab]"),
    ("shell expansion", "bash -c 'claude $FLAGS'"),
    ("--session-id", "env -u X claude --session-id=other --print hi"),
    ("expanded program word", "env \"$X\" claude --print hi"),
    ("expanded program word", "nice -n $N claude --print hi"),
    ("expanded program word", "bash -c \"$CMD\""),
    ("shell control structure", "eval claude --print hi"),
]
for construct, source in refusals:
    for extra in ([session, ""], ["", ""]):
        result = subprocess.run([sys.executable, helper, "render-claude", source, *extra], capture_output=True, text=True)
        assert result.returncode != 0 and result.stdout == "", (construct, extra)
        assert construct in result.stderr and "named harness" in result.stderr, (construct, result.stderr)
    print("ok - raw Claude refuses:", construct)
# A plain parameter expansion is data when it only fills an argument; a claude
# behind a named wrapper or in shell -c text is found, and any other program in
# front of claude, or an expansion that names the program, is not.
scanned = [
    ("codex --config \"${HOME}/worker.yml\"", 1, "reads a quoted argument expansion"),
    ("codex --config \"$HOME/worker.yml\"", 1, "reads a quoted unbraced argument expansion"),
    ("FOO=$X codex --config \"$Y\"", 1, "reads a leading assignment expansion"),
    ("codex --config $HOME/worker.yml", 1, "reads an unquoted parameter expansion"),
    ("codex --config ${~P}", 2, "refuses a forced pattern"),
    ("codex --config $~P", 2, "refuses a forced pattern"),
    ("codex --config ${=P}", 2, "refuses a forced splitting form"),
    ("codex --config \"$~P\"", 2, "refuses a forced pattern in a quote"),
    ("codex --config \"${HOME}/x.yml\" && claude --print hi", 0, "still finds a later claude command"),
    ("claude --settings \"${HOME}/s.json\"", 0, "reads a claude argument expansion"),
    ("\"$CMD\" --x", 1, "does not see a program an expanded command word names"),
    ("${CMD} --x", 1, "does not see a program a braced command word names"),
    ("codex --config \"$(claude -p hi)\"", 2, "refuses a command substitution in an argument"),
    ("codex --config \"${(e)PAYLOAD}\"", 2, "refuses zsh parameter expansion flags"),
    ("codex --config `claude -p hi`", 2, "refuses a backtick in an argument"),
    ("true && claude --print \"$(date)\"", 0, "finds a claude before text it cannot read"),
    ("true && (claude --print hi)", 2, "cannot read a grouped claude"),
    ("sh -c \"${X}\"", 1, "does not see a program expanded shell -c text names"),
    ("sh -c code=\"$CMD\"", 1, "does not see a program assignment-shaped shell -c text names"),
    ("bash -lc \"$X\"", 1, "does not see a program expanded shell -c text names"),
    ("env \"$X\" --print hi", 1, "does not see a program an expanded env argument names"),
    ("nohup \"$X\" --print hi", 1, "does not see a program an expanded nohup argument names"),
    ("time \"$CMD\" --x", 1, "does not see a program an expanded time argument names"),
    ("command \"$X\" --print hi", 1, "does not see a program an expanded command argument names"),
    ("if [ -n \"$LOCK\" ]; then omp --resume=bare-session; fi", 1, "reads an expansion in a test command"),
    ("env claude --print hi", 0, "finds claude behind env"),
    ("env -u X claude --print hi", 0, "finds claude behind env -u"),
    ("env -i FOO=1 claude --print hi", 0, "finds claude behind env assignments"),
    ("env -- FOO=1 claude --print hi", 0, "finds claude behind env assignments after --"),
    ("command claude --print hi", 0, "finds claude behind command"),
    ("exec claude --settings \"$HOME/s.json\"", 0, "finds claude behind exec"),
    ("nohup claude --print hi", 0, "finds claude behind nohup"),
    ("time claude --print hi", 0, "finds claude behind time"),
    ("timeout 3600 claude --print hi", 0, "finds claude behind timeout and its duration"),
    ("nice -n 5 claude --print hi", 0, "finds claude behind nice"),
    ("caffeinate claude --print hi", 0, "finds claude behind caffeinate"),
    ("caffeinate -i claude --print hi", 0, "finds claude behind caffeinate -i"),
    ("arch -arm64 claude --print hi", 0, "finds claude behind arch"),
    ("stdbuf -o0 claude --print hi", 0, "finds claude behind stdbuf"),
    ("true && nohup env -u X caffeinate -i claude --print hi", 0, "finds claude behind nested wrappers"),
    ("bash -c 'claude --print hi'", 0, "finds claude in bash -c text"),
    ("sh -e -c 'cd src && claude --print hi'", 0, "finds claude in sh -c text"),
    ("zsh -c 'nohup claude --print hi'", 0, "finds claude behind a wrapper in zsh -c text"),
    ("flock /tmp/lock claude --print hi", 1, "does not find claude behind a wrapper outside the named list"),
    ("sudo claude --print hi", 1, "does not find claude behind sudo"),
    ("env -S 'claude --print hi'", 1, "does not find claude behind an env option outside the named list"),
    ("command -v claude", 1, "does not take command -v for a claude run"),
    ("bash script.sh", 1, "does not read a shell script"),
    ("timeout \"$T\" claude --print hi", 0, "finds claude behind a quoted timeout duration"),
    ("env A=\"$X\" claude -p hi", 0, "finds claude behind a quoted env assignment"),
    ("env -u \"$V\" claude -p hi", 0, "finds claude behind a quoted env -u name"),
    ("nice -n \"$N\" claude -p hi", 0, "finds claude behind a quoted nice value"),
    ("bash -c \"claude -p $X\"", 0, "finds claude in quoted shell -c text"),
    ("true && timeout \"$T\" claude --print hi", 0, "finds claude behind a quoted timeout duration after a command"),
    ("bash --login -c 'claude -p hi'", 0, "finds claude past bash --login"),
    ("bash --norc -c 'claude -p hi'", 0, "finds claude past bash --norc"),
    ("bash --noprofile -c 'claude -p hi'", 0, "finds claude past bash --noprofile"),
    ("bash -O extglob -c 'claude -p hi'", 0, "finds claude past bash -O and its shopt name"),
    ("timeout $T claude --print hi", 1, "does not decide claude behind an unquoted expansion that can split"),
    ("env $OPTS claude --print hi", 1, "does not decide claude behind an unquoted env expansion"),
]
for source, expected, label in scanned:
    result = subprocess.run([sys.executable, helper, "runs-claude", source], capture_output=True, text=True)
    assert result.returncode == expected, (label, source, result.returncode, result.stderr)
    print("ok - raw launch scanner", label + ":", source)
PY
  expect_code 0 "$?" "raw Claude shell-data or refusal regression failed"
}

test_raw_claude_shell_data_fidelity
test_nonmeasured_harness_stays_unconfined_and_audited
test_measured_harness_launch_runs_confined
test_confined_raw_claude_launch_runs_through_teamclaude
test_compound_raw_claude_launch_runs_confined
test_unconfined_raw_claude_launch_keeps_shell_constructs
test_unconfined_raw_claude_launch_keeps_the_caller_shell
test_confined_raw_launch_keeps_the_pane_shell
test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_slow_progressing_get_survives_old_window
test_progress_cannot_outlast_absolute_extreme

echo "# all fm-spawn-worktree-settle tests passed"
