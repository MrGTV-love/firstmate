# DD2 differential: same seeds and text through the real fm_task_inbox_write_idempotent
# on base and head. Compares rc, printed path, and the full record set byte for byte.
import os, subprocess, tempfile, hashlib, json, sys
BASE, HEAD = '/tmp/fm-val-base', '/tmp/fm-val-head'
HDR = 'schema=fm-task-inbox.v1\nat=2026-11-18T00:00:00Z\n'
def rec(body, ff=False):
    return HDR + ('delivery=fire-and-forget\n' if ff else '') + '--\n' + body
LONG = 'L' * 6000
CASES = [
 ('unhandled exact text prints unhandled path', [('0001.msg', rec('steer one\nline two'))], 'steer one\nline two', ''),
 ('handled exact text prints handled path', [('handled/0001.msg', rec('steer one\nline two'))], 'steer one\nline two', ''),
 ('near-miss: same first line, different tail writes new', [('handled/0001.msg', rec('shared first\nold tail'))], 'shared first\nnew tail', ''),
 ('first line with leading dash dedups', [('handled/0001.msg', rec('-- dash first\nbody'))], '-- dash first\nbody', ''),
 ('first line with leading dash near-miss writes new', [('handled/0001.msg', rec('-- dash first\nbody A'))], '-- dash first\nbody B', ''),
 ('regex characters in first line dedup', [('handled/0001.msg', rec('a.*[b]+(c)?^$\\|x\ntail'))], 'a.*[b]+(c)?^$\\|x\ntail', ''),
 ('regex characters: a pattern-like record does not match', [('handled/0001.msg', rec('a.*[b]+ other\ntail'))], 'a.*[b]+(c)?^$\\|x\ntail', ''),
 ('colon in first line dedups', [('0001.msg', rec('key: value: more\nx'))], 'key: value: more\nx', ''),
 ('6000-char first line dedups', [('handled/0001.msg', rec(LONG + '\nend'))], LONG + '\nend', ''),
 ('6000-char first line near-miss writes new', [('handled/0001.msg', rec(LONG + '\nend A'))], LONG + '\nend B', ''),
 ('leading blank lines dedup exact', [('handled/0001.msg', rec('\n\nreal first\nbody'))], '\n\nreal first\nbody', ''),
 ('leading blank lines vs record without them writes new', [('handled/0001.msg', rec('real first\nbody'))], '\n\nreal first\nbody', ''),
 ('multi-line exact dedup', [('handled/0001.msg', rec('l1\nl2\nl3\n'))], 'l1\nl2\nl3\n', ''),
 ('trailing newline differs writes new', [('handled/0001.msg', rec('x'))], 'x\n', ''),
 ('empty text vs empty record', [('handled/0001.msg', rec(''))], '', ''),
 ('empty text vs non-empty records writes new', [('handled/0001.msg', rec('something'))], '', ''),
 ('non-ASCII first line dedups', [('handled/0001.msg', rec('返信: ✓ café\nbody'))], '返信: ✓ café\nbody', ''),
 ('fire-and-forget text never dedups onto ordinary record', [('handled/0001.msg', rec('ff text'))], 'ff text', 'fire-and-forget'),
 ('ordinary text never dedups onto fire-and-forget record', [('handled/0001.msg', rec('ff text', ff=True))], 'ff text', ''),
 ('fire-and-forget dedups onto fire-and-forget record', [('handled/0001.msg', rec('ff text', ff=True))], 'ff text', 'fire-and-forget'),
 ('fire-and-forget unhandled dedup', [('0001.msg', rec('ff text', ff=True))], 'ff text', 'fire-and-forget'),
 ('ordinary unhandled and handled both present, unhandled wins by sort order', [('0001.msg', rec('dup')), ('handled/0002.msg', rec('dup'))], 'dup', ''),
 ('dangling unhandled name maps to its handled twin', [('0001.msg', rec('twin')), ('handled/0001.msg', rec('twin'))], 'twin', ''),
 ('20 mixed records, text matches record 13 only', [('%04d.msg' % i if i % 2 else 'handled/%04d.msg' % i, rec('other %d\nx' % i)) for i in range(1, 21) if i != 13] + [('handled/0013.msg', rec('match me\nend'))], 'match me\nend', ''),
]
def run(tree, seeds, text, mode):
    st = tempfile.mkdtemp(prefix='fm-val-dd2.', dir='/tmp')
    inbox = os.path.join(st, 't1.inbox')
    for rel, content in seeds:
        p = os.path.join(inbox, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, 'w').write(content)
    os.makedirs(os.path.join(inbox, 'handled'), exist_ok=True)
    env = dict(os.environ, FM_STATE_OVERRIDE=st)
    args = ['bash', '-c', '. "$1"; fm_task_inbox_write_idempotent "$2" t1 "$3" "$4"', '_', os.path.join(tree, 'bin/fm-task-inbox-lib.sh'), st, text, mode]
    q = subprocess.run(args, env=env, capture_output=True)
    printed = q.stdout.decode('utf-8', 'replace').replace(st + '/', '')
    recs = []
    for dp, dn, fn in os.walk(inbox):
        for f in fn:
            full = os.path.join(dp, f); rel = os.path.relpath(full, inbox)
            data = open(full, 'rb').read(); data = b'\n'.join(l for l in data.split(b'\n') if not l.startswith(b'at='))  # mask the write-time stamp
            recs.append((rel, hashlib.sha256(data).hexdigest()))
    recs.sort()
    out = {'rc': q.returncode, 'printed': printed, 'records': recs, 'stderr': q.stderr.decode('utf-8', 'replace')[:120]}
    subprocess.run(['rm', '-rf', st])
    return out
ok_all = True
for name, seeds, text, mode in CASES:
    b = run(BASE, seeds, text, mode); h = run(HEAD, seeds, text, mode)
    same = b == h
    ok_all = ok_all and same
    print(json.dumps({'case': name, 'identical': same, 'base_printed': b['printed'], 'head_printed': h['printed'], 'base_rc': b['rc'], 'head_rc': h['rc'], 'base_records': len(b['records']), 'head_records': len(h['records']), 'base_stderr': b['stderr'], 'head_stderr': h['stderr']}, ensure_ascii=False))
print('ALL-IDENTICAL' if ok_all else 'DIFFERENCES-FOUND')
