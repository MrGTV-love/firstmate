#!/usr/bin/env bash
# Live drive of bin/fm-send.sh and bin/fm-send-unattended.sh against a marked
# disposable lab home with real tmux panes on the private fm-lab socket.
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M72J0F8JK5E0YM7A7MKYVDN2
. "$EV/lab-setup.sh"
trap 'tmux -L fm-lab kill-server 2>/dev/null; eval "$TEARDOWN"' EXIT
body() { bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$WT/bin/fm-task-inbox-lib.sh" "$1"; }
inv() { printf '  inbox(%s): ' "$1"; if [ -d "$S/$1.inbox" ]; then (cd "$S/$1.inbox" && ls *.msg 2>/dev/null | tr '\n' ' '); else printf 'ABSENT'; fi; echo; }
pend() { printf '  pending-replies: '; if [ -d "$S/pending-replies" ]; then ls "$S/pending-replies" | wc -l | tr -d ' '; else echo ABSENT; fi; }
run() { # <label> <cmd...>
  local label=$1; shift
  echo; echo "=== $label"
  printf '$'; printf ' %q' "$@"; echo
  "$@" >"$TMPDIR/o" 2>"$TMPDIR/e"; RC=$?
  echo "  exit=$RC"
  grep -v '^●' "$TMPDIR/e" | grep -v 'fm-gate-refuse: gate agent lifecycle permitted' | sed 's/^/  stderr: /'
  sed 's/^/  stdout: /' "$TMPDIR/o"
}
lastbody() { local f; f=$(ls "$S/$1.inbox"/*.msg 2>/dev/null | tail -1); [ -n "$f" ] && { printf '  last record %s body: ' "${f##*/}"; body "$f" | sed -n '1,3p'; } ; }
guard() { echo "  guard events:"; jq -c '{guard,decision,rule,task,override}' "$FM_GUARD_EVENT_LOG" | sed 's/^/    /'; : > "$FM_GUARD_EVENT_LOG"; }

echo "LAB FM_HOME=$FM_HOME (marked lab, private tmux socket $SOCK)"
echo "records: state/fm-slack-main-window-intake.meta (direct report ship, claude); state/fm-mini.meta (secondmate, home=$MINI_HOME); state/other.meta (ship); mini-home/state/child-task.meta"

# S1: the 15:57Z misroute replay.
printf 'needs-decision [key=pr370-fix-round-no-owner-here]: waiting\n' > "$S/fm-mini.status"
cp "$S/fm-mini.status" "$TMPDIR/mini-status-before"
TEXT='Run the PR 370 fix round for fm-slack-main-window-intake now.'
run "S1 wrong owner: Main sends the intake fix round to fm-mini (15:57Z replay)" bin/fm-send.sh fm-mini "$TEXT"
inv fm-mini; pend; guard
cmp -s "$TMPDIR/mini-status-before" "$S/fm-mini.status" && echo "  fm-mini.status unchanged: yes"
run "S1b wrong owner with --resolve-key: refusal must not close the mate's open decision" bin/fm-send.sh fm-mini --resolve-key pr370-fix-round-no-owner-here "$TEXT"
inv fm-mini; pend
cmp -s "$TMPDIR/mini-status-before" "$S/fm-mini.status" && echo "  fm-mini.status unchanged (decision still open): yes"
guard
run "S1c wrong owner, legacy label fm-<id>" bin/fm-send.sh other 'Resume fm-fm-slack-main-window-intake.'
inv other; guard
run "S1d wrong owner, plain worker target" bin/fm-send.sh other "$TEXT"
inv other; guard

# S2: the designated owner receives the same instruction unchanged.
run "S2 correct owner: same instruction to the selector the refusal named" bin/fm-send.sh fm-slack-main-window-intake "$TEXT"
inv fm-slack-main-window-intake; lastbody fm-slack-main-window-intake; guard
run "S2b correct owner via legacy label selector" bin/fm-send.sh fm-fm-slack-main-window-intake "$TEXT"
inv fm-slack-main-window-intake; guard

# S3: deliberate cross-task relay.
run "S3 --relay deliberate cross-task mention" bin/fm-send.sh other --relay "FYI: fm-slack-main-window-intake owns the PR 370 fix round; no action for you."
inv other; lastbody other; guard
run "S3b --relay does not bypass an empty-message refusal" bin/fm-send.sh other --relay '   '
inv other
run "S3c --relay does not bypass a missing-decision refusal" bin/fm-send.sh other --relay --resolve-key nonexistent 'answer'
inv other; guard

# S4: non-mentions are ordinary text.
for t in 'Study fm-slack-main-window-intake-v2 notes.' 'Continue task-not-recorded-here.' 'xfm-slack-main-window-intake is a different word' 'Write output to /not-created/fm-slack-main-window-intake/out.md and see the example /examples/x.md on the other computer.' 'Read data/fm-slack-main-window-intake/review.md (known limit: path-embedded id).' 'plain steer with no task id'; do
  run "S4 non-mention accepted" bin/fm-send.sh other "$t"
  inv other; lastbody other
done
guard

# S5: secondmate routes.
run "S5 secondmate own child task (recorded only in the secondmate home)" bin/fm-send.sh fm-mini 'Continue child-task.'
inv fm-mini; pend; lastbody fm-mini; guard
run "S5b steer to a secondmate that names the secondmate itself" bin/fm-send.sh fm-mini 'fm-mini: report your fleet status.'
inv fm-mini; guard

# S6: declared inputs.
run "S6a declared input missing on the receiver" bin/fm-send.sh other --require-input data/brief.md 'Use the brief to start.'
inv other; guard
mkdir -p "$FM_HOME/data"; printf 'brief\n' > "$FM_HOME/data/brief.md"
run "S6b declared input present: sends, message bytes unchanged" bin/fm-send.sh other --require-input data/brief.md 'Use the brief to start.'
inv other; lastbody other; guard
run "S6c declared input outside the transfer boundary" bin/fm-send.sh other --require-input /etc/hosts 'Use hosts.'
inv other; guard
run "S6d two declared inputs, both missing: every one is reported" bin/fm-send.sh other --require-input data/a.md --require-input data/b.md 'Use a and b.'
inv other; guard
run "S6e --relay does not bypass declared-input validation" bin/fm-send.sh other --relay --require-input data/missing.md 'FYI fm-slack-main-window-intake; use missing.'
inv other; guard
run "S6f a key cannot declare inputs" bin/fm-send.sh other --require-input data/brief.md --key Enter
echo "  exit recorded above"

# S7: remote route failure is not reported as a missing input.
printf 'window=remote:fm-rsm\nkind=secondmate\nharness=claude\nremote_host=lab-unreachable.invalid\nhome=/remote/home\n' > "$S/rsm.meta"
run "S7 remote declared-input check with no registry route" bin/fm-send.sh rsm --require-input data/x.md 'Use x.'
inv rsm; pend; guard
rm -f "$S/rsm.meta"

# S8: unattended wrapper.
: > "$S/fm-mini.status"
run "S8a unattended wrong-owner steer is refused and handed to Firstmate" bin/fm-send-unattended.sh fm-mini "$TEXT"
inv fm-mini; echo "  fm-mini.status:"; sed 's/^/    /' "$S/fm-mini.status"
run "S8b second unattended steer is held, no send attempted" bin/fm-send-unattended.sh fm-mini 'Continue child-task.'
inv fm-mini
echo "  open decisions (Firstmate view):"; bash -c '. bin/fm-classify-lib.sh; status_open_decisions "$1"' _ "$S/fm-mini.status" | sed 's/^/    /'
echo "  own open decisions (worker view, gates recovery):"; bash -c '. bin/fm-classify-lib.sh; status_own_open_decisions "$1"' _ "$S/fm-mini.status" | sed 's/^/    /'; echo "    <end>"
run "S8c attended fm-send to the same mate still sends (hold only blocks unattended)" bin/fm-send.sh fm-mini 'Continue child-task.'
inv fm-mini; guard
run "S8d unattended ordinary steer to a task with no hold sends normally" bin/fm-send-unattended.sh other 'plain unattended check-in'
inv other; echo "  other.status:"; sed 's/^/    /' "$S/other.status" 2>/dev/null || echo "    (none)"
guard

# S9: legitimate dependency stays reported.
printf 'needs-decision [key=dep-api-key]: waiting for the captain to choose the staging database\n' > "$S/other.status"
run "S9 a worker's dependency decision stays open after a refused steer" bin/fm-send.sh other --resolve-key dep-api-key "$TEXT"
echo "  other.status:"; sed 's/^/    /' "$S/other.status"
echo "  own open decisions:"; bash -c '. bin/fm-classify-lib.sh; status_own_open_decisions "$1"' _ "$S/other.status" | sed 's/^/    /'
guard
echo; echo "=== tmux panes (real shells; the doorbell is skipped for a bare shell pane)"
tmux -L fm-lab list-windows -t lab
