# fm_test_wait_until <seconds> <command> [args...]
# Polls until the command succeeds or the ceiling passes. For a result that a
# detached background job publishes, such as bin/fm-home-summary-refresh.sh
# --detach, where the foreground command under test returns before it exists.
main_fm_test_wait_until() {
  local limit=$1 ticks=0
  shift
  while ! "$@" >/dev/null 2>&1; do
    ticks=$((ticks + 1))
    [ "$ticks" -le $((limit * 10)) ] || return 1
    sleep 0.1
  done
}
