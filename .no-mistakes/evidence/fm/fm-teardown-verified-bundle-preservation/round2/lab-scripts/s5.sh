bundle_ready() { local id=$1 src=$SCR/$1.bundle
  record_bundle "$id" "$src" >/dev/null && hold_call "$id" "$src" "$(cut -f3 "$FM_HOME/data/$id/preservation-bundles.tsv")" >/dev/null && echo "valid bundle recorded and call filed for $id"; }
echo "=== S5: unattended cleanup cannot use the bundle route (valid bundle + call filed each time) ==="
new_task t-s5 || exit 1; bundle_ready t-s5
echo "--- S5a: away mode (.afk in state) ---"
: > "$FM_HOME/state/.afk"; td t-s5; rm -f "$FM_HOME/state/.afk"; present "$FM_HOME/state/t-s5.meta"
echo "--- S5b: quiet contract (.afk-contract in state) ---"
: > "$FM_HOME/state/.afk-contract"; td t-s5; rm -f "$FM_HOME/state/.afk-contract"; present "$FM_HOME/state/t-s5.meta"
echo "--- S5c: idle reaper admission (FM_IDLE_REAP_ADMISSION=1) ---"
FM_IDLE_REAP_ADMISSION=1 td t-s5; present "$FM_HOME/state/t-s5.meta"
echo "--- S5d: supervision branch actor (FM_SUPERVISION_ACTOR=branch) ---"
FM_SUPERVISION_ACTOR=branch td t-s5; present "$FM_HOME/state/t-s5.meta"
echo "--- control: attended main actor, same bundle ---"
td t-s5; present "$FM_HOME/state/t-s5.meta"
echo
echo "=== S8: --force with NO bundle, BASE vs NEW code ==="
echo 'Fixture: the captain approved discarding this lab work.' > "$SCR/captain-words.txt"
for CODE in base new; do
  [ "$CODE" = base ] && TDBIN=$SCR/base/bin/fm-teardown.sh || TDBIN=$WT/bin/fm-teardown.sh
  id=t-s8-$CODE; new_task $id
  echo "--- $CODE: --force without --drop-file ---"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE "$TDBIN" $id --force 2>&1 | grep -v -e '^●' -e 'watcher still down' -e '^fm-gate-refuse' -e '^$' | cut -c1-240; echo "[exit ${PIPESTATUS[0]}]"
  echo "--- $CODE: --force --drop-file ---"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE "$TDBIN" $id --force --drop-file "$SCR/captain-words.txt" 2>&1 | grep -v -e '^●' -e 'watcher still down' -e '^fm-gate-refuse' -e '^$' | cut -c1-240; echo "[exit ${PIPESTATUS[0]}]"
  present "$FM_HOME/state/$id.meta"; echo "slot HEAD: $(git -C "$COPY" rev-parse HEAD)  main: $(git -C "$PROJ" rev-parse main)"
  tasks-axi show $id --file "$FM_HOME/data/backlog.md" | grep -E '^  (state|links|held):'
done
