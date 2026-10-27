#!/usr/bin/env bash
# Live lab drive 2: 200,000-line status log, eight-record cap with rotation,
# and ten-minute refusal age-out. Real fm-pr-ready-reconcile.sh / fm-pr-check.sh
# against real gh (read-only, wrapped only to log calls), in a marked lab home.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5ZAE6YBSFRTH8GNJKYKXSX4
EV=/Users/charlesabrooker/.no-mistakes/evidence/01M5ZAE6YBSFRTH8GNJKYKXSX4
cd "$WT"
eval "$(bin/fm-lab-home.sh env 2> "$EV/lab-env-2-r2.stderr")"
LAB=$FM_HOME; echo "lab=$LAB"
REPO=https://github.com/MrGTV-love/firstmate/pull
REAL_GH=$(command -v gh)
FAKEBIN=$LAB/data/fakebin; mkdir -p "$FAKEBIN" "$LAB/projects"
cat > "$FAKEBIN/gh" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "\$(date +%s)" "\$*" >> "$LAB/data/gh.calls"
exec "$REAL_GH" "\$@"
SH
chmod +x "$FAKEBIN/gh"; : > "$LAB/data/gh.calls"
P=$LAB/projects/proj
git init -q -b main "$P"; git -C "$P" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m init
git init -q --bare "$LAB/data/origin.git"; git -C "$P" remote add origin "$LAB/data/origin.git"; git -C "$P" push -q origin main
Q=$LAB/projects/unpushed
git init -q -b main "$Q"; git -C "$Q" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m local
S=$LAB/state
meta() { printf 'kind=ship\nmode=%s\nproject=%s\nworktree=%s\nbranch=main\n' "$2" "$3" "$3" > "$S/$1.meta"; chmod 600 "$S/$1.meta"; }
i=0
for n in 279 274 266 265 264 263 240 212 209 202; do
  i=$((i + 1)); id=$(printf 's%02d' "$i")
  meta "$id" no-mistakes "$P"
  printf 'done: PR %s/%s checks green\n' "$REPO" "$n" > "$S/$id.status"
done
# s05 gets a 200,000-line log: an old ready line for PR 201 at the top (outside
# the tail) and the real ready line for PR 264 at the end.
{ printf 'done: PR %s/201 checks green\n' "$REPO"
  yes 'working [at=1792479210]: still validating with /no-mistakes - padding line' | head -n 199998
  printf 'done: PR %s/264 checks green\n' "$REPO"; } > "$S/s05.status"
echo "s05.status lines: $(wc -l < "$S/s05.status") bytes: $(wc -c < "$S/s05.status")"
meta z-refused direct-PR "$Q"
printf 'done: PR %s/195\n' "$REPO" > "$S/z-refused.status"

pass() {  # <label>
  local t0 t1 c0
  c0=$(wc -l < "$LAB/data/gh.calls"); t0=$(date +%s)
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" PATH="$FAKEBIN:$PATH" bash bin/fm-pr-ready-reconcile.sh; echo "(exit $?)"
  t1=$(date +%s)
  echo "[$1] took $((t1 - t0))s; cursor=$(cat "$S/.pr-ready-reconcile/cursor"); gh pr-view calls this pass: $(tail -n +"$((c0 + 1))" "$LAB/data/gh.calls" | grep -c 'pr view')"
  printf '[%s] registered: ' "$1"; grep -l '^pr=' "$S"/*.meta | sed 's#.*/##; s/\.meta$//' | tr '\n' ' '; echo
}
echo "=== pass A (11 eligible, cap 8)"; pass A
echo "=== pass B (rotation)"; pass B
echo "--- s05 (200k-line log) meta"; cat "$S/s05.meta"
echo "=== pass C (fresh refusal: no forge call)"; pass C
echo "--- refusal wakes: $(awk -F '\t' '$4 == "pr-ready-refused:z-refused"' "$S/.wake-queue" | wc -l | tr -d ' ')"
touch -t "$(date -v-11M +%Y%m%d%H%M.%S)" "$S/.pr-ready-reconcile/z-refused.refused"
echo "=== pass D (refusal aged 11 minutes: retried at the forge)"; pass D
echo "--- refusal wakes after retry with same reason: $(awk -F '\t' '$4 == "pr-ready-refused:z-refused"' "$S/.wake-queue" | wc -l | tr -d ' ')"
echo "--- all gh calls"; cat "$LAB/data/gh.calls"
tmux -L fm-lab kill-server 2>/dev/null || true
TEARDOWN=$(sed -n 's/^fm-lab-home: teardown: //p' "$EV/lab-env-2-r2.stderr" | head -1)
echo "teardown: $TEARDOWN"; eval "$TEARDOWN"
[ ! -e "$LAB" ] && echo "lab removed: $LAB"
