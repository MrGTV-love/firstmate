#!/bin/bash
# Usage: orca-run.sh <A|B> <evidence-dir>
set -u
T=$1 EV=$2
S=/Users/charlesabrooker/.no-mistakes/worktrees/e2f2c2589455/01M60X7EHPFP3WC1T7VVP0W6VM/.nm-test-scratch; B5=$S/bash-build/inst/bin
out=$EV/orca-$T; mkdir -p "$out"
t=$(mktemp -d /Users/charlesabrooker/tmp/nm-orca-$T.XXXXXX) || exit 1
case "$t" in /Users/charlesabrooker/tmp/nm-orca-$T.??????) ;; *) echo "bad tmp $t"; exit 1 ;; esac
( cd "$S/$T" || exit 1
  TMPDIR=$t PATH=$B5:$PATH bash tests/fm-teardown-endpoint-safety.test.sh test_absent_orca_descendant_preserves_backend_copy test_orca_close_failure_refuses_even_under_force > "$out/endpoint.out" 2> "$out/endpoint.err"; echo "endpoint_exit=$?" > "$out/receipt.txt"
  TMPDIR=$t PATH=$B5:$PATH bash tests/fm-teardown-cleanup.test.sh test_forced_orca_children_clean_docker_before_worktree_removal > "$out/cleanup.out" 2> "$out/cleanup.err"; echo "cleanup_exit=$?" >> "$out/receipt.txt" )
sleep 10
{ echo "--- owned tmp after 10s:"; find "$t" | sort
  if [ "$(find "$t" -mindepth 1 | wc -l | tr -d ' ')" = 0 ]; then rmdir -- "$t" && echo owned_tmp_removed=empty_rmdir_ok; else echo owned_tmp_residue=retained; fi; } >> "$out/receipt.txt"
echo "== $T"; cat "$out/receipt.txt"; grep -hE "^(ok|not ok|FAIL)" "$out/endpoint.out" "$out/cleanup.out"; tail -2 "$out/endpoint.err" "$out/cleanup.err"
