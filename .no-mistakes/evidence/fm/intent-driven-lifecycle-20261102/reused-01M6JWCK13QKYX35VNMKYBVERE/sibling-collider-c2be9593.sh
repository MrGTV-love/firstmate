#!/usr/bin/env bash
# Owned check: do the backends reboot-recovery cases that keep literal fmlab-<x> session names
# reach the host-wide server-start absence proof? Disposable archive of HEAD with those literals
# renamed to an owned token; run each case with and without steady same-name colliders.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/624bc6fbd7a5/01M6JWCK13QKYX35VNMKYBVERE
cd "$WT" || exit 1; echo "head=$(git rev-parse --short HEAD)"
d=$(mktemp -d /tmp/fm-nm-sib.XXXXXX); mkdir "$d/fm" "$d/tmp"; git archive HEAD | tar -x -C "$d/fm"
tok="fmnmsib$$"; sed -i '' "s/fmlab-/$tok-/g" "$d/fm/tests/fm-control-relaunch-backends.test.sh"
echo "renamed literals: $(grep -c "$tok-" "$d/fm/tests/fm-control-relaunch-backends.test.sh") lines; remaining fmlab in backends: $(grep -c fmlab "$d/fm/tests/fm-control-relaunch-backends.test.sh")"
printf '#!/usr/bin/env bash\ntrap '"'"'kill "$c" 2>/dev/null; wait "$c"; exit 143'"'"' TERM\n/bin/sleep 600 & c=$!\nwait "$c"\n' > "$d/herdr"; chmod +x "$d/herdr"
cases="test_bounded_reboot_recovery_rotates_unmanaged_inspections_without_mutation test_bounded_reboot_recovery_notifies_each_unmanaged_identity_once test_bounded_reboot_recovery_advances_after_interrupted_inspection"
for c in $cases; do
  echo "== $c: no collider"; (cd "$d/fm" && TMPDIR="$d/tmp" bash tests/fm-control-relaunch-backends.test.sh "$c" > "$d/out" 2>&1; r=$?; grep -E '^(ok|not ok)|error' "$d/out"; echo "exit=$r")
done
pids=; for x in a b c h 1 2 3 4; do "$d/herdr" server --session "$tok-$x" & pids="$pids $!"; done; /bin/sleep 0.5
echo "colliders: $(ps -o pid=,command= -p "$(echo $pids | tr ' ' ,)" | wc -l | tr -d ' ') live, e.g. $(ps -o command= -p "${pids##* }")"
for c in $cases; do
  echo "== $c: steady colliders on every renamed session"; (cd "$d/fm" && TMPDIR="$d/tmp" bash tests/fm-control-relaunch-backends.test.sh "$c" > "$d/out" 2>&1; r=$?; grep -E '^(ok|not ok)|error' "$d/out"; echo "exit=$r")
done
for p in $pids; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; echo "collider $p wait=$?"; done
rm -rf "$d"; echo "left: $(ls -d "$d" 2>/dev/null || echo none)"
