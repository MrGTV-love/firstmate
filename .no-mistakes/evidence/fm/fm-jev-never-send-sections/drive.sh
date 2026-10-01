#!/usr/bin/env bash
# Live drive of the real bin/fm-dispatch-resolve.sh in a disposable lab FM_HOME.
# A PATH curl catcher records the exact request body and answers offline, so no
# byte (synthetic or not) reaches api.typesafe.ai. All data is synthetic.
set -u
WT=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
BIN="$LAB/catcher-bin"; CAP="$LAB/capture"; mkdir -p "$BIN" "$CAP"
trap 'rm -rf "$LAB"' EXIT
cat > "$BIN/curl" <<'SH'
#!/usr/bin/env bash
out=''
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift 2;; *) shift;; esac; done
cat > "$CAP_DIR/body"
cat > "$out" <<'J'
{ "model": "jev-1.13.0", "answers": { "rule": { "type": "choice", "choice": "rule_2", "confidence": 0.9,
  "probabilities": { "rule_1": 0.05, "rule_2": 0.9, "default": 0.05 } } }, "usage": { "input_tokens": 1, "output_tokens": 1 } }
J
printf 200
SH
cat > "$BIN/quota-axi" <<'SH'
#!/usr/bin/env bash
cat <<'J'
{ "generatedAt": "2030-01-01T00:00:00Z", "schemaVersion": 5, "providers": [
 { "provider": "claude", "state": { "status": "fresh" }, "quotaSemantics": { "status": "known", "effectiveAvailability": [
  { "scope": "all_models", "status": "known", "effectivePercentRemaining": 80, "runway": { "status": "through_reset" }, "selection": { "spendPriority": 0.5 } } ] } } ] }
J
SH
chmod +x "$BIN/curl" "$BIN/quota-axi"
cat > "$LAB/config/crew-dispatch.json" <<'J'
{ "rules": [
  { "when": "New feature work on the app.", "use": { "harness": "claude", "model": "opus" } },
  { "when": "A simple bug fix with a stated root cause.", "use": { "harness": "claude", "model": "sonnet", "effort": "high" } } ] }
J
NS="$LAB/config/dispatch-never-send"
B="$LAB/brief.md"

# drive <scenario> : runs the resolver, prints stdout/stderr and the captured body
drive() {
  rm -f "$CAP/body"
  echo "================ $1"
  echo "--- list file:"; if [ -e "$NS" ]; then sed 's/^/    | /' "$NS"; else echo "    (absent)"; fi
  echo "--- brief:"; sed 's/^/    | /' "$B"
  local out err
  out=$(env -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE PATH="$BIN:$PATH" CAP_DIR="$CAP" FM_HOME="$LAB" TYPESAFE_API_KEY=synthetic-key \
        "$WT/bin/fm-dispatch-resolve.sh" "$B" --project pager 2>"$LAB/err"); echo "--- exit: $?"
  echo "--- stdout:"; printf '%s\n' "$out" | sed 's/^/    | /'
  echo "--- stderr:"; sed 's/^/    | /' "$LAB/err"
  if [ -f "$CAP/body" ]; then echo "--- OUTGOING BODY (state.task.brief):"; jq -r '.state.task.brief // .' "$CAP/body" | sed 's/^/    > /'
    echo "--- OUTGOING project: $(jq -r '.state.task.project // empty' "$CAP/body")"
  else echo "--- OUTGOING BODY: none (curl never called)"; fi
  for leak in "${@:2}"; do
    if grep -rqF -- "$leak" "$CAP" "$LAB/err" 2>/dev/null || printf '%s' "$out" | grep -qF -- "$leak"; then echo "!!! LEAK: '$leak' seen in body/stdout/stderr"; else echo "ok: '$leak' absent from body/stdout/stderr"; fi
  done
}

# S1 unmarked brief, no list file: old behavior
rm -f "$NS"
printf '%s\n' '# Task' "## Captain's intent" 'Fix the pager off-by-one; root cause is the <= on line 40.' > "$B"
drive "S1 unmarked brief, no list file -> sent as before"

# S2 unmarked brief, literal-only list with ordinary comment, no match
printf '%s\n' '# Client names' 'Synthetic Client Ltd' > "$NS"
drive "S2 unmarked brief, literal list without a match -> sent as before"

# S3 literal match still withholds
printf '%s\n' '# Task' "## Captain's intent" 'Fix pager for Synthetic Client Ltd.' > "$B"
drive "S3 literal match -> withheld" 'Synthetic Client Ltd'

# S4 opt-in + marked sections in a real fm-brief.sh scaffold
printf '%s\n' '# Client names' 'Synthetic Client Ltd' '# dispatch-never-send marked-sections' > "$NS"
rm -f "$B"
FM_HOME="$LAB" "$WT/bin/fm-brief.sh" synth-task pager --mode local-only >/dev/null 2>&1
SCAF="$LAB/data/synth-task/brief.md"; [ -f "$SCAF" ] || SCAF=$(ls "$LAB"/data/*/brief.md 2>/dev/null | head -1)
python3 - "$SCAF" "$B" <<'PY'
import sys
src=open(sys.argv[1]).read()
src=src.replace("{TASK}", "Fix the pager off-by-one; root cause is the <= on line 40.\n<!-- dispatch-never-send:start -->\nCustomer SYNTHETIC-CUST-7781 reported it on their ledger export.\n<!-- dispatch-never-send:end -->\nExpected: one page per call.",1)
src=src.replace("{FIRSTMATE_SPEC}", "  <!-- dispatch-never-send:start -->\n### SYNTHETIC-PRIVATE-HEADING\nSYNTHETIC-PROJECT-CONSTRAINT applies.\n  <!-- dispatch-never-send:end -->\nKeep the change in pager.sh.",1)
open(sys.argv[2],"w").write(src)
PY
echo "(scaffold from fm-brief.sh: $SCAF; placeholders filled into $B)"
drive "S4 opt-in + canonical markers in an fm-brief.sh scaffold -> marked text stripped, rest sent" SYNTHETIC-CUST-7781 SYNTHETIC-PRIVATE-HEADING SYNTHETIC-PROJECT-CONSTRAINT dispatch-never-send
echo "local brief file on disk after the run still holds the marked text: $(grep -c SYNTHETIC-CUST-7781 "$B") marked line(s) still present"

# S5 whole-brief fallback (no task sections), marked heading
printf '%s\n' '# Task' 'Public pagination fix.' '<!-- dispatch-never-send:start -->' "## Captain's intent" 'SYNTHETIC-HIDDEN-TASK' '<!-- dispatch-never-send:end -->' > "$B"
drive "S5 whole-brief fallback with marked fake task heading -> hidden text never sent" SYNTHETIC-HIDDEN-TASK

# S6 markers, no list file
rm -f "$NS"
printf '%s\n' '# Task' 'Public task' '<!-- dispatch-never-send:start -->' 'SYNTHETIC-CUST-7781' '<!-- dispatch-never-send:end -->' > "$B"
drive "S6 markers but no list file -> whole request withheld" SYNTHETIC-CUST-7781

# S7 markers, literal-only list
printf '%s\n' '# Client names' 'Synthetic Client Ltd' > "$NS"
drive "S7 markers with literal-only list (no opt-in) -> withheld" SYNTHETIC-CUST-7781

# S8 near-miss markers with and without opt-in
for variant in unspaced recased; do
  case $variant in
    unspaced) s='<!--dispatch-never-send:start-->'; e='<!--dispatch-never-send:end-->';;
    recased) s='<!-- Dispatch-Never-Send:start -->'; e='<!-- Dispatch-Never-Send:end -->';;
  esac
  printf '%s\n' '# Task' 'Public task' "$s" 'SYNTHETIC-NEAR-MISS' "$e" > "$B"
  printf '%s\n' 'Synthetic Client Ltd' > "$NS"
  drive "S8a $variant markers, no opt-in -> withheld" SYNTHETIC-NEAR-MISS
  printf '%s\n' '# dispatch-never-send marked-sections' > "$NS"
  drive "S8b $variant markers, with opt-in -> withheld, not auto-corrected" SYNTHETIC-NEAR-MISS
done

# S9 malformed canonical markers with opt-in
printf '%s\n' '# dispatch-never-send marked-sections' > "$NS"
for kind in unclosed orphan nested inline typo; do
  case $kind in
    unclosed) printf '%s\n' 'Public' '<!-- dispatch-never-send:start -->' 'SYNTHETIC-BAD' > "$B";;
    orphan) printf '%s\n' 'SYNTHETIC-BAD' '<!-- dispatch-never-send:end -->' > "$B";;
    nested) printf '%s\n' '<!-- dispatch-never-send:start -->' '<!-- dispatch-never-send:start -->' 'SYNTHETIC-BAD' '<!-- dispatch-never-send:end -->' '<!-- dispatch-never-send:end -->' > "$B";;
    inline) printf '%s\n' 'Public <!-- dispatch-never-send:start --> SYNTHETIC-BAD <!-- dispatch-never-send:end -->' > "$B";;
    typo) printf '%s\n' '<!-- dispatch-never-send:begin -->' 'SYNTHETIC-BAD' '<!-- dispatch-never-send:end -->' > "$B";;
  esac
  drive "S9 $kind markers with opt-in -> withheld" SYNTHETIC-BAD
done

# S10 near-miss / removed directives
printf '%s\n' '# Task' 'Public task' '<!-- dispatch-never-send:start -->' 'SYNTHETIC-DIR-SECRET' '<!-- dispatch-never-send:end -->' > "$B"
for d in '#dispatch-never-send marked-sections' '# Dispatch-Never-Send marked-sections' '#   DISPATCH-NEVER-SEND marked-sections' '# dispatch-never-send marked-section' '# dispatch-never-send project: pager'; do
  printf '%s\n' "$d" > "$NS"
  drive "S10 directive '$d' -> invalid directive, withheld" SYNTHETIC-DIR-SECRET
done
printf '%s\n' '# dispatch-never-send project: pager' > "$NS"
printf '%s\n' '# Task' 'Public unmarked pager task' > "$B"
drive "S10b removed project directive on an UNMARKED brief -> still refused as invalid (no whole-project mode)"

# S11 opt-in + canonical markers indented, inside a code fence
printf '%s\n' '# dispatch-never-send marked-sections' > "$NS"
printf '%s\n' '# Task' 'Public' '```' '   <!-- dispatch-never-send:start -->	' 'SYNTHETIC-FENCED' '<!-- dispatch-never-send:end -->' '```' 'More public' > "$B"
drive "S11 canonical markers with surrounding whitespace inside a code fence -> stripped" SYNTHETIC-FENCED
echo "lab removed on exit: $LAB"
