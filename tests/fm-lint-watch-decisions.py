#!/usr/bin/env python3
"""Decision checks for bin/fm-lint-cache.pl's resident watch, gate and signal helper.

Each check takes a named piece of bin/fm-lint-cache.pl (a sub or an embedded
program) out of the source and runs it on synthetic input, in a foreground perl or
python, or reads the source text. Nothing here starts a lint, a ShellCheck, a
watch, a gate or any background process, and nothing is signalled: the signal
program runs with its send calls replaced by a recorder.

Usage: fm-lint-watch-decisions.py [<repo root>]
Prints one "ok - <case>" or "not ok - <case>: <detail>" line per case and exits 1
when any case fails.
"""
import os
import re
import subprocess
import sys
import tempfile
import time

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), '..'))
SOURCE_PATH = os.path.join(ROOT, 'bin', 'fm-lint-cache.pl')
SOURCE = open(SOURCE_PATH).read()
FAILED = []


def report(name, ok, detail=''):
    if ok:
        print('ok - ' + name)
    else:
        FAILED.append(name)
        print('not ok - %s: %s' % (name, detail))


def perl_sub(name):
    match = re.search(r'^sub %s \{\n.*?^\}\n' % re.escape(name), SOURCE, re.S | re.M)
    return match.group(0) if match else None


def embedded(variable):
    match = re.search(r'my \$%s = <<\'PYTHON\';\n(.*?)\nPYTHON\n' % re.escape(variable), SOURCE, re.S)
    return match.group(1) if match else None


def run_perl(program, *args):
    result = subprocess.run(['perl', '-e', 'use strict; use warnings;\n' + program, '--', *args],
                            capture_output=True, text=True)
    return result.returncode, result.stdout, result.stderr


# F3: any miss followed by a later tick fails the root; only a miss on the last tick
# is exempt. Then the exit status: 96 before 98.
def check_unmeasured_and_exit():
    unmeasured, exit_rule = perl_sub('fm_watch_unmeasured'), perl_sub('fm_watch_exit')
    if not unmeasured or not exit_rule:
        report('F3 the tick rule and the exit rule are named subs', False, 'fm_watch_unmeasured or fm_watch_exit is missing')
        return
    cases = [
        ('m s', 1, 'a miss at t=1 then a sample at t=2 (reaped at 2.2)'),
        ('s m s s', 1, 'a miss in the middle'),
        ('m m', 1, 'two misses, only the last exempt'),
        ('s s m', 0, 'a miss on the last tick only (the root\'s own exit)'),
        ('s s', 0, 'samples only'),
        ('', 0, 'no tick at all'),
    ]
    for ticks, want, label in cases:
        rc, out, err = run_perl(unmeasured + 'print fm_watch_unmeasured(split / /, $ARGV[0]), "\\n";', ticks)
        report('F3 %s -> unmeasured %d' % (label, want), rc == 0 and out.strip() == str(want), out + err)
    statuses = [
        ('unmeasured => 1, status => 0', 96, 'a short loss with a successful command'),
        ('unmeasured => 1, over => 1', 96, 'a short loss then over the cap'),
        ('warned => 1, over => 1', 96, 'every reader lost then over the cap'),
        ('escaped => 1, over => 1', 96, 'a counted process outside the group outlived the root'),
        ('unpublished => 1, status => 0', 96, 'a sample that could not be published'),
        ('over => 1', 98, 'measured throughout and over the cap'),
        ('signal => 15', 143, 'ended on TERM'),
        ('status => 256', 1, 'the command\'s own status'),
        ('status => 0', 0, 'a clean measured run'),
    ]
    for fields, want, label in statuses:
        rc, out, err = run_perl(exit_rule + 'print fm_watch_exit(%s), "\\n";' % fields)
        report('F3 exit for %s is %d' % (label, want), rc == 0 and out.strip() == str(want), out + err)
    # The watch uses these subs for its own end, and records each tick.
    report('F3 the watch exits through fm_watch_exit with fm_watch_unmeasured',
           'exit fm_watch_exit(' in SOURCE and '$unmeasured = fm_watch_unmeasured(@ticks);' in SOURCE
           and "push @ticks, 'm';" in SOURCE and "push @ticks, 's';" in SOURCE, 'the watch does not use the named rules')


# F2: the measurement record holds only a successful sample's time.
def check_health_record():
    subs = [perl_sub(n) for n in ('fm_health_publish', 'fm_health_invalidate', 'fm_health_fresh')]
    if not all(subs):
        report('F2 the record subs are named', False, 'a fm_health_* sub is missing')
        return
    prelude = ''.join(subs)
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, 'slot.1.peak.health')
        now = time.time()

        def fresh(content):
            if content is None:
                if os.path.exists(path):
                    os.unlink(path)
            else:
                with open(path, 'w') as handle:
                    handle.write(content)
            rc, out, err = run_perl(prelude + 'print fm_health_fresh($ARGV[0], $ARGV[1]), "\\n";', path, '%.6f' % now)
            return out.strip() if rc == 0 else 'error ' + err

        report('F2 no record is not proof', fresh(None) == '0')
        report('F2 an empty record is not proof (even with a fresh file time)', fresh('') == '0')
        report('F2 an invalidated record is not proof', fresh('failed a sample was missed\n') == '0')
        report('F2 a sample 6 s old is not proof', fresh('sample %.6f\n' % (now - 6)) == '0')
        report('F2 a sample from the future is not proof', fresh('sample %.6f\n' % (now + 5)) == '0')
        report('F2 a malformed record is not proof', fresh('sample soon\n') == '0')
        report('F2 a sample 1 s old is proof', fresh('sample %.6f\n' % (now - 1)) == '1')
        os.unlink(path)
        rc, out, err = run_perl(prelude + 'print fm_health_publish($ARGV[0], $ARGV[1]) ? "published\\n" : "failed\\n"; '
                                'print fm_health_fresh($ARGV[0], $ARGV[1]), "\\n"; '
                                'print fm_health_invalidate($ARGV[0], "a sample was missed") ? "invalidated\\n" : "kept\\n"; '
                                'print fm_health_fresh($ARGV[0], $ARGV[1]), "\\n";', path, '%.6f' % now)
        report('F2 a published sample is proof, and an invalidated one is not at once',
               rc == 0 and out.split() == ['published', '1', 'invalidated', '0'], out + err)
        report('F2 an invalidated record says it failed', open(path).read().startswith('failed '), open(path).read())
        # A failed publication: the directory cannot take a new file. The publish
        # reports failure; the invalidation still rewrites the existing record in place.
        with open(path, 'w') as handle:
            handle.write('sample %.6f\n' % now)
        os.chmod(work, 0o500)
        try:
            rc, out, err = run_perl(prelude + 'print fm_health_publish($ARGV[0], $ARGV[1]) ? "published\\n" : "failed\\n"; '
                                    'print fm_health_invalidate($ARGV[0], "the sample could not be published") ? "invalidated\\n" : "kept\\n"; '
                                    'print fm_health_fresh($ARGV[0], $ARGV[1]), "\\n";', path, '%.6f' % now)
        finally:
            os.chmod(work, 0o700)
        report('F2 a failed publication is reported and the record is invalidated in place at once',
               rc == 0 and out.split() == ['failed', 'invalidated', '0'], out + err)
    gate_block = SOURCE[SOURCE.index("if (($ARGV[0] // '') eq 'gate'"):SOURCE.index('# Private resident-memory watch.')]
    report('F2 the gate judges records only through fm_health_fresh', 'fm_health_fresh("$peak.health"' in gate_block
           and '(stat _)[9]' not in gate_block, 'the gate still reads a file time')
    report('F2 the gate creates no record at admission, it removes an old one',
           "open($health, '>', \"$peak_file.health\")" not in gate_block
           and 'unlink("$peak_file.health")' in gate_block, 'the gate still creates the record')
    watch_block = SOURCE[SOURCE.index('# Private resident-memory watch.'):]
    miss_at = watch_block.index("push @ticks, 'm';")
    report('F2 the watch invalidates the record at its first miss',
           "$invalidate->('a sample was missed');" in watch_block[miss_at:miss_at + 200], 'no invalidation at the miss')
    report('F2 a failed publication fails the root and invalidates the record',
           '$unpublished = 1;' in watch_block and "$invalidate->('the sample could not be published');" in watch_block,
           'the failed-publication branch is missing')


# F1: a reader reply is counted only when every member it names still has the
# identity the reply gave; the table fallback keeps start times only to the second.
FAKE_FMPROC = '''
import os
IDS = {}
for item in os.environ.get("FM_FAKE_IDS", "").split(","):
    if item:
        pid, sec, usec = item.split(":")
        IDS[int(pid)] = (int(sec), int(usec))
def kinfo(pid):
    if os.environ.get("FM_FAKE_UNREADABLE") == str(pid):
        raise OSError("unreadable")
    if pid not in IDS:
        raise LookupError(pid)
    return IDS[pid]
def process_identity(record):
    return record
'''


def check_reply_binding():
    program = embedded('verify_members_py')
    if not program:
        report('F1 the reply check is a named program', False, 'verify_members_py is missing')
        return
    with tempfile.TemporaryDirectory() as work:
        module = os.path.join(work, 'fmproc.py')
        with open(module, 'w') as handle:
            handle.write(FAKE_FMPROC)

        def verify(ids, items, unreadable=''):
            env = dict(os.environ, FM_FAKE_IDS=ids, FM_FAKE_UNREADABLE=unreadable)
            result = subprocess.run([sys.executable, '-I', '-c', program, module, *items], capture_output=True, text=True, env=env)
            return result.stdout.strip() if result.returncode == 0 else 'error ' + result.stderr

        report('F1 members whose identity is unchanged are bound', verify('10:100:1,43:100:5', ['10:100:1', '43:100:5']) == 'same')
        report('F1 a member recycled after the census (another start time) makes the sample unknown',
               verify('10:100:1,43:100:6', ['10:100:1', '43:100:5']) == 'unknown')
        report('F1 a member recycled in the same second (another microsecond) makes the sample unknown',
               verify('43:100:2', ['43:100:1']) == 'unknown')
        report('F1 a member that has ended makes the sample unknown', verify('10:100:1', ['10:100:1', '43:100:5']) == 'unknown')
        report('F1 a member whose identity cannot be read makes the sample unknown',
               verify('43:100:5', ['43:100:5'], unreadable='43') == 'unknown')
        report('F1 a reply naming no member needs no check', verify('', []) == 'same')
    watch_block = SOURCE[SOURCE.index('# Private resident-memory watch.'):]
    verify_at = watch_block.find('return undef unless $verify_members->(%reply);')
    adopt_at = watch_block.find('%known = %reply;')
    report('F1 every reply is checked before its members are adopted or its size counted',
           0 <= verify_at < adopt_at, 'the reply is adopted before it is checked')
    report('F1 a reply without a whole member list is unknown',
           "return undef unless ref $named eq 'ARRAY'" in watch_block, 'a reply without members is still counted')
    fallback = re.search(r'\n(        \$next\{\$_\} = \[\$table->\{\$_\}\[3\], undef\] for keys %selected;\n)', SOURCE)
    if not fallback:
        report('F1 the table fallback keeps a selected member to the second only', False, 'the fallback line is missing')
    else:
        setup = 'my %selected = (43 => 1); my %known = (43 => [100, 1]); my %next; my $table = { 43 => [1, 40, 1024, 100] };\n'
        rc, out, err = run_perl(setup + fallback.group(1) + 'print join(":", map { defined $_ ? $_ : "-" } @{$next{43}}), "\\n";')
        report('F1 the table fallback keeps a selected member to the second only (never an earlier microsecond)',
               rc == 0 and out.strip() == '100:-', out + err)


# F5: the signal program sends only to a process group.
def check_group_signals():
    program = embedded('IDENTITY_SIGNAL_PY')
    if program is None:
        match = re.search(r"my \$IDENTITY_SIGNAL_PY = <<'PYTHON';\n(.*?)\nPYTHON\n", SOURCE, re.S)
        program = match.group(1) if match else None
    if not program:
        report('F5 the signal program is named', False, 'IDENTITY_SIGNAL_PY is missing')
        return
    report('F5 the signal program has no per-process send', 'os.kill(' not in program and program.count('os.killpg(') == 1,
           'a per-process send remains')
    recorder = ('import os, sys\nSENT = []\n'
                'os.kill = lambda pid, sig: (_ for _ in ()).throw(AssertionError("per-process send"))\n'
                'os.killpg = lambda pid, sig: SENT.append((pid, sig))\n'
                'program = sys.argv.pop(1)\n'
                'try:\n    exec(compile(program, "signal", "exec"))\n'
                'finally:\n    sys.stderr.write("SENT %r\\n" % SENT)\n')
    result = subprocess.run([sys.executable, '-I', '-c', recorder, program, 'x', 'STOP', 'group:999999990', '123:1:2', 'under:1:123', '77'],
                            capture_output=True, text=True)
    lines = result.stdout.split('\n')
    report('F5 a group item is sent as a group and every per-process item is refused',
           result.returncode == 0 and lines[:4] == ['sent 999999990', 'refused 0', 'refused 0', 'refused 0']
           and 'SENT [(999999990,' in result.stderr, result.stdout + result.stderr)
    signal_mode = SOURCE[SOURCE.index("# Private mode: perl fm-lint-cache.pl signal"):SOURCE.index('my $PROCESS_STATE_PY')]
    report('F5 the signal mode accepts only group items', r"!grep { !/\Agroup:[0-9]+\z/ } @items" in signal_mode,
           'the signal mode accepts another form')
    watch_block = SOURCE[SOURCE.index('# Private resident-memory watch.'):SOURCE.index("my ($mode, $root, @args) = @ARGV;")]
    sends = re.findall(r"fm_signal_items\('[A-Z]+', ([^)]*)\)", watch_block)
    report('F5 the watch signals only its own root\'s group', sends and all(item == '"group:$child"' for item in sends)
           and 'under:' not in SOURCE, repr(sends) + (' and an under:<gate>:<pid> route remains' if 'under:' in SOURCE else ''))


# Main 1862: no analysis result is reused.
def check_no_reuse():
    report('Main 1862 the success cache and the delegate sampler are gone',
           'sub fingerprint' not in SOURCE and '.passed' not in SOURCE and 'DELEGATE_SAMPLER_PY' not in SOURCE
           and 'cache hit' not in SOURCE, 'a reuse path remains')
    check_at = SOURCE.index("my ($mode, $root, @args) = @ARGV;")
    report('Main 1862 the check mode takes no cache directory', "$cache" not in SOURCE[check_at:], 'a cache directory is still read')
    lint = open(os.path.join(ROOT, 'bin', 'fm-lint.sh')).read()
    report('Main 1862 the lint passes no cache and reads no cache setting',
           'FM_LINT_INTERNAL_CACHE' not in lint and 'CACHE_DIR=' not in lint and 'SHELLCHECK_DELEGATE' not in lint,
           'the lint still passes or reads a cache setting')


for check in (check_unmeasured_and_exit, check_health_record, check_reply_binding, check_group_signals, check_no_reuse):
    try:
        check()
    except Exception as error:  # a missing anchor in an old tree is a failure, not a crash
        report(check.__name__, False, '%s: %s' % (type(error).__name__, error))
print('%d failed' % len(FAILED))
sys.exit(1 if FAILED else 0)
