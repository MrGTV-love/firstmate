#!/usr/bin/env bash
# Drive the real Claude PreToolUse hook (bin/fm-jev-guard-hook.sh) in disposable homes.
set -u
ROOT=$1; OUT=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
REAL=$(mktemp -d "${TMPDIR:-/tmp}/fm-realish.XXXXXX"); mkdir -p "$REAL/state" "$REAL/config" "$REAL/data/t1"
WT=$(mktemp -d "${TMPDIR:-/tmp}/fm-wt.XXXXXX")
FORGED=$(mktemp -d "${TMPDIR:-/tmp}/fm-forged.XXXXXX")
mkdir -p "$LAB/data/t1"
for h in "$LAB" "$REAL"; do printf 'TYPESAFE_API_KEY=fake-drive-key\n' > "$h/.env"; done
export FM_TEST_SEAM=1
REQ=$(mktemp); PORTF=$(mktemp -u)
node /tmp/fm-jev-drive/fake.mjs "$REQ" "$PORTF" & FAKE=$!
for _ in $(seq 100); do [ -s "$PORTF" ] && break; sleep 0.05; done
HEALTHY="http://127.0.0.1:$(cat "$PORTF")/v1/systemone"
DOWN="http://127.0.0.1:9/v1/systemone"   # discard port: connection refused = judge outage
pre() { jq -cn --arg cwd "$WT" --arg tool "$1" --argjson input "$2" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:$input,tool_use_id:"drive"}'; }
hook() { # home url tool input-json
  local home=$1 url=$2 tool=$3 input=$4 out rc row
  out=$(pre "$tool" "$input" | env -u NO_MISTAKES_GATE FM_JEV_GUARD_BASE_URL="$url" "$ROOT/bin/fm-jev-guard-hook.sh" "$home" "$home/config" "$home/state" t1 "$WT" "$home/data/t1" firstmate FIRSTMATE_JEV_GUARD_V1 2>/dev/null); rc=$?
  if [ -z "$out" ] && [ $rc -eq 0 ]; then verdict=ALLOW; elif jq -e '.hookSpecificOutput.permissionDecision=="deny"' <<<"$out" >/dev/null 2>&1; then verdict=DENY; else verdict="OTHER rc=$rc"; fi
  row=$(tail -1 "$home/state/jev-guard.jsonl" 2>/dev/null | jq -c '{decision,branch,error_type}' 2>/dev/null)
  printf '%-6s %s\n' "$verdict" "$row"
}
case_() { # label home url tool input
  local label=$1; shift
  local b; b=$(wc -l < "$REQ" | tr -d ' ')
  local r; r=$(hook "$@")
  local a; a=$(wc -l < "$REQ" | tr -d ' ')
  printf '%-58s -> %s judge_requests=+%s\n' "$label" "$r" "$((a-b))"
}
cmd() { jq -cn --arg c "$1" '{command:$c}'; }
{
echo "== lab home: $LAB (marker line 1: $(head -1 "$LAB/.fm-lab-home"))"
echo "== real-like home (no marker): $REAL"
echo
echo "-- S1 judge DOWN, real home, read-only commands"
for c in 'ls -la' 'ps aux | grep firstmate' 'git status --short' 'git --no-pager log --oneline -3' 'find . -name x' 'cat README.md | wc -l'; do case_ "real/down: $c" "$REAL" "$DOWN" Bash "$(cmd "$c")"; done
echo
echo "-- S2 judge DOWN, real home, mutating or unproven commands (must DENY)"
# shellcheck disable=SC2016
for c in 'rm -rf build' 'deploy' 'sort -o x y' "find . -'delete'" 'find . "-exec" rm {} +' 'find . -de\lete' 'find . -delete' 'find . -fprint0 x' 'git branch -D main' 'git reflog expire --expire=now --all' 'git --git-dir=/tmp/x/.git status' 'git -c core.fsmonitor=x status' 'git diff --output=x' 'git log --out=x' 'rg --pre rm x .' 'uniq a b' 'ls; rm -rf build' 'ls && rm -rf build' 'ls | xargs rm' 'cat $HOME' 'echo $(rm -rf build)' 'echo hi > f' 'ls &' 'find . -{delete,x}' 'tee f' "$(printf 'ls\nrm -rf build')"; do case_ "real/down: $(printf %s "$c" | tr '\n' '⏎')" "$REAL" "$DOWN" Bash "$(cmd "$c")"; done
echo
echo "-- S3 judge DOWN, lab home, teardown and other shell"
case_ "lab/down: rm -rf build" "$LAB" "$DOWN" Bash "$(cmd 'rm -rf build')"
case_ "lab/down: tmux -L fm-lab kill-server" "$LAB" "$DOWN" Bash "$(cmd 'tmux -L fm-lab kill-server')"
case_ "lab/down: ls -la (read-only wins first)" "$LAB" "$DOWN" Bash "$(cmd 'ls -la')"
echo
echo "-- S4 judge DOWN, lab home, override set (must DENY)"
for v in FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_ANYTHING_OVERRIDE; do
  b=$(wc -l < "$REQ" | tr -d ' ')
  r=$(export "$v=/tmp/elsewhere"; hook "$LAB" "$DOWN" Bash "$(cmd 'rm -rf build')")
  printf '%-58s -> %s\n' "lab/down + $v=/tmp/elsewhere: rm -rf build" "$r"
done
r=$(export FM_STATE_OVERRIDE=; hook "$LAB" "$DOWN" Bash "$(cmd 'rm -rf build')"); printf '%-58s -> %s\n' "lab/down + FM_STATE_OVERRIDE= (empty): rm -rf build" "$r"
echo
echo "-- S5 judge DOWN, lab home, writes and edits (must DENY)"
case_ "lab/down: Write $WT/src/lab.ts" "$LAB" "$DOWN" Write "$(jq -cn --arg p "$WT/src/lab.ts" '{file_path:$p,content:"plain text"}')"
case_ "lab/down: Edit $WT/src/lab.ts" "$LAB" "$DOWN" Edit "$(jq -cn --arg p "$WT/src/lab.ts" '{file_path:$p,old_string:"a",new_string:"b"}')"
case_ "lab/down: Write outside root /etc/x" "$LAB" "$DOWN" Write '{"file_path":"/etc/fm-x","content":"x"}'
echo
echo "-- S6 judge DOWN, forged or wrong marker (must DENY)"
mkdir -p "$FORGED/state" "$FORGED/config" "$FORGED/data/t1"; printf 'TYPESAFE_API_KEY=fake\n' > "$FORGED/.env"
printf 'fm-lab-home v1-forged\n' > "$FORGED/.fm-lab-home"; case_ "forged token 'fm-lab-home v1-forged': rm -rf build" "$FORGED" "$DOWN" Bash "$(cmd 'rm -rf build')"
printf 'xx\nfm-lab-home v1\n' > "$FORGED/.fm-lab-home"; case_ "token not on line 1: rm -rf build" "$FORGED" "$DOWN" Bash "$(cmd 'rm -rf build')"
rm "$FORGED/.fm-lab-home"; case_ "no marker: rm -rf build" "$FORGED" "$DOWN" Bash "$(cmd 'rm -rf build')"
echo
echo "-- S7 judge DOWN, oversized command (bound = 16 x 16384 = 262144 chars; above it is a size refusal, never admitted)"
case_ "lab/down: 'ls ' + 200k chars" "$LAB" "$DOWN" Bash "$(cmd "ls $(head -c 200000 /dev/zero | tr '\0' a)")"
case_ "real/down: 'ls ' + 200k chars" "$REAL" "$DOWN" Bash "$(cmd "ls $(head -c 200000 /dev/zero | tr '\0' a)")"
case_ "lab/down: 'ls ' + 300k chars (too large)" "$LAB" "$DOWN" Bash "$(cmd "ls $(head -c 300000 /dev/zero | tr '\0' a)")"
case_ "real/down: 'ls ' + 300k chars (too large)" "$REAL" "$DOWN" Bash "$(cmd "ls $(head -c 300000 /dev/zero | tr '\0' a)")"
case_ "lab/healthy: 'rm -rf build ' + 300k chars (too large)" "$LAB" "$HEALTHY" Bash "$(cmd "rm -rf build $(head -c 300000 /dev/zero | tr '\0' a)")"
echo
echo "-- S8 judge HEALTHY: everything still judged"
case_ "real/healthy: ls -la" "$REAL" "$HEALTHY" Bash "$(cmd 'ls -la')"
case_ "real/healthy: git status --short" "$REAL" "$HEALTHY" Bash "$(cmd 'git status --short')"
case_ "real/healthy: rm -rf build" "$REAL" "$HEALTHY" Bash "$(cmd 'rm -rf build')"
case_ "lab/healthy: rm -rf build" "$LAB" "$HEALTHY" Bash "$(cmd 'rm -rf build')"
case_ "lab/healthy: ls -la" "$LAB" "$HEALTHY" Bash "$(cmd 'ls -la')"
case_ "lab/healthy: Write $WT/src/a.ts" "$LAB" "$HEALTHY" Write "$(jq -cn --arg p "$WT/src/a.ts" '{file_path:$p,content:"plain text"}')"
case_ "lab/healthy: Write sk-live credential" "$LAB" "$HEALTHY" Write "$(jq -cn --arg p "$WT/src/a.ts" '{file_path:$p,content:"API_KEY=sk-live-abc"}')"
echo
echo "-- S9 judge DOWN via missing credential (no .env), real home"
mv "$REAL/.env" "$REAL/env.off"
case_ "real/no-cred: ls -la" "$REAL" "$HEALTHY" Bash "$(cmd 'ls -la')"
case_ "real/no-cred: deploy" "$REAL" "$HEALTHY" Bash "$(cmd 'deploy')"
} | tee "$OUT"
kill "$FAKE"; rm -rf "$LAB" "$REAL" "$WT" "$FORGED" "$REQ" "$PORTF"
