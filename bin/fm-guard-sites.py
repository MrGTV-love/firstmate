#!/usr/bin/env python3
"""fm-guard-sites.py - enumerate every refusal site in Firstmate's runtime code and
map each one to a guard registry entry.

bin/fm-guard-lint.sh is the only caller. It owns the verdicts; this helper owns the
discovery and the mapping, so the lint cannot validate only the entries it was handed.
docs/guard-spec.md "Refusal sites" owns the signature set and the mapping rule.

Usage:
  fm-guard-sites.py [--root DIR] [--registry PATH] [--touched-since REF]

Output is one JSON object on stdout:
  paths      the scanned files, relative to the root
  sites      one record per site: key, file, line, sig, text, entry, touched
  errors     mapping problems: rule, id, message
  helpers    the refusal helper names the scan derived from the code

Exit: 0 on success; 2 on a usage or environment error.
"""
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys

DEFAULT_DIRS = ('bin', '.claude', '.codex', '.cursor', '.dsh', '.grok', '.omp', '.opencode', '.pi')
SKIP_DIRS = {'tests', 'test', 'node_modules', '__pycache__', '.git', 'fixtures'}
CODE_EXT = {'.sh', '.bash', '.py', '.ts', '.js', '.mjs', '.pl', '.jq'}
HOOK_JSON_GLOBS = ('.codex/hooks.json', '.cursor/hooks.json', '.claude/settings.json')

# The character classes keep this file from matching its own signatures.
MARKER = re.compile(r'REFUS[E]D:')
WORD = re.compile(r'(?<![A-Za-z0-9_$.{/-])refus(?:e|es|ed|ing)(?![A-Za-z0-9_-]|\.sh)', re.I)
STRING = re.compile(r'"(?:[^"\\]|\\.)*"|\'[^\']*\'|`[^`]*`')
COMPARED = re.compile(r'(?:[=!]==?|\.(?:starts|ends)_?[wW]ith\(\s*\(?(?:\s*(?:' + STRING.pattern + r')\s*,)*)\s*$')
HELPER_WORD = 'refus' + 'e'
HELPER_EXACT = ('deny', 'block_stop')
DENY_DECISION = re.compile(r'decision\\?"?\s*[:=]\s*\\?["\'](?:deny|block)\\?["\']')
DENY_PERMISSION = re.compile(r'permissionDecisio[n].*deny')
DENY_BLOCK = re.compile(r'\bblock\s*:\s*true\s*,')
GUARD_EVENT = re.compile(r'(?:^|[\s"/(])(?P<cmd>fm-guard-event\.sh|fm_guard_event|guard_event)"?\s+(?=[a-z$"\'])')
DECISIONS = ('deny', 'warn', 'allow', 'error')
EXIT_TWO = re.compile(r'^(?:.*(?:&&|\|\|)\s*)?exit 2\s*$')
HEREDOC = re.compile(r'<<-?([\'"]?)([A-Z_][A-Z0-9_]*)\1')
SH_DEF = re.compile(r'^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{?')
PY_DEF = re.compile(r'^\s*(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(')
JS_DEF = re.compile(r'^\s*(?:export\s+)?(?:async\s+)?function\s+([A-Za-z_$][A-Za-z0-9_$]*)'
                    r'|^\s*(?:export\s+)?(?:const|let)\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*=\s*(?:async\s*)?\(')


def kind_of(path):
    ext = os.path.splitext(path)[1]
    if ext in ('.sh', '.bash'):
        return 'sh'
    if ext == '.py':
        return 'py'
    if ext in ('.ts', '.js', '.mjs'):
        return 'js'
    if ext in ('.pl', '.jq'):
        return 'sh'
    return 'other'


def read_lines(path):
    try:
        with open(path, errors='replace') as handle:
            return handle.read().split('\n')
    except OSError:
        return []


def shebang_kind(path):
    lines = read_lines(path)[:1]
    if lines and lines[0].startswith('#!'):
        if 'python' in lines[0]:
            return 'py'
        if 'node' in lines[0]:
            return 'js'
        return 'sh'
    return None


def walk(root, rel_dir):
    base = os.path.join(root, rel_dir)
    for here, dirs, files in os.walk(base):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            path = os.path.join(here, name)
            rel = os.path.relpath(path, root)
            if os.path.splitext(name)[1] in CODE_EXT or (
                    not os.path.splitext(name)[1] and shebang_kind(path)):
                yield rel


def registry_owner_files(registry):
    out = []
    for guard in registry.get('guards', []):
        for part in re.split(r'[,+\s]+', guard.get('owner', '') or ''):
            if part:
                out.append(part)
    return out


def hook_script_names(root):
    names = set()
    candidates = list(HOOK_JSON_GLOBS)
    grok = os.path.join(root, '.grok', 'hooks')
    if os.path.isdir(grok):
        candidates += ['.grok/hooks/' + n for n in sorted(os.listdir(grok)) if n.endswith('.json')]
    for rel in candidates:
        text = '\n'.join(read_lines(os.path.join(root, rel)))
        names.update(re.findall(r'bin/([A-Za-z0-9_.-]+\.(?:sh|py|mjs|ts))', text))
    return names


def is_hook_script(path, hook_names):
    base = os.path.basename(path)
    return base in hook_names or bool(re.search(r'-hook\.|pretool|posttool|turnend', base))


def is_helper_name(name):
    # A name part of the verb is a refusing function; a trailing _text part formats a message.
    parts = name.split('_')
    return (HELPER_WORD in parts and parts[-1] != 'text') or name in HELPER_EXACT


def collect_helpers(root, files):
    helpers = {'sh': set(), 'py': set(), 'js': set()}
    for rel in files:
        kind = kind_of(rel) if kind_of(rel) != 'other' else shebang_kind(os.path.join(root, rel))
        if kind not in helpers:
            continue
        pattern = {'sh': SH_DEF, 'py': PY_DEF, 'js': JS_DEF}[kind]
        for line in read_lines(os.path.join(root, rel)):
            match = pattern.match(line)
            if match:
                name = next((g for g in match.groups() if g), '')
                if name and is_helper_name(name):
                    helpers[kind].add(name)
    return helpers


def call_pattern(names, kind):
    if not names:
        return None
    alt = '|'.join(re.escape(n) for n in sorted(names, key=len, reverse=True))
    if kind == 'sh':
        return re.compile(r'(?:^\s*|[;&|({)]\s*|\b(?:then|do|else|elif|if|while|until)\s+|!\s*)(?:' + alt
                          + r')(?=\s|;|$)')
    return re.compile(r'(?<![.\w$])(?:' + alt + r')\s*\(')


def case_arm_text(line):
    """The message part of a shell case arm; a pattern such as *"connection refused"*) tests text and does not emit it."""
    quote = None
    for index, char in enumerate(line):
        if quote:
            if char == quote and line[index - 1] != '\\':
                quote = None
        elif char in '"\'':
            quote = char
        elif char == ')':
            if re.match(r'^[\s*S|]+$', STRING.sub('S', line[:index])):
                return line[index + 1:]
            break
    return line


def emits_refusal(text):
    """True when a string literal carries the refusal vocabulary; an operand of == or !=, or a prefix or suffix a startswith or endswith call tests for, does not emit it."""
    for match in STRING.finditer(text):
        if WORD.search(match.group()) and not COMPARED.search(text[:match.start()]) \
                and not re.match(r'\s*[=!]==?', text[match.end():]):
            return True
    return False


def is_comment(stripped, kind):
    if kind in ('sh', 'py', 'other'):
        return stripped.startswith('#')
    return stripped.startswith(('//', '*', '/*'))


def is_docstring_open(stripped, prev_code):
    """A triple-quoted string opening a block (first statement after a header) documents; any other runs."""
    if not re.match(r'[rRuUbBfF]{0,2}("""|\'\'\')', stripped):
        return False
    return prev_code is None or STRING.sub('S', prev_code).split('#', 1)[0].rstrip().endswith(':')


def command_words(text):
    """The words of one shell command: quoting is honored, and the command ends at ; & | ) } or a comment."""
    try:
        lexer = shlex.shlex(text, posix=True, punctuation_chars=True)
        lexer.whitespace_split = True
        words = []
        for word in lexer:
            if word.startswith('}') or set(word) <= set(';&|()<>'):
                break
            words.append(word)
        return words
    except ValueError:
        return text.split()  # unbalanced quotes: the plain split still keeps the order of the arguments


def event_denies(body):
    """True when a guard event call records a decision other than allow.

    The writer takes <guard-id> <decision>, so its decision is its second argument
    (bin/fm-guard-event.sh). A wrapper that takes the decision first is judged by
    that first argument. The guard id, a later option, a comment or a following
    command never decides: only a decision that is exactly allow is an allow event.
    """
    match = GUARD_EVENT.search(body)
    if not match:
        return False
    if re.search(r'\b(?:grep|egrep|sed|awk)\b', body[:match.start()]):
        return False  # a search for the writer's name, not a call to it
    args = command_words(body[match.end():])
    if match.group('cmd') == 'fm-guard-event.sh':
        decision = args[1] if len(args) > 1 else None
    else:
        decision = args[0] if args and args[0] in DECISIONS else (args[1] if len(args) > 1 else None)
    return decision != 'allow'


def embedded_kind(opener_line):
    """The language of a heredoc body when the opener feeds an interpreter, else None (text)."""
    if re.search(r'\b(?:python3?|py)\b', opener_line):
        return 'py'
    if re.search(r'\b(?:node|bun|deno)\b', opener_line):
        return 'js'
    return None


def scan_file(root, rel, helpers, hook_names):
    path = os.path.join(root, rel)
    kind = kind_of(rel)
    if kind == 'other':
        kind = shebang_kind(path) or 'other'
    lines = read_lines(path)
    hook = kind == 'sh' and is_hook_script(rel, hook_names)
    opencode = rel.startswith('.opencode/plugins/')
    heredoc = None
    heredoc_stderr = False
    body_kind = None
    triple = None
    prev_code = None
    sites = []
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        sig = []
        eff = kind
        if heredoc is not None:
            if stripped == heredoc:
                heredoc = None
                body_kind = None
                triple = None
                prev_code = None
                continue
            if body_kind is None:
                # A text heredoc is data: only a marker, or a message it prints to stderr, is a site.
                if MARKER.search(line):
                    sig.append('A')
                elif heredoc_stderr and WORD.search(line):
                    sig.append('B')
                if sig:
                    sites.append((number, ','.join(sig), stripped))
                continue
            eff = body_kind  # an interpreter heredoc is code in that interpreter's language
        if eff == 'py':
            quotes = len(re.findall(r'"""|\'\'\'', line))
            if triple == 'doc':
                if quotes % 2 == 1:
                    triple = None
                if MARKER.search(line):
                    sites.append((number, 'A', stripped))
                continue
            if triple == 'run':
                if quotes % 2 == 1:
                    triple = None
                sig = ['A'] if MARKER.search(line) else (['B'] if WORD.search(line) else [])
                if sig:
                    sites.append((number, ','.join(sig), stripped))
                continue
            if quotes % 2 == 1:
                if is_docstring_open(stripped, prev_code):
                    triple = 'doc'
                    if MARKER.search(line):
                        sites.append((number, 'A', stripped))
                    continue
                triple = 'run'  # a string expression that runs: scan its body like any message
                opener_tail = re.split(r'"""|\'\'\'', line)[-1]
                if WORD.search(opener_tail):
                    sig.append('B')
        if is_comment(stripped, eff) or not stripped:
            continue
        if eff == 'py' and triple is None and is_docstring_open(stripped, prev_code):
            continue  # a one-line docstring describes; it does not emit
        if eff == 'py' and triple is None:
            prev_code = stripped
        if eff == 'sh' and heredoc is None:
            opener = HEREDOC.search(line)
            # An opener with no terminator below it is a shift or an awk string, not a heredoc.
            if opener and any(row.strip() == opener.group(2) for row in lines[number:]):
                heredoc = opener.group(2)
                heredoc_stderr = '>&2' in line
                body_kind = embedded_kind(line)
        calls = call_pattern(helpers.get(eff, set()), eff) if eff in helpers else None
        if MARKER.search(line) and 'A' not in sig:
            sig.append('A')
        message = case_arm_text(line) if eff == 'sh' else line
        if emits_refusal(message) and 'B' not in sig:
            sig.append('B')
        # A definition header names a function and calls nothing; a one-line body after it still can.
        header = {'sh': SH_DEF, 'py': PY_DEF, 'js': JS_DEF}.get(eff)
        header = header.match(line) if header else None
        body = line[header.end():] if header else line
        if calls and calls.search(body):
            sig.append('C')
        if DENY_PERMISSION.search(line) or DENY_DECISION.search(line) or DENY_BLOCK.search(line) \
                or (hook and eff == 'sh' and EXIT_TWO.search(stripped)
                    and not any('usage' in row for row in lines[max(0, number - 3):number - 1])
                    and '$#' not in (lines[number - 2] if stripped == 'exit 2' and number > 1 else stripped)) \
                or (opencode and re.search(r'\bthrow new Error\(', line)):
            sig.append('D')
        if event_denies(body):
            sig.append('E')
        if sig:
            sites.append((number, ','.join(sig), stripped))
    return sites


def site_key(rel, text, seen):
    norm = ' '.join(text.split())
    digest = hashlib.sha1(norm.encode('utf-8', 'replace')).hexdigest()[:10]
    base = 'site:%s:%s' % (rel, digest)
    seen[base] = seen.get(base, 0) + 1
    return base if seen[base] == 1 else '%s~%d' % (base, seen[base])


def touched_lines(root, ref, rels):
    """File -> set of new-side line numbers changed since ref; None when the file is new."""
    def git(*args):
        return subprocess.run(['git', '-C', root] + list(args), capture_output=True, text=True)

    probe = git('rev-parse', '--verify', '--quiet', ref + '^{commit}')
    if probe.returncode != 0:
        print('error: cannot resolve base ref %r' % ref, file=sys.stderr)
        sys.exit(2)
    changed = {}
    diff = git('diff', '-U0', '--no-color', '--no-ext-diff', '--no-prefix', ref, '--', *rels)
    current = None
    for row in diff.stdout.split('\n'):
        if row.startswith('+++ '):
            current = None if row == '+++ /dev/null' else row[4:]
            if current is not None:
                changed.setdefault(current, set())
        elif row.startswith('@@') and current is not None:
            match = re.search(r'\+(\d+)(?:,(\d+))?', row)
            if match:
                start = int(match.group(1))
                count = int(match.group(2)) if match.group(2) is not None else 1
                changed[current].update(range(start, start + count))
    untracked = git('ls-files', '--others', '--exclude-standard', '--', *rels).stdout.split('\n')
    for rel in untracked:
        if rel:
            changed[rel] = None
    return changed


def map_sites(sites, registry):
    errors = []
    for guard in registry.get('guards', []):
        gid = guard.get('id', '')
        markers = guard.get('sites')
        if markers is None:
            continue
        if not isinstance(markers, list) or not all(
                isinstance(m, dict) and isinstance(m.get('file'), str) and isinstance(m.get('match'), str)
                and m['file'] and m['match'] for m in markers):
            errors.append(('S2', gid, 'sites must be a list of {file, match} objects with non-empty strings'))
            continue
        expected_total = 0
        for marker in markers:
            expected = marker.get('count', 1)
            if not isinstance(expected, int) or expected < 1:
                errors.append(('S2', gid, 'site marker count for %s must be a positive integer' % marker['file']))
                continue
            expected_total += expected
            hits = [s for s in sites if s['file'] == marker['file'] and marker['match'] in s['text_full']]
            if not hits:
                errors.append(('S2', gid, "site marker '%s' in %s matches no site; remove or update it"
                               % (marker['match'], marker['file'])))
                continue
            if len(hits) != expected:
                errors.append(('S2', gid, "site marker '%s' in %s matches %d sites, the entry declares %d;"
                               " review whether every new site shares the entry's invariant, then update count"
                               % (marker['match'], marker['file'], len(hits), expected)))
            for hit in hits:
                if hit['entry'] and hit['entry'] != gid:
                    errors.append(('S2', gid, 'site %s is already mapped to %s' % (hit['key'], hit['entry'])))
                else:
                    hit['entry'] = gid
        if expected_total > 1 and not (guard.get('group_reason') or '').strip():
            errors.append(('S3', gid, 'an entry that maps %d sites needs group_reason: why those sites share'
                           ' one invariant' % expected_total))
    return errors


def main(argv):
    root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    registry_path = None
    touched_ref = None
    args = list(argv)
    while args:
        arg = args.pop(0)
        if arg == '--root' and args:
            root = os.path.abspath(args.pop(0))
        elif arg == '--registry' and args:
            registry_path = args.pop(0)
        elif arg == '--touched-since' and args:
            touched_ref = args.pop(0)
        else:
            print('error: unknown argument %r' % arg, file=sys.stderr)
            return 2
    registry = {}
    registry_path = registry_path or os.path.join(root, 'docs', 'guards', 'registry.json')
    try:
        with open(registry_path) as handle:
            registry = json.load(handle)
    except (OSError, ValueError):
        registry = {}
    if not isinstance(registry, dict) or not isinstance(registry.get('guards'), list):
        registry = {'guards': []}
    registry['guards'] = [g for g in registry['guards'] if isinstance(g, dict)]

    files = []
    for rel_dir in DEFAULT_DIRS:
        if os.path.isdir(os.path.join(root, rel_dir)):
            files.extend(walk(root, rel_dir))
    for owned in registry_owner_files(registry):
        if owned not in files and os.path.isfile(os.path.join(root, owned)):
            files.append(owned)
    files = sorted(set(files))

    helpers = collect_helpers(root, files)
    hook_names = hook_script_names(root)
    sites = []
    for rel in files:
        seen = {}
        for number, sig, text in scan_file(root, rel, helpers, hook_names):
            sites.append({'key': site_key(rel, text, seen), 'file': rel, 'line': number, 'sig': sig,
                          'text': text[:200], 'text_full': text, 'entry': None, 'touched': False})
    errors = map_sites(sites, registry)

    if touched_ref:
        changed = touched_lines(root, touched_ref, files)
        for site in sites:
            lines = changed.get(site['file'], set())
            site['touched'] = lines is None or site['line'] in lines

    for site in sites:
        del site['text_full']
    json.dump({'paths': files, 'sites': sites, 'helpers': {k: sorted(v) for k, v in helpers.items()},
               'errors': [{'rule': r, 'id': i, 'message': m} for r, i, m in errors]}, sys.stdout)
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
