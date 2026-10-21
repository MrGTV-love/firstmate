test_gate_real_kernel_cwd() {
  # Real owned process, real kernel cwd read by the real lsof; Herdr itself stays scripted.
  prepare_omp_adoption real-cwd
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID out rc=0 pid
  rm -f "$dir/fake/adoption-cwd"
  printf '#!/usr/bin/env bash\nexec /usr/sbin/lsof "$@"\n' > "$dir/fakebin/lsof"
  chmod +x "$dir/fakebin/lsof"
  ( cd "$dir/wt/subdirectory" && exec /bin/sleep 300 ) &
  pid=$!
  trap 'kill $pid 2>/dev/null' RETURN
  sleep 0.5
  printf '%s' "$pid" > "$dir/fake/recovery-pid"
  printf '%s' "$pid" > "$dir/fake/holder-pid"
  echo "GATE real pid=$pid cwd=$(/usr/sbin/lsof -w -a -p $pid -d cwd -Fn | tr '\n' ' ')"
  out=$(run_continuation_control "$dir" "$id" adopt) || rc=$?
  echo "GATE real-cwd adopt rc=$rc: $out"
  echo "GATE record: $(cat "$dir/home/state/$id.omp-session.json")"
  # Move the process out of the worktree: real kernel cwd now outside -> reader must refuse.
  kill $pid; wait $pid 2>/dev/null
  ( cd "$dir" && exec /bin/sleep 300 ) &
  pid=$!
  sleep 0.5
  printf '%s' "$pid" > "$dir/fake/recovery-pid"
  printf '%s' "$pid" > "$dir/fake/holder-pid"
  rc=0
  out=$(run_continuation_control "$dir" "$id" adopt) || rc=$?
  echo "GATE outside-worktree-real-cwd adopt rc=$rc: $out"
  kill $pid 2>/dev/null
}

test_gate_idempotent_and_harness_scope() {
  prepare_omp_adoption idem
  local dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID out rc=0 rec1 rec2
  out=$(run_continuation_control "$dir" "$id" adopt) || rc=$?
  echo "GATE first adopt rc=$rc: $out"
  rec1=$(cat "$dir/home/state/$id.omp-session.json")
  rc=0
  out=$(run_continuation_control "$dir" "$id" adopt) || rc=$?
  echo "GATE second adopt rc=$rc: $out"
  rec2=$(cat "$dir/home/state/$id.omp-session.json")
  [ "$rec1" = "$rec2" ] && echo "GATE idempotent: record byte-identical" || echo "GATE NOT idempotent"
  # Different harness is out of scope for adopt.
  prepare_omp_adoption claude-scope
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  while IFS= read -r line; do
    case "$line" in harness=*) printf 'harness=claude\n' ;; *) printf '%s\n' "$line" ;; esac
  done < "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.new"
  mv "$dir/home/state/$id.meta.new" "$dir/home/state/$id.meta"
  before=$(cat "$dir/home/state/$id.omp-session.json")
  rc=0
  out=$(run_continuation_control "$dir" "$id" adopt) || rc=$?
  echo "GATE claude-harness adopt rc=$rc: $out"
  [ "$before" = "$(cat "$dir/home/state/$id.omp-session.json")" ] && echo "GATE claude record unchanged"
  # Missing record is refused, not fabricated.
  prepare_omp_adoption no-record
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  rm -f "$dir/home/state/$id.omp-session.json"
  rc=0
  out=$(run_continuation_control "$dir" "$id" adopt) || rc=$?
  echo "GATE no-record adopt rc=$rc: $out"
  [ ! -e "$dir/home/state/$id.omp-session.json" ] && echo "GATE no record fabricated"
  # Empty generation in meta is refused.
  prepare_omp_adoption empty-gen
  dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID
  grep -v '^spawn_gen=' "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.new"; mv "$dir/home/state/$id.meta.new" "$dir/home/state/$id.meta"
  rc=0
  out=$(run_continuation_control "$dir" "$id" adopt) || rc=$?
  echo "GATE missing-meta-gen adopt rc=$rc: $out"
}

