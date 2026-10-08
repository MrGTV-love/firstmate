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
    printf 'version=9:unknown\n'
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

test_large_previous_fold_cache_migrates_within_startup_bound() {
  local dir state status cursor out probe status_bytes ident probe_bytes
  dir=$(make_case cursor-large-migration)
  state="$dir/state"
  status="$state/task.status"
  cursor="$state/.task.open-decisions-cursor"
  out="$dir/drain.out"
  probe="$dir/probe.tsv"
  printf 'kind=secondmate\n' > "$state/task.meta"
  printf 'needs-decision [key=upgrade-gate]: choose the migration path\n' > "$status"
  python3 - "$status" <<'PY'
import sys
with open(sys.argv[1], "a") as handle:
    for i in range(24000):
        handle.write(f"working: routine checks passed {i:04d}\n")
PY
  ident=$(bash -c '. "$1"; _fm_open_decisions_file_ident "$2"' \
    _ "$ROOT/bin/fm-classify-lib.sh" "$status")
  status_bytes=$(LC_ALL=C wc -c < "$status" | tr -d '[:space:]')
  printf 'version=9:secondmate\noffset=%s\nident=%s\n' "$status_bytes" "$ident" > "$cursor"
  : > "$probe"
  bash -c '. "$1"; fm_run_timed 120 env FM_STATE_OVERRIDE="$2" FM_OPEN_DECISIONS_READ_PROBE="$3" "$4"' \
    _ "$ROOT/bin/fm-timeout-lib.sh" "$state" "$probe" "$DRAIN" > "$out" \
    || fail "previous-version large-history drain exhausted the startup bound"
  assert_contains "$(cat "$out")" 'task [key=upgrade-gate] needs-decision: choose the migration path' \
    "large-history migration lost the buried decision"
  probe_bytes=$(last_probe_bytes "$probe" "$status")
  [ "$probe_bytes" = "$status_bytes" ] \
    || fail "large-history migration trusted the obsolete checkpoint instead of folding $status_bytes bytes"
  FM_STATE_OVERRIDE="$state" FM_OPEN_DECISIONS_READ_PROBE="$probe" "$DRAIN" > "$out" \
    || fail "cached drain after large-history migration failed"
  assert_contains "$(cat "$out")" 'task [key=upgrade-gate] needs-decision: choose the migration path' \
    "migrated checkpoint lost the buried decision on reuse"
  pass "a previous-version large-history checkpoint rebuilds within the startup bound"
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
  local LC_ALL=C offset=0 line
  printf '0\n'
  while IFS= read -r line; do
    offset=$((offset + ${#line} + 1))
    printf '%s\n' "$offset"
  done < "$1"
}

line_split_offsets() {  # <file>
  local LC_ALL=C offset=0 line head
  while IFS= read -r line; do
    case "$line" in
      needs-decision*|blocked*|resolved*|captain-held*)
        printf '%s\n' "$((offset + 3))"
        case "$line" in
          *'[key='*)
            head=${line%%'[key='*}
            printf '%s\n' "$((offset + ${#head} + 6))"
            ;;
        esac
        case "$line" in
          *': '*)
            head=${line%%': '*}
            printf '%s\n' "$((offset + ${#head} + 4))"
            ;;
        esac
        ;;
    esac
    offset=$((offset + ${#line} + 1))
  done < "$1"
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
      f=$2 reader=$3 spanlog=$4 offsets=$5 splits=$6
      kind=$(_fm_status_kind "$f")
      prefix="${f%.status}-prefix.status"
      cf="$(dirname "$f")/.task.open-decisions-cursor"
      size=$(LC_ALL=C wc -c < "$f" | tr -d "[:space:]")
      rm -f "$cf"
      reference=$(status_open_decisions "$f")
      [ -n "$reference" ] || { echo "the corpus folded to nothing"; exit 1; }
      for k in $offsets $splits "$size" $((size - 7)) 3; do
        [ "$k" -le "$size" ] || continue
        rm -f "$cf"
        _fm_status_read_span "$f" 0 "$k" > "$prefix" || exit 1
        expected=$(status_open_decisions "$prefix" "$kind")
        incremental=$(status_open_decisions_incremental "$f" "$k")
        [ "$incremental" = "$expected" ] || { echo "first incremental fold at $k differs from its byte-0 prefix"; exit 1; }
        grep -qx "offset=$k" "$cf" || { echo "writer did not checkpoint at $k"; exit 1; }
        : > "$spanlog"
        seeded=$(FM_STATUS_SPAN_READER=$reader status_open_decisions "$f")
        [ "$seeded" = "$reference" ] || { printf "offset %s diverged:\n%s\n--- reference:\n%s\n" "$k" "$seeded" "$reference"; exit 1; }
        case " $offsets " in
          *" $k "*)
            if [ "$k" -lt "$size" ]; then
              grep -qx "$k $((size - k))" "$spanlog" || { echo "offset $k: seeded fold did not read only the tail: $(cat "$spanlog")"; exit 1; }
            fi
            ;;
          *)
            ! grep -q "^$k " "$spanlog" || { echo "offset $k: a mid-line checkpoint seeded the fold"; exit 1; }
            ;;
        esac
        : > "$spanlog"
        completed=$(FM_STATUS_SPAN_READER=$reader status_open_decisions_incremental "$f")
        [ "$completed" = "$reference" ] || { echo "retained cursor at $k corrupted the completing incremental fold"; exit 1; }
        case " $offsets " in
          *" $k "*)
            if [ "$k" -lt "$size" ]; then
              grep -qx "$k $((size - k))" "$spanlog" || { echo "retained boundary $k did not fold only the new tail"; exit 1; }
            fi
            ;;
          *)
            grep -qx "0 $size" "$spanlog" || { echo "retained partial endpoint $k did not refold from byte 0"; exit 1; }
            ;;
        esac
        [ "$(status_open_decisions "$f")" = "$reference" ] || { echo "completed cursor at $k poisoned the whole-file fold"; exit 1; }
      done
      rm -f "$cf"
      [ "$(status_open_decisions "$f")" = "$reference" ] || { echo "fold without a checkpoint changed"; exit 1; }
    ' _ "$ROOT/bin/fm-classify-lib.sh" "$status" "$reader" "$spanlog" \
      "$(line_end_offsets "$status" | tr '\n' ' ')" "$(line_split_offsets "$status" | tr '\n' ' ')" 2>&1) \
      || fail "seeded fold diverged for kind $kind: $out"
  done
  pass "golden: retained cursors across two incremental calls match byte-0 folds at complete and split lines for every kind"
}

test_partial_appends_and_previous_version_are_refused_by_every_consumer() {
  local dir state kind reading out
  for kind in ship scout secondmate; do
    for reading in default resolve held reserved all; do
      dir=$(make_case "partial-$kind-$reading"); state="$dir/state"
      printf 'kind=%s\n' "$kind" > "$state/task.meta"
      out=$(bash -c '
        . "$1"
        state=$2 reading=$3
        case "$reading" in resolve|all) export FM_CLASSIFY_RESOLVE_VERB=answered ;; esac
        case "$reading" in held|all) export FM_CLASSIFY_CAPTAIN_HELD_VERB=awaiting-captain ;; esac
        case "$reading" in reserved|all) export FM_CLASSIFY_RESERVED_KEY_PREFIXES="pending-reply- secret-" ;; esac
        f="$state/task.status"; cf="$state/.task.open-decisions-cursor"
        ref="$state/reference.status"; copy="$state/copy.status"; ccf="$state/.copy.open-decisions-cursor"
        snapshot="$state/export.cursor"; probe="$state/probe"
        kind=$(_fm_status_kind "$f")
        resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
        held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
        file_size() { _fm_status_file_size "$f"; }
        reference() { cp "$f" "$ref" && status_open_decisions "$ref" "$kind"; }
        check_incremental() {
          expected=$(reference) || exit 1
          got=$(FM_OPEN_DECISIONS_READ_PROBE=$probe status_open_decisions_incremental "$f") || exit 1
          [ "$got" = "$expected" ] || { echo "$1 incremental differs from its byte-0 fold"; exit 1; }
          [ "$(status_open_decisions "$f")" = "$expected" ] || { echo "$1 checkpoint poisoned the whole-file fold"; exit 1; }
          grep -qx "offset=$(file_size)" "$cf" || { echo "$1 did not retain its observed endpoint"; exit 1; }
        }
        check_refusal() {
          cp "$cf" "$cf.saved"
          _fm_open_decisions_checkpoint_parse "$cf" || exit 1
          {
            printf "version=%s\noffset=%s\nident=%s\n" "$_FM_ODC_VERSION" "$_FM_ODC_OFFSET" "$_FM_ODC_IDENT"
            printf "poison\tneeds-decision\tuntrusted checkpoint"
          } > "$cf"
          before=$(cat "$cf")
          expected=$(reference) || exit 1
          [ "$(status_open_decisions "$f")" = "$expected" ] || { echo "$1 whole-file fold reused an invalid endpoint"; exit 1; }
          [ "$(cat "$cf")" = "$before" ] || { echo "$1 pure fold rewrote the checkpoint"; exit 1; }
          [ "$(status_presentation_cursor_offset "$f")" = 0 ] || { echo "$1 legacy presentation reused an invalid endpoint"; exit 1; }
          [ "$(FM_STATUS_CURSOR_SNAPSHOT_FILE=$snapshot status_open_decisions_cursor_offset "$f")" = 0 ] \
            || { echo "$1 legacy cursor exported an invalid endpoint"; exit 1; }
          _fm_open_decisions_checkpoint_parse "$snapshot" || exit 1
          [ "$_FM_ODC_OFFSET" = 0 ] && [ -z "$_FM_ODC_OPEN" ] || { echo "$1 exported the invalid open set"; exit 1; }
          cp "$f" "$copy"; rm -f "$ccf"
          status_open_decisions_checkpoint_carry "$f" "$copy" "$(_fm_open_decisions_file_ident "$f")"
          [ ! -e "$ccf" ] || { echo "$1 carried an invalid checkpoint"; exit 1; }
          [ "$(status_open_decisions "$copy" "$kind")" = "$expected" ] || { echo "$1 scratch copy did not fold from byte 0"; exit 1; }
          [ "$(cat "$cf")" = "$before" ] || { echo "$1 reader or carry mutated the live checkpoint"; exit 1; }
          mv "$cf.saved" "$cf"
        }
        printf "needs-deci" > "$f"
        check_incremental split-open
        check_incremental unchanged-partial-eof
        printf "sion [key=split]: choose the option\n" >> "$f"
        check_incremental completed-open
        first_size=$(file_size)
        printf "blocked [key=key-" >> "$f"
        check_incremental split-key
        printf "split]: waiting\n" >> "$f"
        check_incremental completed-key
        printf "needs-decision [key=note]: part" >> "$f"
        check_incremental split-note
        check_refusal partial-eof
        printf "ial note\n" >> "$f"
        check_refusal completed-file-with-partial-checkpoint
        check_incremental completed-note
        printf "%s" "${resolve:0:3}" >> "$f"
        check_incremental split-resolution
        printf "%s [key=split]: answered\n" "${resolve:3}" >> "$f"
        check_incremental completed-resolution
        printf "%s" "${held:0:3}" >> "$f"
        check_incremental split-held-transfer
        printf "%s [key=key-split]: tracked\n" "${held:3}" >> "$f"
        check_incremental completed-held-transfer
        printf "needs-decision [key=secret-vote]: ordinary question\ndo" >> "$f"
        check_incremental split-terminal
        printf "ne: report saved\n" >> "$f"
        check_incremental completed-terminal

        _fm_open_decisions_checkpoint_parse "$cf" || exit 1
        printf "version=9:%s\noffset=%s\nident=%s\npoison\tneeds-decision\told polluted state" \
          "${_FM_ODC_VERSION#*:}" "$_FM_ODC_OFFSET" "$_FM_ODC_IDENT" > "$cf"
        check_refusal previous-version-at-valid-boundary
        size=$(file_size)
        ident=$(_fm_open_decisions_file_ident "$f")
        printf "task\t%s\t%s\t%s\n" "$ident" "$size" "$size" > "$state/.status-presentation-cursor"
        manifest=$(cat "$state/.status-presentation-cursor")
        [ "$(status_presentation_cursor_offset "$f")" = "$size" ] || { echo "old fold version rewound the independent presentation manifest"; exit 1; }
        [ -z "$(status_new_lines_since_cursor "$f")" ] || { echo "old fold version replayed already-presented status"; exit 1; }
        : > "$probe"
        check_incremental previous-version-rebuild
        [ "$(tail -1 "$probe" | cut -f2)" = "$size" ] || { echo "old version was not rebuilt from byte 0"; exit 1; }
        [ "$(cat "$state/.status-presentation-cursor")" = "$manifest" ] || { echo "fold repair changed the presentation manifest"; exit 1; }
        _fm_open_decisions_checkpoint_parse "$cf" || exit 1
        [ "$_FM_ODC_VERSION" = "$(_fm_open_decisions_fold_signature "$kind")" ] || { echo "fold repair retained the old signature"; exit 1; }
        [ "$(status_open_decisions_cursor_offset "$f")" = "$size" ] || { echo "a valid rebuilt legacy endpoint was refused"; exit 1; }
        [ "$(FM_STATUS_CURSOR_SNAPSHOT_FILE=$snapshot status_open_decisions_cursor_offset "$f")" = "$size" ] || exit 1
        _fm_open_decisions_checkpoint_parse "$snapshot" || exit 1
        [ "$_FM_ODC_OPEN" = "$(reference)" ] || { echo "a valid migration snapshot lost the open set"; exit 1; }
        cp "$f" "$copy"; rm -f "$ccf"
        status_open_decisions_checkpoint_carry "$f" "$copy" "$ident"
        [ -f "$ccf" ] || { echo "a valid current-signature checkpoint was not carried"; exit 1; }
        _fm_open_decisions_checkpoint_parse "$ccf" || exit 1
        [ "$_FM_ODC_IDENT" = "$(_fm_open_decisions_file_ident "$copy")" ] || { echo "valid carry did not rebind identity"; exit 1; }
        [ "$(status_open_decisions "$copy" "$kind")" = "$(reference)" ] || { echo "valid carry changed the copied fold"; exit 1; }

        printf "needs-decision [key=current]: a fresh append\n" >> "$f"
        appended=$(($(file_size) - size))
        : > "$probe"
        check_incremental ordinary-append-after-rebuild
        [ "$(tail -1 "$probe" | cut -f2)" = "$appended" ] || { echo "a valid new-byte fold reread history"; exit 1; }
        _fm_status_read_span "$f" 0 "$first_size" > "$ref" || exit 1
        expected=$(status_open_decisions "$ref" "$kind")
        [ "$(status_open_decisions_incremental "$f" "$first_size")" = "$expected" ] \
          || { echo "a later valid checkpoint leaked past an earlier captured endpoint"; exit 1; }
        check_incremental restored-current-endpoint
      ' _ "$ROOT/bin/fm-classify-lib.sh" "$state" "$reading" 2>&1) \
        || fail "partial/checkpoint consumers for $kind/$reading: $out"
    done
  done
  pass "partial appends and valid-boundary old versions are refused across folds, legacy/export, and carry for every kind and override signature"
}

test_boundary_read_failure_never_advances_or_exports_a_checkpoint() {
  local dir state out
  dir=$(make_case checkpoint-boundary-read-failure); state="$dir/state"
  printf 'kind=secondmate\n' > "$state/task.meta"
  printf 'needs-decision [key=kept]: already trusted\n' > "$state/task.status"
  cat > "$dir/failing-reader" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$dir/failing-reader"
  out=$(bash -c '
    . "$1"
    f=$2 reader=$3
    cf=$(_fm_open_decisions_cursor_path "$f")
    copy="${f%.status}-copy.status"; ccf=$(_fm_open_decisions_cursor_path "$copy")
    snapshot="${f%.status}-export.cursor"
    trusted=$(status_open_decisions_incremental "$f")
    before=$(cat "$cf")
    printf "needs-decision [key=new]: not yet folded\n" >> "$f"
    printf "do not overwrite\n" > "$snapshot"
    got=$(FM_STATUS_SPAN_READER=$reader status_open_decisions_incremental "$f")
    [ "$got" = "$trusted" ] || { echo "boundary IO failure silently lost the retained open set"; exit 1; }
    [ "$(cat "$cf")" = "$before" ] || { echo "boundary IO failure advanced or rewrote the cursor"; exit 1; }
    if FM_STATUS_SPAN_READER=$reader FM_STATUS_CURSOR_SNAPSHOT_FILE=$snapshot status_open_decisions_cursor_offset "$f"; then
      echo "boundary IO failure was exported as a successful legacy offset"; exit 1
    fi
    [ "$(cat "$snapshot")" = "do not overwrite" ] || { echo "boundary IO failure overwrote the migration snapshot"; exit 1; }
    cp "$f" "$copy"
    FM_STATUS_SPAN_READER=$reader status_open_decisions_checkpoint_carry "$f" "$copy" "$(_fm_open_decisions_file_ident "$f")"
    [ ! -e "$ccf" ] || { echo "boundary IO failure carried uncertain state"; exit 1; }
    expected=$(status_open_decisions "$copy" secondmate)
    [ "$(FM_STATUS_SPAN_READER=$reader status_open_decisions "$f")" = "$expected" ] \
      || { echo "pure whole-file fold did not rebuild after boundary IO failure"; exit 1; }
    [ "$(status_open_decisions_incremental "$f")" = "$expected" ] || { echo "boundary IO recovery failed to consume the pending append"; exit 1; }
  ' _ "$ROOT/bin/fm-classify-lib.sh" "$state/task.status" "$dir/failing-reader" 2>&1) \
    || fail "checkpoint boundary read failure: $out"
  pass "boundary IO failure preserves live fold state, fails legacy export, refuses carry, and recovers on the next read"
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
test_utf8_whitespace_uses_full_fold_locale
test_terminal_supersession_reaches_cached_drains
test_kind_changes_invalidate_folded_decisions
test_seeded_whole_file_fold_matches_a_fold_from_line_one
test_partial_appends_and_previous_version_are_refused_by_every_consumer
test_boundary_read_failure_never_advances_or_exports_a_checkpoint
test_seeded_fold_refuses_checkpoints_from_another_reading
test_checkpoint_carries_onto_a_snapshot_copy_only_when_it_describes_it
test_truncated_log_falls_back_to_a_full_refold_not_a_dropped_decision
test_same_size_rewrite_is_detected_via_inode_identity
test_read_failure_preserves_state_for_retry
test_cursor_cache_read_failure_refolds_without_replaying_unread_status
test_pre_fix_cursor_refolds_corr_tagged_decision
test_previous_fold_cache_is_refolded_under_current_semantics
test_large_previous_fold_cache_migrates_within_startup_bound
test_buried_decision_survives_many_growing_drains_and_resolution_clears_it
