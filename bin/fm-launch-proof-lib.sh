#!/usr/bin/env bash
# Proof that a recorded Herdr agent came through Firstmate's launch boundary.
# fm-spawn stamps FM_SPAWN_GEN with the record's spawn_gen and records
# launch_proof=env-v1. The live PID's pin must match that recorded incarnation.
# For omp, a matching pin also requires current-session proof. There is no omp
# adoption route (Main 1874, Main 1901), as there is none for claude (Main
# 1637): an omp agent without its matching pin is unmanaged, with its cause.
# Native Herdr restore reconstructs argv, not the launch environment/settings.
# Verdicts: managed|unmanaged|pinned-elsewhere|contested|unknown. Only managed
# authorizes lifecycle action for a proven record; a legacy record (one
# positively read record with no launch_proof line) keeps its pre-proof
# attribution rule, and a record that is not one readable record with at most
# one nonempty launch_proof is unknown (fm_launch_proof_record_proof). For a
# claude record with launch_proof=env-v1 the only proof is that launch record
# and the FM_SPAWN_GEN token fm-spawn put in the agent's environment, judged on
# one read: pinned-elsewhere (a token for another generation, on the agent or on
# another member of its process group), unmanaged (a readable environment with
# no token: an unpinned native restore, which nothing can authorize, since a
# native restore runs outside the launch environment), unknown (unreadable, or
# no spawn_gen). For every harness, a matching token on a versioned record is
# managed only after the refusal checks of fm_launch_proof_token_checks pass;
# a failed check is contested, unknown or pinned-elsewhere, with its own cause.
# No endpoint discovery: callers supply this home's validated exact endpoint.

_FM_LAUNCH_PROOF_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-remote-herdr-owner-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-agent-process-lib.sh"

fm_launch_proof_pid() { # <pid> <spawn-gen> -> managed|unmanaged|unknown
  local pid=$1 gen=$2 environment
  case "$pid" in ''|*[!0-9]*) printf unknown; return ;; esac
  [ -n "$gen" ] || { printf unmanaged; return; }
  environment=$(fm_remote_herdr_process_env "$pid") || { printf unknown; return; }
  # A platform which hides process environments supplies neither signal.
  # Do not confuse that with a positively readable environment missing our pin.
  if ! printf '%s\n' "$environment" | grep -Eq '^(PATH|HOME)='; then
    printf unknown
  elif printf '%s\n' "$environment" | grep -Fx "FM_SPAWN_GEN=$gen" >/dev/null; then
    printf managed
  else
    printf unmanaged
  fi
}

# Succeeds only when a readable environment carries a nonempty pin for another
# generation: that process belongs to a different launch. An absent, empty, or
# unreadable pin names no other launch. Prints nothing.
fm_launch_proof_pid_pinned_elsewhere() { # <pid> <spawn-gen>
  local pid=$1 gen=$2 environment pinned
  environment=$(fm_remote_herdr_process_env "$pid") || return 1
  printf '%s\n' "$environment" | grep -Eq '^(PATH|HOME)=' || return 1
  pinned=$(printf '%s\n' "$environment" | sed -n 's/^FM_SPAWN_GEN=//p')
  [ -n "$pinned" ] && [ "$pinned" != "$gen" ]
}

# One environment read judges a claude agent against its launch record: managed
# (its token equals <spawn-gen>), pinned-elsewhere (a nonempty token for another
# generation), unmanaged (readable, with no token), unknown (no recorded
# <spawn-gen>, an invalid pid, or an environment that cannot be read).
fm_launch_proof_pid_classify() { # <pid> <spawn-gen> -> managed|unmanaged|pinned-elsewhere|unknown
  local pid=$1 gen=$2 environment pinned
  case "$pid" in ''|*[!0-9]*) printf unknown; return ;; esac
  [ -n "$gen" ] || { printf unknown; return; }
  environment=$(fm_remote_herdr_process_env "$pid") || { printf unknown; return; }
  printf '%s\n' "$environment" | grep -Eq '^(PATH|HOME)=' || { printf unknown; return; }
  if printf '%s\n' "$environment" | grep -Fx "FM_SPAWN_GEN=$gen" >/dev/null; then
    printf managed
    return
  fi
  pinned=$(printf '%s\n' "$environment" | sed -n 's/^FM_SPAWN_GEN=//p')
  if [ -n "$pinned" ]; then printf pinned-elsewhere; else printf unmanaged; fi
}

# Succeeds when a member of <anchor>'s process group in <process-table> (pid ppid
# pgid rows), other than <anchor> itself, carries a pin for another launch
# generation. Each member's environment is read once. Prints nothing.
fm_launch_proof_group_pinned_elsewhere() { # <spawn-gen> <process-table> <anchor-pid>
  local gen=$1 table=$2 anchor=$3 group kid
  group=$(awk -v p="$anchor" '$1 == p {print $3; exit}' <<< "$table")
  [ -n "$group" ] || return 1
  while IFS= read -r kid; do
    [ -z "$kid" ] || ! fm_launch_proof_pid_pinned_elsewhere "$kid" "$gen" || return 0
  done < <(awk -v g="$group" -v p="$anchor" '$3 == g && $1 != p {print $1}' <<< "$table")
  return 1
}

# With <with-listed>, a second line names every process Herdr listed in the
# pane's foreground, so the refusal checks judge each one (Main 1807 (3)).
fm_launch_proof_herdr_pid() { # <meta> [with-listed] -> the attributed live foreground PID
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local meta=$1 target session pane info foreground pid
  local candidates ids='' name argv0 parents group
  fm_launch_proof_record_ensure "$meta"
  target=$(fm_launch_proof_field "$meta" window)
  session=${target%%:*}; pane=${target#*:}
  info=$(fm_backend_herdr_cli "$session" pane process-info --pane "$pane" 2>/dev/null) \
    || return 1
  # The process-group leader may be a launcher shell, and omp helpers share
  # the group. Attribute the unique ancestor-most non-shell process instead.
  candidates=$(printf '%s' "$info" | jq -ec --arg pane "$pane" '
    select(.result.type == "pane_process_info" and .result.process_info.pane_id == $pane)
    | .result.process_info as $view | $view.foreground_processes
    | select(type == "array" and length > 0
        and all(.[]; .pid | type == "number" and . > 1 and floor == .))
    | select((map(.pid) | unique | length) == length)
    | if $view.foreground_process_group_id != null then
        select(any(.[]; .pid == $view.foreground_process_group_id))
      else select(length == 1) end' 2>/dev/null) \
    || return 1
  while IFS=$'\t' read -r pid name argv0; do
    [ "$(fm_agent_process_classify_name "$name" "$argv0")" = shell ] || ids="$ids $pid"
  done < <(printf '%s' "$candidates" | jq -r '.[] | [.pid, (.name // ""), (.argv0 // "")] | @tsv')
  candidates=$(printf '%s' "$candidates" | jq -c --arg ids "$ids " '
    map(select(.pid as $pid | $ids | contains(" \($pid) ")))')
  if [ "$(printf '%s' "$info" | jq '.result.process_info.foreground_processes | length')" -gt 1 ]; then
    group=$(printf '%s' "$info" | jq '.result.process_info.foreground_process_group_id')
    # A failed or partial table read refuses (Main 1709 ruling 1, Main 1874):
    # pipefail keeps the reader's status, every row must be two numbers (a short
    # or malformed row may hide a process), and every process Herdr listed must
    # be in the table.
    parents=$(set -o pipefail; LC_ALL=C ps -axo pid=,ppid= 2>/dev/null) && [ -n "$parents" ] || return 1
    awk 'NF != 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ {bad = 1} END {exit bad}' <<< "$parents" || return 1
    parents=$(printf '%s\n' "$parents" | jq -Rnc '
      [inputs | capture("^\\s*(?<pid>[0-9]+)\\s+(?<ppid>[0-9]+)\\s*$")
        | {key:.pid,value:(.ppid | tonumber)}] | from_entries') \
      || return 1
    # A listed process this later table lacks is unaccounted for, never exited.
    printf '%s' "$info" | jq -e --argjson parents "$parents" '
      .result.process_info.foreground_processes
      | all(.[]; $parents[.pid | tostring] != null)' >/dev/null 2>&1 \
      || return 1
    candidates=$(printf '%s' "$candidates" | jq -ec --argjson parents "$parents" --argjson group "$group" '
      map(.pid) as $ids
      | def below($pid; $targets; $seen):
          $parents[$pid | tostring] as $parent
          | if $parent == null or ($seen | index($parent)) != null then error("unreadable ancestry")
            elif ($targets | index($parent)) != null then true
            elif $parent <= 1 then false
            elif ($seen | length) >= 64 then error("deep ancestry")
            else below($parent; $targets; $seen + [$parent]) end;
        map(select(below(.pid; $ids; [.pid]) | not))
        | map(select(.pid == $group or below(.pid; [$group]; [.pid])))' 2>/dev/null) \
      || return 1
  fi
  foreground=$(printf '%s' "$candidates" | jq -ec 'select(length == 1) | .[0]') || return 1
  pid=$(printf '%s' "$foreground" | jq -er '.pid | select(type == "number" and . > 1) | floor' 2>/dev/null) || return 1
  printf '%s' "$pid"
  [ "${2:-}" = with-listed ] || return 0
  printf '\n%s' "$(printf '%s' "$info" | jq -r '[.result.process_info.foreground_processes[].pid | tostring] | join(" ")')"
}

# The one read of a task record (Main 1634 D1, Main 1807 (2)). One decision
# reads the record's bytes once, and every field it uses comes from those same
# bytes; a nested call in the same decision reuses them. Each entry point
# below declares the three FM_LAUNCH_PROOF_RECORD_* variables local, so the
# bytes live only as long as that decision. A read that needs the file again
# compares it byte for byte and refuses on a change.
FM_LAUNCH_PROOF_RECORD_CAUSE='its launch record is not one readable record with at most one launch_proof line naming a known proof (it is missing, unreadable, empty, duplicated, changed while read, or names an unknown proof), so nothing proves the live agent'
# The exact bytes of a regular, readable, nonempty file, trailing newlines kept
# (Main 1856 F6). A shell variable cannot hold a NUL byte, so each NUL is turned
# into a \001 byte on the way in, and any \001 then refuses: no record that
# carries either byte is read as text. Fails on a failed read (pipefail).
fm_launch_proof_bytes() { # <file>
  local raw
  { [ -f "$1" ] && [ -r "$1" ]; } || return 1
  raw=$(set -o pipefail; cat -- "$1" 2>/dev/null | LC_ALL=C tr '\000' '\001' && printf x) || return 1
  raw=${raw%x}
  [ -n "$raw" ] || return 1
  case "$raw" in *$'\001'*) return 1 ;; esac
  printf '%sx' "$raw"
}

# One field of <bytes> as fm_meta_get reads a record: the last <key>= line wins.
fm_launch_proof_bytes_field() { # <bytes> <key>
  local line value=''
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) value=${line#*=} ;; esac
  done <<< "$1"
  printf '%s' "$value"
}

# The one nonempty value of <key> in <bytes>, as fm_backend_meta_exact_value
# reads a file: fails unless exactly one <key>= line carries a value.
fm_launch_proof_bytes_exact_value() { # <bytes> <key>
  local line value='' count=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$2="*) count=$((count + 1)); value=${line#*=} ;; esac
  done <<< "$1"
  [ "$count" = 1 ] && [ -n "$value" ] || return 1
  printf '%s' "$value"
}

fm_launch_proof_record_read() { # <meta>: sets FM_LAUNCH_PROOF_RECORD_PATH, _BYTES, _OK in scope
  local raw
  FM_LAUNCH_PROOF_RECORD_PATH=$1 FM_LAUNCH_PROOF_RECORD_BYTES='' FM_LAUNCH_PROOF_RECORD_OK=0
  raw=$(fm_launch_proof_bytes "$1") || return 0
  FM_LAUNCH_PROOF_RECORD_BYTES=${raw%x} FM_LAUNCH_PROOF_RECORD_OK=1
}

# Reads <meta> unless this decision already holds its bytes. Callers declare the
# three variables local first (see fm_launch_proof_record_read).
fm_launch_proof_record_ensure() { # <meta>
  [ "${FM_LAUNCH_PROOF_RECORD_PATH-}" = "$1" ] || fm_launch_proof_record_read "$1"
}

# One field of <meta>, from this decision's bytes when it holds them (the last
# line for <key> wins, as fm_meta_get reads it), else from the file.
fm_launch_proof_field() { # <meta> <key>
  if [ "${FM_LAUNCH_PROOF_RECORD_PATH-}" = "$1" ]; then
    [ "${FM_LAUNCH_PROOF_RECORD_OK-}" = 1 ] || return 0
    fm_launch_proof_bytes_field "$FM_LAUNCH_PROOF_RECORD_BYTES" "$2"
    return 0
  fi
  fm_meta_get "$1" "$2"
}

# A private copy of this decision's bytes of <meta>, for a validator that reads
# a file, so that validation rests on the same bytes as the rest of the
# decision (Main 1874 rule S). Prints the copy's path; the caller removes it.
fm_launch_proof_record_copy() { # <meta>
  local copy
  [ "${FM_LAUNCH_PROOF_RECORD_OK-}" = 1 ] && [ "${FM_LAUNCH_PROOF_RECORD_PATH-}" = "$1" ] || return 1
  copy=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-launch-record.XXXXXX") || return 1
  printf '%s' "$FM_LAUNCH_PROOF_RECORD_BYTES" > "$copy" || { rm -f -- "$copy"; return 1; }
  printf '%s' "$copy"
}

# Whether <meta> still holds exactly this decision's bytes. Prints nothing.
fm_launch_proof_record_unchanged() { # <meta>
  local raw
  [ "${FM_LAUNCH_PROOF_RECORD_OK-}" = 1 ] && [ "${FM_LAUNCH_PROOF_RECORD_PATH-}" = "$1" ] || return 1
  raw=$(fm_launch_proof_bytes "$1") || return 1
  [ "${raw%x}" = "$FM_LAUNCH_PROOF_RECORD_BYTES" ]
}

# The record's launch proof, from this decision's bytes (Main 1709 ruling 2,
# Main 1716 (B), Main 1807 (1)). Prints absent only when the record has no
# launch_proof line at all, and proof=<value> for its one line otherwise, so no
# value (the literal "legacy" included) can read as absent. Fails for a
# missing, unreadable or empty record, an empty value, or two or more lines.
fm_launch_proof_record_proof() { # <meta>
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local line value='' count=0
  fm_launch_proof_record_ensure "$1"
  [ "$FM_LAUNCH_PROOF_RECORD_OK" = 1 ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      launch_proof=*) count=$((count + 1)); value=${line#launch_proof=} ;;
    esac
  done <<< "$FM_LAUNCH_PROOF_RECORD_BYTES"
  case "$count" in
    0) printf absent ;;
    1) [ -n "$value" ] || return 1; printf 'proof=%s' "$value" ;;
    *) return 1 ;;
  esac
}

# Succeeds only for a record with no launch_proof line at all (a legacy record).
fm_launch_proof_record_legacy() { # <meta>
  local proof
  proof=$(fm_launch_proof_record_proof "$1") && [ "$proof" = absent ]
}

# Whether <from>'s parent chain in <process-table> (pid ppid [pgid] rows) reaches
# <to>: 0 it does, with every link's live parent read now equal to the table's;
# 1 the chain ends first; 2 a link's live parent differs from the table's, so
# the two reads disagree or the live parent read fails. Prints nothing.
fm_launch_proof_chain() { # <process-table> <from> <to>
  local table=$1 pid=$2 to=$3 parent live depth=0
  while [ "$depth" -lt 64 ]; do
    parent=$(awk -v p="$pid" '$1 == p {print $2; exit}' <<< "$table")
    [ -n "$parent" ] || return 1
    # pipefail: a reader that prints a plausible parent and then fails is no
    # evidence (Main 1856 F8).
    live=$(set -o pipefail; LC_ALL=C ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ') || return 2
    [ "$live" = "$parent" ] || return 2
    [ "$parent" != "$to" ] || return 0
    [ "$parent" -gt 1 ] 2>/dev/null || return 1
    pid=$parent
    depth=$((depth + 1))
  done
  return 1
}

# The physical form of an existing absolute directory, else nothing, so an
# absent or relative field never matches anything.
fm_launch_proof_physical_dir() { # <path>
  case "$1" in
    /*) (cd -P -- "$1" 2>/dev/null && pwd -P) || true ;;
  esac
}

# Prints the physical kernel working directory of <pid> (never argv or env).
fm_launch_proof_pid_cwd() { # <pid>
  local pid=$1 out line path='' pids=0 names=0
  # pipefail: a reader that fails gives no proof, whatever it printed.
  out=$(set -o pipefail; lsof -w -a -p "$pid" -d cwd -F pn0 2>/dev/null | tr '\0' '\n') || return 1
  while IFS= read -r line; do
    case "$line" in
      p*) [ "$line" = "p$pid" ] || return 1; pids=$((pids + 1)) ;;
      n*) path=${line#n}; names=$((names + 1)) ;;
    esac
  done <<< "$out"
  [ "$pids" -eq 1 ] && [ "$names" -eq 1 ] || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  # lsof escapes backslashes and nonprinting bytes even with -F0. Decode the
  # unambiguous escapes the omp proof decodes; any other escape, and a decoded
  # control character (no line-based record can name it), is not proof.
  case "$path" in
    *\\*)
      path=$(python3 -I -c '
import re, sys
escapes = {b"a": b"\a", b"b": b"\b", b"f": b"\f", b"n": b"\n", b"r": b"\r", b"t": b"\t", b"v": b"\v", b"\\": b"\\"}
def unescape(match):
    token = match.group(0)[1:]
    if token.startswith(b"x"):
        return bytes([int(token[1:], 16)])
    if token not in escapes:
        raise ValueError
    return escapes[token]
try:
    name = re.sub(rb"\\(?:x[0-9a-fA-F]{2}|.)", unescape, sys.argv[1].encode("utf-8", "surrogateescape"))
except (ValueError, re.error):
    sys.exit(1)
if any(byte < 32 or byte == 127 for byte in name):
    sys.exit(1)
sys.stdout.buffer.write(name + b"/")
' "$path") || return 1
      path=${path%/}
      ;;
  esac
  (cd -P -- "$path" 2>/dev/null && pwd -P)
}
# Every local Firstmate state directory a record in <meta>'s state directory can
# share a pane or home with: the root inventory (bin/fm-wake-lib.sh
# fm_local_firstmate_state_dirs, strict) anchored on the home that holds the
# record, one per line. Fails, printing why, when that inventory cannot be
# proved. A separate process keeps the inventory's source-time settings (and
# its state directory creation, a no-op for this existing one) out of the
# caller. The host attribution verb never calls it (Main 1716 (C)).
fm_launch_proof_claim_states() { # <meta>
  local state home
  state=$(dirname -- "$1")
  case "${state##*/}" in
    state) home=$(dirname -- "$state") ;;
    *) home=${FM_HOME:-} ;;
  esac
  # shellcheck disable=SC2016 # the script expands in the child shell
  env -u FM_STATE_OVERRIDE FM_HOME="$home" STATE="$state" bash -c '
    . "$1/fm-wake-lib.sh" >/dev/null 2>&1 && . "$1/fm-secondmate-registry-lib.sh" >/dev/null 2>&1 \
      || { printf "the home inventory could not be loaded"; exit 1; }
    fm_local_firstmate_state_dirs "$2" 2>/dev/null \
      || { printf "%s" "${FM_LOCAL_FIRSTMATE_ERROR:-the local homes cannot be enumerated}"; exit 1; }
    printf "%s\n" "${FM_LOCAL_FIRSTMATE_STATES[@]}"' _ "$_FM_LAUNCH_PROOF_DIR" "$state"
}

# Whether <state-dir> holds a local task record other than <self-meta> that
# claims this pane (by window, or by Herdr session and pane id), this home or
# worktree, or a worktree at least as deep around <cwd>. Paths compare
# physically. Returns 0 with no claim, printing the state directory of each
# local secondmate home a record there names (one per line, from the same read
# that judged the record, Main 1874 rule S); 1 printing the claiming record; 2
# printing what could not be read: an unreadable directory or record is never
# "no claim".
fm_launch_proof_state_claimed() { # <self-meta> <state-dir> <cwd> <home> <root>
  local self=$1 dir=$2 cwd=$3 home=$4 root=$5 target session pane peer path bytes named homes=''
  target=$(fm_launch_proof_field "$self" window)
  session=${target%%:*}; pane=${target#*:}
  { [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ]; } || { printf 'the task records at %s' "$dir"; return 2; }
  for peer in "$dir"/*.meta; do
    [ -e "$peer" ] || [ -L "$peer" ] || continue
    if [ "$peer" -ef "$self" ]; then
      # The record under judgment names its own home from this decision's bytes.
      if [ "$(fm_launch_proof_field "$self" kind)" = secondmate ] && [ -z "$(fm_launch_proof_field "$self" remote_host)" ]; then
        named=$(fm_launch_proof_field "$self" home)
        [ -z "$named" ] || homes+="$named/state"$'\n'
      fi
      continue
    fi
    # One strict read of each peer (Main 1856 F7): a failed, empty or
    # NUL-bearing read is unknown, never "no claim". The homes it names come
    # from the same read, so no second read can disagree (Main 1874 rule S).
    bytes=$(fm_launch_proof_bytes "$peer") || { printf 'the task record %s' "$peer"; return 2; }
    bytes=${bytes%x}
    [ -z "$(fm_launch_proof_bytes_field "$bytes" remote_host)" ] || continue
    if [ "$(fm_launch_proof_bytes_field "$bytes" kind)" = secondmate ]; then
      named=$(fm_launch_proof_bytes_field "$bytes" home)
      [ -z "$named" ] || homes+="$named/state"$'\n'
    fi
    if [ -n "$target" ] && [ "$(fm_launch_proof_bytes_field "$bytes" window)" = "$target" ]; then
      printf '%s' "${peer##*/}"; return 1
    fi
    if [ -n "$session" ] && [ "$(fm_launch_proof_bytes_field "$bytes" herdr_session)" = "$session" ] \
      && [ "$(fm_launch_proof_bytes_field "$bytes" herdr_pane_id)" = "$pane" ]; then
      printf '%s' "${peer##*/}"; return 1
    fi
    for path in "$(fm_launch_proof_physical_dir "$(fm_launch_proof_bytes_field "$bytes" home)")" \
      "$(fm_launch_proof_physical_dir "$(fm_launch_proof_bytes_field "$bytes" worktree)")"; do
      [ -n "$path" ] || continue
      if { [ -n "$home" ] && [ "$path" = "$home" ]; } || { [ -n "$root" ] && [ "$path" = "$root" ]; }; then
        printf '%s' "${peer##*/}"; return 1
      fi
    done
    path=$(fm_launch_proof_physical_dir "$(fm_launch_proof_bytes_field "$bytes" worktree)")
    [ -n "$path" ] || continue
    case "$cwd/" in
      "$path"/*)
        if [ "${#path}" -ge "${#root}" ]; then printf '%s' "${peer##*/}"; return 1; fi
        ;;
    esac
  done
  printf '%s' "$homes"
  return 0
}

# The claim inventory for <meta> (Main 1634 D2, Main 1716 (C)). Locally: the
# record's own state directory, every local home the root inventory reaches,
# and each local secondmate home a reached record names, followed to a fixed
# point; the cycle guard is an exact set of physical paths, never a joined
# string. On the host attribution verb (FM_LAUNCH_PROOF_VERB_PATH=1): only the
# record's own state directory and the state directory of the home it names,
# with no root walk and no bin/fm-wake-lib.sh. Returns as
# fm_launch_proof_state_claimed does.
fm_launch_proof_claims() { # <meta> <cwd> <home> <root>
  local meta=$1 cwd=$2 home=$3 root=$4 state named inventory dir key seen_dir known i=0 rc out
  local -a queue=() seen=()
  state=$(dirname -- "$meta")
  queue=("$state")
  if [ -n "${FM_LAUNCH_PROOF_VERB_PATH:-}" ]; then
    named=$(fm_launch_proof_field "$meta" home)
    [ -z "$named" ] || queue+=("$named/state")
  else
    inventory=$(fm_launch_proof_claim_states "$meta") || { printf 'the local home inventory (%s)' "$inventory"; return 2; }
    while IFS= read -r dir; do
      [ -z "$dir" ] || queue+=("$dir")
    done <<< "$inventory"
  fi
  while [ "$i" -lt "${#queue[@]}" ]; do
    dir=${queue[$i]}
    i=$((i + 1))
    key=$(fm_launch_proof_physical_dir "$dir")
    [ -n "$key" ] || key=$dir
    known=0
    for seen_dir in "${seen[@]+"${seen[@]}"}"; do
      [ "$seen_dir" != "$key" ] || known=1
    done
    [ "$known" = 0 ] || continue
    seen+=("$key")
    rc=0
    out=$(fm_launch_proof_state_claimed "$meta" "$dir" "$cwd" "$home" "$root") || rc=$?
    [ "$rc" = 0 ] || { printf '%s' "$out"; return "$rc"; }
    [ -z "${FM_LAUNCH_PROOF_VERB_PATH:-}" ] || continue
    # The secondmate homes come from the claim scan's own read of each record;
    # no record is read a second time.
    while IFS= read -r named; do
      [ -z "$named" ] || queue+=("$named")
    done <<< "$out"
  done
  return 0
}

# The executable path of <pid>, read by proc_pidpath without its environment.
# Fails on a host other than macOS, for a pid that cannot be read, or for an
# empty path. Prints the path.
fm_launch_proof_pid_exe() { # <pid>
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  [ "$(uname -s)" = Darwin ] || return 1
  python3 -I -c '
import ctypes, sys
lib = ctypes.CDLL("/usr/lib/libproc.dylib")
lib.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
lib.proc_pidpath.restype = ctypes.c_int
buf = ctypes.create_string_buffer(4096)
n = lib.proc_pidpath(int(sys.argv[1]), buf, 4096)
if n <= 0 or b"\0" in buf.raw[:n]:
    sys.exit(1)
sys.stdout.buffer.write(buf.raw[:n])
' "$1" 2>/dev/null
}

# Whether <kid>, a live group member whose environment cannot be read, is the
# agent's own platform helper (caffeinate, a tool shell): a proven descendant of
# <pid> (fm_launch_proof_chain from <kid> to <pid>, every link re-read live),
# whose executable path, read without its environment, is a platform binary
# under /bin, /usr/bin, /usr/sbin or /System (not /System/Volumes, which holds
# the writable data volume). Any failed read is no proof.
fm_launch_proof_platform_descendant() { # <process-table> <pid> <kid>
  local path
  fm_launch_proof_chain "$1" "$3" "$2" || return 1
  path=$(fm_launch_proof_pid_exe "$3") || return 1
  case "$path" in *$'\n'*|*/./*|*/../*|*/.|*/..|/System/Volumes/*) return 1 ;; esac
  case "$path" in /bin/?*|/usr/bin/?*|/usr/sbin/?*|/System/?*) return 0 ;; esac
  return 1
}

# Whether <kid>, a member of process group <group> in the table, has exited, on
# positive proof only: kill -0 finds no such process (ESRCH), ps shows it
# exited and not reaped (state Z), or its pid now belongs to another process
# group (reused). A start-time difference is no proof. A live member of
# <group>, and any failed or unclear read, is never gone.
fm_launch_proof_member_gone() { # <group> <kid>
  local err row stat pgid
  case "$2" in ''|*[!0-9]*) return 1 ;; esac
  if ! err=$(export LC_ALL=C; kill -0 "$2" 2>&1); then
    case "$err" in *'No such process'*) return 0 ;; esac
  fi
  row=$(set -o pipefail; LC_ALL=C ps -o stat=,pgid= -p "$2" 2>/dev/null) || return 1
  read -r stat pgid _ <<< "$row"
  case "$pgid" in ''|*[!0-9]*) return 1 ;; esac
  case "$stat" in Z*) return 0 ;; esac
  [ "$pgid" != "$1" ]
}

# The refusal checks an agent whose token matches its versioned record must
# pass before it is managed, for every harness (Main 1709 ruling 1, Main 1713
# (1), Main 1716 (A) and (C), Main 1777 (1)). In this order: the process table, each other member of the agent's
# process group (one environment read each: a pin for another generation
# refuses, and an unreadable environment refuses unless the member is the
# agent's platform helper, fm_launch_proof_platform_descendant), the descendant
# rule (every other member is an ancestor of the agent in its group or a proven
# descendant of it), the agent's kernel working directory (the recorded home or
# worktree), and the claim inventory. A member whose own environment or parent
# read fails, and that is positively shown to have exited since the table read,
# is no live member and is skipped (fm_launch_proof_member_gone). None is proof: each can only refuse. E3
# (k), a matching pin keeping its base outcome, applies only after all pass.
# Prints <verdict><TAB><cause>, the cause empty when the verdict's own applies.
fm_launch_proof_token_checks() { # <meta> <pid> <spawn-gen>
  local meta=$1 pid=$2 gen=$3 table group kid environment pinned foreign='' unread='' rc cwd home root claim seen
  local -a members=()
  table=$(set -o pipefail; LC_ALL=C ps -axo pid=,ppid=,pgid= 2>/dev/null) && [ -n "$table" ] || {
    printf 'unknown\tthe process table could not be read completely, so the agent'"'"'s process group cannot be judged'
    return
  }
  # Every row must carry a pid, a parent and a group (Main 1856 F8): a short or
  # malformed row may hide a member, so the table is no evidence.
  awk 'NF != 3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ {bad = 1} END {exit bad}' <<< "$table" || {
    printf 'unknown\tthe process table has a short or malformed row, so the agent'"'"'s process group cannot be judged'
    return
  }
  group=$(awk -v p="$pid" '$1 == p {print $3; exit}' <<< "$table")
  [ -n "$group" ] || { printf 'unknown\tthe process table does not list the attributed agent %s' "$pid"; return; }
  while IFS= read -r kid; do
    [ -z "$kid" ] || members+=("$kid")
  done < <(awk -v g="$group" -v p="$pid" '$3 == g && $1 != p {print $1}' <<< "$table")
  # Every process Herdr listed in the foreground is a member too, judged from
  # this one table: one the table lacks is unaccounted for, never exited
  # (Main 1807 (3)).
  for kid in ${FM_LAUNCH_PROOF_LISTED:-}; do
    [ "$kid" != "$pid" ] || continue
    awk -v p="$kid" '$1 == p {found=1} END {exit !found}' <<< "$table" || {
      printf 'unknown\tthe listed foreground process %s is missing from the process-group table, so the agent'"'"'s process group cannot be judged' "$kid"
      return
    }
    seen=0
    for rc in "${members[@]+"${members[@]}"}"; do [ "$rc" != "$kid" ] || seen=1; done
    [ "$seen" = 1 ] || members+=("$kid")
  done
  for kid in "${members[@]+"${members[@]}"}"; do
    if environment=$(fm_remote_herdr_process_env "$kid") \
      && printf '%s\n' "$environment" | grep -Eq '^(PATH|HOME)='; then
      pinned=$(printf '%s\n' "$environment" | sed -n 's/^FM_SPAWN_GEN=//p')
      if [ -n "$pinned" ] && [ "$pinned" != "$gen" ] && [ -z "$foreign" ]; then foreign=$kid; fi
    elif [ -z "$unread" ] && ! fm_launch_proof_platform_descendant "$table" "$pid" "$kid" \
      && ! fm_launch_proof_member_gone "$group" "$kid"; then
      unread=$kid
    fi
  done
  [ -z "$foreign" ] || { printf 'pinned-elsewhere\t'; return; }
  [ -z "$unread" ] || {
    printf 'unknown\tthe environment of live group process %s cannot be read, so the agent'"'"'s process group cannot be judged' "$unread"
    return
  }
  for kid in "${members[@]+"${members[@]}"}"; do
    rc=0; fm_launch_proof_chain "$table" "$pid" "$kid" || rc=$?
    if [ "$rc" = 1 ]; then rc=0; fm_launch_proof_chain "$table" "$kid" "$pid" || rc=$?; fi
    case "$rc" in
      0) ;;
      2)
        ! fm_launch_proof_member_gone "$group" "$kid" || continue
        printf 'unknown\tthe parent chain of live group process %s changed between reads' "$kid"; return ;;
      *) printf 'contested\tlive group process %s is not the agent, its launcher, or a proven descendant of the agent' "$kid"; return ;;
    esac
  done
  cwd=$(fm_launch_proof_pid_cwd "$pid") || {
    printf 'unknown\tthe agent'"'"'s kernel working directory cannot be read'
    return
  }
  home=$(fm_launch_proof_physical_dir "$(fm_launch_proof_field "$meta" home)")
  root=$(fm_launch_proof_physical_dir "$(fm_launch_proof_field "$meta" worktree)")
  { [ -n "$root" ] && [ "$cwd" = "$root" ]; } || { [ -n "$home" ] && [ "$cwd" = "$home" ]; } || {
    printf 'contested\tthe agent'"'"'s working directory is not this task'"'"'s recorded home or worktree'
    return
  }
  rc=0
  claim=$(fm_launch_proof_claims "$meta" "$cwd" "$home" "$root") || rc=$?
  case "$rc" in
    0) printf 'managed\t' ;;
    1) printf 'contested\tanother task record (%s) claims this pane, this home or worktree, or a worktree around the agent'"'"'s working directory' "$claim" ;;
    *) printf 'unknown\tthe local task records that could claim this pane cannot all be read: %s' "$claim" ;;
  esac
}

fm_launch_proof_herdr() { # <meta> -> managed|unmanaged|pinned-elsewhere|contested|unknown
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local judged
  judged=$(fm_launch_proof_herdr_judge "$1")
  printf '%s' "${judged%%$'\t'*}"
}

# The verdict with its cause: <verdict><TAB><cause>, the cause empty when the
# verdict's own wording (fm_launch_proof_refusal_cause) applies.
fm_launch_proof_herdr_judge() { # <meta>
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local out pid FM_LAUNCH_PROOF_LISTED
  fm_launch_proof_record_ensure "$1"
  out=$(fm_launch_proof_herdr_pid "$1" with-listed) || { printf 'unknown\t'; return; }
  pid=${out%%$'\n'*}
  FM_LAUNCH_PROOF_LISTED=''
  [ "$out" = "$pid" ] || FM_LAUNCH_PROOF_LISTED=${out#*$'\n'}
  fm_launch_proof_herdr_verdict_judge "$1" "$pid"
}

# One recovery inspection from one record read: <legacy 0|1><TAB><pid or
# empty><TAB><verdict><TAB><cause>, so the caller's legacy branch, its
# identity and the verdict all rest on the same bytes (Main 1807 (2)). The
# record must name <expected-endpoint>, the endpoint the caller inspected and
# will act on (Main 1874 finding 2); otherwise, or with no endpoint named, the
# inspection is unknown with that cause and never legacy.
fm_launch_proof_recovery_judge() { # <meta> <expected-endpoint>
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local out pid='' legacy=0 judged FM_LAUNCH_PROOF_LISTED=''
  fm_launch_proof_record_ensure "$1"
  if [ -z "${2:-}" ] || [ "$(fm_launch_proof_field "$1" window)" != "$2" ]; then
    printf '0\t\tunknown\tits launch record does not name the endpoint this inspection read (%s)' "${2:-none named}"
    return
  fi
  ! fm_launch_proof_record_legacy "$1" || legacy=1
  if out=$(fm_launch_proof_herdr_pid "$1" with-listed); then
    pid=${out%%$'\n'*}
    [ "$out" = "$pid" ] || FM_LAUNCH_PROOF_LISTED=${out#*$'\n'}
    judged=$(fm_launch_proof_herdr_verdict_judge "$1" "$pid")
  else
    judged=$(printf 'unknown\t')
  fi
  printf '%s\t%s\t%s' "$legacy" "$pid" "$judged"
}

fm_launch_proof_herdr_verdict() { # <meta> <pid> -> managed|unmanaged|pinned-elsewhere|contested|unknown
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local judged
  judged=$(fm_launch_proof_herdr_verdict_judge "$1" "$2")
  printf '%s' "${judged%%$'\t'*}"
}

# The causes an omp refusal names (Main 1901): no matching pin, which no route
# can repair, or a matching pin whose session record does not prove the live
# process's current session.
FM_LAUNCH_PROOF_OMP_UNPINNED_CAUSE='live omp agent carries no launch pin matching this record (a native resume or restore), and there is no omp adoption route, so nothing can authorize it'
FM_LAUNCH_PROOF_OMP_SESSION_CAUSE='live omp agent carries this record'"'"'s launch pin, but its omp session record does not name this live process and its current session'
fm_launch_proof_herdr_verdict_judge() { # <meta> <pid>
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local meta=$1 pid=$2 proof gen verdict record session_bytes task_file current_file harness table token
  fm_launch_proof_record_ensure "$meta"
  proof=$(fm_launch_proof_record_proof "$meta") \
    || { printf 'unknown\t%s' "$FM_LAUNCH_PROOF_RECORD_CAUSE"; return; }
  case "$proof" in
    absent) proof='' ;;
    'proof=env-v1') proof='env-v1' ;;
    *) printf 'unknown\t%s' "$FM_LAUNCH_PROOF_RECORD_CAUSE"; return ;;
  esac
  gen=$(fm_launch_proof_field "$meta" spawn_gen)
  harness=$(fm_launch_proof_field "$meta" harness)
  if [ "$harness" = claude ] && [ "$proof" = env-v1 ]; then
    # The launch record and its token are the only proof: one read of the agent;
    # an unpinned agent then gets one read of each other group member, and a
    # matching token the refusal checks.
    verdict=$(fm_launch_proof_pid_classify "$pid" "$gen")
    case "$verdict" in
      managed) fm_launch_proof_token_checks "$meta" "$pid" "$gen"; return ;;
      unmanaged)
        # The same complete-table rule as the refusal checks (Main 1874): a
        # failed read or a short row could hide a member pinned elsewhere,
        # whose next action differs, so it is unknown.
        if ! table=$(set -o pipefail; LC_ALL=C ps -axo pid=,ppid=,pgid= 2>/dev/null) || [ -z "$table" ] \
          || ! awk 'NF != 3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ {bad = 1} END {exit bad}' <<< "$table"; then
          printf 'unknown\tthe process table could not be read completely, so the agent'"'"'s process group cannot be judged'
          return
        fi
        if fm_launch_proof_group_pinned_elsewhere "$gen" "$table" "$pid"; then
          verdict='pinned-elsewhere'
        fi
        ;;
    esac
    printf '%s\t' "$verdict"
    return
  fi
  verdict=$(fm_launch_proof_pid "$pid" "$gen")
  # A versioned record whose live token matches is managed, for every harness,
  # only after the same refusal checks (Main 1777 (1)); a legacy record keeps
  # its base outcome.
  token=''
  [ "$verdict" != managed ] || [ "$proof" != env-v1 ] || token=1
  if [ "$harness" = omp ]; then
    # There is no omp adoption route (Main 1874, Main 1901): an omp agent
    # without its matching pin is unmanaged, and nothing can authorize it.
    case "$verdict" in
      unmanaged) printf 'unmanaged\t%s' "$FM_LAUNCH_PROOF_OMP_UNPINNED_CAUSE"; return ;;
      unknown) printf 'unknown\t'; return ;;
    esac
    # A current activation for this live PID is mandatory: the session record,
    # read once, must name this PID and its current session (Main 1874 rule S).
    session_bytes=$(fm_launch_proof_bytes "${meta%.meta}.omp-session.json") \
      || { printf 'unmanaged\t%s' "$FM_LAUNCH_PROOF_OMP_SESSION_CAUSE"; return; }
    session_bytes=${session_bytes%x}
    record=$(printf '%s' "$session_bytes" | jq -ec --arg gen "$gen" --argjson pid "$pid" '
      select(.version == 1 and .spawn_gen == $gen and .pid == $pid)
      | select(all(.task_session_file, .current_session_file;
          type == "string" and startswith("/") and (explode | all(. >= 32))))' 2>/dev/null) \
      || { printf 'unmanaged\t%s' "$FM_LAUNCH_PROOF_OMP_SESSION_CAUSE"; return; }
    task_file=$(printf '%s' "$record" | jq -r '.task_session_file')
    current_file=$(printf '%s' "$record" | jq -r '.current_session_file')
    if [ ! -f "$task_file" ] || [ ! -f "$current_file" ] \
      || [ ! "$task_file" -ef "$current_file" ]; then
      printf 'unmanaged\t%s' "$FM_LAUNCH_PROOF_OMP_SESSION_CAUSE"
      return
    fi
  fi
  if [ -n "$token" ]; then
    fm_launch_proof_token_checks "$meta" "$pid" "$gen"
    return
  fi
  case "$verdict" in
    managed|unknown) printf '%s\t' "$verdict" ;;
    unmanaged)
      if [ "$harness" = omp ]; then
        printf 'unmanaged\t'
      else
        printf 'unknown\t'
      fi
      ;;
  esac
}

# The one wording for a refused live agent: the cause the verdict names and the
# next action. unmanaged is a readable environment without a launch token;
# pinned-elsewhere has a token for another launch generation in its group;
# contested is a matching token that failed a refusal check; unknown is a
# reading that could not be completed. A judged <cause> replaces the verdict's
# own wording.
fm_launch_proof_refusal_cause() { # <unmanaged|pinned-elsewhere|contested|unknown> [<cause>]
  [ -z "${2:-}" ] || { printf '%s' "$2"; return; }
  case "$1" in
    contested) printf 'live agent carries this record'"'"'s launch pin, but a refusal check failed' ;;
    unmanaged) printf 'live agent is an unpinned native restore: its process environment was readable and carries no launch pin matching this record' ;;
    pinned-elsewhere) printf 'live agent is pinned to another launch generation: a process in its tree carries a launch pin for a different spawn_gen than this record' ;;
    *) printf 'live launch settings are unreadable' ;;
  esac
}

# The next action follows the judged <cause> when one is present, otherwise the
# verdict. Nothing can authorize an unpinned native restore, so its next action
# is the guarded relaunch of a positively stopped agent, or a decision by hand.
fm_launch_proof_refusal_next() { # <unmanaged|pinned-elsewhere|contested|unknown> <meta> [<cause>]
  local id=${2##*/}
  if [ "${3:-}" = "$FM_LAUNCH_PROOF_OMP_SESSION_CAUSE" ]; then
    printf 'the pinned agent may be running a conversation other than its task session; Main inspects the pane and decides the lane by hand'
    return
  fi
  if [ "$1" = unknown ] && [ -n "${3:-}" ]; then
    printf 'retry once the cause named above is cleared, or decide the lane by hand'
    return
  fi
  case "$1" in
    contested) printf 'something other than this task'"'"'s own agent tree, directory or record shares its pane; Main inspects the pane and decides the lane by hand' ;;
    unmanaged) printf 'no Firstmate launch record proves it, since a native restore runs without the launch token, so nothing can authorize it; stop it by hand in its pane and then relaunch it with "bin/fm-control.sh %s relaunch", or decide the lane by hand' "${id%.meta}" ;;
    pinned-elsewhere) printf 'the process belongs to another launch; Main inspects the pane and decides the lane by hand' ;;
    *) printf 'no foreground process could be attributed in the recorded pane, or its environment could not be read; retry once it can be read, or decide the lane by hand' ;;
  esac
}

# Lifecycle authorization for a live recorded Herdr agent, with the refusal
# cause and next action on stdout when it fails for a claude or omp record
# (Main 1901: an omp record that adoption once repaired now refuses with its
# named reason). A legacy record (no launch_proof line at all: published
# before launch proofs existed) has no pin to compare; any present value other
# than a known proof, and a record that cannot be read as one record with at
# most one launch_proof, refuses. The record and the verdict are each read
# exactly once. <expected-endpoint> is mandatory (Main 1874 finding 2): it is
# the endpoint the caller will act on, and the record this decision read must
# name exactly it, so a proof is never of one endpoint while the caller keeps
# another; a call without it refuses.
fm_launch_proof_herdr_refusal() { # <meta> <expected-endpoint>
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local proof judged verdict harness
  if [ -z "${2:-}" ]; then
    printf 'no endpoint was named to bind the launch proof to, so nothing proves the agent the action would reach; refusing'
    return 1
  fi
  fm_launch_proof_record_ensure "$1"
  harness=$(fm_launch_proof_field "$1" harness)
  # The proof is of the endpoint the action targets (Main 1856 F2): the record
  # this decision read must name exactly that endpoint.
  if [ "$(fm_launch_proof_field "$1" window)" != "$2" ]; then
    printf 'its launch record no longer names the endpoint this action targets (%s); refusing; retry once the record is settled, or decide the lane by hand' "$2"
    return 1
  fi
  if ! proof=$(fm_launch_proof_record_proof "$1") || { [ "$proof" != absent ] && [ "$proof" != proof=env-v1 ]; }; then
    case "$harness" in claude|omp)
      printf '%s; %s' "$FM_LAUNCH_PROOF_RECORD_CAUSE" "$(fm_launch_proof_refusal_next unknown "$1" "$FM_LAUNCH_PROOF_RECORD_CAUSE")" ;;
    esac
    return 1
  fi
  [ "$proof" != absent ] || return 0
  judged=$(fm_launch_proof_herdr_judge "$1")
  verdict=${judged%%$'\t'*}
  [ "$verdict" != managed ] || return 0
  case "$harness" in claude|omp)
    printf '%s; %s' "$(fm_launch_proof_refusal_cause "$verdict" "${judged#*$'\t'}")" \
      "$(fm_launch_proof_refusal_next "$verdict" "$1" "${judged#*$'\t'}")" ;;
  esac
  return 1
}

fm_launch_proof_herdr_authorizes() { # <meta> <expected-endpoint>
  fm_launch_proof_herdr_refusal "$@" >/dev/null
}
