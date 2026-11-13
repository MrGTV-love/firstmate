#!/usr/bin/env bash
# SC4(a): with FM_SLACK_SECOND_USER unset, run the same owner-only session through the real entry points of the base tree
# (9d516486, extracted with git archive) and of the head tree, each in its own disposable FM_HOME, and compare what the owner
# path produces: every command's output, every Slack call the replay saw, the plane's state keys, and the files the plane wrote.
# Usage: owner-path-base-vs-head.sh <head repo root> <base tree> <work dir>
set -uo pipefail
HEAD_ROOT=$1; BASE_ROOT=$2; WORK=$3
export FM_SLACK_NO_NETWORK=1
run_tree() {  # <tree> <label>
  local R=$1 L=$2 D="$WORK/$2"
  local HELPER="$R/tests/fm_slack_watch_test.py"
  bash "$R/tests/fixtures/slack/make-home.sh" typed-reply "$D" >/dev/null
  export FM_HOME="$D" FM_STATE_OVERRIDE="$D/state" FM_DATA_OVERRIDE="$D/data" FM_CONFIG_OVERRIDE="$D/config"
  unset FM_SLACK_SECOND_USER
  # The same transcript bytes for both trees (the base has no second-person fixture; its owner part is what matters).
  cp "$HEAD_ROOT/tests/fixtures/slack/second-person/transcript.json" "$D/transcript.json"
  local TS="$D/transcript.json" OUT="$WORK/$L.out"
  {
    "$R/bin/fm-captain-hold.sh" bind slack-dm >/dev/null
    echo "## arm"; "$R/bin/fm-slack-check.sh" arm --replay "$TS"; echo "rc=$?"
    echo "## mirror"; "$R/bin/fm-slack-mirror.sh" --replay "$TS"; echo "rc=$?"
    echo "## poll 1"; "$R/bin/fm-slack-poll.sh" --replay "$TS"; echo "rc=$?"
    RP=$(python3 "$HELPER" replay-file "$D/state/slack-watch")
    python3 "$HELPER" owner-message "$RP" 3000.000100 U0TESTOWNER 'owner: what is the d7 status? <https://x.example|link> & 1'
    python3 "$HELPER" owner-message "$RP" 3000.000200 U0CDVHFU1A5 'scott words while he is not configured' '{"channel": "D0SECONDDM1"}'
    echo "## poll 2"; "$R/bin/fm-slack-poll.sh" --replay "$TS"; echo "rc=$?"
    echo "## read"; "$R/bin/fm-slack-read.sh" --thread 3000.000100 --replay "$TS"; echo "rc=$?"
    echo "## reply"; printf 'd7 is merged.' | "$R/bin/fm-slack-reply.sh" --thread 3000.000100 --to 3000.000100 --replay "$TS"; echo "rc=$?"
    CARD=$(python3 -c 'import json,sys; print(next(r["ts"] for r in json.load(open(sys.argv[1]))["threads"].values() if r["key"]=="typed-call"))' "$D/state/slack-watch/state.json")
    python3 "$HELPER" reply "$RP" "$CARD" 3000.000300 U0TESTOWNER 2
    echo "## poll 3 (owner answers the card)"; "$R/bin/fm-slack-poll.sh" --replay "$TS"; echo "rc=$?"
    echo "## check"; "$R/bin/fm-slack-check.sh" check --replay "$TS"; echo "rc=$?"
    echo "## outbound calls"; python3 -c 'import json,sys; [print(json.dumps({k:v for k,v in json.loads(l).items()}, sort_keys=True)) for l in open(sys.argv[1])]' "$D/state/slack-watch/outbound.jsonl"
    echo "## state keys"; python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1])).keys()))' "$D/state/slack-watch/state.json"
    echo "## plane files"; (cd "$D/state/slack-watch" && ls | sed 's/replay-state-.*/replay-state-<digest>.json/' | sort)
    echo "## request record"; cat "$D/state/slack-watch/requests.jsonl" 2>/dev/null
  } > "$OUT" 2>&1
  # Normalize the home path, which differs between the two runs.
  sed -i '' "s#$D#<HOME>#g" "$OUT"
}
run_tree "$BASE_ROOT" base
run_tree "$HEAD_ROOT" head
echo "=== head run output (setting unset) ==="
cat "$WORK/head.out"
echo "=== diff base vs head ==="
if diff -u "$WORK/base.out" "$WORK/head.out"; then echo "IDENTICAL: the owner path output, Slack calls, state keys and plane files are the same at base and head"; else echo "DIFFERENT"; exit 1; fi
