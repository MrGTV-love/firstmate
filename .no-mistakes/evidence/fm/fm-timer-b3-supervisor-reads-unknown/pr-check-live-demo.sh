#!/usr/bin/env bash
# Live demo: drive the real bin/fm-pr-check.sh in a disposable lab FM_HOME with a
# fake no-mistakes daemon (silent / slow-but-working / unreadable) and a fake gh
# that fails (no network). Runs each case on the change (HEAD) and on base bin/.
# Usage: pr-check-live-demo.sh <worktree> <base-sha>
set -u
WT_REPO=$1 BASE=$2
for v in $(env | sed -n 's/^\(FM_[A-Z_]*_OVERRIDE\)=.*/\1/p'); do unset "$v"; done
unset FM_GATE_REFUSE_BYPASS
eval "$("$WT_REPO/bin/fm-lab-home.sh" env)"
LAB=$FM_HOME
echo "lab home: $LAB"
FAKE="$LAB/fakebin"; mkdir -p "$FAKE" "$LAB/base"
git -C "$WT_REPO" archive "$BASE" bin | tar -x -C "$LAB/base"

cat > "$FAKE/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s %s mode=%s\n' "$(date +%s)" "$*" "$(cat "$FM_DEMO_MODE_FILE")" >> "$FM_DEMO_NM_LOG"
[ "${1:-} ${2:-}" = "axi status" ] || exit 2
case "$(cat "$FM_DEMO_MODE_FILE")" in
  silent) exec sleep 117 ;;
  slow)
    # A loaded host: 20 s of CPU before it answers (base's fixed cap was 15 s).
    end=$((SECONDS + 20)); while [ "$SECONDS" -lt "$end" ]; do :; done ;;
  unreadable) printf 'garbage without a run line\n'; exit 0 ;;
esac
head=$(git rev-parse HEAD)
printf 'run:\n  id: "DEMORUN"\n  branch: fm/demo\n  status: completed\n  head_sha: %s\noutcome: passed\nbranch_sync:\n  state: synchronized\n  local:\n    head: %s\n  pipeline:\n    current_head: %s\n' "$head" "$head" "$head"
SH
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE/gh"
chmod +x "$FAKE/no-mistakes" "$FAKE/gh"
export PATH="$FAKE:$PATH" FM_DEMO_NM_LOG="$LAB/nm-calls.log" FM_DEMO_MODE_FILE="$LAB/mode"
echo "no-mistakes resolves to: $(command -v no-mistakes)"
echo "gh resolves to: $(command -v gh)"

REPO="$LAB/repo"; git init -q -b fm/demo "$REPO"
git -C "$REPO" -c user.email=d@e -c user.name=demo commit -q --allow-empty -m init
mkdir -p "$LAB/state"

run_case() { # <label> <bin-root> <mode> <stall>
  local label=$1 root=$2 mode=$3 stall=$4 id rc start end
  id="demo-$label"
  printf 'kind=ship\nmode=no-mistakes\nworktree=%s\nproject=%s\nbranch=fm/demo\n' "$REPO" "$REPO" > "$LAB/state/$id.meta"
  printf '%s\n' "$mode" > "$FM_DEMO_MODE_FILE"
  echo "=== case $label: $root/bin/fm-pr-check.sh, daemon=$mode, FM_DOD_NM_STALL_SECS=$stall"
  start=$(date +%s); rc=0
  FM_DOD_NM_STALL_SECS=$stall bash "$root/bin/fm-pr-check.sh" "$id" https://github.com/example/demo/pull/7 \
    > "$LAB/out" 2>&1 || rc=$?
  end=$(date +%s)
  grep -v '^$' "$LAB/out" | grep -iv 'banner\|^[=#*-]\{5,\}' | tail -4
  echo "exit=$rc elapsed=$((end - start))s"
  echo "recorded pr= in meta: $(grep -c '^pr=' "$LAB/state/$id.meta")"
  echo "leftover fake daemons: $(pgrep -f "$FAKE/no-mistakes|^sleep 117$" | wc -l | tr -d ' ')"
}

echo "##### CHANGE (target commit)"
run_case change-silent "$WT_REPO" silent 3
run_case change-slow "$WT_REPO" slow 3
run_case change-unreadable "$WT_REPO" unreadable 3
echo "##### BASE ($BASE) - same fakes; FM_DOD_NM_STALL_SECS is unknown to base"
run_case base-silent "$LAB/base" silent 3
run_case base-slow "$LAB/base" slow 3
echo "##### daemon calls"
cat "$FM_DEMO_NM_LOG"
pkill -f "$FAKE/no-mistakes" 2>/dev/null; pkill -fx "sleep 117" 2>/dev/null
"$WT_REPO/bin/fm-lab-home.sh" teardown "$LAB" && rm -rf "$LAB" && echo "lab removed: $([ -e "$LAB" ] && echo no || echo yes)"
