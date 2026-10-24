#!/usr/bin/env bash
# Replays the 136 logged resolve structures (tests/fixtures/dispatch-resolve-20261024.json)
# through the real public resolver in a disposable lab home, local fake provider only.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5R0BFX4V25T7RRQ9PMN8VHK
DRV=$(cd "$(dirname "$0")" && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); bash "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-replay.XXXXXX"); server=''
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; rm -rf "$LAB" "$WORK"' EXIT
mkdir -p "$LAB/config" "$LAB/data"
printf '%s\n' '# Projects' '- firstmate - Supervisor' > "$LAB/data/projects.md"
jq -n '{judgments:(reduce range(1;8) as $i ({}; .["r\($i)"]={type:"noul",instructions:"Does this recorded task have property \($i)?",criteria:{"true":"Present.","false":"Absent."}})),
  rules:[range(1;8) as $i | {when:"Recorded rule \($i)", match:{projects:["firstmate"],all:["r\($i)"]}, use:{harness:"claude",model:"claude-sonnet-5-5[1m]",effort:"high"}}],
  default:{harness:"claude",model:"claude-sonnet-5-5[1m]",effort:"high"}}' > "$LAB/config/crew-dispatch.json"
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in --version) echo 0.1.51;; --json) echo '"'"'{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}}]}'"'"';; *) exit 2;; esac' > "$FAKEBIN/quota-axi"
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in usage) echo "{\"reports\":[]}";; *) exit 2;; esac' > "$FAKEBIN/omp"
chmod +x "$FAKEBIN"/*
SETTINGS="$WORK/s.json"; echo '{}' > "$SETTINGS"
node "$DRV/provider.mjs" "$SETTINGS" "$WORK/calls.jsonl" "$WORK/port" & server=$!
for _ in $(seq 100); do [ -f "$WORK/port" ] && break; sleep .05; done
export FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$WORK/port")"
unset FM_MODEL_CATALOG_DIR FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
FM_HOME="$LAB" bash "$WT/bin/fm-brief.sh" replay firstmate --mode no-mistakes >/dev/null || exit 1
sed -i '' 's/{TASK}/Recorded task (text not retained in the ledger)./' "$LAB/data/replay/brief.md"
mism=0 esc=0 human=0 n=0
clear_n=0 amb_n=0 other_n=0
while IFS=$'\t' read -r choice oldreason; do
  n=$((n+1))
  sel=$(sed -n 's/^rule_\([1-7]\)$/\1/p' <<<"$choice")
  if [ -n "$sel" ]; then printf '{"judgment_r%s":1}\n' "$sel" > "$SETTINGS"; want="rule_$sel"; else echo '{}' > "$SETTINGS"; want=none; fi
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$LAB" TYPESAFE_API_KEY=synthetic-lab-key bash "$WT/bin/fm-dispatch-resolve.sh" "$LAB/data/replay/brief.md" 2>/dev/null)
  st=$(sed -n 's/^  status: //p' <<<"$OUT"); got=$(sed -n 's/^  rule: \(rule_[0-9]*\).*/\1/p' <<<"$OUT"); [ -n "$got" ] || got=none
  case "$st" in clear) clear_n=$((clear_n+1));; ambiguous) amb_n=$((amb_n+1));; *) other_n=$((other_n+1));; esac
  [ "$st" != escalate ] || esc=$((esc+1))
  grep -q 'human requires\|explicit handler' <<<"$OUT" && human=$((human+1))
  [ "$got" = "$want" ] || { mism=$((mism+1)); echo "row $n: logged=$choice got=$got status=$st"; }
  printf 'row %3d logged=%-8s old_reason=%-60s -> status=%-9s rule=%s\n' "$n" "$choice" "${oldreason:-none}" "$st" "$got"
done < <(jq -r '.[] | [(.choice // "null"), (.reason // "")] | @tsv' "$WT/tests/fixtures/dispatch-resolve-20261024.json")
echo; echo "rows=$n escalations=$esc q7_human_reasons=$human rule_mismatches=$mism"
echo "status clear=$clear_n ambiguous=$amb_n other=$other_n"
echo "provider calls: $(wc -l < "$WORK/calls.jsonl" | tr -d ' '); any profile question sent: $(jq -s 'map(.request.questions|has("profile"))|any' "$WORK/calls.jsonl")"
[ "$n" = 136 ] && [ "$esc" = 0 ] && [ "$human" = 0 ] && [ "$mism" = 0 ]
