#!/usr/bin/env bash
# Proof that a recorded Herdr agent came through Firstmate's launch boundary.
# fm-spawn stamps FM_SPAWN_GEN with the record's spawn_gen and records
# launch_proof=env-v1. The live PID's pin must match that recorded incarnation.
# For omp, a matching pin also requires current-session proof. Explicit adopt
# repairs only a record whose PID is gone, and never a live PID pinned to
# another generation; without a pin, every adoption proof is rechecked before
# the repaired live PID and session-file identity authorize lifecycle.
# Native Herdr restore reconstructs argv, not the launch environment/settings.
# Verdicts: managed|unmanaged|unknown. Only managed authorizes lifecycle action
# for a proven record; a legacy record keeps its pre-proof attribution rule.
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

# Publication eligibility is stricter than a lifecycle verdict: an unknown
# environment must not let adoption hide the task anchor from a pinned writer.
# Readers keep their existing managed/unmanaged/unknown contract. Prints nothing.
fm_launch_proof_pid_unpinned() { # <pid>
  local environment
  environment=$(fm_remote_herdr_process_env "$1") || return 1
  printf '%s\n' "$environment" | grep -Eq '^(PATH|HOME)=' || return 1
  ! printf '%s\n' "$environment" | grep -Eq '^FM_SPAWN_GEN=.+$'
}

fm_launch_proof_herdr_pid() { # <meta> -> the attributed live foreground PID
  local meta=$1 target session pane info foreground pid
  local candidates ids='' name argv0 parents group
  target=$(fm_meta_get "$meta" window)
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
    parents=$(ps -axo pid=,ppid= 2>/dev/null | jq -Rnc '
      [inputs | capture("^\\s*(?<pid>[0-9]+)\\s+(?<ppid>[0-9]+)\\s*$")
        | {key:.pid,value:(.ppid | tonumber)}] | from_entries') \
      || return 1
    # A candidate Herdr listed but this later table lacks exited between the
    # reads, so it is dropped. Its pid stays in $ids, so a vanished agent still
    # drops its own children and leaves no survivor; a broken chain still fails.
    candidates=$(printf '%s' "$candidates" | jq -ec --argjson parents "$parents" --argjson group "$group" '
      map(.pid) as $ids
      | def below($pid; $targets; $seen):
          $parents[$pid | tostring] as $parent
          | if $parent == null or ($seen | index($parent)) != null then error("unreadable ancestry")
            elif ($targets | index($parent)) != null then true
            elif $parent <= 1 then false
            elif ($seen | length) >= 64 then error("deep ancestry")
            else below($parent; $targets; $seen + [$parent]) end;
        map(select($parents[.pid | tostring] != null))
        | map(select(below(.pid; $ids; [.pid]) | not))
        | map(select(.pid == $group or below(.pid; [$group]; [.pid])))' 2>/dev/null) \
      || return 1
  fi
  foreground=$(printf '%s' "$candidates" | jq -ec 'select(length == 1) | .[0]') || return 1
  printf '%s' "$foreground" | jq -er '.pid | select(type == "number" and . > 1) | floor' 2>/dev/null
}

# Rebuild candidate proof only from this home's recorded endpoint. The native
# session reference supplies a file candidate, never authority on its own.
# All five adoption checks live here so lifecycle readers can recheck them too.
fm_launch_proof_omp_adoption() { # <meta> -> candidate session-record JSON
  local meta=$1 target session pane pid reference comm args
  target=$(fm_backend_meta_exact_value "$meta" window) || {
    echo 'adopt refused: endpoint proof needs one recorded window' >&2; return 1;
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
  # into a lifecycle target: the resolved process itself has to be an agent.
  comm=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null) \
    && args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) \
    && [ -n "$comm" ] && [ -n "$args" ] \
    && [ "$(fm_agent_process_classify "$comm" "${args%% *}" "$args" "$pid")" = agent ] || {
    echo 'adopt refused: process proof needs the resolved foreground process to be a readable agent process' >&2; return 1;
  }
  if fm_launch_proof_pid_pinned_elsewhere "$pid" "$(fm_meta_get "$meta" spawn_gen)"; then
    echo 'adopt refused: generation proof needs the live process not to be pinned to another launch generation' >&2; return 1
  fi
  reference=$(fm_backend_herdr_pane_agent_session_ref "$session" "$pane") || {
    echo 'adopt refused: session proof needs a readable omp session-file registration on the recorded pane' >&2; return 1;
  }
  case "$reference" in
    omp$'\t'/*) reference=${reference#*$'\t'} ;;
    *) echo 'adopt refused: session proof needs an absolute omp session-file registration' >&2; return 1 ;;
  esac
  python3 - "$meta" "$pid" "$reference" <<'PY'
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def metadata(path):
    require(path.is_file() and not path.is_symlink(),
            f"record proof needs a readable regular metadata file: {path.name}")
    fields = {}
    for line in path.read_text().splitlines():
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
    fields = metadata(meta)
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
    old = json.loads(record_path.read_text())
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

fm_launch_proof_herdr() { # <meta> -> managed|unmanaged|unknown
  local pid
  pid=$(fm_launch_proof_herdr_pid "$1") || { printf unknown; return; }
  fm_launch_proof_herdr_verdict "$1" "$pid"
}

fm_launch_proof_herdr_verdict() { # <meta> <pid> -> managed|unmanaged|unknown
  local meta=$1 pid=$2 proof gen verdict record task_file current_file adopted refusal=unmanaged
  proof=$(fm_meta_get "$meta" launch_proof)
  case "$proof" in
    env-v1|'') ;;
    *) printf unknown; return ;;
  esac
  gen=$(fm_meta_get "$meta" spawn_gen)
  verdict=$(fm_launch_proof_pid "$pid" "$gen")
  [ "$verdict" != unknown ] || refusal=unknown
  if [ "$(fm_meta_get "$meta" harness)" = omp ]; then
    # A current activation for this live PID is mandatory, even after adoption.
    record=$(jq -ec --arg gen "$gen" --argjson pid "$pid" '
      select(.version == 1 and .spawn_gen == $gen and .pid == $pid)
      | select(all(.task_session_file, .current_session_file;
          type == "string" and startswith("/") and (explode | all(. >= 32))))' \
      "${meta%.meta}.omp-session.json" 2>/dev/null) \
      || { printf '%s' "$refusal"; return; }
    task_file=$(printf '%s' "$record" | jq -r '.task_session_file')
    current_file=$(printf '%s' "$record" | jq -r '.current_session_file')
    if [ ! -f "$task_file" ] || [ ! -f "$current_file" ] \
      || [ ! "$task_file" -ef "$current_file" ]; then
      printf '%s' "$refusal"
      return
    fi
    if [ "$verdict" = unmanaged ]; then
      # Adoption is a second authorization route, not a relaxed environment
      # comparison. A valid record alone still cannot license lifecycle input.
      adopted=$(fm_launch_proof_omp_adoption "$meta" 2>/dev/null) \
        || { printf '%s' "$refusal"; return; }
      [ "$(printf '%s' "$adopted" | jq -r '.pid')" = "$pid" ] \
        && [ "$current_file" -ef "$(printf '%s' "$adopted" | jq -r '.current_session_file')" ] \
        || { printf '%s' "$refusal"; return; }
      verdict=managed
    fi
  fi
  case "$verdict" in
    managed|unknown) printf '%s' "$verdict" ;;
    unmanaged)
      if [ "$(fm_meta_get "$meta" harness)" = omp ]; then
        printf unmanaged
      else
        printf unknown
      fi
      ;;
  esac
}

# Lifecycle authorization for a live recorded Herdr agent. A record published
# before launch proofs existed (empty launch_proof) has no pin to compare.
fm_launch_proof_herdr_authorizes() { # <meta>
  [ -z "$(fm_meta_get "$1" launch_proof)" ] || [ "$(fm_launch_proof_herdr "$1")" = managed ]
}
