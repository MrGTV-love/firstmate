. "$(dirname "$0")/common.sh"
H=$W/hook-state
echo "=== POSITIVE: a declared successor of a live predecessor"
echo "markers before: $(markers $H)"
brief nmt-succ-pos
spawn nmt-succ-pos --successor-of nmt-pred-a; rc=$?
echo "spawn exit=$rc"
echo "--- meta"; meta nmt-succ-pos
echo "markers after: $(markers $H)"; marker_show $H
carry nmt-succ-pos nmt-pred-a && r13 nmt-succ-pos "$H"
echo
echo "=== NEGATIVE CONTROL: the same spawn without the flag"
pred nmt-pred-b >/dev/null 2>&1 || echo "pred-b spawn failed"
echo "predecessor nmt-pred-b: $(sed -n 's/^branch=//p' "$L/state/nmt-pred-b.meta")"
m0=$(markers $H)
brief nmt-succ-neg
spawn nmt-succ-neg; rc=$?
echo "spawn exit=$rc"
echo "--- meta"; meta nmt-succ-neg
echo "markers before=$m0 after=$(markers $H)"
carry nmt-succ-neg nmt-pred-b && r13 nmt-succ-neg "$H"
echo
echo "=== ADVERSARIAL: an existing marker for nmt-pred-a does not cover a different successor carrying nmt-pred-a"
brief nmt-succ-other
spawn nmt-succ-other >/dev/null 2>&1; echo "spawn exit=$?"
carry nmt-succ-other nmt-pred-a && r13 nmt-succ-other "$H"
