#!/usr/bin/env bash
# Build a real Seatbelt profile with a given fm-write-confinement.py and probe
# writes to the review ledger, carry-over scratch, and an allowed own-state file.
set -u
BUILDER=$1 HARNESS=$2 LABEL=$3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-seatbelt.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
H=$LAB/home
mkdir -p "$H/projects" "$H/config" "$H/data/task" "$H/state"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git init -q -b main "$H/projects/project"
git -C "$H/projects/project" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$H/projects/project" worktree add -q -b fm/task "$LAB/wt" main
printf '{"schema":"fm-review-record.v1"}\n' > "$H/state/review-records.jsonl"
EXTRA=""; [ "$HARNESS" = claude ] && EXTRA="--claude-session 11111111-2222-4333-8444-555555555555"
mkdir -p "$H/state/.review-carry-4242-x/proof.git"; printf x > "$H/state/.review-carry-4242-x/proof.git/config"
python3 "$BUILDER" --worktree "$LAB/wt" --home "$H" --config "$H/config" --projects "$H/projects" \
  --data "$H/data/task" --state "$H/state" --task task --harness "$HARNESS" --branch fm/task --profile "$LAB/profile.sb" $EXTRA \
  || { echo "$LABEL $HARNESS: build failed"; rm -rf "$LAB"; exit 1; }
probe() {  # <name> <shell snippet>
  if sandbox-exec -f "$LAB/profile.sb" /bin/sh -c "$2" 2>/dev/null; then r=WRITE-ALLOWED; else r=WRITE-DENIED; fi
  printf '%-8s %-6s %-40s %s\n' "$LABEL" "$HARNESS" "$1" "$r"
}
S=$H/state
probe "append review-records.jsonl" "printf '{\"forged\":1}\n' >> '$S/review-records.jsonl'"
probe "replace review-records.jsonl (mv)" "printf f > '$S/rr.tmp' && mv '$S/rr.tmp' '$S/review-records.jsonl'"
probe "tamper existing carry scratch file" "printf evil > '$S/.review-carry-4242-x/proof.git/config'"
probe "create new .review-carry-* dir" "mkdir '$S/.review-carry-9-new'"
probe "own task.status (should stay allowed)" "printf ok > '$S/task.status'"
probe "worktree file (should stay allowed)" "printf ok > '$LAB/wt/file.txt'"
grep -c 'review-records.jsonl\|review-carry' "$LAB/profile.sb" | sed "s/^/$LABEL $HARNESS profile rules mentioning ledger\/carry: /"
ln "$H/state/review-records.jsonl" "$LAB/wt/ledger-alias"
if out=$(python3 "$BUILDER" --worktree "$LAB/wt" --home "$H" --config "$H/config" --projects "$H/projects" \
  --data "$H/data/task" --state "$H/state" --task task --harness "$HARNESS" --branch fm/task --profile "$LAB/profile2.sb" $EXTRA 2>&1); then
  printf '%-8s %-6s %-40s %s\n' "$LABEL" "$HARNESS" "build with ledger hard-link alias" "BUILD-ACCEPTED"
else
  printf '%-8s %-6s %-40s %s\n' "$LABEL" "$HARNESS" "build with ledger hard-link alias" "BUILD-REFUSED: ${out#error: }"
fi
rm -rf "$LAB"
