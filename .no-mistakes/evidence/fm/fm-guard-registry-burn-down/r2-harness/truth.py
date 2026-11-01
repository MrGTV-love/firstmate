"""Ground truth by execution: does each function's deny call reach the module wrapper?

Replaces subprocess with an in-memory stub, so nothing is spawned.
Prints {label: true|false} per test function, or the SyntaxError.
"""
import contextlib
import inspect
import io
import json
import sys
import types

path = sys.argv[1]
src = open(path).read()
calls = []
fake = types.ModuleType('subprocess')
fake.run = lambda argv, **k: calls.append(argv[1])
sys.modules['subprocess'] = fake
ns = {'__name__': 'fx'}
try:
    exec(compile(src, path, 'exec'), ns)
except SyntaxError as e:
    print(json.dumps({'syntax_error': str(e)}))
    sys.exit(0)
out = {}


def run(label, fn):
    before = len(calls)
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            r = fn([7], [7])
        if inspect.iscoroutine(r):
            try:
                r.send(None)
            except StopIteration:
                pass
    except Exception:
        pass
    out[label] = any(c == label for c in calls[before:])


for name, obj in list(ns.items()):
    if inspect.isfunction(obj) and name != 'record':
        run(name.split('_')[0].upper(), obj)
    elif inspect.isclass(obj) and obj.__module__ == 'fx':
        run(name, lambda o, d, c=obj: c().method(o, d))
print(json.dumps(out, sort_keys=True))
