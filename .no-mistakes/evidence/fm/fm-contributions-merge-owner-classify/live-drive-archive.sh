#!/usr/bin/env bash
# Extra owner-decision scenarios. Sources the helper functions of live-drive.sh.
set -u
ROOT=$1; SCRATCH=$2
eval "$(sed -n '/^NOW=/,/^echo "== firstmate root/p' "$(dirname "$0")/live-drive.sh" | sed '$d')"
mkdir -p "$SCRATCH"
echo "== firstmate root: $ROOT"
echo; echo "S13 captain verdict on task call-8; hold answered; row retired to the done archive (done_keep=1)"
h=$(home_new s13)
printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' 'archive = "data/done-archive.md"' 'done_keep = 1' > "$h/.tasks.toml"
hold "$h" hold call-8 --title "Captain call $URL" --reason 'choose contract' --repo sample
poll "$h"
run "$h" bash "$ROOT/bin/fm-contributions.sh" verdict call-8 "$URL" "$(cat "$h/forge/head")" "$URL#issuecomment-1" captain 'choose X' >/dev/null && echo "  recorded captain verdict for call-8"
show "$h" S13-before-answer
printf 'Choose X.\n' > "$h/ev.txt"; hold "$h" answer call-8 --decision-file "$h/ev.txt"
run "$h" bash "$ROOT/bin/fm-tasks-axi.sh" add filler 'Filler row' --kind captain --repo sample >/dev/null
run "$h" bash "$ROOT/bin/fm-tasks-axi.sh" done filler >/dev/null
echo "  call-8 in backlog.md: $(grep -c call-8 "$h/data/backlog.md")  in done-archive.md: $(grep -c call-8 "$h/data/done-archive.md")"
echo "  fm-captain-hold.sh archived-resolution call-8 -> $(run "$h" bash "$ROOT/bin/fm-captain-hold.sh" archived-resolution call-8; echo " (exit $?)")"
echo "  fm-captain-hold.sh archived-resolution filler -> $(run "$h" bash "$ROOT/bin/fm-captain-hold.sh" archived-resolution filler; echo "(exit $?)")"
show "$h" S13-archived

echo; echo "S14 legacy captain verdict (no at field) then hold answered --release (Main 789 Decision 1=A: stays owner call)"
h=$(home_new s14); poll "$h"
jq --arg head "$(cat "$h/forge/head")" --arg url "$URL" '.records[0].verdict={head:$head,source:($url+"#issuecomment-1"),actor:"captain",summary:"legacy choose X"}' "$h/data/delivery/contributions.json" > "$h/u.json" && mv "$h/u.json" "$h/data/delivery/contributions.json"
hold "$h" hold delivery --reason 'legacy choose X'
printf 'Choose X.\n' > "$h/ev.txt"; hold "$h" answer delivery --decision-file "$h/ev.txt" --release
show "$h" S14
