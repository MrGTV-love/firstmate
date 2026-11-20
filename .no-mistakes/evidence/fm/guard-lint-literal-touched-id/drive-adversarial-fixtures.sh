#!/usr/bin/env bash
# drive.sh <lint-script> <workdir> : runs adversarial new-or-touched scenarios against fixture git roots
set -u
LINT=$1; W=$2
mkdir -p "$W"
gitc() { git -C "$1" -c user.email=t@example.invalid -c user.name=t "${@:2}"; }
fixture() {  # <dir> <guards-json-array>
  local d=$1
  mkdir -p "$d/docs/guards" "$d/bin" "$d/tests"
  : >"$d/bin/gguard.sh"; : >"$d/tests/gguard.test.sh"
  jq -n --argjson g "$2" '{schema_version:1,system:"firstmate",audited:1,excluded:[],guards:$g}' >"$d/docs/guards/registry.json"
  printf '{"schema_version":1,"allowed":[]}\n' >"$d/docs/guards/lint-allowlist.json"
  printf '[]\n' >"$d/docs/guards/retired.json"
  git -C "$d" init -q; gitc "$d" add -A; gitc "$d" commit -qm base
}
row() {  # <id> <invariant> <fail_direction>
  jq -nc --arg id "$1" --arg inv "$2" --arg fd "$3" '{id:$id,owner:"bin/gguard.sh",invariant:$inv,layer:"runtime-block",source:"a fixture source",trigger:"a fixture trigger",decision:"deny",fail_direction:$fd,remedy:"bin/gguard.sh --clear <id>",budget:1,telemetry:"state/guard-events.jsonl",test:"tests/gguard.test.sh",tier:"C",harm:"reversible",exemptions:[]}'
}
mut() { jq "$2" "$1/docs/guards/registry.json" >"$1/r.tmp" && mv "$1/r.tmp" "$1/docs/guards/registry.json"; }
run() {  # <name> <dir> [extra env...]
  local name=$1 d=$2; shift 2
  local log="$W/$name.events.jsonl" rc=0 out
  out=$(env -u FM_TASK_ID FM_HOME="$W/nohome-$name" FM_GUARD_EVENT_LOG="$log" "$@" "$LINT" --root "$d" --mode new-or-touched --base HEAD 2>&1) || rc=$?
  echo "=== $name"
  echo "exit=$rc"
  printf '%s\n' "$out" | grep -E '^(VIOLATION|error|LINT_SUMMARY)' | sed 's/^/  /'
  if [ -s "$log" ]; then jq -c '{guard,decision,source_ok,actor,base}' "$log" | sed 's/^/  event: /'; else echo "  event: (none)"; fi
}

# A: numeric-looking ids. Untouched 1e1 carries debt; only 10 is edited.
A=$W/A; fixture "$A" "[$(row 1e1 'inv one' unspecified),$(row 10 'inv two' closed)]"
mut "$A" '(.guards[] | select(.id=="10") | .source) += " edited"'
run A_numeric_untouched_1e1_edit_10 "$A"

# B: backslash id. An added guard g\tx carries a finding (literal backslash, not a tab).
B=$W/B; fixture "$B" "[$(row gguard 'inv one' closed)]"
mut "$B" ".guards += [$(row 'g\tx' 'inv two' unspecified)]"
run B_backslash_id_added_with_finding "$B"

# C: reorder rows and keys only; untouched gbad carries debt.
C=$W/C; fixture "$C" "[$(row gbad 'inv one' unspecified),$(row gok 'inv two' closed)]"
mut "$C" '.guards |= (reverse | map(to_entries | reverse | from_entries))'
run C_reorder_rows_and_keys_only "$C"

# D: an exact duplicate row of an untouched offending-free guard is added.
D=$W/D; fixture "$D" "[$(row gdup 'inv one' closed)]"
mut "$D" '.guards += [.guards[0]]'
run D_exact_duplicate_row_added "$D"

# E: current registry guards is not an array of objects (unreadable current).
E=$W/E; fixture "$E" "[$(row gguard 'inv one' closed)]"
mut "$E" '.guards = ["unreadable"]'
run E_unreadable_current_guards "$E"

# F: base registry blob unreadable for comparison.
F=$W/F; mkdir -p "$F"; fixture "$F" '["unreadable"]'
mut "$F" ".guards = [$(row gguard 'inv one' closed)]"
run F_unreadable_base_guards "$F"

# G: gate actor recorded; plus unavailable sink keeps the verdict.
G=$W/G; fixture "$G" "[$(row gguard 'inv one' closed)]"
mut "$G" ".guards += [$(row gnew 'inv two' unspecified)]"
run G_gate_actor_deny "$G" FM_GUARD_LINT_EVENT_ACTOR=gate
: >"$W/plainfile"
rc=0; env -u FM_TASK_ID FM_HOME="$W/nohome-G2" FM_GUARD_EVENT_LOG="$W/plainfile/x.jsonl" "$LINT" --root "$G" --mode new-or-touched --base HEAD >/dev/null 2>&1 || rc=$?
echo "=== G2_unavailable_sink_same_refusal"; echo "exit=$rc"
echo "  nohome dirs created: $(ls -d "$W"/nohome-* 2>/dev/null | wc -l | tr -d ' ')"
