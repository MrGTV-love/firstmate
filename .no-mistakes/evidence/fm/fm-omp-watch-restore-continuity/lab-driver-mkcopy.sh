#!/usr/bin/env bash
# usage: mkcopy.sh <dest> <ext-ref> <pending:0|1> <hold-ms>
set -eu
W=/Users/charlesabrooker/.no-mistakes/worktrees/eded895c05cf/01M78E48V6WPVZCB3M81FKRCM2
D=$1 REF=$2 PEND=$3 HOLD=${4:-30000}
rm -rf "$D"; mkdir -p "$D"
git -C "$W" archive HEAD | tar -x -C "$D"
git -C "$W" show "$REF:.omp/extensions/fm-primary-omp-watch.ts" > "$D/.omp/extensions/fm-primary-omp-watch.ts"
if [ "$PEND" = 1 ]; then
  mkdir -p "$D/.omp/lab-real"
  mv "$D/.omp/extensions/fm-primary-omp-watch.ts" "$D/.omp/lab-real/"
  cp -R "$D/.omp/extensions/lib" "$D/.omp/lab-real/lib"
  cat > "$D/.omp/extensions/fm-lab-pending-send.ts" <<TS
// LAB ONLY: omp's sendUserMessage is made to settle late (as if after the model turn).
import { appendFileSync } from "node:fs";
import real from "../lab-real/fm-primary-omp-watch.ts";
const log = (line: string) => { try { appendFileSync(\`\${process.env.FM_HOME}/state/.lab-send-log\`, \`\${new Date().toISOString()} \${line}\n\`); } catch {} };
export default function (pi: any) {
  const proxied = new Proxy(pi, {
    get(target, key) {
      if (key === "sendUserMessage") {
        return (...args: any[]) => {
          const text = String(args[0] ?? "");
          const result = target.sendUserMessage(...args);
          if (!text.includes("FIRSTMATE WATCHER WAKE")) return result;
          log("send-accepted-by-omp held=${HOLD}ms " + JSON.stringify(text.slice(0, 120)));
          return new Promise((resolve) => setTimeout(() => { log("send-promise-settled " + JSON.stringify(text.slice(0, 120))); resolve(result); }, ${HOLD}));
        };
      }
      const value = Reflect.get(target, key);
      return typeof value === "function" ? value.bind(target) : value;
    },
  });
  return real(proxied);
}
TS
fi
(cd "$D" && git init -q && git add -A && git -c user.name=lab -c user.email=lab@lab commit -qm lab)
echo "built $D from ext $(git -C "$W" rev-parse "$REF") pending=$PEND"
