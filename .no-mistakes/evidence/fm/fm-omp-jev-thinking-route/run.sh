#!/usr/bin/env bash
# run.sh <label> <spawn-label> <task-id> <wt> <tool> <typesafe ok|down> [timeout-s]
# Runs fm-spawn's exact staged omp launch in a real tmux pane on the lab's fm-lab socket.
# Only change: -e points at a wrapper that loads the generated extension unchanged and
# moves the registered TypeSafe base URL to the loopback fake (the credential command is kept).
set -u
W=/tmp/fmlive.9rLnPC; LAB=$(cat $W/labpath); PORT=$(cat $W/port); BASE=http://127.0.0.1:$PORT
label=$1 spawn=$2 id=$3 wt=$4 tool=$5 ts=$6 limit=${7:-420}
gen="$LAB/state/$id.omp-ext.ts"
rm -f $W/$label-start.json $W/$label-end.json
curl -s -X POST $BASE/__scenario -d "{\"scenario\":\"$label\",\"tool\":\"$tool\",\"typesafe\":\"$ts\"}" >/dev/null
cat > $W/wrap-$label.ts <<TS
import gen from "$gen";
import { writeFileSync } from "node:fs";
export default function (pi: any) {
  const own = { id: "main", name: "Fixture main", reasoning: true, input: ["text"], contextWindow: 32768, maxTokens: 8192, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
  pi.registerProvider("fixture", { baseUrl: "$BASE/v1", apiKey: "fake-main-key", api: "openai-completions", models: [own] });
  const orJudge = { ...own, id: "~typesafe/jev-latest", name: "Credentialed OpenRouter judge trap", kind: "judge", reasoning: false, api: "openrouter-decisions", baseUrl: "$BASE/openrouter/v1" };
  const orChat = { ...own, id: "anthropic/claude-haiku-5.5", name: "Credentialed OpenRouter chat trap", reasoning: false };
  pi.registerProvider("openrouter", { baseUrl: "$BASE/openrouter/v1", apiKey: "fake-or-trap", api: "openai-completions", models: [orJudge, orChat], fetchDynamicModels: async () => [orJudge, orChat] });
  pi.registerProvider("secondary", { baseUrl: "$BASE/secondary/v1", apiKey: "fake-secondary-key", api: "openai-completions", models: [{ ...own, id: "tiny", reasoning: false }] });
  const typesafe: any[] = [];
  const proxied = new Proxy(pi, { get(t: any, k: any) {
    if (k === "registerProvider") return (name: string, cfg: any) => {
      if (name !== "typesafe") return t.registerProvider(name, cfg);
      typesafe.push({ productionBaseUrl: cfg.baseUrl, credential: cfg.apiKey === "!false" ? "!false (always fails)" : cfg.apiKey.startsWith("!bash -c ") ? "!bash fm_typesafe_key lookup" : "other" });
      return t.registerProvider(name, { ...cfg, baseUrl: "$BASE" });
    };
    const v = t[k]; return typeof v === "function" ? v.bind(t) : v;
  } });
  gen(proxied);
  const role = (ctx: any, r: string) => { const m = ctx.models?.resolve?.(r); return m ? m.provider + "/" + m.id : null; };
  pi.on("session_start", (_e: any, ctx: any) => writeFileSync("$W/$label-start.json", JSON.stringify({ typesafeRegistration: typesafe, activeTools: pi.getActiveTools(), main: ctx.model ? ctx.model.provider + "/" + ctx.model.id : null, smol: role(ctx, "@smol"), tiny: role(ctx, "@tiny"), judge: role(ctx, "@judge"), hasUI: ctx.hasUI }, null, 1)));
  pi.on("agent_end", (e: any, ctx: any) => { if (e?.willContinue) return; writeFileSync("$W/$label-end.json", JSON.stringify({ hasUI: ctx.hasUI, sessionFile: ctx.sessionManager?.getSessionFile?.() ?? null })); });
}
TS
grep -c -- "-e '$gen'" $W/launch-$spawn.log >/dev/null || { echo "staged launch lacks generated extension"; exit 1; }
python3 -I - "$W/launch-$spawn.log" "$W/launch-$label.run" "$gen" "$W/wrap-$label.ts" <<'PY'
import sys; src, dst, gen, wrap = sys.argv[1:]
t = open(src).read(); a = f"-e '{gen}'"; assert t.count(a) == 1, t.count(a)
t = t.replace(a, f"-e '{wrap}'")
import os
for spec in filter(None, os.environ.get("CONTROL_REPLACE", "").split("|||")):
    x, y = spec.split("=>"); assert t.count(x) == 1, (x, t.count(x)); t = t.replace(x, y)
open(dst, "w").write(t)
PY
export TMUX_TMPDIR=$LAB/tmux
env -i PATH="/Users/charlesabrooker/.bun/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$W/userhome" TERM=xterm-256color LANG=en_US.UTF-8 \
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_TEST_SEAM=1 FM_JEV_GUARD_BASE_URL="$BASE/guard" \
  tmux -L fm-lab new-session -d -s "${TSESS:-$label}" -n "${TWIN:-main}" -x 180 -y 45 -c "$wt" "bash --noprofile --norc -c '. \"\$1\"; echo OMP-EXITED-\$?; exec sleep 3600' _ '$W/launch-$label.run'"
start=$(date +%s)
while [ ! -f $W/$label-end.json ] && [ $(( $(date +%s) - start )) -lt $limit ]; do perl -e 'select(undef,undef,undef,1)'; done
perl -e 'select(undef,undef,undef,3)'
tmux -L fm-lab capture-pane -p -t "${TSESS:-$label}:${TWIN:-main}" > $W/$label-pane.txt
echo "waited $(( $(date +%s) - start ))s; end=$( [ -f $W/$label-end.json ] && echo yes || echo NO)"
