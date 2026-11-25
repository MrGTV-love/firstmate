#!/usr/bin/env bash
# Usage: herdrwalk.sh <repo> - real Herdr lab pane: shell foreground, Bun job in background; read the walk verdict
REPO=$1; LAB=$REPO/bin/fm-herdr-lab.sh
NAME=$("$LAB" name relbun) || exit 1
"$LAB" prepare "$NAME" >/dev/null || { echo "prepare refused"; exit 1; }
trap '"$LAB" teardown "$NAME" >/dev/null 2>&1 && echo "# teardown ok: $NAME" || echo "# TEARDOWN FAILED: $NAME"; rm -rf "$S"' EXIT
"$LAB" provision "$NAME" >/dev/null || { echo "provision failed"; exit 1; }
S=$(mktemp -d /tmp/fm-relbunh.XXXXXX); S=$(cd "$S" && pwd -P); mkdir -p "$S/src"
printf '{"name":"scratch","scripts":{"dev":"sleep 40"}}\n' > "$S/package.json"
echo 'setTimeout(()=>{},40000);' > "$S/src/cli.ts"
echo 'import {test} from "bun:test"; test("wait", async()=>{ await Bun.sleep(30000); }, 40000);' > "$S/wait.test.ts"
WS=$("$LAB" run "$NAME" workspace create --cwd "$S" --label relbun --no-focus 2>&1)
PANE=$("$LAB" run "$NAME" pane list 2>/dev/null | jq -r '.. | objects | select(has("pane_id")) | .pane_id' | head -1)
echo "# herdr $(herdr --version 2>/dev/null | head -1); lab session $NAME; pane $PANE; repo $(git -C "$REPO" rev-parse --short HEAD); $(date -u +%FT%TZ)"
. "$REPO/bin/fm-backend.sh"; . "$REPO/bin/backends/herdr.sh"
sample() { local label=$1 cmd=$2
  "$LAB" run "$NAME" pane run "$PANE" "$cmd" >/dev/null 2>&1; sleep 6
  echo "case: $label"; echo "  typed in pane: $cmd"
  echo "  pane process-info foreground: $("$LAB" run "$NAME" pane process-info --pane "$PANE" 2>/dev/null | jq -c '[.result.process_info.foreground_processes[]?|.argv]')"
  SH=$("$LAB" run "$NAME" pane process-info --pane "$PANE" 2>/dev/null | jq -r '.result.process_info.shell_pid')
  echo "  live children of pane shell $SH: $(ps -axo pid=,ppid=,args= | awk -v s="$SH" '{p[$1]=$2;l[$1]=$0} END{for(k in p){q=k;while(q in p&&q!=s)q=p[q]; if(q==s&&k!=s)print l[k]}}' | tr '\n' ';')"
  echo "  walk verdict (fm_backend_herdr_pane_process_state_sample): $(fm_backend_herdr_pane_process_state_sample "$NAME" "$PANE")"
  "$LAB" run "$NAME" pane run "$PANE" 'kill %1 2>/dev/null; wait' >/dev/null 2>&1; sleep 2; }
sleep 6
echo "case: empty shell"; echo "  walk verdict: $(fm_backend_herdr_pane_process_state_sample "$NAME" "$PANE")"
sample "background bun run dev (relative 'run')" 'bun run dev >/dev/null 2>&1 &'
sample "background bun test (relative 'test')" 'bun test ./wait.test.ts >/dev/null 2>&1 & '
sample "background bun src/cli.ts (relative src/cli.ts)" 'bun src/cli.ts >/dev/null 2>&1 &'
echo "case: empty shell again"; echo "  walk verdict: $(fm_backend_herdr_pane_process_state_sample "$NAME" "$PANE")"
