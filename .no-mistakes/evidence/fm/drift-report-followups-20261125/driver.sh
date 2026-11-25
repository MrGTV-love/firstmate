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

say "S1 relaunch with 25 ignored paths (sampled report) — fm-control.sh $id relaunch"
out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -E '^relaunch drift report|^  (drift|sampled|limitation|a relaunch)' | sed 's/^/  | /'
echo "printed uncertain,ignored lines: $(printf '%s\n' "$out" | grep -c '^  drift: uncertain,ignored ')"
echo "file: $F mode=$(python3 -c 'import os,sys;print(oct(os.stat(sys.argv[1]).st_mode&0o777))' "$F") ignored-lines-in-file=$(grep -c '^  drift: uncertain,ignored ' "$F")"
printf '%s\n' "$out" > "$TMP_ROOT/out-sampled"

say "S2 second relaunch after removing 10 logs — a successful write replaces the file"
for i in $(seq 16 25); do rm "$WT/gen-$i.log"; done
out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -E '^relaunch drift report|sampled:' | sed 's/^/  | /'
echo "file header: $(head -n1 "$F")"; echo "ignored-lines-in-file=$(grep -c '^  drift: uncertain,ignored ' "$F")"
cp "$F" "$TMP_ROOT/earlier"

say "S3 relaunch whose report write fails (mv onto the report refused) — earlier file kept, complete report printed"
for i in $(seq 16 25); do printf 'x\n' > "$WT/gen-$i.log"; done
cat > "$SHIM/mv" <<SH
#!/bin/sh
case "\$*" in *drift-report.txt) echo "shim: refusing mv onto the drift report" >&2; exit 1 ;; esac
exec "$REALMV" "\$@"
SH
chmod +x "$SHIM/mv"
out=$(PATH="$SHIM:$PATH" run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -E '^relaunch drift report|sampled:' | sed 's/^/  | /'
echo "printed uncertain,ignored lines: $(printf '%s\n' "$out" | grep -c '^  drift: uncertain,ignored ')"
cmp -s "$F" "$TMP_ROOT/earlier" && echo "file unchanged from the earlier report: yes" || echo "file unchanged from the earlier report: NO"
echo "temps left: $(ls -A "$ST" | grep -c '^\.lane\.drift-report\.')"

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

say "S5 relaunch whose report cannot be produced — the file is replaced with its one-line reason"
FB=$ADOPT_DIR/fakebin; "$REALMV" "$FB/python3" "$FB/python3.fixture"
cat > "$FB/python3" <<SH
#!/bin/sh
if [ "\$1" = -c ] && printf '%s' "\$2" | grep -q 'drift-count'; then echo "error: simulated report failure" >&2; exit 1; fi
exec "$FB/python3.fixture" "\$@"
SH
chmod +x "$FB/python3"; rm -f "$SHIM/mv"
out=$(PATH="$SHIM:$PATH" run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -E '^relaunch drift report' | sed 's/^/  | /'
echo "file lines: $(wc -l < "$F" | tr -d ' ')"; echo "file: $(cat "$F")"
"$REALMV" -f "$FB/python3.fixture" "$FB/python3"

say "S6 complete report whose path holds ': sampled: ' (no STATE sample) — produced by fm-control for session-end"
for i in $(seq 1 25); do rm -f "$WT/gen-$i.log"; done
out=$(run_adopt_control "$ADOPT_DIR" "$id"); rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -E '^relaunch drift report|^  (drift|sampled)' | sed 's/^/  | /'
printf '%s\n' "$out" > "$TMP_ROOT/out-marker"
mkdir -p "$KEEP"; cp "$TMP_ROOT/out-sampled" "$TMP_ROOT/out-marker" "$KEEP/"

say "S7 skip-worktree names with a space, a newline and a backslash, changed and unchanged (SF5)"
make_adopt_case live7 lane7 src
WT7=$ADOPT_DIR/wt
for f in 'docs/sp ace' 'docs/sp same' $'docs/new\nline' $'docs/new\nsame' 'docs/back\slash' 'docs/back\same'; do
  mkdir -p "$WT7/docs"; printf 'unusual name\n' > "$WT7/$f.txt"; done
git -C "$WT7" add -A && git -C "$WT7" -c user.name=T -c user.email=t@example.invalid commit -qm 'unusual names'
nb=$(git -C "$WT7" rev-parse HEAD)
git -C "$WT7" update-ref refs/remotes/origin/main "$nb"
sed -i '' "s/^slot_base_sha=.*/slot_base_sha=$nb/" "$ADOPT_META"
python3 - "$ADOPT_MANIFEST" "$nb" <<'PY'
import json,sys; p,b=sys.argv[1:]; d=json.load(open(p)); d["base_sha"]=b; json.dump(d,open(p,"w"),sort_keys=True)
PY
git -C "$WT7" update-index --skip-worktree 'docs/sp ace.txt' 'docs/sp same.txt' $'docs/new\nline.txt' $'docs/new\nsame.txt' 'docs/back\slash.txt' 'docs/back\same.txt'
for f in 'docs/sp ace' $'docs/new\nline' 'docs/back\slash'; do printf 'unusual name, changed\n' > "$WT7/$f.txt"; done
echo "git status --porcelain (hidden): [$(git -C "$WT7" status --porcelain)]"
echo "skip-worktree entries: $(git -C "$WT7" ls-files -v | grep -c '^S ')"
out=$(run_adopt_control "$ADOPT_DIR" lane7); rc=$?
echo "exit=$rc"; printf '%s\n' "$out" | grep -E '^relaunch drift report|^  drift' | sort -u | sed 's/^/  | /'
