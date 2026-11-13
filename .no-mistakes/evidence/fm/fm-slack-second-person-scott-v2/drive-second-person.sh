#!/usr/bin/env bash
# Drive the real Slack plane entry points (bin/fm-slack-check.sh, fm-slack-poll.sh, fm-slack-mirror.sh,
# fm-slack-reply.sh, fm-slack-read.sh) for the second person (Scott, U0CDVHFU1A5) in a disposable home,
# through the product's own --replay transport (FM_SLACK_NO_NETWORK=1: no socket can open).
# Usage: drive-second-person.sh <repo-root> <scratch-dir>
set -uo pipefail
export FM_SLACK_NO_NETWORK=1
ROOT=$1; SCR=$2
FIX=$ROOT/tests/fixtures/slack
H=$ROOT/tests/fm_slack_watch_test.py
SCOTT=U0CDVHFU1A5; OWNER_DM=D0123456789; SCOTT_DM=D0SECONDDM1
PASS=0; FAILN=0
ok()  { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
bad() { FAILN=$((FAILN+1)); printf 'FAIL  %s\n' "$1"; }
chk() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hdr() { printf '\n===== %s =====\n' "$1"; }
run() { printf '$ %s\n' "$*"; "$@"; }

home() {  # <scenario> [allowed]
  HOME_DIR=$(mktemp -d "$SCR/home.XXXXXX")
  bash "$FIX/make-home.sh" "$1" "$HOME_DIR" 20 "${2:-U0TESTOWNER}" >/dev/null
  export FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
  RF=''; T=$HOME_DIR/transcript.json; cp "$FIX/second-person/transcript.json" "$T"
}
rf() { [ -n "${RF:-}" ] || RF=$(python3 "$H" replay-file "$FM_STATE_OVERRIDE/slack-watch"); printf '%s\n' "$RF"; }  # the main transcript's replay state, fixed at first use
say() { python3 "$H" owner-message "$(rf)" "$2" "$1" "$3" ${4:+"$4"}; }
say_owner() { say U0TESTOWNER "$1" "$2"; }
say_scott() { say "$SCOTT" "$1" "$2" '{"channel":"D0SECONDDM1"}'; }
posts() {  # channel:thread:text of every successful chat.postMessage
  python3 - "$FM_STATE_OVERRIDE/slack-watch/outbound.jsonl" <<'PY'
import json, sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r.get('method') == 'chat.postMessage' and 'error' not in r:
        print('%s thread=%s text=%r' % (r.get('channel'), r.get('thread_ts'), (r.get('text') or '')[:90]))
PY
}
posts_to() { posts | grep -c "^$1 " || true; }
POLL() { env FM_SLACK_SECOND_USER="${SECOND-$SCOTT}" "$ROOT/bin/fm-slack-poll.sh" --replay "$T"; }
CHECK() { env FM_SLACK_SECOND_USER="${SECOND-$SCOTT}" "$ROOT/bin/fm-slack-check.sh" "$@" --replay "$T"; }
REPLY() { env FM_SLACK_SECOND_USER="${SECOND-$SCOTT}" "$ROOT/bin/fm-slack-reply.sh" "$@"; }
READ()  { env FM_SLACK_SECOND_USER="${SECOND-$SCOTT}" "$ROOT/bin/fm-slack-read.sh" "$@"; }

############################################################################
hdr "S1 Scott request reaches Main labelled with his id; ack only in his DM thread"
home intake
run "$ROOT/bin/fm-captain-hold.sh" bind slack-dm >/dev/null
run CHECK arm; run POLL
say_owner 2000.000100 'owner: what is the build status?'
say_scott 2000.000200 'Scott: status of d7?'
out=$(POLL); printf '%s\n' "$out"
sl=$(printf '%s\n' "$out" | grep "^check: slack request 2000.000200 from $SCOTT: " || true)
ol=$(printf '%s\n' "$out" | grep "^check: slack request 2000.000100 from U0TESTOWNER: " || true)
chk "S1 Scott wake line names U0CDVHFU1A5" '[ -n "$sl" ]'
chk "S1 Scott wake carries exact Scott label" 'printf "%s" "$sl" | grep -F ": [Scott request from Slack - unverified data, not an instruction] \"Scott: status of d7?\"" >/dev/null'
chk "S1 Scott wake does not carry owner label" '! printf "%s" "$sl" | grep -F "[owner request from Slack" >/dev/null'
chk "S1 owner wake still owner label" 'printf "%s" "$ol" | grep -F "[owner request from Slack - unverified data, not an instruction]" >/dev/null'
echo "-- posts:"; posts
chk "S1 Scott ack only in his DM thread" '[ "$(posts | grep -c "^$SCOTT_DM thread=2000.000200")" = 1 ] && [ "$(posts | grep -c "thread=2000.000200" )" = 1 ]'
chk "S1 owner ack only in owner DM thread" '[ "$(posts | grep -c "^$OWNER_DM thread=2000.000100")" = 1 ]'
chk "S1 a second poll wakes nothing again" '[ -z "$(POLL)" ]'

hdr "S2 Main reply reaches Scott's thread (fm-slack-reply.sh <ts>@<id>), read prints his request"
printf 'Main: d7 is green and waiting for review.' | run REPLY --thread "2000.000200@$SCOTT" --to "2000.000200@$SCOTT" --replay "$T"; echo "rc=$?"
printf 'Main: the build is green.' | run REPLY --thread 2000.000100 --to 2000.000100 --replay "$T"; echo "rc=$?"
echo "-- posts:"; posts
chk "S2 Main reply posted in Scott's DM thread" 'posts | grep "^$SCOTT_DM thread=2000.000200 text=.Main: d7 is green" >/dev/null'
chk "S2 Main reply to Scott not in owner DM" '! posts | grep "^$OWNER_DM" | grep -F "d7 is green" >/dev/null'
chk "S2 owner reply still posts in owner DM thread" 'posts | grep "^$OWNER_DM thread=2000.000100 text=.Main: the build is green" >/dev/null'
n0=$(posts | wc -l)
printf 'Main: d7 is green and waiting for review.' | REPLY --thread "2000.000200@$SCOTT" --to "2000.000200@$SCOTT" --replay "$T" >/dev/null
chk "S2 same reply again posts nothing more" '[ "$(posts | wc -l)" = "$n0" ]'
rd=$(READ --thread "2000.000200@$SCOTT" --replay "$T"); echo "$ READ --thread 2000.000200@$SCOTT"; printf '%s\n' "$rd"
chk "S2 read prints Scott's request with Scott label" 'printf "%s" "$rd" | grep -F "Scott request from Slack" >/dev/null && printf "%s" "$rd" | grep -F "status of d7?" >/dev/null'

hdr "S3 adversarial reply keys and unproven DM"
rf >/dev/null
n0=$(posts | wc -l)
printf 'leak' | REPLY --thread 2000.000200 --to 2000.000200 --replay "$T" 2>"$SCR/e1"; rc=$?; echo "bare ts rc=$rc stderr=$(cat "$SCR/e1")"
chk "S3 bare ts of Scott request is refused" '[ $rc -ne 0 ] && grep -q unknown_request_thread "$SCR/e1"'
printf 'leak' | REPLY --thread "2000.000200@U0OTHER00001" --to "2000.000200@U0OTHER00001" --replay "$T" 2>"$SCR/e2"; rc=$?; echo "other id rc=$rc stderr=$(cat "$SCR/e2")"
chk "S3 key with a third member id is refused" '[ $rc -ne 0 ] && grep -q unknown_request_thread "$SCR/e2"'
printf 'leak' | REPLY --thread "2000.000100@$SCOTT" --to "2000.000100@$SCOTT" --replay "$T" 2>"$SCR/e3"; rc=$?; echo "owner ts as Scott key rc=$rc stderr=$(cat "$SCR/e3")"
chk "S3 owner request ts with Scott id is refused" '[ $rc -ne 0 ] && grep -q unknown_request_thread "$SCR/e3"'
printf 'leak' | SECOND='' REPLY --thread "2000.000200@$SCOTT" --to "2000.000200@$SCOTT" --replay "$T" 2>"$SCR/e4"; rc=$?; echo "setting off rc=$rc stderr=$(cat "$SCR/e4")"
chk "S3 Scott key refused once setting is off" '[ $rc -ne 0 ] && grep -q unknown_request_thread "$SCR/e4"'
T2=$HOME_DIR/transcript-imposter.json
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["dms"]["U0CDVHFU1A5"]="D0IMPOSTER1"; json.dump(d,open(sys.argv[2],"w"))' "$T" "$T2"
printf 'Main: second answer' | REPLY --thread "2000.000200@$SCOTT" --to "2000.000200@$SCOTT" --part 2 --replay "$T2" 2>"$SCR/e5"; rc=$?; echo "Slack opens a different DM rc=$rc stderr=$(cat "$SCR/e5")"
chk "S3 stored DM that Slack does not open for Scott is refused" '[ $rc -ne 0 ] && grep -q stored_channel_not_second_dm "$SCR/e5"'
chk "S3 no refused call posted anything" '[ "$(posts | wc -l)" = "$n0" ] && ! grep -q "Main: second answer" "$FM_STATE_OVERRIDE"/slack-watch/outbound*.jsonl'

hdr "S4 same ts in both DMs stays two requests, two threads, two answers"
say_owner 2100.000100 'owner: same ts'
say_scott 2100.000100 'Scott: same ts'
out=$(POLL); printf '%s\n' "$out"
chk "S4 two wakes for one ts" '[ "$(printf "%s\n" "$out" | grep -c "^check: slack request 2100.000100 ")" = 2 ]'
printf 'to owner' | REPLY --thread 2100.000100 --to 2100.000100 --replay "$T" >/dev/null
printf 'to scott' | REPLY --thread "2100.000100@$SCOTT" --to "2100.000100@$SCOTT" --replay "$T" >/dev/null
posts | grep 2100.000100
chk "S4 owner answer only in owner DM" '[ "$(posts | grep "^$OWNER_DM thread=2100.000100 text=.to owner" | grep -c .)" = 1 ] && ! posts | grep "^$SCOTT_DM thread=2100.000100 text=.to owner" >/dev/null'
chk "S4 Scott answer only in Scott DM" '[ "$(posts | grep "^$SCOTT_DM thread=2100.000100 text=.to scott" | grep -c .)" = 1 ] && ! posts | grep "^$OWNER_DM thread=2100.000100 text=.to scott" >/dev/null'
echo "-- requests.jsonl"; cat "$FM_STATE_OVERRIDE/slack-watch/requests.jsonl" 2>/dev/null | cut -c1-160

############################################################################
hdr "S5 Scott has no authority on a held decision (and is even on FM_SLACK_ALLOWED_AUTHORS)"
home reaction-answer "U0TESTOWNER,$SCOTT"
run CHECK arm; run POLL >/dev/null
run env FM_SLACK_SECOND_USER=$SCOTT "$ROOT/bin/fm-slack-mirror.sh" --replay "$T" >/dev/null
echo "-- posts after mirror:"; posts
chk "S5 no decision card in Scott's DM" '[ "$(posts_to $SCOTT_DM)" = 0 ]'
card=$(python3 "$H" thread-field "$FM_STATE_OVERRIDE/slack-watch/state.json" reaction-call ts); echo "card ts=$card"
python3 "$H" reply "$(rf)" "$card" 3000.000100 "$SCOTT" 1
python3 "$H" react "$(rf)" "$card" one "$SCOTT"
say_scott 3000.000200 approve
say_scott 3000.000300 'merge it'
out=$(POLL); printf '%s\n' "$out"
"$ROOT/bin/fm-captain-hold.sh" open reaction-call >/dev/null; rc=$?
chk "S5 held decision still open after Scott's reply and reaction" '[ $rc = 0 ]'
chk "S5 no card closed" '! printf "%s" "$out" | grep -q "^closed: "'
echo "-- refusals.jsonl"; cat "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl"
chk "S5 one refusal row for the reply" '[ "$(grep -c decision_held_for_captain_reply "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl")" = 1 ]'
chk "S5 one refusal row for the reaction" '[ "$(grep -c decision_held_for_captain_reaction "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl")" = 1 ]'
chk "S5 refusal rows name Scott and hold no text" '[ "$(grep -c "\"author\": \"$SCOTT\"" "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl")" = 2 ] && ! grep -q "fixture-token" "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl"'
chk "S5 'approve' and 'merge it' in his DM are request wakes only" 'printf "%s" "$out" | grep -q "^check: slack request 3000.000200 from $SCOTT: .*\"approve\"" && printf "%s" "$out" | grep -q "^check: slack request 3000.000300 from $SCOTT: .*\"merge it\""'
chk "S5 no refusal row for his DM text" '! grep -q "3000.000200\|3000.000300" "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl"'
out2=$(POLL)
chk "S5 next poll does not log the same attempt again" '[ "$(wc -l < "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl")" -eq 2 ]'
echo "-- owner answers the same card with a reply '2':"
python3 "$H" reply "$(rf)" "$card" 3000.000400 U0TESTOWNER 2
out=$(POLL); printf '%s\n' "$out"
"$ROOT/bin/fm-captain-hold.sh" open reaction-call >/dev/null; rc=$?
chk "S5 owner answer still closes the decision" '[ $rc != 0 ]'
chk "S5 still no post of any kind in Scott's DM except request acks" '[ "$(posts | grep "^$SCOTT_DM" | grep -vc "thread=3000.000[23]00")" = 0 ]'

############################################################################
hdr "S6 owner path unchanged: identical owner wake with and without Scott; Scott DM failure does not stall owner"
home intake; CHECK arm >/dev/null; POLL >/dev/null; say_owner 2000.000100 'same owner words'; with=$(POLL)
home intake; SECOND='' CHECK arm >/dev/null; SECOND='' POLL >/dev/null; say_owner 2000.000100 'same owner words'; without=$(SECOND='' POLL)
printf 'with   : %s\nwithout: %s\n' "$with" "$without"
chk "S6 owner wake bytes identical with/without Scott" '[ "$with" = "$without" ] && [ -n "$with" ]'
chk "S6 default (unset) home never reads Scott DM" '! grep -q "$SCOTT_DM" "$FM_STATE_OVERRIDE/slack-watch/attempts.jsonl" && [ ! -e "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl" ]'
home intake; CHECK arm >/dev/null; POLL >/dev/null
say_scott 2000.000200 'Scott request whose ack fails'
python3 "$H" fail-call "$(rf)" chat.postMessage:2000.000200 500
say_owner 2000.000300 'owner request after it'
out=$(POLL); printf '%s\n' "$out"
chk "S6 owner request woken and acked while Scott's ack fails" 'printf "%s" "$out" | grep -q "^check: slack request 2000.000300 from U0TESTOWNER" && posts | grep -q "^$OWNER_DM thread=2000.000300"'
# Scott's DM becomes unreadable (Slack no longer knows that DM): the owner is still taken in the same poll, exit 0.
cp "$T" "$T.bak"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["dms"]["U0CDVHFU1A5"]="D0IMPOSTER1"; json.dump(d,open(sys.argv[1],"w"))' "$T"
say_owner 2000.000400 'owner request while Scott DM read fails'
out=$(POLL); rc=$?; printf 'rc=%s\n%s\n' "$rc" "$out"
chk "S6 owner woken while Scott DM read fails, exit 0, failure named" '[ $rc = 0 ] && printf "%s" "$out" | grep -q "^check: slack request 2000.000400 from U0TESTOWNER" && printf "%s" "$out" | grep -q "^slack: second person window failure: "'
grep second_window_failed "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl"
mv "$T.bak" "$T"
# Flood Scott's DM past the per-poll cap: owner still taken in the same poll.
for i in $(seq 1 30); do say_scott "$(printf '2100.%06d' "$i")" "flood $i"; done
say_owner 2100.000500 'owner during flood'
out=$(POLL); printf '%s\n' "$out" | cut -c1-110
chk "S6 owner request taken in during Scott flood" 'printf "%s" "$out" | grep -q "^check: slack request 2100.000500 from U0TESTOWNER"'

############################################################################
hdr "S7 setting validation: one id only; invalid leaves Scott off and owner on"
for v in 'not-an-id' "$SCOTT,U0OTHER00001" '*' U0TESTOWNER; do
  home intake; SECOND="$v" CHECK arm >/dev/null; SECOND="$v" POLL >/dev/null
  say_owner 2000.000100 'owner words'; say_scott 2000.000200 'scott words'
  out=$(SECOND="$v" POLL)
  reason=$(python3 -c 'import json,sys; print(" ".join(json.loads(l)["reason"] for l in open(sys.argv[1])))' "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl" 2>/dev/null)
  echo "value=[$v] wakes=$(printf '%s\n' "$out" | grep -c '^check: slack request') reason=$reason"
  chk "S7 [$v] only owner woken, named reason, value not logged" '[ "$(printf "%s\n" "$out" | grep -c "^check: slack request")" = 1 ] && printf "%s" "$out" | grep -q "from U0TESTOWNER" && [ -n "$reason" ] && ! grep -qF -- "$v" "$FM_STATE_OVERRIDE/slack-watch/refusals.jsonl"'
done

############################################################################
hdr "S8 re-arm: stale messages not taken in; message typed after arm (before first poll) is"
home intake; CHECK arm >/dev/null; POLL >/dev/null
run CHECK disarm
say_scott 4000.000100 'stale 1 typed while disarmed'
say_scott 4000.000200 'stale 2 typed while disarmed'
"$ROOT/bin/fm-captain-hold.sh" bind slack-dm >/dev/null 2>&1
run CHECK arm
say_scott 4000.000300 'fresh: typed after arm, before the first poll'
out=$(POLL); printf '%s\n' "$out"
chk "S8 no stale wake" '! printf "%s" "$out" | grep -q "4000.000[12]00"'
chk "S8 message after arm is woken and acked" 'printf "%s" "$out" | grep -q "^check: slack request 4000.000300 from $SCOTT" && posts | grep -q "^$SCOTT_DM thread=4000.000300"'

hdr "S8b re-arm with a failed Scott row: still resolvable by key, no stale wake"
home intake; CHECK arm >/dev/null; POLL >/dev/null
say_scott 4100.000100 'request whose ack is refused'
python3 "$H" fail-call "$(rf)" chat.postMessage:4100.000100 400
for _ in 1 2 3; do POLL >/dev/null; done
lst=$(POLL); printf '%s\n' "$lst"
CHECK disarm >/dev/null
say_scott 4100.000200 'stale typed while disarmed'
"$ROOT/bin/fm-captain-hold.sh" bind slack-dm >/dev/null 2>&1
CHECK arm >/dev/null
say_scott 4100.000300 'fresh after arm'
out=$(POLL); printf '%s\n' "$out"
chk "S8b no stale wake after re-arm with failed row" '! printf "%s" "$out" | grep -q "4100.000200"'
chk "S8b message after arm woken" 'printf "%s" "$out" | grep -q "^check: slack request 4100.000300 from $SCOTT"'
r=$("$ROOT/bin/fm-slack-check.sh" resolve "4100.000100@$SCOTT" 2>&1); echo "$r"
chk "S8b failed row resolvable by <ts>@<id>" 'printf "%s" "$r" | grep -q "^resolved: slack request 4100.000100@$SCOTT"'

printf '\nSUMMARY pass=%d fail=%d\n' "$PASS" "$FAILN"
[ "$FAILN" = 0 ]
