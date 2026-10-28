#!/usr/bin/env bash
# Live driver: real bin/fm-review-record.py against a disposable FM_HOME.
set -u
REPO=$1
R="$REPO/bin/fm-review-record.py"
LAB=$(mktemp -d /tmp/fm-rr-lab.XXXXXX)
URL=https://github.com/example/repo/pull/9
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
run() { echo "\$ $*"; "$@"; echo "[exit $?]"; echo; }
home() { mkdir -p "$LAB/$1"; export FM_HOME="$LAB/$1"; }
report() { printf 'VERDICT: %s head=%s\nbody\n' "$1" "$2" > "$LAB/report-$1-$2.md"; echo "$LAB/report-$1-$2.md"; }
rev() { # verdict head reader authorsjson trigger
  "$R" review --pr "$URL" --head "$2" --verdict "$1" --reader-model "$3" --author-groups "$4" \
    --report "$(report "$1" "$2")" --loosens-deny-allow-list no --widens-guard "${5:-no}" --customer-data-billing-spend no; }

echo "=== A: independent PASS (gpt reader, claude-opus author) ==="
home a; rev PASS $H1 gpt-5.5 '{"c1":["claude-opus-5-5"]}'
run "$R" verify --pr "$URL" --head $H1 --review-only --json
run "$R" verify --pr "$URL" --head $H1

echo "=== B: no history at all -> typed not-qualified absence ==="
home b
run "$R" verify --pr "$URL" --head $H1 --review-only --json

echo "=== C: corrupt history -> unavailable (degraded), not absence ==="
home c; mkdir -p "$FM_HOME/state"; printf '{"schema":"fm-review-record.v1","kind":"rev' > "$FM_HOME/state/review-records.jsonl"
run "$R" verify --pr "$URL" --head $H1 --review-only --json
printf 'not json\n' > "$FM_HOME/state/review-records.jsonl"
run "$R" verify --pr "$URL" --head $H1 --review-only --json

echo "=== D: invalid input -> invalid-input, exit 2 ==="
home d
run "$R" verify --pr "not-a-url" --head $H1 --review-only --json
run "$R" verify --pr "$URL" --head abc --review-only --json

echo "=== E: captain-word at head: default accepts, --review-only refuses ==="
home e; "$R" captain-word --pr "$URL" --head $H1 --words "Merge PR 9 now"
run "$R" verify --pr "$URL" --head $H1 --json
run "$R" verify --pr "$URL" --head $H1 --review-only --json

echo "=== F: later FAIL after captain-word: default refuses (FAIL precedence) ==="
rev FAIL $H1 gpt-5.5 '{"c1":["claude-opus-5-5"]}'
run "$R" verify --pr "$URL" --head $H1 --json
run "$R" verify --pr "$URL" --head $H1

echo "=== G: independent PASS with escalation trigger yes: default PASS, --review-only refuses ==="
home g; rev PASS $H1 gpt-5.5 '{"c1":["claude-opus-5-5"]}' yes
run "$R" verify --pr "$URL" --head $H1 --json
run "$R" verify --pr "$URL" --head $H1 --review-only --json

echo "=== H: same-family reader is not independent ==="
home h; rev PASS $H1 claude-sonnet-5-5 '{"c1":["claude-opus-5-5"]}'
run "$R" verify --pr "$URL" --head $H1 --review-only --json

echo "=== I: bare native Claude names opus/sonnet/haiku are anthropic ==="
home i; rev PASS $H1 gpt-5.5 '{"c1":["opus","sonnet","haiku"]}'
run "$R" verify --pr "$URL" --head $H1 --review-only --json
home i2; rev PASS $H1 opus '{"c1":["gpt-5.5"]}'
run "$R" verify --pr "$URL" --head $H1 --review-only --json

echo "=== J: PASS at stale head -> not-qualified at live head ==="
home j; rev PASS $H1 gpt-5.5 '{"c1":["claude-opus-5-5"]}'
run "$R" verify --pr "$URL" --head $H2 --review-only --json

rm -rf "$LAB"
