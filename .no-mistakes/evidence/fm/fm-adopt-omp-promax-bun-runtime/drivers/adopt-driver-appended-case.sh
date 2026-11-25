test_live_real_bun_recorded_writer() {
  local shape dir id record out rc scratch rpid before after
  scratch=$(mktemp -d /tmp/fm-relbun-adopt.XXXXXX); scratch=$(cd "$scratch" && pwd -P); mkdir -p "$scratch/src"
  printf '{"name":"scratch","scripts":{"dev":"sleep 30"}}\n' > "$scratch/package.json"
  echo 'setTimeout(()=>{},30000);' > "$scratch/src/cli.ts"
  for shape in bun-run-dev relative-src-cli; do
    prepare_bun_adoption "live-$shape"
    dir=$HERDR_CASE_DIR id=$HERDR_CASE_ID record="$HERDR_CASE_DIR/home/state/$HERDR_CASE_ID.omp-session.json"
    case "$shape" in
      bun-run-dev) ( cd "$scratch" && exec bun run dev </dev/null >/dev/null 2>&1 ) & rpid=$! ;;
      relative-src-cli) ( cd "$scratch" && exec bun src/cli.ts </dev/null >/dev/null 2>&1 ) & rpid=$! ;;
    esac
    sleep 2
    echo "# case $shape: recorded pid $rpid is a REAL bun process: $(/bin/ps -p "$rpid" -o args=)"
    jq --argjson pid "$rpid" '.pid=$pid' "$record" > "$record.new" && mv "$record.new" "$record"
    before=$(jq -c . "$record"); echo "#   record before: $before"
    rc=0; out=$(run_continuation_control "$dir" "$id" adopt 2>&1) || rc=$?
    after=$(jq -c . "$record")
    echo "#   adopt exit=$rc"; printf '%s\n' "$out" | sed 's/^/#   | /'
    echo "#   record after:  $after"
    case "$shape" in
      bun-run-dev) [ "$rc" -eq 0 ] || fail "a real bun run dev recorded pid must not block adoption: $out"
        assert_contains "$out" "adopted: $id" "adoption over an unrelated real bun reports its task"
        [ "$(jq -r .pid "$record")" = "$BUN_PID" ] || fail "record must name the adopted live pid" ;;
      relative-src-cli) [ "$rc" -ne 0 ] || fail "a relative src/cli.ts recorded pid must keep the record: $out"
        assert_contains "$out" "$rpid is a live omp process" "refusal names the may-own pid"
        assert_contains "$out" "adopt note: a live Bun process counts as a possible omp writer" "refusal carries the note"
        assert_equals "$before" "$after" "record unchanged" ;;
    esac
    kill "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null
    bun_stop_all
  done
  rm -rf "$scratch"
  pass "live real bun: a recorded bun run dev pid lets adopt repair the record; a recorded relative src/cli.ts pid keeps it, with the note"
}
control_relaunch_test_cases+=(test_live_real_bun_recorded_writer)
control_relaunch_run "$@"
