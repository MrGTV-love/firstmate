fm_test_wait_until() {
  local limit=$1 ticks=0
  shift
  while ! "$@" >/dev/null 2>&1; do
    ticks=$((ticks + 1))
    [ "$ticks" -le $((limit * 10)) ] || return 1
    sleep 0.1
  done
}
