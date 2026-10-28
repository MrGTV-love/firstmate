. $S/lab.sh
echo "=== Scenario 1: PR-197 shape. OpenAI ship worker, Claude no-mistakes pipeline commits, Claude-only PASS typed {all:[openai]} ==="
mk s1 no-mistakes openai-codex/gpt-6.1-sol
commit "feat: ship worker implementation"
commit "no-mistakes(review): fix finding A"; commit "no-mistakes(test): add regression"; commit "no-mistakes(document): docs"
git -C "$L/wt" log --format='  %h %s' "$BASE..HEAD"
db "add_run('run1', '$URL', 'fm/x'); add_inv('run1','review','claude','claude-opus-5-5','anthropic'); add_inv('run1','document','claude','claude-opus-5-5','anthropic')"
rec PASS claude-opus-5-5 '{"all":["openai-codex/gpt-6.1-sol"]}'
echo "--- BEFORE (base 3c5ff4b4c fm-review-record.py verify, the gate fm-pr-merge.sh called) ---"
"$S/old/bin/fm-review-record.py" verify --pr "$URL" --head "$HEAD_SHA"; echo "  rc=$?"
echo "--- AFTER (this change) ---"
ver | tee $S/s1.out
run_printed() {  # reader
  cmd=$(grep -o "FM_HOME=.*LOCAL_READER_REPORT" $S/s1.out | head -1 | sed "s#<lab>#$S#g")
  printf 'VERDICT: PASS head=%s\nread\n' "$HEAD_SHA" > $L/r-$1.md
  cmd=${cmd//OUTSIDE_FAMILY_MODEL/$1}; cmd=${cmd//LOCAL_READER_REPORT/$L/r-$1.md}
  echo "\$ ${cmd//$S/<lab>}"; eval "$cmd"; echo "  rc=$?"
}
echo "--- Fix path 1: run the printed command with an OpenAI-family reader ---"
run_printed gpt-5.1-codex
ver | tee $S/s1.out
echo "--- Fix path 2: run the newly printed command with a Claude-family reader ---"
run_printed claude-opus-5-5
ver
