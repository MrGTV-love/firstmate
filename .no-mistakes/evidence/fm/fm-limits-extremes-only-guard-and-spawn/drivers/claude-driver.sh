#!/usr/bin/env bash
# usage: claude-driver.sh <label> <repo-root-containing-bin>
set -u
label=$1; root=$2; T=$(cat /tmp/fm-nm-live-dir.txt)
H=$T/chome-$label; rm -rf "$H"; mkdir -p "$H/config" "$H/state" "$H/data/scout1" "$H/data/other" "$H/repo"
printf 'TYPESAFE_API_KEY=lab-key\n' > "$H/.env"
git init -q "$H/repo"; echo base > "$H/repo/notes.md"; git -C "$H/repo" add notes.md
git -C "$H/repo" -c user.name=F -c user.email=f@e.invalid -c commit.gpgsign=false commit -qm f
echo 'edited by scout deadjudge' > "$H/repo/notes.md"; echo 'untracked deadjudge' > "$H/repo/untracked.md"
echo 'own task file deadjudge' > "$H/data/scout1/request.md"; echo 'other task file deadjudge' > "$H/data/other/secret.md"
: > "$T/creq-$label.log"; rm -f "$T/cport-$label"
node "$T/fake.mjs" "$T/creq-$label.log" "$T/cport-$label" 2>/dev/null & fpid=$!
for _ in $(seq 1 100); do [ -s "$T/cport-$label" ] && break; sleep 0.05; done
export FM_TEST_SEAM=1 FM_JEV_GUARD_BASE_URL="http://127.0.0.1:$(cat "$T/cport-$label")/v1/systemone"
hook() { printf '%s' "$1" | "$root/bin/fm-jev-guard-hook.sh" "$H" "$H/config" "$H/state" scout1 "$H/repo" "$H/data/scout1" firstmate FIRSTMATE_JEV_GUARD_V1 2>/dev/null; }
pre() { jq -cn --arg cwd "$H/repo" --arg tool "$1" --argjson input "$2" '{hook_event_name:"PreToolUse",cwd:$cwd,tool_name:$tool,tool_input:$input,tool_use_id:"x"}'; }
postread() { jq -cn --arg cwd "$H/repo" --arg p "$1" --rawfile body "$1" '{hook_event_name:"PostToolUse",cwd:$cwd,tool_name:"Read",tool_input:{file_path:$p},tool_response:{file:{content:$body}},tool_use_id:"y"}'; }
show() { # name ms out
  local o=$3; [ -n "$o" ] || o='(no output => allowed / no advisory)'
  printf '%s | %s | %s ms | %s\n' "$label" "$1" "$2" "$(printf '%s' "$o" | cut -c1-170)"; }
t() { local n=$1; shift; local s e out; s=$(python3 -c 'import time;print(int(time.time()*1000))'); out=$("$@"); e=$(python3 -c 'import time;print(int(time.time()*1000))'); show "$n" $((e-s)) "$out"; }
t "C1 PreToolUse Bash 'ls', judge answers after 15 s" hook "$(pre Bash '{"command":"ls # delayms15000"}')"
t "C2 PreToolUse Write own worktree file, judge answers after 15 s" hook "$(pre Write "$(jq -cn --arg p "$H/repo/review-request.md" '{file_path:$p,content:"review request delayms15000"}')")"
t "C3 PostToolUse Read own task data file, judge dead" hook "$(postread "$H/data/scout1/request.md")"
t "C4 PostToolUse Read modified tracked worktree file, judge dead" hook "$(postread "$H/repo/notes.md")"
t "C5 PostToolUse Read ANOTHER task's data file, judge dead" hook "$(postread "$H/data/other/secret.md")"
t "C6 PostToolUse Read UNTRACKED worktree file, judge dead" hook "$(postread "$H/repo/untracked.md")"
kill $fpid 2>/dev/null
