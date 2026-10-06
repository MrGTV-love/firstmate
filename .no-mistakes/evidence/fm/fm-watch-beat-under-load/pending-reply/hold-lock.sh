set -e
. "$1/fm-wake-lib.sh"
fm_lock_acquire_wait "$2"
trap 'fm_lock_release "$2"' EXIT
printf 'ready\n'
IFS= read -r release
