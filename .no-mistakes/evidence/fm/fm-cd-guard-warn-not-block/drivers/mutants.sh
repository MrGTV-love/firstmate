#!/usr/bin/env bash
# F3 mutant proof: each mutant changes ONE character of deny output; the golden
# byte-compare assertions in tests/fm-cd-pretool-check.test.sh must fail.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5BWZMJEVPGDQB5HWVWNFAZT
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5BWZMJEVPGDQB5HWVWNFAZT
M=$(mktemp -d "${TMPDIR:-/tmp}/fm-cdg-mut.XXXXXX")
for n in real m1-reason m2-cursor-renderer m3-claude-renderer m4-grok-renderer; do
  mkdir -p "$M/$n"; git -C "$WT" archive HEAD | tar -x -C "$M/$n"; git init -q -b main "$M/$n"; git -C "$M/$n" add -A; git -C "$M/$n" -c user.email=a@b -c user.name=t commit -q -m base
done
# M1: deny reason 'blocked' -> 'blockeD' (one char) in the policy owner
sed -i '' 's/is blocked; it would move/is blockeD; it would move/' "$M/m1-reason/bin/fm-cd-command-policy.mjs"
# M2: cursor deny object key 'deny' -> 'dene'
sed -i '' 's/{"permission":"deny","user_message"/{"permission":"dene","user_message"/' "$M/m2-cursor-renderer/bin/fm-cd-pretool-check.sh"
# M3: claude deny object 'systemMessage' -> 'systemMessagE' on the deny line only
sed -i '' '/permissionDecision":"deny"}/s/"systemMessage"/"systemMessagE"/' "$M/m3-claude-renderer/bin/fm-cd-pretool-check.sh"
# M4: grok deny object 'reason' -> 'reasoN'
sed -i '' 's/{"decision":"deny","reason":"%s"}/{"decision":"deny","reasoN":"%s"}/' "$M/m4-grok-renderer/bin/fm-cd-pretool-check.sh"
for n in m1-reason m2-cursor-renderer m3-claude-renderer m4-grok-renderer; do
  echo "== diff vs real: $n"; diff <(git -C "$WT" archive HEAD | tar -xO bin/fm-cd-command-policy.mjs) "$M/$n/bin/fm-cd-command-policy.mjs" | grep -c '^[<>]' | sed 's/^/policy diff lines: /'
  diff <(git -C "$WT" archive HEAD | tar -xO bin/fm-cd-pretool-check.sh) "$M/$n/bin/fm-cd-pretool-check.sh" | grep -c '^[<>]' | sed 's/^/checker diff lines: /'
done
for n in real m1-reason m2-cursor-renderer m3-claude-renderer m4-grok-renderer; do
  ( cd "$M/$n" && bash tests/fm-cd-pretool-check.test.sh > "$M/$n.log" 2>&1; echo $? > "$M/$n.rc" ) &
done
wait
for n in real m1-reason m2-cursor-renderer m3-claude-renderer m4-grok-renderer; do
  echo "### $n exit=$(cat "$M/$n.rc")  ok-lines=$(grep -c '^ok' "$M/$n.log")  not-ok=$(grep -c '^not ok' "$M/$n.log")"
  grep -m1 -E '^not ok|differs from the original|FAIL' "$M/$n.log" | cut -c1-220
  cp "$M/$n.log" "$EV/s8-mutant-$n.log"
done
rm -rf "$M"
