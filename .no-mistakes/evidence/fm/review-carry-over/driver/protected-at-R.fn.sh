test_zz_carried_pass_reads_protected_class_at_R() {
  local case_dir base2 h1 h2
  case_dir=$(auto_case "carry-protected")
  # The read at h1 is a PASS whose report answers Protected class: yes.
  auto_mode "$case_dir" "$AUTO_SONNET" protected-yes
  auto_step "$case_dir"; auto_wait "$case_dir"
  jq '.statusCheckRollup[0].status = "IN_PROGRESS"' "$case_dir/github-view.json" > "$case_dir/v" && mv "$case_dir/v" "$case_dir/github-view.json"
  auto_step "$case_dir"
  expect_code 1 "$(auto_reviews "$case_dir")" "carry-protected: the h1 PASS is recorded"
  git -C "$case_dir/wt" checkout -q main
  printf 'base moved\n' > "$case_dir/wt/base-moved.txt"
  git -C "$case_dir/wt" add base-moved.txt
  git -C "$case_dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -q -m 'base moves'
  base2=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin main
  printf '%s\n' "$base2" > "$case_dir/github-base"
  git -C "$case_dir/wt" checkout -q fm/fixture
  git -C "$case_dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' merge -q --no-edit main
  auto_publish_head "$case_dir" h2
  auto_step "$case_dir"; auto_wait "$case_dir"; auto_step "$case_dir"
  h1=$(auto_sha "$case_dir" h1 | cut -c1-12); h2=$(auto_sha "$case_dir" h2 | cut -c1-12)
  echo "  live check: verify at h2 -> $(NM_HOME="$NM_FIXTURE" FM_HOME="$case_dir" "$ROOT/bin/fm-review-record.py" verify --pr "$AUTO_URL" --head "$(auto_sha "$case_dir" h2)" --task task-x1 --base "$base2" --json 2>&1 | jq -c '{ok,basis,carried_from:(.carried_from // null)[0:12]}' 2>&1)"
  expect_code 1 "$(auto_calls "$case_dir")" "carry-protected: no new read for the carried head"
  expect_code 0 "$(auto_merges "$case_dir")" "carry-protected: a carried PASS whose read at R said protected must not merge"
  case $(auto_state "$case_dir") in "held: protected class yes"*) ;;
    *) fail "carry-protected: expected a protected-class hold at h2, got: $(auto_state "$case_dir")" ;; esac
  echo "  h1=$h1 h2=$h2"
  auto_dump "$case_dir" "carry-over protected-yes at R"
  pass "a carried PASS is judged by the protected-class answers recorded at the reviewed head R, so a yes at R holds the live head"
}
