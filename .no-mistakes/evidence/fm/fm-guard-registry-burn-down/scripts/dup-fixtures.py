#!/usr/bin/env python3
"""Mutate a fixture copy of bin/fm-spawn.sh. mode=move | insert-new | insert-same-block."""
import sys
path, mode = sys.argv[1], sys.argv[2]
L = open(path).read().split('\n')
def find(prefix, start=0):
    for i in range(start, len(L)):
        if L[i].strip().startswith(prefix): return i
    raise SystemExit('not found: ' + prefix)
if mode == 'move':
    # Cut the 2616 admission block (4 lines) and paste it above the 1490 record_present block.
    a = find('fm_backlog_relaunch_admission "$CONFIG"')
    block = L[a:a+4]; del L[a:a+4]
    b = find('fm_backlog_record_present "$policy_meta"')
    L[b:b] = block
elif mode == 'insert-new':
    # A brand-new identical refusal under a new, unowned block opener.
    b = find('fm_backlog_record_present "$policy_meta"')
    L[b:b] = ['    fm_brand_new_check "$policy_meta" || {',
              '      echo "error: --relaunch refused: $FM_BACKLOG_TRANSITION_ERROR" >&2',
              '      exit 1', '    }']
elif mode == 'insert-same-block':
    # A third identical refusal inside an owned fm_backlog_record_present block.
    b = find('fm_backlog_record_present "$policy_meta"')
    L[b:b] = ['    fm_backlog_record_present "$other_meta" "task record" "$STATE" || {',
              '      echo "error: --relaunch refused: $FM_BACKLOG_TRANSITION_ERROR" >&2',
              '      exit 1', '    }']
open(path, 'w').write('\n'.join(L))
