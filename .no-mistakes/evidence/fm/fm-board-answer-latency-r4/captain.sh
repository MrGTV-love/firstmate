#!/usr/bin/env bash
# The captain: open a Lavish review page in a headless Chrome, type an answer, click "Send to Agent".
# Usage: captain.sh <session-url> <answer text> [screenshot-path]
set -u
export CHROME_DEVTOOLS_AXI_SESSION=fmlab-captain
url=$1 text=$2 shot=${3-}
uid_of() { sed -n "s/.*uid=\([^ ]*\) $1.*/\1/p" | head -1; }
snap=$(chrome-devtools-axi open "$url" 2>&1)
show=$(printf '%s\n' "$snap" | uid_of 'button "Show anyway"')
[ -z "$show" ] || chrome-devtools-axi click "@$show" >/dev/null 2>&1 || true
snap=$(chrome-devtools-axi snapshot 2>&1)
box=$(printf '%s\n' "$snap" | uid_of 'textbox "Write a message for the agent')
[ -n "$box" ] || { echo "captain: message box not found"; printf '%s\n' "$snap" | head -30; exit 1; }
chrome-devtools-axi fill "@$box" "$text" >/dev/null 2>&1 || { echo "captain: fill failed"; exit 1; }
snap=$(chrome-devtools-axi snapshot 2>&1)
send=$(printf '%s\n' "$snap" | uid_of 'button "Send to Agent"')
[ -n "$send" ] || { echo "captain: Send to Agent not found"; exit 1; }
res=$(chrome-devtools-axi click "@$send" 2>&1) || { echo "captain: click failed: $res"; exit 1; }
now=$(date +%s)
echo "captain clicked 'Send to Agent' at $(date -r "$now" +%H:%M:%S) (epoch $now): $text"
if [ -n "$shot" ]; then sleep 3; chrome-devtools-axi screenshot "$shot" >/dev/null 2>&1 && echo "screenshot: $shot"; fi
