#!/usr/bin/env bash
set -eu
set -o pipefail
ROOT=$PWD
WRAP="$ROOT/bin/fm-proc-budget.sh"
FIX="$ROOT/.gate-proc-budget-validation"
parent_soft=$(ulimit -S -u)
parent_hard=$(ulimit -H -u)
count_before=$(ps -U "$(id -u)" -o pid= | wc -l)
printf 'parent soft=%s hard=%s; baseline user processes=%s\n' "$parent_soft" "$parent_hard" "$count_before"
for extra in 80 default; do
  if [ "$extra" = default ]; then args=(--); allowance=1500; else args=("$extra" --); allowance=$extra; fi
  limits=$("$WRAP" "${args[@]}" bash -c 'printf "%s %s\n" "$(ulimit -S -u)" "$(ulimit -H -u)"; python3 -c "import resource; print(\"descendant soft/hard=%s\" % (resource.getrlimit(resource.RLIMIT_NPROC),))"')
  printf 'extra=%s: %s\n' "$extra" "$limits"
  read -r soft hard <<< "$limits"
  [ "$soft" -eq "$hard" ] && [ "$soft" -lt "$parent_soft" ]
  count_after=$(ps -U "$(id -u)" -o pid= | wc -l)
  delta=$((soft - count_before))
  [ "$delta" -ge "$((allowance - 60))" ] && [ "$delta" -le "$((allowance + 60))" ]
  printf 'observed allowance=%s; user processes after=%s\n' "$delta" "$count_after"
done
bash -c 'export EXPECTED_PID=$$; exec "$1" 80 -- bash -c '\''printf "exec pid=%s expected=%s args=<%s>|<%s>\n" "$$" "$EXPECTED_PID" "$1" "$2"; [ "$$" = "$EXPECTED_PID" ]'\'' _ "a b" "c*"' _ "$WRAP"
"$WRAP" 80 -- bash -c 'exit 7' && rc=0 || rc=$?
printf 'child exit propagated=%s\n' "$rc"
[ "$rc" -eq 7 ]
"$WRAP" 120 -- bash -c '
  before=$(ulimit -S -u)
  printf "outer soft=%s hard=%s\n" "$before" "$(ulimit -H -u)"
  "$1" 1500 -- bash -c '\''printf "nested soft=%s hard=%s\n" "$(ulimit -S -u)" "$(ulimit -H -u)"; [ "$(ulimit -S -u)" = "$1" ]; if ulimit -S -u "$(( $1 + 1 ))" 2>/dev/null; then exit 1; else printf "raising sealed hard limit refused\n"; fi'\'' _ "$before"
' _ "$WRAP"
for extra in 0 01 -5 1.5 nope; do
  "$WRAP" "$extra" -- touch "$FIX/refused-command-ran" && rc=0 || rc=$?
  printf 'malformed extra=%s exit=%s command-ran=%s\n' "$extra" "$rc" "$([ -e "$FIX/refused-command-ran" ] && echo yes || echo no)"
  [ "$rc" -eq 2 ] && [ ! -e "$FIX/refused-command-ran" ]
done
mkdir -p "$FIX/failing-ps"
printf '#!/bin/sh\nexit 1\n' > "$FIX/failing-ps/ps"
chmod +x "$FIX/failing-ps/ps"
PATH="$FIX/failing-ps:$PATH" "$WRAP" -- touch "$FIX/refused-command-ran" && rc=0 || rc=$?
printf 'unreadable count exit=%s command-ran=%s\n' "$rc" "$([ -e "$FIX/refused-command-ran" ] && echo yes || echo no)"
[ "$rc" -eq 125 ] && [ ! -e "$FIX/refused-command-ran" ]
[ "$(ulimit -S -u)" = "$parent_soft" ] && [ "$(ulimit -H -u)" = "$parent_hard" ]
printf 'parent remains soft=%s hard=%s\n' "$(ulimit -S -u)" "$(ulimit -H -u)"
