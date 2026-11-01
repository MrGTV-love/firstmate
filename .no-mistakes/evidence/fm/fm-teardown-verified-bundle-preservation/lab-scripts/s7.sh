PRIMARY=$FM_HOME
SMH=$("$WT/bin/fm-lab-home.sh" create "$SCR/sm-home") || exit 1
mkdir -p "$SMH/state" "$SMH/data"; printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$SMH/data/backlog.md"
echo "=== S7 setup: a real bundle-route child teardown inside the secondmate home $SMH ==="
(
  export FM_HOME=$SMH
  new_task c-bundled || exit 1
  record_bundle c-bundled "$SCR/c-bundled.bundle" >/dev/null
  hold_call c-bundled "$SCR/c-bundled.bundle" "$(cut -f3 "$SMH/data/c-bundled/preservation-bundles.tsv")" >/dev/null
  td c-bundled | grep -e 'preserved unlanded' -e 'complete (' -e '^\[exit' | head -3 | cut -c1-250
  rm -f "$SCR/c-bundled.bundle"   # original source deleted after admission: the stored copy is the only copy
  new_task c-live || exit 1
  echo "live child c-live: $COPY"
  echo "$COPY" > "$SCR/c-live.path"
)
STORED=$(ls "$SMH"/data/c-bundled/preserved-bundles/*.bundle); echo "stored bundle in the home: $STORED"
CLIVE=$(cat "$SCR/c-live.path")
echo; echo "=== S7: retire the secondmate (task t-s7 in the primary lab home) ==="
new_task t-s7 || exit 1
sed -i '' -e 's/^kind=ship/kind=secondmate/' "$FM_HOME/state/t-s7.meta"; echo "home=$SMH" >> "$FM_HOME/state/t-s7.meta"
printf '%s\n' t-s7 > "$SMH/.fm-secondmate-home"
echo 'Fixture: the captain approved retiring this lab secondmate.' > "$SCR/captain-words.txt"
echo "--- S7a: ordinary retirement ---"; td t-s7
present "$STORED"; present "$SMH/.fm-secondmate-home"; present "$FM_HOME/state/t-s7.meta"
echo "--- S7b: forced retirement (--force --drop-file) ---"; td t-s7 --force --drop-file "$SCR/captain-words.txt"
present "$STORED"; present "$SMH/.fm-secondmate-home"; present "$SMH/state/c-live.meta"; present "$CLIVE/.git"; present "$FM_HOME/state/t-s7.meta"
echo "--- S7c: move the stored bundle to a durable place outside the home, then forced retirement ---"
mkdir -p "$SCR/durable"; mv "$STORED" "$SCR/durable/"; MOVED=$SCR/durable/${STORED##*/}
td t-s7 --force --drop-file "$SCR/captain-words.txt" | grep -v '^🌳' | tail -6 | cut -c1-250
present "$SMH"; present "$MOVED"; present "$FM_HOME/state/t-s7.meta"
R=$SCR/restore-s7; rm -rf "$R"; git init -q "$R"
show git -C "$R" bundle unbundle "$MOVED"
