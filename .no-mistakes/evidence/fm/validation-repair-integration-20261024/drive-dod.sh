#!/usr/bin/env bash
# Live driver: real bin/fm-dod-lib.sh --shape and --verification-plan over throwaway briefs.
set -u
REPO=$1; D="$REPO/bin/fm-dod-lib.sh"
LAB=$(mktemp -d /tmp/fm-dod-lab.XXXXXX)
brief() { # name, items-block
  cat > "$LAB/$1.md" <<B
# Task
## Captain's intent
Fix the stale badge.
## Firstmate spec
### Out of scope
- Do not redesign the dashboard.
# Definition of done
## Definition Of Done (task)
The badge updates after a refresh.
### Mandatory items
$2
## How You're Graded
Grading prose.
B
  echo "$LAB/$1.md"; }
run() { echo "--- $1"; shift; out=$(bash "$D" --verification-plan "$@" 2>&1); rc=$?; printf '%s\n[exit %s]\n\n' "$out" "$rc"; }
GOOD='- C1 Source: captain intent. Expected: badge refreshes. Verify: reload page. Edge/negative: failed refresh keeps last value. Evidence place: PR body. Authority: grader.'
echo '$ bash bin/fm-dod-lib.sh --shape'; bash "$D" --shape; echo "[exit $?]"; echo
echo "=== well-formed item -> plan built"
b=$(brief good "$GOOD"); out=$(bash "$D" --verification-plan "$b" 2>&1); rc=$?; printf '%s\n' "$out" | head -20; echo "[exit $rc]"; echo
echo "=== numbered list marker"; run "1. C1 marker" "$(brief num "1. ${GOOD#- }")"
echo "=== missing Verify field"; run "missing" "$(brief miss '- C1 Source: a. Expected: b. Edge/negative: d. Evidence place: e. Authority: grader.')"
echo "=== invalid Authority"; run "auth" "$(brief auth '- C1 Source: a. Expected: b. Verify: c. Edge/negative: d. Evidence place: e. Authority: captain.')"
echo "=== duplicate id"; run "dup" "$(brief dup "$GOOD
$GOOD")"
echo "=== empty item list"; run "empty" "$(brief empty 'Write items here later.')"
echo "=== trailing prose after last item must not pollute Authority"; run "trail" "$(brief trail "$GOOD
This trailing note is ordinary prose.")"
echo "=== heading-marked item line is a heading, never an item"; run "heading" "$(brief heading '### C1 Source: a Expected: b Verify: c Edge/negative: d Evidence place: e Authority: grader')"
echo "=== label line with no item id"; run "noid" "$(brief noid "$GOOD
Verify: orphan check")"
echo "=== legacy brief with no DoD section still builds"
cat > "$LAB/legacy.md" <<B
# Task
## Captain's intent
Fix it.
B
run legacy "$LAB/legacy.md"
rm -rf "$LAB"
