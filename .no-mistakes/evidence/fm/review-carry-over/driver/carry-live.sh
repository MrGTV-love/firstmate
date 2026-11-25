#!/usr/bin/env bash
# Drives the real bin/fm-review-record.py review/captain-word/verify CLI in a
# throwaway FM_HOME and git repo. Usage: carry-live.sh <repo-root>
set -u
ROOT=$1
RECORD="$ROOT/bin/fm-review-record.py"
URL=https://github.com/example/repo/pull/9
SCR=$(mktemp -d "${TMPDIR:-/tmp}/fm-carry-live.XXXXXX")
trap 'rm -rf "$SCR"' EXIT
NM="$SCR/nm"; mkdir -p "$NM"
python3 -c 'import sqlite3, sys; sqlite3.connect(sys.argv[1]).executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")' "$NM/state.sqlite"
g() { git -C "$C/wt" -c user.name=Lab -c user.email=lab@example.invalid "$@"; }

new_case() {  # sets C, BASE, R, TRUNK
  C="$SCR/$1"; mkdir -p "$C/home/state"
  git init -q -b main "$C/wt"; printf 'readme\n' > "$C/wt/README.md"; g add README.md; g commit -qm initial
  BASE=$(g rev-parse HEAD)
  printf 'worktree=%s\nkind=ship\nmodel=gpt-5.1\nbranch=fm/fixture\nmode=direct-PR\n' "$C/wt" > "$C/home/state/task-x1.meta"
  g checkout -q -b pr; printf 'one\ntwo\nthree\n' > "$C/wt/app.txt"; g add app.txt; g commit -qm 'ship change'
  R=$(g rev-parse HEAD)
  g checkout -q -b trunk "$BASE"; printf 'other\n' > "$C/wt/other.txt"; g add other.txt; g commit -qm 'base moves'
  TRUNK=$(g rev-parse HEAD)
}
review() {  # head verdict reader
  printf 'VERDICT: %s head=%s\nIndependent reader evidence.\n' "$2" "$1" > "$C/report-$2-$1.md"
  FM_HOME="$C/home" "$RECORD" review --pr "$URL" --head "$1" --verdict "$2" --reader-model "$3" \
    --author-groups '{"ship":["gpt-5.1"]}' --loosens-deny-allow-list no --widens-guard no \
    --customer-data-billing-spend no --report "$C/report-$2-$1.md" >/dev/null || echo "!! record failed"
}
verify() {  # head base [flags]  -- prints command, output, exit
  local h=$1 b=$2 rc; shift 2
  echo "\$ fm-review-record.py verify --head ${h:0:12} --base ${b:0:12} $*"
  NM_HOME="$NM" FM_HOME="$C/home" "$RECORD" verify --pr "$URL" --head "$h" --task task-x1 --base "$b" "$@" 2>&1 | sed -e "s#$SCR#<tmp>#g" -e "s#$ROOT#<repo>#g"; rc=${PIPESTATUS[0]}
  echo "[exit $rc]"
}
hdr() { printf '\n===== %s =====\n' "$1"; }

hdr "S1 clean merge of base into reviewed PR carries the PASS (base moved again after)"
new_case s1; review "$R" PASS sonnet
g checkout -q pr; g merge -q --no-edit trunk; H=$(g rev-parse HEAD)
g checkout -q trunk; printf 'later\n' > "$C/wt/later.txt"; g add later.txt; g commit -qm later; LATER=$(g rev-parse HEAD)
echo "reviewed R=${R:0:12} live H=${H:0:12}"
objs_before=$(find "$C/wt/.git/objects" -type f | wc -l | tr -d ' ')
verify "$H" "$LATER"
verify "$H" "$LATER" --json
verify "$H" "$LATER" --review-only
objs_after=$(find "$C/wt/.git/objects" -type f | wc -l | tr -d ' ')
echo "task object files before=$objs_before after=$objs_after (must be equal)"
echo "\$ fm-review-record.py plan --head ${H:0:12} --base ${LATER:0:12}   (plan answers for the exact head only)"
NM_HOME="$NM" FM_HOME="$C/home" "$RECORD" plan --pr "$URL" --head "$H" --task task-x1 --base "$LATER" 2>&1; echo "[exit $?]"

hdr "S2 clean rebase onto base carries the PASS"
new_case s2; review "$R" PASS sonnet
g checkout -q -b rebased "$R"; g rebase -q trunk; H=$(g rev-parse HEAD)
verify "$H" "$TRUNK"

hdr "S3 ADVERSARIAL: one unread line hidden inside the update merge is refused"
new_case s3; review "$R" PASS sonnet
g checkout -q pr; g merge -q --no-commit --no-ff trunk >/dev/null 2>&1; printf 'unread\n' >> "$C/wt/app.txt"; g add app.txt; g commit -qm "Merge branch 'trunk' into pr"; H=$(g rev-parse HEAD)
verify "$H" "$TRUNK" --json

hdr "S4 ADVERSARIAL: conflicted update resolved to the reviewed side is refused"
new_case s4; review "$R" PASS sonnet
g checkout -q trunk; printf 'base version\n' > "$C/wt/app.txt"; g add app.txt; g commit -qm 'base edits app'; TRUNK=$(g rev-parse HEAD)
g checkout -q pr; g merge -q --no-edit trunk >/dev/null 2>&1; printf 'one\ntwo\nthree\n' > "$C/wt/app.txt"; g add app.txt; g commit -qm merge; H=$(g rev-parse HEAD)
verify "$H" "$TRUNK"

hdr "S5 ADVERSARIAL: same conflict, but task worktree config+attributes and GIT_CONFIG_* env select a take-the-PR-side merge driver"
new_case s5; review "$R" PASS sonnet
g checkout -q trunk; printf 'base version\n' > "$C/wt/app.txt"; g add app.txt; g commit -qm 'base edits app'; TRUNK=$(g rev-parse HEAD)
g checkout -q pr; g merge -q --no-edit trunk >/dev/null 2>&1; printf 'one\ntwo\nthree\n' > "$C/wt/app.txt"; g add app.txt; g commit -qm merge; H=$(g rev-parse HEAD)
git -C "$C/wt" config merge.keepours.driver 'cp %B %A'
mkdir -p "$C/wt/.git/info"; printf 'app.txt merge=keepours\n' > "$C/wt/.git/info/attributes"
echo "control: plain git merge-tree in the task worktree with that driver:"
P=$(git -C "$C/wt" merge-base "$TRUNK" "$H")
T=$(git -C "$C/wt" merge-tree --write-tree "$P" "$R" | head -1); echo "  driver tree=${T:0:12} live tree=$(git -C "$C/wt" rev-parse "$H^{tree}" | cut -c1-12) (equal means the driver would fool an unisolated proof)"
verify "$H" "$TRUNK"
echo "-- and with GIT_CONFIG_COUNT env injecting the driver:"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=merge.keepours.driver GIT_CONFIG_VALUE_0='cp %B %A' verify "$H" "$TRUNK"

hdr "S6 ADVERSARIAL: a replace ref swaps the live head for a commit whose tree matches"
new_case s6; review "$R" PASS sonnet
g checkout -q pr; g merge -q --no-commit --no-ff trunk >/dev/null 2>&1; printf 'unread\n' >> "$C/wt/app.txt"; g add app.txt; g commit -qm unread-merge; H=$(g rev-parse HEAD)
g checkout -q -b clean "$R"; g merge -q --no-edit trunk; CLEAN=$(g rev-parse HEAD)
git -C "$C/wt" replace "$H" "$CLEAN"
echo "with replace refs honored, H^{tree}=$(git -C "$C/wt" rev-parse "$H^{tree}" | cut -c1-12); clean tree=$(git -C "$C/wt" rev-parse "$CLEAN^{tree}" | cut -c1-12)"
verify "$H" "$TRUNK"

hdr "S7 captain-word at the reviewed head never carries"
new_case s7
FM_HOME="$C/home" "$RECORD" captain-word --pr "$URL" --head "$R" --words 'Merge PR 9.' >/dev/null
g checkout -q pr; g merge -q --no-edit trunk; H=$(g rev-parse HEAD)
verify "$H" "$TRUNK"

hdr "S8 a standing FAIL at the reviewed head still stands"
new_case s8; review "$R" PASS sonnet; review "$R" FAIL gemini-3-pro
g checkout -q pr; g merge -q --no-edit trunk; H=$(g rev-parse HEAD)
verify "$H" "$TRUNK"

hdr "S9 any read of the live head turns carry-over off"
new_case s9
g checkout -q pr; g merge -q --no-edit trunk; H=$(g rev-parse HEAD)
review "$H" FAIL gemini-3-pro; review "$R" PASS sonnet
verify "$H" "$TRUNK"

hdr "S10 ADVERSARIAL: an older-head PASS recorded after a FAIL at a later version is not carried"
new_case s10
g checkout -q pr; printf 'four\n' >> "$C/wt/app.txt"; g add app.txt; g commit -qm 'later version'; R2=$(g rev-parse HEAD)
review "$R2" FAIL gemini-3-pro; review "$R" PASS sonnet
g checkout -q -b back "$R"; g merge -q --no-edit trunk; H=$(g rev-parse HEAD)
echo "H is R merged cleanly with trunk, so only the ancestry rule can refuse it"
echo "R=${R:0:12} (PASS, recorded last)  R2=${R2:0:12} (FAIL, later version)  H=${H:0:12}"
verify "$H" "$TRUNK"
