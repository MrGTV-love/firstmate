#!/usr/bin/env bash
# Live drive, part 2: env-var bypass attempts, piped --body-file, a real merged
# --pr proof (read-only GitHub lookup), and the repeated-timeout filer with
# seven open timeout items, all against a disposable marked lab home.
# Usage: drive-bypass-pr-timeout.sh <worktree>
set -u
WT=$1
cd "$WT" || exit 1
for v in FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE FM_DURATION_FILE FM_DURATION_HOME; do unset "$v"; done
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
REPO=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-repo.XXXXXX")
trap 'bin/fm-lab-home.sh teardown "$FM_HOME" >/dev/null 2>&1; rm -rf "$FM_HOME" "$REPO"' EXIT
W="$WT/bin/fm-tasks-axi.sh"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
echo "lab FM_HOME=$FM_HOME (marked lab home); tasks-axi $(tasks-axi --version)"
show() { echo "--- $1:"; sed 's/^/    /' "$2" 2>/dev/null || echo "    (absent)"; }

"$W" add lock-a "Lock holder crash" --objective O7 --kind ship --repo firstmate >/dev/null 2>&1
echo; echo "##### M4: no environment variable bypasses the add checks #####"
for envset in "FM_INTAKE_SKIP=1" "FM_GATE_REFUSE_BYPASS=1" "FM_TASKS_AXI_REFUSE_OPEN_CALL=1" "FM_BACKLOG_INTAKE_OFF=1" "TASKS_AXI_NO_DUP=1"; do
  echo "\$ env $envset fm-tasks-axi.sh add lock-z 'Lock holder crash recovery' --objective O7"
  out=$(env "$envset" "$W" add lock-z "Lock holder crash recovery" --objective O7 2>&1); rc=$?
  printf '%s\n' "$out" | sed -n '1,3p' | sed 's/^/    /'; echo "    -> exit $rc"
  echo "\$ env $envset fm-tasks-axi.sh add lock-y 'Unrelated walrus' (no --objective)"
  out=$(env "$envset" "$W" add lock-y "Unrelated walrus" 2>&1); rc=$?
  printf '%s\n' "$out" | sed -n '1p' | sed 's/^/    /'; echo "    -> exit $rc"
done
grep -q 'lock-z\|lock-y' "$FM_HOME/data/backlog.md" && echo "    !! a bypass filed an item" || echo "    (no bypass filed lock-z or lock-y)"

echo; echo "##### piped --body-file reaches tasks-axi unchanged #####"
echo "\$ fm-tasks-axi.sh add pipe-a 'Heron pipeline body' --objective O7 --body-file <(printf 'line one\\nline two\\n')"
"$W" add pipe-a "Heron pipeline body" --objective O7 --body-file <(printf 'line one\nline two\n') 2>&1 | grep -E '^ok|body:' | sed 's/^/    /'
echo "\$ fm-tasks-axi.sh add pipe-b 'Heron pipeline body dup' --objective O7 --dup-of pipe-a --body-file <(printf 'third line\\n')"
"$W" add pipe-b "Heron pipeline body dup" --objective O7 --dup-of pipe-a --body-file <(printf 'third line\n') 2>&1 | sed 's/^/    /'
"$W" show pipe-a --full 2>&1 | grep 'body:' | sed 's/^/    /'

echo; echo "##### M4: --pr proof unchanged (real read-only forge lookup) #####"
"$W" add ship-p "Puffin release notes" --objective O6 --kind ship --repo firstmate >/dev/null 2>&1
echo "\$ fm-tasks-axi.sh done ship-p --pr https://github.com/MrGTV-love/firstmate/pull/361   (open, not merged)"
"$W" done ship-p --pr https://github.com/MrGTV-love/firstmate/pull/361 2>&1 | sed 's/^/    /'; echo "    -> exit ${PIPESTATUS[0]}"
echo "\$ fm-tasks-axi.sh done ship-p --pr https://github.com/MrGTV-love/firstmate/pull/364   (merged)"
"$W" done ship-p --pr https://github.com/MrGTV-love/firstmate/pull/364 2>&1 | sed 's/^/    /'; echo "    -> exit ${PIPESTATUS[0]}"
grep -n 'ship-p' "$FM_HOME/data/backlog.md" | sed 's/^/    /'

echo; echo "##### repeated-timeout filer with seven open timeout items #####"
git -C "$REPO" init -q && git -C "$REPO" remote add origin git@github.com:acme/widgets.git
ln -s "$WT/bin" "$FM_HOME/bin"
export FM_DURATION_HOME=$FM_HOME
RAW="TASKS_AXI_FILE=$FM_HOME/data/backlog.md"
for i in 0 1 2 3 4 5 6; do (cd "$FM_HOME" && env "$RAW" tasks-axi add "fm-timeout-other$i" "Measure and repair repeated timeout: acme/widgets other.key$i" --kind ship >/dev/null); done
tmo() { echo "\$ (cd <scratch repo acme/widgets>) fm-duration.py timeout $1 1200000 --event-id $2"; (cd "$REPO" && python3 "$WT/bin/fm-duration.py" timeout "$1" 1200000 --event-id "$2" 2>&1) | sed 's/^/    /'; echo "    -> exit ${PIPESTATUS[0]}"; }
tmo lab.fresh f1
tmo lab.fresh f2
grep -n 'lab.fresh' "$FM_HOME/data/backlog.md" | sed 's/^/    /'
echo "--- other host's open item under the same title takes the occurrence"
(cd "$FM_HOME" && env "$RAW" tasks-axi add fm-timeout-otherhost "Measure and repair repeated timeout: acme/widgets lab.shared" --kind ship --body "filed on host other-host" >/dev/null)
tmo lab.shared s1
tmo lab.shared s2
"$W" show fm-timeout-otherhost --full 2>&1 | grep 'body:' | sed 's/^/    /'
grep -c 'lab.shared' "$FM_HOME/data/backlog.md" | sed 's/^/    rows naming lab.shared: /'
echo "--- a hand-filed, closed and archived neighbour goes to the operator, nothing filed"
(cd "$FM_HOME" && env "$RAW" tasks-axi add hand-raise "Raise the lab archived timeout" --kind ship >/dev/null && env "$RAW" tasks-axi done hand-raise --note "raised by hand" --keep 0 >/dev/null)
tmo lab.archived a1
tmo lab.archived a2
grep -c 'lab.archived' "$FM_HOME/data/backlog.md" | sed 's/^/    rows naming lab.archived: /'
show backlog-review.tsv "$FM_HOME/data/backlog-review.tsv"
echo "--- ledger filed rows:"
jq -rc 'select(.event=="filed") | [.key, .task] | @tsv' "$FM_HOME/data/command-durations.jsonl" | sed 's/^/    /'
show "final backlog.md" "$FM_HOME/data/backlog.md"
