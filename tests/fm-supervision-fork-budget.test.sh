#!/usr/bin/env bash
# tests/fm-supervision-fork-budget.test.sh - helper-level supervision budgets.
# The counter measures subshell-depth transitions, not all process starts;
# its bounds are helper-level budgets. For exact fork and spawn counts and
# host process-creation rates before/after, see:
# data/fm-supervision-fork-budget/evidence/R1-evidence.md
#
# User-supplied measurements from that evidence report compare main fd9b8b02
# with branch 400ec4b5, counting every fork and posix_spawn (not this counter):
#   quiet watcher poll cycle: 2,157 -> 366 process starts (-83%);
#   scan_signals quiet pass: 1,375 -> 83 starts;
#   owner-watchdog tick: 38 -> 13 starts;
#   crew-state pass over 44 live tasks: 12,203 -> 8,216 starts, with all 44
#     outputs byte-identical;
#   fleet snapshot on a frozen home: 13,756 -> 12,774 starts (summary),
#     14,404 -> 13,421 (json), byte-identical after dropping time fields.
# Host rates used the same sampler (host-rate.sh 240 5), the same 240-second
# window, and 8 lab watchers on a frozen copy of the same 38 tasks, in 3 paired
# rounds. Idle host rates ranged from 2,197 to 2,529 process starts/second;
# watchers added +221/second on main versus +37/second on the branch on average
# (-83%). Live homes have no after sample until rollout.
#
# A loaded host pays for every process a bash loop starts, and the loops that
# run all day (the watcher's signal scan and its per-task checks, the crew
# current-state read, the owner watchdog tick) used to start one process or
# more per log line, per ledger row, or per task: a quiet watcher cycle over 35
# tasks started about 2,000, one crew-state read about 330, and one owner tick
# about 38. Each case here runs the loop over a fixture that grows with the
# fleet and counts the subshells it enters (every $( ) and pipeline stage; the
# count a wall clock cannot give on a busy CI host), so a per-row or per-task
# subshell shows up as a count that scales with the fixture and fails its bound.
#
# The fork-free helpers must also answer exactly as the pipelines they replace
# did, because the same functions gate teardown and liveness decisions. Each of
# those cases embeds the replaced pipeline as the reference and compares both on
# the same inputs under every available Bash and both a C and a UTF-8 locale.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-fork-budget)
fm_git_identity fmtest fmtest@example.invalid

# Every distinct Bash this host offers: the running one, stock /bin/bash, and
# whatever `bash` resolves to on PATH.
test_interpreters() {
  local seen='' candidate version
  for candidate in "${BASH:-bash}" /bin/bash "$(command -v bash 2>/dev/null || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    # shellcheck disable=SC2016 # Expanded by the candidate interpreter.
    version=$("$candidate" -c 'printf "%s" "$BASH_VERSION"' 2>/dev/null) || continue
    case " $seen " in *" $version "*) continue ;; esac
    seen="$seen $version"
    printf '%s\n' "$candidate"
  done
}

test_locales() {
  printf '%s\n' C
  if locale -a 2>/dev/null | grep -qx 'C.UTF-8'; then
    printf '%s\n' C.UTF-8
  elif locale -a 2>/dev/null | grep -qx 'en_US.UTF-8'; then
    printf '%s\n' en_US.UTF-8
  fi
}

# Run <script> under every interpreter and locale; any output is a mismatch
# report and fails the case.
run_everywhere() {  # <label> <script> [args...]
  local label=$1 script=$2 interpreter loc out
  shift 2
  while IFS= read -r interpreter; do
    while IFS= read -r loc; do
      out=$(LC_ALL=$loc "$interpreter" "$script" "$ROOT" "$@" 2>&1) \
        || fail "$label failed under $interpreter ($loc): $out"
      [ -z "$out" ] || fail "$label differs under $interpreter ($loc):"$'\n'"$out"
    done < <(test_locales)
  done < <(test_interpreters)
}

# The subshell counter. A measured script sources this after its setup: the
# DEBUG trap (inherited by functions and subshells) appends one byte to
# $FMB_LOG each time the shell is one subshell deeper than the command before,
# so the log length is the number of subshells that ran at least one command.
COUNTER="$TMP_ROOT/counter.sh"
cat > "$COUNTER" <<'SH'
set -T
_FMB_PREV=0
trap '_fmb_d=$BASH_SUBSHELL; [ "$_fmb_d" -le "$_FMB_PREV" ] || printf x >> "$FMB_LOG"; _FMB_PREV=$_fmb_d' DEBUG
SH

# Run <script> once and print how many subshells it entered while measured.
subshells_of() {  # <script> [args...]
  local script=$1 log="$TMP_ROOT/fmb.log" out
  shift
  : > "$log"
  out=$(FMB_LOG="$log" COUNTER="$COUNTER" "${BASH:-bash}" "$script" "$ROOT" "$@" 2>&1) \
    || fail "measured script failed: $out"
  [ -z "$out" ] || fail "measured script printed: $out"
  wc -c < "$log" | tr -d ' '
}

# --- the no-mistakes run ledger ----------------------------------------------

test_run_ledger_scan_starts_no_subshell_per_row() {
  local dir="$TMP_ROOT/ledger" script="$TMP_ROOT/ledger.sh" sha i count
  mkdir -p "$dir/wt"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m init
  sha=$(git -C "$dir/wt" rev-parse --short=8 HEAD)
  : > "$dir/list"
  i=0
  while [ "$i" -lt 200 ]; do
    i=$((i + 1))
    printf 'failed other/branch-%s 0123456 2026-09-30 11:00\n' "$i" >> "$dir/list"
  done
  printf 'completed fm/task %s 2026-10-01 12:00\n' "$sha" >> "$dir/list"
  cat > "$script" <<'SH'
root=$1 dir=$2
. "$root/bin/fm-nm-run-lib.sh"
list=$(cat "$dir/list")
. "$COUNTER"
fm_nm_runs_status_for_worktree "$dir/wt" fm/task "$list" > "$dir/result"
trap - DEBUG
SH
  count=$(subshells_of "$script" "$dir")
  [ "$(cat "$dir/result")" = completed ] \
    || fail "the ledger read must still attribute the branch's run: $(cat "$dir/result")"
  # One git read for the worktree head and a few for the matching row. A subshell
  # per ledger row would be 200 or more.
  [ "$count" -le 20 ] \
    || fail "reading a 201-row run ledger entered $count subshells; the bound is 20 (one per row is the old cost)"
  pass "a 201-row run ledger is read in $count subshells (bound 20)"
}

# --- the shared TOON readers answer as the pipelines they replaced -----------

test_toon_readers_match_the_pipelines_they_replace() {
  local script="$TMP_ROOT/toon.sh" cases="$TMP_ROOT/toon-cases"
  # Each case is one TOON document; the separator line is three at-signs.
  cat > "$cases" <<'EOF'
status: running
outcome:
branch: fm/task
@@@
  status:   "completed"
outcome: "merged"
@@@
repo: /x/y
branch_sync:
  state: pipeline_owned
  next_action:
    code: wait
runs[1]{id,branch,status}:
  r1, fm/task, awaiting_approval, 0
@@@
status: fixing
gate: test
@@@
awaiting_agent: yes
status: running
@@@
x: 1

   state: ignored
branch_sync:
	state: "pipeline_owned"
other:
  state: late
@@@
branch_sync:
branch_sync:
  state: second
@@@
status:
@@@

status: a:b
status: second
@@@
branch_sync:
  nested:
    state: deep
  state: shallow
top: 1
  state: after-end
@@@
EOF
  cat > "$script" <<'SH'
root=$1 cases=$2
. "$root/bin/fm-nm-run-lib.sh"
IFS=$'\t\n'

# The replaced pipelines, verbatim.
ref_field() { printf '%s\n' "$1" | sed -n "s/^[[:space:]]*$2:[[:space:]]*\(.*\)/\1/p" | head -1; }
ref_trim() {
  local s=${1:-}
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
ref_strip() {
  local s
  s=$(ref_trim "${1:-}")
  case "$s" in \"*\") s=${s#\"}; s=${s%\"} ;; esac
  ref_trim "$s"
}
ref_sync_state() {
  local s
  s=$(printf '%s\n' "$1" \
    | sed -n '/^[[:space:]]*branch_sync:[[:space:]]*$/,/^[^[:space:]][^:]*:/s/^[[:space:]]\{1,\}state:[[:space:]]*\(.*\)/\1/p' \
    | head -1)
  ref_strip "$s"
}
ref_parked() {
  printf '%s\n' "$1" | grep -Eq \
    "$FM_NM_GATE_LINE_RE|$FM_NM_AWAITING_AGENT_RE|$FM_NM_GATE_SCALAR_RE|$FM_NM_GATE_ROW_RE"
}
ref_active() {
  local status outcome
  status=$(ref_strip "$(ref_field "$1" status)")
  outcome=$(ref_strip "$(ref_field "$1" outcome)")
  [ -z "$outcome" ] || return 1
  case "$status" in completed|failed|cancelled) return 1 ;; esac
}
ref_executing() {
  ref_active "$1" || return 1
  ref_parked "$1" && return 1
  case "$(ref_strip "$(ref_field "$1" status)")" in
    pending|running|fixing|ci) return 0 ;;
  esac
  return 1
}

check() {  # <label> <want> <got>
  [ "$2" = "$3" ] || printf '%s: reference %q, helper %q\n' "$1" "$2" "$3"
}
rc() { "$@" >/dev/null 2>&1; printf '%s' "$?"; }

doc=
n=0
flush() {
  [ -n "$doc" ] || return 0
  doc=${doc%$'\n'}
  n=$((n + 1))
  local key
  for key in status outcome state id branch head nope; do
    check "case $n field $key" "$(ref_field "$doc" "$key")" "$(fm_nm_field "$doc" "$key")"
    check "case $n field printed form $key" "$(ref_field "$doc" "$key" | od -c)" "$(fm_nm_field "$doc" "$key" | od -c)"
  done
  check "case $n sync state" "$(ref_sync_state "$doc")" "$(fm_nm_branch_sync_state "$doc")"
  check "case $n parked" "$(rc ref_parked "$doc")" "$(rc fm_nm_run_is_parked "$doc")"
  check "case $n active" "$(rc ref_active "$doc")" "$(rc fm_nm_run_is_active "$doc")"
  check "case $n executing" "$(rc ref_executing "$doc")" "$(rc fm_nm_run_is_executing "$doc")"
  doc=
}
while IFS= read -r line; do
  if [ "$line" = '@@@' ]; then flush; else doc="$doc$line"$'\n'; fi
done < "$cases"
flush

for s in '' ' ' '  a  ' '"q"' ' "q" ' '""' '"' 'a"b' $'a\tb' ' "  spaced  " '; do
  check "trim [$s]" "$(ref_trim "$s")" "$(fm_nm_trim "$s")"
  check "strip [$s]" "$(ref_strip "$s")" "$(fm_nm_strip_quotes "$s")"
done
SH
  run_everywhere "TOON readers" "$script" "$cases"
  pass "the TOON field, sync-state and parked readers match the sed, grep and trim pipelines they replaced"
}

# --- the reported-state signature --------------------------------------------

test_status_signature_matches_the_od_pipeline() {
  local dir="$TMP_ROOT/sig" script="$TMP_ROOT/sig.sh"
  mkdir -p "$dir/dir"
  printf 'working [at=1]: hi\n' > "$dir/a.status"
  : > "$dir/empty.status"
  printf 'x' > "$dir/sp ace.status"
  ln -s "$dir/a.status" "$dir/link.status"
  ln -s "$dir/nowhere" "$dir/dangling.status"
  ln -s "$dir/caf"$'\303\251' "$dir/utf-link.status"
  ln -s "$dir/a"$'\t'"b" "$dir/ctl-link.status"
  cat > "$script" <<'SH'
root=$1 dir=$2
. "$root/bin/fm-wake-lib.sh"
. "$root/bin/fm-classify-lib.sh"
_fm_wake_require_status
# A runner can carry any IFS; the helpers must not depend on the default one.
IFS=$'\t\n'

# The replaced signature, verbatim: separate stats and an od pipeline.
ref_signature() {
  local f=$1 size=${2-} ident=${3-} path_state link_target=- access kind encoded
  path_state=$(_status_observed_path_state "$f") || path_state=stat-error
  if [ -L "$f" ]; then
    link_target=$(readlink "$f" 2>/dev/null) || link_target=readlink-error
    kind=symlink
  elif [ ! -e "$f" ]; then
    kind=absent
  elif [ ! -f "$f" ]; then
    kind=nonregular
  elif [ -r "$f" ]; then
    kind=readable
  else
    kind=unreadable
  fi
  if [ -z "$size" ]; then
    size=$(_fm_status_file_size "$f") || size='size-error'
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) size='size-error' ;; esac
  fi
  if [ -z "$ident" ]; then
    ident=$(_fm_open_decisions_file_ident "$f") || ident=identity-error
    [ -n "$ident" ] || ident=identity-error
  fi
  if [ -r "$f" ]; then access=readable; else access=unreadable; fi
  encoded=$(printf '%s\0%s\0%s\0%s\0%s\0%s' \
    "$size" "$ident" "$path_state" "$link_target" "$access" "$kind" \
    | LC_ALL=C od -An -v -tx1 | tr -d ' \n') || return 1
  printf 'r1:%s' "$encoded"
}

for f in "$dir/a.status" "$dir/empty.status" "$dir/sp ace.status" "$dir/missing.status" "$dir/dir" \
  "$dir/link.status" "$dir/dangling.status" "$dir/utf-link.status" "$dir/ctl-link.status"; do
  want=$(ref_signature "$f"; echo " rc=$?")
  got=$(status_observed_signature "$f"; echo " rc=$?")
  [ "$want" = "$got" ] || printf 'signature of %s: reference %q, helper %q\n' "$f" "$want" "$got"
  want=$(ref_signature "$f" 12 weak:1:2; echo " rc=$?")
  got=$(status_observed_signature "$f" 12 weak:1:2; echo " rc=$?")
  [ "$want" = "$got" ] || printf 'signature of %s with size and identity: reference %q, helper %q\n' "$f" "$want" "$got"
done
SH
  run_everywhere "status signature" "$script" "$dir"
  pass "the reported-state signature is byte-identical to the od pipeline for every file kind"
}

# --- the watcher's per-cycle scans -------------------------------------------

test_quiet_signal_scan_costs_one_stat_per_log() {
  local dir="$TMP_ROOT/scan" script="$TMP_ROOT/scan.sh" i count
  mkdir -p "$dir/state" "$dir/home"
  i=0
  while [ "$i" -lt 12 ]; do
    i=$((i + 1))
    printf 'working [at=%s]: step\n' "$i" > "$dir/state/task-$i.status"
  done
  cat > "$script" <<'SH'
root=$1 dir=$2
export FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home"
# The watcher's source guard returns before its lock and loop: only functions load.
. "$root/bin/fm-watch.sh"
STATE="$dir/state"
for f in "$STATE"/*.status; do fm_wake_status_mark_current "$STATE" "$f" || echo "mark failed: $f"; done
out=$(scan_signals)
[ -z "$out" ] || echo "the scan was not quiet: $out"
. "$COUNTER"
scan_signals > /dev/null
trap - DEBUG
SH
  count=$(subshells_of "$script" "$dir")
  # One stat per log reads everything the signature needs; the old scan entered
  # about 19 subshells per log (233 for these 12). 12 logs plus a few constant reads.
  [ "$count" -le 40 ] \
    || fail "a quiet scan of 12 status logs entered $count subshells; the bound is 40 (the old cost was 233)"
  pass "a quiet scan of 12 status logs enters $count subshells (bound 40)"
}

test_recorded_windows_reads_each_task_without_a_subshell() {
  local dir="$TMP_ROOT/windows" script="$TMP_ROOT/windows.sh" i count
  mkdir -p "$dir/state" "$dir/home"
  i=0
  while [ "$i" -lt 20 ]; do
    i=$((i + 1))
    fm_write_meta "$dir/state/task-$i.meta" "window=firstmate:fm-task-$i" "kind=ship"
  done
  cat > "$script" <<'SH'
root=$1 dir=$2
export FM_STATE_OVERRIDE="$dir/state" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$dir/home"
. "$root/bin/fm-watch.sh"
STATE="$dir/state"
. "$COUNTER"
recorded_windows > "$dir/windows.out"
trap - DEBUG
SH
  count=$(subshells_of "$script" "$dir")
  [ "$(wc -l < "$dir/windows.out" | tr -d ' ')" -eq 20 ] \
    || fail "recorded_windows must still list every task's window: $(cat "$dir/windows.out")"
  [ "$count" -le 4 ] \
    || fail "listing 20 task windows entered $count subshells; the bound is 4 (the old cost was 80)"
  pass "listing 20 task windows enters $count subshells (bound 4)"
}

# --- the process-event owner watchdog ----------------------------------------

test_owner_watchdog_tick_subshell_budget() {
  local dir="$TMP_ROOT/tick" script="$TMP_ROOT/tick.sh" count
  mkdir -p "$dir/state/procevent"
  chmod 700 "$dir/state"
  cat > "$script" <<'SH'
root=$1 dir=$2
STATE="$dir/state"
. "$root/bin/fm-wake-lib.sh"
. "$root/bin/fm-pr-lib.sh"
. "$root/bin/fm-procevent-lib.sh"
pid=$$
identity=$(fm_pid_identity "$pid") || { echo "no identity"; exit 0; }
fm_procevent_owner_lease_touch "$STATE" || { echo "no lease"; exit 0; }
state_identity=$(fm_procevent_claim_state_root_identity "$STATE") || { echo "no state identity"; exit 0; }
IFS=$'\t' read -r _ state_device state_inode _ _ <<< "$state_identity"
. "$COUNTER"
# The owner watchdog's per-tick checks, as bin/fm-procevent.sh cmd_owner_watchdog runs them.
for _ in 1 2 3 4 5; do
  fm_procevent_pid_state "$pid" "$identity" || echo "runner not live"
  state_identity=$(fm_procevent_claim_state_root_identity "$STATE" 2>/dev/null || true)
  IFS=$'\t' read -r _ current_device current_inode _ _ <<< "$state_identity"
  [ "$current_device" = "$state_device" ] && [ "$current_inode" = "$state_inode" ] || echo "state root identity moved"
  fm_procevent_owner_alive "$STATE" 600 || echo "lease not fresh"
done
trap - DEBUG
SH
  count=$(subshells_of "$script" "$dir")
  # The old tick entered about 23 subshells (38 processes), 115 for five. The
  # identity read, the state-root stat and the lease age are the only readers
  # left; the bound leaves room for the /proc form of the identity read on Linux.
  [ "$count" -le 80 ] \
    || fail "five owner-watchdog ticks entered $count subshells; the bound is 80 (the old cost was 115)"
  pass "five owner-watchdog ticks enter $count subshells (bound 80)"
}

# A detached runner is started with its own IFS. The state-root checks split one
# stat line into fields, and a split that trusted the default IFS read a
# one-field line, saw no owner, and refused every claim.
test_state_root_checks_do_not_depend_on_ifs() {
  local dir="$TMP_ROOT/ifs" script="$TMP_ROOT/ifs.sh"
  mkdir -p "$dir/state"
  chmod 700 "$dir/state"
  cat > "$script" <<'SH'
root=$1 dir=$2
. "$root/bin/fm-wake-lib.sh"
. "$root/bin/fm-pr-lib.sh"
. "$root/bin/fm-procevent-lib.sh"
IFS=$'\t\n'
fm_procevent_state_root_resolve "$dir/state" > /dev/null || echo "resolve refused the state root under a tab-and-newline IFS"
identity=$(fm_procevent_claim_state_root_identity "$dir/state") || echo "identity refused the state root under a tab-and-newline IFS"
case "$identity" in *"$dir/state"*) ;; *) echo "identity did not name the state root: $identity" ;; esac
SH
  run_everywhere "state root checks" "$script" "$dir"
  pass "the state-root checks work under a tab-and-newline IFS"
}

# --- process identity ---------------------------------------------------------

test_pid_identity_trim_matches_sed_for_multiline_commands() {
  local dir="$TMP_ROOT/ident" script="$TMP_ROOT/ident.sh" shim="$TMP_ROOT/ident-shim"
  mkdir -p "$dir" "$shim"
  # A ps whose command column holds newlines and leading blanks.
  cat > "$shim/ps" <<'SH'
#!/bin/sh
printf '  Thu Oct  8 12:00:00 2026 bash -c first\n   second line\n\n    third\n'
SH
  chmod +x "$shim/ps"
  cat > "$script" <<'SH'
root=$1 shim=$2
PATH="$shim:$PATH"
FM_PROC_ROOT_OVERRIDE="$shim/no-proc"
. "$root/bin/fm-wake-lib.sh"
got=$(fm_pid_identity "$$"; echo "|rc=$?")
want=$(printf '%s\n' "$(printf '  Thu Oct  8 12:00:00 2026 bash -c first\n   second line\n\n    third\n')" | sed 's/^[[:space:]]*//'; echo "|rc=0")
[ "$got" = "$want" ] || printf 'identity: reference %q, helper %q\n' "$want" "$got"
SH
  run_everywhere "pid identity" "$script" "$shim"
  pass "a multi-line ps command column is trimmed line by line, exactly as sed did"
}

if [ -n "${FM_TEST_ONLY:-}" ]; then
  "$FM_TEST_ONLY"
else
  test_run_ledger_scan_starts_no_subshell_per_row
  test_toon_readers_match_the_pipelines_they_replace
  test_status_signature_matches_the_od_pipeline
  test_quiet_signal_scan_costs_one_stat_per_log
  test_recorded_windows_reads_each_task_without_a_subshell
  test_owner_watchdog_tick_subshell_budget
  test_state_root_checks_do_not_depend_on_ifs
  test_pid_identity_trim_matches_sed_for_multiline_commands
fi
