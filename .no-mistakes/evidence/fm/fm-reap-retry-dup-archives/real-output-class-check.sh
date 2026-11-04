#!/usr/bin/env bash
# Feeds a real recorded Vernant closeout-driver output (read-only source) through
# the real teardown refusal printer (teardown_closeout_refusal in
# bin/fm-teardown-nested-lib.sh, using the real fm_refuse_text) and then into
# the new class check fm_closeout_retained_class from bin/fm-idle-reap-lib.sh.
# Usage: real-output-class-check.sh <worktree> <real-closeout-output-file> <kind: own|foreign>
set -u
WT=$1; SRC=$2; KIND=$3
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-classcheck.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
cd "$WT"
. bin/fm-refuse-lib.sh
. bin/fm-idle-reap-lib.sh
# Pull only the two printer functions out of the nested lib (it is not sourceable on its own).
eval "$(sed -n '/^teardown_closeout_refusal() {/,/^}/p' bin/fm-teardown-nested-lib.sh)"
DATA="$SCRATCH/data"; ID=lab-task
COPY="/lab/slot/vernant/.claude/worktrees/fm-lab-task-l2"
TEARDOWN_CLOSEOUT_OUT=$(cat "$SRC"; printf .); TEARDOWN_CLOSEOUT_OUT=${TEARDOWN_CLOSEOUT_OUT%.}
case "$KIND" in own) k='own nested' ;; *) k=foreign ;; esac
teardown_closeout_refusal "$k" "$COPY" 3 2> "$SCRATCH/teardown-stderr.txt"
printf 'source file: %s\n' "$SRC"
printf 'source bytes: %s  sha256: %s\n' "$(wc -c < "$SRC" | tr -d ' ')" "$(shasum -a 256 "$SRC" | cut -c1-16)"
printf 'source top-level reason: %s\n' "$(python3 -I -c 'import json,sys
for l in open(sys.argv[1]):
  l=l.strip()
  if l.startswith("{"): print(json.loads(l).get("reason"))' "$SRC")"
printf 'printed teardown output: %s lines; line lengths: %s\n' "$(wc -l < "$SCRATCH/teardown-stderr.txt" | tr -d ' ')" "$(awk '{printf "%s ", length($0)}' "$SCRATCH/teardown-stderr.txt")"
printf 'printed refusal line: %s\n' "$(head -n 1 "$SCRATCH/teardown-stderr.txt" | sed "s#$SCRATCH#<scratch>#")"
if fm_closeout_retained_class "$(cat "$SCRATCH/teardown-stderr.txt")"; then
  printf 'fm_closeout_retained_class: RECOGNISED (retained class); named copies: %s\n' "${CLOSEOUT_RETAINED_PATHS[*]}"
else
  printf 'fm_closeout_retained_class: NOT recognised\n'
fi
# Negative: same real output with the top-level reason swapped must not match.
python3 -I -c 'import json,sys
src,dst=sys.argv[1:3]; out=[]
for l in open(src).read().split("\n"):
  if l.strip().startswith("{"):
    d=json.loads(l.strip()); d["reason"]="different_closeout_refusal_class"; l=json.dumps(d)
  out.append(l)
open(dst,"w").write("\n".join(out))' "$SRC" "$SCRATCH/swapped"
TEARDOWN_CLOSEOUT_OUT=$(cat "$SCRATCH/swapped")
teardown_closeout_refusal "$k" "$COPY" 3 2> "$SCRATCH/swapped-stderr.txt"
if fm_closeout_retained_class "$(cat "$SCRATCH/swapped-stderr.txt")"; then
  printf 'negative (top-level reason swapped, retained token still nested=%s): WRONGLY recognised\n' "$(grep -c cleanup_ignored_payload_archived_tree_retained "$SCRATCH/swapped-stderr.txt")"
else
  printf 'negative (top-level reason swapped, retained token still nested in %s line(s)): not recognised, as required\n' "$(grep -c cleanup_ignored_payload_archived_tree_retained "$SCRATCH/swapped-stderr.txt")"
fi
