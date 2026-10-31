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
  sites      one record per site: key, file, line, sig, text, entry, touched,
             remedy and inclusive remedy_spans (diagnostic plus local helper bodies)
  errors     mapping problems: rule, id, message
  helpers    the refusal helper names the scan derived from the code

Exit: 0 on success; 2 on a usage or environment error.
"""
import ast
import hashlib
import json
import os
import re
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


def git_files(root):
    """Paths git tracks or would track; None when root is not the top of a git work tree."""
    try:
        top = subprocess.run(['git', '-C', root, 'rev-parse', '--show-toplevel'],
                             capture_output=True, text=True)
        if top.returncode != 0 or os.path.realpath(top.stdout.strip()) != os.path.realpath(root):
            return None
        listed = subprocess.run(['git', '-C', root, 'ls-files', '-z', '--cached', '--others',
                                 '--exclude-standard'],
                                capture_output=True, text=True)
    except OSError:
        return None
    if listed.returncode != 0:
        return None
    return {rel for rel in listed.stdout.split('\0') if rel and os.path.isfile(os.path.join(root, rel))}


def walk(root, rel_dir, listed):
    if listed is None:
        rels = []
        for here, dirs, files in os.walk(os.path.join(root, rel_dir)):
            dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
            rels.extend(os.path.relpath(os.path.join(here, name), root) for name in sorted(files))
    else:
        rels = sorted(rel for rel in listed if rel.startswith(rel_dir + '/')
                      and not SKIP_DIRS.intersection(rel.split('/')[:-1]))
    for rel in rels:
        ext = os.path.splitext(rel)[1]
        if ext in CODE_EXT or (not ext and shebang_kind(os.path.join(root, rel))):
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


def command_words(text, with_remainder=False):
    """The words of one shell command, with quote provenance.

    Quoting is honored as bash does: a quoted character is part of a word and never syntax.
    The command ends at an unquoted ; & | ( ) < >, at an unquoted } that stands alone as a
    word, or at an unquoted # that starts a word (a # inside a word is literal).
    """
    words = []
    word = []
    started = False  # a word is open, even an empty quoted one
    quote = None
    comment = False
    index = 0
    while index < len(text):
        char = text[index]
        index += 1
        if quote == "'":
            if char == "'":
                quote = None
            else:
                word.append(char)
        elif quote == '"':
            if char == '"':
                quote = None
            elif char == '\\' and index < len(text) and text[index] in '"\\$`':
                word.append(text[index])
                index += 1
            else:
                word.append(char)
        elif char in '"\'':
            quote = char
            started = True
        elif char == '\\' and index < len(text):
            word.append(text[index])
            index += 1
            started = True
        elif char in ' \t':
            if started:
                words.append(''.join(word))
            word, started = [], False
        elif char in ';&|()<>':
            break
        elif char == '#' and not started:
            comment = True
            break
        elif char == '}' and not started and (index >= len(text) or text[index] in ' \t;&|)'):
            break
        else:
            word.append(char)
            started = True
    if started and quote is None:
        words.append(''.join(word))
    if with_remainder:
        return words, '' if comment else text[index:]
    return words


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


def embedded_kind(opener_line, tag):
    """The language of a heredoc body when the opener feeds an interpreter, else None (text)."""
    if re.search(r'\b(?:python3?|py)\b', opener_line):
        return 'py'
    if re.search(r'\b(?:node|bun|deno)\b', opener_line):
        return 'js'
    if tag == 'PERL' or re.search(r'\bperl\b', opener_line):
        return 'sh'  # perl is scanned like a .pl file
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
                body_kind = embedded_kind(line, heredoc)
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


def diagnostic_statement(lines, index):
    """Return the joined statement and its inclusive, one-based source span."""
    if index and lines[index - 1].strip() == 'print(':
        index -= 1
    start = index + 1
    text = lines[index].strip()
    if re.match(r'(?:print|[A-Za-z_][A-Za-z0-9_]*' + HELPER_WORD + '|' + HELPER_WORD + r')\(', text):
        # Python diagnostics may span adjacent literals inside a single call.
        for end in range(index + 1, len(lines) + 1):
            candidate = '\n'.join(line.lstrip() for line in lines[index:end])
            try:
                ast.parse(candidate)
            except SyntaxError:
                continue
            return candidate, start, end
        return text, start, start
    while text.endswith('\\') and index + 1 < len(lines):
        index += 1
        text = text[:-1] + ' ' + lines[index].strip()
    return text, start, index + 1


def literal_message(value):
    if isinstance(value, ast.Constant) and isinstance(value.value, str):
        return value.value
    if isinstance(value, ast.JoinedStr):
        return ''.join(part.value for part in value.values if isinstance(part, ast.Constant))
    if isinstance(value, ast.BinOp) and isinstance(value.op, ast.Add):
        return literal_message(value.left) + literal_message(value.right)
    return ''


def diagnostic_arguments(statement):
    """Literal output arguments only, excluding comments and neighboring commands."""
    try:
        program = ast.parse(statement)
    except SyntaxError:
        program = None
    if program is not None:
        for node in program.body:
            value = node.value if isinstance(node, (ast.Expr, ast.Assign, ast.AnnAssign)) else None
            if isinstance(value, ast.Call) and isinstance(value.func, ast.Name) \
                    and (value.func.id in ('print', 'die') or is_helper_name(value.func.id)):
                name = value.func.id
                values = value.args  # file= and other keyword arguments are not message text
            elif isinstance(value, (ast.Constant, ast.JoinedStr)):
                name, values = None, [value]
            else:
                continue
            yield name, ' '.join(literal_message(value) for value in values)
        return
    remainder = statement
    while remainder:
        words, remainder = command_words(remainder, with_remainder=True)
        while words and words[0] in ('then', 'else', 'do', '!', 'export', 'local'):
            words = words[1:]
        if not words:
            continue
        if words[0] == 'fm_refuse':
            # The shared formatter owns this argument's printed envelope.
            text = 'completing-command: ' + words[5] if len(words) >= 6 and words[4] == 'machine' else ''
            yield words[0], text
        elif words[0] in ('echo', 'printf', 'die', 'return') or is_helper_name(words[0]):
            yield words[0], ' '.join(words[1:])
        elif len(words) == 1 and re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', words[0]):
            yield None, words[0].split('=', 1)[1]


def statement_has_remedy(statement, root):
    # A second command cannot lend its footer to a refusal that lacks one.
    # This syntactic lint still leaves remedy safety/sufficiency to fixtures and review.
    arguments = [text for _, text in diagnostic_arguments(statement)]
    refusals = [text for text in arguments if MARKER.search(text) or WORD.search(text)]
    for text in refusals or arguments:
        marker = re.search(r'\b(?:Remedy|completing-command):', text)
        if marker and remedy_has_command(text[marker.end():], root):
            return True
    return False


def remedy_has_command(remedy, root):
    paths = re.findall(r'\bbin/[A-Za-z0-9_./-]+', remedy)
    if any(not os.path.isfile(os.path.join(root, path.rstrip('.'))) for path in paths):
        return False
    return bool(re.search(r'\bbin/[A-Za-z0-9_.-]+|\bgit\s+|\bherdr\s+|\benv\s+-u\s+', remedy))


def site_remedies(root, lines, discovered, helpers):
    """Retain diagnostic/helper spans even when their remedy has been removed."""
    helper_remedies, helper_spans = set(), {}
    names = set().union(*helpers.values())
    for index, line in enumerate(lines):
        definition = PY_DEF.match(line) or SH_DEF.match(line) or JS_DEF.match(line)
        if not definition:
            continue
        name = next((group for group in definition.groups() if group), '')
        if name not in names:
            continue
        indent = len(line) - len(line.lstrip())
        end = index + 1
        for body_index in range(index + 1, len(lines)):
            body = lines[body_index]
            if body.strip() and len(body) - len(body.lstrip()) <= indent:
                break
            end = body_index + 1
            if body.lstrip().startswith(('echo ', 'printf ', 'print(')):
                statement, _, _ = diagnostic_statement(lines, body_index)
                if statement_has_remedy(statement, root):
                    helper_remedies.add(name)
        helper_spans[name] = [index + 1, end]
    result = {}
    for number, sig, _ in discovered:
        statement, start, end = diagnostic_statement(lines, number - 1)
        called = {name for name, _ in diagnostic_arguments(statement)}
        direct = statement_has_remedy(statement, root)
        call = bool(called.intersection(helper_remedies))
        spans = [[start, end]] + [helper_spans[name] for name in sorted(called - {None}) if name in helper_spans]
        result[number] = (direct or ('C' in sig.split(',') and call), spans)
    return result


def site_key(rel, text, seen):
    norm = ' '.join(text.split())
    digest = hashlib.sha1(norm.encode('utf-8', 'replace')).hexdigest()[:10]
    base = 'site:%s:%s' % (rel, digest)
    seen[base] = seen.get(base, 0) + 1
    return base if seen[base] == 1 else '%s~%d' % (base, seen[base])


def touched_lines(root, ref, rels):
    """File -> changed new-side lines/deletion boundaries; None when the file is new."""
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
                if count:
                    changed[current].update(range(start, start + count))
                else:
                    # A deleted footer has no new-side lines; retain both sides
                    # of its boundary so an unchanged caller cannot hide it.
                    changed[current].update((max(1, start), start + 1))
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
        for marker in markers:
            expected = marker.get('count', 1)
            if not isinstance(expected, int) or expected < 1:
                errors.append(('S2', gid, 'site marker count for %s must be a positive integer' % marker['file']))
                continue
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

    owners = registry_owner_files(registry)
    listed = git_files(root)
    files = []
    for rel_dir in DEFAULT_DIRS:
        if os.path.isdir(os.path.join(root, rel_dir)):
            files.extend(walk(root, rel_dir, listed))
    for owned in owners:
        if owned not in files and os.path.isfile(os.path.join(root, owned)) and (
                listed is None or owned in listed):
            files.append(owned)
    files = sorted(set(files))

    helpers = collect_helpers(root, files)
    hook_names = hook_script_names(root)
    sites = []
    for rel in files:
        seen = {}
        discovered = scan_file(root, rel, helpers, hook_names)
        remedies = site_remedies(root, read_lines(os.path.join(root, rel)), discovered, helpers)
        for number, sig, text in discovered:
            sites.append({'key': site_key(rel, text, seen), 'file': rel, 'line': number, 'sig': sig,
                          'text': text[:200], 'text_full': text, 'entry': None, 'touched': False,
                          'remedy': remedies[number][0], 'remedy_spans': remedies[number][1]})
    errors = map_sites(sites, registry)

    if touched_ref:
        changed = touched_lines(root, touched_ref, files)
        for site in sites:
            lines = changed.get(site['file'], set())
            site['touched'] = lines is None or any(start <= line <= end
                                                   for start, end in site['remedy_spans'] for line in lines)

    for site in sites:
        del site['text_full']
    json.dump({'paths': files, 'sites': sites, 'helpers': {k: sorted(v) for k, v in helpers.items()},
               'errors': [{'rule': r, 'id': i, 'message': m} for r, i, m in errors]}, sys.stdout)
    sys.stdout.write('\n')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
