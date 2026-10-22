# revert-transport.py <in> <out>: swap the fixed file-backed stdin back to the
# pre-fix spawnSync `input:` pipe, keeping every other line (incl. the new mode).
import sys, re
s = open(sys.argv[1]).read()
start = s.index("  const label = `${registration.event}/${registration.target}/home=")
end = s.index("function silent(result, label)")
old = """  const result = spawnSync('/bin/bash', ['-c', registration.command], {
    cwd: home, env, input: JSON.stringify(payload), encoding: 'utf8', timeout: 15000,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null, `${registration.target} did not settle`);
  return result;
}
"""
open(sys.argv[2], 'w').write(s[:start] + old + s[end:])
