#!/usr/bin/env bash
# Proof that a recorded Herdr agent came through Firstmate's launch boundary.
# fm-spawn stamps FM_SPAWN_GEN with the record's spawn_gen and records
# launch_proof=env-v1. The live PID's pin must match that recorded incarnation.
# For omp, a matching pin also requires current-session proof. Explicit adopt
# repairs only a record whose PID is gone or no longer an omp process and
# whose live process has a readable environment without a usable pin; without
# a pin, every adoption proof is rechecked before the repaired live PID and
# session-file identity authorize lifecycle, and a pin for another generation
# never passes that recheck.
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
# An adopted omp process carries no token and keeps its own adoption proofs.
# There is no claude adoption route (Main 1637).
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

# Publication eligibility is stricter than a lifecycle verdict: an unknown
# environment must not let adoption hide the task anchor from a pinned writer.
# Readers keep their existing managed/unmanaged/unknown contract. Prints nothing.
fm_launch_proof_pid_unpinned() { # <pid>
  local environment
  environment=$(fm_remote_herdr_process_env "$1") || return 1
  printf '%s\n' "$environment" | grep -Eq '^(PATH|HOME)=' || return 1
  ! printf '%s\n' "$environment" | grep -Eq '^FM_SPAWN_GEN=.+$'
}

# Succeeds only for a live process whose readable executable name or argv[0]
# has basename omp. Installation directory names are not identity. Prints nothing.
fm_launch_proof_pid_is_omp() { # <pid>
  local pid=$1 comm args name
  comm=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null) \
    && args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || return 1
  for name in "$comm" "${args%% *}"; do
    [ "${name##*/}" != omp ] || return 0
  done
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

# Rebuild candidate proof only from this home's recorded endpoint. The native
# session reference supplies a file candidate, never authority on its own.
# All five adoption checks live here so lifecycle readers can recheck them too.
# One record read (Main 1874 rule S): the window, the generation and the
# Python proof all rest on this decision's bytes of <meta> (a caller's when it
# holds them), and the Python proof refuses any other bytes. Every caller reads
# the session record once and passes the sha256 of those bytes in
# FM_LAUNCH_PROOF_EXPECTED_SESSION_SHA256 (mandatory, as the endpoint is for
# fm_launch_proof_herdr_refusal), and the proof refuses any other.
fm_launch_proof_omp_adoption() { # <meta> -> candidate session-record JSON
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local meta=$1 target session pane pid reference gen sha
  fm_launch_proof_record_ensure "$meta"
  [ "$FM_LAUNCH_PROOF_RECORD_OK" = 1 ] || {
    echo 'adopt refused: record proof needs one readable task record without NUL bytes' >&2; return 1;
  }
  target=$(fm_launch_proof_bytes_exact_value "$FM_LAUNCH_PROOF_RECORD_BYTES" window) || {
    echo 'adopt refused: endpoint proof needs one recorded window' >&2; return 1;
  }
  gen=$(fm_launch_proof_field "$meta" spawn_gen)
  sha=$(set -o pipefail; printf '%s' "$FM_LAUNCH_PROOF_RECORD_BYTES" | shasum -a 256 | cut -d' ' -f1) && [ -n "$sha" ] || {
    echo 'adopt refused: record proof needs the digest of the task record it read' >&2; return 1;
  }
  session=${target%%:*}; pane=${target#*:}
  if ! fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null \
    | jq -e --arg pane "$pane" '.result.pane.pane_id == $pane' >/dev/null; then
    echo 'adopt refused: endpoint proof needs the recorded pane to exist and be readable' >&2; return 1
  fi
  pid=$(fm_launch_proof_herdr_pid "$meta") || {
    echo 'adopt refused: foreground proof needs one uniquely resolved live process in the recorded pane' >&2; return 1;
  }
  # A lingering registration must not turn whatever now runs in the worktree
  # into a lifecycle target: the resolved process itself has to be omp.
  fm_launch_proof_pid_is_omp "$pid" || {
    echo 'adopt refused: process proof needs the resolved foreground process to be a readable omp process' >&2; return 1;
  }
  if fm_launch_proof_pid_pinned_elsewhere "$pid" "$gen"; then
    echo 'adopt refused: generation proof needs the live process not to be pinned to another launch generation' >&2; return 1
  fi
  reference=$(fm_backend_herdr_pane_agent_session_ref "$session" "$pane") || {
    echo 'adopt refused: session proof needs a readable omp session-file registration on the recorded pane' >&2; return 1;
  }
  case "$reference" in
    omp$'\t'/*) reference=${reference#*$'\t'} ;;
    *) echo 'adopt refused: session proof needs an absolute omp session-file registration' >&2; return 1 ;;
  esac
  FM_LAUNCH_PROOF_EXPECTED_RECORD_SHA256=$sha python3 - "$meta" "$pid" "$reference" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def metadata(path, expected_sha256=None):
    require(path.is_file() and not path.is_symlink(),
            f"record proof needs a readable regular metadata file: {path.name}")
    raw = path.read_bytes()
    # The proof rests on the bytes the shell decision read, so an A-to-B-to-A
    # rewrite cannot slip a B proof past an A read (Main 1856 (a), Main 1874).
    if expected_sha256 is not None:
        import hashlib
        require(hashlib.sha256(raw).hexdigest() == expected_sha256,
                "record proof needs the same record bytes the caller read")
    # A NUL (or the \001 the shell reader maps it to) makes a record unknown,
    # never a record without a claim (Main 1856 F6/F7, Main 1874).
    require(b"\0" not in raw and b"\x01" not in raw,
            f"record proof needs task records without NUL bytes: {path.name}")
    fields = {}
    for line in raw.decode().splitlines():
        key, sep, value = line.partition("=")
        if sep:
            fields.setdefault(key, []).append(value)
    return fields


def single(fields, key):
    values = fields.get(key, [])
    require(len(values) == 1 and values[0] and not any(ord(c) < 32 for c in values[0]),
            f"metadata proof needs one nonempty {key}")
    return values[0]


def remote(fields):
    values = fields.get("remote_host", [])
    require(len(values) <= 1, "unique-claim proof needs an unambiguous remote_host field")
    return any(values)


def inside(path, root):
    return path == root or root in path.parents


try:
    meta = Path(sys.argv[1])
    pid = int(sys.argv[2])
    live = Path(sys.argv[3])
    expected_record = os.environ.get("FM_LAUNCH_PROOF_EXPECTED_RECORD_SHA256", "")
    require(expected_record != "", "record proof needs the digest of the task record the shell read")
    fields = metadata(meta, expected_record)
    require(single(fields, "backend") == "herdr" and single(fields, "harness") == "omp"
            and not remote(fields), "endpoint proof needs a local Herdr omp task")
    session = single(fields, "herdr_session")
    pane = single(fields, "herdr_pane_id")
    target = single(fields, "window")
    require(target == f"{session}:{pane}", "endpoint proof needs window and herdr_pane_id to agree")
    root = Path(single(fields, "worktree"))
    require(root.is_absolute() and root.is_dir(), "workspace proof needs an existing absolute worktree")
    root = root.resolve(strict=True)
    gen = single(fields, "spawn_gen")
    record_path = meta.with_suffix(".omp-session.json")
    require(record_path.is_file() and not record_path.is_symlink(),
            "generation proof needs an existing regular session record")
    session_raw = record_path.read_bytes()
    expected_session = os.environ.get("FM_LAUNCH_PROOF_EXPECTED_SESSION_SHA256", "")
    require(expected_session != "", "generation proof needs the digest of the session record the caller read")
    import hashlib
    require(hashlib.sha256(session_raw).hexdigest() == expected_session,
            "generation proof needs the same session record bytes the caller read")
    old = json.loads(session_raw.decode())
    require(isinstance(old, dict) and old.get("version") == 1 and old.get("spawn_gen") == gen,
            "generation proof needs the existing record spawn_gen to equal metadata spawn_gen")

    # Read cwd from the resolved PID, not the pane's creation-time directory.
    result = subprocess.run(["lsof", "-w", "-a", "-p", str(pid), "-d", "cwd", "-F", "pn0"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
    parts = [p.lstrip(b"\n") for p in result.stdout.split(b"\0") if p.strip(b"\n")]
    require([p for p in parts if p.startswith(b"p")] == [f"p{pid}".encode()],
            "workspace proof needs the resolved foreground PID's kernel cwd")
    names = [p[1:] for p in parts if p.startswith(b"n")]
    require(len(names) == 1, "workspace proof needs exactly one readable foreground cwd")
    # lsof escapes backslashes and nonprinting/non-ASCII bytes even with -F0.
    def unescape(match):
        token = match.group(0)[1:]
        if token == b"\\":
            return b"\\"
        if token.startswith(b"x"):
            return bytes([int(token[1:], 16)])
        escapes = {b"a": b"\a", b"b": b"\b", b"f": b"\f", b"n": b"\n",
                   b"r": b"\r", b"t": b"\t", b"v": b"\v"}
        require(token in escapes, "workspace proof needs an unambiguous kernel cwd pathname")
        return escapes[token]
    cwd = Path(os.fsdecode(re.sub(rb"\\(?:x[0-9a-fA-F]{2}|.)", unescape, names[0])))
    require(cwd.is_absolute() and cwd.is_dir(), "workspace proof needs an existing absolute foreground cwd")
    cwd = cwd.resolve(strict=True)
    require(inside(cwd, root), "workspace proof needs the foreground cwd inside this task's recorded worktree")

    # The deepest containing worktree wins; ties are not exclusive ownership.
    # scandir must succeed: glob can silently turn an unreadable directory
    # into an empty inventory, which would not prove exclusive ownership.
    try:
        with os.scandir(meta.parent) as entries:
            peers = sorted(Path(entry.path) for entry in entries if entry.name.endswith(".meta"))
    except OSError:
        raise ValueError("unique-claim proof needs a readable complete inventory of local task metadata") from None
    for other in peers:
        if other == meta:
            continue
        peer = metadata(other)
        if remote(peer):
            continue
        require(target not in peer.get("window", []) and not
                (session in peer.get("herdr_session", []) and pane in peer.get("herdr_pane_id", [])),
                f"unique-claim proof needs no other local task to claim this pane; claimed by {other.stem}")
        if "worktree" not in peer:
            continue
        peer_root = Path(single(peer, "worktree"))
        require(peer_root.is_absolute(), f"workspace proof needs an absolute worktree for {other.stem}")
        peer_root = peer_root.resolve()
        require(not (inside(cwd, peer_root) and len(peer_root.parts) >= len(root.parts)),
                f"workspace proof needs this task to be the unique deepest match; cwd belongs to {other.stem}")

    require(live.is_absolute() and live.is_file() and not any(ord(c) < 32 for c in str(live)),
            "session proof needs an existing absolute live session file")
    current = old.get("current_session_file")
    if old.get("pid") == pid:
        # The extension's record for this exact live process, including its
        # deliberate empty mark, outranks a registration Herdr may have
        # retained from an earlier conversation.
        require(isinstance(current, str) and current != "",
                "current-session proof for the live PID is empty or invalid, which the omp extension writes as unproven; adoption cannot overwrite it")
        require(current.startswith("/")
                and not any(ord(c) < 32 for c in current)
                and Path(current).is_file() and os.path.samefile(current, live),
                "current-session proof contradicts the registered task session for the live PID; adoption needs agreeing current-session evidence")
    task = old.get("task_session_file")
    if task is None or task == "":
        task = str(live)
    require(isinstance(task, str) and task.startswith("/") and not any(ord(c) < 32 for c in task),
            "session proof needs an absolute task_session_file to preserve")
    require(Path(task).is_file() and os.path.samefile(task, live),
            "session proof needs the live session file to identify the preserved task session")
    print(json.dumps(dict(version=1, spawn_gen=gen, pid=pid,
                          task_session_file=task, current_session_file=str(live))))
except (OSError, ValueError, TypeError, subprocess.SubprocessError):
    error = sys.exc_info()[1]
    # Never leak subprocess output, process argv/environment, or a traceback.
    message = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else "readable metadata, session file, and kernel cwd proof are required"
    print(f"adopt refused: {message}", file=sys.stderr)
    sys.exit(1)
PY
}

# The one read of a task record (Main 1634 D1, Main 1807 (2)). One decision
# reads the record's bytes once, and every field it uses comes from those same
# bytes; a nested call in the same decision reuses them. Each entry point
# below declares the three FM_LAUNCH_PROOF_RECORD_* variables local, so the
# bytes live only as long as that decision. A read that needs the file again
# (the omp adoption proof) compares it byte for byte and refuses on a change.
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

# The refusal checks an agent whose token matches its versioned record must
# pass before it is managed, for every harness (Main 1709 ruling 1, Main 1713
# (1), Main 1716 (A) and (C), Main 1777 (1)). In this order: the process table, each other member of the agent's
# process group (one environment read each: a pin for another generation or an
# unreadable environment refuses, with no descendant exemption), the descendant
# rule (every other member is an ancestor of the agent in its group or a proven
# descendant of it), the agent's kernel working directory (the recorded home or
# worktree), and the claim inventory. None is proof: each can only refuse. E3
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
    elif [ -z "$unread" ]; then
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
      2) printf 'unknown\tthe parent chain of live group process %s changed between reads' "$kid"; return ;;
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

fm_launch_proof_herdr_verdict_judge() { # <meta> <pid>
  local FM_LAUNCH_PROOF_RECORD_PATH=${FM_LAUNCH_PROOF_RECORD_PATH-} FM_LAUNCH_PROOF_RECORD_BYTES=${FM_LAUNCH_PROOF_RECORD_BYTES-} FM_LAUNCH_PROOF_RECORD_OK=${FM_LAUNCH_PROOF_RECORD_OK-}
  local meta=$1 pid=$2 proof gen verdict record session_bytes session_sha task_file current_file adopted refusal=unmanaged harness table token
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
  [ "$verdict" != unknown ] || refusal=unknown
  # A versioned record whose live token matches is managed, for every harness,
  # only after the same refusal checks (Main 1777 (1)); a legacy record keeps
  # its base outcome. Adoption carries no token and has its own proofs.
  token=''
  [ "$verdict" != managed ] || [ "$proof" != env-v1 ] || token=1
  if [ "$harness" = omp ]; then
    # A current activation for this live PID is mandatory, even after adoption.
    # The session record is read once (Main 1874 rule S): the adoption proof
    # gets the digest of these bytes and refuses any other.
    session_bytes=$(fm_launch_proof_bytes "${meta%.meta}.omp-session.json") \
      || { printf '%s\t' "$refusal"; return; }
    session_bytes=${session_bytes%x}
    record=$(printf '%s' "$session_bytes" | jq -ec --arg gen "$gen" --argjson pid "$pid" '
      select(.version == 1 and .spawn_gen == $gen and .pid == $pid)
      | select(all(.task_session_file, .current_session_file;
          type == "string" and startswith("/") and (explode | all(. >= 32))))' 2>/dev/null) \
      || { printf '%s\t' "$refusal"; return; }
    task_file=$(printf '%s' "$record" | jq -r '.task_session_file')
    current_file=$(printf '%s' "$record" | jq -r '.current_session_file')
    if [ ! -f "$task_file" ] || [ ! -f "$current_file" ] \
      || [ ! "$task_file" -ef "$current_file" ]; then
      printf '%s\t' "$refusal"
      return
    fi
    if [ "$verdict" = unmanaged ]; then
      # Adoption is a second authorization route, not a relaxed environment
      # comparison. A valid record alone still cannot license lifecycle input.
      # The adoption proof rests on this decision's task record bytes (in scope)
      # and on the session record bytes read above; it refuses any other.
      session_sha=$(set -o pipefail; printf '%s' "$session_bytes" | shasum -a 256 | cut -d' ' -f1) && [ -n "$session_sha" ] \
        || { printf '%s\t' "$refusal"; return; }
      adopted=$(FM_LAUNCH_PROOF_EXPECTED_SESSION_SHA256=$session_sha fm_launch_proof_omp_adoption "$meta" 2>/dev/null) \
        || { printf '%s\t' "$refusal"; return; }
      # The record must still hold those bytes after the proof.
      fm_launch_proof_record_unchanged "$meta" \
        || { printf 'unknown\t%s' "$FM_LAUNCH_PROOF_RECORD_CAUSE"; return; }
      [ "$(printf '%s' "$adopted" | jq -r '.pid')" = "$pid" ] \
        && [ "$current_file" -ef "$(printf '%s' "$adopted" | jq -r '.current_session_file')" ] \
        || { printf '%s\t' "$refusal"; return; }
      verdict=managed
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

# Nothing can authorize an unpinned native restore, so its next action is the
# guarded relaunch of a positively stopped agent, or a decision by hand.
fm_launch_proof_refusal_next() { # <unmanaged|pinned-elsewhere|contested|unknown> <meta>
  local id=${2##*/}
  case "$1" in
    contested) printf 'something other than this task'"'"'s own agent tree, directory or record shares its pane; Main inspects the pane and decides the lane by hand' ;;
    unmanaged) printf 'no Firstmate launch record proves it, since a native restore runs without the launch token, so nothing can authorize it; stop it by hand in its pane and then relaunch it with "bin/fm-control.sh %s relaunch", or decide the lane by hand' "${id%.meta}" ;;
    pinned-elsewhere) printf 'the process belongs to another launch; Main inspects the pane and decides the lane by hand' ;;
    *) printf 'no foreground process could be attributed in the recorded pane, or its environment could not be read; retry once it can be read, or decide the lane by hand' ;;
  esac
}

# Lifecycle authorization for a live recorded Herdr agent, with the refusal
# cause on stdout when it fails for a claude record (omp's unmanaged verdict
# also covers a matching pin whose session proof failed, so it keeps its
# existing wording). A legacy record (no launch_proof line at all: published
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
    [ "$harness" != claude ] \
      || printf '%s; %s' "$FM_LAUNCH_PROOF_RECORD_CAUSE" "$(fm_launch_proof_refusal_next unknown "$1")"
    return 1
  fi
  [ "$proof" != absent ] || return 0
  judged=$(fm_launch_proof_herdr_judge "$1")
  verdict=${judged%%$'\t'*}
  [ "$verdict" != managed ] || return 0
  [ "$harness" != claude ] \
    || printf '%s; %s' "$(fm_launch_proof_refusal_cause "$verdict" "${judged#*$'\t'}")" \
      "$(fm_launch_proof_refusal_next "$verdict" "$1")"
  return 1
}

fm_launch_proof_herdr_authorizes() { # <meta> <expected-endpoint>
  fm_launch_proof_herdr_refusal "$@" >/dev/null
}
