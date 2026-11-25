#!/bin/bash
# run INSIDE the confined worker: try ref writes and report each result
G="git -C /Users/charlesabrooker/tmp/fm-succ-fx.1IZ4MZ/fx/slots/22/project"
P=$($G rev-parse refs/heads/fm/fm-succ-lab-task-v2); S=$($G rev-parse refs/heads/fm/fm-succ-lab-task); M=$($G rev-parse refs/heads/main)
C=$($G commit-tree "$P^{tree}" -p "$P" -m "probe on successor $1") || echo "commit-tree failed"
try() { local what=$1; shift; if out=$($G "$@" 2>&1); then echo "PROBE $what: ALLOWED"; else echo "PROBE $what: DENIED: $(echo "$out" | head -1)"; fi; }
echo "PROBE sandboxed=$(sandbox-exec -p '(version 1)(allow default)' /usr/bin/true 2>/dev/null && echo no || echo yes) FM_TASK_ID=$FM_TASK_ID"
try "successor fm/fm-succ-lab-task-v2 -> child of P" update-ref refs/heads/fm/fm-succ-lab-task-v2 "$C" "$P"
try "unrecorded sibling fm/fm-succ-lab-task-v3" update-ref refs/heads/fm/fm-succ-lab-task-v3 "$C" 0000000000000000000000000000000000000000
try "default branch main" update-ref refs/heads/main "$C" "$M"
try "prefix-sharing fm/fm-succ-lab-task-v2x" update-ref refs/heads/fm/fm-succ-lab-task-v2x "$C" 0000000000000000000000000000000000000000
echo "PROBE refs now: v2=$($G rev-parse -q --verify refs/heads/fm/fm-succ-lab-task-v2) v3=$($G rev-parse -q --verify refs/heads/fm/fm-succ-lab-task-v3 || echo none) main=$($G rev-parse refs/heads/main)"
