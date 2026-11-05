#!/usr/bin/env bash
# Usage: live-web-run.sh <git-rev> <label>. Run from the repo worktree. The rev is exported by value
# into a clean lab code root; the watcher refuses to arm from a .no-mistakes/worktrees path.
# Drives a real private `dsh --profile web` server with the real .dsh/fm-primary.mjs,
# real bin/fm-lock.sh, real inspect, real watcher, in a disposable marked lab home.
set -u
EV=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LABEL=$2; WORKTREE=$PWD
export PATH="$HOME/.nvm/versions/node/$(ls "$HOME/.nvm/versions/node" | tail -1)/bin:$PATH"
REV=$1; DRIVER=$EV/lab-driver.mjs
eval "$(bin/fm-lab-home.sh env 2>/dev/null)"
HOME_LAB=$FM_HOME; STATE=$HOME_LAB/state; LAB=$(mktemp -d /tmp/fmweb.XXXXXX)
. "$EV/live-web-lib.sh"
CODE=$LAB/code; mkdir "$CODE"; git archive "$REV" | tar -x -C "$CODE"
cleanup() {
  chflags nouchg "$STATE/.lock" "$STATE/.lock-session" 2>/dev/null; chmod 755 "$STATE" 2>/dev/null
  stop_servers
  bash "$WORKTREE/bin/fm-lab-home.sh" teardown "$HOME_LAB" >/dev/null 2>&1
  rm -rf "$HOME_LAB" "$LAB"
  printf '\nlab removed: home=%s lab=%s\n' "$([ -e "$HOME_LAB" ] && echo no || echo yes)" "$([ -e "$LAB" ] && echo no || echo yes)"
}
trap cleanup EXIT
PASS=0; FAIL=0
check() { if eval "$2"; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; else FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$1"; fi; }
errs() { count release-error; }
pairnow() { printf '%s|%s' "$(cat "$STATE/.lock" 2>/dev/null)" "$(cat "$STATE/.lock-session" 2>/dev/null)"; }
wake_followups() { jq -c 'select(.event=="followup" and .kind=="watcher")' "$STATE/.dsh-primary-events.jsonl" | wc -l | tr -d ' '; }
session_census() { # <server-tag> <id> <text>: event-type census of lines in that session's own log that hold the text
  python3 - "$LAB/$1/dsh/sessions" "$2" "$3" <<'PY'
import collections,glob,json,os,sys
root,sid,text=sys.argv[1:]
c=collections.Counter()
for p in glob.glob(os.path.join(root,'*',sid,'*.jsonl')):
    for line in open(p):
        if text not in line: continue
        try: c[json.loads(line).get('type','?')]+=1
        except ValueError: c['?']+=1
print(json.dumps(dict(c),sort_keys=True))
PY
}
session_exists() { ls "$LAB/$1/dsh/sessions"/*/"$2"/*.jsonl >/dev/null 2>&1; }
say "$LABEL: rev=$(git rev-parse "$REV") bin-tree=$(git rev-parse "$REV:bin") dsh=$(dsh --version)"
git init -q "$HOME_LAB"; cp "$WORKTREE/AGENTS.md" "$HOME_LAB/AGENTS.md"
ln -s "$CODE/bin" "$HOME_LAB/bin"; ln -s "$WORKTREE/.agents" "$HOME_LAB/.agents"; ln -s "$WORKTREE/docs" "$HOME_LAB/docs"
printf 'manual\n' > "$HOME_LAB/config/backlog-backend"
printf '# Backlog\n\n## Queued\n\n## In flight\n\n## Done\n' > "$HOME_LAB/data/backlog.md"
printf 'fixture\n' > "$STATE/demo.meta"
cat > "$STATE/lab-probe.check.sh" <<'CHK'
#!/usr/bin/env bash
if [ -f "$FM_HOME/state/probe-wake" ]; then rm "$FM_HOME/state/probe-wake"; echo 'lab runtime wake notification'; fi
CHK
chmod 700 "$STATE/lab-probe.check.sh"
FM_HOME="$HOME_LAB" bash "$WORKTREE/bin/fm-check-register.sh" lab-probe
A=lab-session-a; B=lab-session-b; C=lab-session-c

say "Start private web server with explicit bindings for session A and session B"
start_server s1 $A $B
PID1=$(cmd s1 pid x | jq -r .pid); echo "server pid=$PID1"

say "S0 attach: A is created, canonical acquire records exact native identity"
cmd s1 create $A; wait_count watcher-ready 1 200; pair
check "A owns the exact pair (server pid + dsh-web:A)" '[ "$(pairnow)" = "$PID1|dsh-web:$A" ]'
check "real watcher armed for A" '[ "$(count watcher-ready)" -ge 1 ]'

say "S1 control: successful owned release"
cmd s1 dispose $A; sleep 1.5; pair; errors
check "successful owned release removes the pair" '[ "$(pairnow)" = "|" ]'
check "successful owned release records no release-error" '[ "$(errs)" = 0 ]'

say "S2 same-ID resume on a free lock"
cmd s1 resume $A; wait_count watcher-ready 2 200; pair
check "resumed A re-acquires the free lock" '[ "$(pairnow)" = "$PID1|dsh-web:$A" ]'

say "S3 real exit-1 fault: state directory really unwritable (chmod 555), then true Agent termination"
before=$(pairnow); chmod 555 "$STATE"
cmd s1 dispose $A
wait_count release-error 1 80
chmod 755 "$STATE"; pair; errors
check "real exit-1 fault is recorded as one release-error" '[ "$(errs)" = 1 ]'
check "recorded detail carries real stderr" 'errors | grep -q "cannot write session lock"'
check "fault leaves the exact pair in place" '[ "$(pairnow)" = "$before" ]'

say "S4 adversarial: different live session B on the same server after the failed release"
cmd s1 create $B; sleep 3; pair
check "B does not acquire: pair is byte-identical" '[ "$(pairnow)" = "$before" ]'
echo "B log census for Firstmate text: $(session_census s1 $B Firstmate)"
check "B session log really exists" 'session_exists s1 $B'
check "B gets no Firstmate follow-up" '[ "$(session_census s1 $B Firstmate)" = "{}" ]'
errs_before=$(errs); cmd s1 dispose $B; wait_count release-error $((errs_before+1)) 80; pair; errors | tail -1
check "B termination records the legitimate refusal" 'errors | tail -1 | grep -q "cannot release another"'
check "the refusal changes nothing" '[ "$(pairnow)" = "$before" ]'
if ! [ "$(pairnow)" = "$before" ]; then echo "(diverged: state above)"; fi

say "S5 same-ID recovery on that server; real watcher wake reaches A once"
ready=$(count watcher-ready); cmd s1 resume $A; wait_count watcher-ready $((ready+1)) 200; pair
check "same-ID A recovers ownership on that server" '[ "$(pairnow)" = "$PID1|dsh-web:$A" ]'
check "recovered A has a real armed watcher" '[ "$(count watcher-ready)" -gt "$ready" ]'
touch "$STATE/probe-wake"
i=0; until [ "$(wake_followups)" -ge 1 ] || [ "$i" -gt 450 ]; do sleep 0.1; i=$((i+1)); done
sleep 6
A_CENSUS=$(session_census s1 $A 'Firstmate watcher notification'); B_CENSUS=$(session_census s1 $B 'Firstmate watcher notification')
echo "watcher follow-ups=$(wake_followups) A log census=$A_CENSUS B log census=$B_CENSUS"
check "real watcher wake gave exactly one native follow-up" '[ "$(wake_followups)" = 1 ]'
check "that follow-up is in A session log" '[ "$A_CENSUS" != "{}" ]'
check "sibling B session log has no such follow-up" '[ "$B_CENSUS" = "{}" ]'

say "S6 real removal fault: state/.lock is really immutable (chflags uchg), so real rm fails"
before=$(pairnow); chflags uchg "$STATE/.lock"; e0=$(errs)
ls -lO "$STATE/.lock" | awk '{print "flags:", $5}'
cmd s1 dispose $A
wait_count release-error $((e0+1)) 80; pair; errors | tail -1
chflags nouchg "$STATE/.lock"
check "removal fault is recorded" '[ "$(errs)" = "$((e0+1))" ]'
check "recorded detail names the real rm error" 'errors | tail -1 | grep -q "Operation not permitted"'
check "sidecar stays paired with the lock" '[ "$(pairnow)" = "$before" ]'
ready=$(count watcher-ready); cmd s1 resume $A; wait_count watcher-ready $((ready+1)) 200; pair
check "same ID recovers after the removal fault" '[ "$(pairnow)" = "$PID1|dsh-web:$A" ] && [ "$(count watcher-ready)" -gt "$ready" ]'

say "S6b real removal fault on the sidecar only: state/.lock-session is really immutable"
chflags uchg "$STATE/.lock-session"; e0=$(errs)
cmd s1 dispose $A
wait_count release-error $((e0+1)) 80; pair; errors | tail -1
chflags nouchg "$STATE/.lock-session"
check "sidecar removal fault is recorded" '[ "$(errs)" = "$((e0+1))" ] && errors | tail -1 | grep -q "Operation not permitted"'
ready=$(count watcher-ready); cmd s1 resume $A; wait_count watcher-ready $((ready+1)) 200; pair
check "same ID re-acquires after the sidecar fault" '[ "$(pairnow)" = "$PID1|dsh-web:$A" ] && [ "$(count watcher-ready)" -gt "$ready" ]'

say "S7 adversarial: second live private server, different session C, while A still owns"
before=$(pairnow)
start_server s2 $C
cmd s2 create $C; sleep 3; pair
check "second server is refused: pair is byte-identical" '[ "$(pairnow)" = "$before" ]'
e0=$(errs); cmd s2 dispose $C; wait_count release-error $((e0+1)) 80; errors | tail -1; pair
check "second server termination is a recorded refusal, pair unchanged" 'errors | tail -1 | grep -q "cannot release another" && [ "$(pairnow)" = "$before" ]'
kill "$SERVER_s2" 2>/dev/null; sleep 1

say "S8 final successful owned release after the faults"
e0=$(errs); cmd s1 dispose $A; sleep 1.5; pair
check "owned release still removes the pair after the faults" '[ "$(pairnow)" = "|" ]'
check "owned release adds no release-error" '[ "$(errs)" = "$e0" ]'

say "S9 server death: same-ID reclaims a dead recorded server pid on restart"
ready=$(count watcher-ready); cmd s1 resume $A; wait_count watcher-ready $((ready+1)) 200; pair
kill -9 "$PID1"; sleep 2; pair
start_server s1 $A $B
PID3=$(cmd s1 pid x | jq -r .pid); echo "new server pid=$PID3"
cmd s1 resume $A; sleep 4; pair
check "dead old server pid is reclaimed by same ID" '[ "$(pairnow)" = "$PID3|dsh-web:$A" ]'

say "S10 plugin teardown on graceful stop never reports a failed release"
e0=$(errs); kill -TERM "$SERVER_s1"; sleep 4; pair; echo "release-errors added=$(( $(errs) - e0 ))"
check "graceful stop adds no release-error" '[ "$(errs)" = "$e0" ]'

say "Full plugin event log"
events | sed -E 's/"arm":[0-9]+/"arm":N/'
say "Result: $LABEL pass=$PASS fail=$FAIL"
