#!/usr/bin/env bash
# omp-case.sh <name> <tool> <args-json> <grant-json-or-none> [extra-config.yml] [tools-list]
# Drives the REAL installed omp with the REAL fm-spawn-generated worker extension and the
# worker overlay; the model is a loopback scripted provider that emits exactly one tool call.
set -u
S=/Users/charlesabrooker/tmp/fm-t4-live.qr0aEH; R=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5SZXS1J5EMJABDG23S1KFEZ
name=$1 tool=$2 args=$3 grant=$4 extra=${5:-} tools=${6:-$2}
H=$S/lab/spawn-omp/home; WT=$S/lab/spawn-omp/wt; OUT=$S/out/omp-$name; mkdir -p "$OUT"
meta=$H/state/t4omp.meta
grep -v '^egress=' "$meta" > "$meta.tmp"; mv "$meta.tmp" "$meta"
[ "$grant" = none ] || printf 'egress=%s\n' "$grant" >> "$meta"
jq -n --arg tool "$tool" --argjson args "$args" '{phase:"normal",tool:$tool,benign:true,args:$args}' > "$S/run/scenario.json"
: > "$S/run/model.jsonl"; : > "$S/run/jev.jsonl"
rows_before=$(cat "$H/state/jev-guard.jsonl" 2>/dev/null | wc -l); ev_before=$(cat "$H/state/guard-events.jsonl" 2>/dev/null | wc -l)
curl -fsS -X POST -d '{}' "http://127.0.0.1:$(cat $S/run/port)/reset" >/dev/null
cfg=(--config "$R/.omp/fm-worker-overlay.yml"); [ -z "$extra" ] || cfg+=(--config "$extra")
(cd "$WT" && env -u TYPESAFE_API_KEY -u OPENROUTER_API_KEY HOME="$S/run/os-home" PI_CODING_AGENT_DIR="$S/run/agent" OMP_SKIP_SETUP=1 TMPDIR="$S/run/tmp" \
  HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  PI_EDIT_VARIANT=replace timeout 120 omp -p "Use the one tool call, then stop." --model native/gpt-6.1-sol --thinking off --no-session \
  --no-extensions -e "$H/state/t4omp.omp-ext.ts" ${EXTRA_EXT:+-e "$EXTRA_EXT"} "${cfg[@]}" $( [ -n "${KEEP_SKILLS:-}" ] || echo --no-skills ) --no-rules --no-title --no-lsp --tools "$tools" \
  < /dev/null > "$OUT/omp.out" 2>&1); echo "exit=$?" > "$OUT/exit"
{ echo "== case: $name  tool=$tool grant=$grant"; echo "== omp version: $(omp --version)"; echo "== args: $args"; cat "$OUT/exit"
  echo "== tool calls the scripted model emitted (turn 1):"; head -1 "$S/run/model.jsonl" | jq -c '[.tools[].name]' 2>/dev/null | head -c 600; echo
  echo "== tool result omp returned to the model (turn 2 request):"
  sed -n 2p "$S/run/model.jsonl" | jq -r '.input[] | select(.type=="function_call_output") | .output' 2>/dev/null | head -c 1500; echo
  echo "== new state/jev-guard.jsonl rows:"; tail -n +$((rows_before+1)) "$H/state/jev-guard.jsonl" 2>/dev/null | jq -c '{tool,decision,enforcement,branch,destination_class,confinement_owner}'
  echo "== new state/guard-events.jsonl events:"; tail -n +$((ev_before+1)) "$H/state/guard-events.jsonl" 2>/dev/null | jq -c '{guard,decision,session,source_ok}'
  echo "== Jev model requests: $(wc -l < "$S/run/jev.jsonl" | tr -d ' ')"
} > "$OUT/transcript.txt"
cat "$OUT/transcript.txt"
