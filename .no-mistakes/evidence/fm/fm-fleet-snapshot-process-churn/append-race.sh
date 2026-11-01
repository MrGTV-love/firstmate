#!/usr/bin/env bash
# append-race.sh <root>: real --secondmate-home-summary runs while a writer keeps
# appending new decisions to the live status log. Every run must stay valid and
# count M open decisions (counts.decisions_open; the list shows the first 20,
# k1..), M never shrinking; after the writer
# stops, one more run must show every written decision (no stale cached answer).
set -u
ROOT=$1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-race.XXXXXX"); trap 'kill $wp 2>/dev/null; rm -rf "$WORK"' EXIT
home=$WORK/home fb=$WORK/fakebin
mkdir -p "$home/state" "$home/data" "$home/projects/child" "$home/config" "$fb"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/no-mistakes"
cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) sed -n 's/^window=[^:]*://p' "${FM_HOME:?}"/state/*.meta ;;
  display-message) case "$*" in *pane_current_command*) printf 'claude\n' ;; *) printf '%%1\n' ;; esac ;;
  capture-pane) printf 'all quiet\n> \n' ;;
esac
SH
chmod +x "$fb/no-mistakes" "$fb/tmux"
printf '## In flight\n- [ ] child - Child (repo: alpha) (kind: scout) (since 2026-10-01)\n' > "$home/data/backlog.md"
printf '%s\n' window=firstmate:fm-child "worktree=$home/projects/child" project=alpha harness=claude kind=scout mode=scout spawn_gen=g1 > "$home/state/child.meta"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" child)
"$ROOT/bin/fm-busy-event.sh" apply "$home/state" child idle --gen "$gen" --source claude-hook --event stop
printf 'needs-decision [key=k1] [at=1791450000]: q1\n' > "$home/state/child.status"
( i=2; while [ ! -e "$WORK/stop" ]; do printf 'needs-decision [key=k%d] [at=1791450000]: q%d\n' "$i" "$i" >> "$home/state/child.status"; i=$((i+1)); sleep 0.05; done ) &
wp=$!
prev=0 bad=0
for r in $(seq 1 8); do
  out=$(PATH="$fb:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary); rc=$?
  m=$(printf '%s' "$out" | jq -r '[.decisions_open[].key] as $k | .counts.decisions_open as $n | if (.valid and $n>0 and $k == [range(1; ([$n,20]|min)+1) | "k\(.)"]) then $n else "BAD" end')
  echo "run $r rc=$rc valid=$(printf '%s' "$out" | jq -c .valid) open_decisions=$m live_lines=$(wc -l < "$home/state/child.status" | tr -d ' ')"
  if [ "$rc" != 0 ] || [ "$m" = BAD ] || [ "$m" -lt "$prev" ]; then bad=1; else prev=$m; fi
done
touch "$WORK/stop"; wait "$wp"
total=$(wc -l < "$home/state/child.status" | tr -d ' ')
out=$(PATH="$fb:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary)
final=$(printf '%s' "$out" | jq '.counts.decisions_open')
echo "after writer stopped: written=$total shown=$final"
[ "$final" = "$total" ] || bad=1
[ "$bad" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
