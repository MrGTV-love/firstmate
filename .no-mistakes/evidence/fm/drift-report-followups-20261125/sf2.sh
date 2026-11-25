#!/usr/bin/env bash
# driver.sh <tree>: drive the real bin/fm-control.sh relaunch (stubbed tmux session provider) in a throwaway home.
TREE=$1
. "$TREE/tests/fm-control-relaunch-helpers.sh"
. "$TREE/tests/fm-control-relaunch-slot-helpers.sh"
trap relaunch_cleanup EXIT
SHIM=$TMP_ROOT/shim; mkdir -p "$SHIM"
REALMV=$(command -v mv) REALPY=$(command -v python3)
say() { printf '\n===== %s =====\n' "$*"; }
id=lane
make_adopt_case live "$id" src
WT=$ADOPT_DIR/wt ST=$ADOPT_DIR/home/state F=$ST/$id.drift-report.txt
printf '*.log\n' >> "$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)"
for i in $(seq 1 25); do printf 'x\n' > "$WT/gen-$i.log"; done
printf 'own\n' > "$WT/docs.txt"
printf 'scratch\n' > "$WT/notes: sampled: draft.txt"
mkdir -p "$ST"; : > "$TMP_ROOT/earlier"
say "S4 relaunch whose temp cannot be removed after a failed write (SF2) — relaunch survives, complete report printed"
cat > "$SHIM/mv" <<SH
#!/bin/sh
case "\$*" in *drift-report.txt) "$REALMV" -f -- "\$3" "\$3.gone" 2>/dev/null; rm -f -- "\$3.gone"; mkdir -- "\$3"; echo "shim: temp turned into a directory, mv fails" >&2; exit 1 ;; esac
exec "$REALMV" "\$@"
SH
chmod +x "$SHIM/mv"
out=$(PATH="$SHIM:$PATH" run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -E '^relaunch drift report|sampled:|^  a relaunch|^error' | sed 's/^/  | /'
echo "printed uncertain,ignored lines: $(printf '%s\n' "$out" | grep -c '^  drift: uncertain,ignored ')"
echo "launched replacement (literal sent): $( [ -s "$ADOPT_DIR/fake/literal" ] && echo yes || echo no)"
echo "unremovable temps: $(cd "$ST" && find . -maxdepth 1 -type d -name '.lane.drift-report.??????' | wc -l | tr -d ' ')"
cmp -s "$F" "$TMP_ROOT/earlier" && echo "file unchanged from the earlier report: yes" || echo "file unchanged from the earlier report: NO"
printf '%s\n' "$out" | tail -n 3 | sed 's/^/  tail| /'
for d in "$ST"/.lane.drift-report.??????; do [ -d "$d" ] && rmdir "$d"; done
