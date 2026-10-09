#!/usr/bin/env bash
set -eu
set -o pipefail
CODE_ROOT=$PWD
parent_soft=$(ulimit -S -u)
parent_hard=$(ulimit -H -u)
LAB=$(mktemp -d /tmp/fm-lab-01M4FNQD-XXXXXX)
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  "$CODE_ROOT/bin/fm-lab-home.sh" teardown "$LAB"
  rm -rf "$LAB"
  [ ! -e "$LAB" ]
  printf 'removed lab and private socket directory: %s (absent)\n' "$LAB"
}
trap cleanup EXIT
"$CODE_ROOT/bin/fm-lab-home.sh" create "$LAB"
mkdir -p "$LAB/tmux"
# Load the shipped launch function without calling up (which would mutate
# operator trust and create another checkout). Its help dispatch has no lifecycle.
. "$CODE_ROOT/bin/fm-live-lab.sh" --help >/dev/null
ROOT=$LAB
TMUX_DIR="$LAB/tmux"
CLAUDE_DIR=
log="$LAB/process-limits.txt"
printf 'outside lab soft=%s hard=%s\n' "$parent_soft" "$parent_hard"
lab_run tmux -f /dev/null -L fm-lab new-session -d -s budget -n measurement -x 120 -y 40 -c "$CODE_ROOT" -e FM_HOME="$LAB" \
  bash -c 'printf "pane pid=%s soft=%s hard=%s\n" "$$" "$(ulimit -S -u)" "$(ulimit -H -u)" > "$1"; python3 -c "import resource,os; a,b=resource.getrlimit(resource.RLIMIT_NPROC); print(\"descendant pid=%s soft=%s hard=%s\" % (os.getpid(),a,b))" >> "$1"; printf "budget report completed\n"; exec sleep 45' _ "$log"
for ((n=0; n<100; n++)); do [ -s "$log" ] && [ "$(wc -l < "$log")" -ge 2 ] && break; sleep 0.1; done
server_pid=$(TMUX_TMPDIR="$TMUX_DIR" tmux -L fm-lab display-message -p -t budget '#{pid}')
printf 'real tmux server pid=%s private socket=%s\n' "$server_pid" "$TMUX_DIR"
cat "$log"
python3 - "$log" "$parent_soft" <<'PY'
import re,sys
text=open(sys.argv[1]).read()
rows=re.findall(r'soft=(\d+) hard=(\d+)',text)
assert len(rows)==2, text
for soft,hard in rows: assert int(soft)==int(hard)<int(sys.argv[2]), text
assert rows[0]==rows[1], text
print('pane and real descendant inherited identical sealed budgets below the outside limit')
PY
TMUX_TMPDIR="$TMUX_DIR" tmux -L fm-lab capture-pane -p -t budget
[ "$(ulimit -S -u)" = "$parent_soft" ] && [ "$(ulimit -H -u)" = "$parent_hard" ]
TMUX_TMPDIR="$TMUX_DIR" tmux -L fm-lab kill-server
cleanup
trap - EXIT
