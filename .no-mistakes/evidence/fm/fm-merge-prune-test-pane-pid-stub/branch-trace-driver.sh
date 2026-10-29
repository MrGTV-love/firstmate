#!/usr/bin/env bash
# Drives fm_mp_pane_agent_gone directly, the way the test's supplemental assertion does, with bash -x.
lab=$1; root=$2
mkdir -p "$lab/tbin"; real_ps=$(command -v ps)
bash -c 'sleep 300 & wait' & pane=$!; sleep 0.5  # a shell pane with a live child, like the test's pane agent
cat > "$lab/tbin/ps" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"-axo pid=,ppid="*) $real_ps -axo pid=,ppid= | awk -v p=$pane '\$1 == p'; exit 1 ;;
  *) exec $real_ps "\$@" ;;
esac
EOF
chmod +x "$lab/tbin/ps"
run() { # label stub-body pid lib-dir
  echo "=== $1  (pane pid argument: '${3}')"
  PATH="$lab/tbin:$PATH" bash -c '. "$1/fm-merge-prune-lib.sh"; test_pane_pid=$2; eval "$3"; set -x; fm_mp_pane_agent_gone /nonexistent.meta; rc=$?; set +x; echo "fm_mp_pane_agent_gone rc=$rc ($( [ $rc = 0 ] && echo AGENT GONE || echo not proven gone))"' _ "$4" "$3" "$2" 2>&1 | grep -v '^++* *\(local\|FM_MP_TREE\)' | grep -v '^    \|^      \|^        \|^    }'
  echo
}
FIXED='fm_mp_pane_pid() { printf %s "$test_pane_pid"; }'
OLD='fm_mp_pane_pid() { printf %s "$2"; }'
run "fixed stub, real lib" "$FIXED" "$pane" "$root/bin"
run "old stub (called with one arg), real lib" "$OLD" "$pane" "$root/bin"
run "fixed stub, lib with ps status check removed" "$FIXED" "$pane" "$lab/iso-fixed-mut/bin"
run "old stub, lib with ps status check removed" "$OLD" "$pane" "$lab/iso-fixed-mut/bin"
run "ADVERSARIAL: fixed stub with an empty pane pid, real lib" "$FIXED" "" "$root/bin"
run "ADVERSARIAL: fixed stub with an empty pane pid, lib with ps status check removed" "$FIXED" "" "$lab/iso-fixed-mut/bin"
pkill -P $pane; kill $pane
