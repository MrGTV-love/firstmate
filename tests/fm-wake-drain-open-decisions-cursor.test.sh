#!/usr/bin/env bash
# tests/fm-wake-drain-open-decisions-cursor.test.sh - end-to-end behavior tests
# for the incremental, cursor-backed OPEN DECISIONS scan
# (fm-classify-lib.sh's status_open_decisions_incremental /
# scan_open_decisions_incremental, wired into bin/fm-wake-drain.sh). These drive
# the REAL drain script across MANY successive invocations over a status log
# that keeps growing, and assert both the printed output and a bounded-cost
# property, not the fold's own source text. tests/fm-wake-drain-open-decisions.test.sh
# already covers the fold's single-drain correctness; this file covers the
# cursor's cross-drain persistence and cost bound.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-drain-open-decisions-cursor-tests)

# Append <count> harmless filler lines (routine working: notes, never a
# needs-decision/blocked/resolved verb) to <file> and print the exact number of
# bytes appended, so a test can assert the read-probe's byte count against a
# known ground truth rather than an approximation.
append_filler() {  # <file> <count>
  local file=$1 count=$2 i=0 before after
  before=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  [ -n "$before" ] || before=0
  while [ "$i" -lt "$count" ]; do
    printf 'working: routine filler padding line %04d of growing status log\n' "$i" >> "$file"
    i=$((i + 1))
  done
  after=$(LC_ALL=C wc -c < "$file" 2>/dev/null | tr -d '[:space:]')
  printf '%s\n' "$((after - before))"
}

# The byte count the read-probe recorded for <file> on its MOST RECENT
# incremental fold call (last matching line in the probe log).
last_probe_bytes() {  # <probe-file> <status-file>
  grep -F "$(printf '%s\t' "$2")" "$1" 2>/dev/null | tail -1 | cut -f2
}

test_buried_decision_survives_many_growing_drains_and_resolution_clears_it() {
  local dir state out probe status bootstrap_bytes total_size round increment_bytes probe_bytes
  dir=$(make_case cursor-lifecycle)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task1.status"
  : > "$probe"

  # Open a keyed decision, buried under an initial filler round big enough to
  # make a full-file rescan cost visibly more than a small incremental one.
  printf 'needs-decision [key=api-shape]: pick REST or RPC\n' > "$status"
  append_filler "$status" 400 >/dev/null

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "first drain over a large buried decision failed"
  grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
    || fail "the buried decision did not surface on the bootstrap drain"
  bootstrap_bytes=$(last_probe_bytes "$probe" "$status")
  [ -n "$bootstrap_bytes" ] && [ "$bootstrap_bytes" -gt 0 ] \
    || fail "the bootstrap drain recorded no incremental read at all"

  # Many further drains, each appending only a SMALL increment while the total
  # log keeps growing large. The buried decision must resurface on EVERY one of
  # them (never dropped just because it is old or buried under more appends),
  # and each drain's read-probe byte count must match ONLY that round's small
  # increment - never the ever-growing total file size - proving the read cost
  # is bounded by new appends, not by total log size.
  for round in 1 2 3 4 5; do
    increment_bytes=$(append_filler "$status" 20)
    FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
      || fail "drain $round over a growing log failed"
    grep -F 'task1' "$out" | grep -F '[key=api-shape]' | grep -F 'pick REST or RPC' >/dev/null \
      || fail "the buried decision was dropped on growth round $round"
    probe_bytes=$(last_probe_bytes "$probe" "$status")
    [ "$probe_bytes" = "$increment_bytes" ] \
      || fail "round $round read $probe_bytes bytes, expected exactly this round's $increment_bytes-byte increment (cost is not bounded)"
  done
  total_size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  [ "$total_size" -gt "$bootstrap_bytes" ] \
    || fail "test setup error: the log never grew past its bootstrap size"

  # Now resolve it. The very next drain's own read (a small increment) must
  # clear it - not by rescanning the whole now-large file, but by folding the
  # small resolved line into the still-persisted open set.
  increment_bytes=$(printf 'resolved [key=api-shape]: went with REST\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "resolution drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "the resolved decision still printed as open right after resolution: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte resolved line (cost is not bounded)"

  # Grow the log again after resolution: the decision must stay cleared (a
  # closed decision is not resurrected by unrelated later growth), and the read
  # cost for this final round must still be bounded to that round's increment.
  increment_bytes=$(append_filler "$status" 20)
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-resolution growth drain failed"
  if grep -F 'OPEN DECISIONS' "$out" >/dev/null; then
    fail "a resolved decision reappeared after later unrelated growth: $(cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$increment_bytes" ] \
    || fail "the post-resolution drain read $probe_bytes bytes, expected exactly the $increment_bytes-byte increment (cost is not bounded)"

  pass "a buried decision survives many growing drains with bounded read cost, and resolution durably clears it at bounded cost too"
}

test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision() {
  local dir state out probe status rewritten_bytes probe_bytes
  dir=$(make_case cursor-truncation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task2.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before truncation failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before truncation"

  # Simulate a rewritten/truncated log (shrunk below the persisted cursor
  # offset): the decision is re-opened by a fresh needs-decision line in the
  # rewritten content, and the incremental scan must fall back to a full
  # re-fold of the new, smaller file rather than trusting a now-invalid cursor.
  printf 'needs-decision [key=migration]: rewritten after truncation\n' > "$status"
  rewritten_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-truncation drain failed"
  grep -F 'task2' "$out" | grep -F '[key=migration]' | grep -F 'rewritten after truncation' >/dev/null \
    || fail "the rewritten decision after truncation did not surface"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$rewritten_bytes" ] \
    || fail "post-truncation drain read $probe_bytes bytes, expected a full re-fold of the $rewritten_bytes-byte rewritten file"

  pass "a truncated/rewritten log falls back to a full re-fold instead of dropping or misreading the decision"
}

test_same_size_rewrite_is_detected_via_inode_identity() {
  local dir state out probe status new_bytes probe_bytes
  dir=$(make_case cursor-rotation)
  state="$dir/state"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  status="$state/task3.status"
  : > "$probe"

  printf 'needs-decision [key=migration]: pick the rollout plan\n' > "$status"
  append_filler "$status" 100 >/dev/null
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "initial drain before rotation failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' >/dev/null \
    || fail "the decision did not surface before rotation"

  # Replace the file at the same path with a DIFFERENT file of the SAME byte
  # size (mv gives the destination path a new inode) - a same-size rewrite,
  # which a plain offset>size shrink check alone would NOT catch. The buried
  # decision must still surface: the device+inode identity check must detect
  # this as a rotation/recreation and fall back to a full re-fold.
  new_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  printf 'needs-decision [key=migration]: rewritten via rotation\n' > "$dir/replacement"
  padded=$(LC_ALL=C wc -c < "$dir/replacement" | tr -d '[:space:]')
  pad=$((new_bytes - padded))
  [ "$pad" -gt 0 ] && head -c "$pad" /dev/zero | tr '\0' 'x' >> "$dir/replacement"
  mv "$dir/replacement" "$status"
  [ "$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')" = "$new_bytes" ] \
    || fail "test setup error: the rotated replacement is not the same size as the original"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "post-rotation drain failed"
  grep -F 'task3' "$out" | grep -F '[key=migration]' | grep -F 'rewritten via rotation' >/dev/null \
    || fail "the same-size rotated file's decision did not surface (inode-identity check did not fire)"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$new_bytes" ] \
    || fail "post-rotation drain read $probe_bytes bytes, expected a full re-fold of the $new_bytes-byte replacement"

  pass "a same-size file rotation (new inode) is detected and falls back to a full re-fold"
}

test_read_failure_preserves_state_for_retry() {
  local dir state reader statusfile cursor out before_cursor after_cursor
  dir=$(make_case cursor-read-failure)
  state="$dir/state"
  reader="$dir/fail-reader"
  statusfile="$state/task4.status"
  cursor="$state/.task4.open-decisions-cursor"
  out="$dir/drain.out"

  printf 'needs-decision [key=x]: something important\n' > "$statusfile"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the injected read failure failed"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the decision did not surface on the bootstrap drain"
  [ -s "$cursor" ] || fail "no cursor was persisted after the bootstrap drain"
  before_cursor=$(LC_ALL=C cksum "$cursor")

  printf 'working: more routine content\n' >> "$statusfile"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$reader"
  chmod +x "$reader"

  FM_STATE_OVERRIDE="$state" FM_STATUS_SPAN_READER="$reader" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of preserving state after the injected read failure"
  [ ! -s "$out" ] \
    || fail "the failed presentation read emitted a partial status presentation: $(command cat "$out")"
  after_cursor=$(LC_ALL=C cksum "$cursor")
  [ "$after_cursor" = "$before_cursor" ] \
    || fail "the failed read advanced or rewrote the persisted cursor"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake drain did not recover after the injected read failure"
  grep -F 'task4' "$out" | grep -F '[key=x]' | grep -F 'something important' >/dev/null \
    || fail "the open decision disappeared when presentation reads recovered: $(command cat "$out")"

  pass "a failed presentation read preserves status state for retry"
}

test_cursor_cache_read_failure_refolds_without_replaying_unread_status() {
  local dir state fakebin statusfile cursor out probe real_cat status_bytes probe_bytes
  dir=$(make_case cursor-cache-read-failure)
  state="$dir/state"
  fakebin="$dir/failbin"
  mkdir -p "$fakebin"
  statusfile="$state/task5.status"
  cursor="$state/.task5.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  real_cat=$(command -v cat)

  {
    printf 'needs-decision [key=cache]: recover from authoritative status\n'
    printf 'note: already handled informational status\n'
  } > "$statusfile"
  append_filler "$statusfile" 40 >/dev/null
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain before the cursor-cache read failure failed"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the decision did not surface before the cursor-cache read failure"
  grep -F 'task5 note: already handled informational status' "$out" >/dev/null \
    || fail "the bootstrap drain did not surface the informational status"
  [ -s "$cursor" ] || fail "no cursor was persisted before the cursor-cache read failure"

  printf 'working: appended before cache failure\n' >> "$statusfile"
  status_bytes=$(LC_ALL=C wc -c < "$statusfile" | tr -d '[:space:]')
  : > "$probe"
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 1 ] && [ "\$1" = "$cursor" ]; then
  exit 1
fi
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" PATH="$fakebin:$PATH" "$DRAIN" > "$out" \
    || fail "wake drain failed instead of refolding after the cursor-cache read failure"
  grep -F 'task5' "$out" | grep -F '[key=cache]' | grep -F 'authoritative status' >/dev/null \
    || fail "the cursor-cache read failure hid the recurring open decision: $(command cat "$out")"
  if grep -F 'UNREAD STATUS' "$out" >/dev/null \
    || grep -F 'already handled informational status' "$out" >/dev/null; then
    fail "the cursor-cache read failure replayed handled informational status as new: $(command cat "$out")"
  fi
  probe_bytes=$(last_probe_bytes "$probe" "$statusfile")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the cursor-cache read failure read $probe_bytes bytes, expected a full $status_bytes-byte authoritative refold"

  pass "a cursor-cache read failure refolds decisions without replaying handled unread status"
}

test_pre_fix_cursor_refolds_corr_tagged_decision() {
  local dir state status cursor out probe status_bytes ident probe_bytes
  dir=$(make_case cursor-corr-tag-migration)
  state="$dir/state"
  status="$state/task7.status"
  cursor="$state/.task7.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'needs-decision [corr=d448ea86afa4bf67] [key=loan-installment-cadence-amount]: pick the cadence\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the corr-tag cursor migration failed"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  [ -n "$ident" ] || fail "bootstrap drain did not persist a file identity"
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'version=3\n'
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while migrating the pre-fix corr-tag cursor"
  grep -F 'task7 [key=loan-installment-cadence-amount] needs-decision: pick the cadence' "$out" >/dev/null \
    || fail "the pre-fix cursor hid the corr-tagged decision after migration: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the pre-fix cursor read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  pass "a pre-fix cursor is rebuilt so a previously skipped corr-tagged decision surfaces"
}

test_previous_fold_cache_is_refolded_under_current_semantics() {
  local dir state status cursor out probe status_bytes ident appended_bytes probe_bytes
  dir=$(make_case cursor-fold-version)
  state="$dir/state"
  status="$state/task6.status"
  cursor="$state/.task6.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"

  printf 'blocked [key=pending-reply-abcdef0123456789]: forged decision\n' > "$status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "bootstrap drain for the fold-version migration failed"
  [ ! -s "$out" ] || fail "the current whole-file semantics accepted the foreign reserved-key decision: $(cat "$out")"
  ident=$(sed -n 's/^ident=//p' "$cursor")
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  {
    printf 'offset=%s\n' "$status_bytes"
    printf 'ident=%s\n' "$ident"
    printf 'pending-reply-abcdef0123456789\tblocked\tforged decision'
  } > "$cursor"
  : > "$probe"

  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "drain failed while upgrading the previous fold cache"
  [ ! -s "$out" ] || fail "the previous fold cache kept surfacing a foreign reserved-key decision: $(cat "$out")"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "the previous fold cache read $probe_bytes bytes instead of refolding all $status_bytes authoritative bytes"

  appended_bytes=$(printf 'needs-decision [key=current]: choose the current path\n' | tee -a "$status" | LC_ALL=C wc -c | tr -d '[:space:]')
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "same-version incremental drain failed after cache migration"
  grep -F 'task6 [key=current] needs-decision: choose the current path' "$out" >/dev/null \
    || fail "the same-version append did not fold into the migrated open set"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$appended_bytes" ] \
    || fail "the same-version fold read $probe_bytes bytes instead of only the $appended_bytes-byte append"

  pass "an old fold cache is rebuilt once before same-version incremental reads resume"
}

test_terminal_supersession_reaches_cached_drains() {
  local dir state status cursor out kind terminal expected closing ident size span pass_number
  for kind in scout ship secondmate; do
    for terminal in 'done' failed; do
      dir=$(make_case "terminal-$kind-$terminal")
      state="$dir/state"; status="$state/task.status"; cursor="$state/.task.open-decisions-cursor"; out="$dir/drain.out"
      printf 'kind=%s\n' "$kind" > "$state/task.meta"
      printf 'blocked [key=access]: waiting\n' > "$status"
      FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "initial blocked drain failed"
      assert_contains "$(cat "$out")" 'task [key=access] blocked: waiting' "initial blocker must surface"
      printf '%s: report saved\nnote: cleanup complete\n' "$terminal" >> "$status"
      expected=''; closing=$terminal
      if [ "$kind" = secondmate ]; then expected=$'access\tblocked\twaiting'; closing=blocked; fi
      for pass_number in 1 2; do
        if [ "$pass_number" = 2 ]; then
          ident=$(sed -n 's/^ident=//p' "$cursor")
          size=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
          printf 'version=5\noffset=%s\nident=%s\naccess\tblocked\twaiting' "$size" "$ident" > "$cursor"
        fi
        FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "$kind terminal drain failed"
        if [ "$kind" = secondmate ]; then
          assert_contains "$(cat "$out")" 'task [key=access] blocked: waiting' "secondmate blocker must survive $terminal and cache migration"
        else
          assert_not_contains "$(cat "$out")" 'OPEN DECISIONS' "$kind pre-terminal blocker resurfaced after $terminal or cache migration"
        fi
        bash -c '. "$1"; [ "$(status_open_decisions "$2")" = "$3" ] && [ "$(status_open_decisions_incremental "$2")" = "$3" ] && [ "$(status_key_closing_verb "$2" access)" = "$4" ]' \
          _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$expected" "$closing" \
          || fail "$kind whole-file, incremental, and key-history reads disagree with terminal supersession"
      done
      span=$(bash -c '. "$1"; status_span_first_actionable "$2" 0' _ "$ROOT/bin/fm-classify-lib.sh" "$status")
      if [ "$kind" = secondmate ]; then
        assert_contains "$span" 'blocked [key=access]: waiting' "secondmate opening must remain actionable"
      else
        assert_not_contains "$span" 'waiting' "$kind superseded opening remained actionable in a captured span"
      fi
      printf 'blocked [key=access]: reopened\nneeds-decision [key=new]: a new decision\nnote: more cleanup\n' >> "$status"
      FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "reopened drain failed"
      assert_contains "$(cat "$out")" 'task [key=access] blocked: reopened' "post-terminal reopening must surface"
      assert_contains "$(cat "$out")" 'task [key=new] needs-decision: a new decision' "post-terminal new key must surface"
      printf 'resolved [key=access]: answered\nresolved [key=new]: answered\nnote: final cleanup\n' >> "$status"
      FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$dir/drain.err" || fail "resolved drain failed"
      assert_not_contains "$(cat "$out")" 'OPEN DECISIONS' "matching resolutions must close reopened decisions"
    done
  done
  pass "terminal supersession reaches whole-file reads, incremental drains, old caches, and captured spans"
}

test_kind_changes_invalidate_folded_decisions() {
  local dir state status kind expected
  dir=$(make_case cursor-kind-change); state="$dir/state"; status="$state/task.status"
  printf 'blocked [key=access]: waiting\ndone: report saved\nnote: cleanup complete\n' > "$status"
  for kind in unknown ship secondmate scout; do
    [ "$kind" = unknown ] || printf 'kind=%s\n' "$kind" >> "$state/task.meta"
    case "$kind" in unknown|secondmate) expected=$'access\tblocked\twaiting' ;; *) expected='' ;; esac
    bash -c '. "$1"; [ "$(status_open_decisions_incremental "$2")" = "$3" ] && [ "$(status_open_decisions "$2")" = "$3" ]' \
      _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$expected" \
      || fail "cached decisions did not follow the current $kind metadata without a status append"
  done
  pass "folded decisions are rebuilt when task-kind evidence changes"
}

# A golden corpus that exercises every fold rule: keyed and keyless opens,
# resolutions and captain-held transfers, a note-head key, corr tokens in both
# forms, reserved pending-reply keys with and without their vocabulary, stamped
# heads whose colons must not move the separator, a colonless keyed line,
# continuation prose, an invalid slug, ship/scout terminal supersession, and a
# final line with no newline.
write_golden_corpus() {  # <status-file>
  {
    printf 'working: started\n'
    printf 'needs-decision: keyless question one\n'
    printf 'continuation prose: with a colon that is not a verb\n'
    printf 'needs-decision [key=api-shape]: REST or RPC\n'
    printf 'blocked [at=10:30] [key=access]: waiting on a login\n'
    printf 'note: an informational line\n'
    printf 'needs-decision: [key=note-head] key written after the colon\n'
    printf 'resolved [key=api-shape]: REST\n'
    printf 'needs-decision corr=0123456789abcdef [key=corr-open]: answered via corr\n'
    printf 'needs-decision [key=pending-reply-abc]: unrelated takeover attempt\n'
    printf 'needs-decision [key=pending-reply-def]: pending-reply-missed: parent owned\n'
    printf 'blocked [key=bad slug!]: rejected slug\n'
    printf 'blocked [key=colonless] no colon on this keyed line\n'
    printf 'resolved: keyless closes default\n'
    printf 'captain-held [key=access]: tracked by fm-access\n'
    printf 'resolved corr=0123456789abcdef [key=corr-open]: closed via corr\n'
    printf 'paused: waiting for CI\n'
    printf 'needs-decision [key=late]: opened after the pause\n'
    printf 'done: phase one finished\n'
    printf 'needs-decision [key=after-done]: opened after a terminal line\n'
    printf 'resolved [key=pending-reply-def]: pending-reply-resolved: parent closed\n'
    printf 'failed [at=1791400000]: a failure line\n'
    printf 'blocked [key=tail]: the last line has no newline'
  } > "$1"
}

# Byte offsets of every line end in <file> (the boundaries a checkpoint may
# legitimately sit on), plus 0.
line_end_offsets() {  # <file>
  LC_ALL=C awk 'BEGIN { n = 0; print 0 } { n += length($0) + 1; print n }' "$1"
}

# Span reader that records every span it serves, so a test can prove a seeded
# fold read only the bytes after its checkpoint.
make_span_probe() {  # <dir> -> path of the reader
  cat > "$1/span-reader" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$2" "$3" >> "${FM_TEST_SPAN_LOG:?}"
LC_ALL=C tail -c +"$(($2 + 1))" "$1" | LC_ALL=C head -c "$3"
SH
  chmod +x "$1/span-reader"
  printf '%s\n' "$1/span-reader"
}

# The golden equivalence test for the checkpoint-seeded whole-file fold: for
# every task kind and EVERY line boundary of the corpus, a checkpoint written
# through that boundary by the real incremental writer seeds a whole-file fold
# whose output is byte-for-byte the fold from line 1, and the seeded fold reads
# only the bytes after the checkpoint. A checkpoint that does not sit on a line
# boundary is refused and the fold starts from line 1, with the same output.
test_seeded_whole_file_fold_matches_a_fold_from_line_one() {
  local dir state status reader spanlog kind out
  dir=$(make_case seeded-golden); state="$dir/state"; status="$state/task.status"
  write_golden_corpus "$status"
  reader=$(make_span_probe "$dir")
  spanlog="$dir/spans"
  for kind in ship scout secondmate; do
    printf 'kind=%s\n' "$kind" > "$state/task.meta"
    out=$(FM_TEST_SPAN_LOG="$spanlog" bash -c '
      . "$1"
      f=$2 reader=$3 spanlog=$4 offsets=$5
      cf="$(dirname "$f")/.task.open-decisions-cursor"
      size=$(LC_ALL=C wc -c < "$f" | tr -d "[:space:]")
      rm -f "$cf"
      reference=$(status_open_decisions "$f")
      [ -n "$reference" ] || { echo "the corpus folded to nothing"; exit 1; }
      for k in $offsets $((size - 7)) 3; do
        [ "$k" -le "$size" ] || continue
        rm -f "$cf"
        status_open_decisions_incremental "$f" "$k" >/dev/null
        checkpoint=$(sed -n "s/^offset=//p" "$cf")
        expected=0
        for boundary in $offsets; do
          [ "$boundary" -le "$k" ] && [ "$boundary" -le "$size" ] && expected=$boundary
        done
        [ "$checkpoint" = "$expected" ] || { echo "writer checkpointed at $checkpoint instead of complete boundary $expected"; exit 1; }
        : > "$spanlog"
        seeded=$(FM_STATUS_SPAN_READER=$reader status_open_decisions "$f")
        [ "$seeded" = "$reference" ] || { printf "offset %s diverged:\n%s\n--- reference:\n%s\n" "$k" "$seeded" "$reference"; exit 1; }
        if [ "$checkpoint" -lt "$size" ]; then
          grep -qx "$checkpoint $((size - checkpoint))" "$spanlog" || { echo "offset $checkpoint: seeded fold did not read only the tail: $(cat "$spanlog")"; exit 1; }
        fi
      done
      rm -f "$cf"
      [ "$(status_open_decisions "$f")" = "$reference" ] || { echo "fold without a checkpoint changed"; exit 1; }
    ' _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$reader" "$spanlog" "$(line_end_offsets "$status" | tr '\n' ' ')" 2>&1) \
      || fail "seeded fold diverged for kind $kind: $out"
  done
  pass "golden: a checkpoint-seeded whole-file fold equals the fold from line 1 at every boundary and kind"
}

# A checkpoint is reused only under the exact reading that wrote it: another
# kind, a fold-affecting override, a replaced log, or a damaged checkpoint all
# fold from line 1, and none of them writes anything.
test_seeded_fold_refuses_checkpoints_from_another_reading() {
  local dir state status out
  dir=$(make_case seeded-refusals); state="$dir/state"; status="$state/task.status"
  write_golden_corpus "$status"
  # End on a newline so the full-length checkpoint sits on a line boundary.
  printf '\n' >> "$status"
  printf 'kind=ship\n' > "$state/task.meta"
  out=$(bash -c '
    . "$1"
    f=$2 cf="$(dirname "$2")/.task.open-decisions-cursor"
    status_open_decisions_incremental "$f" >/dev/null
    cp "$cf" "$cf.saved"
    # Poison the checkpoint set so any reuse would be visible in the output.
    { sed -n 1,3p "$cf.saved"; printf "poison\tneeds-decision\tfrom the checkpoint\n"; } > "$cf"
    poisoned=$(status_open_decisions "$f")
    case "$poisoned" in *poison*) ;; *) echo "control: a matching checkpoint was not reused"; exit 1 ;; esac
    for override in "FM_CLASSIFY_RESOLVE_VERB=answered" "FM_CLASSIFY_CAPTAIN_HELD_VERB=awaiting-captain" \
      "FM_CLASSIFY_RESERVED_KEY_PREFIXES=pending-reply- secret-"; do
      got=$(env "$override" bash -c ". \"$1\"; status_open_decisions \"$2\"" _ "$1" "$f")
      case "$got" in *poison*) echo "override $override reused a default-reading checkpoint"; exit 1 ;; esac
    done
    got=$(status_open_decisions "$f" scout)
    case "$got" in *poison*) echo "an explicit other kind reused the ship checkpoint"; exit 1 ;; esac
    before=$(cat "$cf")
    cp "$f" "$f.new" && mv -f "$f.new" "$f"
    got=$(status_open_decisions "$f")
    case "$got" in *poison*) echo "a replaced log reused the old checkpoint"; exit 1 ;; esac
    [ "$(cat "$cf")" = "$before" ] || { echo "a whole-file read rewrote the checkpoint"; exit 1; }
    printf "version=garbage\n" > "$cf"
    got=$(status_open_decisions "$f")
    case "$got" in *poison*|"") echo "a damaged checkpoint was not ignored"; exit 1 ;; esac
    exit 0
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status" 2>&1) || fail "seeded fold refusal: $out"
  pass "seeded fold reuses a checkpoint only under its own kind, verbs, and file identity, and never writes one"
}

# The fleet snapshot folds point-in-time copies of each log. The checkpoint is
# carried onto a copy only when it describes the copied file and lies within
# the copy, so the copy's fold is the full fold of the copy's bytes either way.
test_checkpoint_carries_onto_a_snapshot_copy_only_when_it_describes_it() {
  local dir state status out
  dir=$(make_case seeded-carry); state="$dir/state"; status="$state/task.status"
  write_golden_corpus "$status"
  printf '\n' >> "$status"
  printf 'kind=secondmate\n' > "$state/task.meta"
  mkdir -p "$dir/copy"
  out=$(bash -c '
    . "$1"
    f=$2 copydir=$3
    copy="$copydir/task.status"; ccf="$copydir/.task.open-decisions-cursor"
    status_open_decisions_incremental "$f" >/dev/null
    ident=$(_fm_open_decisions_file_ident "$f")
    cp -p "$f" "$copy"; cp "$(dirname "$f")/task.meta" "$copydir/task.meta"
    status_open_decisions_checkpoint_carry "$f" "$copy" "$ident"
    [ -f "$ccf" ] || { echo "a describing checkpoint was not carried"; exit 1; }
    grep -qx "ident=$(_fm_open_decisions_file_ident "$copy")" "$ccf" || { echo "carried checkpoint does not name the copy"; exit 1; }
    reference=$(rm -f "$ccf.ref"; mv "$ccf" "$ccf.ref"; status_open_decisions "$copy"; mv "$ccf.ref" "$ccf")
    [ "$(status_open_decisions "$copy")" = "$reference" ] || { echo "carried checkpoint changed the copy fold"; exit 1; }
    rm -f "$ccf"
    status_open_decisions_checkpoint_carry "$f" "$copy" "strong:0:0:not-this-file"
    [ ! -e "$ccf" ] || { echo "a checkpoint was carried under another identity"; exit 1; }
    head -c 40 "$f" > "$copy"
    status_open_decisions_checkpoint_carry "$f" "$copy" "$ident"
    [ ! -e "$ccf" ] || { echo "a checkpoint past the copy end was carried"; exit 1; }
    exit 0
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$dir/copy" 2>&1) || fail "checkpoint carry: $out"
  pass "a fold checkpoint rides onto a snapshot copy only when it describes that copy"
}

# Opt-in golden check over real status logs: FM_FOLD_GOLDEN_DIRS names one or
# more state directories (space separated). Each log is copied first, so the
# check never writes beside the real log, then folded from line 1 and seeded
# from checkpoints at several line boundaries; every result must be identical.
test_golden_fold_equivalence_on_real_status_logs() {
  local golden_dirs=${FM_FOLD_GOLDEN_DIRS:-} dir out count=0 f work
  if [ -z "$golden_dirs" ]; then
    pass "golden fold over real status logs skipped (set FM_FOLD_GOLDEN_DIRS to run it)"
    return 0
  fi
  work="$TMP_ROOT/golden-real"
  for dir in $golden_dirs; do
    for f in "$dir"/*.status; do
      [ -f "$f" ] && [ ! -L "$f" ] || continue
      rm -rf "$work"; mkdir -p "$work"
      cp "$f" "$work/task.status"
      [ ! -f "${f%.status}.meta" ] || cp "${f%.status}.meta" "$work/task.meta"
      out=$(bash -c '
        . "$1"
        f=$2 offsets=$3
        cf="$(dirname "$f")/.task.open-decisions-cursor"
        rm -f "$cf"
        reference=$(status_open_decisions "$f")
        for k in $offsets; do
          rm -f "$cf"
          incremental=$(status_open_decisions_incremental "$f" "$k")
          seeded=$(status_open_decisions "$f")
          [ "$seeded" = "$reference" ] || { echo "seeded at $k diverged"; exit 1; }
        done
        rm -f "$cf"
        [ "$(status_open_decisions_incremental "$f")" = "$reference" ] || { echo "incremental diverged"; exit 1; }
      ' _ "$ROOT/bin/fm-classify-lib.sh" "$work/task.status" \
        "$(line_end_offsets "$work/task.status" | awk 'NR == 1 || NR % 500 == 0 { print } END { print }' | tr '\n' ' ')" 2>&1) \
        || fail "golden fold diverged on $f: $out"
      count=$((count + 1))
    done
  done
  [ "$count" -gt 0 ] || fail "FM_FOLD_GOLDEN_DIRS named no status logs"
  pass "golden fold: $count real status logs fold identically from line 1, seeded, and incrementally"
}

test_successive_appends_replay_unfinished_lines() {
  local dir state status out
  dir=$(make_case unfinished-lines); state="$dir/state"; status="$state/task.status"
  printf 'kind=secondmate\n' > "$state/task.meta"
  mkdir -p "$dir/copy"
  out=$(bash -c '
    . "$1"
    f=$2 copy=$3 cf="$(dirname "$2")/.task.open-decisions-cursor"
    printf "needs-decision [key=api]: REST" > "$f"
    [ "$(status_open_decisions_incremental "$f")" = $'"'"'api\tneeds-decision\tREST'"'"' ] || exit 1
    grep -qx "offset=0" "$cf" || { echo "partial opener was checkpointed"; exit 1; }
    printf " or RPC\n" >> "$f"
    expected=$'"'"'api\tneeds-decision\tREST or RPC'"'"'
    [ "$(status_open_decisions_incremental "$f")" = "$expected" ] || { echo "completed opener lost its suffix"; exit 1; }
    [ "$(status_open_decisions "$f")" = "$expected" ] || exit 1
    printf "resolved [key=api]: settled" >> "$f"
    [ -z "$(status_open_decisions_incremental "$f")" ] || exit 1
    printf "\nneeds-decision [key=utf8]: café" >> "$f"
    expected=$'"'"'utf8\tneeds-decision\tcafé'"'"'
    [ "$(status_open_decisions_incremental "$f")" = "$expected" ] || exit 1
    printf " or thé\n" >> "$f"
    expected=$'"'"'utf8\tneeds-decision\tcafé or thé'"'"'
    [ "$(status_open_decisions_incremental "$f")" = "$expected" ] || { echo "multibyte partial opener diverged"; exit 1; }
    ident=$(_fm_open_decisions_file_ident "$f")
    cp "$f" "$copy"; cp "${f%.status}.meta" "${copy%.status}.meta"
    status_open_decisions_checkpoint_carry "$f" "$copy" "$ident"
    [ "$(status_open_decisions "$copy")" = "$expected" ] || { echo "snapshot carried a partial fold"; exit 1; }
    size=$(wc -c < "$f" | tr -d "[:space:]")
    printf "version=9:secondmate\noffset=%s\nident=%s\napi\tneeds-decision\tREST\n" "$size" "$ident" > "$cf"
    [ "$(status_open_decisions "$f")" = "$expected" ] || { echo "whole-file read reused poisoned legacy checkpoint"; exit 1; }
    rm -f "$(dirname "$copy")/.task.open-decisions-cursor"
    status_open_decisions_checkpoint_carry "$f" "$copy" "$ident"
    [ ! -e "$(dirname "$copy")/.task.open-decisions-cursor" ] || { echo "legacy checkpoint carried onto snapshot"; exit 1; }
    [ "$(status_open_decisions_incremental "$f")" = "$expected" ] || { echo "incremental reused poisoned legacy checkpoint"; exit 1; }
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$dir/copy/task.status" 2>&1) \
    || fail "successive unfinished lines: $out"
  pass "successive appends replay partial lines and reject poisoned legacy checkpoints"
}

test_utf8_whitespace_uses_full_fold_locale() {
  local dir state out
  dir=$(make_case utf8-locale); state="$dir/state"
  printf 'kind=secondmate\n' > "$state/task.meta"
  mkdir -p "$dir/copy"
  out=$(LC_ALL=en_US.UTF-8 bash -c '
    . "$1"
    f=$2 copy=$3 cf="$(dirname "$2")/.task.open-decisions-cursor"
    printf "needs-decision:\342\200\203[key=api] choose café" > "$f"
    expected=$'"'"'api\tneeds-decision\tchoose café'"'"'
    [ "$(status_open_decisions "$f")" = "$expected" ] || { echo "locale does not recognize UTF-8 whitespace"; exit 1; }
    [ "$(status_open_decisions_incremental "$f")" = "$expected" ] || { echo "partial fold changed locale"; exit 1; }
    printf "\n" >> "$f"
    [ "$(status_open_decisions_incremental "$f")" = "$expected" ] || { echo "complete fold changed locale"; exit 1; }
    size=$(LC_ALL=C wc -c < "$f" | tr -d "[:space:]")
    grep -qx "offset=$size" "$cf" || { echo "checkpoint offset counted characters"; exit 1; }
    ident=$(_fm_open_decisions_file_ident "$f")
    cp "$f" "$copy"; cp "${f%.status}.meta" "${copy%.status}.meta"
    status_open_decisions_checkpoint_carry "$f" "$copy" "$ident"
    [ "$(status_open_decisions "$copy")" = "$expected" ] || { echo "snapshot fold changed locale"; exit 1; }
    printf "resolved [key=api]: settled\n" >> "$f"
    [ -z "$(status_open_decisions_incremental "$f")" ] || { echo "resolution left a phantom decision"; exit 1; }
    size=$(LC_ALL=C wc -c < "$f" | tr -d "[:space:]")
    printf "version=10:secondmate\noffset=%s\nident=%s\ndefault\tneeds-decision\tphantom\n" "$size" "$ident" > "$cf"
    [ -z "$(status_open_decisions "$f")" ] || { echo "full fold accepted divergent checkpoint"; exit 1; }
    cp "$f" "$copy"
    rm -f "$(dirname "$copy")/.task.open-decisions-cursor"
    status_open_decisions_checkpoint_carry "$f" "$copy" "$ident"
    [ ! -e "$(dirname "$copy")/.task.open-decisions-cursor" ] || { echo "divergent checkpoint reached snapshot"; exit 1; }
    [ -z "$(status_open_decisions_incremental "$f")" ] || { echo "incremental accepted divergent checkpoint"; exit 1; }
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$state/task.status" "$dir/copy/task.status" 2>&1) \
    || fail "UTF-8 fold locale: $out"
  pass "UTF-8 fold locale matches full parsing with byte offsets and legacy invalidation"
}

test_checkpoint_rejects_a_previous_parsing_locale() {
  local dir state out from to
  dir=$(make_case cross-locale); state="$dir/state"
  printf 'kind=secondmate\n' > "$state/task.meta"
  mkdir -p "$dir/copy"
  printf 'kind=secondmate\n' > "$dir/copy/task.meta"
  for from in C en_US.UTF-8; do
    if [ "$from" = C ]; then to=en_US.UTF-8; else to=C; fi
    printf 'needs-decision:\342\200\203[key=api] choose a plan\n' > "$state/task.status"
    rm -f "$state/.task.open-decisions-cursor" "$dir/copy/.task.open-decisions-cursor"
    LC_ALL="$from" bash -c '. "$1"; status_open_decisions_incremental "$2" >/dev/null' \
      _ "$ROOT/bin/fm-classify-lib.sh" "$state/task.status" || fail "could not seed $from checkpoint"
    cp "$state/task.status" "$dir/copy/task.status"
    out=$(LC_ALL="$to" bash -c '
      . "$1"
      f=$2 copy=$3 cf="$(dirname "$2")/.task.open-decisions-cursor"
      cp "$f" "$copy"
      expected=$(status_open_decisions "$copy")
      before=$(cat "$cf")
      [ "$(status_open_decisions "$f")" = "$expected" ] || { echo "whole-file reused another locale"; exit 1; }
      [ "$(cat "$cf")" = "$before" ] || { echo "read-only fold wrote its checkpoint"; exit 1; }
      . "$4"
      [ "$(status_open_decisions_cursor_offset "$f")" = 0 ] || { echo "wake reader accepted another locale"; exit 1; }
      status_open_decisions_checkpoint_carry "$f" "$copy" "$(_fm_open_decisions_file_ident "$f")"
      [ ! -e "$(dirname "$copy")/.task.open-decisions-cursor" ] || { echo "snapshot carried another locale"; exit 1; }
      [ "$(status_open_decisions_incremental "$f")" = "$expected" ] || { echo "incremental reused another locale"; exit 1; }
      [ "$(cat "$cf")" != "$before" ] || { echo "incremental did not replace the signature"; exit 1; }
      printf "resolved [key=api]: settled\n" >> "$f"
      printf "resolved [key=api]: settled\n" >> "$copy"
      [ "$(status_open_decisions_incremental "$f")" = "$(status_open_decisions "$copy")" ] || { echo "resolution diverged"; exit 1; }
    ' _ "$ROOT/bin/fm-classify-lib.sh" "$state/task.status" "$dir/copy/task.status" "$ROOT/bin/fm-status-wake-lib.sh" 2>&1) \
      || fail "$from to $to checkpoint reuse: $out"
  done
  pass "locale changes invalidate incremental, read-only, wake and snapshot checkpoint reuse"
}

test_checkpoint_rejects_a_previous_parsing_locale
test_successive_appends_replay_unfinished_lines
test_utf8_whitespace_uses_full_fold_locale
test_terminal_supersession_reaches_cached_drains
test_kind_changes_invalidate_folded_decisions
test_seeded_whole_file_fold_matches_a_fold_from_line_one
test_seeded_fold_refuses_checkpoints_from_another_reading
test_checkpoint_carries_onto_a_snapshot_copy_only_when_it_describes_it
test_golden_fold_equivalence_on_real_status_logs
test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision
test_same_size_rewrite_is_detected_via_inode_identity
test_read_failure_preserves_state_for_retry
test_cursor_cache_read_failure_refolds_without_replaying_unread_status
test_pre_fix_cursor_refolds_corr_tagged_decision
test_previous_fold_cache_is_refolded_under_current_semantics
test_buried_decision_survives_many_growing_drains_and_resolution_clears_it
