# <bin> <state> <phase>: real daemon classifier on the real volume (sourced library mode)
bin=$1 state=$2 phase=$3
export FM_HOME=${state%/state}
. "$bin/fm-supervise-daemon.sh"
log_size() { LC_ALL=C wc -c < "$1" | tr -d "[:space:]"; }
case "$phase" in
  prime)
    printf 'working: step\ndone: already delivered before reboot\n' > "$state/dtask.status"
    mark_status_seen "$state" dtask "$(log_size "$state/dtask.status")" "$(_fm_open_decisions_file_ident "$state/dtask.status")" || echo prime-failed
    echo "primed marker: $(cat "$(_seen_status_path "$state" dtask)" | cut -f3)" ;;
  check)
    for i in 1 2; do out=$(classify_signal "$state/dtask.status" "$state"); echo "classify pass $i -> ${out%%|*} | offset=$(status_seen_offset "$state" dtask) size=$(log_size "$state/dtask.status")"; done
    echo "marker now: $(cat "$(_seen_status_path "$state" dtask)" | cut -f3)" ;;
  grow)
    printf 'done: new result after reboot\n' >> "$state/dtask.status"
    out=$(classify_signal "$state/dtask.status" "$state"); echo "after growth -> ${out%%|*} | $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-160)" ;;
esac
