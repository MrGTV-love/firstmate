#!/bin/bash
# Live real CLI checks on gate HEAD: refresh --detach default/registry/missing, fm-duration keep-going --record,
# and fm_test_wait_processes against pending, partial, dead and live records. Owned root only; exact-pid cleanup.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M60X7EHPFP3WC1T7VVP0W6VM
R=$(mktemp -d "$HOME/tmp/nm-r8-live.XXXXXX"); R=$(cd -P "$R" && pwd -P)
echo "head=$(git -C "$WT" rev-parse HEAD) bash=$BASH_VERSION root=<R>"
mkhome() { mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"; }
wait_pub() { local i=0; while [ ! -s "$1/state/home-summary.json" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done; }
lib() { ( export TMPDIR=$R/libtmp; mkdir -p "$TMPDIR"; "$@" ); }
s() { sed "s#$R#<R>#g"; }

echo "== 1. registry UNSET (default product path): --detach"
mkhome "$R/unset-home"
t0=$(python3 -c 'import time;print(time.monotonic())')
env -u FM_TEST_PROCESS_REGISTRY -u FM_TEST_PROCESS_RECORD FM_HOME="$R/unset-home" "$WT/bin/fm-home-summary-refresh.sh" --detach; rc=$?
t1=$(python3 -c 'import time;print(time.monotonic())')
echo "exit=$rc return_secs=$(python3 -c "print(round($t1-$t0,3))")"
wait_pub "$R/unset-home"; sleep 2
[ -s "$R/unset-home/state/home-summary.json" ] && echo "published: $(jq -r .schema "$R/unset-home/state/home-summary.json")" || echo "published: none"
echo "files in root other than unset-home: $(ls -A "$R" | grep -v -c -e unset-home -e libtmp)"

echo; echo "== 2. registry SET: --detach"
mkhome "$R/reg-home"; : > "$R/registry"
FM_TEST_PROCESS_REGISTRY="$R/registry" FM_HOME="$R/reg-home" "$WT/bin/fm-home-summary-refresh.sh" --detach; rc=$?
echo "exit=$rc"
echo "registry immediately after return:"; s < "$R/registry" | sed 's/\.[A-Za-z0-9]\{6\}\t/.XXXXXX\t/'
first=$(head -1 "$R/registry" | cut -f1); fpid=$(head -1 "$first" 2>/dev/null)
echo "first record filled at return: $( [ -n "$fpid" ] && echo "yes pid=$fpid" || echo no)"
wait_pub "$R/reg-home"
echo "published: $(jq -r .schema "$R/reg-home/state/home-summary.json" 2>/dev/null || echo none)"
echo "record labels:"; cut -f2,3 "$R/registry" | sort | uniq -c
echo "-- fm_test_wait_processes on that registry (bound 60 s):"
lib env FM_TEST_PROCESS_WAIT_SECONDS=60 bash -c ". '$WT/tests/lib.sh' >/dev/null 2>&1; fm_test_wait_processes '$R/registry'; echo \"  wait rc=\$?\"" 
echo "records left: $(ls "$R" | grep -c '^registry\.')  registry kept: $([ -e "$R/registry" ] && echo yes || echo no)"
diff <(jq -S 'del(.generated,.generated_epoch)' "$R/unset-home/state/home-summary.json") <(jq -S 'del(.generated,.generated_epoch)' "$R/reg-home/state/home-summary.json") | s && echo "summary unset vs set: identical except generated fields"

echo; echo "== 3. ADVERSARIAL registry set to a missing file: --detach"
FM_TEST_PROCESS_REGISTRY="$R/missing-registry" FM_HOME="$R/badreg-home" "$WT/bin/fm-home-summary-refresh.sh" --detach 2>&1 | s; echo "exit=${PIPESTATUS[0]}"
sleep 3
echo "home created: $([ -e "$R/badreg-home" ] && echo yes || echo no); missing registry created: $([ -e "$R/missing-registry" ] && echo yes || echo no)"

echo; echo "== 4. fm-duration.py keep-going --record fills the child group pid"
: > "$R/kg-record"
python3 "$WT/bin/fm-duration.py" keep-going --record "$R/kg-record" 30 -- bash -c 'echo "child pid=$$ pgid=$(ps -o pgid= -p $$ | tr -d " ")"'; echo "exit=$?"
echo "record content: $(od -c "$R/kg-record" | head -2 | tr -s ' ')"
echo "-- keep-going without --record (default) still runs:"; python3 "$WT/bin/fm-duration.py" keep-going 30 -- echo plain-ok; echo "exit=$?"

echo; echo "== 5. ADVERSARIAL wait records (fm_test_wait_processes, bound 1 s)"
sleep 300 & live=$!
pfx=${live%?}   # pid with last digit cut: a partial write of the live pid
: > "$R/adv-reg"
mk() { local f; f=$(mktemp "$R/adv-reg.XXXXXX"); printf '%s\t%s\twait\n' "$f" "$1" >> "$R/adv-reg"; printf "$2" > "$f"; }
mk pending-empty ''
mk partial-no-newline "$pfx"
echo "live pid=$live partial prefix=$pfx (prefix alive: $(kill -0 $pfx 2>/dev/null && echo y || echo n))"
lib env FM_TEST_PROCESS_WAIT_SECONDS=1 bash -c ". '$WT/tests/lib.sh' >/dev/null 2>&1; fm_test_wait_processes '$R/adv-reg'; echo \"  wait rc=\$?\"" 2>&1 | s | sed 's/\.[A-Za-z0-9]\{6\} (/.XXXXXX (/g'
echo "registry kept: $([ -e "$R/adv-reg" ] && echo yes || echo no); records kept: $(ls "$R" | grep -c '^adv-reg\.')"
: > "$R/adv2"; mk2() { local f; f=$(mktemp "$R/adv2.XXXXXX"); printf '%s\t%s\twait\n' "$f" "$1" >> "$R/adv2"; printf "$2" > "$f"; }
mk2 live-full "$live\n"
lib env FM_TEST_PROCESS_WAIT_SECONDS=1 bash -c ". '$WT/tests/lib.sh' >/dev/null 2>&1; fm_test_wait_processes '$R/adv2'; echo \"  live full record wait rc=\$?\"" 2>&1 | s | sed 's/\.[A-Za-z0-9]\{6\} (/.XXXXXX (/g'
kill "$live"; wait "$live" 2>/dev/null
lib env FM_TEST_PROCESS_WAIT_SECONDS=5 bash -c ". '$WT/tests/lib.sh' >/dev/null 2>&1; fm_test_wait_processes '$R/adv2'; echo \"  after exact kill of $live: wait rc=\$?\"" 2>&1 | s
echo "adv2 records left: $(ls "$R" | grep -c '^adv2\.')"
: > "$R/adv3"; f=$(mktemp "$R/adv3.XXXXXX"); printf '%s\tjunk\twait\n' "$f" >> "$R/adv3"; printf 'abc\n' > "$f"
lib env FM_TEST_PROCESS_WAIT_SECONDS=1 bash -c ". '$WT/tests/lib.sh' >/dev/null 2>&1; fm_test_wait_processes '$R/adv3'; echo \"  non-numeric record wait rc=\$?\"" 2>&1 | s | sed 's/\.[A-Za-z0-9]\{6\} (/.XXXXXX (/g'

echo; echo "== cleanup of owned root (evidence retained above)"
rm -rf "$R"; echo "root removed: $([ -e "$R" ] && echo no || echo yes)"
