#!/usr/bin/env bash
# LABELED fixture quota transitions (fake gh-axi on PATH), real owner, real ps, real fixture callers.
# Never touches the account. Proves a cold reader can join records alone.
set -u
EV=$1; . "$EV/drivers/common.sh"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; export FM_HOME; echo "lab_home=$FM_HOME"
FIX="$FM_HOME/fixtures"; make_caller "$FIX"; mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh-axi" <<'F'
#!/bin/sh
d=$(dirname "$0")/..
n=$(cat "$d/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$d/n"
printf '%s\n' "$*" >> "$d/argv.log"
case $n in
 1) printf 'api_response:\n  body: used=100 reset=1794000000 limit=5000 remaining=4900\n';;
 2) printf 'api_response:\n  body: used=120 reset=1794000000 limit=5000 remaining=4880\n';;
 3) printf 'api_response:\n  body: used=4900 reset=1794000000 limit=5000 remaining=100\n';;
 4) printf 'api_response:\n  body: used=5000 reset=1794000000 limit=5000 remaining=0\n';;
 5) printf 'api_response:\n  body: used=1 reset=2 limit=3 remaining=4\n'; echo "API rate limit already exceeded" >&2; exit 1;;
 6) printf 'api_response:\n  body: used=oops\n';;
 7) printf 'api_response:\n  body: used=7 reset=1794003600 limit=null remaining=null\n';;
 *) printf 'api_response:\n  body: used=9 reset=1794003600 limit=5000 remaining=4991\n';;
esac
F
chmod +x "$FIX/bin/gh-axi"; export PATH="$FIX/bin:$PATH"
at() { until [ "$(cat "$FIX/n" 2>/dev/null || echo 0)" -ge "$1" ]; do sleep 0.1; done; }
mkdir -p "$FIX/quiet" "$FIX/burst"; make_caller "$FIX/quiet"; make_caller "$FIX/burst"
python3 "$OWNER" start; echo "start_exit=$?"
at 1; sleep 3
# QUIET lives only inside interval 1->2. BURST lives only inside interval 2->3.
( FIX_SECS=4 "$FIX/quiet/fixture-parent.sh" "$FIX/quiet/gh" pr view & wait ) &
at 2; sleep 3
( FIX_SECS=6 "$FIX/burst/fixture-parent.sh" "$FIX/burst/gh" api graphql --paginate & wait ) &
at 8; sleep 2
python3 "$OWNER" stop; echo "stop_exit=$?"
python3 "$OWNER" records > "$EV/s2-all.jsonl"; echo "records_exit=$?"
echo "--- exact argv the owner gave gh-axi (unique)"; sort -u "$FIX/argv.log"
wait 2>/dev/null
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo "teardown_exit=$?"
