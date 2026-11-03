#!/usr/bin/env bash
# Print the identity of this home's backlog, so a caller can prove that two homes
# are different backlogs without trusting host names or addresses.
#
# Usage: fm-backlog-identity.sh
#
# Reads FM_HOME (and FM_DATA_OVERRIDE when set) like every home command. Prints
# three lines and changes nothing:
#   machine=<id>    this machine's own id (hardware UUID, machine-id, or hostname)
#   data=<path>     the data directory's canonical path
#   dev_ino=<d:i>   the data directory's device and inode numbers
# Two backlogs are the same one only when all three lines are equal. A caller
# reads this through bin/fm-on.sh for a remote home and runs it directly for the
# local one, then compares the output.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

[ -d "$DATA" ] || { printf 'error: no data directory at %s\n' "$DATA" >&2; exit 1; }

machine=
if [ -r /etc/machine-id ]; then
  machine=$(tr -d '[:space:]' < /etc/machine-id)
elif [ -r /var/lib/dbus/machine-id ]; then
  machine=$(tr -d '[:space:]' < /var/lib/dbus/machine-id)
elif command -v ioreg >/dev/null 2>&1; then
  machine=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ { print $4; exit }')
fi
[ -n "$machine" ] || machine=$(hostname 2>/dev/null) || machine=
[ -n "$machine" ] || { printf 'error: cannot tell which machine this is\n' >&2; exit 1; }

data_path=$(cd "$DATA" && pwd -P)
dev_ino=$(python3 -c 'import os, sys; s = os.stat(sys.argv[1]); print("%d:%d" % (s.st_dev, s.st_ino))' "$data_path") \
  || { printf 'error: cannot read the data directory identity\n' >&2; exit 1; }

printf 'machine=%s\ndata=%s\ndev_ino=%s\n' "$machine" "$data_path" "$dev_ino"
