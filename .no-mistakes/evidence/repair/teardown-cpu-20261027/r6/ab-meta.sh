#!/bin/bash
# Usage: ab-meta.sh <label> <tree> <bash-dir-or-empty> <evidence-dir>
set -u
label=$1 tree=$2 bdir=$3 ev=$4
out=$ev/meta-$label; mkdir -p "$out"
run_tmp=$(mktemp -d /Users/charlesabrooker/tmp/nm-meta-r6-$label.XXXXXX); run_tmp=$(cd -P "$run_tmp" && pwd -P)
P=$PATH; [ -n "$bdir" ] && P="$bdir:$PATH"
{ echo "tree=$tree run_tmp=$run_tmp"; PATH=$P command -v bash; PATH=$P bash --version | head -1; sed -n '1697p;1701p' "$tree/bin/fm-teardown.sh"; } > "$out/inputs.txt"
TMPDIR=$run_tmp PATH=$P bash "$ev/meta-diff-driver.sh" "$tree" > "$out/results.txt" 2> "$out/driver-stderr.txt"
echo "driver_exit=$?" > "$out/receipt.txt"
sleep 10
{ echo "--- owned tmp after 10s:"; find "$run_tmp" | sort
  if [ "$(find "$run_tmp" -mindepth 1 | wc -l | tr -d ' ')" = 0 ]; then rmdir "$run_tmp" && echo owned_tmp_removed=empty_rmdir_ok; else echo "owned_tmp_residue=retained"; fi
} >> "$out/receipt.txt" 2>&1
cat "$out/receipt.txt"
