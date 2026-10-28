#!/usr/bin/env bash
# Live driver: real bin/fm-review-record.py against a real git repo and a
# state.sqlite created by the real no-mistakes binary (schema), in throwaway dirs.
set -u
WT_ROOT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M60Z05FQ5ECT7BK4D4PXCK0G
REC="$WT_ROOT/bin/fm-review-record.py"
LAB=/tmp/nmlab-73675
PRISTINE=$LAB/nmhome/state.sqlite
OLD_REC=$LAB/old-fm-review-record.py
BASE_COMMIT=7c204105483e077e19f2df76fbad072bed1eb7f6
git -C "$WT_ROOT" show "$BASE_COMMIT:bin/fm-review-record.py" > "$OLD_REC"
# Old script resolves fm-pr-lib.sh next to itself; run it from a copy of bin.
mkdir -p "$LAB/oldbin" && git -C "$WT_ROOT" archive "$BASE_COMMIT" bin | tar -x -C "$LAB/oldbin"
OLD_REC=$LAB/oldbin/bin/fm-review-record.py
unset NM_HOME FM_STATE_OVERRIDE
URL=https://github.com/example/repo/pull/197
OPENAI=openai-codex/gpt-6.1-sol
CLAUDE=claude-opus-5-5
G() { git -C "$WT" -c user.name=lab -c user.email=lab@example.invalid "$@"; }

say() { printf '\n$ %s\n' "$*"; }
run() { say "$*"; "$@"; echo "[exit $?]"; }

# new_case <name> <ship-model>: repo with base commit on main, branch fm/fixture
new_case() {
  C=$LAB/cases/$1; rm -rf "$C"; mkdir -p "$C/fmhome/state" "$C/nm"
  WT=$C/wt; git init -q -b main "$WT"; G commit -q --allow-empty -m base
  BASE=$(G rev-parse HEAD); G checkout -q -b fm/fixture
  cp "$PRISTINE" "$C/nm/state.sqlite"
  printf '%s\n' "worktree=$WT" "project=$WT" kind=ship "model=$2" branch=fm/fixture spawn_gen=g1 > "$C/fmhome/state/task-197.meta"
  export FM_HOME=$C/fmhome NM_HOME=$C/nm
  printf 'case %s: ship meta model=%s\n' "$1" "$2"
}
commit() { G commit -q --allow-empty -m "$1"; HEAD=$(G rev-parse HEAD); }
sql() { sqlite3 "$NM_HOME/state.sqlite" "$1"; }
# add_run <id> <base> <head> ; add_inv <run> <agent> <model|NULL> <provider|NULL> <exit>
add_run() {
  sql "INSERT OR IGNORE INTO repos(id,working_path,upstream_url,created_at) VALUES('repo','$WT','https://github.com/example/repo',0);
       INSERT INTO runs(id,repo_id,branch,head_sha,base_sha,last_pushed_sha,pr_url,status,created_at,updated_at)
       VALUES('$1','repo','fm/fixture','$3','$2','$3','$URL','completed',0,0);"
}
add_inv() {
  local m=$3 p=$4
  [ "$m" = NULL ] || m="'$m'"; [ "$p" = NULL ] || p="'$p'"
  sql "INSERT INTO agent_invocations(id,run_id,step_name,round,purpose,agent,model,model_provider,session_mode,started_at,completed_at,duration_ms,exit_status)
       VALUES(lower(hex(randomblob(8))),'$1','review',1,'fix','$2',$m,$p,'fresh',0,0,0,'$5');"
}
review() {  # <reader> <author-groups> [covered] [verdict]
  local verdict=${4:-PASS}
  printf 'VERDICT: %s head=%s\nlab report\n' "$verdict" "$HEAD" > "$C/report-$RANDOM.md"
  local rep; rep=$(ls -t "$C"/report-*.md | head -1)
  local -a cov=(); [ -n "${3:-}" ] && cov=(--covered-groups "$3")
  run python3 "$REC" review --pr "$URL" --head "$HEAD" --verdict "$verdict" --reader-model "$1" \
    --author-groups "$2" ${cov[@]+"${cov[@]}"} --loosens-deny-allow-list no --widens-guard no \
    --customer-data-billing-spend no --report "$rep"
}
verify() { run python3 "$REC" verify --pr "$URL" --head "$HEAD" --task task-197 --base "$BASE"; }

scenario() { printf '\n==================== %s ====================\n' "$*"; }

SEL=${1:-all}
want() { [ "$SEL" = all ] || [ "$SEL" = "$1" ]; }
if want s1; then
scenario "S1 PR-197 shape: OpenAI ship + Claude pipeline commits, Main types all=OpenAI, one Claude PASS"
new_case s1 "$OPENAI"
commit 'feat: ship implementation'; commit 'no-mistakes(review): repair consumer behavior'; commit 'no-mistakes(test): update assertion'
add_run run1 "$BASE" "$HEAD"; add_inv run1 claude claude-sonnet-5-5 anthropic completed; add_inv run1 claude "$CLAUDE" anthropic completed
G log --format='  %h %s' "$BASE..$HEAD"
review "$CLAUDE" "{\"all\":[\"$OPENAI\"]}"
say "OLD gate at base commit $BASE_COMMIT (no evidence derivation):"
run python3 "$OLD_REC" verify --pr "$URL" --head "$HEAD"
say "NEW gate:"
verify
scenario "S1b fix path: OpenAI reader reads the pipeline group (command shape printed by the refusal)"
review "$OPENAI" "{\"ship\":[\"$OPENAI\"],\"no-mistakes:anthropic\":[\"$CLAUDE\",\"claude-sonnet-5-5\"]}" '["no-mistakes:anthropic"]'
verify
scenario "S1c Claude reader re-records its read declaring the real ship author"
review "$CLAUDE" "{\"ship\":[\"$OPENAI\"]}" '["ship"]'
verify
fi
if want s2; then
scenario "S2 routine: OpenAI-only ship, one Claude PASS naming ship"
new_case s2 "$OPENAI"; commit 'feat: ship implementation'
review "$CLAUDE" "{\"ship\":[\"$OPENAI\"]}"
verify
fi
if want s3; then
scenario "S3 typed lie: Claude ship author (meta), Main types all=OpenAI, Claude reader"
new_case s3 "$CLAUDE"; commit 'feat: ship implementation'
review "$CLAUDE" "{\"all\":[\"$OPENAI\"]}"
say "OLD gate:"; run python3 "$OLD_REC" verify --pr "$URL" --head "$HEAD"
say "NEW gate:"; verify
fi
if want s4; then
scenario "S4 relaunch history: gen g0 OpenAI then g1 Claude; Claude-only PASS, then add OpenAI PASS"
new_case s4 "$CLAUDE"; commit 'feat: ship implementation'
printf 'g0\t\t%s\ng1\tg0\t%s\ng1\tg0\t%s\ngOLD\t\tgemini-3-pro\n' "$OPENAI" "$OPENAI" "$CLAUDE" > "$FM_HOME/state/task-197.launch-models"
cat "$FM_HOME/state/task-197.launch-models"
review "$CLAUDE" "{\"ship\":[\"$OPENAI\",\"$CLAUDE\"]}"
verify
review "$OPENAI" "{\"ship\":[\"$OPENAI\",\"$CLAUDE\"]}"
verify
fi
if want s6; then
scenario "S6 null-base run (new-branch push, base_sha all zero) with Claude invocations"
new_case s6 "$OPENAI"; commit 'feat: ship'; commit 'no-mistakes(review): fix'
add_run run1 0000000000000000000000000000000000000000 "$HEAD"; add_inv run1 claude "$CLAUDE" anthropic completed
review "$CLAUDE" "{\"ship\":[\"$OPENAI\"]}" '["ship"]'
verify
review "$OPENAI" "{\"no-mistakes:anthropic\":[\"$CLAUDE\"]}"
verify
fi
if want s7; then
scenario "S7 rebase: OpenAI run A wrote commit (old SHA), Claude run B rebased it"
new_case s7 "$CLAUDE"; commit 'feat: ship'
commit 'no-mistakes(review): OpenAI draft'; OLDSHA=$HEAD; G reset -q --hard HEAD~1
commit 'no-mistakes(review): OpenAI draft (rebased)'
add_run runA "$BASE" "$OLDSHA"; add_inv runA acp:omp gpt-5.1-codex openai completed
add_run runB "$BASE" "$HEAD"; add_inv runB claude "$CLAUDE" anthropic completed
review "$OPENAI" "{\"ship\":[\"$CLAUDE\"],\"no-mistakes:anthropic\":[\"$CLAUDE\"],\"no-mistakes:openai\":[\"gpt-5.1-codex\"]}"
verify
review "$CLAUDE" "{\"no-mistakes:openai\":[\"gpt-5.1-codex\"]}"
verify
fi
if want s8; then
scenario "S8a cancelled claude invocation with empty model counts as anthropic"
new_case s8a "$OPENAI"; commit 'feat: ship'; commit 'no-mistakes(review): fix'
add_run run1 "$BASE" "$HEAD"; add_inv run1 claude '' NULL cancelled
review "$CLAUDE" "{\"ship\":[\"$OPENAI\"]}" '["ship"]'
verify
review "$OPENAI" "{\"no-mistakes:anthropic\":[\"claude\"]}"
verify
scenario "S8b errored acp:omp invocation with empty model stays unknown -> captain words only"
new_case s8b "$OPENAI"; commit 'feat: ship'; commit 'no-mistakes(review): fix'
add_run run1 "$BASE" "$HEAD"; add_inv run1 claude "$CLAUDE" anthropic completed; add_inv run1 acp:omp '' NULL error
review "$CLAUDE" "{\"ship\":[\"$OPENAI\"]}" '["ship"]'
review "$OPENAI" "{\"no-mistakes:anthropic\":[\"$CLAUDE\"],\"no-mistakes:unknown\":[\"unknown\"]}"
verify
run python3 "$REC" captain-word --pr "$URL" --head "$HEAD" --words 'Lab: merge PR 197 at this head'
verify
fi
if want s9; then
scenario "S9 exact-head FAIL blocks even after later covering PASSes"
new_case s9 "$OPENAI"; commit 'feat: ship'
review gemini-3-pro "{\"ship\":[\"$OPENAI\"]}" '' FAIL
review "$CLAUDE" "{\"ship\":[\"$OPENAI\"]}"
verify
fi
if want s10; then
scenario "S10 state.sqlite opened read-only: bytes+mtime unchanged; missing DB is never created"
new_case s10 "$OPENAI"; commit 'feat: ship'; commit 'no-mistakes(review): fix'
add_run run1 "$BASE" "$HEAD"; add_inv run1 claude "$CLAUDE" anthropic completed
review "$OPENAI" "{\"ship\":[\"$OPENAI\"],\"no-mistakes:anthropic\":[\"$CLAUDE\"]}" '["no-mistakes:anthropic"]'
review "$CLAUDE" "{\"ship\":[\"$OPENAI\"]}" '["ship"]'
chmod 0444 "$NM_HOME/state.sqlite"; chmod 0555 "$NM_HOME"
say "before:"; stat -f '%m %z' "$NM_HOME/state.sqlite"; shasum -a 256 "$NM_HOME/state.sqlite"; ls -a "$NM_HOME"
verify
say "after:"; stat -f '%m %z' "$NM_HOME/state.sqlite"; shasum -a 256 "$NM_HOME/state.sqlite"; ls -a "$NM_HOME"
chmod 0755 "$NM_HOME"; chmod 0644 "$NM_HOME/state.sqlite"
say "missing database:"
export NM_HOME=$C/nm-empty; mkdir -p "$NM_HOME"
verify
ls -a "$NM_HOME"
fi
