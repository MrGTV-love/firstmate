. "$(dirname "$0")/lab-lib.sh"; cd "$W"
DRAIN_OUT=$(cat $FM_HOME/lab-last-drain 2>/dev/null)
step "S3a: rubber stamp attempt - escalate with --hold naming a task NOT held for the captain (must refuse)"
printf '## In flight\n\n## Queued\n\n## Done\n' > $FM_HOME/data/backlog.md
run ol action unanswered_question:beta:deploy escalated --evidence "escalated" --hold beta-deploy
step "S3b: make a real captain hold for the beta deploy call"
run "$W/bin/fm-captain-hold.sh" hold beta-deploy --reason "captain decides whether beta deploys to prod" --title "Beta deploy call"
step "S3c: escalate bound to that captain hold (accepted)"
run ol action unanswered_question:beta:deploy escalated --evidence "captain asked: deploy beta to prod?" --hold beta-deploy
