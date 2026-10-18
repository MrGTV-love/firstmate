#!/usr/bin/env bash
# Finished-board sweep regressions: which Lavish board listeners the sweep
# retires or keeps, and how bound captain keys resolve at the sweep.
# Shared definitions and fixture setup live in fm-captain-hold-lifecycle-helpers.sh.
set -u

# shellcheck source=tests/fm-captain-hold-lifecycle-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-captain-hold-lifecycle-helpers.sh"

# A Lavish listener lives as long as its Lavish session, and a captain answers a
# board with choice forms that never end the session, so every board ever armed
# kept its resident processes until someone retired it by hand: 25 were live on
# a host at load 102, most of them for boards eight days idle. The sweep retires
# a listener only when its board is provably finished, and keeps everything that
# could still carry a captain answer. Each scenario below is a board the sweep
# must keep or retire for a different reason; the live-listener case proves the
# retirement actually stops the resident poll, not just the registration.
sweep_session() {  # <store-dir> <artifact> <status> <queued-prompts> <updated-at|->
  mkdir -p "$1"
  perl -MJSON::PP -MCwd=realpath -MDigest::SHA=sha256_hex -e '
    my ($dir, $art, $status, $queued, $updated) = @ARGV;
    my $path = "$dir/state.json";
    my $doc = { sessions => {} };
    if (-f $path) { open my $in, "<", $path or die $!; local $/; $doc = decode_json(<$in>); }
    my $real = realpath($art) // die "missing artifact";
    my $key = substr(sha256_hex($real), 0, 16);
    my $session = {
      key => $key, file => $real, url => "http://127.0.0.1:14387/session/$key",
      status => $status, pending_prompts => $queued + 0,
    };
    $session->{updated_at} = $updated unless $updated eq "-";
    $doc->{sessions}{$key} = $session;
    open my $out, ">", $path or die $!;
    print $out encode_json($doc);
  ' "$@"
}

sweep_board() {  # <home> <name> <age: old|new> <card-key...>: write one board, print its path
  local home=$1 name=$2 age=$3 file key
  shift 3
  mkdir -p "$home/boards"
  file="$home/boards/$name.html"
  {
    printf '<h1>%s</h1>\n' "$name"
    for key in "$@"; do
      printf '<form data-lavish-question="%s"><button>go</button></form>\n' "$key"
    done
  } > "$file"
  [ "$age" != old ] || touch -t 200001010000 "$file"
  printf '%s\n' "$file"
}

sweep_register() {  # <home> <artifact>: register its listener without starting it, print the source id
  local home=$1 artifact=$2 sid
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive a source id"
  run_procevent "$home" register lavish "$sid" -- \
    "$ROOT/bin/fm-procevent-lavish.sh" poll "$artifact" >/dev/null \
    || fail "could not register the board listener"
  printf '%s\n' "$sid"
}

test_sweep_retires_only_finished_board_listeners() {
  local home store out rc list before after unreadable unreadable_id
  local gone ended nosession dormant closed openheld fresh queued owned standing pending
  local gone_id ended_id nosession_id dormant_id closed_id openheld_id fresh_id queued_id owned_id standing_id pending_id
  local session syntax board sid kept_count
  local -a protected_ids=()
  home=$(make_home board-sweep)
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  store="$home/lavish-state"
  fm_fake_exit0 "$home/fakebin" lavish-axi

  run_captain "$home" hold sweep-open-call --title "Choose the sweep route" \
    --reason "captain sweep route pending" --repo sample >/dev/null \
    || fail "could not hold the open captain call"
  run_captain "$home" hold sweep-closed-call --title "Choose the closed route" \
    --reason "captain closed route pending" --repo sample >/dev/null \
    || fail "could not hold the call that is answered below"
  printf 'north\n' > "$home/answer.txt"
  run_captain "$home" answer sweep-closed-call --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not answer the call"

  gone=$(sweep_board "$home" gone old)
  ended=$(sweep_board "$home" ended new sweep-closed-call)
  nosession=$(sweep_board "$home" nosession new sweep-closed-call)
  dormant=$(sweep_board "$home" dormant old sweep-closed-call)
  closed=$(sweep_board "$home" closed old sweep-closed-call)
  openheld=$(sweep_board "$home" openheld old sweep-open-call)
  fresh=$(sweep_board "$home" fresh new sweep-closed-call)
  queued=$(sweep_board "$home" queued old)
  owned=$(sweep_board "$home" owned old)
  standing="$home/boards/standing.html"
  mkdir -p "$home/.lavish"
  printf '<h1>standing</h1>\n' > "$standing"
  ln -s "$standing" "$home/.lavish/bearings-board.html"
  touch -t 200001010000 "$standing"
  pending=$(sweep_board "$home" pending old sweep-closed-call)

  gone_id=$(sweep_register "$home" "$gone")
  ended_id=$(sweep_register "$home" "$ended")
  nosession_id=$(sweep_register "$home" "$nosession")
  dormant_id=$(sweep_register "$home" "$dormant")
  closed_id=$(sweep_register "$home" "$closed")
  openheld_id=$(sweep_register "$home" "$openheld")
  fresh_id=$(sweep_register "$home" "$fresh")
  queued_id=$(sweep_register "$home" "$queued")
  standing_id=$(sweep_register "$home" "$standing")
  pending_id=$(sweep_register "$home" "$pending")
  owned_id=$(run_lavish "$home" source-id "$owned") || fail "could not derive the owned source id"
  printf 'window=fmtest:fm-sweep-owner\nworktree=%s/worktree-sweep-owner\nproject=fmtest\n' "$home" \
    > "$home/state/sweep-owner.meta"
  run_procevent "$home" register-task lavish "$owned_id" sweep-owner -- \
    "$ROOT/bin/fm-procevent-lavish.sh" poll "$owned" >/dev/null \
    || fail "could not register the worker-owned board"

  for session in ended nosession idle; do
    for syntax in quoted single unquoted uppercase hex decimal invalid valueless unreadable; do
      board=$(sweep_board "$home" "$session-$syntax" new)
      case "$syntax" in
        quoted) printf '<form data-lavish-question="sweep-open-call"></form>\n' > "$board" ;;
        single) printf "<form data-lavish-question='sweep-open-call'></form>\n" > "$board" ;;
        unquoted) printf '<form data-lavish-question=sweep-open-call></form>\n' > "$board" ;;
        uppercase) printf '<form DATA-LAVISH-QUESTION="sweep-open-call"></form>\n' > "$board" ;;
        hex) printf '<form data-lavish-question="sweep&#x2d;open-call"></form>\n' > "$board" ;;
        decimal) printf '<form data-lavish-question="sweep&#45;open-call"></form>\n' > "$board" ;;
        invalid) printf '<form data-lavish-question="sweep-closed-call"></form><form data-lavish-question="bad&amp;key"></form>\n' > "$board" ;;
        valueless) printf '<form data-lavish-question></form>\n' > "$board" ;;
      esac
      [ "$session" != idle ] || touch -t 200001010000 "$board"
      sid=$(sweep_register "$home" "$board")
      protected_ids+=("$sid")
      case "$session" in
        ended) sweep_session "$store" "$board" ended 0 - ;;
        idle) sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z ;;
      esac
      [ "$syntax" != unreadable ] || chmod 000 "$board"
    done
  done
  kept_count=$((6 + ${#protected_ids[@]}))

  sweep_session "$store" "$gone" open 0 2000-01-01T00:00:00.000Z
  sweep_session "$store" "$ended" ended 0 -
  sweep_session "$store" "$dormant" open 0 2000-01-01T00:00:00.000Z
  sweep_session "$store" "$closed" open 0 2000-01-01T00:00:00.000Z
  sweep_session "$store" "$openheld" open 0 2000-01-01T00:00:00.000Z
  sweep_session "$store" "$fresh" open 0 -
  sweep_session "$store" "$queued" open 2 2000-01-01T00:00:00.000Z
  sweep_session "$store" "$owned" open 0 2000-01-01T00:00:00.000Z
  sweep_session "$store" "$standing" open 0 2000-01-01T00:00:00.000Z
  sweep_session "$store" "$pending" open 0 2000-01-01T00:00:00.000Z
  mkdir -p "$home/state/procevent-inbox"
  printf 'session:\n  status: feedback\n' > "$home/state/procevent-inbox/$pending_id.1.result"
  printf 'lavish\n' > "$home/state/procevent-inbox/$pending_id.1.adapter"
  touch -t 200001010000 "$home/state/procevent-inbox/$pending_id.1.result" \
    "$home/state/procevent-inbox/$pending_id.1.adapter"
  rm -f "$gone"
  before=$(cksum < "$store/state.json")

  # A dry run reports the verdicts and changes nothing.
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --dry-run) \
    || fail "the dry-run sweep failed: $out"
  assert_contains "$out" "would-retire: $gone_id" "the dry run missed a board whose file is gone"
  assert_contains "$out" "kept: $fresh_id $fresh - active within the last 48 hours" "the dry run did not keep the recently touched board for its activity"
  assert_contains "$out" "sweep: would-retire=5 kept=$kept_count" "the dry run counted the wrong verdicts: $out"
  list=$(run_procevent "$home" list)
  assert_contains "$list" "$dormant_id" "a dry run retired a registration"

  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) \
    || fail "the sweep failed: $out"
  assert_contains "$out" "retired: $gone_id" "a board whose file is gone kept its listener"
  assert_contains "$out" "retired: $ended_id" "an ended Lavish session kept its listener"
  assert_contains "$out" "retired: $nosession_id" "a board Lavish has no session for kept its listener"
  assert_contains "$out" "retired: $dormant_id" "an idle board with no open call kept its listener"
  assert_contains "$out" "retired: $closed_id" "an idle board whose only call is answered kept its listener"
  assert_contains "$out" "kept: $openheld_id" "an idle board with an open captain call lost its listener"
  assert_contains "$out" "kept: $fresh_id $fresh - active within the last 48 hours" "the sweep did not keep the recently touched board for its activity"
  assert_contains "$out" "kept: $queued_id" "a board holding queued feedback lost its listener"
  assert_contains "$out" "kept: $owned_id" "a worker-owned board lost its listener to a dormancy rule"
  assert_contains "$out" "kept: $standing_id" "the standing Bearings board lost its listener"
  assert_contains "$out" "kept: $pending_id" "a board with an unread captured answer lost its listener"
  for after in "${protected_ids[@]}"; do
    assert_contains "$out" "kept: $after" "a board with an open or unreadable captain card lost its listener: $out"
  done
  assert_contains "$out" "sweep: retired=5 kept=$kept_count" "the sweep counted the wrong verdicts: $out"

  list=$(run_procevent "$home" list)
  for after in "$gone_id" "$ended_id" "$nosession_id" "$dormant_id" "$closed_id"; do
    assert_not_contains "$list" "$after" "a retired board is still registered"
  done
  for after in "$openheld_id" "$fresh_id" "$queued_id" "$owned_id" "$standing_id" "$pending_id" "${protected_ids[@]}"; do
    assert_contains "$list" "$after" "a kept board lost its registration"
  done
  [ "$before" = "$(cksum < "$store/state.json")" ] \
    || fail "the sweep changed the Lavish session store; retiring a listener must not end a board"

  sweep_session "$store" "$owned" ended 0 -
  sweep_session "$store" "$standing" ended 0 -
  sweep_session "$store" "$queued" ended 2 -
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) || fail "the repeat sweep failed: $out"
  assert_contains "$out" "kept: $owned_id" "a worker-owned board with an ended session lost its listener"
  assert_contains "$out" "kept: $standing_id" "the standing board with an ended session lost its listener"
  assert_contains "$out" "kept: $queued_id" "an ended board with queued feedback lost its listener"
  assert_contains "$out" "sweep: retired=0 kept=$kept_count" "a repeat sweep retired more than the first"

  # A store the sweep cannot read proves nothing about any board's session, so
  # a board that would otherwise be retired keeps its listener.
  unreadable=$(sweep_board "$home" unreadable old sweep-closed-call)
  unreadable_id=$(sweep_register "$home" "$unreadable")
  sweep_session "$store" "$unreadable" open 0 2000-01-01T00:00:00.000Z
  gone=$(sweep_board "$home" gone-store-unreadable old)
  gone_id=$(sweep_register "$home" "$gone")
  sweep_session "$store" "$gone" open 0 2000-01-01T00:00:00.000Z
  rm -f "$gone"
  cp "$store/state.json" "$home/state-good.json"
  printf 'not json\n' > "$store/state.json"
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) || fail "the unreadable-store sweep failed: $out"
  assert_contains "$out" "kept: $unreadable_id" "an unreadable Lavish store retired a listener"
  assert_contains "$out" "kept: $gone_id" "a missing-file board was retired while the Lavish store was unreadable"
  assert_contains "$out" "sweep: retired=0 kept=$((kept_count + 2))" "an unreadable Lavish store changed the verdicts: $out"
  cp "$home/state-good.json" "$store/state.json"
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) || fail "the restored-store sweep failed: $out"
  assert_contains "$out" "retired: $unreadable_id" "the same board was not retired once its session was readable"
  assert_contains "$out" "retired: $gone_id" "a missing-file board was not retired once the store was readable"

  set +e
  out=$(FM_BOARD_LISTENER_IDLE_HOURS=0 LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unusable idle window was accepted"
  assert_contains "$out" "FM_BOARD_LISTENER_IDLE_HOURS" "the refusal did not name the setting"
  pass "the sweep retires finished boards and keeps every board that could still carry an answer"
}

# The unattended mode the watcher runs (sweep --auto) retires a listener for two findings
# only: the board file is gone, or the Lavish session has ended or is absent with every card
# closed. A board with a live session keeps its listener however idle it is and whatever
# state its listener is in, and every keep guard of the manual sweep still applies first.
test_auto_sweep_retires_only_finished_listeners() {
  local home store out log list marker source id
  local gone ended nosession idle stuck
  local gone_id ended_id nosession_id idle_id stuck_id
  home=$(make_home auto-sweep)
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  store="$home/lavish-state"
  fm_fake_exit0 "$home/fakebin" lavish-axi
  log="$home/state/lavish-auto-retire.log"
  run_captain "$home" hold auto-open-call --title "Choose the open route" \
    --reason "captain open route pending" --repo sample >/dev/null \
    || fail "could not hold the call that stays unanswered"
  run_captain "$home" hold auto-closed-call --title "Choose the closed route" \
    --reason "captain closed route pending" --repo sample >/dev/null \
    || fail "could not hold the call that is answered below"
  printf 'north\n' > "$home/answer.txt"
  run_captain "$home" answer auto-closed-call --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not answer the call"

  # The captain's board: a live session, an unanswered call, and a registration the runner
  # refuses to start, so the real reconcile reports the launch failed and leaves its marker.
  stuck=$(sweep_board "$home" auto-stuck new auto-open-call)
  stuck_id=$(sweep_register "$home" "$stuck")
  sweep_session "$store" "$stuck" open 0 -
  source="$home/state/procevent/$stuck_id.source"
  sed 's/^argc=.*/argc=99/' "$source" > "$home/damaged.source" \
    || fail "could not prepare the damaged registration"
  cat "$home/damaged.source" > "$source"
  out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 LAVISH_AXI_STATE_DIR="$store" run_procevent "$home" reconcile 2>&1)
  assert_contains "$out" "failed=1" "reconcile did not report the unstartable listener as failed: $out"
  marker="$home/state/procevent/.$stuck_id.launch-failed"
  assert_present "$marker" "reconcile did not leave a launch-failure marker"
  touch -t 200001010000 "$marker"

  gone=$(sweep_board "$home" auto-gone old)
  ended=$(sweep_board "$home" auto-ended new auto-closed-call)
  nosession=$(sweep_board "$home" auto-nosession new auto-closed-call)
  idle=$(sweep_board "$home" auto-idle old auto-closed-call)
  gone_id=$(sweep_register "$home" "$gone")
  ended_id=$(sweep_register "$home" "$ended")
  nosession_id=$(sweep_register "$home" "$nosession")
  idle_id=$(sweep_register "$home" "$idle")
  sweep_session "$store" "$gone" open 0 2000-01-01T00:00:00.000Z
  sweep_session "$store" "$ended" ended 0 -
  sweep_session "$store" "$idle" open 0 2000-01-01T00:00:00.000Z
  rm -f "$gone"

  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --auto --dry-run) \
    || fail "the dry-run automatic sweep failed: $out"
  assert_contains "$out" "would-retire: $gone_id" "the dry run missed a board whose file is gone"
  assert_contains "$out" "kept: $stuck_id" "the dry run would retire the captain's board"
  [ ! -e "$log" ] || fail "a dry run wrote the retirement record"
  list=$(run_procevent "$home" list)
  assert_contains "$list" "$gone_id" "a dry run retired a registration"

  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --auto) \
    || fail "the automatic sweep failed: $out"
  assert_contains "$out" "retired: $gone_id" "an automatic sweep kept a board whose file is gone"
  assert_contains "$out" "retired: $ended_id" "an automatic sweep kept the listener of an ended session"
  assert_contains "$out" "retired: $nosession_id" "an automatic sweep kept the listener of a board with no session"
  assert_contains "$out" "kept: $idle_id $idle - the Lavish session is live" \
    "an automatic sweep retired a live idle board; only the manual sweep applies the idle rule"
  assert_contains "$out" "kept: $stuck_id $stuck - the Lavish session is live" \
    "an automatic sweep retired a live board whose listener cannot start: $out"
  assert_contains "$out" "sweep: retired=3 kept=2" "the automatic sweep counted the wrong verdicts: $out"
  list=$(run_procevent "$home" list)
  for id in "$gone_id" "$ended_id" "$nosession_id"; do
    assert_not_contains "$list" "$id" "a retired listener is still registered"
  done
  for id in "$idle_id" "$stuck_id"; do
    assert_contains "$list" "$id" "a kept listener lost its registration"
  done
  assert_present "$marker" "the sweep removed the launch-failure marker of a kept board"
  assert_present "$log" "the automatic sweep did not record why it retired"
  [ "$(wc -l < "$log" | tr -d ' ')" = 3 ] || fail "the record must hold one line per retirement: $(cat "$log")"
  assert_contains "$(cat "$log")" "retired $gone_id $gone - the board file is gone" "the record lacks the gone-file reason"
  assert_not_contains "$(cat "$log")" "$stuck_id" "the record names a listener that was kept"
  assert_not_contains "$(cat "$log")" "$idle_id" "the record names a listener that was kept"

  # Once its session ends, the unanswered captain call still keeps the board's listener.
  sweep_session "$store" "$stuck" ended 0 -
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --auto) \
    || fail "the repeat automatic sweep failed: $out"
  assert_contains "$out" "kept: $stuck_id" "an ended board with an unanswered captain call lost its listener: $out"
  assert_contains "$out" "sweep: retired=0 kept=2" "the repeat automatic sweep counted the wrong verdicts: $out"
  pass "the automatic sweep retires finished boards, never a live or unanswered one whose listener cannot start, and records why"
}

test_sweep_keeps_recently_handled_boards_in_literal_home_paths() {
  local name home store board sid idle_board idle_sid out list
  for name in board-sweep-handled 'board sweep handled' 'board sweep [literal]*?'; do
    home=$(make_home "$name")
    fm_test_track_procevent_home "$home" "$home/procevent-claims"
    tasks_in "$home" add sweep-finished-card "Finished board card" >/dev/null \
      || fail "could not create the non-held card"
    store="$home/lavish-state"
    board=$(sweep_board "$home" recently-handled old sweep-finished-card)
    idle_board=$(sweep_board "$home" idle old sweep-finished-card)
    sid=$(sweep_register "$home" "$board")
    idle_sid=$(sweep_register "$home" "$idle_board")
    sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z
    sweep_session "$store" "$idle_board" open 0 2000-01-01T00:00:00.000Z
    mkdir -p "$home/state/procevent-inbox"
    printf 'session:\n  status: feedback\n' > "$home/state/procevent-inbox/$sid.1.result"
    printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"
    touch -t 200001010000 "$home/state/procevent-inbox/$sid.1.result" \
      "$home/state/procevent-inbox/$sid.1.adapter"
    run_procevent "$home" handled "$sid" 1 >/dev/null \
      || fail "could not acknowledge the captured board round"
    assert_present "$home/state/procevent-inbox/$sid.1.handled" \
      "the captured round has no durable acknowledgement"

    out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --dry-run) \
      || fail "the handled-board dry run failed: $out"
    assert_contains "$out" "kept: $sid" "the dry run missed recent handling in $home: $out"
    assert_contains "$out" "would-retire: $idle_sid" "another board inherited recent handling: $out"
    out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) \
      || fail "the handled-board sweep failed: $out"
    assert_contains "$out" "kept: $sid" "recent handling did not keep the listener in $home: $out"
    assert_contains "$out" "retired: $idle_sid" "another board inherited recent handling: $out"
    list=$(run_procevent "$home" list)
    assert_contains "$list" "$sid" "the recently handled listener lost its registration"
    assert_not_contains "$list" "$idle_sid" "the idle listener kept its registration"
  done
  pass "recent acknowledgements keep only their own listeners in literal home paths"
}

# The point of the sweep is the resident processes: a live listener's board is
# finished, and after the sweep neither its runner nor its blocked poll remains.
test_sweep_stops_a_live_listener_of_a_finished_board() {
  local home store artifact sid out list tries poll_pid
  home=$(make_home board-sweep-live)
  tasks_in "$home" add sweep-finished-card "Finished board card" >/dev/null \
    || fail "could not create the non-held card"
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  store="$home/lavish-state"
  artifact=$(sweep_board "$home" live-idle old sweep-finished-card)
  cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
# A poll that blocks until it is killed; bounded so an escaped stub cannot linger.
printf '%s\n' "$$" > "$FM_HOME/poll.pid"
for _ in $(seq 1 1800); do sleep 0.1; done
SH
  chmod +x "$home/fakebin/lavish-axi"
  sweep_session "$store" "$artifact" open 0 2000-01-01T00:00:00.000Z
  sid=$(run_lavish "$home" source-id "$artifact") || fail "could not derive the live source id"
  out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=60 LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" arm "$artifact") \
    || fail "could not arm the live listener: $out"
  list=$(run_procevent "$home" list)
  assert_contains "$list" "$sid" "the armed listener is not registered"
  assert_contains "$list" "live" "the armed listener is not running"
  # Armed means claimed; the poll process follows the claim, so wait for it.
  tries=0
  while [ ! -s "$home/poll.pid" ] && [ "$tries" -lt 300 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  [ -s "$home/poll.pid" ] \
    || fail "the armed listener has no resident poll to retire"
  poll_pid=$(cat "$home/poll.pid")
  kill -0 "$poll_pid" 2>/dev/null \
    || fail "the armed listener's poll is not running"

  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) || fail "the sweep failed: $out"
  assert_contains "$out" "retired: $sid" "the idle board's live listener was kept"
  tries=0
  while kill -0 "$poll_pid" 2>/dev/null && [ "$tries" -lt 100 ]; do
    tries=$((tries + 1))
    sleep 0.1
  done
  ! kill -0 "$poll_pid" 2>/dev/null \
    || fail "the retired listener's poll is still resident"
  list=$(run_procevent "$home" list)
  assert_not_contains "$list" "$sid" "the retired listener is still registered"
  pass "the sweep stops the resident poll of a finished board's live listener"
}

test_sweep_preserves_deleted_board_keep_guards() {
  local home store guard board sid out list before hop next
  local -a kept_ids=()
  home=$(make_home board-sweep-deleted)
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  store="$home/lavish-state"
  for guard in standing feedback queued owned pending ambiguous; do
    board=$(sweep_board "$home" "$guard" old)
    if [ "$guard" = standing ]; then
      mkdir -p "$home/.lavish"
      mv "$board" "$home/.lavish/bearings-board.html"
      board="$home/.lavish/bearings-board.html"
    fi
    if [ "$guard" = owned ]; then
      sid=$(run_lavish "$home" source-id "$board") || fail "could not derive the owned source id"
      printf 'window=fmtest:fm-deleted-owner\nworktree=%s/worktree-deleted-owner\nproject=fmtest\n' "$home" \
        > "$home/state/deleted-owner.meta"
      run_procevent "$home" register-task lavish "$sid" deleted-owner -- \
        "$ROOT/bin/fm-procevent-lavish.sh" poll "$board" >/dev/null \
        || fail "could not register the deleted worker-owned board"
    else
      sid=$(sweep_register "$home" "$board")
    fi
    kept_ids+=("$sid")
    case "$guard" in
      feedback|ambiguous) sweep_session "$store" "$board" feedback 0 - ;;
      queued) sweep_session "$store" "$board" open 2 - ;;
      *) sweep_session "$store" "$board" ended 0 - ;;
    esac
    if [ "$guard" = ambiguous ]; then
      perl -MJSON::PP -e '
        my ($path, $board) = @ARGV;
        open my $in, "<", $path or die $!;
        local $/;
        my $doc = decode_json(<$in>);
        close $in;
        $doc->{sessions}{duplicate} = { file => $board, status => "ended", pending_prompts => 0 };
        open my $out, ">", $path or die $!;
        print $out encode_json($doc);
        close $out or die $!;
      ' "$store/state.json" "$board"
    fi
    if [ "$guard" = pending ]; then
      mkdir -p "$home/state/procevent-inbox"
      printf 'session:\n  status: feedback\n' > "$home/state/procevent-inbox/$sid.1.result"
      printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"
    fi
    rm "$board"
  done
  before=$(cksum < "$store/state.json")
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --dry-run) \
    || fail "the deleted-board dry run failed: $out"
  assert_contains "$out" 'sweep: would-retire=0 kept=6' "deleted boards bypassed keep guards: $out"
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) \
    || fail "the deleted-board sweep failed: $out"
  list=$(run_procevent "$home" list)
  for sid in "${kept_ids[@]}"; do
    assert_contains "$out" "kept: $sid" "a deleted protected board was retired: $out"
    assert_contains "$list" "$sid" "a deleted protected board lost its registration"
  done
  [ "$before" = "$(cksum < "$store/state.json")" ] || fail "the deleted-board sweep changed Lavish sessions"
  printf '#!/usr/bin/env bash\nexec sleep 120\n' > "$home/fakebin/lavish-axi"
  chmod +x "$home/fakebin/lavish-axi"
  for guard in absolute relative chain cycle limit; do
    board=$(sweep_board "$home" "standing-$guard" old)
    case "$guard" in
      relative) ln -s "../boards/standing-$guard.html" "$home/.lavish/bearings-board.html" ;;
      chain)
        ln -s "standing-$guard.html" "$home/boards/standing-link.html"
        ln -s ../boards/standing-link.html "$home/.lavish/bearings-board.html"
        ;;
      *) ln -s "$board" "$home/.lavish/bearings-board.html" ;;
    esac
    sid=$(run_lavish "$home" source-id "$board") || fail "could not derive the standing target source id"
    sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z
    out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=60 LAVISH_AXI_STATE_DIR="$store" \
      run_lavish "$home" arm "$home/.lavish/bearings-board.html") \
      || fail "could not arm the $guard standing symlink: $out"
    assert_contains "$out" "artifact: $board" "arm did not record the standing board's physical target: $out"
    rm "$board"
    case "$guard" in
      cycle)
        rm "$home/.lavish/bearings-board.html"
        ln -s bearings-board.html "$home/.lavish/bearings-board.html"
        ;;
      limit)
        rm "$home/.lavish/bearings-board.html"
        ln -s standing-hop-1 "$home/.lavish/bearings-board.html"
        for hop in {1..40}; do
          next=$((hop + 1))
          ln -s "standing-hop-$next" "$home/.lavish/standing-hop-$hop"
        done
        ;;
    esac
    out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --dry-run) \
      || fail "the deleted $guard standing symlink dry run failed: $out"
    assert_contains "$out" "kept: $sid $board - the standing Bearings board" \
      "the deleted $guard standing board was not protected in the dry run: $out"
    out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) \
      || fail "the deleted $guard standing symlink sweep failed: $out"
    assert_contains "$out" "kept: $sid $board - the standing Bearings board" \
      "the deleted $guard standing board was not protected: $out"
    case "$guard" in
      cycle|limit) assert_contains "$out" 'the standing Bearings board path cannot be resolved' \
        "the unresolved standing symlink did not keep listeners: $out" ;;
    esac
    list=$(run_procevent "$home" list)
    assert_contains "$list" "$sid" "the deleted $guard standing board lost its registration"
    run_procevent "$home" retire "$sid" >/dev/null || fail "could not retire the standing symlink fixture"
    rm "$home/.lavish/bearings-board.html"
  done
  pass "deleted boards retain standing, feedback, ownership and captured-result protections"
}

test_sweep_keeps_boards_with_unsearchable_parents() {
  local home store session board parent sid out rc list
  home=$(make_home board-sweep-inaccessible)
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  store="$home/lavish-state"
  mkdir -p "$store"
  printf '{"sessions":{}}\n' > "$store/state.json"
  run_captain "$home" hold sweep-inaccessible-call --title "Choose the inaccessible route" \
    --reason "captain route pending" --repo sample >/dev/null || fail "could not hold the inaccessible call"
  for session in ended nosession idle; do
    board=$(sweep_board "$home/$session" inaccessible old sweep-inaccessible-call)
    parent=${board%/*}
    sid=$(sweep_register "$home" "$board")
    case "$session" in
      ended) sweep_session "$store" "$board" ended 0 - ;;
      idle) sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z ;;
    esac
    chmod 000 "$parent"
    perl -MErrno=EACCES -e 'stat($ARGV[0]); exit($! == EACCES ? 0 : 1)' "$board"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      chmod 700 "$parent"
      fail "the unsearchable-parent fixture did not produce EACCES"
    fi
    out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep)
    rc=$?
    chmod 700 "$parent"
    [ "$rc" -eq 0 ] || fail "the inaccessible-board sweep failed: $out"
    assert_contains "$out" "kept: $sid" "an inaccessible $session board was treated as missing: $out"
    assert_contains "$out" 'the board file cannot be checked' "the filesystem error lost its unknown verdict: $out"
    list=$(run_procevent "$home" list)
    assert_contains "$list" "$sid" "an inaccessible board lost its registration"
  done
  pass "filesystem permission errors keep ended, sessionless and idle board listeners"
}

test_sweep_keeps_unknown_inbox_evidence() {
  local home store board sid inbox session identity dry_out out locked_out rc dry_rc sweep_rc fixture_rc list
  local role blocked healthy healthy_id
  for session in idle ended nosession missing; do
    home=$(make_home "board-sweep-inbox-unreadable-$session")
    tasks_in "$home" add sweep-finished-card "Finished board card" >/dev/null \
      || fail "could not create the non-held card"
    fm_test_track_procevent_home "$home" "$home/procevent-claims"
    store="$home/lavish-state"
    mkdir -p "$store"
    printf '{"sessions":{}}\n' > "$store/state.json"
    board=$(sweep_board "$home" unreadable-inbox old sweep-finished-card)
    sid=$(sweep_register "$home" "$board")
    case "$session" in
      ended) sweep_session "$store" "$board" ended 0 - ;;
      idle|missing) sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z ;;
    esac
    [ "$session" != missing ] || rm -f "$board"
    identity=$(perl -e 'my @s = stat $ARGV[0]; die $! unless @s; print "$s[0]:$s[1]"' "$home/state/procevent/$sid.source")
    inbox="$home/state/procevent-inbox"
    mkdir -p "$inbox"
    printf 'session:\n  status: feedback\n' > "$inbox/$sid.1.result"
    printf 'lavish\n' > "$inbox/$sid.1.adapter"
    touch -t 200001010000 "$inbox/$sid.1.result" "$inbox/$sid.1.adapter"
    chmod 0300 "$inbox"
    perl -MErrno=EACCES -e 'opendir(my $d, $ARGV[0]); exit($! == EACCES ? 0 : 1)' "$inbox"
    fixture_rc=$?
    dry_out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --dry-run)
    dry_rc=$?
    out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep)
    sweep_rc=$?
    if locked_out=$(run_procevent "$home" retire "$sid" --if-identity "$identity" 2>&1); then rc=0; else rc=$?; fi
    chmod 0700 "$inbox"
    [ "$fixture_rc" -eq 0 ] || fail "the non-listable inbox did not produce EACCES"
    [ "$dry_rc" -eq 0 ] && [ "$sweep_rc" -eq 0 ] || fail "the unreadable-inbox sweep failed: $dry_out $out"
    assert_contains "$dry_out" "kept: $sid" "a dry run would retire an unreadable $session inbox: $dry_out"
    assert_contains "$out" "kept: $sid" "an unreadable $session inbox lost its listener: $out"
    assert_contains "$out" 'inbox cannot be opened' "the inbox read error was not logged: $out"
    [ "$rc" -ne 0 ] || fail "locked retirement accepted an unreadable inbox"
    assert_contains "$locked_out" 'inbox cannot be opened' "locked retirement lost the inbox error: $locked_out"
    list=$(run_procevent "$home" list)
    assert_contains "$list" "$sid" "an unreadable inbox lost its registration"
    assert_present "$inbox/$sid.1.result" "the unacknowledged capture was deleted"
    assert_absent "$inbox/$sid.1.handled" "the unreadable capture was acknowledged"
    rm -f "$inbox/$sid.1.result" "$inbox/$sid.1.adapter"
    rmdir "$inbox"
    out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) || fail "the absent-inbox sweep failed: $out"
    assert_contains "$out" "retired: $sid" "confirmed inbox absence kept a finished $session board: $out"
    assert_absent "$home/state/procevent/$sid.source" "the absent-inbox source remains registered"
  done
  for role in result adapter handled; do
    home=$(make_home "board-sweep-inbox-stat-$role")
    tasks_in "$home" add sweep-finished-card "Finished board card" >/dev/null \
      || fail "could not create the non-held card"
    fm_test_track_procevent_home "$home" "$home/procevent-claims"
    store="$home/lavish-state"
    board=$(sweep_board "$home" stat-error old sweep-finished-card)
    sid=$(sweep_register "$home" "$board")
    sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z
    healthy=$(sweep_board "$home" healthy old sweep-finished-card)
    healthy_id=$(sweep_register "$home" "$healthy")
    sweep_session "$store" "$healthy" open 0 2000-01-01T00:00:00.000Z
    identity=$(perl -e 'my @s = stat $ARGV[0]; die $! unless @s; print "$s[0]:$s[1]"' "$home/state/procevent/$sid.source")
    inbox="$home/state/procevent-inbox"
    blocked="$home/blocked"
    mkdir -p "$inbox" "$blocked"
    printf 'captured\n' > "$blocked/entry"
    [ "$role" != handled ] || printf 'session:\n  status: feedback\n' > "$inbox/$sid.1.result"
    ln -s "$blocked/entry" "$inbox/$sid.1.$role"
    [ "$role" != handled ] || touch -t 200001010000 "$inbox/$sid.1.result"
    chmod 000 "$blocked"
    perl -MErrno=EACCES -e 'stat($ARGV[0]); exit($! == EACCES ? 0 : 1)' "$inbox/$sid.1.$role"
    fixture_rc=$?
    dry_out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --dry-run)
    dry_rc=$?
    out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep)
    sweep_rc=$?
    if locked_out=$(run_procevent "$home" retire "$sid" --if-identity "$identity" 2>&1); then rc=0; else rc=$?; fi
    chmod 0700 "$blocked"
    [ "$fixture_rc" -eq 0 ] || fail "the inbox $role fixture did not produce a stat error"
    [ "$dry_rc" -eq 0 ] && [ "$sweep_rc" -eq 0 ] || fail "the stat-error sweep failed: $dry_out $out"
    assert_contains "$dry_out" "kept: $sid" "a dry run ignored an inbox $role stat error: $dry_out"
    assert_contains "$out" "kept: $sid" "an inbox $role stat error lost its listener: $out"
    assert_contains "$out" 'cannot be checked' "the inbox stat error was not logged: $out"
    assert_contains "$dry_out" "would-retire: $healthy_id" "one source's stat error kept an unrelated idle board: $dry_out"
    assert_contains "$out" "retired: $healthy_id" "one source's stat error kept an unrelated idle board: $out"
    [ "$rc" -ne 0 ] || fail "locked retirement accepted an inbox $role stat error"
    assert_contains "$locked_out" 'cannot be checked' "locked retirement lost the inbox stat error: $locked_out"
    assert_present "$home/state/procevent/$sid.source" "an uncertain inbox source lost its registration"
    rm -f "$inbox/$sid.1.$role" "$inbox/$sid.1.result"
    rmdir "$inbox"
    out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) || fail "the recovered-inbox sweep failed: $out"
    assert_contains "$out" "retired: $sid" "the recovered idle board was not retired: $out"
  done
  pass "unknown inbox evidence keeps listeners at sweep and locked retirement boundaries"
}

test_sweep_preserves_rearmed_registration_generations() (
  local mode home store board sid real_perl sweep_pid poll_pid out list rc tries
  real_perl=$(command -v perl)
  for mode in plain worker pending; do
    home=$(make_home "board-sweep-rearmed-$mode")
    tasks_in "$home" add sweep-finished-card "Finished board card" >/dev/null \
      || fail "could not create the non-held card"
    fm_test_track_procevent_home "$home" "$home/procevent-claims"
    store="$home/lavish-state"
    board=$(sweep_board "$home" rearmed old sweep-finished-card)
    sid=$(sweep_register "$home" "$board")
    sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z
    printf '#!/usr/bin/env bash\nreal_perl=%q\n' "$real_perl" > "$home/fakebin/perl"
    cat >> "$home/fakebin/perl" <<'SH'
if [ "${FM_TEST_SWEEP_PAUSE:-}" = 1 ] \
    && [ "${!#}" = "$FM_HOME/lavish-state/state.json" ] \
    && [ ! -e "$FM_HOME/sweep-ready" ]; then
  : > "$FM_HOME/sweep-ready"
  while [ ! -e "$FM_HOME/sweep-release" ] && [ "$SECONDS" -lt 120 ]; do sleep 0.01; done
fi
exec "$real_perl" "$@"
SH
    cat > "$home/fakebin/lavish-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/poll.pid"
exec sleep 120
SH
    chmod +x "$home/fakebin/perl" "$home/fakebin/lavish-axi"
    exec 7< "$home/state/procevent/$sid.source"
    FM_TEST_SWEEP_PAUSE=1 LAVISH_AXI_STATE_DIR="$store" \
      run_lavish "$home" sweep > "$home/sweep.out" 2> "$home/sweep.err" &
    sweep_pid=$!
    if ! wait_for_test_file "$home/sweep-ready" "$sweep_pid"; then
      : > "$home/sweep-release"
      wait "$sweep_pid" 2>/dev/null || true
      fail "the sweep did not reach its post-snapshot barrier"
    fi
    if [ "$mode" = pending ]; then
      mkdir -p "$home/state/procevent-inbox"
      printf 'session:\n  status: feedback\n' > "$home/state/procevent-inbox/$sid.1.result"
      printf 'lavish\n' > "$home/state/procevent-inbox/$sid.1.adapter"
      touch -t 200001010000 "$home/state/procevent-inbox/$sid.1.result" \
        "$home/state/procevent-inbox/$sid.1.adapter"
      : > "$home/sweep-release"
      wait "$sweep_pid" || fail "the capture-race sweep failed: $(cat "$home/sweep.err")"
      exec 7<&-
      out=$(cat "$home/sweep.out")
      assert_contains "$out" "kept: $sid" "the stale sweep retired a newly captured round: $out"
      assert_contains "$out" 'retire refused' "the new capture did not block conditional retirement: $out"
      assert_contains "$out" 'while a captured round is unacknowledged' "retirement refused for the wrong reason: $out"
      list=$(run_procevent "$home" list)
      assert_contains "$list" "$sid" "the source with a newly captured round lost its registration"
      assert_present "$home/state/procevent-inbox/$sid.1.result" "the new captured round was deleted"
      assert_absent "$home/state/procevent-inbox/$sid.1.handled" "the new captured round was acknowledged"
      run_procevent "$home" retire "$sid" >/dev/null \
        || fail "ordinary retirement refused the plain source's captured round"
      assert_present "$home/state/procevent-inbox/$sid.1.result" "ordinary retirement deleted the captured round"
      assert_absent "$home/state/procevent-inbox/$sid.1.handled" "ordinary retirement acknowledged the captured round"
      continue
    fi
    run_procevent "$home" retire "$sid" >/dev/null \
      || { : > "$home/sweep-release"; wait "$sweep_pid"; fail "could not retire the snapshotted board"; }
    if [ "$mode" = worker ]; then
      printf 'window=fmtest:fm-rearmed-owner\nworktree=%s/worktree-rearmed-owner\nproject=fmtest\n' "$home" \
        > "$home/state/rearmed-owner.meta"
      out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=60 LAVISH_AXI_STATE_DIR="$store" \
        run_lavish "$home" arm "$board" --for rearmed-owner)
      rc=$?
    else
      out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=60 LAVISH_AXI_STATE_DIR="$store" \
        run_lavish "$home" arm "$board")
      rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      : > "$home/sweep-release"
      wait "$sweep_pid" 2>/dev/null || true
      fail "could not re-arm the $mode replacement: $out"
    fi
    tries=0
    while [ ! -s "$home/poll.pid" ] && [ "$tries" -lt 300 ]; do
      tries=$((tries + 1))
      sleep 0.1
    done
    if [ ! -s "$home/poll.pid" ]; then
      : > "$home/sweep-release"
      wait "$sweep_pid" 2>/dev/null || true
      fail "the replacement listener did not start polling"
    fi
    poll_pid=$(cat "$home/poll.pid")
    : > "$home/sweep-release"
    wait "$sweep_pid" || fail "the stale sweep failed: $(cat "$home/sweep.err")"
    exec 7<&-
    out=$(cat "$home/sweep.out")
    assert_contains "$out" "kept: $sid" "the stale sweep retired the $mode replacement: $out"
    assert_contains "$out" 'source registration generation changed' "the stale retirement was not generation-gated: $out"
    list=$(run_procevent "$home" list)
    assert_contains "$list" "$sid" "the replacement registration was deleted"
    kill -0 "$poll_pid" 2>/dev/null || fail "the stale sweep stopped the replacement poll"
    run_procevent "$home" retire "$sid" >/dev/null \
      || fail "ordinary retirement refused the replacement listener"
  done
  pass "stale sweeps preserve replacement generations and newly captured rounds"
)

test_sweep_keeps_unknown_card_discovery() {
  local home store session shape board sid out list before
  local -a kept_ids=() retired_ids=()
  home=$(make_home board-sweep-card-discovery)
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  store="$home/lavish-state"
  mkdir -p "$store"
  printf '{"sessions":{}}\n' > "$store/state.json"
  tasks_in "$home" add sweep-static-finished "Finished static card" >/dev/null \
    || fail "could not create the non-held static card"
  run_captain "$home" hold sweep-dynamic-open --title "Dynamic captain call" \
    --reason "captain choice pending" --repo sample >/dev/null \
    || fail "could not create the dynamic captain call"
  for session in idle ended nosession; do
    for shape in empty dynamic mixed external module handler unkeyed comment malformed frame static; do
      board=$(sweep_board "$home" "$session-$shape" new sweep-static-finished)
      case "$shape" in
        empty) printf '<h1>No static cards</h1>\n' > "$board" ;;
        dynamic|mixed)
          [ "$shape" != dynamic ] || : > "$board"
          cat >> "$board" <<'HTML'
<script>
const row = {data: {question: 'sweep-dynamic-open', answer: 'north'}};
const form = document.createElement('form');
form.addEventListener('submit', event => {
  event.preventDefault();
  window.lavish.queuePrompt('north', {tag: 'choice', element: form, data: row.data});
});
form.append(document.createElement('button'));
document.body.append(form);
</script>
HTML
          ;;
        external) printf '<script src="deck.js"></script>\n' >> "$board" ;;
        module) printf '<script type="module">document.createElement("form");</script>\n' >> "$board" ;;
        handler) printf '<button onclick="window.lavish.queuePrompt(\x27north\x27, {data: {question: \x27sweep-dynamic-open\x27}})">go</button>\n' >> "$board" ;;
        unkeyed) printf '<form><button>dynamic choice</button></form>\n' >> "$board" ;;
        comment) printf '<!-- <form data-lavish-question="sweep-static-finished"></form> -->\n' > "$board" ;;
        malformed) printf '<form data-lavish-question="sweep-static-finished" broken="\n' > "$board" ;;
        frame) printf '<iframe src="cards.html"></iframe>\n' >> "$board" ;;
      esac
      touch -t 200001010000 "$board"
      sid=$(sweep_register "$home" "$board")
      if [ "$shape" = static ]; then retired_ids+=("$sid"); else kept_ids+=("$sid"); fi
      case "$session" in
        ended) sweep_session "$store" "$board" ended 0 - ;;
        idle) sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z ;;
      esac
    done
  done
  before=$(cksum < "$store/state.json")
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --dry-run) \
    || fail "the discovery dry run failed: $out"
  for sid in "${kept_ids[@]}"; do
    assert_contains "$out" "kept: $sid" "unknown card discovery permitted retirement: $out"
  done
  for sid in "${retired_ids[@]}"; do
    assert_contains "$out" "would-retire: $sid" "a complete static closed-card set was kept: $out"
  done
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) \
    || fail "the discovery sweep failed: $out"
  list=$(run_procevent "$home" list)
  for sid in "${kept_ids[@]}"; do
    assert_contains "$out" "kept: $sid" "unknown card discovery lost its listener: $out"
    assert_contains "$list" "$sid" "unknown card discovery lost its registration"
  done
  for sid in "${retired_ids[@]}"; do
    assert_contains "$out" "retired: $sid" "a complete static closed-card set was not retired: $out"
    assert_not_contains "$list" "$sid" "the closed static board remains registered"
  done
  assert_contains "$out" 'complete card-key set cannot be established' "unknown discovery was not explained"
  assert_equals "$before" "$(cksum < "$store/state.json")" "discovery changed Lavish sessions"
  pass "unknown and dynamic card discovery keeps ended, sessionless and idle listeners"
}

test_sweep_resolves_bound_captain_keys() {
  local home store session route key origin board sid expected rc out list before legacy_sid=''
  local -a kept_ids=() retired_ids=()
  home=$(make_home board-sweep-bound-keys)
  fm_test_track_procevent_home "$home" "$home/procevent-claims"
  store="$home/lavish-state"
  mkdir -p "$store"
  printf '{"sessions":{}}\n' > "$store/state.json"
  for key in origin-open-decision-third-choice origin-closed-decision-third-choice \
      origin-open-decision-exact-choice sweep-bound-open; do
    run_captain "$home" hold "$key" --title "Bound captain call $key" \
      --reason "captain choice pending" --repo sample >/dev/null \
      || fail "could not create the bound call $key"
  done
  tasks_in "$home" add exact-choice "Non-held exact identity" >/dev/null \
    || fail "could not create the exact precedence fixture"
  printf 'north\n' > "$home/answer.txt"
  run_captain "$home" answer origin-closed-decision-third-choice --decision-file "$home/answer.txt" >/dev/null \
    || fail "could not answer the legacy closed fixture"
  before=$(cksum < "$home/data/backlog.md")
  for session in idle ended nosession; do
    for route in legacy-open legacy-closed exact-open exact-closed missing any-origin bad-binding; do
      origin="origin-open"; expected=0
      case "$route" in
        legacy-open) key=third-choice ;;
        legacy-closed) key="third-choice"; origin="origin-closed"; expected=1 ;;
        exact-open) key=sweep-bound-open; origin=--any-origin ;;
        exact-closed) key=exact-choice; expected=1 ;;
        missing) key=missing-choice; expected=2 ;;
        any-origin) key=third-choice; origin=--any-origin; expected=2 ;;
        bad-binding) key=exact-choice; expected=2 ;;
      esac
      board=$(sweep_board "$home" "$session-$route" old "$key")
      sid=$(sweep_register "$home" "$board")
      run_captain "$home" bind "$sid" "$origin" >/dev/null || fail "could not bind $route"
      if [ "$route" = bad-binding ]; then
        printf 'schema=invalid\norigin=origin-open\n' > "$home/state/decision-bindings/$sid.origin"
      fi
      if out=$(run_captain "$home" open-bound "$sid" "$key" 2> "$home/predicate.err"); then rc=0; else rc=$?; fi
      expect_code "$expected" "$rc" "bound predicate $session/$route: $(cat "$home/predicate.err")"
      assert_equals '' "$out" "the read-only bound predicate emitted output"
      if [ "$expected" = 1 ]; then retired_ids+=("$sid"); else kept_ids+=("$sid"); fi
      if [ "$session/$route" = idle/legacy-open ]; then legacy_sid=$sid; fi
      case "$session" in
        ended) sweep_session "$store" "$board" ended 0 - ;;
        idle) sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z ;;
      esac
    done
  done
  assert_equals "$before" "$(cksum < "$home/data/backlog.md")" "bound predicates changed captain tasks"
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep --dry-run) \
    || fail "the bound-key dry run failed: $out"
  for sid in "${kept_ids[@]}"; do assert_contains "$out" "kept: $sid" "the dry run lost a bound or unresolved call: $out"; done
  for sid in "${retired_ids[@]}"; do assert_contains "$out" "would-retire: $sid" "the dry run ignored a closed bound identity: $out"; done
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) \
    || fail "the bound-key sweep failed: $out"
  list=$(run_procevent "$home" list)
  for sid in "${kept_ids[@]}"; do
    assert_contains "$out" "kept: $sid" "an open or unresolved bound call lost its listener: $out"
    assert_contains "$list" "$sid" "an open or unresolved bound call lost its registration"
  done
  for sid in "${retired_ids[@]}"; do
    assert_contains "$out" "retired: $sid" "a closed bound identity kept its listener: $out"
    assert_not_contains "$list" "$sid" "a closed bound identity remains registered"
  done
  printf 'third-choice\tnorth\tNorth\n' | run_captain "$home" answers origin-open --source "bound sweep fixture" >/dev/null \
    || fail "the preserved legacy call could not receive its answer"
  out=$(tasks_in "$home" show origin-open-decision-third-choice)
  assert_contains "$out" 'state: done' "the bound answer did not reach the derived task"
  out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep) \
    || fail "the answered bound-key sweep failed: $out"
  assert_contains "$out" "retired: $legacy_sid" "the answered legacy card kept its listener: $out"
  pass "bound sweep keys share exact and legacy answer precedence without cross-source cache leakage"
}

test_sweep_resolves_migrated_captain_keys() {
  local mode home store board sid key origin identity expected out rc list before
  local permission_path permission_mode fixture_rc sweep_rc session predicate_err predicate_out
  for mode in note derived-note prefix derived-prefix marker-wins ambiguous-note ambiguous-prefix exact-error derived-error prefix-error \
      binding-lookup-error-idle binding-lookup-error-ended binding-lookup-error-nosession binding-read-error unbound unbound-directory; do
    home=$(make_home "board-sweep-migrated-$mode")
    fm_test_track_procevent_home "$home" "$home/procevent-claims"
    store="$home/lavish-state"
    key="legacy-choice"; origin="migration-origin"; expected=0; identity=$key
    case "$mode" in derived-note|derived-prefix) identity="$origin-decision-$key" ;; esac
    cat > "$home/.tasks.toml" <<EOF
backend = "beads"
[beads]
path = "$home/graph"
binary = "bd"
prefix = "fm"
[markdown]
path = "data/backlog.md"
EOF
    printf '[]\n' > "$home/migration-list.json"
    : > "$home/closed-id"
    : > "$home/error-id"
    case "$mode" in
      note|derived-note)
        write_known_rows_stub "$home/fakebin" migrated-row
        jq -cn --arg identity "$identity" '[{id:"migrated-row", notes:("migrated from data/backlog.md id " + $identity + " on 2026-09-04")}]' > "$home/migration-list.json"
        ;;
      prefix|derived-prefix) write_known_rows_stub "$home/fakebin" "fm-$identity" ;;
      marker-wins)
        write_known_rows_stub "$home/fakebin" migrated-row fm-legacy-choice
        printf 'migrated-row\n' > "$home/closed-id"
        printf '[{"id":"migrated-row","notes":"migrated from data/backlog.md id legacy-choice"}]\n' > "$home/migration-list.json"
        expected=1
        ;;
      ambiguous-note)
        write_known_rows_stub "$home/fakebin" migrated-row other-migrated-row
        printf '[{"id":"migrated-row","notes":"migrated from data/backlog.md id legacy-choice"},{"id":"other-migrated-row","notes":"migrated from data/backlog.md id legacy-choice"}]\n' > "$home/migration-list.json"
        expected=2
        ;;
      ambiguous-prefix)
        write_known_rows_stub "$home/fakebin" fm-legacy-choice fm-migration-origin-decision-legacy-choice
        expected=2
        ;;
      exact-error|derived-error|prefix-error)
        write_known_rows_stub "$home/fakebin" migrated-row
        case "$mode" in
          exact-error) printf '%s\n' "$key" > "$home/error-id" ;;
          derived-error) printf '%s\n' "$origin-decision-$key" > "$home/error-id" ;;
          prefix-error) printf '%s\n' "fm-$key" > "$home/error-id" ;;
        esac
        if [ "$mode" != prefix-error ]; then
          printf 'migrated-row\n' > "$home/closed-id"
          printf '[{"id":"migrated-row","notes":"migrated from data/backlog.md id legacy-choice"}]\n' > "$home/migration-list.json"
        fi
        expected=2
        ;;
      binding-lookup-error-*|binding-read-error|unbound|unbound-directory)
        key=third-choice
        write_known_rows_stub "$home/fakebin" migrated-row other-migrated-row
        printf 'migrated-row\n' > "$home/closed-id"
        jq -cn --arg key "$key" --arg derived "$origin-decision-$key" \
          '[{id:"migrated-row", notes:("migrated from data/backlog.md id " + $key)},
            {id:"other-migrated-row", notes:("migrated from data/backlog.md id " + $derived)}]' \
          > "$home/migration-list.json"
        case "$mode" in unbound*) expected=1 ;; *) expected=2 ;; esac
        ;;
    esac
    cp "$home/fakebin/tasks-axi" "$home/fakebin/tasks-axi-rows"
    cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ]; then
  if [ "$2" = "$(cat "$FM_HOME/error-id")" ]; then
    printf 'error: backlog record cannot be read\n' >&2
    exit 1
  fi
  if [ "$2" = "$(cat "$FM_HOME/closed-id")" ]; then
    printf 'task:\n  id: %s\n  state: done\n  held: no\n  blocked: no\n  hold_kind: -\n  body: ""\n' "$2"
    exit 0
  fi
fi
exec "$FM_HOME/fakebin/tasks-axi-rows" "$@"
SH
    cat > "$home/fakebin/bd" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list ] || exit 1
cat "$FM_HOME/migration-list.json"
SH
    chmod +x "$home/fakebin/tasks-axi" "$home/fakebin/bd"
    board=$(sweep_board "$home" migrated old "$key")
    sid=$(sweep_register "$home" "$board")
    case "$mode" in
      unbound) ;;
      unbound-directory) mkdir -p "$home/state/decision-bindings" ;;
      *) run_captain "$home" bind "$sid" "$origin" >/dev/null || fail "could not bind the $mode fixture" ;;
    esac
    session=idle
    case "$mode" in binding-lookup-error-*) session=${mode##*-} ;; esac
    case "$session" in
      idle) sweep_session "$store" "$board" open 0 2000-01-01T00:00:00.000Z ;;
      ended) sweep_session "$store" "$board" ended 0 - ;;
      nosession) mkdir -p "$store"; printf '{"sessions":{}}\n' > "$store/state.json" ;;
    esac
    permission_path=''
    permission_mode=700
    case "$mode" in
      binding-lookup-error-*|binding-read-error)
        if run_captain "$home" open-bound "$sid" "$key" 2> "$home/predicate.err"; then rc=0; else rc=$?; fi
        expect_code 2 "$rc" "the readable binding did not preserve both migration candidates"
        permission_path="$home/state/decision-bindings"
        if [ "$mode" = binding-read-error ]; then
          permission_path="$permission_path/$sid.origin"
          permission_mode=600
        fi
        chmod 000 "$permission_path"
        if perl -MErrno=EACCES -e '
          if ($ARGV[1] eq "binding-read-error") { open my $file, "<", $ARGV[0]; }
          else { lstat $ARGV[0]; }
          exit($! == EACCES ? 0 : 1);
        ' "$home/state/decision-bindings/$sid.origin" "$mode"; then fixture_rc=0; else fixture_rc=$?; fi
        if [ "$fixture_rc" -ne 0 ]; then
          chmod "$permission_mode" "$permission_path"
          fail "the binding permission fixture did not produce EACCES"
        fi
        ;;
    esac
    before=$(cksum < "$home/migration-list.json")
    if out=$(run_captain "$home" open-bound "$sid" "$key" 2> "$home/predicate.err"); then rc=0; else rc=$?; fi
    predicate_err=$(cat "$home/predicate.err")
    predicate_out=$out
    if out=$(LAVISH_AXI_STATE_DIR="$store" run_lavish "$home" sweep); then sweep_rc=0; else sweep_rc=$?; fi
    [ -z "$permission_path" ] || chmod "$permission_mode" "$permission_path"
    expect_code "$expected" "$rc" "migrated bound predicate $mode: $predicate_err"
    assert_equals '' "$predicate_out" "the migrated predicate emitted output"
    [ "$sweep_rc" -eq 0 ] || fail "the $mode migration sweep failed: $out"
    case "$mode" in
      binding-lookup-error-*|binding-read-error)
        assert_contains "$predicate_err" 'decision binding cannot be' "the binding read error was not reported"
        assert_contains "$out" "card $key is an open captain call or cannot be checked" "binding uncertainty was not explained: $out"
        ;;
    esac
    list=$(run_procevent "$home" list)
    if [ "$expected" = 1 ]; then
      assert_contains "$out" "retired: $sid" "the closed marker-noted row lost precedence: $out"
      assert_not_contains "$list" "$sid" "the closed migrated board remains registered"
    else
      assert_contains "$out" "kept: $sid" "the migrated or unknown call lost its listener: $out"
      assert_contains "$list" "$sid" "the migrated or unknown call lost its registration"
    fi
    assert_equals "$before" "$(cksum < "$home/migration-list.json")" "the predicate changed migration evidence"
  done
  pass "sweeps reuse migration note and prefix precedence and keep ambiguous or unreadable identities"
}

# --- calls moved to the done archive by backlog retention -------------------
#
# Backlog retention moves a closed call out of data/backlog.md into the archive
# tasks-axi writes, and the completion gate must still resolve it. These
# fixtures use the real layout: the rows are closed through the real commands
# and pushed out by retention (done_keep = 1), never hand-written into the file.

tests=(
test_sweep_retires_only_finished_board_listeners
test_auto_sweep_retires_only_finished_listeners
test_sweep_stops_a_live_listener_of_a_finished_board
test_sweep_preserves_deleted_board_keep_guards
test_sweep_keeps_boards_with_unsearchable_parents
test_sweep_preserves_rearmed_registration_generations
test_sweep_keeps_recently_handled_boards_in_literal_home_paths
test_sweep_keeps_unknown_inbox_evidence
test_sweep_keeps_unknown_card_discovery
test_sweep_resolves_bound_captain_keys
test_sweep_resolves_migrated_captain_keys
)
captain_hold_run_tests "$@"
