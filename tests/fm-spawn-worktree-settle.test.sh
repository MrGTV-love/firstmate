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

# A raw launch that runs claude after another command takes the Claude profile
# too, so a leading test or command cannot start Claude outside it.
test_compound_raw_claude_launch_runs_confined() {
  local rec id out source_line probe session raw index=0
  local FM_COMPAT_LAUNCH_LOG
  if [ "$(uname -s)" != Darwin ]; then
    printf 'skip: macOS Seatbelt launch; Linux remains unconfined\n'
    return 0
  fi
  for raw in '[ -d src ] && cd src; claude --print hi' 'true && claude --print hi'; do
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
  pass "a raw launch that runs claude after another command runs confined under its session id"
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
]
for construct, source in refusals:
    for extra in ([session, ""], ["", ""]):
        result = subprocess.run([sys.executable, helper, "render-claude", source, *extra], capture_output=True, text=True)
        assert result.returncode != 0 and result.stdout == "", (construct, extra)
        assert construct in result.stderr and "named harness" in result.stderr, (construct, result.stderr)
    print("ok - raw Claude refuses:", construct)
PY
  expect_code 0 "$?" "raw Claude shell-data or refusal regression failed"
}

test_raw_claude_shell_data_fidelity
test_nonmeasured_harness_stays_unconfined_and_audited
test_measured_harness_launch_runs_confined
test_confined_raw_claude_launch_runs_through_teamclaude
test_compound_raw_claude_launch_runs_confined
test_unconfined_raw_claude_launch_keeps_shell_constructs
test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_slow_progressing_get_survives_old_window
test_progress_cannot_outlast_absolute_extreme

echo "# all fm-spawn-worktree-settle tests passed"
