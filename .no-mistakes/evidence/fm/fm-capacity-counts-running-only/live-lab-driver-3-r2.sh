#!/usr/bin/env bash
# Live lab drive 3: refusal age-out alone. Real reconcile + fm-pr-check.sh,
# real gh (read-only, wrapped only to log calls), marked lab home.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5ZAE6YBSFRTH8GNJKYKXSX4
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5ZAE6YBSFRTH8GNJKYKXSX4
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2> "$EV/lab-env-3-r2.stderr")"
LAB=$FM_HOME; echo "lab=$LAB"
REAL_GH=$(command -v gh)
FAKEBIN=$LAB/data/fakebin; mkdir -p "$FAKEBIN" "$LAB/projects"
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$(date +%s)" "\$*" >> "$LAB/data/gh.calls"
exec "$REAL_GH" "\$@"
SH
chmod +x "$FAKEBIN/gh"; : > "$LAB/data/gh.calls"
Q=$LAB/projects/unpushed
git init -q -b main "$Q"; git -C "$Q" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m local
S=$LAB/state
printf 'kind=ship\nmode=direct-PR\nproject=%s\nworktree=%s\nbranch=main\n' "$Q" "$Q" > "$S/z-refused.meta"; chmod 600 "$S/z-refused.meta"
printf 'done: PR https://github.com/MrGTV-love/firstmate/pull/195\n' > "$S/z-refused.status"
pass() {
  local c0; c0=$(wc -l < "$LAB/data/gh.calls")
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" PATH="$FAKEBIN:$PATH" bash bin/fm-pr-ready-reconcile.sh; echo "(exit $?)"
  echo "[$1] gh pr-view calls: $(tail -n +"$((c0 + 1))" "$LAB/data/gh.calls" | grep -c 'pr view'); wakes: $(awk -F '\t' '$4 == "pr-ready-refused:z-refused"' "$S/.wake-queue" 2>/dev/null | wc -l | tr -d ' '); pr= lines: $(grep -c '^pr=' "$S/z-refused.meta")"
}
echo "=== pass 1 (first refusal)"; pass 1
echo "=== pass 2 (fresh refusal, 0s old)"; pass 2
touch -t "$(date -v-9M +%Y%m%d%H%M.%S)" "$S/.pr-ready-reconcile/z-refused.refused"
echo "=== pass 3 (refusal 9 minutes old)"; pass 3
touch -t "$(date -v-11M +%Y%m%d%H%M.%S)" "$S/.pr-ready-reconcile/z-refused.refused"
echo "=== pass 4 (refusal 11 minutes old)"; pass 4
echo "--- stored refusal reason"; cat "$S/.pr-ready-reconcile/z-refused.refused"
echo "--- wake lines containing guard banner text: $(awk -F '\t' '$4 == "pr-ready-refused:z-refused" {print $5}' "$S/.wake-queue" | grep -c -E 'WATCHER|WARNING|queued wakes')"
echo "--- wake text"; awk -F '\t' '$4 == "pr-ready-refused:z-refused" {print $5}' "$S/.wake-queue"
echo "=== pass 5 (cause repaired: head pushed to an origin; refusal aged 11 minutes)"
git init -q --bare "$LAB/data/origin.git"; git -C "$Q" remote add origin "$LAB/data/origin.git"; git -C "$Q" push -q origin main
touch -t "$(date -v-11M +%Y%m%d%H%M.%S)" "$S/.pr-ready-reconcile/z-refused.refused"
pass 5
echo "--- z-refused meta after pass 5"; cat "$S/z-refused.meta"; ls "$S"/z-refused.check.sh 2>/dev/null
echo "--- all wake text after pass 5"; awk -F '\t' '$4 == "pr-ready-refused:z-refused" {print $5}' "$S/.wake-queue"
tmux -L fm-lab kill-server 2>/dev/null || true
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/lab-env-3-r2.stderr" | head -1)
echo "teardown: $TEARDOWN"; eval "$TEARDOWN"
[ ! -e "$LAB" ] && echo "lab removed: $LAB"
