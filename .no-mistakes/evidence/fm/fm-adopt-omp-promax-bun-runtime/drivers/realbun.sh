#!/usr/bin/env bash
# Usage: realbun.sh <repo>  - start real bun processes in a scratch dir and judge them
REPO=$1; IDENT=$REPO/bin/fm-omp-identity.py
S=$(mktemp -d /tmp/fm-relbun.XXXXXX); S=$(cd "$S" && pwd -P); mkdir -p "$S/src"
printf '{"name":"scratch","scripts":{"dev":"sleep 15"}}\n' > "$S/package.json"
echo 'setInterval(()=>{},1000);' > "$S/src/cli.ts"; cp "$S/src/cli.ts" "$S/cli.ts"
echo 'import {test} from "bun:test"; test("wait", async()=>{ await Bun.sleep(15000); }, 20000);' > "$S/wait.test.ts"
echo "# live: real Bun ($(command -v bun), $(bun --version)) processes; verdicts from bin/fm-omp-identity.py at $(git -C "$REPO" rev-parse --short HEAD), $(date -u +%FT%TZ)"
echo "# writer exit: 1 = positively another program (unrelated), 0 = may own; interactive exit: 0 admitted, 1 refused, 2 unresolved"
judge() { local label=$1 p=$2; sleep 2
  local w=0 i=0 wo io; wo=$(python3 -I "$IDENT" writer "$p" 2>&1) || w=$?; io=$(python3 -I "$IDENT" interactive "$p" 2>&1) || i=$?
  echo "case: $label"; echo "  pid=$p  ps args: $(ps -p "$p" -o args=)"; echo "  writer exit=$w : $wo"; echo "  interactive exit=$i : $io"
  kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; }
cd "$S" || exit 1
bun run dev </dev/null >/dev/null 2>&1 & judge "bun run dev (relative argv[1] 'run')" $!
bun dev </dev/null >/dev/null 2>&1 & judge "bun dev (relative argv[1] 'dev')" $!
bun test ./wait.test.ts </dev/null >/dev/null 2>&1 & judge "bun test (relative argv[1] 'test')" $!
bun src/cli.ts --no-title </dev/null >/dev/null 2>&1 & judge "bun src/cli.ts (relative src/cli.ts)" $!
bun cli.ts --no-title </dev/null >/dev/null 2>&1 & judge "bun cli.ts (relative cli.ts)" $!
bun "$S/cli.ts" </dev/null >/dev/null 2>&1 & judge "bun <abs>/cli.ts outside a src dir" $!
bun "$S/src/cli.ts" </dev/null >/dev/null 2>&1 & judge "bun <abs>/src/cli.ts (not the installed tree)" $!
cd / && rm -rf "$S"
