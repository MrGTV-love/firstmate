MR_HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
JQ_BIN=$(command -v jq)
add_glab_mock() {
  local case_dir=$1
  cat > "$case_dir/fakebin/glab" <<'SH'
#!/usr/bin/env bash
printf 'GITLAB_HOST=%s %s\n' "${GITLAB_HOST-<unset>}" "$*" >> "$FM_TEST_GLAB_LOG"
case_dir=$(dirname "$FM_TEST_GLAB_JSON")
case "${1:-} ${2:-}" in
  "mr view")
    [ ! -e "$case_dir/glab-view-fails" ] || exit 1
    if [ -e "$case_dir/glab-merge-called" ] && [ ! -e "$case_dir/glab-stays-open" ]; then
      cat "$case_dir/mr-post.json"
    else
      cat "$FM_TEST_GLAB_JSON"
    fi
    exit 0
    ;;
  "mr merge")
    [ ! -e "$case_dir/glab-merge-fails" ] || { echo "error: mr merge failed" >&2 ; exit 1 ; }
    : > "$case_dir/glab-merge-called"
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/glab"
  ln -sf "$JQ_BIN" "$case_dir/fakebin/jq"
}
write_mr_json() {
  local file=$1 kv key value
  local state=opened detail=mergeable conflicts=false discussions=true
  local head=$MR_HEAD pipeline_sha=$MR_HEAD pipeline_status=success pipeline=present
  local merge_when_pipeline_succeeds=false merge_after=null
  shift
  for kv in "$@"; do
    key=${kv%%=*}
    value=${kv#*=}
    case "$key" in
      state) state=$value ;;
      detail) detail=$value ;;
      conflicts) conflicts=$value ;;
      discussions) discussions=$value ;;
      head) head=$value ;;
      pipeline_sha) pipeline_sha=$value ;;
      pipeline_status) pipeline_status=$value ;;
      pipeline) pipeline=$value ;;
      merge_when_pipeline_succeeds) merge_when_pipeline_succeeds=$value ;;
      merge_after) merge_after=$value ;;
      *) fail "write_mr_json: unknown field '$key'" ;;
    esac
  done
  if [ "$pipeline" = present ]; then
    pipeline=$(printf '{"sha":"%s","status":"%s"}' "$pipeline_sha" "$pipeline_status")
  fi
  printf '{"iid":7,"state":"%s","detailed_merge_status":"%s","has_conflicts":%s,' \
    "$state" "$detail" "$conflicts" > "$file"
  printf '"blocking_discussions_resolved":%s,"sha":"%s","head_pipeline":%s,' \
    "$discussions" "$head" "$pipeline" >> "$file"
  printf '"merge_when_pipeline_succeeds":%s,"merge_after":%s}\n' \
    "$merge_when_pipeline_succeeds" "$merge_after" >> "$file"
}
