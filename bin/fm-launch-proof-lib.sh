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
# Verdicts: managed|unmanaged|unknown. Only managed authorizes lifecycle action
# for a proven record; a legacy record keeps its pre-proof attribution rule.
# unmanaged: the environment was readable and carries no matching pin (omp, and
# claude with a versioned launch proof). unknown: it could not be read.
# A restored claude agent is adopted by fm_launch_proof_claude_adoption, a second
# authorization route that rechecks its positive proofs at every use.
# No endpoint discovery: callers supply this home's validated exact endpoint.

_FM_LAUNCH_PROOF_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-remote-herdr-owner-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-remote-herdr-owner-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$_FM_LAUNCH_PROOF_DIR/fm-operational-input.sh"

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

# Succeeds only for a live process whose readable executable name or argv[0]
# has basename <name>. Installation directory names are not identity. Prints nothing.
fm_launch_proof_pid_is_named() { # <pid> <name>
  local pid=$1 want=$2 comm args name
  comm=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null) \
    && args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || return 1
  for name in "$comm" "${args%% *}"; do
    [ "${name##*/}" != "$want" ] || return 0
  done
  return 1
}

fm_launch_proof_pid_is_omp() { # <pid>
  fm_launch_proof_pid_is_named "$1" omp
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
  local meta=$1 target session pane pid reference
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
  # into a lifecycle target: the resolved process itself has to be omp.
  fm_launch_proof_pid_is_omp "$pid" || {
    echo 'adopt refused: process proof needs the resolved foreground process to be a readable omp process' >&2; return 1;
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

# Launchers that forward a native claude restore: `<launcher> run -- <harness
# arguments>` with the harness as the launcher's direct child in its process
# group. The list is empty: the repository launcher bin/fm-teamclaude-launch.sh
# execs claude directly and avoids `teamclaude run`, and config/ is host
# configuration, not repository evidence. A restored lane behind a
# `teamclaude run --` wrapper is therefore refused. An entry needs Main's
# recorded confirmation before it is added.
FM_LAUNCH_PROOF_FORWARDING_LAUNCHERS=''

fm_launch_proof_adopt_refuse() { echo "adopt refused: $1" >&2; return 1; }

# Whether <script> names a launcher on the forwarding allow-list (by basename).
fm_launch_proof_forwarding_launcher() { # <script-or-executable>
  local name=${1##*/}
  [ -n "$name" ] || return 1
  case " $FM_LAUNCH_PROOF_FORWARDING_LAUNCHERS " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

# The directory name claude keeps a project's transcripts under: the working
# directory with every non-alphanumeric character replaced by a dash.
fm_launch_proof_claude_project_dir() { # <absolute-directory>
  printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'
}

# Prints the physical kernel working directory of <pid> (never argv or env).
fm_launch_proof_pid_cwd() { # <pid>
  local pid=$1 out line path='' pids=0 names=0
  out=$(lsof -w -a -p "$pid" -d cwd -F pn0 2>/dev/null | tr '\0' '\n') || return 1
  while IFS= read -r line; do
    case "$line" in
      p*) [ "$line" = "p$pid" ] || return 1; pids=$((pids + 1)) ;;
      n*) path=${line#n}; names=$((names + 1)) ;;
    esac
  done <<< "$out"
  [ "$pids" -eq 1 ] && [ "$names" -eq 1 ] || return 1
  case "$path" in /*) ;; *) return 1 ;; esac
  # lsof escapes backslashes and nonprinting bytes; an escaped name is not proof.
  case "$path" in *\\*) return 1 ;; esac
  (cd -P -- "$path" 2>/dev/null && pwd -P)
}

# Whether <state-dir> holds a task record other than <self> that claims this
# pane (by window, or by Herdr session and pane id), this home, or a worktree at
# least as deep around <cwd>. Paths compare physically: another record naming the
# home through a symlink still claims it. Succeeds on a conflict and prints the
# claiming task; an unreadable inventory also conflicts.
fm_launch_proof_claude_claimed() { # <self-meta> <state-dir> <window> <home> <root> <cwd>
  local self=$1 dir=$2 target=$3 home=$4 root=$5 cwd=$6 peer peer_home peer_root session pane
  session=${target%%:*}; pane=${target#*:}
  [ -d "$dir" ] || return 1
  { [ -r "$dir" ] && [ -x "$dir" ]; } || { printf '%s (inventory unreadable)' "$dir"; return 0; }
  for peer in "$dir"/*.meta; do
    [ -f "$peer" ] || continue
    [ "$peer" != "$self" ] || continue
    [ -z "$(fm_meta_get "$peer" remote_host)" ] || continue
    peer_home=$(fm_launch_proof_physical_path "$(fm_meta_get "$peer" home)")
    peer_root=$(fm_launch_proof_physical_path "$(fm_meta_get "$peer" worktree)")
    if [ "$(fm_meta_get "$peer" window)" = "$target" ]; then
      printf '%s' "${peer##*/}"; return 0
    fi
    if [ "$(fm_meta_get "$peer" herdr_session)" = "$session" ] && [ "$(fm_meta_get "$peer" herdr_pane_id)" = "$pane" ]; then
      printf '%s' "${peer##*/}"; return 0
    fi
    if [ -n "$peer_home" ] && { [ "$peer_home" = "$home" ] || [ "$peer_home" = "$root" ]; }; then
      printf '%s' "${peer##*/}"; return 0
    fi
    if [ -n "$peer_root" ] && { [ "$peer_root" = "$home" ] || [ "$peer_root" = "$root" ]; }; then
      printf '%s' "${peer##*/}"; return 0
    fi
    case "$peer_root" in /*) ;; *) continue ;; esac
    case "$cwd/" in
      "$peer_root"/*)
        if [ "${#peer_root}" -ge "${#root}" ]; then printf '%s' "${peer##*/}"; return 0; fi
        ;;
    esac
  done
  return 1
}

# The physical form of an existing absolute directory, else the text unchanged;
# empty stays empty so an absent field never matches anything.
fm_launch_proof_physical_path() { # <path>
  local resolved
  case "$1" in
    /*) if resolved=$(cd -P -- "$1" 2>/dev/null && pwd -P); then printf '%s' "$resolved"; else printf '%s' "$1"; fi ;;
    *) printf '%s' "$1" ;;
  esac
}

# Rebuilds, from the live system only, the proof that the foreground process of
# the task's recorded pane is the task's own restored claude conversation. Every
# fact below is positive and independent of the launch pin; prints the
# candidate adoption record, or refuses on stderr naming the missing proof.
fm_launch_proof_claude_adoption() { # <meta> -> candidate adoption-record JSON
  local meta=$1 target session pane home root gen pid harness_pid table kids kid args
  local resume_count=0 session_id='' i recorded tie transcript config_dir claude_home env_text
  local first epoch message kind record mtime launcher_args harness_args claim peer_state cwd
  local peer_meta peer_home peer_states
  local -a argv hargv

  target=$(fm_backend_meta_exact_value "$meta" window) \
    || { fm_launch_proof_adopt_refuse 'endpoint proof needs one recorded window'; return 1; }
  session=${target%%:*}; pane=${target#*:}
  gen=$(fm_meta_get "$meta" spawn_gen)
  if [ "$(fm_meta_get "$meta" backend)" != herdr ] || [ "$(fm_meta_get "$meta" harness)" != claude ] \
    || [ "$(fm_meta_get "$meta" kind)" != secondmate ] || [ -n "$(fm_meta_get "$meta" remote_host)" ] \
    || [ "$(fm_meta_get "$meta" launch_proof)" != env-v1 ] || [ -z "$gen" ] \
    || [ "$(fm_meta_get "$meta" herdr_session)" != "$session" ] \
    || [ "$(fm_meta_get "$meta" herdr_pane_id)" != "$pane" ]; then
    fm_launch_proof_adopt_refuse 'endpoint proof needs a local Herdr claude secondmate with a versioned launch proof, a spawn_gen, and window, herdr_session and herdr_pane_id that agree'
    return 1
  fi
  # cd to an empty name succeeds in place, so an absent field must refuse first.
  home=$(fm_backend_meta_exact_value "$meta" home) || home=/nonexistent
  home=$(cd -P -- "$home" 2>/dev/null && pwd -P) \
    || { fm_launch_proof_adopt_refuse 'workspace proof needs one recorded home that exists'; return 1; }
  root=$(fm_backend_meta_exact_value "$meta" worktree) || root=/nonexistent
  root=$(cd -P -- "$root" 2>/dev/null && pwd -P) \
    || { fm_launch_proof_adopt_refuse 'workspace proof needs one recorded worktree that exists'; return 1; }
  if ! fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null \
    | jq -e --arg pane "$pane" '.result.pane.pane_id == $pane' >/dev/null; then
    fm_launch_proof_adopt_refuse 'endpoint proof needs the recorded pane to exist and be readable'; return 1
  fi
  pid=$(fm_launch_proof_herdr_pid "$meta") \
    || { fm_launch_proof_adopt_refuse 'foreground proof needs one uniquely resolved live process in the recorded pane'; return 1; }

  # The attributed process is the one lifecycle input reaches: it is the claude
  # harness itself or a proven forwarding launcher around exactly one.
  table=$(LC_ALL=C ps -axo pid=,ppid=,pgid= 2>/dev/null) \
    || { fm_launch_proof_adopt_refuse 'process proof needs a readable process table'; return 1; }
  if fm_launch_proof_pid_is_named "$pid" claude; then
    harness_pid=$pid
  else
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) \
      || { fm_launch_proof_adopt_refuse 'process proof needs the attributed foreground process to be readable'; return 1; }
    read -r -a argv <<< "$args"
    i=0
    [ "$(basename -- "${argv[0]:-}")" != node ] || i=1
    fm_launch_proof_forwarding_launcher "${argv[i]:-}" && [ "${argv[i+1]:-}" = run ] && [ "${argv[i+2]:-}" = -- ] \
      || { fm_launch_proof_adopt_refuse 'process proof needs the attributed foreground process to be the claude harness or a listed forwarding launcher in the form "<launcher> run -- <harness arguments>"'; return 1; }
    launcher_args=${argv[*]:i+3}
    kids=$(awk -v p="$pid" -v g="$(awk -v p="$pid" '$1 == p {print $3; exit}' <<< "$table")" \
      '$2 == p && $3 == g {print $1}' <<< "$table")
    harness_pid=''
    for kid in $kids; do
      fm_launch_proof_pid_is_named "$kid" claude || continue
      [ -z "$harness_pid" ] || { fm_launch_proof_adopt_refuse 'process proof needs exactly one claude harness as the launcher'"'"'s direct child'; return 1; }
      harness_pid=$kid
    done
    [ -n "$harness_pid" ] \
      || { fm_launch_proof_adopt_refuse 'process proof needs the claude harness to be the launcher'"'"'s direct child in the launcher'"'"'s process group'; return 1; }
    read -r -a hargv <<< "$(LC_ALL=C ps -p "$harness_pid" -o args= 2>/dev/null)"
    harness_args=${hargv[*]:1}
    [ "$harness_args" = "$launcher_args" ] \
      || { fm_launch_proof_adopt_refuse 'process proof needs the launcher to forward exactly the harness'"'"'s own arguments'; return 1; }
  fi

  # Kernel working directory of the harness: the task's recorded workspace.
  cwd=$(fm_launch_proof_pid_cwd "$harness_pid") \
    || { fm_launch_proof_adopt_refuse 'workspace proof needs the harness process'"'"'s kernel cwd'; return 1; }
  [ "$cwd" = "$home" ] || [ "$cwd" = "$root" ] \
    || { fm_launch_proof_adopt_refuse 'workspace proof needs the harness cwd to be this task'"'"'s recorded home or worktree'; return 1; }

  # Generation and launch-pin proof, then unique ownership of pane and home.
  # Every process of the harness's group is part of the tree: a helper pinned to
  # another launch belongs to a different incarnation.
  for kid in $(awk -v g="$(awk -v p="$harness_pid" '$1 == p {print $3; exit}' <<< "$table")" '$3 == g {print $1}' <<< "$table") $pid $harness_pid; do
    if fm_launch_proof_pid_pinned_elsewhere "$kid" "$gen"; then
      fm_launch_proof_adopt_refuse 'generation proof needs no process in the tree to be pinned to another launch generation'; return 1
    fi
  done
  for kid in $pid $harness_pid; do
    fm_launch_proof_pid_unpinned "$kid" \
      || { fm_launch_proof_adopt_refuse 'launch-pin proof needs a positively readable environment without a usable launch pin; pinned or unreadable processes are not adoption candidates'; return 1; }
  done
  # Every home this home can read: its own records and each secondmate's.
  peer_states=$(dirname -- "$meta")
  for peer_meta in "$peer_states"/*.meta; do
    [ "$(fm_meta_get "$peer_meta" kind)" = secondmate ] || continue
    peer_home=$(fm_meta_get "$peer_meta" home)
    [ -z "$peer_home" ] || peer_states="$peer_states"$'\n'"$peer_home/state"
  done
  while IFS= read -r peer_state; do
    if claim=$(fm_launch_proof_claude_claimed "$meta" "$peer_state" "$target" "$home" "$root" "$cwd"); then
      fm_launch_proof_adopt_refuse "unique-claim proof needs no other task record to claim this pane or home; claimed by $claim"; return 1
    fi
  done <<< "$(printf '%s\n' "$peer_states" | sort -u)"

  # Task-specific session tie: the conversation, not just the directory.
  read -r -a hargv <<< "$(LC_ALL=C ps -p "$harness_pid" -o args= 2>/dev/null)"
  for ((i = 1; i < ${#hargv[@]}; i++)); do
    case "${hargv[i]}" in
      --resume|-r) resume_count=$((resume_count + 1)); session_id=${hargv[i+1]:-}; i=$((i + 1)) ;;
      --resume=*) resume_count=$((resume_count + 1)); session_id=${hargv[i]#--resume=} ;;
    esac
  done
  if [ "$resume_count" -ne 1 ] \
    || ! [[ $session_id =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    fm_launch_proof_adopt_refuse 'no task-specific session tie: the harness argv exposes no single session id'; return 1
  fi
  recorded=$(fm_meta_get "$meta" claude_session_id)
  if [ -n "$recorded" ] && [ "$recorded" != "$session_id" ]; then
    fm_launch_proof_adopt_refuse 'recorded session id differs from the live session; the task record names another conversation'; return 1
  fi
  tie=recorded
  if [ -z "$recorded" ]; then
    tie=launch-brief
    env_text=$(fm_remote_herdr_process_env "$harness_pid") \
      || { fm_launch_proof_adopt_refuse 'no task-specific session tie: the harness environment cannot be read to locate its transcript'; return 1; }
    config_dir=$(printf '%s\n' "$env_text" | sed -n 's/^CLAUDE_CONFIG_DIR=//p')
    claude_home=$(printf '%s\n' "$env_text" | sed -n 's/^HOME=//p')
    [ -n "$config_dir" ] || config_dir="$claude_home/.claude"
    transcript="$config_dir/projects/$(fm_launch_proof_claude_project_dir "$home")/$session_id.jsonl"
    if [ ! -f "$transcript" ] || [ -L "$transcript" ] \
      || ! first=$(python3 -I - "$transcript" 2>/dev/null <<'PY'
import json
import sys
from datetime import datetime

try:
    with open(sys.argv[1], "rb") as stream:
        for number, line in enumerate(stream):
            if number > 5000:
                break
            try:
                record = json.loads(line)
            except ValueError:
                continue
            if not isinstance(record, dict) or record.get("type") != "user" or record.get("isSidechain"):
                continue
            content = (record.get("message") or {}).get("content")
            if isinstance(content, list) and len(content) == 1 and isinstance(content[0], dict) \
                    and content[0].get("type") == "text":
                content = content[0].get("text")
            if not isinstance(content, str) or "\n" in content or "\r" in content:
                sys.exit(1)
            stamp = datetime.fromisoformat(record["timestamp"].replace("Z", "+00:00"))
            print(f"{stamp.timestamp():.3f}")
            print(content)
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
PY
); then
      fm_launch_proof_adopt_refuse 'no task-specific session tie: the session has no readable transcript whose first user message is a single line'; return 1
    fi
    epoch=${first%%$'\n'*}; message=${first#*$'\n'}
    if ! fm_operational_doorbell_kind "$message" "$home/state" kind || [ "$kind" != launch-brief ] \
      || ! fm_operational_doorbell_path "$message" record; then
      fm_launch_proof_adopt_refuse 'no task-specific session tie: the first user message is not the launch-brief doorbell of a record in this task'"'"'s own home'; return 1
    fi
    if [ "$(uname)" = Darwin ]; then mtime=$(/usr/bin/stat -f %m "$record"); else mtime=$(stat -c %Y "$record"); fi
    if ! [[ $mtime =~ ^[0-9]+$ ]] || [ "$mtime" -gt "${epoch%.*}" ]; then
      fm_launch_proof_adopt_refuse 'no task-specific session tie: the launch-brief record is newer than the first user message'; return 1
    fi
  fi
  jq -cn --arg gen "$gen" --arg window "$target" --argjson pid "$pid" --argjson harness_pid "$harness_pid" \
    --arg session_id "$session_id" --arg tie "$tie" \
    '{version:1, harness:"claude", spawn_gen:$gen, window:$window, pid:$pid, harness_pid:$harness_pid, session_id:$session_id, tie:$tie}'
}

# Succeeds only when the task's adoption record names exactly the proof the live
# system gives right now for <pid>. A record alone never licenses lifecycle input.
fm_launch_proof_claude_adopted() { # <meta> <pid>
  local meta=$1 pid=$2 record fresh
  record=$(jq -cS --arg gen "$(fm_meta_get "$meta" spawn_gen)" --argjson pid "$pid" '
    select(.version == 1 and .harness == "claude" and .spawn_gen == $gen and .pid == $pid)' \
    "${meta%.meta}.claude-adoption.json" 2>/dev/null) && [ -n "$record" ] || return 1
  fresh=$(fm_launch_proof_claude_adoption "$meta" 2>/dev/null | jq -cS . 2>/dev/null) || return 1
  [ "$record" = "$fresh" ]
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
  if [ "$verdict" = unmanaged ] && [ "$(fm_meta_get "$meta" harness)" = claude ] \
    && [ "$proof" = env-v1 ] && fm_launch_proof_claude_adopted "$meta" "$pid"; then
    # Adoption is a second authorization route, not a relaxed environment
    # comparison: every positive proof is rechecked against the live system here.
    verdict=managed
  fi
  case "$verdict" in
    managed|unknown) printf '%s' "$verdict" ;;
    unmanaged)
      # Only harnesses with an adoption route report a readable unpinned
      # environment as such; a legacy claude record keeps its pre-proof rule.
      case "$(fm_meta_get "$meta" harness):$proof" in
        omp:*|claude:env-v1) printf unmanaged ;;
        *) printf unknown ;;
      esac
      ;;
  esac
}

# The one wording for a refused live agent: the cause the verdict names and the
# next action. unmanaged is a readable environment without a matching pin;
# unknown is an environment that could not be read.
fm_launch_proof_refusal_cause() { # <unmanaged|unknown>
  case "$1" in
    unmanaged) printf 'live agent is an unpinned native restore: its process environment was readable and carries no launch pin matching this record' ;;
    *) printf 'live launch settings are unreadable' ;;
  esac
}

# adopt accepts only a secondmate, so a ship or scout is never sent to it.
fm_launch_proof_refusal_next() { # <unmanaged|unknown> <meta>
  local id=${2##*/}
  case "$1:$(fm_meta_get "$2" kind)" in
    unmanaged:secondmate) printf 'if it is this task'"'"'s own agent, the lock-owning main Firstmate can authorize it once with "bin/fm-control.sh %s adopt"' "${id%.meta}" ;;
    unmanaged:*) printf 'unmanaged restored worker: adopt supports secondmates only; Main inspects the pane and decides' ;;
    *) printf 'no foreground process could be attributed in the recorded pane, or its environment could not be read; retry once it can be read, or decide the lane by hand' ;;
  esac
}

# Lifecycle authorization for a live recorded Herdr agent, with the refusal
# cause on stdout when it fails and the harness has an adoption route to name
# (claude; omp's unmanaged verdict also covers a matching pin whose session proof
# failed, so it keeps its existing wording). A record published before launch
# proofs existed (empty launch_proof) has no pin to compare. The verdict is read
# exactly once.
fm_launch_proof_herdr_refusal() { # <meta>
  local verdict
  [ -n "$(fm_meta_get "$1" launch_proof)" ] || return 0
  verdict=$(fm_launch_proof_herdr "$1")
  [ "$verdict" != managed ] || return 0
  [ "$(fm_meta_get "$1" harness)" != claude ] \
    || printf '%s; %s' "$(fm_launch_proof_refusal_cause "$verdict")" \
      "$(fm_launch_proof_refusal_next "$verdict" "$1")"
  return 1
}

fm_launch_proof_herdr_authorizes() { # <meta>
  fm_launch_proof_herdr_refusal "$1" >/dev/null
}
