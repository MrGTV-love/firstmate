"""Resolve every `site:<file>:<hash>[ within <text>]` ref in registry `source` fields
against real scanner output, and check each ref names only sites its citing entry owns.

usage: refs.py <scanner.py> <root>
`within` follows docs/guard-spec.md: a substring of the line that opens the site's
block (the nearest earlier code line indented less than the site).
"""
import json
import re
import subprocess
import sys

scanner, root = sys.argv[1], sys.argv[2]
scan = json.loads(subprocess.check_output([sys.executable, scanner, '--root', root]))
registry = json.load(open(root + '/docs/guards/registry.json'))
lines_cache = {}


def opener(rel, line):
    if rel not in lines_cache:
        lines_cache[rel] = open(root + '/' + rel).read().split('\n')
    lines = lines_cache[rel]
    text = lines[line - 1]
    indent = len(text) - len(text.lstrip())
    for n in range(line - 2, -1, -1):
        cand = lines[n]
        s = cand.strip()
        if not s or s.startswith('#'):
            continue
        if len(cand) - len(cand.lstrip()) < indent:
            return cand
    return ''


by_base = {}
for s in scan['sites']:
    by_base.setdefault(s['key'].split('~')[0], []).append(s)
ref_re = re.compile(r'site:([^\s,:]+):([0-9a-f]{10})(?: within ([^,;]+?))?(?=,|;|$|\s*\))')
total = bad = multi_owner = 0
for g in registry['guards']:
    for m in ref_re.finditer(g.get('source', '')):
        rel, h, within = m.group(1), m.group(2), m.group(3)
        total += 1
        group = by_base.get(f'site:{rel}:{h}', [])
        owners = {s['entry'] for s in group}
        if len(owners) > 1:
            multi_owner += 1
        chosen = [s for s in group if within is None or within.strip() in opener(rel, s['line'])]
        ok = bool(chosen) and all(s['entry'] == g['id'] for s in chosen)
        if not ok or len(owners) > 1:
            print(('ok   ' if ok else 'BAD  ') + f'{g["id"]}: {m.group(0)} -> '
                  + ', '.join(f'{s["line"]}:{s["entry"]}' for s in chosen) + f' (group owners: {sorted(map(str, owners))})')
        bad += not ok
print(f'refs={total} refs_into_multi_owner_groups={multi_owner} unresolved_or_foreign={bad}')
sys.exit(1 if bad else 0)
