#!/usr/bin/env bash
# Drives the real bin/fm-dispatch-resolve.sh (and fm-brief.sh scaffold) in a
# disposable lab home against a local fake TypeSafe endpoint. No paid call.
set -u
WT=/Users/charlesabrooker/.no-mistakes/worktrees/32d18ed9638d/01M5R0BFX4V25T7RRQ9PMN8VHK
DRV=$(cd "$(dirname "$0")" && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bash "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-drive.XXXXXX")
server=''
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; rm -rf "$LAB" "$WORK"' EXIT
PASS=0 FAILN=0
ok()   { PASS=$((PASS+1)); echo "  PASS: $*"; }
bad()  { FAILN=$((FAILN+1)); echo "  FAIL: $*"; }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
hdr()  { echo; echo "=== $* ==="; }

# --- lab fixture: registry, clones, rules, fake quota tools ---------------
mkdir -p "$LAB/config" "$LAB/data" "$LAB/projects/vernant" "$LAB/projects/pager"
printf '%s\n' '# Projects' '- firstmate [no-mistakes] - Supervisor' '- vernant [no-mistakes] - Vernant' '- pager - Pager' > "$LAB/data/projects.md"
cat > "$LAB/config/crew-dispatch.json" <<'JSON'
{"judgments":{
  "design_judgment":{"type":"noul","instructions":"Does task require choosing a design not already settled in its specification?","criteria":{"true":"A design choice remains necessary.","false":"The design is already specified."}},
  "bounded":{"type":"noul","instructions":"Does task have a known cause and written acceptance?","criteria":{"true":"The cause and acceptance are written.","false":"Investigation is still needed."}}},
 "rules":[
  {"when":"Vernant ship that needs design.","match":{"projects":["vernant"],"kind":"ship","all":["design_judgment"]},"use":{"harness":"claude","model":"opus","effort":"high"}},
  {"when":"Non-Vernant ship that is well understood.","match":{"projects":["firstmate","pager"],"kind":"ship","all":["bounded"]},"use":{"harness":"claude","model":"claude-haiku-5-5","effort":"low"}},
  {"when":"Scout on any project.","match":{"projects":["firstmate","vernant","pager"],"kind":"scout","any":["bounded","design_judgment"]},"use":{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"medium"}}
 ],
 "default":{"harness":"claude","model":"claude-sonnet-5-5[1m]","effort":"high"}}
JSON
cp "$LAB/config/crew-dispatch.json" "$WORK/rules.base.json"
FAKEBIN="$WORK/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/quota-axi" <<'Q'
#!/usr/bin/env bash
case "$1" in
  --version) echo 0.1.51 ;;
  --json) echo '{"schemaVersion":5,"providers":[{"provider":"claude","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":80,"runway":{"status":"through_reset"},"selection":{"spendPriority":0.8}}]}}]}' ;;
  *) exit 2 ;;
esac
Q
cat > "$FAKEBIN/omp" <<'O'
#!/usr/bin/env bash
case "$1" in usage) echo '{"reports":[]}' ;; models) echo '{"models":[]}' ;; *) exit 2 ;; esac
O
chmod +x "$FAKEBIN/quota-axi" "$FAKEBIN/omp"
SETTINGS="$WORK/settings.json" CALLS="$WORK/calls.jsonl"
echo '{}' > "$SETTINGS"
node "$DRV/provider.mjs" "$SETTINGS" "$CALLS" "$WORK/port" & server=$!
for _ in $(seq 100); do [ -f "$WORK/port" ] && break; sleep .05; done
export FM_TEST_SEAM=1 FM_TYPESAFE_TEST_ENDPOINT="http://127.0.0.1:$(cat "$WORK/port")"
unset FM_MODEL_CATALOG_DIR FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE
count() { [ -f "$CALLS" ] && wc -l < "$CALLS" | tr -d ' ' || echo 0; }
last() { tail -n 1 "$CALLS" | jq -c .request; }
resolve() { # resolve <brief> [args...]; sets OUT ERR CODE
  OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$LAB" TYPESAFE_API_KEY=synthetic-lab-key bash "$WT/bin/fm-dispatch-resolve.sh" "$@" 2>"$WORK/err"); CODE=$?
  ERR=$(cat "$WORK/err")
  echo "\$ fm-dispatch-resolve.sh $(printf '%q ' "${@/#$LAB/\$LAB}")  -> exit $CODE"
  printf '%s\n' "$OUT" | sed 's/^/    | /'
  [ -z "$ERR" ] || printf '%s\n' "$ERR" | sed 's/^/    ! /'
}
scaffold() { # scaffold <id> <repo> [flags...]
  FM_HOME="$LAB" bash "$WT/bin/fm-brief.sh" "$@" >/dev/null 2>"$WORK/scaf.err" || { echo "scaffold failed: $(cat "$WORK/scaf.err")"; return 1; }
  local b="$LAB/data/$1/brief.md"
  # Fill the captain's intent placeholder so the brief has task text.
  python3 - "$b" <<'P'
import sys; p=sys.argv[1]; t=open(p).read()
t=t.replace("{TASK}","Fix the known pager retry bug; the cause and acceptance case are written.",1)
open(p,"w").write(t)
P
  echo "  scaffolded $1 ($2 $3): line 1 = $(head -n1 "$b" | sed "s#$LAB#\$LAB#")"
}

hdr "S1 Vernant ship scaffold can never select a non-Vernant rule (T6a)"
scaffold vern-ship vernant --mode direct-PR
echo '{"judgment_bounded":1,"judgment_design_judgment":0.9}' > "$SETTINGS"
resolve "$LAB/data/vern-ship/brief.md"
REQ=$(last)
check '[ "$CODE" = 0 ]' 'exit 0'
check 'grep -q "rule: rule_1" <<<"$OUT"' 'selected the Vernant rule_1'
check '! grep -q "rule_2" <<<"$OUT"' 'non-Vernant rule_2 never appears in support or fallback'
check '[ "$(jq -r ".questions | has(\"judgment_bounded\")" <<<"$REQ")" = false ]' 'non-Vernant judgment "bounded" is never asked'
check '[ "$(jq -r ".state.repository" <<<"$REQ")" = vernant ]' 'state.repository is the code-derived id vernant'
echo '{"judgment_bounded":1,"judgment_design_judgment":0}' > "$SETTINGS"
resolve "$LAB/data/vern-ship/brief.md"
check '! grep -q "rule: rule_2" <<<"$OUT" && ! grep -q "claude-haiku" <<<"$OUT"' 'even when the Vernant predicate is false and bounded=1, the non-Vernant haiku rule is not reachable'

hdr "S2 Non-Vernant (pager) ship reaches only its own rule"
scaffold pager-ship pager --mode direct-PR
echo '{"judgment_bounded":1,"judgment_design_judgment":1}' > "$SETTINGS"
resolve "$LAB/data/pager-ship/brief.md"
REQ=$(last)
check 'grep -q "rule: rule_2" <<<"$OUT"' 'pager ship selects rule_2'
check '[ "$(jq -r ".questions | has(\"judgment_design_judgment\")" <<<"$REQ")" = false ]' 'Vernant-only judgment is not asked for pager'

hdr "S3 Adversarial: free-text --project spellings are refused (review finding)"
for sp in Vernant ' vernant' vernant; do
  b=$(count); resolve "$LAB/data/pager-ship/brief.md" --project "$sp"
  check '[ "$CODE" = 2 ] && grep -q "unknown flag --project" <<<"$ERR"' "--project '$sp' exits 2 as an unknown flag"
  check '[ "$(count)" = "$b" ]' "--project '$sp' sends nothing"
done

hdr "S4 Adversarial: hand-edited project_path cannot fake Vernant identity"
for loc in "$LAB/projects/Vernant" "$LAB/projects/ vernant" "$WORK/elsewhere" "relative/projects/vernant"; do
  mkdir -p "$WORK/elsewhere"
  { printf 'FIRSTMATE_DISPATCH: %s\n' "$(jq -cn --arg p "$loc" '{project_path:$p}')"; tail -n +2 "$LAB/data/vern-ship/brief.md"; } > "$WORK/forged.md"
  b=$(count); resolve "$WORK/forged.md"
  check 'grep -q "status: escalate" <<<"$OUT" && ! grep -q "  profile:" <<<"$OUT"' "project_path='${loc/#$LAB/\$LAB}' escalates with no profile"
  check '[ "$(count)" = "$b" ]' "project_path='${loc/#$LAB/\$LAB}' sends nothing"
done
ln -s "$WORK/elsewhere" "$WORK/vernant"
{ printf 'FIRSTMATE_DISPATCH: %s\n' "$(jq -cn --arg p "$WORK/vernant" '{project_path:$p}')"; tail -n +2 "$LAB/data/vern-ship/brief.md"; } > "$WORK/forged.md"
b=$(count); resolve "$WORK/forged.md"
check 'grep -q "exactly one registered project clone" <<<"$OUT" && [ "$(count)" = "$b" ]' 'a symlink named vernant to an unrelated dir is not the Vernant clone'
{ tail -n +2 "$LAB/data/vern-ship/brief.md"; printf '\n```json\n%s\n```\n' "$(head -n1 "$LAB/data/vern-ship/brief.md")"; } > "$WORK/quoted.md"
b=$(count); resolve "$WORK/quoted.md"
check 'grep -q "missing FIRSTMATE_DISPATCH" <<<"$OUT" && [ "$(count)" = "$b" ]' 'a record quoted in task prose cannot supply identity'

hdr "S5 Adversarial: rules naming 'Vernant' or ' vernant' are config errors"
for id in Vernant ' vernant'; do
  jq --arg id "$id" '.rules[0].match.projects=[$id]' "$WORK/rules.base.json" > "$LAB/config/crew-dispatch.json"
  b=$(count); resolve "$LAB/data/vern-ship/brief.md"
  check '[ "$CODE" = 2 ] && grep -q "match.projects contains an unregistered project id" <<<"$ERR" && [ "$(count)" = "$b" ]' "projects=['$id'] exits 2, names the field, sends nothing"
done
jq '.rules[0].match={project:"vernant",all:["design_judgment"]}' "$WORK/rules.base.json" > "$LAB/config/crew-dispatch.json"
resolve "$LAB/data/vern-ship/brief.md"
check '[ "$CODE" = 2 ] && grep -q "non-empty projects array" <<<"$ERR"' 'legacy singular match.project is rejected'
cp "$WORK/rules.base.json" "$LAB/config/crew-dispatch.json"

hdr "S6 Request shape: Q6 split, Q7 gone, Q9 criteria, current model, no kind"
echo '{"judgment_design_judgment":1}' > "$SETTINGS"
resolve "$LAB/data/vern-ship/brief.md"
REQ=$(last)
echo "  request questions: $(jq -c '.questions | to_entries | map({(.key): .value.type}) | add' <<<"$REQ")"
echo "  request model: $(jq -r .model <<<"$REQ"); state keys: $(jq -c '.state|keys' <<<"$REQ")"
echo "  needs_desktop: $(jq -c .questions.needs_desktop <<<"$REQ")"
check '[ "$(jq -r .model <<<"$REQ")" = jev-latest ]' 'model is jev-latest (no pinned version)'
check '[ "$(jq -r ".questions | has(\"profile\")" <<<"$REQ")" = false ]' 'Q7 workflow "profile" question is gone'
check '[ "$(jq -r ".questions | has(\"rule\")" <<<"$REQ")" = false ]' 'Q6 categorical "rule" choice is gone'
check '[ "$(jq -r "[.questions | to_entries[] | select(.key|startswith(\"judgment_\")) | .value.type] | unique | join(\",\")" <<<"$REQ")" = noul ]' 'every judgment_* question is a single-judgment noul'
check '[ "$(jq -r ".questions.needs_desktop | (.type==\"noul\") and (.criteria.true|length>0) and (.criteria.false|length>0)" <<<"$REQ")" = true ]' 'Q9 needs_desktop is a noul with true/false criteria'
check '[ "$(jq -c ".state|keys" <<<"$REQ")" = "[\"repository\",\"task\"]" ]' 'state holds only task and repository (no kind)'
check '! jq -r .state.task <<<"$REQ" | grep -q "project_path\|FIRSTMATE_DISPATCH"' 'the clone path record never reaches the provider'
check '! grep -qF "$LAB" <<<"$REQ"' 'no absolute lab path reaches the provider'

hdr "S7 Q7 removed: an obsolete 'profile: human' answer cannot escalate; Q9 still can"
echo '{"judgment_design_judgment":1,"extra":{"profile":{"type":"choice","choice":"human","confidence":1,"probabilities":{"human":1}}}}' > "$SETTINGS"
resolve "$LAB/data/vern-ship/brief.md"
check '! grep -q "status: escalate" <<<"$OUT" && ! grep -qi "human requires" <<<"$OUT"' 'stray profile=human answer does not escalate'
echo '{"judgment_design_judgment":1,"needs_desktop":0.9}' > "$SETTINGS"
resolve "$LAB/data/vern-ship/brief.md"
check 'grep -q "status: escalate" <<<"$OUT" && grep -q "desktop access" <<<"$OUT"' 'needs_desktop=0.9 escalates for a capability decision'
echo '{"judgment_design_judgment":1,"needs_desktop":0.5}' > "$SETTINGS"
resolve "$LAB/data/vern-ship/brief.md"
check '! grep -q "desktop access" <<<"$OUT"' 'needs_desktop=0.5 (boundary) does not escalate'

hdr "S8 Scout kind comes from the scaffold's # Setup, in code"
scaffold vern-scout vernant --scout
echo '{"judgment_bounded":1,"judgment_design_judgment":1}' > "$SETTINGS"
resolve "$LAB/data/vern-scout/brief.md"
REQ=$(last)
check 'grep -q "rule: rule_3" <<<"$OUT" && ! grep -q "rule_1=" <<<"$OUT"' 'Vernant scout selects the scout rule_3, not the ship rule'
check '[ "$(jq -r ".state|has(\"kind\")" <<<"$REQ")" = false ]' 'scout kind is not sent in state'
{ cat "$LAB/data/vern-ship/brief.md"; printf '\n```\n%s\n```\n' 'This is a SCOUT task: the deliverable is a written report, not a PR.'; } > "$WORK/ship-quoting-scout.md"
resolve "$WORK/ship-quoting-scout.md"
check 'grep -q "rule: rule_1" <<<"$OUT"' 'a ship quoting the scout line in a fence stays a ship'

hdr "S9 Never-send screens judgment ids in request keys"
cp "$WORK/rules.base.json" "$LAB/config/crew-dispatch.json"
printf '%s\n' 'design_judgment' > "$LAB/config/dispatch-never-send"
b=$(count); resolve "$LAB/data/vern-ship/brief.md"
check '[ "$CODE" = 0 ] && [ -z "$OUT" ] && grep -q "nothing sent" <<<"$ERR" && [ "$(count)" = "$b" ]' 'a never-send line matching only a judgment id withholds the request'
rm -f "$LAB/config/dispatch-never-send"

hdr "S10 FM_PROJECTS_OVERRIDE binds to the overridden clone directory"
mkdir -p "$WORK/alt-projects/vernant"
FM_HOME="$LAB" FM_PROJECTS_OVERRIDE="$WORK/alt-projects" bash "$WT/bin/fm-brief.sh" vern-alt vernant --mode direct-PR >/dev/null 2>&1
sed -i '' 's/{TASK}/Fix the bounded bug./' "$LAB/data/vern-alt/brief.md"
echo "  line 1: $(head -n1 "$LAB/data/vern-alt/brief.md" | sed "s#$WORK#\$WORK#")"
echo '{"judgment_design_judgment":1}' > "$SETTINGS"
OUT=$(PATH="$FAKEBIN:$PATH" FM_HOME="$LAB" FM_PROJECTS_OVERRIDE="$WORK/alt-projects" TYPESAFE_API_KEY=synthetic-lab-key bash "$WT/bin/fm-dispatch-resolve.sh" "$LAB/data/vern-alt/brief.md" 2>&1)
printf '%s\n' "$OUT" | sed 's/^/    | /' | head -6
check 'grep -q "rule: rule_1" <<<"$OUT"' 'override-scaffolded Vernant brief resolves to the Vernant rule'
b=$(count); resolve "$LAB/data/vern-alt/brief.md"
check 'grep -q "exactly one registered project clone" <<<"$OUT" && [ "$(count)" = "$b" ]' 'without the override the same path is unregistered and nothing is sent'

hdr "S11 Registry failure is named, not a rules error"
mv "$LAB/data/projects.md" "$WORK/projects.md"
b=$(count); resolve "$LAB/data/vern-ship/brief.md"
check 'grep -q "project registry data/projects.md is missing or unreadable" <<<"$OUT" && [ "$(count)" = "$b" ]' 'missing registry escalates with its own reason and sends nothing'
mv "$WORK/projects.md" "$LAB/data/projects.md"

hdr "S12 Shipped docs/examples/crew-dispatch.json is accepted by the real resolver"
cp "$WT/docs/examples/crew-dispatch.json" "$LAB/config/crew-dispatch.json"
cp "$WT/docs/examples/model-index.json" "$LAB/config/model-index.json"
scaffold fm-ship firstmate --mode no-mistakes
echo '{"judgment_mechanical":1}' > "$SETTINGS"
resolve "$LAB/data/fm-ship/brief.md"
REQ=$(last)
check '[ "$CODE" = 0 ] && grep -q "status:" <<<"$OUT"' 'example config (with its documented model index) validates and resolves (exit 0 with a status)'
check '[ "$(jq -r ".state.repository" <<<"$REQ")" = firstmate ] && [ "$(jq -r ".questions|has(\"judgment_mechanical\")" <<<"$REQ")" = true ]' 'example judgments are sent as judgment_* nouls for a firstmate ship'
rm -f "$LAB/config/model-index.json"
cp "$WORK/rules.base.json" "$LAB/config/crew-dispatch.json"

hdr "Result log"
echo "  data/dispatch-resolve.jsonl lines: $(wc -l < "$LAB/data/dispatch-resolve.jsonl" | tr -d ' ')"
echo "  last record: $(tail -n1 "$LAB/data/dispatch-resolve.jsonl")"
echo; echo "TOTAL PASS=$PASS FAIL=$FAILN"
[ "$FAILN" = 0 ]
