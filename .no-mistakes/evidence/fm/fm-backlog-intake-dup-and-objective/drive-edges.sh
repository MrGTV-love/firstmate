#!/usr/bin/env bash
# Live drive, part 3: add-grammar bypass attempts, unwritable sidecar, --json add,
# archive tails written by real tasks-axi, more owner shapes, timeout recurrence
# after close. Disposable marked lab home; real tasks-axi.
# Usage: drive-edges.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 1
for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE FM_DURATION_FILE FM_DURATION_HOME; do unset "$v"; done
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
REPO=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-repo.XXXXXX")
trap 'chmod -R u+w "$FM_HOME" 2>/dev/null; bin/fm-lab-home.sh teardown "$FM_HOME" >/dev/null 2>&1; rm -rf "$FM_HOME" "$REPO"' EXIT
W="$WT/bin/fm-tasks-axi.sh"
B="$FM_HOME/data/backlog.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$B"
raw() { (cd "$FM_HOME" && TASKS_AXI_FILE="$B" tasks-axi "$@"); }
echo "lab FM_HOME=$FM_HOME (marked lab home); tasks-axi $(tasks-axi --version)"
n=0
run() {  # <label> <expect ok|refused> <args...>
  local label=$1 expect=$2 out rc
  shift 2
  n=$((n+1))
  echo; echo "=== [$n] $label"; echo "\$ fm-tasks-axi.sh $*"
  out=$("$W" "$@" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -v '^\s*\(blocked\|held\|hold_\|priority\|deps\|links\|created\|closed\|blocked_by\|help\|- Run\)' | sed 's/^/    /'
  echo "    -> exit $rc"
  if [ "$expect" = ok ] && [ "$rc" -ne 0 ]; then echo "    !! UNEXPECTED: expected success"; fi
  if [ "$expect" = refused ] && [ "$rc" -eq 0 ]; then echo "    !! UNEXPECTED: expected refusal"; fi
}

"$W" add lock-a "Lock holder crash" --objective O7 >/dev/null 2>&1
echo; echo "##### add-grammar spellings cannot skip the checks #####"
run "create alias, no objective" refused create g1 "Granite sloth"
run "task add, no objective" refused task add g2 "Granite sloth"
run "task create, no objective" refused task create g3 "Granite sloth"
run "--title form, no objective" refused add --title "Granite sloth" g4
run "--mint form, no objective" refused add "Granite sloth" --mint
run "create alias, overlapping title" refused create g5 "Lock holder crash recovery" --objective O7
run "task add, overlapping title" refused task add g6 "Lock holder crash recovery" --objective O7
run "--title form, overlapping title" refused add --title "Lock holder crash recovery" g7 --objective O7
run "--mint form, overlapping title" refused add "Lock holder crash recovery" --mint --objective O7
run "--objective= form, overlapping title" refused add g8 "Lock holder crash recovery" --objective=O7
grep -qE '^- \[ \] g[1-8] ' "$B" && echo "    !! a spelling filed an item" || echo "    (no g1..g8 row filed)"

echo; echo "##### unwritable sidecar stops the add, nothing filed #####"
touch "$FM_HOME/data/backlog-review.tsv"; chmod a-w "$FM_HOME/data/backlog-review.tsv"
run "add with read-only backlog-review.tsv is refused" refused add side-a "Sidecar lynx probe" --objective O7
grep -q 'side-a' "$B" && echo "    !! side-a was filed" || echo "    (no side-a row in backlog.md)"
chmod u+w "$FM_HOME/data/backlog-review.tsv"

echo; echo "##### --json add still records the objective row #####"
run "add --json files and records the row" ok add json-a "Jsonified marmot feed" --objective O5 --json
grep -n 'json-a' "$FM_HOME/data/backlog-review.tsv" | sed 's/^/    tsv: /'
grep -n 'json-a' "$B" | sed 's/^/    backlog: /'

echo; echo "##### archive tails written by real tasks-axi #####"
raw add h1 "Quill holder crash" >/dev/null
raw hold h1 --until 2026-12-01 >/dev/null
raw done h1 --keep 0 >/dev/null
grep 'h1' "$FM_HOME/data/done-archive.md" | sed 's/^/    archive: /'
run "add 'Quill timeout' is refused at 0.25 beside an archived held row" refused add h2 "Quill timeout" --objective O7
raw add pc1 "Fix the zinc gear (process cleanup)" --repo firstmate --kind ship >/dev/null
raw done pc1 --keep 0 >/dev/null
grep 'pc1' "$FM_HOME/data/done-archive.md" | sed 's/^/    archive: /'
run "add 'Process cleanup' is refused at 0.40 beside archived '(process cleanup)' row" refused add pc2 "Process cleanup" --objective O7

echo; echo "##### owner shapes from the round-4 rulings #####"
"$W" add keep-k "Keeper iguana item" --objective O7 >/dev/null 2>&1
i=0
for body in "Captain's ask 2026-09-22 on /bearings lavish: show the board" "Captain chose this on the Lavish page" "Captain direction 2026-10-22, verbatim in data/x.md" "Captain's words, 2026-10-20 (via /kun): yes"; do
  i=$((i+1))
  "$W" add "ow-$i" "Owner shape probe $i quokka" --objective O7 --body "$body" >/dev/null 2>&1 || "$W" add "ow-$i" "Owner shape probe $i quokka" --objective O7 --body "$body" --not-dup ow-1 >/dev/null 2>&1
  echo "    body of ow-$i: $body"
  run "owner shape $i refuses --duplicate-of" refused done "ow-$i" --duplicate-of keep-k
done
"$W" add low-a "Lowercase owner decision tapir" --objective O7 --body "owner decision: keep the lock owner field" >/dev/null 2>&1
run "lower-case 'owner decision' is not an owner item and closes on proof" ok done low-a --duplicate-of keep-k

echo; echo "##### timeout recurrence after the item closed #####"
git -C "$REPO" init -q && git -C "$REPO" remote add origin git@github.com:acme/widgets.git
ln -s "$WT/bin" "$FM_HOME/bin"
export FM_DURATION_HOME=$FM_HOME
tmo() { echo "\$ fm-duration.py timeout $1 1200000 --event-id $2"; (cd "$REPO" && python3 "$WT/bin/fm-duration.py" timeout "$1" 1200000 --event-id "$2" 2>&1) | sed 's/^/    /'; echo "    -> exit ${PIPESTATUS[0]}"; }
tmo lab.again r1
tmo lab.again r2
first=$(jq -r 'select(.event=="filed" and .key=="lab.again") | .task' "$FM_HOME/data/command-durations.jsonl" | head -1)
echo "    first item: $first"
raw done "$first" --note "limit repaired" --keep 5 >/dev/null
tmo lab.again r3
"$W" show "$first-2" --full 2>&1 | grep -E 'id:|state:|body:' | sed 's/^/    /'
grep -n "$first" "$FM_HOME/data/backlog-review.tsv" | sed 's/^/    tsv: /'
echo; echo "--- final backlog-review.tsv:"; sed 's/^/    /' "$FM_HOME/data/backlog-review.tsv"
