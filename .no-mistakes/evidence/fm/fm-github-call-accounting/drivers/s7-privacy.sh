#!/usr/bin/env bash
# Real ps sees a battery of secret-shaped arguments and a secret-bearing ancestor chain. No canary may reach state.
set -u
EV=$1; . "$EV/drivers/common.sh"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"; export FM_HOME; echo "lab_home=$FM_HOME"
FIX="$FM_HOME/fixtures"; make_caller "$FIX"; mkdir -p "$FIX/bin"
cat > "$FIX/bin/gh-axi" <<'F'
#!/bin/sh
printf 'api_response:\n  body: used=1 reset=1794000000 limit=5000 remaining=4999\n'
F
chmod +x "$FIX/bin/gh-axi"; export PATH="$FIX/bin:$PATH"
G="$FIX/gh"; export FIX_SECS=8 GH_TOKEN=CANARY01_env_token
python3 "$OWNER" start >/dev/null
"$G" api graphql -f query=CANARY02 & 
"$G" api user --header "Authorization: token CANARY03" &
"$G" api --header="Authorization: Bearer CANARY04" /user &
"$G" pr create --title CANARY05 --body=CANARY06 --body-file /tmp/CANARY07 &
"$G" auth login --with-token CANARY08 &
"$G" api "https://api.github.com/user?access_token=CANARY09" &
"$G" CANARY10 --repo=CANARY11/x -R CANARY12 --jq '.[]|CANARY13' &
"$G" -fquery=CANARY14 --unknown-option CANARY15 --unknown=CANARY16 &
bash -c "$G api CANARY17; true" &
/bin/sh -c "$G pr view CANARY18; true" &
zsh -f -c "$G pr view CANARY19; true" &
python3 -c "import subprocess,sys; subprocess.call(['$G','api','CANARY20']); print('CANARY21')" &
python3 -W CANARY22 -X CANARY23 -c "import subprocess; subprocess.call(['$G','api','x'])" &
perl -e 'system(@ARGV); # CANARY24' "$G" api y &
"$FIX/fixture-parent.sh" "$G" api z CANARY25 &
sleep 6
python3 "$OWNER" stop >/dev/null
python3 "$OWNER" records > "$FIX/all.jsonl"
S="$FM_HOME/state/github-accounting"
echo "fixture callers seen: $(grep -c '"argv": \["sh", "gh"' "$FIX/all.jsonl")"
echo "--- canaries in records:"; grep -o 'CANARY[0-9]*' "$FIX/all.jsonl" | sort -u || true; echo "count=$(grep -c CANARY "$FIX/all.jsonl")"
echo "--- canaries in raw state bytes:"; grep -al CANARY "$S"/* || echo none
strings "$S/observations.sqlite" | grep -c CANARY
echo "--- token-shaped in records:"; grep -cE 'ghp_|Bearer|Authorization|access_token' "$FIX/all.jsonl"
python3 - "$FIX/all.jsonl" <<'PY'
import json,sys
seen=set()
for l in open(sys.argv[1]):
    r=json.loads(l)
    if r["kind"]=="process" and r["argv"][:2]==["sh","gh"]:
        a=[x["argv"] for x in r["ancestors"][:1]]
        k=json.dumps((r["argv"],a))
        if k not in seen: seen.add(k); print(r["argv"],"parent",a[0] if a else None)
PY
wait 2>/dev/null
bin/fm-lab-home.sh teardown "$FM_HOME" && rm -rf "$FM_HOME"; echo "teardown_exit=$?"
