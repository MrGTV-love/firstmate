#!/usr/bin/env bash
# Compare scanner E sites with execution ground truth, per interpreter, for a scanner file.
# usage: compare.sh <scanner.py> <label>
set -u
F=/tmp/fm-r2fx-9566
scanner=$1; tag=$2; R=${ROOT:-$F/root}
for py in /usr/bin/python3 python3.12 python3 python3.14; do
  v=$($py -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])')
  echo "== scanner=$tag  interpreter=$py Python $v"
  $py -I "$scanner" --root "$R" > "$F/out-$tag-$(basename $R)-$v.json" 2>"$F/err-$tag-$v.txt" || echo "scanner exit=$? $(cat "$F/err-$tag-$v.txt")"
  for file in ${FILES:-a b}; do
    truth=$($py -I "$F/truth.py" "$R/bin/$file.py")
    python3 -I - "$F/out-$tag-$(basename $R)-$v.json" "bin/$file.py" "$truth" "$R/bin/$file.py" <<'PY'
import json, re, sys
out, rel, truth, path = sys.argv[1], sys.argv[2], json.loads(sys.argv[3]), sys.argv[4]
if 'syntax_error' in truth:
    print(f'  {rel}: interpreter cannot parse this file ({truth["syntax_error"]}); skipped')
    sys.exit(0)
lines = open(path).read().split('\n')
found = {}
for s in json.load(open(out))['sites']:
    if s['file'] == rel and s['sig'] == 'E':
        m = re.search(r'"([RNMST]\d\d)"', lines[s['line'] - 1])
        if m:
            found[m.group(1)] = s['line']
bad = 0
for label in sorted(truth):
    reaches = truth[label]
    site = label in found
    ok = reaches == site
    bad += not ok
    print(f'  {label}: runtime reaches wrapper={str(reaches):5} scanner site={str(site):5} {"ok" if ok else "MISMATCH"}')
print(f'  {rel}: {len(truth)} cases, mismatches={bad}')
PY
  done
done
