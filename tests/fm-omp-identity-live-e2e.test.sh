#!/usr/bin/env bash
# tests/fm-omp-identity-live-e2e.test.sh - default-on drift guard proving the INSTALLED
# omp is still recognized by the omp identity rule (bin/fm-omp-identity.py) and
# by the Herdr descendant walk that keeps its worktree occupied.
#
# Why this file exists: the verdict rests on what the installed omp emits - its
# process shape (a launcher that execs the Bun runtime on an entry script, or a
# native binary), its entry script and its CLI role dispatch. A stub can only
# confirm the assumption written into it, so tests/fm-omp-identity.test.sh pins
# the logic with real stand-in processes and THIS guard checks the real install.
# It fails loudly naming the harness and its version when the installed shape is
# not recognized, so an omp release that changes its launcher, its process shape
# or its dispatch tables cannot silently turn a restored worker back into a
# process no lifecycle verb can attribute.
#
# Pass FM_OMP_IDENTITY_LIVE=0 (or FM_LIVE=0) to keep it from starting the installed omp.
# It spends no model tokens and reads no credential: omp starts bare, on a
# pseudo-terminal, in a scratch worktree, under `env -i` with a scratch HOME (so
# it has no key, no agent directory and no settings of the operator), no prompt is
# submitted and no running worker is touched; the process is killed at the end.
# It uses no Herdr server: the pane is a pseudo-terminal and Herdr's process-info
# view is the same JSON shape the adapter parses (docs/herdr-backend.md).
# Refresh docs/verification/runtime-backends.md "omp identity" with this command:
#   bash bin/fm-test-run.sh tests/fm-omp-identity-live-e2e.test.sh
# The identity rule compares the live process with the one trusted installed identity
# held in bin/fm-omp-identity.py (installed_identity(), FM_OMP_INSTALLED_ROOT for tests)
# and needs no launcher, but this guard must start a real Bun-shaped omp. It starts the
# first omp on PATH; when that is a native binary it starts the file named by
# FM_OMP_IDENTITY_LIVE_LAUNCHER, which only chooses what to start and never decides
# identity, or a text launcher from later on PATH, and it names any Bun launcher that is
# not first. With no text launcher it FAILS, naming FM_OMP_IDENTITY_LIVE_LAUNCHER (and
# FM_OMP_IDENTITY_LIVE=0 for an explicit opt-out), because a guard that could pass
# having checked nothing proves nothing. It also fails when FM_OMP_INSTALLED_ROOT is set,
# because an override makes it compare a stand-in with itself and it could never see
# drift in the real install; tests/fm-omp-identity.test.sh alone sets
# FM_OMP_IDENTITY_LIVE_STANDIN=1 to run this script on a stand-in tree. An absent omp is
# reported explicitly (fm_live_gate), and a run that checked nothing fails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_OMP_IDENTITY_LIVE omp

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IDENT="$ROOT/bin/fm-omp-identity.py"
PROCINFO="$ROOT/bin/fm-proc-info.py"
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-omp-identity-live.XXXXXX") || fail "could not create a scratch directory"
SCRATCH=$(cd "$SCRATCH" && pwd)
HOLDER=
cleanup_all() {
  [ -z "$HOLDER" ] || kill "$HOLDER" 2>/dev/null || true
  [ -z "${AGENT_PID:-}" ] || kill "$AGENT_PID" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup_all EXIT

if [ "$(uname -s)" != Darwin ]; then
  fail "the omp identity rule reads libproc facts and runs on macOS; this host is $(uname -s), so nothing was checked"
fi
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
if [ -n "${FM_OMP_INSTALLED_ROOT:-}" ] && [ "${FM_OMP_IDENTITY_LIVE_STANDIN:-}" != 1 ]; then
  fail "FM_OMP_INSTALLED_ROOT is set; this guard checks the real installed identity and cannot detect drift against an override. Unset it"
fi
OMP=$(command -v omp)
is_text_launcher() { [ -f "$1" ] && [ "$(head -c 2 "$1" 2>/dev/null)" = '#!' ]; }
START=
while IFS= read -r CANDIDATE; do
  if [ -z "$CANDIDATE" ] || ! is_text_launcher "$CANDIDATE"; then
    continue
  fi
  if [ -z "$START" ]; then
    START=$CANDIDATE
  elif [ ! "$CANDIDATE" -ef "$START" ]; then
    note "the Bun launcher $CANDIDATE is not first on PATH and is not started by this run"
  fi
done < <(printf '%s\n' "$OMP" "${FM_OMP_IDENTITY_LIVE_LAUNCHER:-}"; type -ap omp)
if [ -z "$START" ]; then
  fail "no Bun launcher to start: the first omp on PATH is native and no text launcher was found, so the Bun identity rule was not exercised. Name the installed launcher with FM_OMP_IDENTITY_LIVE_LAUNCHER=<path>, or set FM_OMP_IDENTITY_LIVE=0 to opt out of this guard"
fi
[ "$START" -ef "$OMP" ] || note "the Bun launcher $START is not first on PATH ($OMP is); this run starts $START"
# Even `--version` runs under the scratch environment, so no operator agent directory or .env is read.
mkdir -p "$SCRATCH/home" "$SCRATCH/wt"
VERSION=$(env -i PATH="$PATH" HOME="$SCRATCH/home" OMP_SKIP_SETUP=1 "$START" --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION=unknown
LABEL="omp $VERSION at $START"
CHECKED=0
drift() { fail "OMP IDENTITY DRIFT: $LABEL: $1"; }

# The pane: a pseudo-terminal holding the bare installed omp in a scratch worktree.
cat > "$SCRATCH/hold.py" <<'PY'
import os, pty, signal, subprocess, sys, time
pidfile, cwd, home, omp = sys.argv[1:5]
master, slave = pty.openpty()
env = {"PATH": os.environ["PATH"], "HOME": home, "TERM": "xterm-256color", "OMP_SKIP_SETUP": "1"}
child = subprocess.Popen([omp, "--no-session", "--no-extensions", "--no-skills", "--no-rules", "--no-title"],
                         stdin=slave, stdout=slave, stderr=slave, cwd=cwd, env=env, close_fds=True)
signal.signal(signal.SIGTERM, lambda *_: (child.kill(), os._exit(0)))
open(pidfile, "w").write(str(child.pid))
while True:
    try:
        os.read(master, 65536)
    except OSError:
        time.sleep(0.1)
PY
python3 -I "$SCRATCH/hold.py" "$SCRATCH/pid" "$SCRATCH/wt" "$SCRATCH/home" "$START" >/dev/null 2>&1 &
HOLDER=$!
for _ in $(seq 1 100); do [ -s "$SCRATCH/pid" ] && break; sleep 0.1; done
[ -s "$SCRATCH/pid" ] || drift "the installed omp did not start in the scratch pane"
AGENT_PID=$(cat "$SCRATCH/pid")
# Let the launcher exec and the interface come up; the process must still be alive.
sleep 3
kill -0 "$AGENT_PID" 2>/dev/null || drift "the installed omp exited before it could be inspected (it ran bare, with no prompt)"

EXE=$(python3 -I "$PROCINFO" exe "$AGENT_PID") || drift "the process executable path is unreadable"
RESULT=$(python3 -I "$IDENT" interactive "$AGENT_PID" 2>&1); rc=$?
[ "$rc" -eq 0 ] || drift "the installed interactive agent is not recognized (exit $rc): $RESULT"
CHECKED=$((CHECKED + 1))
pass "the installed omp's Bun runtime is recognized as the interactive agent ($RESULT)"
python3 -I "$IDENT" facts "$AGENT_PID" > "$SCRATCH/facts.json" || drift "the process facts are unreadable"
python3 -I "$IDENT" interactive --facts "$SCRATCH/facts.json" >/dev/null 2>&1 \
  || drift "the captured facts of the installed interactive agent do not replay as recognized"
# The same process in a foreign package must not be recognized, or the identity check is vacuous.
python3 -I - "$SCRATCH/facts.json" "$SCRATCH/foreign.json" <<'PY'
import json, sys
facts = json.load(open(sys.argv[1]))
facts["evidence"]["runtime_package"] = "some-other-runtime"
json.dump(facts, open(sys.argv[2], "w"))
PY
if python3 -I "$IDENT" interactive --facts "$SCRATCH/foreign.json" >/dev/null 2>&1; then
  drift "a foreign runtime package still recognized the live process: the identity check is vacuous"
fi
CHECKED=$((CHECKED + 1))
# The same process against another installed identity must not be recognized, or the identity binding is vacuous.
python3 -I - "$SCRATCH/facts.json" "$SCRATCH/other-install.json" <<'PY'
import json, sys
facts = json.load(open(sys.argv[1]))
facts["installed"] = {"runtime": facts["installed"]["runtime"] + ".other", "script": facts["installed"]["script"]}
json.dump(facts, open(sys.argv[2], "w"))
PY
if python3 -I "$IDENT" interactive --facts "$SCRATCH/other-install.json" >/dev/null 2>&1; then
  drift "the live process was recognized against an installed identity it does not match: the identity binding is vacuous"
fi
CHECKED=$((CHECKED + 1))
# A worker-role argument vector of the same runtime is never the interactive agent.
python3 -I - "$SCRATCH/facts.json" "$SCRATCH/worker.json" <<'PY'
import json, sys
facts = json.load(open(sys.argv[1]))
facts["argv"] = facts["argv"][:2] + ["__omp_worker_daemon_broker"]
json.dump(facts, open(sys.argv[2], "w"))
PY
if python3 -I "$IDENT" interactive --facts "$SCRATCH/worker.json" >/dev/null 2>&1; then
  drift "the installed runtime in a worker role was recognized as the interactive agent"
fi
CHECKED=$((CHECKED + 1))
# The installed CLI's dispatch tables still match the copy the role rule ports.
SCRIPT=$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["evidence"]["script_real"])' "$SCRATCH/facts.json")
SOURCE_DIR=$(dirname "$SCRIPT")
if [ -f "$SOURCE_DIR/cli-commands.ts" ] && [ -f "$SOURCE_DIR/cli/flag-tables.ts" ]; then
  DIFF=$(python3 -I - "$IDENT" "$SOURCE_DIR" <<'PY'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("oi", sys.argv[1])
oi = importlib.util.module_from_spec(spec); spec.loader.exec_module(oi)
src = sys.argv[2]
commands = open(src + "/cli-commands.ts").read()
tables = open(src + "/cli/flag-tables.ts").read()
names = set(re.findall(r'^\t\tname: "([^"]+)"', commands, re.M))
for group in re.findall(r"aliases: \[([^\]]*)\]", commands):
    names |= {a.strip().strip('"') for a in group.split(",")}
body = tables[tables.index("export const STRING_SETTERS"):tables.index("export const OPTIONAL_FLAGS")]
strings = set(re.findall(r'^\t"([^"]+)"', body, re.M))
start = tables.index("export const VALUELESS_FLAGS")
valueless = set(re.findall(r'"(--[a-z-]+)"', tables[start:tables.index("]);", start)]))
problems = []
if names != set(oi.SUBCOMMANDS): problems.append(f"subcommands differ: installed-only {sorted(names - oi.SUBCOMMANDS)} ported-only {sorted(oi.SUBCOMMANDS - names)}")
if strings != set(oi.STRING_VALUE_FLAGS): problems.append(f"string flags differ: installed-only {sorted(strings - oi.STRING_VALUE_FLAGS)} ported-only {sorted(oi.STRING_VALUE_FLAGS - strings)}")
if valueless != set(oi.VALUELESS_FLAGS): problems.append(f"value-less flags differ: installed-only {sorted(valueless - oi.VALUELESS_FLAGS)} ported-only {sorted(oi.VALUELESS_FLAGS - valueless)}")
print("; ".join(problems))
PY
  ) || drift "could not compare the installed dispatch tables"
  [ -z "$DIFF" ] || drift "the installed CLI's dispatch tables drifted from the role rule's copy ($DIFF); update bin/fm-omp-identity.py"
  CHECKED=$((CHECKED + 1))
  pass "the installed CLI's subcommand and flag tables match the role rule's copy"
else
  note "the installed omp ships no readable CLI source next to its entry script; the dispatch-table comparison was not run"
fi
# The liveness route: with a shell in the foreground and the agent a descendant, the pane is never agent-free.
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"; . "$ROOT/bin/backends/herdr.sh"
fm_backend_herdr_cli() {
  printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"zsh","argv0":"zsh","argv":["zsh"]}]}}}'
}
cat > "$SCRATCH/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *-axo*) printf '4242 1 zsh\n%s 4242 %s\n' "$WALK_PID" "$WALK_COMM" ;;
  *-p*-o\ args=*) printf '%s\n' "$WALK_ARGS" ;;
esac
SH
chmod +x "$SCRATCH/ps"
ARGS=$(python3 -I "$PROCINFO" args "$AGENT_PID")
STATE=$(FM_HERDR_PS_BIN="$SCRATCH/ps" WALK_PID="$AGENT_PID" WALK_COMM="$EXE" WALK_ARGS="$ARGS" \
  fm_backend_herdr_pane_process_state_sample live w1:p1)
[ "$STATE" = other ] || drift "a live installed omp that is only a descendant of the pane shell read as '$STATE', not occupied: a relaunch could start a second agent on its worktree"
CHECKED=$((CHECKED + 1))
pass "the Herdr descendant walk keeps a pane holding the installed omp occupied"

[ "$CHECKED" -gt 0 ] || fail "$LABEL: nothing was checked; refusing to pass"
note "checked $CHECKED invariants against $LABEL"
