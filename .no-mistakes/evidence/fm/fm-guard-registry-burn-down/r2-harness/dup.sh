#!/usr/bin/env bash
# Duplicate-ownership and allowlist-growth scenarios on a disposable copy of HEAD.
# usage: dup.sh <worktree>
set -u
W=$1; F=/tmp/fm-r2fx-9566; C=$F/copy-$$
mkdir -p "$C" && git -C "$W" archive HEAD | tar -x -C "$C"
git -C "$C" init -q && git -C "$C" -c user.email=t@t -c user.name=t add -A && git -C "$C" -c user.email=t@t -c user.name=t commit -qm base
BASE=$(git -C "$C" rev-parse HEAD)
owners() {
  python3 -I "$W/bin/fm-guard-sites.py" --root "$C" | python3 -I -c '
import json, sys
for s in json.load(sys.stdin)["sites"]:
    if s["file"] == "bin/fm-spawn.sh" and s["key"].startswith("site:bin/fm-spawn.sh:72505e7e0e"):
        print("line %-5d %-38s -> %s" % (s["line"], s["key"], s["entry"]))'
}
lint() { "$W/bin/fm-guard-lint.sh" --root "$C" --mode enforce 2>&1 | grep -E "^(INFO inventory|VIOLATION|LINT_SUMMARY)"; echo "lint exit=${PIPESTATUS[0]}"; }
S=$C/bin/fm-spawn.sh

echo "### 0. Unmodified HEAD copy: owners of the identical refusal lines"
owners; lint

echo; echo "### 1. MOVE: cut the fm_backlog_relaunch_admission block and paste it above the first fm_backlog_record_present block"
start=$(grep -n 'fm_backlog_relaunch_admission "$CONFIG" "$DATA" "$KIND" "$ID" "$RECONCILE_ONLY" || {' "$S" | head -1 | cut -d: -f1)
end=$((start + 3)); target=$(grep -n 'policy_meta="$STATE/${POS\[0\]}.meta"' "$S" | head -1 | cut -d: -f1)
sed -n "${start},${end}p" "$S" > $F/block.txt; cat $F/block.txt
awk -v s="$start" -v e="$end" -v t="$target" -v bf="$F/block.txt" '
  NR==t { while ((getline l < bf) > 0) print l }
  NR<s || NR>e { print }' "$S" > $F/moved.sh && cat $F/moved.sh > "$S"
owners; lint

echo; echo "### 2. INSERT: a new identical refusal in a new, unmapped block near the top of the file"
cp "$S" $F/moved-keep.sh
awk 'NR==1000 { print "fm_new_unmapped_gate || {"; print "  echo \"error: --relaunch refused: $FM_BACKLOG_TRANSITION_ERROR\" >&2"; print "  exit 1"; print "}" } { print }' $F/moved-keep.sh > "$S"
owners; lint

echo; echo "### 3. INSERT into a mapped block: restore, then add a second identical line inside the second fm_backlog_record_present block"
git -C "$C" checkout -q -- bin/fm-spawn.sh
second=$(grep -n 'relaunch refused: \$FM_BACKLOG_TRANSITION_ERROR' "$S" | sed -n 2p | cut -d: -f1)
awk -v n="$second" '{ print } NR==n { print }' "$S" > $F/ins.sh && cat $F/ins.sh > "$S"
sed -n "$((second-2)),$((second+2))p" "$S"
owners; lint

echo; echo "### 4. ALLOWLIST GROWTH: a new identical unmapped refusal plus a new S1 allowlist entry for it (ratchet vs base copy)"
git -C "$C" checkout -q -- bin/fm-spawn.sh
awk 'NR==1000 { print "fm_new_unmapped_gate || {"; print "  echo \"error: --relaunch refused: $FM_BACKLOG_TRANSITION_ERROR\" >&2"; print "  exit 1"; print "}" } { print }' "$S" > $F/grow.sh && cat $F/grow.sh > "$S"
python3 -I - "$C/docs/guards/lint-allowlist.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
template = next(r for r in d['allowed'] if r['rule'] == 'S1')
new = dict(template); new['id'] = 'site:bin/fm-spawn.sh:72505e7e0e'
d['allowed'].append(new); json.dump(d, open(p, 'w'), indent=2)
print('allowlist entries now', len(d['allowed']))
PY
"$W/bin/fm-guard-lint.sh" --root "$C" --mode new-or-touched --base "$BASE" 2>&1 | grep -E "^(VIOLATION|LINT_SUMMARY)"; echo "lint exit=${PIPESTATUS[0]}"
