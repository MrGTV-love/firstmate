#!/usr/bin/env bash
# Model-free T3 walkthrough: real Git, the real task-hook installer, the real
# Claude PreToolUse hook entrypoint. No harness session, no provider call.
# Usage: t3-walkthrough.sh <firstmate-checkout>
set -u
FM=$1
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS
unset TYPESAFE_API_KEY TYPESAFE_API_KEY_PRIVATE OPENROUTER_API_KEY JEV_BACKEND ANTHROPIC_API_KEY
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-t3-walk.XXXXXX")
trap 'chmod -R u+w "$LAB"; rm -rf "$LAB"' EXIT
export FM_GUARD_EVENT_LOG="$LAB/guard-events.jsonl"
export GIT_AUTHOR_NAME=Walk GIT_AUTHOR_EMAIL=walk@example.invalid GIT_COMMITTER_NAME=Walk GIT_COMMITTER_EMAIL=walk@example.invalid
H="$LAB/home"; mkdir -p "$H/config" "$H/state" "$H/data"
R="$LAB/repo"; REMOTE="$LAB/remote.git"
git init -q -b main "$R"; git init -q --bare "$REMOTE"
printf 'base\n' >"$R/README.md"; git -C "$R" add README.md; git -C "$R" commit -qm base
git -C "$R" remote add origin "$REMOTE"; git -C "$R" push -q origin main
HOOKS="$H/state/walk.git-hooks"
"$FM/bin/fm-git-strip-ai-trailers.sh" install "$HOOKS" "$R" 0 || { echo "install failed"; exit 1; }
# Same mechanism fm-spawn.sh exports into the worker pane.
g() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$HOOKS git -C "$R" "$@"; }
token() { printf 'ghp_%036d' 0; }            # 40 chars: ghp_ + 36
TOK=$(token)
hook_write() {  # Claude PreToolUse Write through the production hook command
  local path=$1 file=$2
  python3 -c 'import json,sys; print(json.dumps({"hook_event_name":"PreToolUse","cwd":sys.argv[1],"tool_name":"Write","tool_input":{"file_path":sys.argv[2],"content":open(sys.argv[3]).read()}}))' "$R" "$path" "$file" \
    | "$FM/bin/fm-jev-guard-hook.sh" "$H" "$H/config" "$H/state" walk "$R" "$H/data" firstmate FIRSTMATE_JEV_GUARD_V1
}
hide() { sed "s/$TOK/<TOKEN-LEAKED>/g"; }
step() { printf '\n=== %s ===\n' "$*"; }
leak_check() { case "$1" in *ghp_*|*AKIA*) echo "LEAK: credential bytes printed";; *) echo "no credential bytes in output";; esac; }

step "S1 / T3(a): commit a file holding a 40-char ghp_ token"
before=$(git -C "$R" rev-parse HEAD)
printf 'GITHUB_TOKEN=%s\n' "$TOK" >"$R/config.txt"; git -C "$R" add config.txt
out=$(g commit -qm 'add token' 2>&1); st=$?
printf '%s\n' "$out" | hide; echo "exit=$st"; leak_check "$out"
[ "$(git -C "$R" rev-parse HEAD)" = "$before" ] && echo "HEAD unchanged" || echo "HEAD MOVED"

step "S6: retry the same refused commit (budget 1 -> escalate)"
out=$(g commit -qm 'add token again' 2>&1); st=$?
printf '%s\n' "$out" | hide; echo "exit=$st"
[ "$(git -C "$R" rev-parse HEAD)" = "$before" ] && echo "HEAD unchanged after escalation" || echo "HEAD MOVED"
git -C "$R" rm -q --cached config.txt; rm "$R/config.txt"

step "S2 / T3(b): Claude Write of the token to an ignored .env"
printf '.env\n' >"$R/.gitignore"; git -C "$R" add .gitignore; g commit -qm 'ignore .env' && echo "gitignore committed (allowed decision)"
before=$(git -C "$R" rev-parse HEAD)
printf 'GITHUB_TOKEN=%s\n' "$TOK" >"$LAB/env.payload"
out=$(hook_write "$R/.env" "$LAB/env.payload"); st=$?
echo "hook exit=$st stdout=[${out}] (empty stdout + exit 0 = write allowed)"
cp "$LAB/env.payload" "$R/.env"
g add -A; echo "staged after 'git add -A': [$(git -C "$R" diff --cached --name-only)]"
out=$(g commit -qm 'try commit' 2>&1); echo "commit exit=$? :: $(printf '%s' "$out" | head -1)"
[ "$(git -C "$R" rev-parse HEAD)" = "$before" ] && echo "HEAD unchanged; .env never committed" || echo "HEAD MOVED"
git -C "$R" log --all --format=%H | while read -r c; do git -C "$R" ls-tree -r --name-only "$c"; done | grep -qx .env && echo ".env FOUND in history" || echo ".env absent from all history"

step "S3 / T3(c): placeholder commits and pushes"
printf 'GITHUB_TOKEN=replace-me\nAPI_KEY=xxx\n' >"$R/settings.env.example"; g add settings.env.example
g commit -qm 'placeholder' && echo "placeholder commit OK"
g push -q origin main && echo "placeholder push OK; remote main=$(git -C "$REMOTE" rev-parse --short main) local=$(git -C "$R" rev-parse --short HEAD)"

step "S4 / T3(d): 396,924-byte report written via Claude hook, then committed"
python3 -c 'import sys; s=("Measured observations in an ordinary report, line of findings.\n"*8000)[:396924]; open(sys.argv[1],"w").write(s)' "$LAB/report.payload"
echo "payload bytes=$(wc -c <"$LAB/report.payload" | tr -d ' ')"
out=$(hook_write "$R/report.md" "$LAB/report.payload"); st=$?
echo "hook exit=$st stdout=[${out}]"
cp "$LAB/report.payload" "$R/report.md"; g add report.md
g commit -qm 'report' && echo "report commit OK; committed blob bytes=$(git -C "$R" cat-file -s HEAD:report.md)"
g push -q origin main && echo "report push OK"

step "S5: credential committed with --no-verify (hooks skipped) is caught at push"
rbefore=$(git -C "$REMOTE" rev-parse main)
printf 'token=%s\n' "$TOK" >"$R/leak.txt"; git -C "$R" add leak.txt; g commit -q --no-verify -m 'sneak'
printf 'token=replace-me\n' >"$R/leak.txt"; git -C "$R" add leak.txt; g commit -q -m 'hide at tip'
out=$(g push -q origin main 2>&1); st=$?
printf '%s\n' "$out" | hide; echo "push exit=$st"; leak_check "$out"
[ "$(git -C "$REMOTE" rev-parse main)" = "$rbefore" ] && echo "remote unchanged" || echo "REMOTE MOVED"
out=$(g push -q origin HEAD:refs/heads/sidebranch 2>&1); echo "new-branch push exit=$? :: $(printf '%s' "$out" | head -1)"
git -C "$R" reset -q --hard "$rbefore"

step "S7: existing fixture line in history is not re-scanned; moved file OK; new line still refused"
printf 'line one\nE2E_KEY=AKIA%s\nline three\n' DESKTOPONLYEXAMPL >"$R/fixture.test.sh"
git -C "$R" add fixture.test.sh; git -C "$R" commit -q --no-verify -m 'historic fixture'
git -C "$R" push -q --no-verify origin main && echo "fixture placed on remote (hooks bypassed, as historic content)"
sed -i.bak 's/line one/line one edited/' "$R/fixture.test.sh"; rm "$R/fixture.test.sh.bak"; g add fixture.test.sh
g commit -qm 'unrelated edit' && echo "unrelated edit beside fixture: commit OK"
g push -q origin main && echo "unrelated edit: push OK"
g mv fixture.test.sh renamed-fixture.test.sh; g commit -qm 'rename' && echo "git mv of fixture file: commit OK"
g push -q origin main && echo "rename: push OK"
printf 'NEW_KEY=AKIA%s\n' ZZZZZZZZZZZZZZZZ >>"$R/renamed-fixture.test.sh"; g add renamed-fixture.test.sh
out=$(g commit -qm 'new key' 2>&1); st=$?; printf '%s\n' "$out" | head -2; echo "new AKIA line exit=$st"; leak_check "$out"
git -C "$R" reset -q --hard HEAD

step "S8: fail closed when inspection input is invalid (bad MERGE_HEAD)"
printf 'not-an-oid\n' >"$R/.git/MERGE_HEAD"
printf 'benign\n' >>"$R/README.md"; git -C "$R" add README.md
out=$(cd "$R" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$HOOKS "$HOOKS/pre-commit" 2>&1); st=$?
printf '%s\n' "$out"; echo "pre-commit exit=$st"
out=$(cd "$R" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$HOOKS "$HOOKS/pre-commit" 2>&1); st=$?
printf '%s\n' "$out" | tail -1; echo "retry pre-commit exit=$st"
rm "$R/.git/MERGE_HEAD"; g commit -qm benign && echo "after restoring input: benign commit OK (allow clears counts)"

step "S9: keep-ai-trailers=1 install keeps credential checks and keeps trailers"
H2="$LAB/hooks-keep"; "$FM/bin/fm-git-strip-ai-trailers.sh" install "$H2" "$R" 1
printf 'x=%s\n' "$TOK" >"$R/k.txt"; git -C "$R" add k.txt
out=$(git -C "$R" -c core.hooksPath="$H2" commit -qm 'k' 2>&1); echo "keep-trailers credential commit exit=$? :: $(printf '%s' "$out" | head -1)"
git -C "$R" rm -q --cached k.txt; rm "$R/k.txt"
printf 'ok\n' >>"$R/README.md"; git -C "$R" add README.md
git -C "$R" -c core.hooksPath="$H2" commit -qm $'subj\n\nCo-Authored-By: Claude <noreply@anthropic.com>' && echo "trailer kept: $(git -C "$R" log -1 --format=%B | grep -c Co-Authored-By)"
printf 'ok2\n' >>"$R/README.md"; git -C "$R" add README.md
g commit -qm $'subj\n\nCo-Authored-By: Claude <noreply@anthropic.com>' && echo "default install trailer count: $(git -C "$R" log -1 --format=%B | grep -c Co-Authored-By)"

step "S10: project pre-commit hook: its failure propagates; credential it stages is caught"
printf '#!/usr/bin/env bash\necho project-hook-ran >&2\nexit 17\n' >"$R/.git/hooks/pre-commit"; chmod +x "$R/.git/hooks/pre-commit"
printf 'p\n' >>"$R/README.md"; git -C "$R" add README.md
out=$(g commit -qm p 2>&1); echo "project hook exit-17 -> commit exit=$? :: $out"
(cd "$R" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$HOOKS "$HOOKS/pre-commit") >/dev/null 2>&1; echo "wrapper status=$?"
cat >"$R/.git/hooks/pre-commit" <<'SH'
#!/usr/bin/env bash
printf 'ghp_%036d\n' 0 >generated.txt; git add generated.txt
SH
out=$(g commit -qm p 2>&1); st=$?; printf '%s\n' "$out" | hide | head -2; echo "project-staged credential exit=$st"
rm "$R/.git/hooks/pre-commit"

step "Guard events (one JSON line per decision)"
python3 - "$FM_GUARD_EVENT_LOG" <<'PY'
import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
for r in rows:
    print({k:r.get(k) for k in ("guard","decision","source_ok","repeat")})
print("events:", len(rows))
PY
step "Jev guard ledger rows for the two Claude writes"
python3 - "$H/state/jev-guard.jsonl" <<'PY'
import json,sys
for l in open(sys.argv[1]):
    r=json.loads(l)
    print({k:r.get(k) for k in ("tool","decision","enforcement","branch","request_started","error_type")})
PY
