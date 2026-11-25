#!/usr/bin/env bash
# Live drive of bin/fm-review-record.py (the real CLI) against a disposable FM_HOME,
# a disposable git fixture and a disposable no-mistakes pipeline database.
# Reproduces the PR 431 shape with a synthetic PR URL. Never reads a real home.
# Usage: live-drive.sh <repo-worktree> <base-commit>
set -u
REPO=$1
OLD_BASE_COMMIT=$2
NEW="$REPO/bin/fm-review-record.py"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-rr-live.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
unset NM_HOME FM_STATE_OVERRIDE FM_HOME
URL=https://github.com/example/firstmate/pull/431
step() { printf '\n=== %s ===\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; local rc=$?; printf '[exit %s]\n' "$rc"; return 0; }

# Old code from the base commit, unpacked outside the worktree, for fail-closed and compat checks.
mkdir -p "$SCRATCH/old"
git -C "$REPO" archive "$OLD_BASE_COMMIT" bin | tar -x -C "$SCRATCH/old"
OLD="$SCRATCH/old/bin/fm-review-record.py"

# Git fixture: a base commit, a ship commit and a no-mistakes pipeline fix commit.
WT="$SCRATCH/wt"
mkdir -p "$WT"
git -C "$WT" init -q -b main
echo base > "$WT/f"; git -C "$WT" add f
git -C "$WT" -c user.name=t -c user.email=t@example.invalid commit -qm base
BASE=$(git -C "$WT" rev-parse HEAD)
echo ship > "$WT/f"
git -C "$WT" -c user.name=t -c user.email=t@example.invalid commit -qam 'feat: ship implementation'
echo fix >> "$WT/f"
git -C "$WT" -c user.name=t -c user.email=t@example.invalid commit -qam 'no-mistakes(review): fix'
HEAD=$(git -C "$WT" rev-parse HEAD)

# Pipeline database: one claude-opus-5-5 invocation, so no-mistakes:anthropic is derived.
NM="$SCRATCH/nm"; mkdir -p "$NM"
python3 -I -c 'import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("CREATE TABLE repos (id TEXT, working_path TEXT); CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, pr_url TEXT); CREATE TABLE agent_invocations (run_id TEXT, agent TEXT, model TEXT, model_provider TEXT);")
db.execute("INSERT INTO runs VALUES (?,?,?,?)", ("run-1", "repo-1", "fm/fixture", sys.argv[2]))
db.execute("INSERT INTO agent_invocations VALUES (?,?,?,?)", ("run-1", "claude", "claude-opus-5-5", "anthropic"))
db.commit()' "$NM/state.sqlite" "$URL"

new_home() {  # <name>: a fresh FM_HOME whose ship task was launched by sonnet, relaunched by gpt-6-luna
  local h="$SCRATCH/$1"
  mkdir -p "$h/state"
  printf 'worktree=%s\nkind=ship\nmodel=claude-sonnet-5-5\nbranch=fm/fixture\nmode=no-mistakes\n' "$WT" > "$h/state/task-pr431.meta"
  printf 'model=openai-codex/gpt-6-luna\n' > "$h/state/task-pr431.control-relaunch.meta-prior"
  printf '%s' "$h"
}
L() { printf '%s/state/review-records.jsonl' "$1"; }
bad_row() {  # line-257 shape, verbatim from the order except the report fields
  printf '{"schema":"fm-review-record.v1","kind":"review","pr":"%s","at":1795202232,"head":"%s","verdict":"PASS","reader_model":"openai-codex/gpt-6.1-terra","reader_family":"openai","author_groups":{"ship":[{"model":"claude-sonnet-5-5","family":"anthropic"}],"no-mistakes":[{"model":"anthropic","family":"anthropic"}]},"loosens_deny_allow_list":"no","widens_guard":"no","customer_data_billing_spend":"no","covered_groups":["ship","no-mistakes"],"report":"/synthetic/bad.md","report_sha256":"%s"}\n' "$URL" "$HEAD" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
}
good_row() {  # line-259 shape, verbatim from the order except the report fields
  printf '{"schema":"fm-review-record.v1","kind":"review","pr":"%s","at":1795206560,"head":"%s","verdict":"PASS","reader_model":"deepseek/deepseek-v4-pro","reader_family":"deepseek","author_groups":{"ship":[{"model":"claude-sonnet-5-5","family":"anthropic"},{"model":"openai-codex/gpt-6-luna","family":"openai"}],"no-mistakes:anthropic":[{"model":"claude-opus-5-5","family":"anthropic"}],"no-mistakes":[{"model":"anthropic","family":"anthropic"}]},"loosens_deny_allow_list":"no","widens_guard":"no","customer_data_billing_spend":"no","covered_groups":["ship","no-mistakes:anthropic"],"report":"/synthetic/good.md","report_sha256":"%s"}\n' "$URL" "$HEAD" bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
}
other_row() { printf '{"schema":"fm-review-record.v1","kind":"review","pr":"%s","at":1795100000,"head":"%s","verdict":"PASS","reader_model":"google/gemini-3-pro","reader_family":"google","author_groups":{"ship":[{"model":"claude-sonnet-5-5","family":"anthropic"}]},"loosens_deny_allow_list":"no","widens_guard":"no","customer_data_billing_spend":"no","covered_groups":["ship"],"report":"/synthetic/other.md"}\n' "$URL" "$HEAD"; }
V() { local h=$1; shift; NM_HOME="$NM" FM_HOME="$h" python3 "${PY:-$NEW}" verify --pr "$URL" --head "$HEAD" --task task-pr431 --base "$BASE" "$@"; }
P() { NM_HOME="$NM" FM_HOME="$1" python3 "${PY:-$NEW}" plan --pr "$URL" --head "$HEAD" --task task-pr431 --base "$BASE"; }
C() {  # <home> <effect> <target-at> <reader> <digest> [extra]
  local h=$1 effect=$2 at=$3 reader=$4 digest=$5; shift 5
  FM_HOME="$h" python3 "$NEW" correction --pr "$URL" --head "$HEAD" --effect "$effect" \
    --target-at "$at" --target-reader-model "$reader" --target-report-sha256 "$digest" \
    --authority-words 'Exclude line 257 and supersede the copied no-mistakes entry in line 259.' \
    --authority-at 1795580000 --reason 'order of 2026-11-20' "$@"
}
BAD=(1795202232 openai-codex/gpt-6.1-terra aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa)
GOOD=(1795206560 deepseek/deepseek-v4-pro bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb)

step "S1 defect reproduced: bad row + genuine row passes; genuine row alone refuses"
H1=$(new_home s1); { bad_row; good_row; } > "$(L "$H1")"
run V "$H1" --review-only --json
H1b=$(new_home s1b); good_row > "$(L "$H1b")"
run V "$H1b" --review-only --json

step "S2 append the two corrections through the CLI; earlier rows stay byte-identical"
H2=$(new_home s2); { bad_row; good_row; } > "$(L "$H2")"
before=$(shasum -a 256 < "$(L "$H2")"); size=$(wc -c < "$(L "$H2")" | tr -d ' ')
run C "$H2" exclude-review "${BAD[@]}"
run C "$H2" supersede-author-group "${GOOD[@]}" --group no-mistakes
prefix=$(head -c "$size" "$(L "$H2")" | shasum -a 256)
echo "prefix sha before: $before"; echo "prefix sha after:  $prefix"
[ "$before" = "$prefix" ] && echo "RESULT: original rows byte-identical" || echo "RESULT: ORIGINAL ROWS CHANGED"
echo "ledger lines: $(wc -l < "$(L "$H2")" | tr -d ' ')"
echo "--- appended correction rows:"; tail -n 2 "$(L "$H2")"

step "S3 corrected evidence passes (review-only JSON, default text, plan)"
run V "$H2" --review-only --json
run V "$H2"
run P "$H2"

step "S4 adversarial: remove the genuine row from the corrected ledger; guard refuses"
H4=$(new_home s4); grep -v deepseek-v4-pro "$(L "$H2")" | grep -v '"kind":"correction".*"group":"no-mistakes"' > "$(L "$H4")"
echo "--- ledger:"; cut -c1-160 "$(L "$H4")"
run V "$H4" --review-only --json
echo "--- variant: corrected ledger with the genuine row line removed but both corrections kept"
H4b=$(new_home s4b); grep -v '"kind":"review".*deepseek-v4-pro' "$(L "$H2")" > "$(L "$H4b")"
run V "$H4b" --review-only --json
echo "--- variant: the genuine row is excluded too"
H4c=$(new_home s4c); cp "$(L "$H2")" "$(L "$H4c")"
run C "$H4c" exclude-review "${GOOD[@]}"
run V "$H4c" --review-only --json

step "S5 adversarial: supersede alone is not enough (bad row still adds its constraint)"
H5=$(new_home s5); { bad_row; good_row; } > "$(L "$H5")"
run C "$H5" supersede-author-group "${GOOD[@]}" --group no-mistakes
run V "$H5" --review-only --json
echo "--- exclude alone (copied entry still in the genuine row)"
H5b=$(new_home s5b); { bad_row; good_row; } > "$(L "$H5b")"
run C "$H5b" exclude-review "${BAD[@]}"
run V "$H5b" --review-only --json

step "S6 adversarial rejections: each exits 2 and leaves the ledger byte-identical"
H6=$(new_home s6); { bad_row; good_row; } > "$(L "$H6")"
sum() { shasum -a 256 < "$(L "$H6")"; }
s0=$(sum)
run C "$H6" exclude-review 1795202233 openai-codex/gpt-6.1-terra aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
run C "$H6" exclude-review "${BAD[0]}" "${BAD[1]}" cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
run C "$H6" supersede-author-group "${GOOD[@]}" --group no-such-group
run C "$H6" supersede-author-group "${GOOD[@]}"
run C "$H6" exclude-review "${BAD[@]}" --authority-words ''
FM_HOME="$H6" run python3 "$NEW" correction --pr "$URL" --head 3333333333333333333333333333333333333333 --effect exclude-review \
  --target-at "${BAD[0]}" --target-reader-model "${BAD[1]}" --target-report-sha256 "${BAD[2]}" \
  --authority-words 'x' --authority-at 1 --reason r
echo "--- ambiguous: duplicate the bad row, then name it"
cp "$(L "$H6")" "$SCRATCH/s6.keep"; bad_row >> "$(L "$H6")"; s_amb=$(sum)
run C "$H6" exclude-review "${BAD[@]}"
[ "$s_amb" = "$(sum)" ] && echo "RESULT: ambiguous rejection left ledger byte-identical" || echo "RESULT: LEDGER CHANGED"
cp "$SCRATCH/s6.keep" "$(L "$H6")"
echo "--- away posture"
printf 'mode: away\n' > "$H6/state/.afk-contract"
run C "$H6" exclude-review "${BAD[@]}"
rm "$H6/state/.afk-contract"
[ "$s0" = "$(sum)" ] && echo "RESULT: ledger byte-identical after all rejections" || echo "RESULT: LEDGER CHANGED"
echo "--- a correction never creates a missing ledger"
H6b=$(new_home s6b)
run C "$H6b" exclude-review "${BAD[@]}"
[ -e "$(L "$H6b")" ] && echo "RESULT: LEDGER CREATED" || echo "RESULT: no ledger created"

step "S7 old (base-commit) code fails closed on a correction row"
PY="$OLD" run V "$H2" --review-only --json
PY="$OLD" run V "$H2"

step "S8 ledgers without corrections: old and new code give byte-identical output"
H8=$(new_home s8); { other_row; bad_row; good_row; } > "$(L "$H8")"
FM_HOME="$H8" python3 "$NEW" captain-word --pr "$URL" --head "$HEAD" --words 'Merge it.' >/dev/null
same=1
for args in "--review-only --json" "--review-only" "--json" ""; do
  # shellcheck disable=SC2086
  o=$(PY="$OLD" V "$H8" $args 2>&1; echo "rc=$?"); n=$(PY="$NEW" V "$H8" $args 2>&1; echo "rc=$?")
  printf 'verify %-22s old: %s\n%-29s new: %s\n' "[$args]" "$o" "" "$n"
  [ "$o" = "$n" ] || same=0
done
o=$(PY="$OLD" P "$H8"; echo "rc=$?"); n=$(PY="$NEW" P "$H8"; echo "rc=$?"); [ "$o" = "$n" ] || same=0
printf 'plan old: %s\nplan new: %s\n' "$o" "$n"
o=$(FM_HOME="$H8" python3 "$OLD" latest --pr "$URL"); n=$(FM_HOME="$H8" python3 "$NEW" latest --pr "$URL"); [ "$o" = "$n" ] || same=0
echo "latest identical: $([ "$o" = "$n" ] && echo yes || echo no)"
[ "$same" = 1 ] && echo "RESULT: old and new outputs identical" || echo "RESULT: OUTPUTS DIFFER"

step "S9 a correction is never merge authority: default verify with only a correction reports review coverage, not captain-word"
run V "$H2" --json

step "S4d adversarial: corrected ledger, genuine row gone, an honest ship-only row remains; guard names the uncovered group"
H4d=$(new_home s4d); { other_row; bad_row; } > "$(L "$H4d")"
run C "$H4d" exclude-review "${BAD[@]}"
run V "$H4d" --review-only --json
run V "$H4d"
