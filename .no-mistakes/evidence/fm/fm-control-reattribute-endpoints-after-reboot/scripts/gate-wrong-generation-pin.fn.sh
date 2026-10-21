test_gate_wrong_generation_pin() {
  prepare_omp_adoption wrong-pin
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID out rc=0
  # The live foreground process carries a POSITIVE pin for a different launch generation.
  printf other > "$dir/fake/recovery-spawn-gen"
  out=$(run_control "$dir" "$id" interrupt) || rc=$?
  echo "GATE pre-adopt interrupt rc=$rc: $out"
  rc=0
  out=$(run_continuation_control "$dir" "$id" adopt) || rc=$?
  echo "GATE adopt rc=$rc: $out"
  echo "GATE record: $(cat "$dir/home/state/$id.omp-session.json")"
  rc=0
  out=$(FM_CONTROL_SETTLE_WAIT=.05 run_control "$dir" "$id" interrupt) || rc=$?
  echo "GATE post-adopt interrupt rc=$rc: $out"
  echo "GATE sends: $(grep -c 'send-' "$dir/fake/herdr-log")"
}

