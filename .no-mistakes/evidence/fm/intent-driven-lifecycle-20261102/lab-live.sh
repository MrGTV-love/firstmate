#!/usr/bin/env bash
# Live lab: real fm-brief + fm-spawn (tmux, treehouse, claude) in a disposable marked home.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6HK714J4FATY5VQP1RB486C
E=/Users/charlesabrooker/.no-mistakes/evidence/01M6HK714J4FATY5VQP1RB486C/lab-live
mkdir -p "$E"
cd "$WT" || exit 1
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX TMUX_PANE
# Supported create + tmux-dir path so owner_pid is this long-lived shell, not a short-lived env process.
dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
bin/fm-lab-home.sh create "$dir" > "$E/lab-path.txt" || { echo "lab create failed"; exit 1; }
LAB=$(cat "$E/lab-path.txt")
TMUX_TMPDIR=$(bin/fm-lab-home.sh tmux-dir "$LAB") || { echo "tmux-dir failed"; exit 1; }
export FM_HOME="$LAB" TMUX_TMPDIR
echo "lab=$LAB socket=$TMUX_TMPDIR"
owner=$(sed -n 's/^owner_pid=//p' "$LAB/.fm-lab-home")
echo "owner_pid=$owner self=$$"
[ "$owner" = "$$" ] && kill -0 "$owner" 2>/dev/null || { echo "lab owner is not this live shell"; rm -rf "$LAB"; exit 1; }
[ -f "$FM_HOME/.fm-lab-home" ] && case "$TMUX_TMPDIR" in /tmp/fml.*) ;; *) echo "unsafe socket"; exit 1;; esac || { echo "unsafe lab"; exit 1; }
SOCK="$TMUX_TMPDIR/tmux-$(id -u)/default"
TH_BEFORE=$(ls -1A "$HOME/.treehouse" 2>/dev/null | sort); TMP_BEFORE=$(ls -1A /tmp | grep -E '^fm' | sort)
export FM_BACKEND=tmux DISABLE_AUTOUPDATER=1 TREEHOUSE_ROOT="$LAB/treehouse" TREEHOUSE_NO_UPDATE_CHECK=1
export CLAUDE_CONFIG_DIR="$LAB/claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR" "$TREEHOUSE_ROOT"; printf '{}\n' > "$CLAUDE_CONFIG_DIR/.claude.json"
CUE='use the existing Intent-to-test alignment criteria in the shared review rubric below during implementation and verification'
cleanup() {
  echo "== teardown"
  tmux -S "$SOCK" kill-server 2>/dev/null || true
  sleep 1
  "$WT/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB"
  for id in labitt-test labitt-docs labitt-nm; do rm -rf "/tmp/fm-$id" 2>/dev/null; done
  ls -d "$LAB" "$TMUX_TMPDIR" 2>&1 | sed 's/^/teardown-check: /'
  echo "treehouse-new: $(comm -13 <(printf '%s\n' "$TH_BEFORE") <(ls -1A "$HOME/.treehouse" 2>/dev/null | sort) | tr '\n' ' ')"
  echo "tmp-fm-new: $(comm -13 <(printf '%s\n' "$TMP_BEFORE") <(ls -1A /tmp | grep -E '^fm' | sort) | tr '\n' ' ')"
}
trap cleanup EXIT

# Disposable project with a lab-private origin.
seed="$LAB/seed"; origin="$LAB/notes-origin.git"
mkdir -p "$seed/notes" "$seed/tests"
printf 'NOTES = []\n\ndef add_note(text):\n    NOTES.append(text)\n' > "$seed/notes/__init__.py"
printf 'import unittest\n' > "$seed/tests/test_notes.py"
printf '# notes\n' > "$seed/README.md"
git -C "$seed" init -q -b main && git -C "$seed" add -A && git -C "$seed" -c user.name=lab -c user.email=lab@example.invalid commit -q -m seed
git clone -q --bare "$seed" "$origin"; rm -rf "$seed"
git clone -q "$origin" "$LAB/projects/notes"
printf '# Projects\n\n- notes [local-only +yolo] - tiny lab notes library\n' > "$LAB/data/projects.md"
tmux new-session -d -s main -c "$LAB" || { echo "tmux server failed"; exit 1; }

fill() {  # <brief> <task> <spec> <mandatory>
  TASK_TEXT=$2 SPEC_TEXT=$3 MAND=$4 python3 - "$1" <<'PY'
import os, sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
t = t.replace("{TASK}", os.environ["TASK_TEXT"], 1).replace("{FIRSTMATE_SPEC}", os.environ["SPEC_TEXT"], 1)
t = t.replace("\n### Out of scope\n", "\n### Out of scope\n- Any change outside the notes package.\n", 1)
for k, v in {"{DOD_CAPABILITY}": "The notes package behaves as the task text says.",
             "{DOD_MANDATORY_ITEMS}": os.environ["MAND"],
             "{DOD_SUPPORTING_ITEMS}": "None.",
             "{DOD_HARD_GATES}": "Do not change files outside the notes repository.",
             "{DOD_HONESTY_RULE}": "Report an unrun test as unrun."}.items():
    t = t.replace(k, v, 1)
open(p, "w", encoding="utf-8").write(t)
PY
}

spawn_one() {  # <id> <task> <spec> <mandatory>
  local id=$1
  echo "== fm-brief $id"; bin/fm-brief.sh "$id" notes --mode local-only 2>&1 | tail -3
  fill "$LAB/data/$id/brief.md" "$2" "$3" "$4"
  bin/fm-tasks-axi.sh add "$id" "lab $id" --kind ship --repo notes >/dev/null 2>&1
  echo "== fm-spawn $id"
  bin/fm-spawn.sh "$id" "$LAB/projects/notes" --mode local-only --yolo on --harness claude --model sonnet --effort low > "$E/$id-spawn.out" 2>&1
  echo "spawn exit=$?"; tail -8 "$E/$id-spawn.out"
}

spawn_one labitt-test \
  "Add a count_notes() function to notes/__init__.py that returns how many notes are stored, plus a unit test, and a validator that rejects empty note text." \
  "Implement count_notes() and reject empty text in add_note() with ValueError; add tests in tests/test_notes.py and run python3 -m unittest discover -s tests." \
  "M1. Source: the task text. Expected: count_notes() returns the stored note count and add_note('') raises ValueError. Verify: python3 -m unittest discover -s tests passes. Edge/negative: an empty store returns 0. Evidence place: tests/test_notes.py and the unittest output. Authority: gate."
spawn_one labitt-docs \
  "Fix the README title so it reads 'Notes library' instead of 'notes'." \
  "Change only the first line of README.md and commit." \
  "M1. Source: the task text. Expected: README.md first line is '# Notes library'. Verify: head -1 README.md prints '# Notes library'. Edge/negative: no other file changes. Evidence place: git diff of README.md. Authority: gate."

sleep 25
for id in labitt-test labitt-docs; do
  lb="$LAB/data/$id/launch-brief.md"
  if [ -f "$lb" ]; then
    cp "$lb" "$E/$id-launch-brief.md"
    echo "$id cue-count=$(grep -cF "$CUE" "$lb") rubric-section=$(grep -c '^## Intent-to-test alignment$' "$lb") unverified-in-section=$(awk '/^## Intent-to-test alignment$/{f=1;next} /^## /{f=0} f' "$lb" | grep -c unverified)"
    awk -v cue="$CUE" '/^# Current worker role contract$/{r=NR} index($0,cue){c=NR} /^## Intent-to-test alignment$/{s=NR} /^## Review outcomes$/{o=NR} END{printf "order: role=%d cue=%d section=%d outcomes=%d\n", r,c,s,o}' "$lb"
  else echo "$id: no launch-brief"; ls "$LAB/data/$id"; fi
  win=$(tmux list-windows -a -F '#{session_name}:#{window_name}' | grep -F "$id" | head -1)
  echo "$id window=$win"
  [ -z "$win" ] || tmux capture-pane -p -t "$win" > "$E/$id-pane.txt"
  [ -z "$win" ] || { echo "--- $id pane (last 25 lines)"; grep -v '^$' "$E/$id-pane.txt" | tail -25; }
  grep -E '^(worktree|harness|branch|launch)=' "$LAB/state/$id.meta" 2>/dev/null | sed "s/^/$id meta: /"
done
ps -axo pid,command | grep -F "$LAB" | grep -i claude | grep -v grep | cut -c1-400 | sed 's/^/proc: /' | head -5

echo "== relaunch labitt-test via fm-control"
bin/fm-control.sh labitt-test relaunch --note "lab relaunch check" > "$E/labitt-test-relaunch.out" 2>&1; echo "relaunch exit=$?"; tail -6 "$E/labitt-test-relaunch.out"
sleep 10
lb="$LAB/data/labitt-test/launch-brief.md"
[ -f "$lb" ] && { cp "$lb" "$E/labitt-test-relaunch-launch-brief.md"; echo "after relaunch cue-count=$(grep -cF "$CUE" "$lb") note=$(grep -c 'lab relaunch check' "$lb")"; }

echo "== verification plan for a no-mistakes brief"
bin/fm-brief.sh labitt-nm notes --mode no-mistakes > /dev/null 2>&1; echo "brief exit=$?"
fill "$LAB/data/labitt-nm/brief.md" "Add a validator that rejects empty note text in add_note()." "Raise ValueError for empty text and add a unit test." \
  "M1. Source: the task text. Expected: add_note('') raises ValueError. Verify: python3 -m unittest discover -s tests passes. Edge/negative: non-empty text is still stored. Evidence place: tests/test_notes.py and the unittest output. Authority: gate."
bash bin/fm-dod-lib.sh --verification-plan "$LAB/data/labitt-nm/brief.md" > "$E/labitt-nm-verification-plan.md" 2> "$E/labitt-nm-verification-plan.err"; echo "plan exit=$?"
echo "plan: section=$(grep -c '^## Intent-to-test alignment$' "$E/labitt-nm-verification-plan.md") unverified-in-section=$(awk '/^## Intent-to-test alignment$/{f=1;next} /^## /{f=0} f' "$E/labitt-nm-verification-plan.md" | grep -c unverified) pending=$(grep -c 'pending' "$E/labitt-nm-verification-plan.md")"
