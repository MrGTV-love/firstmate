#!/usr/bin/env bash
# Shared wake classifier composing the status APIs below with working/paused
# absorb classification, which makes no-verb signal and stale-pane wakes safe
# to absorb.
# Sourced by BOTH the always-on watcher
# (bin/fm-watch.sh) and the away-mode daemon (bin/fm-supervise-daemon.sh) so the
# overlapping triage policy lives in one place instead of two copies that can
# drift apart.
#
# Status contracts have separate owners: fm-status-record-lib.sh owns emission
# metadata and retry identity; fm-status-decision-lib.sh owns keyed folds and
# line parsing; fm-status-event-lib.sh owns event vocabulary and declared waits;
# fm-status-io-lib.sh owns file reads, identity, and marker parsing;
# fm-status-wake-lib.sh owns span classification, reported-state markers, and append ledgers;
# fm-utc-lib.sh owns portable UTC parsing. This classifier composes those APIs
# with crew-state reconciliation and absorb policy.
#
# Most functions are pure, side-effect-free reads of status files: each takes
# what it needs as arguments and touches no globals beyond the optional
# FM_CAPTAIN_RE override. Consumers layer their own dedup/marker state on top (the
# daemon keeps its escalation-digest seen-markers; the watcher keeps its .seen-*
# signatures).
#
# There are four documented exceptions. The absorb classification
# (crew_absorb_class and its working/paused wrappers) is NOT a pure status-file
# read: it reuses bin/fm-crew-state.sh, which may make a bounded no-mistakes call,
# to decide whether a crew that just stopped its turn or went stale is working,
# deliberately paused, or neither. Callers run it ONLY on no-verb signal handling
# and first sighting of a stale hash, never on every wake, so the per-wake triage
# stays cheap. status_open_decisions_incremental (see "incremental (cursor-backed)
# open-decisions fold" below) also writes: it persists a per-status-file byte
# cursor and folded open-set as a side effect, so a per-drain fleet-wide scan
# stays bounded by new appends instead of re-reading each task's whole lifetime
# log every time. status_home_appends_record writes the per-task home-owned
# append ledger documented in fm-status-wake-lib.sh so the wake scan can treat
# this home's own bookkeeping bytes as already owned.
# crew_worktree_written_since reads the task's meta file and walks a bounded slice
# of its worktree instead of a status file, so callers run it only at the moment
# they would otherwise escalate.

# shellcheck source=bin/fm-status-io-lib.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-status-io-lib.sh"
# The crew current-state reader used for the "provably working" decision.
# Overridable so tests can stub the run-step/pane verdict without a real worktree
# or no-mistakes install; absent, it points at the real sibling script.
FM_CREW_STATE_BIN="${FM_CREW_STATE_BIN:-$_FM_CLASSIFY_LIB_DIR/fm-crew-state.sh}"
# shellcheck source=bin/fm-status-decision-lib.sh
. "$_FM_CLASSIFY_LIB_DIR/fm-status-decision-lib.sh"
# shellcheck source=bin/fm-status-wake-lib.sh
. "$_FM_CLASSIFY_LIB_DIR/fm-status-wake-lib.sh"
# shellcheck source=bin/fm-utc-lib.sh
. "$_FM_CLASSIFY_LIB_DIR/fm-utc-lib.sh"

# Bounded re-surface cadence for a declared external-wait pause.
# Far longer than the wedge threshold (FM_STALE_ESCALATE_SECS, default 240s), it
# avoids nagging a deliberate wait while ensuring a forgotten wait cannot rot
# invisibly - it re-surfaces once for a recheck every window. Four hours by
# default: a declared wait is by definition expected to clear on its own, so a
# recheck is a backstop, not progress, and an hourly one only produced nagging
# (the 2026-09-07 away-window audit). A worker that knows when its wait clears
# names it with `until` (status_paused_until below) and is rechecked at that
# time or this cadence bound, whichever comes first. Both consumers read
# FM_PAUSE_RESURFACE_SECS with this default so
# the cadence has one owner. An item held for the captain is not rechecked at all
# while the away-posture record exists (bin/fm-watch.sh owns that rule).
# shellcheck disable=SC2034 # Read by the watcher and daemon (fm-watch.sh, fm-supervise-daemon.sh), not this lib.
FM_PAUSE_RESURFACE_SECS_DEFAULT=14400

# A condition-aware declared wait: a `paused:` line may say WHEN it expects to
# clear with `until <YYYY-MM-DDTHH:MM[:SS]Z>` anywhere in its text (UTC only, so
# no local-zone guess is ever recorded). Prints that time as epoch seconds so a
# supervisor rechecks the wait when the worker said it would clear instead of on
# the flat cadence; returns 1 when the line is not a pause or declares no time,
# or the time is malformed, so a bad token falls back to the cadence rather than
# silencing the wait.
status_paused_until() {  # <status-line> -> epoch on stdout
  local line=$1 token
  status_is_paused "$line" || return 1
  token=$(printf '%s' "$line" \
    | sed -n 's/.*[[:space:]][Uu][Nn][Tt][Ii][Ll][[:space:]]\{1,\}\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z\).*/\1/p; s/.*[[:space:]][Uu][Nn][Tt][Ii][Ll][[:space:]]\{1,\}\([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\).*/\1/p' \
    | head -1)
  [ -n "$token" ] || return 1
  fm_utc_iso_to_epoch "$token"
}

# Resolve the log's current declaration at one boundary for crew-state consumers.
# Any decision the fold still holds open wins over unrelated events, and the
# fold's most recently opened record supplies it; a standing declared wait, then
# the latest recognized event, stands when nothing is open.
# Actual run/pane evidence is still reconciled by fm-crew-state.sh.
status_current_line() {  # <status-file> <kind>
  local open key verb note current=''
  open=$(status_open_decisions "$1" "$2")
  while IFS=$'\t' read -r key verb note; do
    case "$verb" in ?*) current="$verb [key=$key]: $note" ;; esac
  done <<EOF
$open
EOF
  [ -n "$current" ] || current=$(status_declared_wait_line "$1")
  [ -n "$current" ] || current=$(last_status_line "$1")
  printf '%s\n' "$current"
}

# The subset of status_open_decisions the task raised about its own work: a
# reserved-namespace key is raised by a supervisor library about the task (a
# pending-reply escalation), a `remote-reply-continuity-` key is the parent's
# own blocker about a broken remote reply mirror
# (bin/fm-procevent-remote-reply.sh), and a `captain-hold-` key relays a child
# decision a secondmate escalated to the captain (bin/fm-captain-hold.sh) while
# it keeps working, so the task is not waiting on any of them. Pending-reply
# recovery and a fire-and-forget retry ring consult this set and leave a task
# alone while it is non-empty.
status_own_open_decisions() {  # <status-file>
  local line prefix
  status_open_decisions "$1" | while IFS= read -r line || [ -n "$line" ]; do
    for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT} remote-reply-continuity- captain-hold-; do
      case "$line" in "$prefix"*) continue 2 ;; esac
    done
    printf '%s\n' "$line"
  done
}

# 0 when the fold above still holds at least one decision OPENED by
# `needs-decision` - the status side's own record that a human was asked
# something and has not answered. A `blocked` record is deliberately not this: a
# blocker is an obstacle the crew reported, not an unanswered question, and a
# different action clears it. Whole-file and cursor-free on purpose: this answers
# a point-in-time question for a caller that holds no cursor and must not write
# one, so it reads status_open_decisions rather than the incremental fold.
# An unreadable, missing or symlinked status file folds to nothing and answers 1,
# which is the safe answer for every caller: no evidence, no exception.
# Given a <run-id>, only a decision whose key is exactly `nm-<run-id>-<step>` for
# a non-empty step counts - the key shape the brief mandates for a gate
# escalation - so an unrelated question left open earlier in the same task is
# never read as firstmate being told about THIS run's gate.
status_has_open_needs_decision() {  # <status-file> [<run-id>]
  local run=${2-} open line key verb
  open=$(status_open_decisions "$1")
  [ -n "$open" ] || return 1
  if [ $# -ge 2 ] && [ -z "$run" ]; then return 1; fi
  while IFS= read -r line; do
    key=${line%%$'\t'*}
    verb=${line#*$'\t'}; verb=${verb%%$'\t'*}
    [ "$verb" = needs-decision ] || continue
    [ $# -ge 2 ] || return 0
    case "$key" in "nm-$run-"?*) return 0 ;; esac
  done <<EOF
$open
EOF
  return 1
}

# The verb that last moved <key> in a status stream, which is what tells a
# consumer HOW the status side currently reads that key. Prints the opening verb
# (needs-decision or blocked) while the key is still open, the closing verb
# (resolved, or the captain-held durable-transfer verb) once it is closed, and
# nothing at all when no line in the stream ever stated a transition for it.
#
# The distinction between the two closing verbs is the whole point: a
# `captain-held` close is the VERIFIED handoff to a durable captain-held task
# (fm-captain-hold.sh complete writes it only after verifying that task), so the
# structured row staying open afterwards is correct. A `resolved` close claims
# the question is settled outright, so a structured row still open behind it is a
# contradiction between the two records - see fm-captain-hold.sh's `diverged`.
#
# Semantics are not re-derived here: every candidate line goes through the same
# _fm_decision_fold_line rule the two folds use, and the reported verb is read
# off the transitions that rule produces.
#
# One `grep` pre-selects those candidates so the bash fold below costs the log's
# TRANSITIONS rather than its whole lifetime length - status files are only ever
# appended to, and this runs per open task on every supervision presentation.
# The pre-select deliberately over-includes: it takes any line whose leading word
# could be a fold verb (including the ship/scout terminals, which carry no key
# token), and the fold alone decides which of them really moves the set. A line
# whose leading word is followed by neither whitespace, a colon, nor a bracket
# tag cannot be a transition, because the fold's own declaration guard rejects it.
status_key_closing_verb() {  # <status-file> <key>
  local f=$1 want=$2 line resolve held open='' was verb='' kind event candidates
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  [ -n "$want" ] || return 0
  kind=$(_fm_status_kind "$f")
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  candidates=$(grep -E \
    "^[[:space:]]*(needs-decision|blocked|done|failed|$resolve|$held)[[:space:]:[]" \
    "$f") || [ "$?" -eq 1 ] || candidates=$(cat "$f")
  while IFS= read -r line || [ -n "$line" ]; do
    status_line_verb "$line" event
    case "$event:$kind" in
      done:ship|done:scout|failed:ship|failed:scout) ;;
      *)
        case "$event" in
          needs-decision|blocked|"$resolve"|"$held") ;;
          *) continue ;;
        esac
        if [ "$want" != default ]; then
          case "$line" in *"[key=$want]"*) ;; *) continue ;; esac
        fi
        ;;
    esac
    was=0
    _fm_open_set_has "$open" "$want" && was=1
    open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind")
    if [ "$was" = 1 ] && ! _fm_open_set_has "$open" "$want"; then
      verb=$event
    fi
  done <<EOF
$candidates
EOF
  if _fm_open_set_has "$open" "$want"; then
    _fm_open_set_verb "$open" "$want"
    return 0
  fi
  printf '%s' "$verb"
}

# The status file inside <state> that is this home's outbound parent channel
# rather than a self-home task status log, printed; empty when there is none.
# Only a remote mate home resolves one - its state/parent-replies.status is the
# parent channel (bin/fm-parent-channel-lib.sh owns that resolution, sourced
# lazily here because that library sources this one at its top level, so a
# top-level source would be circular). A main home, a local mate - whose
# channel lives in the parent home - or an unusable identity or binding keeps
# every file, so ordinary task logs fold and wake exactly as before. The home
# is the directory containing <state>, the <home>/state layout every caller of
# these fleet-wide scans shares; a state dir outside such a home excludes
# nothing. Callers compare the resolved path, never the file name, so a
# parent-replies.status in any other home shape stays an ordinary task log.
status_scan_parent_channel_exclude() {  # <state>
  local state=$1 exclude
  if ! command -v fm_parent_channel_outbound_status >/dev/null 2>&1; then
    # shellcheck source=bin/fm-parent-channel-lib.sh
    . "$_FM_CLASSIFY_LIB_DIR/fm-parent-channel-lib.sh"
  fi
  exclude=$(fm_parent_channel_outbound_status "$(dirname "$state")" "$state") || return 0
  printf '%s\n' "$exclude"
}

# Fleet-wide wrapper around status_open_decisions: scans every task's status
# log under <state> and prefixes each still-open decision with its owning task
# id, so a per-wake or per-session surface can print the consolidated open set
# without re-walking the fold itself. A thin directory scan only - the fold
# above remains the ONE place the open/resolved semantics are decided. Prints
# one "<task>\t<key>\t<verb>\t<note>" line per open decision, in glob (task id)
# order; prints nothing when none are open.
scan_open_decisions() {  # <state>
  local state=$1 f task open line exclude
  exclude=$(status_scan_parent_channel_exclude "$state")
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions "$f") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

# --- incremental (cursor-backed) open-decisions fold ------------------------
#
# status_open_decisions above re-reads and re-folds a status file's ENTIRE
# lifetime on every call, so its cost grows with total log size. A per-drain
# fleet-wide scan using that whole-file function would pay that cost for every
# task on every wake, which grows unbounded as tasks run longer and accumulate
# status history. status_open_decisions_incremental and scan_open_decisions_incremental
# below are the bounded-cost siblings used for that per-drain path: each call
# reads only the bytes appended to a status file since its own last call (a
# persisted per-file byte cursor) and folds just those new lines into a
# persisted running open-set, via the exact same _fm_decision_fold_line rule
# status_open_decisions uses - so the two strategies can never disagree on what
# is open. Cost is bounded by NEW appends since the last drain, not by the
# status file's total lifetime size.
#
# Correctness invariant (unchanged from the whole-file fold): cursor advancement,
# age, and being buried under later appends never drop an open decision - the
# persisted open-set carries every still-open key forward across calls regardless
# of how much new unrelated log content has since been folded in. Only a line the
# shared fold rule retires removes one.
#
# The cursor format is `version` (FM_OPEN_DECISIONS_FOLD_VERSION plus the task
# kind, as `<n>:<kind>`), `offset`, `ident`, then the folded open set.
# FM_OPEN_DECISIONS_FOLD_VERSION must be bumped whenever
# _fm_decision_fold_line semantics change, so persisted state from an older
# interpretation is discarded and rebuilt from byte 0; the kind suffix does the
# same when a task kind changes, because kind changes the fold below.
#
# Cursor invalidation is deliberately minimal, matching how status files are
# ACTUALLY used in this repo: every one is created once (`>`) and only ever
# appended to (`>>`) - never replaced, renamed, or rewritten in place. So the
# ways a cursor can go stale are a fold-version mismatch, a shrink (truncated),
# or the file at this path being a different file than before
# (replaced/rotated/recreated), which a changed device+inode makes an O(1) check
# via a single `stat` call - no content hashing, no re-reading the consumed
# prefix. Any signal falls back to a full re-fold of the whole current file from
# byte 0 - byte for byte what status_open_decisions itself would compute - and
# rewrites the cursor from that clean baseline. A same-inode, same-size,
# in-place byte edit is NOT detected; that is a deliberately accepted gap
# because no code path in this repo ever does that to a status file.
#
# The other real failure mode is OUR OWN read failing (a stat/wc/tail I/O
# error), not a malformed writer: every such read here is checked, and on
# failure this reports the already-trusted persisted set unchanged rather than
# risking a silent invalidation that would wipe it - never a bare "empty" as if
# nothing were open.
#
# Not a pure status-file read: this writes/rewrites the sibling cursor file as a
# side effect (state/.<task>.open-decisions-cursor), the library's second
# documented exception to the pure-read rule after crew_absorb_class. The write
# is atomic (temp file + rename), so a crash between calls leaves either the
# prior cursor or the new one, never a partial one. bin/fm-wake-drain.sh calls
# this only after releasing the wake-queue lock, so a hypothetical race between
# two overlapping drains can at worst redo a little folding work twice - never
# drop an open decision - because a losing writer's offset can only ever be
# equal to or behind an already-recorded byte position, and the next call
# re-derives from whatever offset actually landed on disk.

status_open_decisions_incremental() {  # <status-file> [<captured-end-offset>]
  local f=$1 captured_end=${2:-} cf offset ident open='' trusted_open='' cursor_data first rest offset_line ident_line
  local version='' size actual_size cur_ident resolve held chunk_file chunk_size line cursor_dirty=0
  local target_cursor kind fold_version
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  kind=$(_fm_status_kind "$f")
  fold_version="$FM_OPEN_DECISIONS_FOLD_VERSION:$kind"
  cf=$(_fm_open_decisions_cursor_path "$f")
  offset=0
  ident=''
  if [ -f "$cf" ] && [ -r "$cf" ] && [ ! -L "$cf" ]; then
    cursor_data=$(LC_ALL=C command cat "$cf" 2>/dev/null) || cursor_data=''
  fi
  if [ -n "${cursor_data:-}" ]; then
      first=${cursor_data%%$'\n'*}
      case "$first" in
        version=*)
          version=${first#version=}
          [ "$version" = "$fold_version" ] || version=''
          rest=${cursor_data#*$'\n'}
          offset_line=${rest%%$'\n'*}
          case "$offset_line" in
            offset=*) offset=${offset_line#offset=} ;;
            *) offset=0; version='' ;;
          esac
          case "$offset" in
            ''|*[!0-9]*) offset=0; version='' ;;
            *)
              case "$rest" in
                *$'\n'*)
                  rest=${rest#*$'\n'}
                  ident_line=${rest%%$'\n'*}
                  case "$ident_line" in
                    ident=*)
                      ident=${ident_line#ident=}
                      case "$rest" in
                        *$'\n'*) open=${rest#*$'\n'} ;;
                      esac
                      if [ -n "$version" ] && [ -n "$ident" ]; then trusted_open=$open; fi
                      ;;
                    *) offset=0; version='' ;;
                  esac
                  ;;
                *) offset=0; version='' ;;
              esac
              ;;
          esac
          ;;
      esac
  fi

  # A stat/size-read failure is a genuine I/O error, not "the file is empty" -
  # report the already-trusted persisted set unchanged rather than risking a
  # silent invalidation that would wipe it.
  cur_ident=$(_fm_open_decisions_file_ident "$f") || { printf '%s' "$trusted_open"; return 0; }
  [ -n "$cur_ident" ] || { printf '%s' "$trusted_open"; return 0; }
  actual_size=$(_fm_status_file_size "$f") \
    || { printf '%s' "$trusted_open"; return 0; }
  actual_size=${actual_size//[[:space:]]/}
  case "$actual_size" in ''|*[!0-9]*) printf '%s' "$trusted_open"; return 0 ;; esac
  if [ -n "$captured_end" ]; then
    case "$captured_end" in
      ''|*[!0-9]*) printf '%s' "$trusted_open"; return 0 ;;
    esac
    [ "$captured_end" -le "$actual_size" ] || { printf '%s' "$trusted_open"; return 0; }
    size=$captured_end
  else
    size=$actual_size
  fi

  if [ -z "$version" ] || [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$actual_size" ]; then
    offset=0
    open=''
    trusted_open=''
    cursor_dirty=1
  fi

  if [ "$offset" -lt "$size" ]; then
    chunk_file="$cf.read.$$"
    _fm_status_read_span "$f" "$offset" "$((size - offset))" > "$chunk_file" 2>/dev/null \
      || { rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0; }
    chunk_size=$(LC_ALL=C wc -c < "$chunk_file" 2>/dev/null) \
      || { rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0; }
    chunk_size=${chunk_size//[[:space:]]/}
    case "$chunk_size" in
      ''|*[!0-9]*) rm -f "$chunk_file"; printf '%s' "$trusted_open"; return 0 ;;
    esac
    # Test-only observability seam (off by default, no production behavior
    # change): when set, records exactly how many bytes THIS call folded, so a
    # test can assert the incremental path stays bounded by new appends rather
    # than re-reading the whole file, without relying on timing or source text.
    [ -n "${FM_OPEN_DECISIONS_READ_PROBE:-}" ] \
      && printf '%s\t%s\n' "$f" "$chunk_size" >> "$FM_OPEN_DECISIONS_READ_PROBE"
    resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
    held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
    while IFS= read -r line || [ -n "$line" ]; do
      open=$(_fm_decision_fold_line "$open" "$line" "$resolve" "$held" "$kind")
    done < "$chunk_file"
    rm -f "$chunk_file"
    offset=$size
    cursor_dirty=1
  fi
  if [ "$cursor_dirty" -eq 1 ]; then
    target_cursor="$cf.tmp.$$"
    {
      printf 'version=%s\n' "$fold_version"
      printf 'offset=%s\n' "$offset"
      printf 'ident=%s\n' "$cur_ident"
      if [ -n "$open" ]; then printf '%s' "$open"; fi
    } > "$target_cursor" || return 1
    mv -f "$target_cursor" "$cf" || return 1
  fi
  printf '%s' "$open"
}

# Incremental sibling of scan_open_decisions: same fleet-wide directory walk and
# output shape ("<task>\t<key>\t<verb>\t<note>" per open decision), but folds
# each task's status log through status_open_decisions_incremental instead of
# the whole-file status_open_decisions, so a fleet-wide per-drain scan stays
# bounded by new appends rather than total lifetime log size across every task.
scan_open_decisions_incremental() {  # <state>
  local state=$1 f task open line exclude
  exclude=$(status_scan_parent_channel_exclude "$state")
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    task=$(basename "$f"); task="${task%.status}"
    open=$(status_open_decisions_incremental "$f") || continue
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done
  return 0
}

status_presentation_snapshot() {  # <state>
  local state=$1 f task size ident exclude
  exclude=$(status_scan_parent_channel_exclude "$state")
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    task=$(basename "$f"); task="${task%.status}"
    size=$(_fm_status_file_size "$f") || return 1
    size=${size//[[:space:]]/}
    ident=$(_fm_open_decisions_file_ident "$f") || return 1
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$ident" ] || return 1
    printf '%s\t%s\t%s\n' "$task" "$size" "$ident" || return 1
  done
}


status_outcome_backstop_cursor_offset() {  # <status-file>
  local f=$1 state task manifest data row_task ident presented row_backstop backstop extra current size
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  state=${f%/*}
  task=${f##*/}; task=${task%.status}
  manifest="$state/.status-presentation-cursor"
  [ -e "$manifest" ] || { printf '0'; return 0; }
  [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
  data=$(LC_ALL=C command cat "$manifest" 2>/dev/null) || return 1
  backstop=0
  while IFS=$(printf '\t') read -r row_task ident presented row_backstop extra; do
    [ -n "$row_task" ] || continue
    [ -z "$extra" ] || return 1
    case "$presented:$row_backstop" in *[!0-9:]*) return 1 ;; esac
    [ -n "$presented" ] && [ -n "$ident" ] || return 1
    if [ "$row_task" = "$task" ]; then
      current=$(_fm_open_decisions_file_ident "$f") || return 1
      size=$(_fm_status_file_size "$f") || return 1
      size=${size//[[:space:]]/}
      case "$size" in ''|*[!0-9]*) return 1 ;; esac
      [ "$ident" = "$current" ] || { printf '0'; return 0; }
      backstop=${row_backstop:-0}
      [ "$backstop" -le "$size" ] || backstop=0
      printf '%s' "$backstop"
      return 0
    fi
  done <<EOF
$data
EOF
  printf '0'
}

status_signal_seen_marker_path() {  # <state> <task-id>
  printf '%s/.seen-%s' "$1" "$(printf '%s.status' "$2" | tr '.' '_')"
}

status_heartbeat_seen_marker_path() {  # <state> <task-id>
  printf '%s/.hb-surfaced-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

status_daemon_seen_marker_path() {  # <state> <task-id>
  printf '%s/.subsuper-seen-status-%s' "$1" "$(printf '%s' "$2" | tr ':/.' '___')"
}

status_retire_presentation_task() {  # <state> <task-id>
  local state=$1 task=$2 lock manifest tmp data row_task ident offset backstop extra rc=0 found=0
  local signal_marker heartbeat_marker daemon_marker home_appends home_appends_lock
  lock="$state/.status-presentation-lock"
  manifest="$state/.status-presentation-cursor"
  tmp="$manifest.tmp.$$"
  signal_marker=$(status_signal_seen_marker_path "$state" "$task")
  heartbeat_marker=$(status_heartbeat_seen_marker_path "$state" "$task")
  daemon_marker=$(status_daemon_seen_marker_path "$state" "$task")
  home_appends="$state/.$task.home-appends"
  home_appends_lock="$home_appends.lock"

  # A remote-home teardown can legitimately retire an endpoint ID that has no
  # status log in that home. Do not contend with that home's unrelated status
  # presenter in this no-op case. A concurrent presenter cannot add this task
  # without its status file, so a valid manifest with no matching row is a
  # durable proof that there is nothing to retire.
  if [ ! -e "$state/$task.status" ] && [ ! -L "$state/$task.status" ] \
    && [ ! -e "$state/.$task.open-decisions-cursor" ] \
    && [ ! -L "$state/.$task.open-decisions-cursor" ] \
    && [ ! -e "$home_appends" ] && [ ! -L "$home_appends" ] \
    && [ ! -e "$home_appends_lock" ] && [ ! -L "$home_appends_lock" ] \
    && [ ! -e "$signal_marker" ] && [ ! -L "$signal_marker" ] \
    && [ ! -e "$heartbeat_marker" ] && [ ! -L "$heartbeat_marker" ] \
    && [ ! -e "$daemon_marker" ] && [ ! -L "$daemon_marker" ]; then
    if [ ! -e "$manifest" ] && [ ! -L "$manifest" ]; then
      return 0
    fi
    if [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] \
      && data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      while IFS=$(printf '\t') read -r row_task ident offset backstop extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset:$backstop" in *[!0-9:]*) rc=1; break ;; esac
        [ -n "$offset" ] || { rc=1; break; }
        [ "$row_task" != "$task" ] || found=1
      done <<EOF
$data
EOF
      [ "$rc" -ne 0 ] || [ "$found" -ne 0 ] || return 0
      rc=0
    fi
  fi

  fm_lock_acquire_wait "$lock" || return 1
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    if [ ! -f "$manifest" ] || [ ! -r "$manifest" ] || [ -L "$manifest" ]; then
      rc=1
    elif ! data=$(LC_ALL=C command cat "$manifest" 2>/dev/null); then
      rc=1
    elif ! : > "$tmp"; then
      rc=1
    else
      while IFS=$(printf '\t') read -r row_task ident offset backstop extra; do
        [ -n "$row_task" ] || continue
        if [ -n "$extra" ] || [ -z "$ident" ]; then rc=1; break; fi
        case "$offset:$backstop" in *[!0-9:]*) rc=1; break ;; esac
        [ -n "$offset" ] || { rc=1; break; }
        if [ "$row_task" != "$task" ]; then
          printf '%s\t%s\t%s\t%s\n' "$row_task" "$ident" "$offset" "${backstop:-0}" >> "$tmp" \
            || { rc=1; break; }
        fi
      done <<EOF
$data
EOF
      if [ "$rc" -eq 0 ]; then mv -f "$tmp" "$manifest" || rc=1; fi
      [ "$rc" -eq 0 ] || rm -f "$tmp"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$state/$task.status" "$state/.$task.open-decisions-cursor" \
      "$home_appends" "$signal_marker" "$heartbeat_marker" "$daemon_marker" || rc=1
    fm_lock_remove_path "$home_appends_lock" 2>/dev/null || true
  fi
  fm_lock_release "$lock" || rc=1
  return "$rc"
}

status_acknowledge_presented_snapshot() {  # <state> <snapshot> [<fully-presented-task-ids>]
  local state=$1 snapshot=$2 fully_presented=${3:-} task endpoint ident f offset lines line safe
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    safe=false
    case "
$fully_presented
" in *$'\n'"$task"$'\n'*) safe=true ;; esac
    if [ "$safe" = false ]; then
      f="$state/$task.status"
      offset=$(status_presentation_cursor_offset "$f") || return 1
      lines=$(status_new_lines_since_cursor "$f" "$endpoint") || return 1
      # Once any informational line in this span is presented fleet-wide, the
      # contiguous cursor may advance through the captured endpoint. Routine
      # lines remain unacknowledged only while they are the sole unread content,
      # preserving delayed signal annotations without replaying a handled note
      # that happened to follow a routine line.
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          *[![:space:]]*)
            if status_line_is_unread_surface "$line"; then safe=true; break; fi
            ;;
        esac
      done <<EOF
$lines
EOF
      if [ "$safe" = false ]; then endpoint=$offset; fi
    fi
    printf '%s\t%s\t%s\n' "$task" "$endpoint" "$ident" || return 1
  done <<EOF
$snapshot
EOF
}

status_commit_presentation_snapshot() {  # <state> <snapshot>
  local state=$1 snapshot=$2 task endpoint ident f cur_ident size tmp backstop acknowledged_task acknowledged_endpoint
  tmp="$state/.status-presentation-cursor.tmp.$$"
  : > "$tmp" || return 1
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    case "$endpoint" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ -n "$ident" ] || { rm -f "$tmp"; return 1; }
    f="$state/$task.status"
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || { rm -f "$tmp"; return 1; }
    cur_ident=$(_fm_open_decisions_file_ident "$f") || { rm -f "$tmp"; return 1; }
    size=$(_fm_status_file_size "$f") || { rm -f "$tmp"; return 1; }
    size=${size//[[:space:]]/}
    case "$size" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ "$cur_ident" = "$ident" ] && [ "$endpoint" -le "$size" ] \
      || { rm -f "$tmp"; return 1; }
    backstop=$(status_outcome_backstop_cursor_offset "$f") || { rm -f "$tmp"; return 1; }
    while IFS=$(printf '\t') read -r acknowledged_task acknowledged_endpoint; do
      if [ "$acknowledged_task" = "$task" ]; then backstop=$acknowledged_endpoint; fi
    done <<EOF
${STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED:-}
EOF
    case "$backstop" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
    [ "$backstop" -le "$size" ] || { rm -f "$tmp"; return 1; }
    printf '%s\t%s\t%s\t%s\n' "$task" "$ident" "$endpoint" "$backstop" >> "$tmp" \
      || { rm -f "$tmp"; return 1; }
  done <<EOF
$snapshot
EOF
  mv -f "$tmp" "$state/.status-presentation-cursor" || { rm -f "$tmp"; return 1; }
}

scan_open_decisions_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f open line
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    open=$(status_open_decisions_incremental "$f" "$endpoint") || return 1
    [ -n "$open" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$open
EOF
  done <<EOF
$snapshot
EOF
}

# --- unread status lines since the presentation cursor ----------------------
#
# The drain annotation historically printed only the newest status line, so a
# substantive `note:` answer immediately followed by a routine `note:` (or a
# pending-reply resolution buried under a later unrelated append) never reached
# the supervisor. Those verbs also never enter the OPEN DECISIONS fold, so they
# had no other surfacing path.
# These helpers are the ONE owner of "what is still unread since the last drain
# presentation": one fleet manifest records each status identity and last-
# presented byte offset, and one atomic replacement commits only the contiguous
# status spans that were successfully presented. A quiet fleet scan leaves
# routine working/done bytes unacknowledged so a subsequently published signal
# can still annotate them. A missing manifest row or changed file identity is
# offset 0 for the current file, while malformed or unreadable cursor state
# aborts presentation without advancing any offset. A trusted cursor at EOF
# prints nothing, so already-presented bytes are not replayed as new. Teardown
# retires a task's manifest row with its status file, so reusing a task ID starts
# the replacement log unread at byte 0. Informational `note:` lines and
# reserved-key pending-reply resolutions are the fleet-wide unread surface;
# they are not open decisions and are not persisted in the folded open-set.

# Fleet-wide unread informational lines: one "<task>\t<status-line>" row per
# still-unread `note:` or pending-reply resolution, in glob (task id) order.
# Prints nothing when none are unread. Directory scan rejects status symlinks
# the same way scan_open_decisions does.
scan_unread_surface_lines() {  # <state>
  local state=$1 f task lines line exclude
  exclude=$(status_scan_parent_channel_exclude "$state")
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    task=$(basename "$f"); task="${task%.status}"
    lines=$(status_new_lines_since_cursor "$f") || return 1
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done
  return 0
}

scan_unread_surface_snapshot() {  # <state> <task-and-endpoint-snapshot>
  local state=$1 snapshot=$2 task endpoint ident f lines line
  while IFS=$(printf '\t') read -r task endpoint ident; do
    [ -n "$task" ] || continue
    f="$state/$task.status"
    lines=$(status_new_lines_since_cursor "$f" "$endpoint") || return 1
    [ -n "$lines" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      status_line_is_unread_surface "$line" || continue
      printf '%s\t%s\n' "$task" "$line"
    done <<EOF
$lines
EOF
  done <<EOF
$snapshot
EOF
}

# Fold material routed-work phases in the same keyed event stream.
# A working or declared-pause event opens or replaces one phase for its key.
# A later done, failed, needs-decision, blocked, or resolved event carrying that
# key closes the phase, because it has moved to a terminal or separately tracked
# state.
# A bare legacy event prints as the default key, preserving one-phase behavior.
# That printed key is not the decision fold's shared default bucket: a line with
# no stated key is a different phase from an explicit "[key=default]" line, so a
# stated default-key retraction cannot cancel an unrelated keyless wait, while a
# keyless retraction still closes only the keyless phase.
# This fold is evidence about whether a parent event was explicitly superseded.
# It is never authoritative current crew state, and consumers must not let an open
# phase outrank a structured home snapshot or fm-crew-state result.

# Rewrite the keyless stand-in back to the public "default" key. Only the key
# field is rewritten, so a note that happens to contain the stand-in stays put.
_fm_activity_publish_keys() {  # <open-set>
  local line key rest
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    key=${line%%$'\t'*}
    rest=${line#*$'\t'}
    [ "$key" = "$_FM_CLASSIFY_KEYLESS_PHASE" ] && key=default
    printf '%s\t%s\n' "$key" "$rest"
  done <<EOF
$1
EOF
}

_fm_status_open_activities_stream() {
  local line verb key note resolve held open='' pause
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
  held=${FM_CLASSIFY_CAPTAIN_HELD_VERB:-$FM_CLASSIFY_CAPTAIN_HELD_VERB_DEFAULT}
  pause=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  while IFS= read -r line || [ -n "$line" ]; do
    # Blank-line guard; see _fm_decision_fold_line for why this is a glob.
    case "$line" in
      *[![:space:]]*) ;;
      *) continue ;;
    esac
    verb=$(status_line_verb "$line")
    key=$(_fm_decision_key "$line" "$_FM_CLASSIFY_KEYLESS_PHASE") || continue
    case "$verb" in
      working|"$pause")
        note=$(status_line_note "$line")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        open="${open}${key}"$'\t'"${verb}"$'\t'"${note}"$'\n'
        ;;
      done|failed|needs-decision|blocked|"$resolve"|"$held")
        open=$(_fm_decision_drop "$open" "$key")
        [ -n "$open" ] && open="${open}"$'\n'
        ;;
    esac
  done
  _fm_activity_publish_keys "$open"
}

status_open_activities() {  # <status-file-or-dash>
  local f=$1
  if [ "$f" = - ]; then
    _fm_status_open_activities_stream
    return 0
  fi
  [ -f "$f" ] || return 0
  _fm_status_open_activities_stream < "$f"
}

# task id from a recorded window target, falling back to the tmux-shaped
# "<session>:fm-<id>" form when no metadata state is available.
window_to_task() {
  local w=$1 state=${2:-${STATE:-${FM_STATE_OVERRIDE:-}}} meta mw mt t line
  if [ -n "$state" ]; then
    for meta in "$state"/*.meta; do
      [ -e "$meta" ] || continue
      # The last window= and terminal= values, read in one pass without the
      # grep | tail -1 | cut -d= -f2- pipelines this once forked per key.
      mw=
      mt=
      {
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in
            window=*) mw=${line#window=} ;;
            terminal=*) mt=${line#terminal=} ;;
          esac
        done < "$meta"
      } 2>/dev/null
      [ "$mw" = "$w" ] || [ "$mt" = "$w" ] || continue
      t=${meta##*/}
      t=${t%.meta}
      printf '%s' "$t"
      return 0
    done
  fi
  t="${w##*:}"; t="${t#fm-}"; printf '%s' "$t"
}

# Classify WHY an idle/stale crew MIGHT be safely absorbed instead of surfaced,
# from bin/fm-crew-state.sh's one authoritative current-state line
# ("state: <s> · source: <src> · <detail>"). Prints exactly one token:
#   working - an actively-running no-mistakes step (running/fixing/ci) or a busy
#             pane; the crew is legitimately mid-work on a static-looking pane
#             (e.g. waiting on CI);
#   paused  - the crew's authoritative current state is a declared external-wait
#             pause (paused:), which is EXPECTED to idle;
#   none    - neither, so the wake must surface (a stopped/finished/parked/failed/
#             torn-down/unknown crew, or an unreadable verdict).
# One fm-crew-state.sh read serves BOTH absorb reasons at once. Reading the state
# authoritatively (not the status log) is what keeps run-step precedence: a crew
# that appended paused: but then STARTED a run reports working, never paused.
# NOT a pure read: fm-crew-state.sh may make a bounded no-mistakes call, so callers
# run it only on no-verb signal and first-sighting stale paths, never every wake.
# FM_CREW_STATE_BIN lets tests stub the verdict.
crew_absorb_class() {  # <id>
  local id=$1 line state src
  [ -n "$id" ] || { printf 'none'; return; }
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) printf 'none'; return ;; esac
  state=${line#state: }; state=${state%% *}
  if [ "$state" = paused ]; then printf 'paused'; return; fi
  if [ "$state" = working ]; then
    src=${line#*source: }; src=${src%% *}
    case "$src" in run-step|pane) printf 'working'; return ;; esac
  fi
  printf 'none'
}

# 0 if crew <id> shows POSITIVE evidence it is still working (crew_absorb_class
# reports `working`). This is the "provably working" predicate at the heart of
# absorb-only-on-positive-evidence. This is the sole proof for stale wakes and the
# shared authoritative proof for no-verb signals. Where a home opts in, fm-watch.sh
# may additionally absorb a bare turn-end on bounded pane churn, while every other
# failed verdict surfaces
# because the crew may be done, waiting on a decision, or wedged. For stale panes
# it is checked before trusting the status log so a pre-validation captain-relevant
# line does not override an active run. See crew_absorb_class for the exact
# working/paused/none decision.
crew_is_provably_working() {  # <id>
  [ "$(crew_absorb_class "$1")" = working ]
}

# 0 if crew <id>'s authoritative current state is a declared external-wait pause.
# The stale path absorbs such a crew (on a long re-surface cadence) instead of
# escalating a possible wedge.
crew_is_paused() {  # <id>
  [ "$(crew_absorb_class "$1")" = paused ]
}

# The one spelling of the verdict component that says a parked gate's answer is
# owed by a HUMAN. bin/fm-crew-state.sh mints it (nm_gate_awaits_human_decision
# owns the derivation: the findings table's `action` column, read by position);
# crew_gate_awaits_human_decision below is its only consumer.
FM_GATE_HUMAN_DECISION='ask-user: authority decision'

# 0 if crew <id>'s authoritative current state is a no-mistakes gate whose answer
# is owed by a human rather than by the crewmate itself.
#
# `parked` alone cannot answer this: the gate's shape (awaiting_approval,
# fix_review, awaiting_agent) is reported parked in every case and does not by
# itself say who owes the answer; only a findings row whose `action` column is
# exactly `ask-user` does. A crewmate that goes quiet before answering its OWN
# gate is precisely the wedge the escalation ladder exists to catch, so only the
# minted component above - never the parked verdict, the gate name, or the
# finding text - admits a lane here.
#
# The whole component is compared for equality rather than searched for, so a
# gate name or a reconciliation note that happens to contain the words cannot
# mint it downstream either.
# On success it prints the reported run id, read from the line's whole
# `run: <id>` component, so the caller can bind the gate to the decision that
# names that run; a line carrying no run id is not evidence, since nothing could
# then tie a decision to this gate.
# Same cost and the same caveat as crew_absorb_class: one fm-crew-state.sh read,
# which may make a bounded no-mistakes call, so callers take it only where they
# already accept that cost.
crew_gate_awaits_human_decision() {  # <id> -> <run-id> on stdout
  local id=$1 line state src rest part human='' run=''
  [ -n "$id" ] || return 1
  line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true
  case "$line" in state:*) ;; *) return 1 ;; esac
  state=${line#state: }; state=${state%% *}
  [ "$state" = parked ] || return 1
  src=${line#*source: }; src=${src%% *}
  [ "$src" = run-step ] || return 1
  rest="$line · "
  while [ -n "$rest" ]; do
    part=${rest%% · *}
    rest=${rest#* · }
    [ "$part" = "$FM_GATE_HUMAN_DECISION" ] && human=1
    case "$part" in "run: "?*) run=${part#run: } ;; esac
  done
  [ -n "$human" ] && [ -n "$run" ] || return 1
  case "$run" in *[[:space:]]*) return 1 ;; esac
  printf '%s\n' "$run"
}

# Directories excluded from the worktree write probe below, and the depth it walks.
# The excluded set is everything a supervisor read or a package manager can write
# without the crew doing any work - .git first, so firstmate's own read-only git
# commands against the worktree can never make the probe self-fulfilling - plus the
# large generated trees that would make the walk expensive. Both are overridable so
# a home with an unusual layout can widen or narrow the probe. The list is a skip
# list, so clearing it skips nothing and widens the walk to the whole depth-bounded
# tree; it never disables the probe, which would quietly cost the wedge detector a
# liveness input on a home that meant to widen it. Defaulted with the plain form so
# an explicitly empty value stays empty: clearing the knob in the environment is the
# documented way to ask for that wider walk, and treating empty as unset would hand
# the default skip list back to exactly the home that asked for more coverage.
FM_WORKTREE_WRITE_PRUNE=${FM_WORKTREE_WRITE_PRUNE-'.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'}
FM_WORKTREE_WRITE_MAXDEPTH=${FM_WORKTREE_WRITE_MAXDEPTH:-6}

# Wall-clock seconds the probe's single walk may take. The walk runs synchronously
# inside the caller's poll loop at the exact moment an escalation would otherwise
# fire, and -xdev keeps it out of a nested mount but cannot help when the worktree
# root ITSELF sits on a hung network or container mount; unbounded, such a walk
# would wedge the very supervisor that exists to notice a wedge, stalling its
# heartbeat instead of escalating. Hitting the bound is a negative outcome like
# every other: it reads as no evidence, so the caller's escalation schedule is
# untouched and a stall that writes nothing still escalates on the existing
# schedule. A value that is not a positive integer is not a bound at all (`timeout
# 0` and the perl fallback's `alarm 0` both disable the deadline), so the default
# applies instead; the check lives at the point of use so an in-process override
# gets it too.
FM_WORKTREE_WRITE_TIMEOUT=${FM_WORKTREE_WRITE_TIMEOUT:-10}

# 0 when some regular file under <id>'s recorded worktree is newer than
# <anchor-file>: positive evidence the crew is still producing work even though its
# rendered pane has gone quiet. This is the third liveness input the wedge detector
# has, after pane quietness and the run step, and it exists because neither of
# those can see a crew that is writing source, then tests, then documentation
# behind a static pane - the 2026-08-14 case of eight consecutive possible-wedge
# escalations against a crew that was demonstrably working the whole time.
#
# 1 for every other outcome, including an id with no recorded worktree, a worktree
# that is gone, a missing anchor, and a walk that fails or finds nothing. Absence of
# evidence therefore always leaves the caller's existing escalation schedule
# untouched, so a crew that writes nothing still escalates exactly as before.
#
# A kind=secondmate task records a provisioned firstmate home, not a code tree, and
# such a home runs its OWN supervision inside it: its state/ directory churns a
# watcher beacon, pane hashes, and heartbeats whether or not the mate is producing
# anything, so a walk there would report liveness for a mate that has done nothing.
# Those homes are excluded outright rather than by pruning "state", which would also
# hide a legitimate source directory of that name in an ordinary worktree. The
# exclusion is a negative outcome like any other, so an unproductive mate keeps
# escalating on the caller's unchanged schedule.
#
# The anchor is the caller's own idle-window timer file, whose mtime already marks
# when the quiet window opened, so `-newer` needs no clock arithmetic, no temp
# file, and no portable mtime-setting. Not a pure status-file read (see the header):
# one pruned, depth-bounded, wall-clock-bounded walk per call, which callers must
# reach only when they are otherwise about to escalate, never on every poll. A walk
# that outlives FM_WORKTREE_WRITE_TIMEOUT is killed and reported as no evidence, so
# a hung mount costs the escalation nothing but the bound. -xdev holds that walk to the
# worktree's own filesystem rather than descending into a nested network or container
# mount, so a write that lands only under such a mount is one more negative outcome.
crew_worktree_written_since() {  # <id> <state> <anchor-file>
  local id=$1 state=$2 anchor=$3 wt kind name hit bound
  local -a names=() prune=()
  [ -n "$id" ] || return 1
  [ -f "$anchor" ] || return 1
  wt=$(grep '^worktree=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ -n "$wt" ] && [ -d "$wt" ] || return 1
  kind=$(grep '^kind=' "$state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2- || true)
  [ "$kind" != secondmate ] || return 1
  if [ -e "$wt/.fm-secondmate-home" ] || [ -L "$wt/.fm-secondmate-home" ]; then
    return 1
  fi
  read -r -a names <<< "$FM_WORKTREE_WRITE_PRUNE"
  for name in ${names[@]+"${names[@]}"}; do
    [ "${#prune[@]}" -eq 0 ] || prune+=( -o )
    prune+=( -name "$name" )
  done
  bound=$FM_WORKTREE_WRITE_TIMEOUT
  case "$bound" in ''|*[!0-9]*|0) bound=10 ;; esac
  if [ "${#prune[@]}" -gt 0 ]; then
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      \( "${prune[@]}" \) -prune -o -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  else
    hit=$(fm_run_timed "$bound" find "$wt" -xdev -maxdepth "$FM_WORKTREE_WRITE_MAXDEPTH" \
      -type f -newer "$anchor" -print -quit 2>/dev/null || true)
  fi
  [ -n "$hit" ]
}

# 0 (benign/absorb) if EVERY task referenced by a no-verb "signal:" wake is provably
# working; 1 (actionable/surface) if any is not, or no task can be resolved. Pass the
# same space-separated file list the caller classified with the span read above.
# Files are mapped to task ids by stripping the .status / .turn-ended suffix;
# a no-verb wake with nothing
# provably working must surface, so an empty/unresolvable list returns 1.
# A kind=secondmate task's .status stream doubles as its routed-reply channel,
# so the lines new since the watcher's classified position are read before any
# busy evidence counts: a decision, blocker, terminal outcome, `note:`, any line
# carrying a correlation marker (fm_pending_reply_corr_token, bracketed or not),
# and any verb this library does not know is parent-directed content the
# supervisor must read, so it surfaces regardless of how busy the mate is. Only
# unmarked routine `working:` and `paused:` progress falls through
# to the same provably-working absorb an ordinary crewmate gets, so a healthy
# mate's progress no longer wakes the primary on every append while an unproven
# mate still surfaces. The span starts at the classified position its owner
# reports (fm_wake_signal_seen_size, bin/fm-wake-lib.sh, loaded by every watcher
# caller); a caller without that library reads the whole log, which can only
# surface more. An unreadable span surfaces. Scoped to .status files - a mate's
# bare turn-ended ping always used the ordinary provably-working absorb.
_fm_secondmate_status_new_lines_routine() {  # <status-file> <state>
  local f=$1 state=$2 start=0 size chunk line verb
  if command -v fm_wake_signal_seen_size >/dev/null 2>&1; then
    start=$(fm_wake_signal_seen_size "$state" "$f")
  fi
  case "$start" in ''|*[!0-9]*) start=0 ;; esac
  size=$(_fm_status_file_size "$f") || return 1
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$start" -le "$size" ] || start=0
  [ "$start" -lt "$size" ] || return 0
  chunk=$(_fm_status_read_span "$f" "$start" "$((size - start))") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *[![:space:]]*) ;; *) continue ;; esac
    case "$line" in *corr=*) return 1 ;; esac
    status_line_verb "$line" verb
    case "$verb" in
      working|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") ;;
      *) return 1 ;;
    esac
  done <<EOF
$chunk
EOF
  return 0
}
signal_crew_provably_working() {  # <file> ...
  local f base dir task seen=""
  for f in "$@"; do
    base=${f##*/}
    dir=${f%/*}
    [ "$dir" != "$f" ] || dir=.
    case "$base" in
      *.status)     task=${base%.status} ;;
      *.turn-ended) task=${base%.turn-ended} ;;
      *)            continue ;;
    esac
    [ -n "$task" ] || continue
    case "$base" in
      *.status)
        if [ "$(grep '^kind=' "$dir/$task.meta" 2>/dev/null | tail -1 | cut -d= -f2-)" = secondmate ]; then
          _fm_secondmate_status_new_lines_routine "$f" "$dir" || return 1
        fi
        ;;
    esac
    case " $seen " in *" $task "*) continue ;; esac
    seen="$seen $task"
    crew_is_provably_working "$task" || return 1
  done
  [ -n "$seen" ] || return 1
  return 0
}

# 0 (terminal/actionable) if a stale window's latest recognized status event is
# captain-relevant; 1 otherwise, including the no-status case. A 1 only means
# "non-terminal"; the always-on watcher then applies crew_is_provably_working,
# while the away-mode daemon applies its persistence recheck.
stale_is_terminal() {  # <window> <state>
  local win=$1 state=$2 last
  last=$(last_status_line "$state/$(window_to_task "$win" "$state").status")
  [ -n "$last" ] && status_is_captain_relevant "$last"
}
