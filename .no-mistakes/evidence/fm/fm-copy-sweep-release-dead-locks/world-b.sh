#!/usr/bin/env bash
# World B: preservable ignored hook logs (the sweep preserves them; the real driver calls them non-payload).
#  q: quiet copy -> preserved once and released, GiB reported.
#  w: a writer whose cwd is OUTSIDE the copy keeps ADDING new ignored files -> no execute, no slot,
#     WAITING while it changes, then one preserve and a release once quiet.
set -u
WT=$1 LAB=$2; . "$(dirname "$0")/lab-lib.sh"
new_world b
DEAD=$(dead_pid)
add_copy q merged "$DEAD"; add_copy w merged "$DEAD"
git -C "$SLOT" fetch -q origin
for n in q w; do mkdir -p "$(cp_of $n)/scripts/hooks"; head -c 3000000 /dev/urandom > "$(cp_of $n)/scripts/hooks/run.log"; done
WD=$(cp_of w)/scripts/hooks
( cd "$W" && i=0; while :; do i=$((i+1)); printf 'msg %s\n' "$i" > "$WD/new-$i.log"; sleep 0.3; done ) & WRITER=$!
pres() { find "$HOMED/data/copy-sweep" -path '*/nested-copy-preserved/*' -name 'run.log' -type f 2>/dev/null | wc -l | tr -d ' '; }
calls() { grep -c -- "$1" "$W/git-calls.log" 2>/dev/null || echo 0; }
REALGIT=$(command -v git); mkdir -p "$W/shim"
printf '#!/bin/bash\nprintf "%%s\\t%%s\\n" "$(ps -o comm= -p $PPID | sed "s|.*/||")" "$*" >> "%s"\nexec "%s" "$@"\n' "$W/git-calls.log" "$REALGIT" > "$W/shim/git"; chmod +x "$W/shim/git"
run() { echo; echo "===== $1"; PATH="$W/shim:$PATH" sweep --apply; echo "exit=$?"
  echo "preserves holding run.log: $(pres)   copy w registered: $(git -C "$SLOT" worktree list | grep -c '/w ')   waiting records: $(ls "$HOMED/data/copy-sweep/waiting" 2>/dev/null | wc -l | tr -d ' ')   retention receipts: $(ls "$HOMED/data/copy-sweep/retained" 2>/dev/null | wc -l | tr -d ' ')"
  echo "driver unlock calls on w so far: $(calls "worktree unlock $(cp_of w)")"; }
sleep 1
run "RUN 1: --apply while the writer adds files to w"
run "RUN 2: --apply while the writer still adds files to w"
kill "$WRITER"; wait "$WRITER" 2>/dev/null; NFILES=$(ls "$WD" | wc -l | tr -d ' '); echo; echo "writer stopped; w/scripts/hooks now holds $NFILES files"
run "RUN 3: --apply, first run after the writer stopped"
run "RUN 4: --apply, second quiet run"
[ -d "$(cp_of w)" ] || { echo; echo "===== the preserve of w (every file the writer made must be there):"
  P=$(grep -l "$(cp_of w)" "$HOMED"/data/copy-sweep/*/nested-copy-preserved/*/copy-path | head -1); P=${P%/copy-path}
  echo "files in preserve: $(ls "$P/scripts/hooks" | wc -l | tr -d ' ') (writer made $NFILES)"; (cd "$P" && shasum -a 256 -c SHA256SUMS | grep -vc ': OK$' | sed 's/^/checksum mismatches: /'); }
echo; echo "===== copy-sweep.log:"; sed "s|$LAB|\$LAB|g" "$HOMED/data/copy-sweep.log"
